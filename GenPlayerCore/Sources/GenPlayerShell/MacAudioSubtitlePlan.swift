#if os(macOS) || os(iOS)
import Foundation
import CryptoKit

struct MacAudioSubtitleCue: Codable, Equatable, Sendable {
    let id: Int
    let start: Double
    let end: Double
    let text: String
}

/// A completed chunk includes silence. Missing chunks, not missing cues, drive resumption.
struct MacAudioSubtitleCache: Codable, Sendable {
    var version = 1
    let key: String
    let duration: Double
    var chunks: [Int: [MacAudioSubtitleCue]] = [:]

    var cues: [MacAudioSubtitleCue] {
        chunks.keys.sorted().flatMap { chunks[$0] ?? [] }
    }
    var isComplete: Bool { chunks.count == MacAudioSubtitlePlan.count(duration: duration) }
    var completedDuration: Double {
        chunks.keys.reduce(0) { $0 + MacAudioSubtitlePlan.range(chunk: $1, duration: duration).count }
    }
    var isValid: Bool {
        guard version == 1, duration.isFinite, duration > 0, duration <= 7 * 86400 else { return false }
        let count = MacAudioSubtitlePlan.count(duration: duration)
        return chunks.allSatisfy { index, cues in
            guard (0..<count).contains(index), cues.count < 10000 else { return false }
            let range = MacAudioSubtitlePlan.range(chunk: index, duration: duration)
            return Set(cues.map(\.id)).count == cues.count && cues.allSatisfy {
                $0.id / 10000 == index && $0.start.isFinite && $0.end.isFinite &&
                $0.start >= range.lowerBound && $0.end <= range.upperBound && $0.end > $0.start &&
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.text.count <= 4000
            }
        }
    }
}

extension Range where Bound == Double {
    fileprivate var count: Double { upperBound - lowerBound }
}

enum MacAudioSubtitlePlan {
    static let chunkSeconds = 30.0
    static let contextSeconds = 2.0
    static let primaryID = -900002
    static let secondaryID = "mac.generated-audio"

    static func count(duration: Double) -> Int {
        guard duration.isFinite, duration > 0, duration <= 7 * 86400 else { return 0 }
        return Int(ceil(duration / chunkSeconds))
    }
    static func range(chunk: Int, duration: Double) -> Range<Double> {
        let start = Double(chunk) * chunkSeconds
        return start..<max(start, min(start + chunkSeconds, duration))
    }
    static func next(at time: Double, duration: Double, completed: Set<Int>) -> Int? {
        let total = count(duration: duration)
        guard total > 0 else { return nil }
        let current = min(total - 1, max(0, Int((time.isFinite ? time : 0) / chunkSeconds)))
        return (current..<total).first { !completed.contains($0) }
            ?? (0..<current).first { !completed.contains($0) }
    }
    static func digest(_ fields: [String]) -> String {
        let value = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func key(source: String, track: Int32, language: String, engine: String) -> String {
        digest(["audio-subtitle-v1-30s-2s", source, String(track), language, engine])
    }
    /// Each contextual recognition run owns words whose midpoint lies in its chunk.
    /// Clipping to that ownership interval prevents overlap between adjacent cached chunks.
    static func cues(words: [(start: Double, end: Double, text: String)], chunk: Int,
                     duration: Double) -> [MacAudioSubtitleCue] {
        let interval = range(chunk: chunk, duration: duration)
        var result: [MacAudioSubtitleCue] = []
        var pending: (start: Double, end: Double, text: String)?
        func flush() {
            if let line = pending, result.count < 9999 {
                result.append(.init(id: chunk * 10000 + result.count, start: line.start, end: line.end,
                                    text: line.text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            pending = nil
        }
        for word in words.sorted(by: { $0.start < $1.start }) {
            guard word.start.isFinite, word.end.isFinite, word.end > word.start,
                  interval.contains((word.start + word.end) / 2),
                  !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let start = max(interval.lowerBound, word.start)
            let end = min(interval.upperBound, word.end)
            if let line = pending,
               start - line.end > 0.7 || end - line.start > 5 || line.text.count + word.text.count > 80 {
                flush()
            }
            if let line = pending { pending = (line.start, max(line.end, end), line.text + word.text) }
            else { pending = (start, end, String(word.text.prefix(4000))) }
            if word.text.trimmingCharacters(in: .whitespacesAndNewlines).last.map({ ".!?。！？".contains($0) }) == true { flush() }
        }
        flush()
        return result
    }
    static func srt(_ cues: [MacAudioSubtitleCue]) -> String {
        func stamp(_ seconds: Double) -> String {
            let ms = Int((max(0, seconds) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return cues.sorted { $0.start < $1.start }.enumerated().map { index, cue in
            "\(index + 1)\n\(stamp(cue.start)) --> \(stamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }
}

actor MacAudioSubtitleStore {
    static let shared = MacAudioSubtitleStore()
    let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("GenPlayer/GeneratedSubtitles-v1", isDirectory: true)) { self.root = root }

    private func url(_ key: String) -> URL { root.appendingPathComponent(key).appendingPathExtension("json") }
    func load(key: String, duration: Double) -> MacAudioSubtitleCache {
        let file = url(key)
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32_000_000,
           let data = try? Data(contentsOf: file), let cached = try? JSONDecoder().decode(MacAudioSubtitleCache.self, from: data),
           cached.key == key, abs(cached.duration - duration) < 0.001, cached.isValid { return cached }
        return MacAudioSubtitleCache(key: key, duration: duration)
    }
    func save(_ cache: MacAudioSubtitleCache) throws {
        guard cache.isValid else { throw CocoaError(.coderInvalidValue) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(cache).write(to: url(cache.key), options: .atomic)
    }
    func remove(key: String) throws {
        if FileManager.default.fileExists(atPath: url(key).path) { try FileManager.default.removeItem(at: url(key)) }
    }
}

/// A lease stays held until cancellation has drained the decoder and analyzer.
actor MacAudioSubtitleLease {
    static let shared = MacAudioSubtitleLease()
    private var owner: UUID?
    func acquire(_ token: UUID) -> Bool {
        guard owner == nil else { return false }
        owner = token
        return true
    }
    func release(_ token: UUID) { if owner == token { owner = nil } }
}
#endif
