#if os(macOS)
import AppKit
import AVKit
import AVFoundation
import CoreMedia
import VLCKitSPM
import GenPlayerCore
import GenPlayerVLCBridge
import GenPlayerPiPBridge

final class MacPiPHostView: NSView {
    override var isFlipped: Bool { false }
}

final class MacVLCPlayerPictureInPictureController: NSObject {
    private enum DrawableRestoreMode {
        case immediateRebuild
        case deferredUntilPlayerViewAttach
        case skip
    }

    private weak var playbackService: MacVLCPlaybackService?
    private var macPIPBridge: GenPlayerMacPIPBridge?

    // Legacy / Fallback AVPictureInPictureController fields
    private var bufferDisplayLayer = AVSampleBufferDisplayLayer()
    private let hostView = MacPiPHostView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    private var pictureInPictureController: AVPictureInPictureController?
    private var pipPossibleObservation: NSKeyValueObservation?
    private var playbackTimebase: CMTimebase?
    private var frameBridge: GenPlayerVLCFrameBridge?
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestRenderSize: CGSize = .zero
    private var lastPlaybackStateInvalidationTime: TimeInterval = .zero
    private var lastReportedPlaybackTime: Double = .zero
    private var lastReportedPlaybackDuration: Double = .zero
    private var lastReportedPlaybackPaused = false
    private let preferredFramesPerSecond = 30
    private let frameRenderQueue = DispatchQueue(label: "com.genplayer.mac.pip.frameRender", qos: .userInteractive)
    private var isPendingFirstStart = false
    private var isPictureInPictureStartInFlight = false
    private var hasActivePictureInPictureSession = false
    private var pendingStartTimeoutWorkItem: DispatchWorkItem?
    private var suppressPausedStateUntil: TimeInterval = .zero
    private var ignorePauseRequestsUntil: TimeInterval = .zero
    private var didDetachDrawableForPictureInPicture = false
    private var hasLoggedFirstFrame = false
    private var cachedFormatDescription: CMVideoFormatDescription?
    private var cachedFormatDescriptionDimensions: (Int, Int) = (0, 0)
    private var pipStateUpdateTimer: Timer?

    var isActiveSession: Bool {
        hasActivePictureInPictureSession || macPIPBridge?.isPIPActive == true
    }
    var isStartingOrActive: Bool {
        isActiveSession || isPendingFirstStart || isPictureInPictureStartInFlight || isRebuildingPlaybackSessionForBridge
    }
    private var isRebuildingPlaybackSessionForBridge = false

    var onDidStart: (() -> Void)?
    var onDidStop: (() -> Void)?
    var onStartFailed: (() -> Void)?

    init(playbackService: MacVLCPlaybackService) {
        self.playbackService = playbackService
        super.init()
    }

    deinit {
        invalidate()
    }

    func start() -> Bool {
        guard let playbackService,
              playbackService.currentFile != nil else {
            return false
        }

        if isActiveSession {
            return true
        }

        tearDownPreviousSessionIfNeeded()

        // 1. Try Native macOS PIP.framework bridge (same mechanism used by IINA / Safari)
        if GenPlayerMacPIPBridge.isPIPSupported(),
           let videoView = playbackService.activeVideoView {
            let bridge = GenPlayerMacPIPBridge()
            bridge.delegate = self
            macPIPBridge = bridge

            let naturalSize = (playbackService.mediaPlayer?.videoSize ?? .zero)
            let aspect: CGSize
            if naturalSize.width > 1, naturalSize.height > 1 {
                aspect = naturalSize
            } else {
                aspect = CGSize(width: 16, height: 9)
            }

            let success = bridge.startPIP(
                withVideoView: videoView,
                aspectRatio: aspect,
                isPlaying: playbackService.isPlaying,
                title: playbackService.currentFile?.name
            )

            if success {
                hasActivePictureInPictureSession = true
                print("[MacPiP] Started native macOS PIP.framework session successfully")
                startStateUpdateTimer()
                invalidatePlaybackStateIfNeeded(force: true)
                onDidStart?()
                return true
            }
        }

        // 2. Fallback to AVPictureInPictureController with frame bridge if needed
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            return false
        }

