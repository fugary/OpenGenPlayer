#if os(macOS)
import Foundation

/// Explicit VLC frame-bridge requests and virtual GPUs retain their existing route.
enum MacMPVPlaybackPolicy {
    static func supports(url: URL, isVideo: Bool, isLive: Bool,
                         requiresVLCBridge: Bool, isVirtualMachine: Bool) -> Bool {
        PlaybackEngineCapabilities(platform: .macOS, engine: .mpv)
            .routingRestriction(url: url, isVideo: isVideo, isAudio: !isVideo,
                                requiresVLCBridge: requiresVLCBridge,
                                isVirtualMachine: isVirtualMachine) == nil
    }

    static func isLiveProtocol(_ url: URL) -> Bool {
        ["rtsp", "rtsps", "rtp", "udp"].contains(url.scheme?.lowercased() ?? "")
    }

    static func milliseconds(_ seconds: Double) -> Int32 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int32(min(seconds * 1000, Double(Int32.max)))
    }
}
#endif
