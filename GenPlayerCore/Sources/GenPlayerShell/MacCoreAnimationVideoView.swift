#if os(macOS)
import SwiftUI
import AppKit
import AVFoundation
import CoreMedia
import VLCKitSPM
import GenPlayerCore
import GenPlayerVLCBridge

public final class MacSampleBufferHostView: NSView {
    public override var isFlipped: Bool { false }
    public let bufferDisplayLayer = AVSampleBufferDisplayLayer()
    
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayer()
    }
    
    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayer()
    }
    
    private func setupLayer() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        bufferDisplayLayer.videoGravity = .resizeAspect
        bufferDisplayLayer.backgroundColor = NSColor.black.cgColor
        bufferDisplayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(bufferDisplayLayer)
    }
    
    public override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bufferDisplayLayer.frame = bounds
        CATransaction.commit()
    }
}

public struct MacCoreAnimationVideoView: NSViewRepresentable {
    @ObservedObject var playbackService: MacVLCPlaybackService
    var fillScreen: Bool
    
    public init(playbackService: MacVLCPlaybackService, fillScreen: Bool = false) {
        self.playbackService = playbackService
        self.fillScreen = fillScreen
    }
    
    public func makeNSView(context: Context) -> MacSampleBufferHostView {
        let view = MacSampleBufferHostView()
        view.autoresizingMask = [.width, .height]
        view.bufferDisplayLayer.videoGravity = fillScreen ? .resizeAspectFill : .resizeAspect
        playbackService.attachCoreAnimationVideoView(view)
        return view
    }
    
    public func updateNSView(_ nsView: MacSampleBufferHostView, context: Context) {
        let targetGravity: AVLayerVideoGravity = fillScreen ? .resizeAspectFill : .resizeAspect
        if nsView.bufferDisplayLayer.videoGravity != targetGravity {
            nsView.bufferDisplayLayer.videoGravity = targetGravity
        }
    }
    
    public static func dismantleNSView(_ nsView: MacSampleBufferHostView, coordinator: Coordinator) {
        nsView.bufferDisplayLayer.flushAndRemoveImage()
    }
}

public final class MacVLCOpenGLHostView: VLCVideoView {
    var onReady: ((VLCVideoView) -> Void)?
    private var readyNotificationScheduled = false

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        notifyWhenReady()
    }

    public override func layout() {
        super.layout()
        notifyWhenReady()
    }

    private func notifyWhenReady() {
        guard !readyNotificationScheduled, window != nil, bounds.width > 0, bounds.height > 0 else { return }
        readyNotificationScheduled = true
        // Finish the SwiftUI/AppKit update before starting playback. Recheck the
        // window and session in the callback so teardown cannot start old media.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.readyNotificationScheduled = false
            guard self.window != nil, self.bounds.width > 0, self.bounds.height > 0 else { return }
            self.onReady?(self)
        }
    }
}

public struct MacVLCOpenGLVideoView: NSViewRepresentable {
    @ObservedObject var playbackService: MacVLCPlaybackService
    var fillScreen: Bool
    let sessionID: UUID
    
    public init(playbackService: MacVLCPlaybackService, fillScreen: Bool = false, sessionID: UUID) {
        self.playbackService = playbackService
        self.fillScreen = fillScreen
        self.sessionID = sessionID
    }
    
    public func makeNSView(context: Context) -> MacVLCOpenGLHostView {
        let videoView = MacVLCOpenGLHostView()
        videoView.autoresizingMask = [.width, .height]
        videoView.fillScreen = fillScreen
        videoView.onReady = { [weak playbackService, sessionID] view in
            playbackService?.videoViewDidBecomeReady(view, sessionID: sessionID)
        }
        playbackService.attachVideoView(videoView, sessionID: sessionID)
        return videoView
    }
    
    public func updateNSView(_ nsView: MacVLCOpenGLHostView, context: Context) {
        if nsView.fillScreen != fillScreen {
            nsView.fillScreen = fillScreen
        }
    }

    public static func dismantleNSView(_ nsView: MacVLCOpenGLHostView, coordinator: Coordinator) {
        nsView.onReady = nil
    }
}
#endif
