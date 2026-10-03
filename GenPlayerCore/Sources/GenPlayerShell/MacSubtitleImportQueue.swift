#if os(macOS)
import Foundation

/// Only one VLC slave may be awaiting registration, so track-ID differences remain unambiguous.
struct MacSubtitleImportQueue {
    struct Request {
        let id: UUID
        let url: URL
        let primaryTrackID: Int?
    }
    struct Active {
        let request: Request
        let previousIDs: Set<Int>
    }
    private(set) var waiting: [Request] = []
    private(set) var active: Active?

    mutating func enqueue(_ request: Request) {
        waiting.append(request)
    }

    mutating func startNext(knownIDs: Set<Int>) -> Request? {
        guard active == nil, !waiting.isEmpty else { return nil }
        let request = waiting.removeFirst()
        active = Active(request: request, previousIDs: knownIDs)
        return request
    }

    mutating func resolve(knownIDs: Set<Int>) -> (request: Request, nativeID: Int)? {
        guard let active else { return nil }
        let added = knownIDs.subtracting(active.previousIDs).subtracting([-1])
        guard added.count == 1, let nativeID = added.first else { return nil }
        self.active = nil
        return (active.request, nativeID)
    }

    mutating func discardActive() { active = nil }
}
#endif
