import Foundation
import Combine

public struct PrivacySpaceSnapshot: Codable, Equatable {
    public let lockedServerIDs: [String]
    public let lockedLocalPaths: [String]
    public let lockedRemotePaths: [String]

    public init(
        lockedServerIDs: [String],
        lockedLocalPaths: [String],
        lockedRemotePaths: [String]
    ) {
        self.lockedServerIDs = Self.normalizedValues(lockedServerIDs)
        self.lockedLocalPaths = Self.normalizedValues(lockedLocalPaths)
        self.lockedRemotePaths = Self.normalizedValues(lockedRemotePaths)
    }

    public var isEmpty: Bool {
        lockedServerIDs.isEmpty &&
            lockedLocalPaths.isEmpty &&
            lockedRemotePaths.isEmpty
    }

    private static func normalizedValues(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted()
    }
}

public final class PrivacySpaceService: ObservableObject {
    public static let shared = PrivacySpaceService()
    public static let didChangeMarksNotification = Notification.Name("PrivacySpaceServiceDidChangeMarks")

    @Published public private(set) var lockedServerIDs: Set<String> = []
    @Published public private(set) var lockedLocalPaths: Set<String> = []
    @Published public private(set) var lockedRemotePaths: Set<String> = []

    private let lockedServerIDsKey = "privacy_space_locked_server_ids_v1"
    private let lockedLocalPathsKey = "privacy_space_locked_local_paths_v1"
    private let lockedRemotePathsKey = "privacy_space_locked_remote_paths_v1"

    private init() {
        lockedServerIDs = Self.loadSet(forKey: lockedServerIDsKey)
        lockedLocalPaths = Self.loadSet(forKey: lockedLocalPathsKey)
        lockedRemotePaths = Self.loadSet(forKey: lockedRemotePathsKey)
    }

    public var currentSnapshot: PrivacySpaceSnapshot {
        PrivacySpaceSnapshot(
            lockedServerIDs: Array(lockedServerIDs),
            lockedLocalPaths: Array(lockedLocalPaths),
            lockedRemotePaths: Array(lockedRemotePaths)
        )
    }

    public func replaceMarks(
        with snapshot: PrivacySpaceSnapshot,
        postChangeNotification: Bool = true
    ) {
        lockedServerIDs = Set(snapshot.lockedServerIDs)
        lockedLocalPaths = Set(snapshot.lockedLocalPaths)
        lockedRemotePaths = Set(snapshot.lockedRemotePaths)
        persistSets(postChangeNotification: postChangeNotification)
    }

    public func isServerMarkedPrivate(_ server: ServerConfig) -> Bool {
        lockedServerIDs.contains(server.id.uuidString)
    }

    public func setServerMarkedPrivate(_ marked: Bool, for server: ServerConfig) {
        let serverID = server.id.uuidString
        if marked {
            lockedServerIDs.insert(serverID)
        } else {
            lockedServerIDs.remove(serverID)
        }
        persistSets()
    }

    @discardableResult
    public func toggleServerMarkedPrivate(_ server: ServerConfig) -> Bool {
        let nextValue = !isServerMarkedPrivate(server)
        setServerMarkedPrivate(nextValue, for: server)
        return nextValue
    }

    public func isLocalFolderMarkedPrivate(_ folderURL: URL) -> Bool {
        let normalized = Self.normalizedLocalPath(for: folderURL)
        return containsLocalPath(normalized)
    }

    public func setLocalFolderMarkedPrivate(_ marked: Bool, for folderURL: URL) {
        let normalized = Self.normalizedLocalPath(for: folderURL)
        guard !normalized.isEmpty else { return }

        if marked {
            lockedLocalPaths.insert(normalized)
        } else {
            lockedLocalPaths.remove(normalized)
        }
        persistSets()
    }

    @discardableResult
    public func toggleLocalFolderMarkedPrivate(_ folderURL: URL) -> Bool {
        let nextValue = !isLocalFolderMarkedPrivate(folderURL)
        setLocalFolderMarkedPrivate(nextValue, for: folderURL)
        return nextValue
    }

    public func isRemoteFolderMarkedPrivate(server: ServerConfig, path: String) -> Bool {
        containsRemotePath(serverID: server.id, path: path)
    }

    public func isRemoteFolderDirectlyMarkedPrivate(server: ServerConfig, path: String) -> Bool {
        let key = Self.remoteFolderKey(serverID: server.id, path: path)
        guard !key.isEmpty else { return false }
        return lockedRemotePaths.contains(key)
    }

