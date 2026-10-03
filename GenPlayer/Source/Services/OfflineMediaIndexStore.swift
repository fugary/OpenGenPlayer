import Foundation
import Combine

/// A low-frequency, pure-in-memory index of completed offline media items.
///
/// Designed to decouple high-frequency download progress updates (speed, percentage)
/// from library views and media poster cards. Updates and publishes ONLY when items
/// complete downloading, are deleted, or when the index is rebuilt at launch.
@MainActor
final class OfflineMediaIndexStore: ObservableObject {
    static let shared = OfflineMediaIndexStore()

    /// Monotonically increasing revision number, triggered only on discrete state transitions
    /// (e.g. download completed, download removed, or server deleted).
    @Published private(set) var revision: UInt = 0

    /// ServerId -> [Normalized Remote Item ID: Validated Local File URL]
    private var completedItemIdsByServer: [UUID: [String: URL]] = [:]

    /// ServerId -> [Normalized Remote Path: Validated Local File URL]
    private var completedPathsByServer: [UUID: [String: URL]] = [:]

    /// Standardized local file path -> Validated Local File URL
    private var completedLocalFileURLs: [String: URL] = [:]

    private init() {}

    // MARK: - Query APIs (O(1) in-memory lookups)

    /// Fast O(1) check if a remote media item on a server has a completed offline file.
    func isDownloaded(serverId: UUID, remoteItemId: String) -> Bool {
        let normalized = normalizeKey(remoteItemId)
        guard !normalized.isEmpty else { return false }
        return completedItemIdsByServer[serverId]?[normalized] != nil
    }

    /// Fast O(1) check if a remote file path on a server has a completed offline file.
    func isDownloaded(serverId: UUID, remotePath: String) -> Bool {
        let normalized = normalizeKey(remotePath)
        guard !normalized.isEmpty else { return false }
        return completedPathsByServer[serverId]?[normalized] != nil
    }

    /// Fast check for a VideoFile.
    func isDownloaded(file: VideoFile) -> Bool {
        if let serverId = file.jellyfinServerId.flatMap(UUID.init(uuidString:)) {
            if let remoteItemId = file.jellyfinItemId, !remoteItemId.isEmpty,
               isDownloaded(serverId: serverId, remoteItemId: remoteItemId) {
                return true
            }
            if let serverPath = file.serverPath, !serverPath.isEmpty,
               isDownloaded(serverId: serverId, remotePath: serverPath) {
                return true
            }
        }
        if file.url.isFileURL {
            let standardized = file.url.standardizedFileURL.path
            return completedLocalFileURLs[standardized] != nil || FileManager.default.fileExists(atPath: standardized)
        }
        return false
    }

    /// Fast O(1) retrieval of the validated local file URL for a remote item.
    func localFileURL(serverId: UUID, remoteItemId: String) -> URL? {
        let normalized = normalizeKey(remoteItemId)
        guard !normalized.isEmpty else { return nil }
        return completedItemIdsByServer[serverId]?[normalized]
    }

    /// Fast O(1) retrieval of the validated local file URL for a remote path.
    func localFileURL(serverId: UUID, remotePath: String) -> URL? {
        let normalized = normalizeKey(remotePath)
        guard !normalized.isEmpty else { return nil }
        return completedPathsByServer[serverId]?[normalized]
    }

    // MARK: - Mutation APIs (Called only on completed/removed state changes)

    /// Full index rebuild from a snapshot of completed tasks.
    func rebuildIndex(from completedTasks: [DownloadTaskItem]) {
        var newItemIds: [UUID: [String: URL]] = [:]
        var newPaths: [UUID: [String: URL]] = [:]
        var newLocalURLs: [String: URL] = [:]

        for task in completedTasks where task.status == .completed {
            guard let localPath = task.localFilePath, !localPath.isEmpty else { continue }
            let localURL = URL(fileURLWithPath: localPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: localURL.path) else { continue }

            let serverId = task.serverId
            let standardizedPath = localURL.path
            newLocalURLs[standardizedPath] = localURL

            if let remoteItemId = task.remoteItemId {
                let normalizedId = normalizeKey(remoteItemId)
                if !normalizedId.isEmpty {
                    newItemIds[serverId, default: [:]][normalizedId] = localURL
                }
            }

            let normalizedPath = normalizeKey(task.remotePath)
            if !normalizedPath.isEmpty {
                newPaths[serverId, default: [:]][normalizedPath] = localURL
            }
        }

        self.completedItemIdsByServer = newItemIds
        self.completedPathsByServer = newPaths
        self.completedLocalFileURLs = newLocalURLs
        self.revision &+= 1
    }

    /// Register a newly completed download item.
    func registerCompleted(task: DownloadTaskItem) {
        guard task.status == .completed,
              let localPath = task.localFilePath, !localPath.isEmpty else { return }

        let localURL = URL(fileURLWithPath: localPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: localURL.path) else { return }

        let serverId = task.serverId
        let standardizedPath = localURL.path
        completedLocalFileURLs[standardizedPath] = localURL

        if let remoteItemId = task.remoteItemId {
            let normalizedId = normalizeKey(remoteItemId)
            if !normalizedId.isEmpty {
                completedItemIdsByServer[serverId, default: [:]][normalizedId] = localURL
            }
        }

        let normalizedPath = normalizeKey(task.remotePath)
        if !normalizedPath.isEmpty {
            completedPathsByServer[serverId, default: [:]][normalizedPath] = localURL
        }

        self.revision &+= 1
    }

    /// Unregister a removed or deleted item.
    func unregister(task: DownloadTaskItem) {
        let serverId = task.serverId

        if let remoteItemId = task.remoteItemId {
            let normalizedId = normalizeKey(remoteItemId)
            completedItemIdsByServer[serverId]?.removeValue(forKey: normalizedId)
        }

        let normalizedPath = normalizeKey(task.remotePath)
        completedPathsByServer[serverId]?.removeValue(forKey: normalizedPath)

        if let localPath = task.localFilePath {
            let standardizedPath = URL(fileURLWithPath: localPath).standardizedFileURL.path
            completedLocalFileURLs.removeValue(forKey: standardizedPath)
        }

        self.revision &+= 1
    }

    /// Clear all cached index entries for a given server.
    func clearIndex(for serverId: UUID) {
        if let items = completedItemIdsByServer.removeValue(forKey: serverId) {
            for (_, url) in items {
                completedLocalFileURLs.removeValue(forKey: url.path)
            }
        }
        if let paths = completedPathsByServer.removeValue(forKey: serverId) {
            for (_, url) in paths {
                completedLocalFileURLs.removeValue(forKey: url.path)
            }
        }
        self.revision &+= 1
    }

    private func normalizeKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
