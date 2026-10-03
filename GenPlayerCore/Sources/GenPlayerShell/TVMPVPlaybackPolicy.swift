import Foundation

/// tvOS routes audio and video independently of the presentation UI.
public enum TVMPVPlaybackPolicy {
    /// Keep secondary subtitles in the lower picture, above the primary region,
    /// including independently authored ASS and same-track mirrors.
    public static func secondarySubtitlePosition(customPosition: Double?) -> Double {
        customPosition ?? 0.84
    }

    public static func supportsText(_ codec: String) -> Bool {
        ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "tx3g", "text", "microdvd", "subviewer", "sami"].contains(codec.lowercased())
    }

    public static func supports(url: URL, isVideo: Bool, isAudio: Bool = false) -> Bool {
        PlaybackEngineCapabilities(platform: .tvOS, engine: .mpv)
            .routingRestriction(url: url, isVideo: isVideo, isAudio: isAudio) == nil
    }
}
