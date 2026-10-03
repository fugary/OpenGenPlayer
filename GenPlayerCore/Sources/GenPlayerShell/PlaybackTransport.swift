import Foundation

/// Native commands and state. Platform services continue to own audio activation, history,
/// failure presentation and cancellation before issuing a transport command.
public protocol PlaybackTransport {
    var engineID: PlaybackEngineID { get }
    var state: PlaybackTransportState { get }
    func resume()
    func pause()
    func seek(to seconds: Double)
    func setRate(_ rate: Float)
    func setVolume(_ volume: Int32)
    func setMuted(_ muted: Bool)
    func selectAudioTrack(_ id: Int)
}

/// Presets for mpv; each platform retains its existing VLC choices.
public enum MPVPlaybackSpeed {
    public static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5, 6, 8]

    public static func clamped(_ rate: Float, maximum: Float = 8) -> Float {
        guard rate.isFinite, rate > 0 else { return 1 }
        return min(rate, maximum)
    }
}
