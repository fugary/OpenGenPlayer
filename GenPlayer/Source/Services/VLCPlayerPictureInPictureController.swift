import UIKit
import AVKit
import CoreMedia
import MobileVLCKit
import GenPlayerShell

final class VLCPlayerPictureInPictureController: NSObject {
    private enum DrawableRestoreMode {
        case immediateRebuild
        case deferredUntilPlayerViewAttach
        case skip
    }

    private weak var playbackService: VLCPlaybackService?
    private var bufferDisplayLayer = AVSampleBufferDisplayLayer()
    private let hostView = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
    private var pictureInPictureController: AVPictureInPictureController?
    private var pipPossibleObservation: NSKeyValueObservation?
    private var playbackTimebase: CMTimebase?
    private var frameBridge: GenPlayerVLCFrameBridge?
    private var mpvOutput: MPVPixelBufferOutput?
    private var subtitleCompositor = PlaybackPixelBufferCompositor()
    private var pausedSubtitleTimer: Timer?
    private var frameGeneration = UUID()
    private var originalVideoSize: CGSize = .zero
    private(set) var usesMPVFrameOutput = false
    var isPreparingOrActive: Bool {
        hasActivePictureInPictureSession || isPendingFirstStart || isPictureInPictureStartInFlight
    }
    private var latestPixelBuffer: CVPixelBuffer?
    private var latestRenderSize: CGSize = .zero
    private var lastPlaybackStateInvalidationTime: TimeInterval = .zero
    private var lastReportedPlaybackTime: Double = .zero
    private var lastReportedPlaybackDuration: Double = .zero
    private var lastReportedPlaybackPaused = false
    private let preferredFramesPerSecond = 30
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

    var isActiveSession: Bool { hasActivePictureInPictureSession }
    /// True while `rebuildPlaybackSessionForFrameBridgeIfNeeded` is running.
    /// Prevents `play(item:)` from prematurely detaching the bridge that is
    /// about to be attached inside the `preparePlayer` closure.
    private var isRebuildingPlaybackSessionForBridge = false

    // All frame delivery and lifecycle state is serialized on the main queue.
    // Native rendering/conversion remain off-main in their respective producers.
    func invalidateFrameOutputForPlaybackChange() {
        guard !isRebuildingPlaybackSessionForBridge else { return }
        frameGeneration = UUID()
        mpvOutput?.invalidate()
        mpvOutput = nil
        frameBridge?.detach()
        frameBridge = nil
        latestPixelBuffer = nil
        pausedSubtitleTimer?.invalidate()
        pausedSubtitleTimer = nil
        subtitleCompositor = PlaybackPixelBufferCompositor()
        playbackService?.clearPictureInPictureSubtitleOverlay()
        latestRenderSize = .zero
        cachedFormatDescription = nil
        cachedFormatDescriptionDimensions = (0, 0)
        bufferDisplayLayer.flushAndRemoveImage()
    }

