#if os(macOS) || os(iOS)
import Foundation

/// Only text actually decoded from the selected track. This is never a full transcript.
public struct MacMPVDecodedSubtitles {
    public struct Cue: Equatable {
        public let id: Int
        public let start: Double
        public let end: Double
        public let text: String
    }
    public private(set) var key = ""
    public private(set) var cues: [Cue] = []
    public private(set) var revision = 0
    private var nextID = 0
    private var textBytes = 0
    private let maximumTextBytes: Int

    public init(maximumTextBytes: Int = .max) { self.maximumTextBytes = max(0, maximumTextBytes) }

    public func activeCues(at time: Double) -> [Cue] {
        cues.filter { $0.start <= time && time < $0.end }
    }

    public mutating func select(_ key: String) {
        guard self.key != key else { return }
        self.key = key
        cues.removeAll()
        nextID = 0
        textBytes = 0
        revision &+= 1
    }

    public mutating func append(text: String, start: Double?, end: Double?) {
        // sub-start/sub-end are source timestamps, before the user's sub-delay.
        guard let start, let end, start.isFinite, end.isFinite, end > start,
              end - start < 3600, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= min(65536, maximumTextBytes) else { return }
        guard !cues.contains(where: { $0.start == start && $0.end == end && $0.text == text }) else { return }
        cues.append(Cue(id: nextID, start: start, end: end, text: text))
        textBytes += text.utf8.count
        nextID += 1
        while cues.count > 2000 || textBytes > maximumTextBytes {
            textBytes -= cues.removeFirst().text.utf8.count
        }
        cues.sort { ($0.start, $0.id) < ($1.start, $1.id) }
        revision &+= 1
    }
}
#endif
