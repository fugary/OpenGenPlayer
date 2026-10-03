import Foundation
import Combine

public class SearchHistoryService: ObservableObject {
    public static let shared = SearchHistoryService()

    @Published public private(set) var historyByServer: [String: [String]] = [:]
    
    private let userDefaultsPrefix = "search_history_server_"
    private let maxHistoryCount = 20
    private let lock = NSLock()

    private init() {}

    private func storageKey(for serverId: String) -> String {
        "\(userDefaultsPrefix)\(serverId)"
    }

    /// Retrieve search history queries for a given server ID (ordered newest first)
    public func getHistory(for serverId: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        if let cached = historyByServer[serverId] {
            return cached
        }

        let key = storageKey(for: serverId)
        let loaded = UserDefaults.standard.stringArray(forKey: key) ?? []
        historyByServer[serverId] = loaded
        return loaded
    }

    /// Add a query to history for the specified server. Automatically deduplicates and moves to top.
    public func addHistory(_ query: String, for serverId: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        var list = historyByServer[serverId] ?? (UserDefaults.standard.stringArray(forKey: storageKey(for: serverId)) ?? [])
        list.removeAll(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
        list.insert(trimmed, at: 0)
        if list.count > maxHistoryCount {
            list = Array(list.prefix(maxHistoryCount))
        }

        historyByServer[serverId] = list
        UserDefaults.standard.set(list, forKey: storageKey(for: serverId))
    }

    /// Remove a specific query for a server
    public func removeHistory(_ query: String, for serverId: String) {
        lock.lock()
        defer { lock.unlock() }

        var list = historyByServer[serverId] ?? (UserDefaults.standard.stringArray(forKey: storageKey(for: serverId)) ?? [])
        list.removeAll(where: { $0.caseInsensitiveCompare(query) == .orderedSame })

        historyByServer[serverId] = list
        UserDefaults.standard.set(list, forKey: storageKey(for: serverId))
    }

    /// Clear all search history queries for a server
    public func clearHistory(for serverId: String) {
        lock.lock()
        defer { lock.unlock() }

        historyByServer.removeValue(forKey: serverId)
        UserDefaults.standard.removeObject(forKey: storageKey(for: serverId))
    }

    // MARK: - UUID Overloads

    public func getHistory(for serverId: UUID) -> [String] {
        getHistory(for: serverId.uuidString)
    }

    public func addHistory(_ query: String, for serverId: UUID) {
        addHistory(query, for: serverId.uuidString)
    }

    public func removeHistory(_ query: String, for serverId: UUID) {
        removeHistory(query, for: serverId.uuidString)
    }

    public func clearHistory(for serverId: UUID) {
        clearHistory(for: serverId.uuidString)
    }
}
