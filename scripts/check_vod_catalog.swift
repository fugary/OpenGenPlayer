import Foundation

public struct VideoFile {
    public var jellyfinServerId: String?
    public var seriesId: String?
}
@MainActor public final class VODService {
    nonisolated static let shared = VODService()
    nonisolated init() {}
    struct Page { let items: [VODItem]; let totalPages: Int }
    struct Request {
        let query: String
        let page: Int
        let completion: CheckedContinuation<Page, Error>
    }
    var pending: [Request] = []
    func fetchCategories(server: ServerConfig, forceRefresh: Bool) async throws -> [VODCategory] {
        [VODCategory(typeId: "1", typeName: "电影"), VODCategory(typeId: "2", typeName: "动作片", typePid: 1)]
    }
    func fetchList(server: ServerConfig, typeId: String?, page: Int) async throws -> Page {
        try await search(server: server, keyword: typeId ?? "ALL", page: page, typeId: nil)
    }
    func search(server: ServerConfig, keyword: String, page: Int, typeId: String?) async throws -> Page {
        try await withCheckedThrowingContinuation { pending.append(Request(query: keyword, page: page, completion: $0)) }
    }
    nonisolated func makeVideoFile(for episode: VODEpisode, item: VODItem, server: ServerConfig, source: VODPlaySource) -> VideoFile { VideoFile() }
    func take(_ query: String, _ page: Int = 1) async -> Request {
        for _ in 0..<1000 {
            if let index = pending.firstIndex(where: { $0.query == query && $0.page == page }) { return pending.remove(at: index) }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Missing request \(query) \(page)")
    }
}
public struct MediaServerSummary { public let libraryCount: Int }
public final class MediaServerSummaryService {
    public static let shared = MediaServerSummaryService()
    public var loadingServers = Set<UUID>()
    var summaries: [UUID: MediaServerSummary] = [:]
    public func summary(for id: UUID) -> MediaServerSummary? { summaries[id] }
    public func refreshSummary(for server: ServerConfig) async {}
}
@main struct Checks {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ result: Bool, _ message: String) { precondition(result, message); checks += 1 }
        func item(_ id: String, year: String = "2025") -> VODItem {
            VODItem(vodId: id, vodName: id, vodYear: year)
        }
        func settle() async { try? await Task.sleep(nanoseconds: 30_000_000) }
        let source = ServerConfig(name: "A", address: "https://a.invalid", type: .vod)
        let other = ServerConfig(name: "B", address: "https://b.invalid", type: .vod)
        let service = VODService.shared, catalog = VODCatalog()
        catalog.reload(owner: source, query: "old")
        let old = await service.take("old")
        catalog.reload(owner: source, query: "new")
        let new = await service.take("new")
        new.completion.resume(returning: .init(items: [item("new")], totalPages: 3)); await settle()
        old.completion.resume(returning: .init(items: [item("old")], totalPages: 1)); await settle()
        check(catalog.groups.map(\.item.id) == ["new"], "Stale query cannot overwrite current query")
        catalog.next()
        let canceled = await service.take("new", 2)
        catalog.cancel()
        check(!catalog.loading && catalog.hasMore, "Cancel clears spinner and keeps completed page")
        catalog.next()
        let retried = await service.take("new", 2)
        canceled.completion.resume(throwing: URLError(.timedOut)); await settle()
        check(catalog.loading && catalog.errors.isEmpty, "Old failure cannot end retry")
        retried.completion.resume(returning: .init(items: [item("page2")], totalPages: 2)); await settle()
        check(catalog.groups.count == 2 && !catalog.hasMore, "Return from detail resumes correct page")
        check(catalog.categories.map(\.name) == ["电影", "动作片"], "Single source preserves category names and order")
        check(catalog.categories.first { $0.id == "1" }?.isRoot == true, "Home shows top-level categories")
        check(catalog.categories.first { $0.id == "2" }?.parentKeys.contains("1") == true, "Child filters remain scoped to parent")
        let entries = [VODCatalogEntry(source: source, item: item("same")), VODCatalogEntry(source: other, item: item("same"))]
        check(VODCatalogGroup.merge(entries).first?.sourceCount == 2, "Matching works group sources")
        check(VODCatalogGroup.merge(entries + entries).first?.entries.count == 2, "Repeated pages deduplicate")
        check(VODCatalogGroup.merge([entries[0], .init(source: other, item: item("same", year: "1978"))]).count == 2, "Remakes stay separate")
        check(source.vodRecordID(ownerID: other.id, itemID: "1") != other.vodRecordID(ownerID: other.id, itemID: "1"), "Source IDs remain distinct")
        check(VODEpisode.displayName("第001集", format: "Episode %d") == "Episode 1", "Episode localization")
        check(VODEpisode.displayName("E221.2026", format: "Episode %d") == "E221.2026", "Named episodes preserved")
        var owner = source
        owner.vodSources = (0..<4).map { VODSourceConfig(name: "Source \($0)", address: "https://s\($0).invalid") }
        catalog.reload(owner: owner, query: "multi")
        for _ in 0..<3 { (await service.take("multi")).completion.resume(returning: .init(items: [], totalPages: 1)) }
        let fourth = await service.take("multi")
        fourth.completion.resume(returning: .init(items: [item("found")], totalPages: 1)); await settle()
        check(catalog.groups.first?.item.id == "found", "Empty first batch continues to remaining sources")
        owner.vodSources = Array(owner.vodSources!.prefix(2))
        catalog.reload(owner: owner, query: "partial")
        let failed = await service.take("partial"), successful = await service.take("partial")
        failed.completion.resume(throwing: URLError(.timedOut))
        successful.completion.resume(returning: .init(items: [item("available")], totalPages: 1)); await settle()
        check(catalog.errors.count == 1 && catalog.groups.first?.item.id == "available", "One source failure preserves other results")
        check(catalog.categories.first { $0.id == "Movies" }?.types.count == 2, "Multiple sources merge normalized categories")
        check(catalog.categories.first { $0.id == "动作片" }?.parentKeys.contains("Movies") == true, "Merged child filters retain normalized parent")
        catalog.reload(owner: source, category: "1")
        let parent = await service.take("1"), child = await service.take("2")
        parent.completion.resume(returning: .init(items: [item("parent")], totalPages: 1))
        child.completion.resume(returning: .init(items: [item("child")], totalPages: 1)); await settle()
        check(Set(catalog.groups.map(\.item.id)) == Set(["parent", "child"]), "Parent category includes direct and child items")
        catalog.reload(owner: owner, category: "1")
        for _ in 0..<2 {
            (await service.take("1")).completion.resume(returning: .init(items: [item("merged")], totalPages: 1))
        }
        (await service.take("2")).completion.resume(returning: .init(items: [], totalPages: 1)); await settle()
        check(catalog.resolvedCategoryID == "Movies", "Single to multi source remaps active category")
        catalog.reload(owner: source, category: "Movies")
        (await service.take("1")).completion.resume(returning: .init(items: [item("single")], totalPages: 1))
        (await service.take("2")).completion.resume(returning: .init(items: [], totalPages: 1)); await settle()
        check(catalog.resolvedCategoryID == "1", "Multi to single source remaps active category")
        let summaries = MediaServerSummaryService.shared
        var singleOwner = owner
        singleOwner.vodSources = [owner.vodSources![0]]
        let singleKey = singleOwner.mobileVODSummaryEndpoints[0].id
        summaries.summaries[singleKey] = MediaServerSummary(libraryCount: 10)
        summaries.summaries[owner.mobileVODSummaryEndpoints[1].id] = MediaServerSummary(libraryCount: 20)
        check(owner.mobileMediaSummary?.libraryCount == 20, "Multi source summary uses maximum")
        check(singleOwner.mobileMediaSummary?.libraryCount == 10, "Removing source excludes its summary")
        singleOwner.vodSources![0].address = "https://replacement.invalid"
        check(singleOwner.mobileVODSummaryEndpoints[0].id != singleKey && singleOwner.mobileMediaSummary == nil, "Single source URL change cannot reuse stale summary")
        print("VOD catalog: \(checks) checks passed")
    }
}
