import Foundation

// Dependencies for source-extracted loading methods. Suspended responses ignore
// cancellation deliberately, so a late server response exercises stale guards.
struct ServerConfig { let id = UUID() }
typealias Page = (items: [VODItem], totalPages: Int, totalCount: Int)

@MainActor final class VODService {
    static let shared = VODService()
    struct Request {
        let kind: String
        let query: String
        let page: Int
        let continuation: CheckedContinuation<Page, Error>
    }
    var pending: [Request] = []
    func fetchCategories(server: ServerConfig, forceRefresh: Bool = false) async throws -> [VODCategory] { [] }
    func fetchList(server: ServerConfig, typeId: String? = nil, page: Int = 1) async throws -> Page {
        try await enqueue(kind: "list", query: typeId ?? "ALL", page: page)
    }
    func search(server: ServerConfig, keyword: String, page: Int = 1, typeId: String? = nil) async throws -> Page {
        try await enqueue(kind: "search", query: typeId.map { keyword + "@" + $0 } ?? keyword, page: page)
    }
    func enqueue(kind: String, query: String, page: Int) async throws -> Page {
        try await withCheckedThrowingContinuation { pending.append(Request(kind: kind, query: query, page: page, continuation: $0)) }
    }
    func take(_ kind: String, _ query: String, _ page: Int) async -> Request {
        for _ in 0..<1000 {
            if let index = pending.firstIndex(where: { $0.kind == kind && $0.query == query && $0.page == page }) {
                return pending.remove(at: index)
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Missing request: \(kind) \(query) page \(page)")
    }
}
@MainActor final class MediaServerSummaryService {
    static let shared = MediaServerSummaryService()
    func updateSummary(for id: UUID, libraryCount: Int) {}
}

final class SearchProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.contains(URLQueryItem(name: "wd", value: "query")))
        precondition(query.contains(URLQueryItem(name: "pg", value: "2")))
        if let category = query.first(where: { $0.name == "t" }) {
            precondition(category.value == "6")
        }
        let body = #"{"code":1,"page":2,"pagecount":"3","total":"42","list":[{"vod_id":21,"vod_name":"result"}]}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class SearchAPI {
    let session: URLSession
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SearchProtocol.self]
        session = URLSession(configuration: config)
    }
    func endpointURL(for server: ServerConfig, queryItems: [URLQueryItem]) -> URL? {
        var components = URLComponents(string: "https://fixture.invalid/api.php/provide/vod")!
        components.queryItems = queryItems
        return components.url
    }
    func makeRequest(url: URL) -> URLRequest { URLRequest(url: url) }
    func validateResponse(_ response: VODResponse) throws -> VODResponse { response }
}