        hasActivePictureInPictureSession = false
        isPendingFirstStart = true
        isPictureInPictureStartInFlight = false
        latestPixelBuffer = nil
        latestRenderSize = .zero
        hasLoggedFirstFrame = false
        cachedFormatDescription = nil
        cachedFormatDescriptionDimensions = (0, 0)
        schedulePictureInPictureStartTimeout()
        prepareHostViewIfNeeded()
        preparePictureInPictureControllerIfNeeded()
        prepareFrameBridgeIfNeeded()
        guard rebuildPlaybackSessionForFrameBridgeIfNeeded() else {
            clearPictureInPictureStartAttempt()
            return false
        }
        renderCurrentFrame()

        guard let pictureInPictureController else {
            clearPictureInPictureStartAttempt()
            return false
        }

        updateLinearPlaybackRequirement(for: pictureInPictureController)
        print("[MacPiP] Fallback start requested active=\(pictureInPictureController.isPictureInPictureActive)")

        if pictureInPictureController.isPictureInPictureActive {
            clearPictureInPictureStartAttempt()
            return true
        }

        if pictureInPictureController.isPictureInPicturePossible,
           latestPixelBuffer != nil {
            requestPictureInPictureStartIfNeeded(using: pictureInPictureController)
            return true
        }

        return true
    }

    func stop() {
        if let macPIPBridge, macPIPBridge.isPIPActive {
            macPIPBridge.stopPIP()
            hasActivePictureInPictureSession = false
            onDidStop?()
            return
        }
        pictureInPictureController?.stopPictureInPicture()
        invalidate()
    }

    // MARK: - Setup (Fallback AVPictureInPictureController)

    private func prepareHostViewIfNeeded() {
        guard hostView.superview == nil,
              let playbackService else { return }

        let containerView = playbackService.activeVideoView?.window?.contentView
            ?? playbackService.activeVideoView?.superview
            ?? playbackService.activeVideoView
        guard let containerView else { return }

        let naturalSize = (playbackService.mediaPlayer?.videoSize ?? .zero)
        let aspect: CGFloat
        if naturalSize.width > 1, naturalSize.height > 1 {
            aspect = naturalSize.width / naturalSize.height
        } else {
            aspect = 16.0 / 9.0
        }

        let canvasW: CGFloat = 960
        let canvasH: CGFloat = (canvasW / aspect).rounded()

        let origin: CGPoint
        if let playerView = playbackService.activeVideoView {
            origin = containerView.convert(playerView.bounds.origin, from: playerView)
        } else {
            origin = .zero
        }
        let initialFrame = CGRect(x: origin.x, y: origin.y, width: canvasW, height: canvasH)

        hostView.wantsLayer = true
        hostView.layer?.backgroundColor = NSColor.clear.cgColor
        hostView.layer?.masksToBounds = false
        hostView.alphaValue = 0.0
        hostView.isHidden = false
        hostView.frame = initialFrame
        hostView.autoresizingMask = []

        if let playerView = playbackService.activeVideoView,
           playerView.superview === containerView {
            containerView.addSubview(hostView, positioned: .below, relativeTo: playerView)
        } else {
            containerView.addSubview(hostView, positioned: .below, relativeTo: nil)
        }

        bufferDisplayLayer.videoGravity = .resizeAspect
        bufferDisplayLayer.backgroundColor = NSColor.clear.cgColor
        bufferDisplayLayer.frame = hostView.bounds
        bufferDisplayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        if bufferDisplayLayer.superlayer !== hostView.layer {
            hostView.layer?.addSublayer(bufferDisplayLayer)
        }
        configurePlaybackTimebaseIfNeeded()
    }

    private func preparePictureInPictureControllerIfNeeded() {
        guard pictureInPictureController == nil else { return }

        bufferDisplayLayer.videoGravity = .resizeAspect
        bufferDisplayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        bufferDisplayLayer.backgroundColor = NSColor.clear.cgColor
        let controller = AVPictureInPictureController(
            contentSource: .init(
                sampleBufferDisplayLayer: bufferDisplayLayer,
                playbackDelegate: self
            )
        )
        controller.delegate = self
        pictureInPictureController = controller
        pipPossibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, change in
            guard let self,
                  change.newValue == true,
                  self.isPendingFirstStart,
                  self.latestPixelBuffer != nil,
                  !controller.isPictureInPictureActive else { return }
            DispatchQueue.main.async { [weak self] in
                self?.requestPictureInPictureStartIfNeeded(using: controller)
            }
        }
    }

    private func configurePlaybackTimebaseIfNeeded() {
        guard playbackTimebase == nil else { return }

        var timebase: CMTimebase?
        let result = CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase
        )
        guard result == noErr, let timebase else { return }

        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 0)
        playbackTimebase = timebase
        bufferDisplayLayer.controlTimebase = timebase
    }

    private func syncPlaybackTimebase() {
        guard let playbackService,
              let playbackTimebase else { return }

        let currentSec = Double(playbackService.currentTime) / 1000.0
        let currentTime = CMTime(
            seconds: max(currentSec, 0),
            preferredTimescale: 600
        )
        CMTimebaseSetTime(playbackTimebase, time: currentTime)

        let isPaused = pictureInPicturePlaybackIsPaused(using: playbackService)
        CMTimebaseSetRate(playbackTimebase, rate: isPaused ? 0 : 1)
    }

    private func updateLinearPlaybackRequirement(for controller: AVPictureInPictureController? = nil) {
        guard let playbackService else { return }
        let resolvedController = controller ?? pictureInPictureController
        let durSec = Double(playbackService.duration) / 1000.0
        resolvedController?.requiresLinearPlayback = durSec <= 0.5
    }

    private func pictureInPicturePlaybackIsPaused(using playbackService: MacVLCPlaybackService) -> Bool {
        let isActuallyPaused = !playbackService.isPlaying
        if isActuallyPaused,
           Date().timeIntervalSinceReferenceDate < suppressPausedStateUntil {
            return false
        }
        return isActuallyPaused
    }

    // MARK: - Frame Bridge

    private func prepareFrameBridgeIfNeeded() {
        guard frameBridge == nil else { return }
        let bridge = GenPlayerVLCFrameBridge()
        bridge.maximumRenderWidth = 1280
        bridge.minimumFrameInterval = 1.0 / Double(preferredFramesPerSecond)
        bridge.callbackQueue = frameRenderQueue
        bridge.videoSizeHandler = { [weak self] size in
            self?.latestRenderSize = size
        }
        bridge.frameHandler = { [weak self] pixelBuffer in
            self?.handleOutputPixelBuffer(pixelBuffer)
        }
        frameBridge = bridge
    }

    private func rebuildPlaybackSessionForFrameBridgeIfNeeded() -> Bool {
        guard let playbackService,
              let currentFile = playbackService.currentFile else { return false }
        prepareFrameBridgeIfNeeded()
        didDetachDrawableForPictureInPicture = true
        isRebuildingPlaybackSessionForBridge = true

        let preservedTimeSec = max(Double(playbackService.currentTime) / 1000.0, 0)

        playbackService.mediaPlayer?.stop()
        playbackService.mediaPlayer?.drawable = nil

        do {
            if let player = playbackService.mediaPlayer { try frameBridge?.attach(to: player) }
        } catch {
            isRebuildingPlaybackSessionForBridge = false
            restoreDrawableIfNeeded(mode: .immediateRebuild)
            return false
        }

        isRebuildingPlaybackSessionForBridge = false

        var fileToPlay = currentFile
        if preservedTimeSec > 1.0 {
            fileToPlay.lastPlayedPosition = preservedTimeSec
        }
        playbackService.play(file: fileToPlay, forceSwDecoding: true)
        return true
    }

    private func restoreDrawableIfNeeded(mode: DrawableRestoreMode) {
        frameBridge?.detach()
        guard didDetachDrawableForPictureInPicture,
              let playbackService else { return }
        switch mode {
        case .immediateRebuild:
            playbackService.reloadCurrentItemPreservingPlaybackState()
        case .deferredUntilPlayerViewAttach:
            playbackService.markDeferredDrawablePlaybackSessionRestoreAfterPictureInPicture()
        case .skip:
            playbackService.clearDeferredDrawablePlaybackSessionRestoreAfterPictureInPicture()
        }
        didDetachDrawableForPictureInPicture = false
    }

    private func handleOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        latestPixelBuffer = pixelBuffer
        if latestRenderSize.width <= 1 || latestRenderSize.height <= 1 {
            latestRenderSize = CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        }
        renderCurrentFrame()
    }

    private func renderCurrentFrame() {
        guard playbackService != nil else {
            DispatchQueue.main.async { [weak self] in self?.invalidate() }
            return
        }

        guard let latestPixelBuffer else { return }

        let sampleBuffer = makeSampleBuffer(from: latestPixelBuffer)
        guard let sampleBuffer else { return }

        DispatchQueue.main.async { [weak self] in self?.syncPlaybackTimebase() }

        let resolvedRenderSize: CGSize
        if latestRenderSize.width > 1, latestRenderSize.height > 1 {
            resolvedRenderSize = latestRenderSize
        } else {
            resolvedRenderSize = CGSize(
                width: CVPixelBufferGetWidth(latestPixelBuffer),
                height: CVPixelBufferGetHeight(latestPixelBuffer)
            )
        }

        if bufferDisplayLayer.status == .failed {
            bufferDisplayLayer.flush()
        }
        bufferDisplayLayer.enqueue(sampleBuffer)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateRenderBounds(for: resolvedRenderSize)
            self.invalidatePlaybackStateIfNeeded()
            self.attemptPendingPictureInPictureStartIfReady()
        }
    }

    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        if cachedFormatDescription == nil ||
           cachedFormatDescriptionDimensions != (width, height) {
            var desc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &desc
            )
            if status == noErr, let desc {
                cachedFormatDescription = desc
                cachedFormatDescriptionDimensions = (width, height)
            }
        }
        guard let formatDescription = cachedFormatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true
        ) as? [NSMutableDictionary], let dict = attachments.first {
            dict[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        return sampleBuffer
    }

    // MARK: - Playback State

    func invalidatePlaybackStateIfNeeded(force: Bool = false) {
        if let macPIPBridge, macPIPBridge.isPIPActive, let playbackService {
            let elapsed = Double(playbackService.currentTime) / 1000.0
            let dur = Double(playbackService.duration) / 1000.0
            macPIPBridge.updatePlaybackProgress(elapsed, duration: dur, isPlaying: playbackService.isPlaying)
            return
        }

        guard let pictureInPictureController,
              let playbackService,
              hasActivePictureInPictureSession else { return }

        let currentTime = max(Double(playbackService.currentTime) / 1000.0, 0)
        let duration = max(Double(playbackService.duration) / 1000.0, 0)
        let isPaused = pictureInPicturePlaybackIsPaused(using: playbackService)
        let now = Date().timeIntervalSinceReferenceDate

        let didPauseStateChange = isPaused != lastReportedPlaybackPaused
        let didDurationChange = abs(duration - lastReportedPlaybackDuration) >= 0.5
        let didPlaybackTimeJump = abs(currentTime - lastReportedPlaybackTime) >= 0.5
        let didThrottleWindowElapse = now - lastPlaybackStateInvalidationTime >= 0.25

        guard force || didPauseStateChange || didDurationChange || (didPlaybackTimeJump && didThrottleWindowElapse) else {
            return
        }

        lastPlaybackStateInvalidationTime = now
        lastReportedPlaybackTime = currentTime
        lastReportedPlaybackDuration = duration
        lastReportedPlaybackPaused = isPaused
        updateLinearPlaybackRequirement(for: pictureInPictureController)
        pictureInPictureController.invalidatePlaybackState()
    }

    // MARK: - Start Helpers

    private func attemptPendingPictureInPictureStartIfReady() {
        guard isPendingFirstStart,
              let pictureInPictureController,
              latestPixelBuffer != nil,
              !pictureInPictureController.isPictureInPictureActive,
              pictureInPictureController.isPictureInPicturePossible else {
            return
        }
        requestPictureInPictureStartIfNeeded(using: pictureInPictureController)
    }

    private func updateRenderBounds(for resolvedSize: CGSize) {
        guard !hasActivePictureInPictureSession else { return }
        guard resolvedSize.width > 1, resolvedSize.height > 1 else { return }
        let aspect = resolvedSize.width / resolvedSize.height
        let currentW = max(hostView.frame.width, 480)
        let fitH = (currentW / aspect).rounded()
        let newFrame = CGRect(x: hostView.frame.minX, y: hostView.frame.minY,
                              width: currentW, height: fitH)
        guard abs(hostView.frame.height - fitH) > 1 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostView.frame = newFrame
        bufferDisplayLayer.frame = hostView.bounds
        CATransaction.commit()
    }

    private func requestPictureInPictureStartIfNeeded(using controller: AVPictureInPictureController? = nil) {
        let resolvedController = controller ?? pictureInPictureController
        guard let resolvedController,
              !resolvedController.isPictureInPictureActive,
              !isPictureInPictureStartInFlight else {
            return
        }
        isPendingFirstStart = false
        isPictureInPictureStartInFlight = true
        DispatchQueue.main.async { [weak resolvedController] in
            guard let resolvedController,
                  !resolvedController.isPictureInPictureActive else { return }
            resolvedController.startPictureInPicture()
        }
    }

    private func clearPictureInPictureStartAttempt() {
        isPendingFirstStart = false
        isPictureInPictureStartInFlight = false
        pendingStartTimeoutWorkItem?.cancel()
        pendingStartTimeoutWorkItem = nil
    }

    private func schedulePictureInPictureStartTimeout() {
        pendingStartTimeoutWorkItem?.cancel()
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isPendingFirstStart || self.isPictureInPictureStartInFlight else { return }
            guard self.pictureInPictureController?.isPictureInPictureActive != true else {
                self.clearPictureInPictureStartAttempt()
                return
            }
            self.clearPictureInPictureStartAttempt()
            self.onStartFailed?()
        }
        pendingStartTimeoutWorkItem = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: timeoutItem)
    }

    private func tearDownPreviousSessionIfNeeded() {
        if macPIPBridge?.isPIPActive == true {
            macPIPBridge?.stopPIP()
            macPIPBridge = nil
        }
        invalidate()
    }

    private func startStateUpdateTimer() {
        stopStateUpdateTimer()
        pipStateUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.invalidatePlaybackStateIfNeeded(force: false)
        }
    }

    private func stopStateUpdateTimer() {
        pipStateUpdateTimer?.invalidate()
        pipStateUpdateTimer = nil
    }

    // MARK: - Lifecycle

    private func invalidate(drawableRestoreMode: DrawableRestoreMode = .skip) {
        stopStateUpdateTimer()
        clearPictureInPictureStartAttempt()
        hasActivePictureInPictureSession = false
        isRebuildingPlaybackSessionForBridge = false
        pipPossibleObservation?.invalidate()
        pipPossibleObservation = nil
        restoreDrawableIfNeeded(mode: drawableRestoreMode)
        frameBridge = nil
        latestPixelBuffer = nil
        latestRenderSize = .zero
        hasLoggedFirstFrame = false
        cachedFormatDescription = nil
        cachedFormatDescriptionDimensions = (0, 0)
        playbackTimebase = nil
        bufferDisplayLayer.controlTimebase = nil
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil
        bufferDisplayLayer.flushAndRemoveImage()
        bufferDisplayLayer.removeFromSuperlayer()
        hostView.removeFromSuperview()
        macPIPBridge = nil
    }
}

