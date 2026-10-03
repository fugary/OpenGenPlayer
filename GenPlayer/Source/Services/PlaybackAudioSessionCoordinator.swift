import Foundation

/// Serializes audio-session transitions without blocking the UI. All backend
/// calls run on this queue, including PiP's synchronous preparation path.
final class PlaybackAudioSessionCoordinator {
    private let queue = DispatchQueue(label: "GenPlayer.playbackAudioSession", qos: .userInitiated)
    private let activateBackend: (Bool) throws -> Void
    private let deactivateBackend: () throws -> Void
    private var isKnownActive = false

    init(activate: @escaping (Bool) throws -> Void, deactivate: @escaping () throws -> Void) {
        activateBackend = activate
        deactivateBackend = deactivate
    }

    /// System interruptions deactivate the session outside this coordinator.
    func invalidateActivation() {
        queue.async { self.isKnownActive = false }
    }

    func activate(completion: @escaping (Bool) -> Void) {
        queue.async {
            let success = self.activateOnQueue()
            DispatchQueue.main.async { completion(success) }
        }
    }

    func deactivate(completion: @escaping (Bool) -> Void) {
        queue.async {
            // Even a failed deactivation must make the next activation explicit.
            self.isKnownActive = false
            let success: Bool
            do {
                try self.deactivateBackend()
                success = true
            } catch {
                success = false
            }
            DispatchQueue.main.async { completion(success) }
        }
    }

    func activateSynchronously() -> Bool {
        queue.sync { activateOnQueue() }
    }

    private func activateOnQueue() -> Bool {
        do {
            try activateBackend(isKnownActive)
            isKnownActive = true
            return true
        } catch {
            isKnownActive = false
            return false
        }
    }
}
