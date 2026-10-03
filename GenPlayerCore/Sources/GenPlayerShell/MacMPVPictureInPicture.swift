#if os(macOS)
import AppKit
import SwiftUI
import GenPlayerPiPBridge

/// Moves the existing Metal surface into the same native PiP bridge used by VLC.
/// No new decoder, CPU frame copy, or playback reload is involved.
final class MacMPVPictureInPicture: NSObject, GenPlayerMacPIPBridgeDelegate {
    private weak var service: MacVLCPlaybackService?
    private let bridge = GenPlayerMacPIPBridge()
    private var overlay: NSView?
    private weak var originalWindow: NSWindow?
    private var active = false
    private var restoring = false
    var onClose: ((Bool) -> Void)?

    init(service: MacVLCPlaybackService) { self.service = service; super.init() }

    func start() -> Bool {
        if active { return true }
        guard GenPlayerMacPIPBridge.isPIPSupported(), let service,
              let view = service.mpvEngine?.videoView, view.window != nil else { return false }
        originalWindow = view.window
        let subtitles = NSHostingView(rootView: MacMPVPiPSubtitles(service: service))
        subtitles.frame = view.bounds
        subtitles.autoresizingMask = [.width, .height]
        view.addSubview(subtitles)
        overlay = subtitles
        bridge.delegate = self
        let size = service.videoNaturalSize
        active = bridge.startPIP(withVideoView: view,
            aspectRatio: size.width > 1 && size.height > 1 ? size : CGSize(width: 16, height: 9),
            isPlaying: service.isPlaying, title: service.currentFile?.name)
        if !active { subtitles.removeFromSuperview(); overlay = nil; bridge.delegate = nil }
        if active {
            if originalWindow?.styleMask.contains(.fullScreen) == true {
                originalWindow?.toggleFullScreen(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    guard let self, self.active, !self.restoring else { return }
                    self.originalWindow?.orderOut(nil)
                }
            } else { originalWindow?.orderOut(nil) }
        }
        return active
    }

    func update() {
        guard active, let service else { return }
        bridge.updatePlaybackProgress(Double(service.currentTime) / 1000,
            duration: Double(service.duration) / 1000, isPlaying: service.isPlaying)
    }

    func stop(restoringWindow: Bool = false) {
        onClose = nil
        bridge.delegate = nil
        active = false
        if restoringWindow { pipBridgeRequestRestore() }
        bridge.stopPIP()
        overlay?.removeFromSuperview(); overlay = nil
    }

    func pipBridgeDidClose() {
        active = false
        overlay?.removeFromSuperview(); overlay = nil
        onClose?(restoring)
    }
    func pipBridgeRequestRestore() {
        restoring = true
        originalWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func pipBridgeRequestPlay() { if service?.isPlaying == false { service?.togglePlayPause() } }
    func pipBridgeRequestPause() { if service?.isPlaying == true { service?.togglePlayPause() } }
    func pipBridgeRequestStop() { pipBridgeRequestPause() }
    func pipBridgeRequestSeek(byInterval interval: TimeInterval) {
        guard interval.isFinite else { return }
        service?.seek(by: Int32(min(Double(Int32.max), max(Double(Int32.min), interval * 1000))))
    }
}

private struct MacMPVPiPSubtitles: View {
    @ObservedObject var service: MacVLCPlaybackService
    @AppStorage("secondarySubtitleVerticalPositionRatio.landscape") private var position = -1.0
    @AppStorage("secondarySubtitleSizeScale") private var scale = 1.0
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if !service.generatedPrimaryText.isEmpty {
                    VStack { Spacer(); Text(service.generatedPrimaryText).padding(.bottom, 16) }
                        .font(.system(size: max(12, geometry.size.height * 0.045), weight: .medium))
                }
                if service.usesMPVTextSecondary {
                    Text(service.currentSecondarySubtitleParts.compactMap { $0.text?.string }.joined(separator: "\n"))
                        .font(.system(size: MacVLCPlaybackService.secondarySubtitleBaseFontSize(forContainerHeight: geometry.size.height) * scale, weight: .medium))
                        .frame(width: max(1, geometry.size.width - 32))
                        .position(x: geometry.size.width / 2,
                            y: MacVLCPlaybackService.secondarySubtitleCenterY(containerHeight: geometry.size.height, positionRatio: position))
                }
            }
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .shadow(color: .black, radius: 1, x: 1, y: 1)
            .shadow(color: .black, radius: 1, x: -1, y: -1)
        }
        .allowsHitTesting(false)
    }
}
#endif
