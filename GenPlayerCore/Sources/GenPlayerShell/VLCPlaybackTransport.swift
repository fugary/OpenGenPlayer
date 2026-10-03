import Foundation
import VLCKitSPM

public struct VLCPlaybackTransport: PlaybackTransport {
    private let player: VLCMediaPlayer?
    public init(player: VLCMediaPlayer?) {
        self.player = PlaybackEngineAvailability.current.vlc ? player : nil
    }
    public static func makePlayer(options: [String]? = nil) -> VLCMediaPlayer? {
        guard PlaybackEngineAvailability.current.vlc else { return nil }
        if let options { return VLCMediaPlayer(options: options) }
        return VLCMediaPlayer()
    }
    public var engineID: PlaybackEngineID { .vlc }
    public var state: PlaybackTransportState {
        let phase: PlaybackTransportState.Phase
        switch player?.state {
        case .opening, .buffering: phase = .loading
        case .playing: phase = .playing
        case .paused: phase = .paused
        case .ended: phase = .ended
        case .error: phase = .failed
        default: phase = player?.isPlaying == true ? .playing : .idle
        }
        return .init(phase: phase, position: Double(player?.time.intValue ?? 0) / 1000,
                     duration: Double(player?.media?.length.intValue ?? 0) / 1000,
                     seekable: player?.isSeekable ?? false, audioTrackID: Int(player?.currentAudioTrackIndex ?? -1),
                     subtitleTrackID: Int(player?.currentVideoSubTitleIndex ?? -1))
    }
    public func resume() { player?.play() }
    public func pause() { player?.pause() }
    public func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        player?.time = VLCTime(int: Int32(min(max(seconds * 1000, 0), Double(Int32.max))))
    }
    public func setRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        player?.rate = rate
    }
    public func setVolume(_ volume: Int32) { player?.audio?.volume = volume }
    public func setMuted(_ muted: Bool) { player?.audio?.isMuted = muted }
    public func selectAudioTrack(_ id: Int) {
        guard let nativeID = Int32(exactly: id) else { return }
        player?.currentAudioTrackIndex = nativeID
    }
}
