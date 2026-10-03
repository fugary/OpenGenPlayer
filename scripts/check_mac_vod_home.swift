import Foundation

struct ServerConfig {}
typealias Page = (items: [VODItem], totalPages: Int, totalCount: Int)
@MainActor final class VODService {
    static let shared = VODService()
    var categories: [VODCategory] = []
    var categoryFailure = false
    var pending: [(String, CheckedContinuation<Page, Error>)] = []
    var requestedPages: [(String, Int)] = []
    func fetchCategories(server: ServerConfig, forceRefresh: Bool = false) async throws -> [VODCategory] {
        if categoryFailure { throw URLError(.cannotConnectToHost) }
        return categories
    }
    func fetchList(server: ServerConfig, typeId: String? = nil, page: Int = 1) async throws -> Page {
        requestedPages.append((typeId ?? "ALL", page))
        return try await withCheckedThrowingContinuation { pending.append((typeId ?? "ALL", $0)) }
    }
    func search(server: ServerConfig, keyword: String, page: Int = 1, typeId: String? = nil) async throws -> Page {
        requestedPages.append((keyword + "@" + (typeId ?? "ALL"), page))
        return try await withCheckedThrowingContinuation { pending.append((keyword + "@" + (typeId ?? "ALL"), $0)) }
    }
    func take(_ key: String) async -> CheckedContinuation<Page, Error> {
        for _ in 0..<1000 {
            if let i = pending.firstIndex(where: { $0.0 == key }) { return pending.remove(at: i).1 }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        fatalError("Missing request \(key)")
    }
}

@main struct HomeChecks {
    @MainActor static var count = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ label: String) {
        precondition(value(), label)
        count += 1
    }
    static func page(_ ids: [String]) -> Page { (ids.map { VODItem(vodId: $0, vodName: $0) }, 1, ids.count) }
    static func settle() async { try? await Task.sleep(nanoseconds: 20_000_000) }
    @MainActor static func main() async {
        check(MacVODHomeModel.Shelf(loaded: true).isConfirmedEmpty, "Completed empty shelf is hidden")
        check(!MacVODHomeModel.Shelf().isConfirmedEmpty, "Unloaded shelf remains available")
        check(!MacVODHomeModel.Shelf(error: "failure", loaded: true).isConfirmedEmpty, "Failed shelf remains retryable")
        check(!MacVODHomeModel.Shelf(loaded: true, hasMore: true).isConfirmedEmpty, "Unfinished empty aggregate remains available")
        let server = ServerConfig()
        let service = VODService.shared
        service.categories = [
            .init(typeId: "1", typeName: "Parent"),
            .init(typeId: "2", typeName: "Child", typePid: 1),
            .init(typeId: "3", typeName: "Other"),
            .init(typeId: "4", typeName: "Cycle A", typePid: 5),
            .init(typeId: "5", typeName: "Cycle B", typePid: 4),
            .init(typeId: "6", typeName: "Orphan", typePid: 99)
        ]
        let model = MacVODHomeModel()
        model.setActive(true, server: server)
        let old = await service.take("ALL")
        model.setActive(false, server: server)
        model.setActive(true, server: server)
        let current = await service.take("ALL")
        old.resume(returning: page(["stale"]))
        await settle()
        check(model.items.isEmpty, "Cancelled response must not overwrite new home")
        current.resume(returning: page(["a", "a", "b"]))
        await settle()
        check(model.items.map(\.id) == ["a", "b"], "Deduplicate default page")
        check(Set(model.roots.map(\.id)) == Set(["1", "3", "4", "5", "6"]), "Cycle and orphan categories are reachable")
        check(model.children(of: service.categories[0]).map(\.id) == ["2"], "Valid child stays under parent")
        check(model.previewCategories.map(\.id) == ["1", "3", "4", "5", "6"], "Preview top-level libraries in source order")
        check(service.pending.isEmpty, "Do not prefetch offscreen categories")

        model.showCategory("1", server: server)
        let child = await service.take("1")
        model.showCategory("3", server: server)
        check(service.pending.isEmpty, "Category queue bounds concurrency")
        child.resume(returning: page(["a", "c", "c"]))
        let descendants = await service.take("2")
        descendants.resume(returning: page(["child-film"]))
        let other = await service.take("3")
        check(model.shelves["1"]?.items.map(\.id) == ["a", "child-film", "c"], "Deduplicate shelf without suppressing carousel entries")
        check(model.shelves["1"]?.totalCount == 3, "Completed aggregate reports unique total, not summed source totals")
        other.resume(throwing: URLError(.timedOut))
        await settle()
        check(model.shelves["3"]?.error != nil && model.items.count == 2, "Partial failure preserves usable home")
        check(model.shelves["3"]?.totalCount == nil, "Failed category does not invent a total")
        model.retryCategory("3", server: server)
        let retry = await service.take("3")
        retry.resume(returning: page(["c", "d"]))
        await settle()
        check(model.shelves["3"]?.items.map(\.id) == ["c", "d"], "Library shelves keep their own content")

        model.refresh(server: server)
        let refresh = await service.take("ALL")
        check(model.items.count == 2, "Refresh keeps old content")
        model.setActive(false, server: server)
        refresh.resume(returning: page(["late"]))
        await settle()
        check(model.items.map(\.id) == ["a", "b"], "Leaving home invalidates refresh callbacks")
        check(!model.isLoading && model.loadingCategoryID == nil, "Cancellation clears spinners")

        model.reset()
        check(model.items.isEmpty && model.categories.isEmpty && model.shelves.isEmpty, "Changing server clears all cached home content")
        model.setActive(true, server: server)
        let resetRequest = await service.take("ALL")
        model.setActive(true, server: server)
        check(service.pending.isEmpty, "Repeated activation does not restart requests")
        resetRequest.resume(returning: page(["new-server"]))
        await settle()
        check(model.items.first?.id == "new-server", "New server can load after reset")
        model.setActive(false, server: server)

        service.categoryFailure = true
        let failedCategories = MacVODHomeModel()
        failedCategories.setActive(true, server: server)
        let goodList = await service.take("ALL")
        goodList.resume(returning: page(["ok"]))
        await settle()
        check(failedCategories.items.first?.id == "ok" && failedCategories.categoryError != nil, "Category failure does not hide list")
        failedCategories.setActive(false, server: server)
        let tree: [VODCategory] = [
            .init(typeId: "10", typeName: "Library"),
            .init(typeId: "11", typeName: "Genre A", typePid: 10),
            .init(typeId: "12", typeName: "Genre B", typePid: 10),
            .init(typeId: "13", typeName: "Genre C", typePid: 10),
            .init(typeId: "14", typeName: "Genre D", typePid: 10)
        ]
        check(MacVODCategoryPager.leaves(of: "10", categories: tree) == ["11", "12", "13", "14"], "Aggregate remains within selected parent")
        check(MacVODCategoryPager.leaves(of: "4", categories: service.categories).isEmpty, "Cycles cannot become recursive fallback requests")
        let firstTask = Task { @MainActor in
            var pager = MacVODCategoryPager()
            let result = try await pager.load(server: server, categoryID: "10", categories: tree, page: 1)
            return (pager, result)
        }
        let parent = await service.take("10")
        parent.resume(returning: page([]))
        let genreA = await service.take("11")
        let genreB = await service.take("12")
        let genreC = await service.take("13")
        check(service.pending.isEmpty, "Three child requests start before any child finishes; fourth stays bounded")
        genreA.resume(returning: (page(["a", "dup"]).items, 2, 4))
        genreB.resume(throwing: URLError(.timedOut))
        genreC.resume(returning: page(["dup", "c"]))
        let (firstPager, firstPage) = try! await firstTask.value
        check(firstPager.isAggregate && firstPager.hasFailures, "Empty parent falls back and exposes partial failure")
        check(firstPage.items.map(\.id) == ["a", "dup", "c"], "Child pages interleave and deduplicate")
        check(firstPage.totalCount == 3 && firstPage.totalPages == 2, "Aggregated count describes loaded items with more available")
        check(service.pending.isEmpty, "Fallback stops after three child requests")
        let nextTask = Task { @MainActor in
            var pager = firstPager
            let result = try await pager.load(server: server, categoryID: "10", categories: tree, page: 2)
            return (pager, result)
        }
        let genreD = await service.take("14")
        genreD.resume(returning: page([]))
        let nextA = await service.take("11")
        nextA.resume(returning: (page(["a", "z"]).items, 2, 4))
        let retryB = await service.take("12")
        retryB.resume(returning: page(["y"]))
        let (lastPager, lastPage) = try! await nextTask.value
        check(lastPage.items.map(\.id) == ["y", "z"], "Later batches suppress cross-page duplicates")
        check(lastPage.totalPages == 2 && lastPage.totalCount == 5 && !lastPager.hasFailures, "Aggregate ends only when all children finish")
        check(service.requestedPages.filter { $0.0 == "11" }.map { $0.1 } == [1, 2], "Successful child advances independently")
        check(service.requestedPages.filter { $0.0 == "12" }.map { $0.1 } == [1, 1], "Failed child retries the same page")

        let cancelled = Task { @MainActor in
            var pager = MacVODCategoryPager()
            return try await pager.load(server: server, categoryID: "10", categories: tree, page: 1)
        }
        let late = await service.take("10")
        cancelled.cancel()
        late.resume(returning: page([]))
        do { _ = try await cancelled.value; preconditionFailure("Cancellation must propagate") }
        catch { check(error is CancellationError, "Cancellation must not trigger child fallback") }
        check(service.pending.isEmpty, "Cancelled parent queues no new requests")

        let scoped = Task { @MainActor in
            var pager = MacVODCategoryPager()
            return try await pager.load(server: server, categoryID: "10", categories: Array(tree.prefix(3)), page: 1, keyword: "query")
        }
        await service.take("query@10").resume(returning: page(["parent"]))
        await service.take("query@11").resume(returning: page(["match", "parent"]))
        await service.take("query@12").resume(returning: page(["second"]))
        let scopedPage = try! await scoped.value
        check(Set(scopedPage.items.map(\.id)) == Set(["parent", "match", "second"]), "Scoped search includes parent and children, deduplicated")
        check(scopedPage.totalPages == 1, "Scoped search ends after all scoped streams finish")

        let sourceA = UUID(), sourceB = UUID()
        func entry(_ source: UUID, _ id: String, _ title: String, _ year: String?) -> MacVODSearchEntry {
            .init(sourceID: source, item: VODItem(vodId: id, vodName: title, vodYear: year))
        }
        let a = entry(sourceA, "1", "Example Season 1", "2026")
        let b = entry(sourceB, "1", " Example Season 1 ", "2026")
        let merged = MacVODSearchGroup.aggregate([a, b, a])
        check(merged.count == 1 && merged[0].entries.count == 2, "Same title/year merges and repeated source items deduplicate")
        check(merged[0].sourceCount == 2, "Equal item IDs across sources remain separate choices")
        check(merged[0].id == MacVODSearchGroup.aggregate([a])[0].id, "Pagination preserves group identity")
        check(merged[0].entries.map(\.sourceID) == [sourceA, sourceB], "Source order and original IDs are retained")
        check(MacVODSearchGroup.aggregate([a, entry(sourceB, "2", "Example Season 1", "2025")]).count == 2, "Different years stay separate")
        check(MacVODSearchGroup.aggregate([a, entry(sourceB, "2", "Example Season 2", "2026")]).count == 2, "Different seasons stay separate")
        check(MacVODSearchGroup.aggregate([a, entry(sourceB, "2", "Example Season 1 Dubbed", "2026")]).count == 2, "Version text remains part of identity")
        check(MacVODSearchGroup.aggregate([entry(sourceA, "1", "Example", nil), entry(sourceB, "1", "Example", "0")]).count == 2, "Unknown years never merge")
        check(MacVODSearchGroup.aggregate([a, entry(sourceB, "2", "Example Season 1", nil)]).count == 2, "Unknown year never joins a known year")

        check(MacVODContentKind.classify("剧情片") == .movie, "Movie genre is not mistaken for a TV series")
        check(MacVODContentKind.classify("电影解说") == .commentary, "Commentary is a separate content type")
        check(MacVODContentKind.classify("国产动漫") == .animation, "Animation maps independently of region")
        check(MacVODContentKind.classify("演员") == nil, "Unknown category never maps to an arbitrary library")
        let relevance = MacVODSearchGroup.aggregate([entry(sourceA, "a", "Small Superman", "2025"), entry(sourceA, "b", "Superman Returns", "2025"), entry(sourceB, "c", "Superman", "2025")])
        check(MacVODSearchGroup.ranked(relevance, keyword: "Superman").compactMap { $0.entries.first?.item.id } == ["c", "b", "a"], "Exact title sorts before prefix and contains matches")
        check(MacVODSearchGroup.interleaved([a, entry(sourceA, "2", "Second", "2025"), b]).map(\.sourceID) == [sourceA, sourceB, sourceA], "Home previews alternate sources instead of filling with the first source")

        print("PASS: \(count) macOS VOD home assertions; no GUI or live network")
    }
}
