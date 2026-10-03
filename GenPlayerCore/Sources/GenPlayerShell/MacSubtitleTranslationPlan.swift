#if os(macOS) || os(iOS)
import Foundation
import CryptoKit

enum MacSubtitleTranslationPreference {
    static func key(provider: String?, serverID: String?, itemID: String?, url: URL) -> String {
        let identity: String
        if let provider, let serverID, let itemID, !itemID.isEmpty {
            identity = "server|\(provider)|\(serverID.lowercased())|\(itemID)"
        } else {
            identity = url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
        }
        let digest = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return "macSubtitleTranslation.enabled.\(digest)"
    }

    static func isEnabled(key: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func save(_ enabled: Bool, key: String, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

/// Value-only scheduling, independent of VLC and Apple's translation session.
struct MacSubtitleTranslationCue: Equatable, Sendable {
    let index: Int
    let start: Double
    let end: Double
    let text: String
}

struct MacSubtitleTranslationUnit: Equatable, Sendable {
    let members: [MacSubtitleTranslationCue]
    var index: Int { members[0].index }
    var text: String {
        if members.count == 1 { return members[0].text }
        return members.map { $0.text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.joined(separator: " ")
    }
}

enum MacSubtitleTranslationPlan {
    /// Conservative continuation matching; never infer a speaker change from timing alone.
    static func units(cues: [MacSubtitleTranslationCue]) -> [MacSubtitleTranslationUnit] {
        var result: [MacSubtitleTranslationUnit] = []
        for cue in cues {
            if let previous = result.last, let last = previous.members.last,
               previous.members.count < 3,
               cue.start >= last.end, cue.start - last.end <= 0.35,
               cue.end - previous.members[0].start <= 8,
               previous.text.count + cue.text.count + 1 <= 180,
               continuesSentence(last.text, cue.text) {
                result[result.count - 1] = MacSubtitleTranslationUnit(members: previous.members + [cue])
            } else {
                result.append(MacSubtitleTranslationUnit(members: [cue]))
            }
        }
        return result
    }

    private static func continuesSentence(_ before: String, _ after: String) -> Bool {
        func hasTurnOrCaptionMarker(_ text: String) -> Bool {
            if text.contains(where: { "♪♫#[]【】():：".contains($0) }) { return true }
            return text.components(separatedBy: .newlines).contains {
                guard let first = $0.trimmingCharacters(in: .whitespaces).first else { return false }
                return "-–—>".contains(first)
            }
        }
        guard !hasTurnOrCaptionMarker(before), !hasTurnOrCaptionMarker(after) else { return false }
        let left = before.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = after.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = left.last, let first = right.first,
              !".!?。！？…\"”’」』".contains(last) else { return false }
        return first.isLowercase || ",，、".contains(last)
    }

    static func batch(units: [MacSubtitleTranslationUnit], at time: Double,
                      translated: Set<Int>) -> [MacSubtitleTranslationUnit] {
        var result: [MacSubtitleTranslationUnit] = []
        var characters = 0
        for unit in units where unit.members.contains(where: { $0.end > time && $0.start <= time + 90 }) {
            guard !translated.contains(unit.index), !unit.text.isEmpty else { continue }
            if !result.isEmpty && (result.count >= 12 || characters + unit.text.count > 3000) { break }
            result.append(unit)
            characters += unit.text.count
        }
        return result
    }

    @available(macOS 13.0, iOS 16.0, *)
    static func isSameWrittenLanguage(source: String, target: String) -> Bool {
        let sourceLanguage = Locale.Language(identifier: source)
        let targetLanguage = Locale.Language(identifier: target)
        guard let code = sourceLanguage.languageCode, code == targetLanguage.languageCode else { return false }
        return sourceLanguage.script == targetLanguage.script
    }

    static func cacheKey(text: String, source: String, target: String) -> String {
        // Length-delimited fields avoid collisions between language/text boundaries.
        let fields = ["apple-subtitle-joined-v2", source, target, text]
        let payload = fields.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

actor MacSubtitleTranslationCache {
    static let shared = MacSubtitleTranslationCache()
    private struct Entry: Codable { let text: String; let date: Date }
    private var entries: [String: Entry] = [:]
    private var loaded = false
    private let fileURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("GenPlayer/SubtitleTranslation-v1.json")

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let fileURL,
              let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size < 12_000_000,
              let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = saved
    }

    func values(for keys: [String]) -> [String: String] {
        loadIfNeeded()
        return keys.reduce(into: [:]) { result, key in result[key] = entries[key]?.text }
    }

    func store(_ values: [String: String]) {
        loadIfNeeded()
        for (key, text) in values where text.count <= 2000 {
            entries[key] = Entry(text: text, date: Date())
        }
        if entries.count > 2000 {
            entries = Dictionary(uniqueKeysWithValues: entries.sorted { $0.value.date > $1.value.date }.prefix(2000).map { ($0.key, $0.value) })
        }
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
#endif
