import Foundation

/// A value snapshot of native playback, independent of UI and server reporting state.
public struct PlaybackTransportState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, loading, playing, paused, ended, failed
    }

    public let phase: Phase
    public let position: Double
    public let duration: Double
    public let seekable: Bool
    public let audioTrackID: Int
    public let subtitleTrackID: Int

    public init(phase: Phase, position: Double, duration: Double, seekable: Bool,
                audioTrackID: Int, subtitleTrackID: Int) {
        self.phase = phase
        self.position = position.isFinite ? max(0, position) : 0
        self.duration = duration.isFinite ? max(0, duration) : 0
        self.seekable = seekable
        self.audioTrackID = audioTrackID
        self.subtitleTrackID = subtitleTrackID
    }
}

/// A terminated engine cannot become playable again through a late native event.
final class PlaybackTransportObservation {
    private let lock = NSLock()
    private var terminal = false
    private var value = PlaybackTransportState(phase: .idle, position: 0, duration: 0,
                                               seekable: false, audioTrackID: -1, subtitleTrackID: -1)
    var snapshot: PlaybackTransportState {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func update(_ state: PlaybackTransportState) {
        lock.lock(); defer { lock.unlock() }
        guard !terminal else { return }
        value = state
    }
    func fail() { finish(.failed) }
    func stop() { finish(.idle) }
    private func finish(_ phase: PlaybackTransportState.Phase) {
        lock.lock(); defer { lock.unlock() }
        terminal = true
        value = .init(phase: phase, position: value.position, duration: value.duration,
                      seekable: false, audioTrackID: value.audioTrackID, subtitleTrackID: value.subtitleTrackID)
    }
}
