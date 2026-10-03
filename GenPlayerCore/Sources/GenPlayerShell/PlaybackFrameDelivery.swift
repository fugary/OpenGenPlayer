import Foundation

/// Backpressure for continuous output: retain only the newest undelivered frame.
/// A cancelled channel is terminal; each playback attempt creates a fresh one.
final class PlaybackFrameDelivery<Frame> {
    private let lock = NSLock()
    private let queue: DispatchQueue
    private var receiver: ((Frame) -> Void)?
    private var pending: Frame?
    private var scheduled = false

    init(queue: DispatchQueue, receiver: @escaping (Frame) -> Void) {
        self.queue = queue
        self.receiver = receiver
    }

    func submit(_ frame: Frame) {
        lock.lock()
        guard receiver != nil else { lock.unlock(); return }
        pending = frame
        let enqueue = !scheduled
        scheduled = true
        lock.unlock()
        if enqueue { queue.async { [weak self] in self?.deliver() } }
    }

    func cancel() {
        lock.lock()
        receiver = nil
        pending = nil
        lock.unlock()
    }

    private func deliver() {
        lock.lock()
        let frame = pending
        let receive = receiver
        pending = nil
        scheduled = false
        lock.unlock()
        // A callback already in flight may finish. The destination must also
        // check its session identity before using a frame or updating UI.
        if let frame { receive?(frame) }
    }
}
