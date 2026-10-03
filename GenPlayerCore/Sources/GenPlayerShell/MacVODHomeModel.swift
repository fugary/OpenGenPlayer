#if os(macOS)
import Foundation
import Combine
import GenPlayerCore

/// macOS-only home data. One request at a time; visible shelves are queued after
/// the default list so a slow category never blocks the first useful content.
@MainActor
final class MacVODHomeModel: ObservableObject {
    struct Shelf {
        var items: [VODItem] = []
        var error: String?
        var loaded = false
        var hasMore = false
        var totalCount: Int? = nil
        var isConfirmedEmpty: Bool { loaded && items.isEmpty && error == nil && !hasMore }
    }

    @Published private(set) var items: [VODItem] = []
    @Published private(set) var categories: [VODCategory] = []
    @Published private(set) var shelves: [String: Shelf] = [:]
    @Published private(set) var error: String?
    @Published private(set) var categoryError: String?
    @Published private(set) var isLoading = false
    @Published private(set) var loadingCategoryID: String?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var hasLoaded = false
    private var active = false
    private var pending: [String] = []
    private var visible: Set<String> = []

    /// Treat invalid parent chains as flat roots; never recurse through a cycle.
    var roots: [VODCategory] {
        categories.filter { category in
            guard let parent = category.typePid?.value, parent != 0,
                  categories.contains(where: { $0.id == String(parent) }) else { return true }
            var seen: Set<String> = [category.id]
            var cursor = String(parent)
            while let node = categories.first(where: { $0.id == cursor }) {
                guard seen.insert(cursor).inserted else { return true }
                guard let next = node.typePid?.value, next != 0 else { return false }
                cursor = String(next)
            }
            return true
        }
    }

    func children(of category: VODCategory) -> [VODCategory] {
        let rootIDs = Set(roots.map(\.id))
        return categories.filter {
            $0.typePid.map { String($0.value) } == category.id && !rootIDs.contains($0.id)
        }
    }

    // Homepage shelves represent top-level libraries, not the first few genres.
    var previewCategories: [VODCategory] {
        roots
    }

    func reset() {
        task?.cancel()
        task = nil
        requestID = UUID()
        active = false
        hasLoaded = false
        isLoading = false
        loadingCategoryID = nil
        pending = []
        visible = []
        items = []
        categories = []
        shelves = [:]
        error = nil
        categoryError = nil
    }

    func setActive(_ value: Bool, server: ServerConfig) {
        guard active != value else { return }
        active = value
        if !value {
            task?.cancel()
            task = nil
            requestID = UUID()
            isLoading = false
            loadingCategoryID = nil
            pending = []
        } else if !hasLoaded {
            refresh(server: server)
        } else {
            enqueueVisible(server: server)
        }
    }

    func refresh(server: ServerConfig, forceCategoryRefresh: Bool = false) {
        guard active else { return }
        task?.cancel()
        let id = UUID()
        requestID = id
        isLoading = true
        loadingCategoryID = nil
        error = nil
        categoryError = nil
        pending = []
        task = Task { @MainActor in
            do {
                let page = try await VODService.shared.fetchList(server: server)
                guard !Task.isCancelled, requestID == id else { return }
                var seen = Set<String>()
                items = Array(page.items.filter { seen.insert($0.id).inserted }.prefix(12))
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                self.error = error.localizedDescription
            }
            do {
                let result = try await VODService.shared.fetchCategories(server: server, forceRefresh: hasLoaded || forceCategoryRefresh)
                guard !Task.isCancelled, requestID == id else { return }
                var seen = Set<String>()
                categories = result.filter { seen.insert($0.id).inserted }
                // Retain old content during refresh; replace each row only when ready.
                shelves = shelves.filter { key, _ in categories.contains { $0.id == key } }
                for key in Array(shelves.keys) { shelves[key]?.loaded = false }
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                categoryError = error.localizedDescription
            }
            hasLoaded = true
            isLoading = false
            task = nil
            enqueueVisible(server: server)
        }
    }

    func showCategory(_ id: String, server: ServerConfig) {
        visible.insert(id)
        enqueueVisible(server: server)
    }

    func hideCategory(_ id: String) {
        visible.remove(id)
        pending.removeAll { $0 == id }
    }

    func retryCategory(_ id: String, server: ServerConfig) {
        shelves[id]?.loaded = false
        enqueueVisible(server: server)
    }

    private func enqueueVisible(server: ServerConfig) {
        guard active, !isLoading else { return }
        for category in previewCategories where visible.contains(category.id) {
            let id = category.id
            if shelves[id]?.loaded != true && loadingCategoryID != id && !pending.contains(id) {
                pending.append(id)
            }
        }
        startNext(server: server)
    }

    private func startNext(server: ServerConfig) {
        guard active, !isLoading, task == nil, !pending.isEmpty else { return }
        let categoryID = pending.removeFirst()
        let id = requestID
        loadingCategoryID = categoryID
        task = Task { @MainActor in
            do {
                var pager = MacVODCategoryPager()
                var page = try await pager.load(server: server, categoryID: categoryID, categories: categories, page: 1)
                var preview = page.items
                var pageNumber = 1
                var fillError: String?
                // Continue short/empty batches, but never crawl an unbounded source.
                while preview.count < 12 && pageNumber < page.totalPages && pageNumber < 4 {
                    do {
                        pageNumber += 1
                        page = try await pager.load(server: server, categoryID: categoryID, categories: categories, page: pageNumber)
                        preview.append(contentsOf: page.items)
                    } catch {
                        try Task.checkCancellation()
                        fillError = error.localizedDescription
                        break
                    }
                }
                guard !Task.isCancelled, requestID == id else { return }
                var seen = Set<String>()
                // The carousel is a separate entry point; do not empty a library
                // merely because its items are featured above it.
                shelves[categoryID] = Shelf(
                    items: Array(preview.filter { seen.insert($0.id).inserted }.prefix(12)),
                    error: fillError ?? (pager.hasFailures ? NSLocalizedString("Some categories could not be loaded.", comment: "VOD partial category load") : nil),
                    loaded: true,
                    hasMore: fillError != nil || page.totalPages > pageNumber,
                    totalCount: fillError == nil && !pager.hasFailures && (!pager.isAggregate || page.totalPages <= pageNumber) ? page.totalCount : nil
                )
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                var shelf = shelves[categoryID] ?? Shelf()
                shelf.error = error.localizedDescription
                shelf.loaded = true
                shelves[categoryID] = shelf
            }
            loadingCategoryID = nil
            task = nil
            startNext(server: server)
        }
    }
}
#endif