@main struct VODRegressionChecks {
    @MainActor static var checks = 0
    @MainActor static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    static func item(_ id: String) -> VODItem {
        try! JSONDecoder().decode(VODItem.self, from: Data("{\"vod_id\":\"\(id)\",\"vod_name\":\"\(id)\"}".utf8))
    }
    @MainActor static func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    @MainActor static func finish(_ request: VODService.Request, _ id: String) async {
        request.continuation.resume(returning: ([item(id)], 3, 42))
        await settle()
    }
    @MainActor static func main() async throws {
        let apiResult = try await SearchAPI().search(server: ServerConfig(), keyword: " query ", page: 2)
        check(apiResult.items.first?.id == "21", "Search list is preserved")
        check(apiResult.totalPages == 3 && apiResult.totalCount == 42, "Search metadata is preserved")
        _ = try await SearchAPI().search(server: ServerConfig(), keyword: "query", page: 2, typeId: "6")
        let empty = try await SearchAPI().search(server: ServerConfig(), keyword: " ")
        check(empty.items.isEmpty && empty.totalCount == 0 && empty.totalPages == 1, "Empty query does not make a request")

        let metadata = try JSONDecoder().decode(VODItem.self, from: Data(#"{"vod_id":1,"vod_name":"film","vod_lang":"English","vod_duration":"110 min","vod_douban_id":36225840}"#.utf8))
        check(metadata.vodDoubanID?.value == "36225840", "Numeric external metadata ID decodes")
        check(metadata.vodLanguage?.value == "English" && metadata.vodDuration?.value == "110 min", "Optional media metadata preserved")
        check(item("legacy").vodDoubanID == nil, "Older responses without metadata still decode")

        let selection = SourceSelection()
        selection.playSources = VODParser.parsePlaySources(from: "empty$$$A$$$B", urlString: "$$$ep$https://a.invalid/1.m3u8$$$ep$https://b.invalid/1.m3u8")
        check(selection.playSources.map(\.index) == [1, 2], "Source IDs survive filtered empty groups")
        check(selection.currentSource?.name == "A", "Default source uses first nonempty group")
        selection.selectedSourceIndex = selection.playSources[1].index
        check(selection.currentSource?.name == "B", "Selecting second visible source resolves B")

        let service = VODService.shared
        let mac = MacBrowser()
        mac.selectedCategoryId = "A"
        mac.loadInitialData(forceRefresh: false)
        let macA = await service.take("list", "A", 1)
        mac.selectedCategoryId = "B"
        mac.loadInitialData(forceRefresh: false)
        let macB = await service.take("list", "B", 1)
        await finish(macB, "B1")
        await finish(macA, "A1")
        check(mac.items.map(\.id) == ["B1"], "macOS late category response ignored")
        mac.loadNextPage()
        let macB2 = await service.take("list", "B", 2)
        mac.searchText = "query"
        mac.loadInitialData(forceRefresh: false)
        let macS1 = await service.take("search", "query@B", 1)
        await finish(macB2, "STALE")
        check(mac.items.isEmpty && mac.isLoading, "Late browse page cannot replace search")
        await finish(macS1, "S1")
        mac.loadNextPage()
        await finish(await service.take("search", "query@B", 2), "S2")
        check(mac.items.map(\.id) == ["S1", "S2"] && mac.currentPage == 2, "macOS search reaches page 2")
        mac.loadInitialData(forceRefresh: true)
        await finish(await service.take("search", "query@B", 1), "REFRESHED")
        check(mac.searchText == "query" && mac.items.map(\.id) == ["REFRESHED"] && mac.currentPage == 1, "macOS refresh preserves search query")
        mac.searchText = ""
        mac.loadInitialData(forceRefresh: false)
        await finish(await service.take("list", "B", 1), "B1")
        check(mac.items.first?.id == "B1", "Clearing search restores selected category")

        let multi = MultiSearch()
        multi.sources = [ServerConfig(), ServerConfig()]
        multi.keyword = "multi"
        multi.search()
        let first = await service.take("search", "multi", 1)
        let second = await service.take("search", "multi", 1)
        await finish(first, "shared-id")
        second.continuation.resume(throwing: URLError(.timedOut))
        await settle()
        check(multi.results.count == 1 && multi.errors.count == 1, "One failed source does not discard another source's results")
        check(!multi.busy, "Multi-source search completes after failures")
        let successfulID = multi.results.keys.first!
        let successfulSource = multi.sources.first { $0.id == successfulID }!
        multi.search(only: successfulSource, page: 2)
        await finish(await service.take("search", "multi", 2), "shared-id")
        check(multi.results[successfulID]?.count == 1 && multi.pages[successfulID] == 2, "Source paging deduplicates and advances independently")
        let failedID = multi.sources.first { $0.id != successfulID }!.id
        multi.totals[successfulID] = 3
        multi.totals[failedID] = 0
        multi.search(more: true)
        await finish(await service.take("search", "multi", 3), "next")
        check(multi.pages[successfulID] == 3 && multi.results[successfulID]?.count == 2, "Unified load more advances from each source's own page")
        check(multi.errors[failedID] != nil && service.pending.isEmpty, "Unified pagination retains failed-source retry and skips exhausted sources")
        multi.keyword = "old"
        multi.search()
        let oldA = await service.take("search", "old", 1)
        let oldB = await service.take("search", "old", 1)
        multi.cancel()
        await finish(oldA, "stale")
        await finish(oldB, "stale")
        check(multi.results.isEmpty && !multi.busy, "Cancelled multi-source responses cannot populate results")

        check(service.pending.isEmpty, "All fixture requests consumed")
        print("PASS: \(checks) VOD regression assertions; real loading/search/source resolution code, no GUI or real network")
    }
}