    public func setRemoteFolderMarkedPrivate(_ marked: Bool, server: ServerConfig, path: String) {
        let key = Self.remoteFolderKey(serverID: server.id, path: path)
        guard !key.isEmpty else { return }

        if marked {
            lockedRemotePaths.insert(key)
        } else {
            lockedRemotePaths.remove(key)
        }
        persistSets()
    }

    @discardableResult
    public func toggleRemoteFolderMarkedPrivate(server: ServerConfig, path: String) -> Bool {
        let nextValue = !isRemoteFolderMarkedPrivate(server: server, path: path)
        setRemoteFolderMarkedPrivate(nextValue, server: server, path: path)
        return nextValue
    }

    public func isFileMarkedPrivate(_ file: VideoFile) -> Bool {
        if file.isRemote {
            if let serverID = resolvedServerID(for: file) {
                if lockedServerIDs.contains(serverID.uuidString) {
                    return true
                }
                return containsRemotePath(serverID: serverID, path: resolvedRemotePath(for: file))
            }

            if let server = resolvedServer(for: file), isServerMarkedPrivate(server) {
                return true
            }

            return false
        }

        return containsLocalPath(Self.normalizedLocalPath(for: file.url))
    }

    public func isFavoriteMarkedPrivate(_ item: FavoriteItem) -> Bool {
        let file = item.file

        if file.isRemote {
            if let serverID = resolvedServerID(for: file) {
                if lockedServerIDs.contains(serverID.uuidString) {
                    return true
                }
                if let folderPath = item.folderPath,
                   !folderPath.hasPrefix("__") {
                    return containsRemotePath(serverID: serverID, path: folderPath)
                }
                return containsRemotePath(serverID: serverID, path: resolvedRemotePath(for: file))
            }

            if let server = resolvedServer(for: file), isServerMarkedPrivate(server) {
                return true
            }

            return false
        }

        if let folderPath = item.folderPath {
            return containsLocalPath(Self.normalizedLocalPath(forRawPath: folderPath))
        }

        return containsLocalPath(Self.normalizedLocalPath(for: file.url))
    }

    public func isMediaItemMarkedPrivate(_ item: MediaItem) -> Bool {
        if item.isRemote {
            if let serverID = resolvedServerID(for: item) {
                if lockedServerIDs.contains(serverID.uuidString) {
                    return true
                }
                let remotePath = resolvedRemotePath(for: item)
                return containsRemotePath(serverID: serverID, path: remotePath)
            }

            if let server = resolvedServer(for: item), isServerMarkedPrivate(server) {
                return true
            }

            return false
        }

        return containsLocalPath(Self.normalizedLocalPath(for: item.url))
    }

    public func remove(server: ServerConfig) {
        let serverID = server.id.uuidString
        lockedServerIDs.remove(serverID)
        lockedRemotePaths = lockedRemotePaths.filter { !$0.hasPrefix("\(serverID)|") }
        persistSets()
    }

    public func clearAll() {
        lockedServerIDs.removeAll()
        lockedLocalPaths.removeAll()
        lockedRemotePaths.removeAll()
        persistSets()
    }

    private func containsLocalPath(_ normalizedPath: String) -> Bool {
        lockedLocalPaths.contains { lockedPath in
            normalizedPath == lockedPath || normalizedPath.hasPrefix("\(lockedPath)/")
        }
    }

    private func containsRemotePath(serverID: UUID, path: String) -> Bool {
        let normalizedPath = Self.normalizedRemotePath(path)
        let prefix = "\(serverID.uuidString)|"

        return lockedRemotePaths.contains { entry in
            guard entry.hasPrefix(prefix) else { return false }
            let lockedPath = String(entry.dropFirst(prefix.count))
            return normalizedPath == lockedPath || normalizedPath.hasPrefix("\(lockedPath)/")
        }
    }

    private func resolvedServerID(for file: VideoFile) -> UUID? {
        if let rawServerID = file.jellyfinServerId,
           let serverID = UUID(uuidString: rawServerID) {
            return serverID
        }

        return resolvedServer(for: file)?.id
    }

    private func resolvedServerID(for item: MediaItem) -> UUID? {
        if let rawServerID = item.jellyfinServerId,
           let serverID = UUID(uuidString: rawServerID) {
            return serverID
        }

        return resolvedServer(for: item)?.id
    }

