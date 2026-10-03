#if os(tvOS)
import AVFoundation
import MediaPlayer
import UIKit

/// Own only this mpv audio session's commands. Never remove other players' targets.
@MainActor
final class TVMPVAudioControls {
    private static let audioQueue = DispatchQueue(label: "GenPlayer.tvMPVAudioSession")
    private var active = true
    private var resumeRequest = UUID()
    private var targets: [(MPRemoteCommand, Any)] = []
    private var observers: [NSObjectProtocol] = []
    private var lastTime: Double = -.infinity
    private var lastRate: Float = -1
    private var lastTitle = ""
    private var lastArtwork: UIImage?

    func activate(completion: @escaping (Bool) -> Void) {
        Self.audioQueue.async { [weak self] in
            let ready: Bool
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .default)
                try session.setActive(true)
                ready = true
            } catch { ready = false }
            DispatchQueue.main.async { [weak self] in
                guard self?.active == true else { return }
                completion(ready)
            }
        }
    }

    func cancelPendingResume() { resumeRequest = UUID() }

    func resume(completion: @escaping (Bool) -> Void) {
        let request = UUID(); resumeRequest = request
        activate { [weak self] ready in
            guard self?.resumeRequest == request else { return }
            completion(ready)
        }
    }

    func install(play: @escaping () -> Void, pause: @escaping () -> Void,
                 next: @escaping () -> Void, previous: @escaping () -> Void,
                 seek: @escaping (Double) -> Void, stop: @escaping () -> Void) {
        let center = MPRemoteCommandCenter.shared()
        func add(_ command: MPRemoteCommand, action: @escaping () -> Void) {
            command.isEnabled = true
            let token = command.addTarget { [weak self] _ in
                Task { @MainActor in
                    guard self?.active == true else { return }
                    action()
                }
                return .success
            }
            targets.append((command, token))
        }
        add(center.playCommand, action: play)
        add(center.pauseCommand, action: pause)
        add(center.togglePlayPauseCommand) { [weak self] in
            guard let self else { return }
            if self.lastRate > 0 { pause() }
            else { play() }
        }
        add(center.nextTrackCommand, action: next)
        add(center.previousTrackCommand, action: previous)
        add(center.stopCommand, action: stop)
        let command = center.changePlaybackPositionCommand
        let token = command.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in
                guard self?.active == true else { return }
                seek(position)
            }
            return .success
        }
        targets.append((command, token))
        // Interruption/headphone disconnect pauses without unsolicited autoplay.
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue else { return }
                Task { @MainActor in guard self?.active == true else { return }; pause() }
            })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,
            object: nil, queue: .main) { [weak self] notification in
                guard (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                Task { @MainActor in guard self?.active == true else { return }; pause() }
            })
    }

    func update(title: String, artist: String?, album: String?, artwork: UIImage?, time: Double,
                duration: Double, rate: Float, canNext: Bool, canPrevious: Bool) {
        guard active else { return }
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = canNext
        center.previousTrackCommand.isEnabled = canPrevious
        center.changePlaybackPositionCommand.isEnabled = duration > 0
        guard abs(lastTime - time) >= 1 || lastRate != rate || lastTitle != title || lastArtwork !== artwork else { return }
        lastTime = time; lastRate = rate; lastTitle = title; lastArtwork = artwork
        var info: [String: Any] = [MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: time,
            MPNowPlayingInfoPropertyPlaybackRate: rate]
        if let artist { info[MPMediaItemPropertyArtist] = artist }
        if let album { info[MPMediaItemPropertyAlbumTitle] = album }
        if let artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = rate > 0 ? .playing : .paused
    }

    func stop(keepingAudioSession: Bool = false) {
        active = false
        if !keepingAudioSession {
            Self.audioQueue.async {
                try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
            }
        }
        cancelPendingResume()
        targets.forEach { $0.0.removeTarget($0.1) }; targets.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }; observers.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }
}
#endif
