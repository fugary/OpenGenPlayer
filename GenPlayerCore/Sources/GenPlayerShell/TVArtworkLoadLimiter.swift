#if os(tvOS)
import Foundation

enum TVArtworkLoadKind: Hashable {
    case mediaLibraryImage
    case fileServicePreview
    case genericArtwork
    case playbackMetadata

    var maximumConcurrentLoads: Int {
        switch self {
        case .mediaLibraryImage:
            return 4
        case .genericArtwork:
            return 2
        case .fileServicePreview, .playbackMetadata:
            return 1
        }
    }
}

final class TVArtworkLoadPermit: @unchecked Sendable {
    private let kind: TVArtworkLoadKind
    private let lock = NSLock()
    private var hasReleased = false

    fileprivate init(kind: TVArtworkLoadKind) {
        self.kind = kind
    }

    func release() {
        lock.lock()
        guard !hasReleased else {
            lock.unlock()
            return
        }
        hasReleased = true
        lock.unlock()

        Task {
            await TVArtworkLoadLimiter.shared.release(kind)
        }
    }

    deinit {
        release()
    }
}

actor TVArtworkLoadLimiter {
    static let shared = TVArtworkLoadLimiter()

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var activeCounts: [TVArtworkLoadKind: Int] = [:]
    private var waiters: [TVArtworkLoadKind: [Waiter]] = [:]

    func acquire(_ kind: TVArtworkLoadKind) async -> TVArtworkLoadPermit? {
        guard !Task.isCancelled else { return nil }

        if canStartLoad(for: kind) {
            activeCounts[kind, default: 0] += 1
            return TVArtworkLoadPermit(kind: kind)
        }

        let waiterID = UUID()
        let didAcquire = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                waiters[kind, default: []].append(Waiter(id: waiterID, continuation: continuation))
            }
        }, onCancel: {
            Task {
                await TVArtworkLoadLimiter.shared.cancelWaiter(waiterID, kind: kind)
            }
        })

        guard didAcquire else { return nil }

        if Task.isCancelled {
            release(kind)
            return nil
        }

        return TVArtworkLoadPermit(kind: kind)
    }

    fileprivate func release(_ kind: TVArtworkLoadKind) {
        activeCounts[kind] = max((activeCounts[kind] ?? 0) - 1, 0)
        resumeNextWaiterIfPossible(for: kind)
    }

    private func cancelWaiter(_ waiterID: UUID, kind: TVArtworkLoadKind) {
        guard var kindWaiters = waiters[kind],
              let index = kindWaiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }

        let waiter = kindWaiters.remove(at: index)
        waiters[kind] = kindWaiters
        waiter.continuation.resume(returning: false)
    }

    private func canStartLoad(for kind: TVArtworkLoadKind) -> Bool {
        (activeCounts[kind] ?? 0) < kind.maximumConcurrentLoads
    }

    private func resumeNextWaiterIfPossible(for kind: TVArtworkLoadKind) {
        guard canStartLoad(for: kind),
              var kindWaiters = waiters[kind],
              !kindWaiters.isEmpty else {
            return
        }

        let waiter = kindWaiters.removeFirst()
        waiters[kind] = kindWaiters
        activeCounts[kind, default: 0] += 1
        waiter.continuation.resume(returning: true)
    }
}
#endif
