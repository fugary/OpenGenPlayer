import Foundation
import Combine

public extension ServerConfig {
    var vodEndpoints: [ServerConfig] {
        (vodSources ?? [VODSourceConfig(id: id, name: name, address: fullURL)])
            .filter(\.isEnabled).map { ServerConfig(id: $0.id, name: $0.name, address: $0.address, type: .vod) }
    }
    func vodRecordID(ownerID: UUID, itemID: String) -> String {
        id == ownerID ? itemID : "vod:" + id.uuidString + ":" + itemID
    }
}

public struct VODCatalogEntry: Identifiable {
    public let source: ServerConfig
    public let item: VODItem
    public var id: String { source.id.uuidString + ":" + item.id }
    public init(source: ServerConfig, item: VODItem) { self.source = source; self.item = item }
    public func file(for episode: VODEpisode, line: VODPlaySource, ownerID: UUID) -> VideoFile {
        var file = VODService.shared.makeVideoFile(for: episode, item: item, server: source, source: line)
        file.jellyfinServerId = ownerID.uuidString
        file.seriesId = source.vodRecordID(ownerID: ownerID, itemID: item.id)
        return file
    }
}

public struct VODCatalogGroup: Identifiable {
    public let id: String
    public var entries: [VODCatalogEntry]
    public var item: VODItem { entries[0].item }
    public var sourceCount: Int { Set(entries.map { $0.source.id }).count }
    public static func merge(_ entries: [VODCatalogEntry], query: String = "") -> [Self] {
        var groups: [Self] = [], indexes: [String: Int] = [:], seen = Set<String>()
        for entry in entries where seen.insert(entry.id).inserted {
            let title = entry.item.vodName.trimmingCharacters(in: .whitespacesAndNewlines)
            let year = entry.item.vodYear ?? ""
            let key = !title.isEmpty && year.count == 4 && (Int(year).map { (1000...2999).contains($0) } ?? false)
                ? "title:\(title)|\(year)|\(VODCatalog.categoryKey(entry.item.typeName ?? ""))" : entry.id
            if let index = indexes[key] { groups[index].entries.append(entry) }
            else { indexes[key] = groups.count; groups.append(Self(id: key, entries: [entry])) }
        }
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return groups }
        func score(_ group: Self) -> Int {
            let title = group.item.vodName.lowercased()
            return title == keyword ? 0 : title.hasPrefix(keyword) ? 1 : 2
        }
        return groups.enumerated().sorted {
            score($0.element) == score($1.element) ? $0.offset < $1.offset : score($0.element) < score($1.element)
        }.map(\.element)
    }
}

/// Shared data only. Touch and television views own navigation and presentation.
@MainActor public final class VODCatalog: ObservableObject {
    public struct Category: Identifiable {
        public let id: String
        public let name: String
        public var isRoot: Bool
        public var parentKeys: Set<String>
        var types: [UUID: [String]]
    }
    private struct Cursor {
        let source: ServerConfig
        let typeID: String?
        var page = 1
        var finished = false
    }
    @Published public private(set) var revision = UUID()
    @Published public private(set) var groups: [VODCatalogGroup] = []
    @Published public private(set) var categories: [Category] = []
    @Published public private(set) var loading = false
    @Published public private(set) var errors: [String] = []
    @Published public private(set) var hasMore = false
    private var cursors: [Cursor] = []
    private var entries: [VODCatalogEntry] = []
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var taxonomySources: [String] = []
    private var query = ""
    private var offset = 0
    public init() {}
    public func seedCategories(from catalog: VODCatalog) {
        categories = catalog.categories
        taxonomySources = catalog.taxonomySources
    }