    func makeMPVFrameOutput(sourceSize: CGSize) -> MPVPixelBufferOutput? {
        guard isPreparingOrActive else { return nil }
        invalidateFrameOutputForPlaybackChange()
        usesMPVFrameOutput = true
        didDetachDrawableForPictureInPicture = true
        let generation = frameGeneration
        let source = sourceSize.width > 1 && sourceSize.height > 1 ? sourceSize : originalVideoSize
        let output = MPVPixelBufferOutput(sourceSize: source, queue: .main) { [weak self] buffer in
            guard let self, self.frameGeneration == generation, self.isPreparingOrActive else { return }
            self.handleOutputPixelBuffer(buffer)
        }
        mpvOutput = output
        // A paused native renderer need not deliver new frames when a translation
        // finishes or a subtitle setting changes. Refresh the cached frame locally.
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self, self.frameGeneration == generation, self.isPreparingOrActive,
                  self.playbackService?.state.status == .paused else { return }
            self.renderCurrentFrame()
        }
        pausedSubtitleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return output
    }

    @discardableResult
    func handleMPVFrameOutputFailure() -> Bool {
        guard usesMPVFrameOutput, isPreparingOrActive else { return false }
        if let controller = pictureInPictureController, controller.isPictureInPictureActive {
            _ = playbackService?.requestVideoPlayerRestoreFromPictureInPicture()
            controller.stopPictureInPicture()
        } else {
            invalidate(drawableRestoreMode: .immediateRebuild)
            onStartFailed?()
        }
        return true
    }

    func forceDetachFrameBridge() {
        guard !isRebuildingPlaybackSessionForBridge else { return }
        frameBridge?.detach()
    }

    func cancelPendingStartForPlaybackFailure() {
        guard isPendingFirstStart || isPictureInPictureStartInFlight else { return }
        let controller = pictureInPictureController
        // Invalidate first so late AVKit callbacks cannot rebuild the failed session.
        invalidate(drawableRestoreMode: .skip)
        controller?.stopPictureInPicture()
        onStartFailed?()
    }
    
    @available(iOS 15.0, *)
    func attachFrameBridge(to player: VLCMediaPlayer) {
        guard hasActivePictureInPictureSession else { return }
        usesMPVFrameOutput = false
        prepareFrameBridgeIfNeeded()
        didDetachDrawableForPictureInPicture = true
        do {
            try frameBridge?.attach(to: player)
        } catch {
            print("[PiP] frame bridge attach error on restart: \(error.localizedDescription)")
        }
    }

    var onDidStart: (() -> Void)?
    var onDidStop: (() -> Void)?
    var onStartFailed: (() -> Void)?

    init(playbackService: VLCPlaybackService) {
        self.playbackService = playbackService
        super.init()
    }

    deinit {
        invalidate()
    }

    @available(iOS 15.0, *)
    func start() -> Bool {
        guard let playbackService,
              playbackService.state.currentItem != nil,
              AVPictureInPictureController.isPictureInPictureSupported() else {
            return false
        }

        // If PiP is already running, don't reset the session.
        if isPreparingOrActive { return true }

        // Tear down any leftover state from a previous PiP session before
        // creating the new one.  This ensures the old frame bridge is fully
        // detached (and its VLC callbacks de-registered) before we allocate
        // a new bridge, and the display layer is fresh to avoid -12080.
        tearDownPreviousSessionIfNeeded()
        originalVideoSize = playbackService.videoNaturalSize

        playbackService.prepareAudioSessionForPictureInPictureStart()
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
        guard rebuildPlaybackSessionForFrameBridgeIfNeeded() else {
            invalidate(drawableRestoreMode: .immediateRebuild)
            return false
        }
        renderCurrentFrame()

        guard let pictureInPictureController else {
            invalidate(drawableRestoreMode: .immediateRebuild)
            return false
        }

        updateLinearPlaybackRequirement(for: pictureInPictureController)
        pictureInPictureController.canStartPictureInPictureAutomaticallyFromInline = false
        print("[PiP] start requested active=\(pictureInPictureController.isPictureInPictureActive) possible=\(pictureInPictureController.isPictureInPicturePossible) duration=\(playbackService.state.duration) currentTime=\(playbackService.state.currentTime) layerStatus=\(bufferDisplayLayer.status.rawValue) layerError=\(String(describing: bufferDisplayLayer.error))")

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

    @available(iOS 15.0, *)
    func stop() {
        pictureInPictureController?.stopPictureInPicture()
        invalidate()
    }

    func handleMediaPlayerSnapshot(from player: VLCMediaPlayer) {
        _ = player
    }

    // MARK: - Setup

    private func prepareHostViewIfNeeded() {
        guard hostView.superview == nil,
              let playbackService else { return }

        let containerView = UIApplication.activeKeyWindow()
            ?? playbackService.pipUsableViewController?.viewIfLoaded
            ?? playbackService.playerView?.superview
        guard let containerView else { return }

        hostView.backgroundColor = .clear
        hostView.alpha = 0.0
        hostView.isUserInteractionEnabled = false
        hostView.clipsToBounds = true

        if let playerView = playbackService.playerView,
           playerView.superview === containerView {
            containerView.insertSubview(hostView, belowSubview: playerView)
        } else {
            containerView.addSubview(hostView)
            containerView.sendSubviewToBack(hostView)
        }
        bufferDisplayLayer.frame = hostView.bounds
        if bufferDisplayLayer.superlayer !== hostView.layer {
            hostView.layer.addSublayer(bufferDisplayLayer)
        }
        print("[PiP] hostView attached to \(type(of: containerView)) playerSuperviewMatch=\(playbackService.playerView?.superview === containerView)")
    }

    private func retainPlayerViewForPictureInPictureRestoreIfNeeded() {
        guard hasActivePictureInPictureSession,
              let playbackService,
              let playerView = playbackService.playerView,
              playerView.superview !== hostView,
              playerView.window != nil else {
            return
        }

        playerView.removeFromSuperview()
        hostView.addSubview(playerView)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: hostView.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: hostView.bottomAnchor),
            playerView.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: hostView.trailingAnchor)
        ])
        hostView.layoutIfNeeded()
        print("[PiP] playerView retained in hostView for restore")
    }

    @available(iOS 15.0, *)
    private func preparePictureInPictureControllerIfNeeded() {
        guard pictureInPictureController == nil else { return }

        bufferDisplayLayer.videoGravity = .resizeAspect
        bufferDisplayLayer.backgroundColor = UIColor.clear.cgColor
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
            print("[PiP] isPictureInPicturePossible changed -> \(String(describing: change.newValue)) active=\(controller.isPictureInPictureActive)")
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

    @available(iOS 15.0, *)
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

    @available(iOS 15.0, *)
    private func syncPlaybackTimebase() {
        guard hasActivePictureInPictureSession,
              let playbackService,
              let playbackTimebase else { return }

        let currentTime = CMTime(
            seconds: max(playbackService.state.currentTime, 0),
            preferredTimescale: 600
        )
        CMTimebaseSetTime(playbackTimebase, time: currentTime)

        let isPaused = pictureInPicturePlaybackIsPaused(using: playbackService)
        CMTimebaseSetRate(playbackTimebase, rate: isPaused ? 0 : Double(playbackService.playbackRate))
    }

    @available(iOS 15.0, *)
    private func updateLinearPlaybackRequirement(for controller: AVPictureInPictureController? = nil) {
        guard let playbackService else { return }
        let resolvedController = controller ?? pictureInPictureController
        resolvedController?.requiresLinearPlayback = playbackService.state.duration <= 0.5
    }

    private func pictureInPicturePlaybackIsPaused(using playbackService: VLCPlaybackService) -> Bool {
        let isActuallyPaused = !(
            (!playbackService.isUsingMPV && (playbackService.mediaPlayer?.isPlaying ?? false)) ||
            playbackService.state.status == .playing ||
            playbackService.state.status == .buffering
        )
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
        bridge.maximumRenderWidth = 480
        bridge.minimumFrameInterval = 1.0 / Double(preferredFramesPerSecond)
        bridge.callbackQueue = .main // The bridge already caps pending deliveries at two.
        let generation = frameGeneration
        bridge.videoSizeHandler = { [weak self] size in
            guard let self, self.frameGeneration == generation else { return }
            self.latestRenderSize = size
        }
        bridge.frameHandler = { [weak self] pixelBuffer in
            guard let self, self.frameGeneration == generation, self.isPreparingOrActive else { return }
            self.handleOutputPixelBuffer(pixelBuffer)
        }
        frameBridge = bridge
    }

    private func rebuildPlaybackSessionForFrameBridgeIfNeeded() -> Bool {
        guard let playbackService else { return false }
        if playbackService.canUseNativeMPVPictureInPicture {
            usesMPVFrameOutput = true
            didDetachDrawableForPictureInPicture = true
            return playbackService.reloadCurrentItemForMPVPictureInPicture()
        }
        usesMPVFrameOutput = false
        prepareFrameBridgeIfNeeded()
        didDetachDrawableForPictureInPicture = true
        isRebuildingPlaybackSessionForBridge = true
        let currentPlayerView = playbackService.playerView
        playbackService.mediaPlayer?.drawable = nil
        playbackService.reloadCurrentItemPreservingPlaybackState(
            in: nil,
            bindToExistingPlayerView: false
        ) { [weak self] player in
            guard let self else { return }
            self.isRebuildingPlaybackSessionForBridge = false
            do {
                try self.frameBridge?.attach(to: player)
                print("[PiP] rebuilt VLC playback session for frame bridge")
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.restoreDrawableIfNeeded(mode: .immediateRebuild)
                    if let currentPlayerView {
                        playbackService.playerView = currentPlayerView
                        playbackService.mediaPlayer?.drawable = currentPlayerView
                    }
                }
                throw error
            }
        }
        return true
    }

    private func restoreDrawableIfNeeded(mode: DrawableRestoreMode) {
        invalidateFrameOutputForPlaybackChange()
        usesMPVFrameOutput = false
        guard didDetachDrawableForPictureInPicture,
              let playbackService else { return }
        guard !playbackService.hasTerminalPlaybackFailure else {
            didDetachDrawableForPictureInPicture = false
            playbackService.clearDeferredDrawablePlaybackSessionRestoreAfterPictureInPicture()
            return
        }
        switch mode {
        case .immediateRebuild:
            let currentPlayerView = playbackService.playerView
            playbackService.reloadCurrentItemPreservingPlaybackState(
                in: currentPlayerView,
                bindToExistingPlayerView: currentPlayerView != nil
            )
            print("[PiP] rebuilt VLC playback session for drawable restore")
        case .deferredUntilPlayerViewAttach:
            playbackService.markDeferredDrawablePlaybackSessionRestoreAfterPictureInPicture()
            print("[PiP] deferred drawable playback session restore until player view reattaches")
        case .skip:
            playbackService.clearDeferredDrawablePlaybackSessionRestoreAfterPictureInPicture()
        }
        didDetachDrawableForPictureInPicture = false
    }

    private func handleOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        // Producers deliver only current-session buffers on the main queue.
        latestPixelBuffer = pixelBuffer
        if usesMPVFrameOutput || latestRenderSize.width <= 1 || latestRenderSize.height <= 1 {
            latestRenderSize = CGSize(
                width: CVPixelBufferGetWidth(pixelBuffer),
                height: CVPixelBufferGetHeight(pixelBuffer)
            )
        }
        if !hasLoggedFirstFrame {
            hasLoggedFirstFrame = true
            print("[PiP] received first video frame size=\(Int(latestRenderSize.width))x\(Int(latestRenderSize.height))")
        }
        if #available(iOS 15.0, *) {
            renderCurrentFrame()
        }
    }

    @available(iOS 15.0, *)
    private func renderCurrentFrame() {
        // Lifecycle, sample enqueue and format descriptions share the main queue.
        guard let playbackService else {
            DispatchQueue.main.async { [weak self] in self?.invalidate() }
            return
        }

        guard let latestPixelBuffer else { return }
        if bufferDisplayLayer.status == .failed {
            print("[PiP] layer failed, error=\(String(describing: bufferDisplayLayer.error)), flushing")
            bufferDisplayLayer.flush()
        }
        guard bufferDisplayLayer.isReadyForMoreMediaData else { return }

        // Build sample buffer with DisplayImmediately — avoids PTS/timebase
        // mismatch that causes the display layer to mis‑schedule frames.
        let displayBuffer: CVPixelBuffer
        if usesMPVFrameOutput {
            let size = CGSize(width: CVPixelBufferGetWidth(latestPixelBuffer), height: CVPixelBufferGetHeight(latestPixelBuffer))
            let overlay = playbackService.pictureInPictureSubtitleOverlay(size: size)
            guard let composed = subtitleCompositor.compose(latestPixelBuffer, overlay: overlay) else { return }
            displayBuffer = composed
        } else { displayBuffer = latestPixelBuffer }
        let sampleBuffer = makeSampleBuffer(from: displayBuffer)
        guard let sampleBuffer else { return }

        // Sync timebase periodically for transport controls (progress bar,
        // play/pause indicator) but decouple it from frame enqueue timing.
        if hasActivePictureInPictureSession {
            DispatchQueue.main.async { [weak self] in self?.syncPlaybackTimebase() }
        }

        let resolvedRenderSize: CGSize
        if latestRenderSize.width > 1, latestRenderSize.height > 1 {
            resolvedRenderSize = latestRenderSize
        } else {
            resolvedRenderSize = CGSize(
                width: CVPixelBufferGetWidth(latestPixelBuffer),
                height: CVPixelBufferGetHeight(latestPixelBuffer)
            )
        }

        bufferDisplayLayer.enqueue(sampleBuffer)

        updateRenderBounds(for: resolvedRenderSize)
        invalidatePlaybackStateIfNeeded()
        attemptPendingPictureInPictureStartIfReady()
    }

    /// Create a sample buffer marked for immediate display, bypassing
    /// timebase-driven scheduling. Uses a cached format description to
    /// avoid per-frame allocation overhead.
    @available(iOS 15.0, *)
    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Reuse format description when dimensions haven't changed.
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

        // Mark for immediate display — the layer shows each frame as soon
        // as it arrives instead of trying to match PTS with the timebase.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true
        ) as? [NSMutableDictionary], let dict = attachments.first {
            dict[kCMSampleAttachmentKey_DisplayImmediately] = true
        }

        return sampleBuffer
    }

    // MARK: - Playback State

    @available(iOS 15.0, *)
    func invalidatePlaybackStateIfNeeded(force: Bool = false) {
        guard let pictureInPictureController,
              let playbackService,
              hasActivePictureInPictureSession else { return }

        let currentTime = max(playbackService.state.currentTime, 0)
        let duration = max(playbackService.state.duration, 0)
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

    @available(iOS 15.0, *)
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
        guard resolvedSize.width > 1, resolvedSize.height > 1 else { return }
        let bounds = CGRect(origin: .zero, size: resolvedSize)
        if hostView.frame != bounds {
            hostView.frame = bounds
            bufferDisplayLayer.frame = bounds
        }
    }

    // MARK: - Lifecycle

    private func invalidate(drawableRestoreMode: DrawableRestoreMode = .skip) {
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
    }

    /// Fully tear down a previous PiP session's resources so the next
    /// `start()` begins with a clean slate.  Most importantly this
    /// recreates the `AVSampleBufferDisplayLayer` — reusing a layer that
    /// has been flushed/removed across independent PiP controllers causes
    /// persistent `-12080` (`FigVideoQueueRemote`) errors on the second
    /// session, which manifest as a black PiP window.
    private func tearDownPreviousSessionIfNeeded() {
        invalidateFrameOutputForPlaybackChange()
        usesMPVFrameOutput = false

        pipPossibleObservation?.invalidate()
        pipPossibleObservation = nil
        playbackTimebase = nil
        cachedFormatDescription = nil
        cachedFormatDescriptionDimensions = (0, 0)

        // Tear down old PiP controller — it holds a reference to the old
        // display layer that we're about to replace.
        pictureInPictureController?.delegate = nil
        pictureInPictureController = nil

        // Destroy the old layer completely to avoid stale internal state.
        bufferDisplayLayer.controlTimebase = nil
        bufferDisplayLayer.flushAndRemoveImage()
        bufferDisplayLayer.removeFromSuperlayer()

        // Create a brand-new layer for the upcoming session.
        bufferDisplayLayer = AVSampleBufferDisplayLayer()

        latestPixelBuffer = nil
        latestRenderSize = .zero
        hasLoggedFirstFrame = false
    }

    @available(iOS 15.0, *)
    private func schedulePictureInPictureStartTimeout() {
        pendingStartTimeoutWorkItem?.cancel()
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.isPendingFirstStart || self.isPictureInPictureStartInFlight else { return }
            guard self.pictureInPictureController?.isPictureInPictureActive != true else {
                self.clearPictureInPictureStartAttempt()
                return
            }
            print("[PiP] start attempt timed out pending=\(self.isPendingFirstStart) inFlight=\(self.isPictureInPictureStartInFlight)")
            self.invalidate(drawableRestoreMode: .immediateRebuild)
            self.onStartFailed?()
        }
        pendingStartTimeoutWorkItem = timeoutItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: timeoutItem)
    }

    @available(iOS 15.0, *)
    private func requestPictureInPictureStartIfNeeded(using controller: AVPictureInPictureController? = nil) {
        let resolvedController = controller ?? pictureInPictureController
        guard let resolvedController,
              !resolvedController.isPictureInPictureActive,
              !isPictureInPictureStartInFlight else {
            return
        }
        isPendingFirstStart = false
        isPictureInPictureStartInFlight = true
        DispatchQueue.main.async { [weak self, weak resolvedController] in
            guard let self, let resolvedController,
                  self.pictureInPictureController === resolvedController,
                  self.isPictureInPictureStartInFlight,
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
}

// MARK: - AVPictureInPictureControllerDelegate

@available(iOS 15.0, *)
extension VLCPlayerPictureInPictureController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard self.pictureInPictureController === pictureInPictureController else { return }
        hasActivePictureInPictureSession = true
        clearPictureInPictureStartAttempt()
        configurePlaybackTimebaseIfNeeded()
        updateLinearPlaybackRequirement(for: pictureInPictureController)
        retainPlayerViewForPictureInPictureRestoreIfNeeded()
        renderCurrentFrame()
        invalidatePlaybackStateIfNeeded(force: true)
        print("[PiP] didStart")
        onDidStart?()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        guard self.pictureInPictureController === pictureInPictureController else { return }
        hasActivePictureInPictureSession = false
        print("[PiP] didStop")
        let drawableRestoreMode: DrawableRestoreMode =
            playbackService?.hasPendingPictureInPictureRestoreRequest() == true
            ? (usesMPVFrameOutput ? .immediateRebuild : .deferredUntilPlayerViewAttach)
            : .skip
        invalidate(drawableRestoreMode: drawableRestoreMode)
        onDidStop?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        guard self.pictureInPictureController === pictureInPictureController else { return }
        hasActivePictureInPictureSession = false
        print("[PiP] failedToStart error=\(error.localizedDescription)")
        invalidate(drawableRestoreMode: .immediateRebuild)
        onStartFailed?()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        guard self.pictureInPictureController === pictureInPictureController else { completionHandler(false); return }
        let didRequestRestore = playbackService?.requestVideoPlayerRestoreFromPictureInPicture(
            completion: completionHandler
        ) ?? false
        if !didRequestRestore {
            completionHandler(false)
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

@available(iOS 15.0, *)
extension VLCPlayerPictureInPictureController: AVPictureInPictureSampleBufferPlaybackDelegate {
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        guard self.pictureInPictureController === pictureInPictureController,
              hasActivePictureInPictureSession, let playbackService else { return }

        let now = Date().timeIntervalSinceReferenceDate
        if !playing,
           now < ignorePauseRequestsUntil,
           !pictureInPicturePlaybackIsPaused(using: playbackService) {
            print("[PiP] ignoring transient pause request after seek")
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
        let attempt = playbackService.playbackAttemptID
        playbackService.togglePlayPause()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            guard let self, self.pictureInPictureController === pictureInPictureController,
                  playbackService.playbackAttemptID == attempt else { return }
            self.invalidatePlaybackStateIfNeeded(force: true)
            self.renderCurrentFrame()
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        guard hasActivePictureInPictureSession,
              let playbackService else {
            return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }

        let currentTime = max(playbackService.state.currentTime, 0)
        let duration = max(playbackService.state.duration, currentTime + 1)
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
        guard self.pictureInPictureController === pictureInPictureController,
              hasActivePictureInPictureSession, let playbackService,
              playbackService.state.duration > 0.5 else {
            completionHandler()
            return
        }

        let seconds = skipInterval.seconds
        guard seconds.isFinite, abs(seconds) > 0.01 else {
            completionHandler()
            return
        }

        let configuredStep = max(AppSettings.shared.doubleTapSeekDuration, 1)
        let resolvedSeekDelta = seconds < 0 ? -configuredStep : configuredStep
        if !pictureInPicturePlaybackIsPaused(using: playbackService) {
            let graceDeadline = Date().timeIntervalSinceReferenceDate + 1.0
            suppressPausedStateUntil = graceDeadline
            ignorePauseRequestsUntil = graceDeadline
            playbackService.pictureInPictureSeekResumeGraceDeadline = graceDeadline
        }
        print("[PiP] skip requested interval=\(seconds) configured=\(configuredStep) resolved=\(resolvedSeekDelta)")
        let attempt = playbackService.playbackAttemptID
        playbackService.seek(by: resolvedSeekDelta)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, self.pictureInPictureController === pictureInPictureController,
                  playbackService.playbackAttemptID == attempt else { completionHandler(); return }
            if !playbackService.isUsingMPV, playbackService.state.currentItem != nil,
               Date().timeIntervalSinceReferenceDate < playbackService.pictureInPictureSeekResumeGraceDeadline,
               !(playbackService.mediaPlayer?.isPlaying ?? false) {
                print("[PiP] forcing resume after skip-induced pause")
                playbackService.togglePlayPause()
            }
            self.invalidatePlaybackStateIfNeeded(force: true)
            self.renderCurrentFrame()
            completionHandler()
        }
    }
}

// CVPixelBuffer → CMSampleBuffer conversion is now handled by\n// VLCPlayerPictureInPictureController.makeSampleBuffer(from:).
