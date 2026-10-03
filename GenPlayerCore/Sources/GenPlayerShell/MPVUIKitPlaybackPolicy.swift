import Foundation

/// UIKit routing is independent of macOS; explicit legacy bridge requests remain VLC-only.
public enum MPVUIKitPlaybackPolicy {
    public static func supports(url: URL, isVideo: Bool, isAudio: Bool = false, requiresVLCBridge: Bool) -> Bool {
        // Simulator uses libmpv's software render API; eligible media stay on mpv.
        PlaybackEngineCapabilities(platform: .iOS, engine: .mpv)
            .routingRestriction(url: url, isVideo: isVideo, isAudio: isAudio,
                                requiresVLCBridge: requiresVLCBridge) == nil
    }
}
