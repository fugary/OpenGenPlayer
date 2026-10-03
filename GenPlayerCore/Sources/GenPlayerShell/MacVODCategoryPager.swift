#if os(macOS)
import Foundation
import GenPlayerCore

/// A value snapshot: callers commit it only after checking their request identity.
/// A failed/cancelled request cannot advance the live page cursors.
@MainActor
struct MacVODCategoryPager {
    private struct Cursor {
        let id: String
        var nextPage = 1
        var finished = false
        var failed = false
    }
    private var cursors: [Cursor] = []
    private var nextCursor = 0
    private var seen: Set<String> = []
    private var directItems: [VODItem] = []
    private(set) var isAggregate = false
    var hasFailures: Bool { cursors.contains { $0.failed } }

    static func leaves(of id: String, categories: [VODCategory]) -> [String] {
        var visited: Set<String> = [id]
        var queue = [id]
        var leaves: [String] = []
        while !queue.isEmpty {
            let current = queue.removeFirst()
            let children = categories.filter { $0.typePid.map { String($0.value) } == current }
            if children.isEmpty && current != id { leaves.append(current) }
            for child in children where visited.insert(child.id).inserted { queue.append(child.id) }
        }
        return leaves
    }

    mutating func load(server: ServerConfig, categoryID: String?, categories: [VODCategory], page: Int, keyword: String = "")
        async throws -> (items: [VODItem], totalPages: Int, totalCount: Int) {
        func fetch(_ typeID: String?, _ pageNumber: Int) async throws -> (items: [VODItem], totalPages: Int, totalCount: Int) {
            if keyword.isEmpty {
                return try await VODService.shared.fetchList(server: server, typeId: typeID, page: pageNumber)
            }
            return try await VODService.shared.search(server: server, keyword: keyword, page: pageNumber, typeId: typeID)
        }
        if page == 1 { self = Self() }
        if !isAggregate {
            let children = categoryID.map { Self.leaves(of: $0, categories: categories) } ?? []
            if children.isEmpty {
                return try await fetch(categoryID, page)
            }
            isAggregate = true
            cursors = children.map { Cursor(id: $0) }
            // A nonempty parent is not proof that the endpoint includes descendants.
            // Keep its direct entries as another stream alongside all child genres.
            if let categoryID {
                var parent = Cursor(id: categoryID)
                do {
                    let result = try await fetch(categoryID, 1)
                    try Task.checkCancellation()
                    directItems = result.items
                    parent.nextPage = 2
                    parent.finished = result.totalPages <= 1
                } catch {
                    try Task.checkCancellation()
                    parent.failed = true
                }
                cursors.append(parent)
            }
        }

        // Round-robin batches avoid fetching a large taxonomy in one operation.
        var batch: [Int] = []
        for offset in 0..<cursors.count {
            let index = (nextCursor + offset) % cursors.count
            if !cursors[index].finished { batch.append(index) }
            if batch.count == 3 { break }
        }
        var output: [VODItem] = []
        var chunks: [[VODItem]] = directItems.isEmpty ? [] : [directItems]
        var successfulRequests = directItems.isEmpty ? 0 : 1
        directItems = []
        var lastError: Error?
        let requests = batch.map { (index: $0, id: cursors[$0].id, page: cursors[$0].nextPage) }
        let responses = await withTaskGroup(of: (Int, Result<([VODItem], Int), Error>).self) { group in
            for request in requests {
                group.addTask {
                    do {
                        let result = try await fetch(request.id, request.page)
                        return (request.index, .success((result.items, result.totalPages)))
                    } catch { return (request.index, .failure(error)) }
                }
            }
            var values: [(Int, Result<([VODItem], Int), Error>)] = []
            for await response in group { values.append(response) }
            return values.sorted { $0.0 < $1.0 }
        }
        try Task.checkCancellation()
        for (index, response) in responses {
            switch response {
            case .success(let result):
                let page = cursors[index].nextPage
                successfulRequests += 1
                chunks.append(result.0)
                cursors[index].failed = false
                cursors[index].nextPage += 1
                cursors[index].finished = page >= result.1
            case .failure(let error):
                lastError = error
                cursors[index].failed = true
            }
        }
        if successfulRequests == 0, let lastError { throw lastError }
        // Mix child genres fairly instead of letting the first child's full page
        // fill the entire home preview.
        for row in 0..<(chunks.map(\.count).max() ?? 0) {
            for chunk in chunks where row < chunk.count {
                let item = chunk[row]
                if seen.insert(item.id).inserted { output.append(item) }
            }
        }
        if let last = batch.last { nextCursor = (last + 1) % cursors.count }
        let hasMore = cursors.contains { !$0.finished }
        return (output, page + (hasMore ? 1 : 0), seen.count)
    }
}
#endif