    nonisolated public static func categoryKey(_ value: String) -> String {
        let name = (value.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? value)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "电影", "电影片", "movies", "movie": return "Movies"
        case "电视剧", "连续剧", "tv shows", "series": return "TV Shows"
        case "动漫", "动漫片", "anime", "animation": return "Anime"
        case "综艺", "综艺片", "variety": return "Variety Shows"
        default: return name
        }
    }

    public func cancel() { task?.cancel(); generation = UUID(); loading = false }
    public private(set) var resolvedCategoryID: String?
    public func reload(owner: ServerConfig, category: String? = nil, query: String = "", force: Bool = false) {
        let previousCategory = categories.first { $0.id == category }
        let previousParents = categories.filter { previousCategory?.parentKeys.contains($0.id) == true }
        cancel(); self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        entries = []; groups = []; errors = []; cursors = []; offset = 0; hasMore = false; loading = true
        let request = generation
        task = Task {
            let identities = owner.vodEndpoints.map { $0.id.uuidString + "|" + $0.fullURL }
            if categories.isEmpty || force || taxonomySources != identities {
                var taxonomy: [Category] = []
                let sources = owner.vodEndpoints
                let refreshTaxonomy = force || taxonomySources != identities
                for start in stride(from: 0, to: sources.count, by: 3) {
                    let batch = Array(sources[start..<min(start + 3, sources.count)])
                    let responses = await withTaskGroup(of: (Int, Result<[VODCategory], Error>).self) { group in
                        for (index, source) in batch.enumerated() {
                            group.addTask {
                                do { return (index, .success(try await VODCatalogRequestGate.shared.categories(source, force: refreshTaxonomy))) }
                                catch { return (index, .failure(error)) }
                            }
                        }
                        var responses: [(Int, Result<[VODCategory], Error>)] = []
                        for await response in group { responses.append(response) }
                        return responses.sorted { $0.0 < $1.0 }
                    }
                    guard !Task.isCancelled, generation == request else { return }
                    for (index, response) in responses {
                        let source = batch[index]
                        switch response {
                        case .success(let list):
                            for cat in list {
                                let key = sources.count == 1 ? cat.id : Self.categoryKey(cat.typeName)
                                let parent = list.first { $0.id == cat.typePid.map { String($0.value) } }
                                let root = parent == nil || parent?.id == cat.id
                                let parents: Set<String> = parent.map { [sources.count == 1 ? $0.id : Self.categoryKey($0.typeName)] } ?? []
                                var ids = [cat.id], pending = [cat.id], seen = Set(ids)
                                while let parent = pending.popLast() {
                                    for child in list where child.typePid.map({ String($0.value) }) == parent && seen.insert(child.id).inserted {
                                        ids.append(child.id); pending.append(child.id)
                                    }
                                }
                                if let index = taxonomy.firstIndex(where: { $0.id == key }) {
                                    taxonomy[index].isRoot = taxonomy[index].isRoot || root
                                    taxonomy[index].parentKeys.formUnion(parents)
                                    taxonomy[index].types[source.id] = Array(Set((taxonomy[index].types[source.id] ?? []) + ids)).sorted()
                                } else {
                                    taxonomy.append(Category(id: key, name: sources.count > 1 && ["Movies", "TV Shows", "Anime", "Variety Shows"].contains(key) ? key : cat.typeName, isRoot: root, parentKeys: parents, types: [source.id: ids]))
                                }
                            }
                        case .failure(let error): errors.append(source.name + ": " + error.localizedDescription)
                        }
                    }
                }
                categories = taxonomy
                taxonomySources = identities
            }
            guard !Task.isCancelled, generation == request else { return }
            let resolved = previousCategory.flatMap { old in
                categories.first { $0.id == old.id && Self.categoryKey($0.name) == Self.categoryKey(old.name) }?.id
                    ?? categories.first { Self.categoryKey($0.name) == Self.categoryKey(old.name) }?.id
                    ?? categories.first { candidate in previousParents.contains { Self.categoryKey($0.name) == Self.categoryKey(candidate.name) } }?.id
            } ?? category
            resolvedCategoryID = resolved
            for source in owner.vodEndpoints {
                if let category = resolved {
                    for type in categories.first(where: { $0.id == category })?.types[source.id] ?? [] {
                        cursors.append(Cursor(source: source, typeID: type))
                    }
                } else { cursors.append(Cursor(source: source, typeID: nil)) }
            }
            revision = UUID()
            await loadBatch(request: request)
        }
    }
    public func next() {
        guard !loading, hasMore else { return }
        loading = true
        let request = generation
        task = Task { await loadBatch(request: request) }
    }
    private func loadBatch(request: UUID) async {
        var indices: [Int] = []
        for step in 0..<cursors.count {
            let index = (offset + step) % cursors.count
            if !cursors[index].finished { indices.append(index) }
            if indices.count == 3 { break }
        }
        let snapshots = indices.map { ($0, cursors[$0]) }, keyword = query
        let results = await withTaskGroup(of: (Int, Result<([VODItem], Int), Error>).self) { group in
            for (index, cursor) in snapshots {
                group.addTask {
                    do {
                        let result = try await VODCatalogRequestGate.shared.page(cursor.source, type: cursor.typeID, page: cursor.page, keyword: keyword)
                        return (index, .success((result.0, result.1)))
                    } catch { return (index, .failure(error)) }
                }
            }
            var output: [(Int, Result<([VODItem], Int), Error>)] = []
            for await value in group { output.append(value) }
            return output.sorted { $0.0 < $1.0 }
        }
        guard !Task.isCancelled, generation == request else { return }
        for (index, result) in results {
            switch result {
            case .success(let page):
                entries += page.0.map { VODCatalogEntry(source: cursors[index].source, item: $0) }
                cursors[index].finished = page.0.isEmpty || cursors[index].page >= page.1
                cursors[index].page += 1
            case .failure(let error):
                errors.append(cursors[index].source.name + ": " + error.localizedDescription)
                cursors[index].finished = true
            }
        }
        if let last = indices.last { offset = (last + 1) % cursors.count }
        groups = VODCatalogGroup.merge(entries, query: query)
        hasMore = cursors.contains { !$0.finished }
        // Empty/failed early sources must not hide remaining sources behind an empty state.
        if groups.isEmpty && hasMore {
            await loadBatch(request: request)
        } else { loading = false }
    }
}

public extension VODEpisode {
    static func displayName(_ name: String, format: String = NSLocalizedString("Episode %d", comment: "")) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: "^第\\s*([0-9]+)\\s*集$"),
              let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed), let number = Int(trimmed[range]) else { return name }
        return String(format: format, number)
    }
}

private actor VODCatalogRequestGate {
    static let shared = VODCatalogRequestGate()
    private var active = 0
    private func acquire() async throws {
        while active >= 3 { try await Task.sleep(nanoseconds: 50_000_000) }
        try Task.checkCancellation()
        active += 1
    }
    func categories(_ source: ServerConfig, force: Bool) async throws -> [VODCategory] {
        try await acquire(); defer { active -= 1 }
        return try await VODService.shared.fetchCategories(server: source, forceRefresh: force)
    }
    func page(_ source: ServerConfig, type: String?, page: Int, keyword: String) async throws -> ([VODItem], Int) {
        try await acquire(); defer { active -= 1 }
        let result = keyword.isEmpty
            ? try await VODService.shared.fetchList(server: source, typeId: type, page: page)
            : try await VODService.shared.search(server: source, keyword: keyword, page: page, typeId: type)
        return (result.items, result.totalPages)
    }
}
