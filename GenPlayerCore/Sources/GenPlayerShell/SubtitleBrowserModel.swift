#if os(iOS) || os(macOS)
import Foundation
import Combine
import GenPlayerCore

public struct SubtitleBrowserSource: Identifiable {
    public let id: String
    public let title: String
    public let revision: String
    /// Media time = cue time + offset. Supplied by the platform's display path.
    public let offset: Double
    public let load: @MainActor () async throws -> SubtitleBrowserDocument

    public init(id: String, title: String, revision: String = "", offset: Double,
                load: @escaping @MainActor () async throws -> SubtitleBrowserDocument) {
        self.id = id
        self.title = title
        self.revision = revision
        self.offset = offset.isFinite ? offset : 0
        self.load = load
    }

    var requestKey: String { "\(id)|\(revision)" }
}

public enum SubtitleBrowserError: Error {
    case bitmap, unreadable, remoteLimit
}

public struct SubtitleBrowserTrackSelection: Identifiable {
    public struct Option: Identifiable {
        public let id: String
        public let title: String
        public let isEnabled: Bool
        public init(id: String, title: String, isEnabled: Bool = true) {
            self.id = id; self.title = title; self.isEnabled = isEnabled
        }
    }
    public let id: String
    public let title: String
    public let selectedTrackID: String
    public let options: [Option]
    public let source: SubtitleBrowserSource?
    public let select: (String) -> Void

    public init(id: String, title: String, selectedTrackID: String, options: [Option],
                source: SubtitleBrowserSource?, select: @escaping (String) -> Void) {
        self.id = id; self.title = title; self.selectedTrackID = selectedTrackID
        self.options = options; self.source = source; self.select = select
    }
}

public struct SubtitleBrowserEntry: Identifiable, Equatable {
    public let id: String
    public let start: Double
    public let end: Double
    public let text: String

    func contains(_ query: String) -> Bool {
        query.isEmpty || text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

public struct SubtitleBrowserDocument {
    public let entries: [SubtitleBrowserEntry]
    public let isPartial: Bool
    public let partialStatusKey: String
    private let maximumEnds: [Double]

    public init(parts: [SubtitlePart], isPartial: Bool = false, partialStatusKey: String = "SB.Partial") {
        self.isPartial = isPartial
        self.partialStatusKey = partialStatusKey
        var occurrences: [String: Int] = [:]
        entries = parts.enumerated().filter {
            $0.element.start.isFinite && $0.element.end.isFinite && $0.element.end > $0.element.start
        }.sorted {
            if $0.element.start == $1.element.start { return $0.offset < $1.offset }
            return $0.element.start < $1.element.start
        }.compactMap { _, part in
            guard part.start.isFinite, part.end.isFinite, part.end > part.start else { return nil }
            let text = SubtitleModel.cleanSubtitleText(part.text?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let key = "\(part.start.bitPattern):\(part.end.bitPattern)"
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            // Appending earlier generated chunks or updating translations must not renumber rows.
            return SubtitleBrowserEntry(id: "\(key):\(occurrence)", start: part.start, end: part.end, text: text)
        }
        var maximum = -Double.infinity
        maximumEnds = entries.map { maximum = max(maximum, $0.end); return maximum }
    }

    public func matching(_ query: String) -> [SubtitleBrowserEntry] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? entries : entries.filter { $0.contains(query) }
    }

    /// Half-open intervals match the player; the prefix maximum also handles overlapping cues.
    public func activeIDs(at mediaTime: Double, offset: Double) -> Set<String> {
        let time = mediaTime - offset
        guard time.isFinite else { return [] }
        var index = upperBound(time) - 1
        var result = Set<String>()
        while index >= 0, maximumEnds[index] > time {
            let entry = entries[index]
            if entry.end > time { result.insert(entry.id) }
            index -= 1
        }
        return result
    }

    public func anchorID(at mediaTime: Double, offset: Double) -> String? {
        guard !entries.isEmpty, mediaTime.isFinite, offset.isFinite else { return nil }
        let active = activeIDs(at: mediaTime, offset: offset)
        let index = max(0, upperBound(mediaTime - offset) - 1)
        if !active.isEmpty {
            var candidate = index
            while candidate >= 0 {
                if active.contains(entries[candidate].id) { return entries[candidate].id }
                candidate -= 1
            }
        }
        return entries[index].id
    }

    public static func seekTime(for entry: SubtitleBrowserEntry, offset: Double) -> Double {
        max(0, entry.start + (offset.isFinite ? offset : 0))
    }

    private func upperBound(_ time: Double) -> Int {
        var low = 0
        var high = entries.count
        while low < high {
            let middle = (low + high) / 2
            if entries[middle].start <= time { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

/// Owned by the visible browser, never by the subtitle rendering or generation pipeline.
final class SubtitleBrowserModel: ObservableObject {
    @Published private(set) var document = SubtitleBrowserDocument(parts: [])
    @Published private(set) var matches: [SubtitleBrowserEntry] = []
    @Published private(set) var statusKey: String? = "SB.SelectSubtitle"
    @Published private(set) var isLoading = false
    @Published private(set) var canRetry = false
    @Published private(set) var updateID = UUID()
    @Published private(set) var loadedKey: String?
    @Published var query = "" { didSet { matches = document.matching(query) } }
    private var requestID = UUID()
    private var sourceID: String?

    @MainActor func load(_ source: SubtitleBrowserSource?) async {
        let request = UUID()
        requestID = request
        if sourceID != source?.id {
            document = SubtitleBrowserDocument(parts: [])
            matches = []
            query = ""
        }
        sourceID = source?.id
        canRetry = false
        guard let source else {
            isLoading = false
            statusKey = "SB.SelectSubtitle"
            return
        }
        isLoading = document.entries.isEmpty
        statusKey = nil
        do {
            let document = try await source.load()
            guard !Task.isCancelled, requestID == request else { return }
            self.document = document
            loadedKey = source.requestKey
            matches = document.matching(query)
            isLoading = false
            statusKey = document.entries.isEmpty ? "SB.Empty" : nil
            updateID = UUID()
        } catch {
            guard !Task.isCancelled, requestID == request else { return }
            document = SubtitleBrowserDocument(parts: [])
            matches = []
            isLoading = false
            switch error {
            case SubtitleBrowserError.bitmap: statusKey = "SB.Bitmap"
            case SubtitleBrowserError.unreadable: statusKey = "SB.Unreadable"
            case SubtitleBrowserError.remoteLimit: statusKey = "SB.RemoteLimit"
            default: statusKey = "SB.ReadFailed"; canRetry = true
            }
        }
    }

    func invalidate() { requestID = UUID() }
}
#endif