// MARK: - GenPlayerMacPIPBridgeDelegate

extension MacVLCPlayerPictureInPictureController: GenPlayerMacPIPBridgeDelegate {
    func pipBridgeDidClose() {
        stopStateUpdateTimer()
        hasActivePictureInPictureSession = false
        onDidStop?()
    }

    func pipBridgeRequestRestore() {
        _ = playbackService?.requestVideoPlayerRestoreFromPictureInPicture()
    }

    func pipBridgeRequestPlay() {
        if playbackService?.isPlaying == false {
            playbackService?.togglePlayPause()
        }
    }

    func pipBridgeRequestPause() {
        if playbackService?.isPlaying == true {
            playbackService?.togglePlayPause()
        }
    }

    func pipBridgeRequestStop() {
        if playbackService?.isPlaying == true {
            playbackService?.togglePlayPause()
        }
    }

    func pipBridgeRequestSeek(byInterval interval: TimeInterval) {
        playbackService?.seek(by: Int32(interval * 1000.0))
    }
}

// MARK: - AVPictureInPictureControllerDelegate (Fallback)

extension MacVLCPlayerPictureInPictureController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        hasActivePictureInPictureSession = true
        clearPictureInPictureStartAttempt()
        startStateUpdateTimer()
        configurePlaybackTimebaseIfNeeded()
        updateLinearPlaybackRequirement(for: pictureInPictureController)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bufferDisplayLayer.frame = hostView.bounds
        CATransaction.commit()
        renderCurrentFrame()
        invalidatePlaybackStateIfNeeded(force: true)
        onDidStart?()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        hasActivePictureInPictureSession = false
        let drawableRestoreMode: DrawableRestoreMode =
            playbackService?.hasPendingPictureInPictureRestoreRequest() == true
            ? .deferredUntilPlayerViewAttach
            : .skip
        invalidate(drawableRestoreMode: drawableRestoreMode)
        onDidStop?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        hasActivePictureInPictureSession = false
        invalidate(drawableRestoreMode: .immediateRebuild)
        onStartFailed?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        let didRequestRestore = playbackService?.requestVideoPlayerRestoreFromPictureInPicture(
            completion: completionHandler
        ) ?? false
        if !didRequestRestore {
            completionHandler(false)
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate (Fallback)

extension MacVLCPlayerPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        guard hasActivePictureInPictureSession,
              let playbackService else { return }

        let now = Date().timeIntervalSinceReferenceDate
        if !playing,
           now < ignorePauseRequestsUntil,
           !pictureInPicturePlaybackIsPaused(using: playbackService) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.invalidatePlaybackStateIfNeeded(force: true)
            }
            return
        }

        let isPaused = pictureInPicturePlaybackIsPaused(using: playbackService)
        let shouldBePaused = !playing
        guard shouldBePaused != isPaused else { return }

        if shouldBePaused {
            suppressPausedStateUntil = .zero
            ignorePauseRequestsUntil = .zero
        } else {
            suppressPausedStateUntil = now + 0.8
            ignorePauseRequestsUntil = .zero
        }
        playbackService.togglePlayPause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            self?.invalidatePlaybackStateIfNeeded(force: true)
            self?.renderCurrentFrame()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        didTransitionToRenderSize newRenderSize: CMVideoDimensions
    ) {
        let width = CGFloat(newRenderSize.width)
        let height = CGFloat(newRenderSize.height)
        guard width > 1, height > 1 else { return }

        // Update VLC render quality to match the PiP window's physical resolution
        let backingScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let targetRenderWidth = max(640, min(1920, Int(width * backingScale)))
        if let bridge = frameBridge, bridge.maximumRenderWidth != targetRenderWidth {
            bridge.maximumRenderWidth = targetRenderWidth
        }

        let applyLayout = { [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            // Keep origin, update size to match the PiP render area
            self.hostView.setFrameSize(NSSize(width: width, height: height))
            self.bufferDisplayLayer.frame = self.hostView.bounds
            CATransaction.commit()
            self.renderCurrentFrame()
        }

        if Thread.isMainThread {
            applyLayout()
        } else {
            DispatchQueue.main.async(execute: applyLayout)
        }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        guard hasActivePictureInPictureSession,
              let playbackService else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }

        let currentTime = max(Double(playbackService.currentTime) / 1000.0, 0)
        let duration = max(Double(playbackService.duration) / 1000.0, currentTime + 1)
        guard duration > 0.5 else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }

        return CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: duration, preferredTimescale: 600)
        )
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        guard hasActivePictureInPictureSession else { return false }
        guard let playbackService else { return true }
        return pictureInPicturePlaybackIsPaused(using: playbackService)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        guard hasActivePictureInPictureSession,
              let playbackService,
              playbackService.duration > 500 else {
            completionHandler()
            return
        }

        let seconds = skipInterval.seconds
        guard seconds.isFinite, abs(seconds) > 0.01 else {
            completionHandler()
            return
        }

        let configuredStep = max(Double(UserDefaults.standard.integer(forKey: "doubleTapSeekDuration")), 10.0)
        let resolvedSeekDelta = seconds < 0 ? -configuredStep : configuredStep
        let currentSec = Double(playbackService.currentTime) / 1000.0
        let durSec = Double(playbackService.duration) / 1000.0
        let targetSec = max(0, min(durSec, currentSec + resolvedSeekDelta))
        let targetPos = Float(targetSec / durSec)

        playbackService.setPosition(targetPos)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.invalidatePlaybackStateIfNeeded(force: true)
            self?.renderCurrentFrame()
            completionHandler()
        }
    }
}
#endif
