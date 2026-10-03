#if os(macOS)
import Foundation
import GenPlayerCore

struct MacVODSearchEntry: Identifiable {
    struct ID: Hashable { let sourceID: UUID; let itemID: String }
    let sourceID: UUID
    let item: VODItem
    var id: ID { ID(sourceID: sourceID, itemID: item.id) }
}

struct MacVODSearchGroup: Identifiable {
    enum ID: Hashable {
        case titleYear(String, String)
        case original(MacVODSearchEntry.ID)
    }
    let id: ID
    var entries: [MacVODSearchEntry]
    var sourceCount: Int { Set(entries.map(\.sourceID)).count }

    // Preserve source order and exact season/version names; never infer unknown years.
    static func interleaved(_ entries: [MacVODSearchEntry]) -> [MacVODSearchEntry] {
        var order: [UUID] = []
        var buckets: [UUID: [MacVODSearchEntry]] = [:]
        for entry in entries {
            if buckets[entry.sourceID] == nil { order.append(entry.sourceID) }
            buckets[entry.sourceID, default: []].append(entry)
        }
        var output: [MacVODSearchEntry] = []
        for index in 0..<(buckets.values.map(\.count).max() ?? 0) {
            for source in order {
                if let bucket = buckets[source], index < bucket.count { output.append(bucket[index]) }
            }
        }
        return output
    }

    static func ranked(_ groups: [Self], keyword: String) -> [Self] {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func score(_ group: Self) -> Int {
            let name = group.entries.first?.item.vodName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            return name == query ? 0 : name.hasPrefix(query) ? 1 : 2
        }
        return groups.enumerated().sorted {
            let left = score($0.element), right = score($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }

    static func aggregate(_ entries: [MacVODSearchEntry]) -> [Self] {
        var groups: [Self] = []
        var indices: [ID: Int] = [:]
        var seen = Set<MacVODSearchEntry.ID>()
        for entry in entries where seen.insert(entry.id).inserted {
            let name = entry.item.vodName.trimmingCharacters(in: .whitespacesAndNewlines)
            let year = (entry.item.vodYear ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let key: ID
            if !name.isEmpty, year.count == 4, let number = Int(year), (1000...2999).contains(number) {
                key = .titleYear(name, year)
            } else {
                key = .original(entry.id)
            }
            if let index = indices[key] {
                groups[index].entries.append(entry)
            } else {
                indices[key] = groups.count
                groups.append(Self(id: key, entries: [entry]))
            }
        }
        return groups
    }
}
#endif

#if os(macOS)
enum MacVODContentKind: String, CaseIterable, Identifiable {
    case movie = "Movies", series = "TV Shows", animation = "Anime", variety = "Variety Shows", commentary = "Film Commentary"
    var id: String { rawValue }
    static var homeKinds: [Self] { [.movie, .series, .animation, .variety] }
    static func classify(_ name: String) -> Self? {
        let value = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("解说") || value.contains("解說") { return .commentary }
        if value.contains("动漫") || value.contains("動漫") || value.contains("动画") || value.contains("動畫") || value == "anime" || value == "animation" { return .animation }
        if value.contains("综艺") || value.contains("綜藝") || value == "variety" { return .variety }
        if !value.hasSuffix("片") && (value.contains("剧") || value.contains("劇")) || value == "tv shows" || value == "series" { return .series }
        if value.contains("电影") || value.contains("電影") || value == "movie" || value == "movies" || ["动作片", "動作片", "喜剧片", "喜劇片", "爱情片", "愛情片", "科幻片", "恐怖片", "剧情片", "劇情片", "战争片", "戰爭片", "纪录片", "紀錄片"].contains(value) { return .movie }
        return nil
    }
}
#endif
