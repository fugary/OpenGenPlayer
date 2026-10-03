import Foundation

// Minimal command spies stand in for the native libraries, not for the adapters.
public final class VLCTime {
    public let intValue: Int32
    public init(int: Int32) { intValue = int }
}
public final class VLCAudio { public var volume: Int32 = 100; public var isMuted = false }
public final class VLCMedia { public var length = VLCTime(int: 90_000) }
public final class VLCMediaPlayer {
    public static var creations = 0
    public init(options: [String]? = nil) { Self.creations += 1 }
    public enum State { case stopped, opening, buffering, playing, paused, ended, error }
    public var state = State.stopped
    public var isPlaying = false
    public var isSeekable = true
    public var time = VLCTime(int: 0)
    public var media: VLCMedia? = VLCMedia()
    public var audio: VLCAudio? = VLCAudio()
    public var rate: Float = 1
    public var currentAudioTrackIndex: Int32 = 2
    public var currentVideoSubTitleIndex: Int32 = 3
    public func play() { state = .playing; isPlaying = true }
    public func pause() { state = .paused; isPlaying = false }
}
public final class MPVPlaybackEngine {
    public var commands: [String] = []
    public var seekTargets: [Double] = []
    public var transportState = PlaybackTransportState(phase: .paused, position: 4.5, duration: 90,
        seekable: true, audioTrackID: 8, subtitleTrackID: -1)
    public func set(_ key: String, _ value: String) { commands.append("\(key)=\(value)") }
    public func seek(seconds: Double) { seekTargets.append(seconds) }
}

@main enum TransportChecks {
    static func main() {
        var count = 0
        func check(_ value: Bool, line: Int = #line) {
            precondition(value, "Transport check failed at line \(line)"); count += 1
        }
        let empty = VLCPlaybackTransport(player: nil)
        empty.resume(); empty.pause(); empty.seek(to: 1); empty.setRate(2)
        empty.setVolume(50); empty.setMuted(true); empty.selectAudioTrack(1)
        check(empty.state.phase == .idle && !empty.state.seekable && empty.state.position == 0)
        if !PlaybackEngineAvailability.current.vlc {
            check(VLCPlaybackTransport.makePlayer() == nil)
            check(VLCPlaybackTransport.makePlayer(options: ["--no-osd"]) == nil)
            check(VLCMediaPlayer.creations == 0)
            print("Passed disabled VLC creation and empty transport checks")
            return
        }
        let player = VLCMediaPlayer()
        let vlc: any PlaybackTransport = VLCPlaybackTransport(player: player)
        check(vlc.engineID == .vlc)
        vlc.resume(); check(player.isPlaying && vlc.state.phase == .playing)
        vlc.pause(); check(!player.isPlaying && vlc.state.phase == .paused)
        vlc.seek(to: 1.25); check(player.time.intValue == 1250 && vlc.state.position == 1.25)
        vlc.seek(to: .nan); vlc.seek(to: .infinity); check(player.time.intValue == 1250)
        vlc.seek(to: -2); check(player.time.intValue == 0)
        vlc.seek(to: Double.greatestFiniteMagnitude); check(player.time.intValue == Int32.max)
        vlc.setRate(1.5); vlc.setRate(.nan); vlc.setRate(0); vlc.setRate(-1); check(player.rate == 1.5)
        vlc.setVolume(65); check(player.audio?.volume == 65)
        vlc.setMuted(true); check(player.audio?.isMuted == true)
        vlc.setMuted(false); check(player.audio?.isMuted == false)
        vlc.selectAudioTrack(9); check(player.currentAudioTrackIndex == 9)
        vlc.selectAudioTrack(Int.max); check(player.currentAudioTrackIndex == 9)
        vlc.selectAudioTrack(-1); check(player.currentAudioTrackIndex == -1)
        check(vlc.state.duration == 90 && vlc.state.subtitleTrackID == 3)
        for (native, expected) in [(VLCMediaPlayer.State.opening, PlaybackTransportState.Phase.loading),
                                  (.buffering, .loading), (.ended, .ended), (.error, .failed), (.stopped, .idle)] {
            player.state = native; check(vlc.state.phase == expected)
        }
        player.audio = nil; vlc.setVolume(10); vlc.setMuted(true)
        player.media = nil; check(vlc.state.duration == 0)
        let engine = MPVPlaybackEngine()
        let mpv: any PlaybackTransport = MPVPlaybackTransport(engine: engine)
        check(mpv.engineID == .mpv && mpv.state == engine.transportState)
        mpv.resume(); mpv.pause(); check(engine.commands == ["pause=no", "pause=yes"])
        mpv.setMuted(true); mpv.setMuted(false); check(engine.commands.suffix(2) == ["mute=yes", "mute=no"])
        mpv.setRate(1.5); mpv.setRate(.infinity); mpv.setRate(.nan); mpv.setRate(-1)
        check(engine.commands.last == "speed=1.5" && engine.commands.count == 5)
        mpv.seek(to: 1.25); mpv.seek(to: -2); mpv.seek(to: .nan); mpv.seek(to: .infinity)
        check(engine.seekTargets == [1.25, 0])
        mpv.selectAudioTrack(-1); mpv.selectAudioTrack(8); check(engine.commands.suffix(2) == ["aid=no", "aid=8"])
        mpv.setVolume(65); check(engine.commands.last == "volume=65")
        check(player.audio == nil && player.currentAudioTrackIndex == -1) // MPV commands never touch VLC.
        print("Passed \(count) production transport adapter checks with native spies (no player or media opened)")
    }
}
