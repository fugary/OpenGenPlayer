import Foundation

public struct MPVPlaybackTransport: PlaybackTransport {
    private let engine: MPVPlaybackEngine
    public init(engine: MPVPlaybackEngine) { self.engine = engine }
    public var engineID: PlaybackEngineID { .mpv }
    public var state: PlaybackTransportState { engine.transportState }
    public func resume() { engine.set("pause", "no") }
    public func pause() { engine.set("pause", "yes") }
    public func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        engine.seek(seconds: max(0, seconds))
    }
    public func setRate(_ rate: Float) {
        guard rate.isFinite, rate > 0 else { return }
        engine.set("speed", String(rate))
    }
    public func setVolume(_ volume: Int32) { engine.set("volume", String(volume)) }
    public func setMuted(_ muted: Bool) { engine.set("mute", muted ? "yes" : "no") }
    public func selectAudioTrack(_ id: Int) { engine.set("aid", id < 0 ? "no" : String(id)) }
}
