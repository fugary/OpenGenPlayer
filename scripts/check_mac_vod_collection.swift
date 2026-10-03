import Foundation
import Combine

@MainActor final class VODService {
    static let shared = VODService()
    var fail: UUID?
    var forced: [Bool] = []
    var categories: [UUID: [VODCategory]] = [:]
    var requested: [(UUID, String?, Int)] = []
    func fetchCategories(server: ServerConfig, forceRefresh: Bool = false) async throws -> [VODCategory] {
        forced.append(forceRefresh)
        if server.id == fail { throw URLError(.timedOut) }
        return categories[server.id] ?? []
    }
    func fetchList(server: ServerConfig, typeId: String? = nil, page: Int = 1) async throws -> (items: [VODItem], totalPages: Int, totalCount: Int) {
        requested.append((server.id, typeId, page))
        return ([VODItem(vodId: String(page), vodName: "Film \(page)", typeName: "动作片", vodYear: "2026")], 2, 2)
    }
    func search(server: ServerConfig, keyword: String, page: Int = 1, typeId: String? = nil) async throws -> (items: [VODItem], totalPages: Int, totalCount: Int) {
        try await fetchList(server: server, typeId: typeId, page: page)
    }
}
@main struct CollectionChecks {
    @MainActor static func main() async {
        var count = 0
        func check(_ condition: Bool, _ text: String) { precondition(condition, text); count += 1 }
        var owner = ServerConfig(name: "Owner", address: "https://first.example", type: .vod)
        let second = VODSourceConfig(name: "Second", address: "https://second.example")
        owner.vodSources = owner.macVODSources + [second]
        let service = VODService.shared
        service.categories[owner.id] = [.init(typeId: "10", typeName: "电影"), .init(typeId: "11", typeName: "动作片", typePid: 10), .init(typeId: "12", typeName: "演员")]
        service.categories[second.id] = [.init(typeId: "80", typeName: "Movies")]
        let model = MacVODCollectionHomeModel()
        await model.reload(owner)
        check(model.groups(.movie).filter { $0.entries.first?.item.id == "1" }.count == 1, "Cross-source same work is one home card")
        check(model.groups(.movie).first?.sourceCount == 2, "Home card retains both source choices")
        check(service.requested.contains { $0.0 == second.id && $0.1 == "80" }, "Category IDs are scoped to their original source")
        check(!service.requested.contains { $0.1 == "12" }, "Unknown categories are not queried as movies")
        check(service.requested.filter { $0.0 == owner.id && $0.1 == "11" }.count == 1, "Mapped descendant is queried once through its ancestor")
        check(model.hasMore(.movie), "Home preview keeps independent cursors for full browsing")
        await model.more(.movie)
        check(model.groups(.movie).count == 2 && !model.hasMore(.movie), "Load more deduplicates and finishes every source stream")
        check(model.facets(.movie).map(\.name) == ["动作片"], "Subcategories are discovered beneath the mapped root")
        let original = model.groups(.movie).count
        service.requested = []
        await model.selectFilter("动作片", kind: .movie)
        check(!service.requested.isEmpty && service.requested.allSatisfy { $0.0 == owner.id && $0.1 == "11" }, "Missing facet excludes source; never requests all-site or another source ID")
        check(model.filters[.movie] == "动作片", "Filter remains local selection")
        await model.selectFilter(nil, kind: .movie)
        check(model.groups(.movie).count == original && !model.hasMore(.movie), "All restores loaded entries and pagination")
        service.fail = second.id
        await model.reload(owner)
        check(model.groups(.movie).first?.sourceCount == 1 && !model.errors.isEmpty, "Failed source does not discard successful home content")
        check(!model.busy, "Partial failure clears loading state")
        check(service.forced.allSatisfy { !$0 }, "Ordinary loading allows category cache")
        service.forced = []
        await model.reload(owner, forceRefresh: true)
        check(service.forced.count == 2 && service.forced.allSatisfy { $0 }, "Explicit refresh bypasses category cache for every source")
        print("PASS: \(count) aggregate home assertions; no GUI or network")
    }
}
