import Foundation

/// Runtime-only continuity for reopening the same media. Native track IDs are not portable.
/// Source URLs remain in memory; this snapshot is never serialized.
public struct PlaybackSessionSnapshot: Equatable, Sendable {
    public let position: Double
    public let duration: Double
    public let paused: Bool
    public let rate: Float
    public let selections: PlaybackSelectionSnapshot

    public init(position: Double, duration: Double, paused: Bool, rate: Float,
                selections: PlaybackSelectionSnapshot = .init()) {
        self.selections = selections
        self.duration = duration.isFinite ? max(0, duration) : 0
        // Do not clamp to an old duration: some remote sources update it after loading.
        self.position = position.isFinite ? max(0, position) : 0
        self.paused = paused
        self.rate = rate.isFinite && rate > 0 ? rate : 1
    }

    public func replaying() -> Self {
        .init(position: 0, duration: duration, paused: false, rate: rate, selections: selections)
    }
}

/// Same-media handoff shared by all platforms. No native numeric IDs survive a rebuild.
/// Nil means unresolved; explicit Off remains distinct from a missing track list.
public struct PlaybackSelectionSnapshot: Equatable, Sendable {
    public let audio: PlaybackTrackSelection?
    public let primary: PlaybackTrackSelection?
    public let primarySourceURL: URL?
    public let secondary: PlaybackSecondarySelection?

    public init(embedded: [String: PlaybackTrackSelection] = [:], primarySourceURL: URL? = nil,
                secondary: PlaybackSecondarySelection? = nil) {
        audio = embedded["audio"]; primary = embedded["sub"]
        self.primarySourceURL = primarySourceURL; self.secondary = secondary
    }

    public var embedded: [String: PlaybackTrackSelection] {
        var result: [String: PlaybackTrackSelection] = [:]
        result["audio"] = audio; result["sub"] = primary
        return result
    }
}