    private func resolvedServer(for file: VideoFile) -> ServerConfig? {
        let savedServers = AppNetworkService.shared.savedServers

        if let serverID = resolvedServerIDByString(file.jellyfinServerId, within: savedServers) {
            return serverID
        }

        return resolveServer(
            host: file.url.host,
            port: file.url.port,
            preferredType: file.serverType,
            savedServers: savedServers
        )
    }

    private func resolvedServer(for item: MediaItem) -> ServerConfig? {
        let savedServers = AppNetworkService.shared.savedServers

        if let serverID = resolvedServerIDByString(item.jellyfinServerId, within: savedServers) {
            return serverID
        }

        return resolveServer(
            host: item.url.host,
            port: item.url.port,
            preferredType: item.serverType,
            savedServers: savedServers
        )
    }

    private func resolvedServerIDByString(_ rawServerID: String?, within servers: [ServerConfig]) -> ServerConfig? {
        guard let rawServerID,
              let serverID = UUID(uuidString: rawServerID) else {
            return nil
        }

        return servers.first { $0.id == serverID }
    }

    private func resolveServer(
        host: String?,
        port: Int?,
        preferredType: ServerConfig.ServerType?,
        savedServers: [ServerConfig]
    ) -> ServerConfig? {
        guard let host = host?.lowercased(), !host.isEmpty else { return nil }

        let matchesHostAndPort: (ServerConfig) -> Bool = { server in
            let normalizedAddress = Self.normalizedServerAddress(server.address)
            guard normalizedAddress == host else { return false }

            let serverPort = server.port
                ?? URLComponents(string: server.fullURL)?.port
                ?? ServerConfig.defaultPort(for: server.type, useSSL: server.useSSL)

            if let port {
                return port == serverPort
            }

            return true
        }

        if let preferredType,
           let server = savedServers.first(where: { $0.type == preferredType && matchesHostAndPort($0) }) {
            return server
        }

        return savedServers.first(where: matchesHostAndPort)
    }

    private func resolvedRemotePath(for file: VideoFile) -> String {
        if let serverPath = file.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serverPath.isEmpty {
            return serverPath
        }

        return file.url.path
    }

    private func resolvedRemotePath(for item: MediaItem) -> String {
        if let serverPath = item.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serverPath.isEmpty {
            return serverPath
        }

        return item.url.path
    }

    private func persistSets(postChangeNotification: Bool = true) {
        Self.saveSet(lockedServerIDs, forKey: lockedServerIDsKey)
        Self.saveSet(lockedLocalPaths, forKey: lockedLocalPathsKey)
        Self.saveSet(lockedRemotePaths, forKey: lockedRemotePathsKey)

        if postChangeNotification {
            NotificationCenter.default.post(
                name: Self.didChangeMarksNotification,
                object: self
            )
        }
    }

    private static func loadSet(forKey key: String) -> Set<String> {
        let values = UserDefaults.standard.array(forKey: key) as? [String] ?? []
        return Set(values.filter { !$0.isEmpty })
    }

    private static func saveSet(_ values: Set<String>, forKey key: String) {
        UserDefaults.standard.set(Array(values).sorted(), forKey: key)
    }

    private static func normalizedLocalPath(for url: URL) -> String {
        normalizedLocalPath(forRawPath: url.standardizedFileURL.path)
    }

    private static func normalizedLocalPath(forRawPath rawPath: String) -> String {
        let standardizedPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path

        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return standardizedPath
        }

        let documentsPath = documentsURL.standardizedFileURL.path
        if standardizedPath == documentsPath {
            return ""
        }

        if standardizedPath.hasPrefix(documentsPath + "/") {
            return String(standardizedPath.dropFirst(documentsPath.count + 1))
        }

        if let range = standardizedPath.range(of: "/Documents/") {
            return String(standardizedPath[range.upperBound...])
        }

        return standardizedPath
    }

    private static func normalizedRemotePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        let withLeadingSlash = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        var components: [String] = []
        for part in withLeadingSlash.components(separatedBy: "/") {
            if part.isEmpty || part == "." { continue }
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
            } else {
                components.append(part)
            }
        }
        return "/" + components.joined(separator: "/")
    }

    private static func normalizedServerAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }

        if let host = URL(string: trimmed)?.host?.lowercased() {
            return host
        }

        if let host = URLComponents(string: "http://\(trimmed)")?.host?.lowercased() {
            return host
        }

        return trimmed
    }

    private static func remoteFolderKey(serverID: UUID, path: String) -> String {
        "\(serverID.uuidString)|\(normalizedRemotePath(path))"
    }
}
