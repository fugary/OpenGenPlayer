import Foundation
import GenPlayerCore
import Darwin
import AMSMB2
#if os(iOS)
import UIKit
#endif
import Network
import UserNotifications

enum RuntimeNetworkAddressResolver {
    private static let lock = NSLock()
    private static var dnsCache: [String: String] = [:]

    static func runtimeAddress(from address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return address }

        let hasExplicitScheme = trimmed.contains("://")
        let candidate = hasExplicitScheme ? trimmed : "placeholder://\(trimmed)"
        guard var components = URLComponents(string: candidate),
              let host = components.host,
              let resolvedHost = resolvedHostIfNeeded(host) else {
            return trimmed
        }

        components.host = resolvedHost
        if hasExplicitScheme {
            return components.string ?? trimmed
        }

        var rebuilt = resolvedHost
        if let port = components.port {
            rebuilt += ":\(port)"
        }

        let path = components.percentEncodedPath
        if !path.isEmpty, path != "/" {
            rebuilt += path
        }
        if let query = components.percentEncodedQuery, !query.isEmpty {
            rebuilt += "?\(query)"
        }
        if let fragment = components.percentEncodedFragment, !fragment.isEmpty {
            rebuilt += "#\(fragment)"
        }

        return rebuilt
    }

    static func runtimeURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host,
              let resolvedHost = resolvedHostIfNeeded(host) else {
            return url
        }

        components.host = resolvedHost
        return components.url ?? url
    }

    private static func resolvedHostIfNeeded(_ host: String) -> String? {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        guard normalized.lowercased().hasSuffix(".local") else { return nil }
        guard !isIPAddress(normalized) else { return nil }
        return resolveHostname(normalized)
    }

    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true }
        let parts = host.split(separator: ".")
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), (0...255).contains(value) else { return false }
            return true
        }
    }

    private static func resolveHostname(_ hostname: String) -> String? {
        lock.lock()
        if let cached = dnsCache[hostname] {
            lock.unlock()
            return cached.isEmpty ? nil : cached
        }
        lock.unlock()

        let resolved = resolveHostnameUncached(hostname) ?? ""

        lock.lock()
        dnsCache[hostname] = resolved
        lock.unlock()

        return resolved.isEmpty ? nil : resolved
    }

    private static func resolveHostnameUncached(_ hostname: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        defer {
            if result != nil {
                freeaddrinfo(result)
            }
        }

        guard status == 0, let info = result else { return nil }

        var firstUsableIPv6: String?
        var addr: UnsafeMutablePointer<addrinfo>? = info
        while let current = addr {
            switch Int32(current.pointee.ai_family) {
            case AF_INET:
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var socketAddress = current.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                inet_ntop(AF_INET, &socketAddress.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                let candidate = String(cString: buffer)
                if isUsableIPv4Address(socketAddress) {
                    return candidate
                }
            case AF_INET6:
                var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                var socketAddress = current.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                inet_ntop(AF_INET6, &socketAddress.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
                let candidate = String(cString: buffer)
                if firstUsableIPv6 == nil, isUsableIPv6Address(socketAddress) {
                    firstUsableIPv6 = candidate
                }
            default:
                break
            }
            addr = current.pointee.ai_next
        }

        return firstUsableIPv6
    }

    private static func isUsableIPv4Address(_ address: sockaddr_in) -> Bool {
        let hostOrder = UInt32(bigEndian: address.sin_addr.s_addr)
        let first = UInt8((hostOrder >> 24) & 0xff)
        let second = UInt8((hostOrder >> 16) & 0xff)
        let third = UInt8((hostOrder >> 8) & 0xff)
        let fourth = UInt8(hostOrder & 0xff)
        let octets = [first, second, third, fourth]
        let isUnspecified = octets.allSatisfy { $0 == 0 }
        let isLoopback = first == 127
        let isLinkLocal = first == 169 && second == 254
        let isBroadcast = octets.allSatisfy { $0 == 255 }

        return !isUnspecified && !isLoopback && !isLinkLocal && !isBroadcast
    }

    private static func isUsableIPv6Address(_ address: sockaddr_in6) -> Bool {
        let bytes = withUnsafeBytes(of: address.sin6_addr.__u6_addr.__u6_addr8, Array.init)
        guard bytes.count == 16 else { return false }

        let isUnspecified = bytes.allSatisfy { $0 == 0 }
        let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
        let isLinkLocal = bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80
        let isMulticast = bytes[0] == 0xff

        return !isUnspecified && !isLoopback && !isLinkLocal && !isMulticast
    }
}

struct ServerBackupPayload: Codable {
    let app: String
    let version: Int
    let exportedAt: TimeInterval
    let includesSensitiveValues: Bool
    let servers: [ServerBackupEntry]
}

struct ServerBackupEntry: Codable {
    var name: String
    var address: String
    var port: Int?
    var useSSL: Bool
    var type: ServerConfig.ServerType
    var username: String?
    var workgroup: String?
    var lastAccessed: Date?

    init(server: ServerConfig) {
        self.name = server.name
        self.address = server.address
        self.port = server.port
        self.useSSL = server.useSSL
        self.type = server.type
        self.username = server.username
        self.workgroup = server.workgroup
        self.lastAccessed = server.lastAccessed
    }

    func serverConfig() -> ServerConfig {
        ServerConfig(
            name: name,
            address: address,
            port: port,
            useSSL: useSSL,
            type: type,
            username: username,
            passwordSecret: nil,
            workgroup: workgroup,
            accessToken: nil,
            userId: nil,
            customEPGURL: nil,
            lastAccessed: lastAccessed
        )
    }
}

struct ServerImportResult {
    let importedCount: Int
    let skippedCount: Int
}

struct ICloudServerListPayload: Codable, Equatable {
    let updatedAt: TimeInterval
    let servers: [ServerConfig]
    let privacySpace: PrivacySpaceSnapshot?

    init(
        updatedAt: TimeInterval,
        servers: [ServerConfig],
        privacySpace: PrivacySpaceSnapshot? = nil
    ) {
        self.updatedAt = updatedAt
        self.servers = servers
        self.privacySpace = privacySpace
    }
}

struct PersistedServerListSnapshot: Codable, Equatable {
    let updatedAt: TimeInterval
    let servers: [ServerConfig]
}

struct ICloudServerListSyncResolution: Equatable {
    let servers: [ServerConfig]
    let removedServerIDs: [UUID]
    let updatedAt: TimeInterval
}

struct ICloudServerListDebugState: Equatable {
    enum RemoteSnapshotStatus: Equatable {
        case missing
        case trusted
        case ignoredFutureTimestamp
    }

    let localUpdatedAt: TimeInterval
    let remoteUpdatedAt: TimeInterval?
    let lastAppliedRemoteUpdatedAt: TimeInterval
    let remoteSnapshotStatus: RemoteSnapshotStatus
    let remoteFutureSkew: TimeInterval?
    let localPersistedServers: [ICloudServerListDebugServerEntry]
    let localRuntimeServers: [ICloudServerListDebugServerEntry]
    let remoteServers: [ICloudServerListDebugServerEntry]
}

struct ICloudServerListDebugServerEntry: Identifiable, Equatable {
    let server: ServerConfig
    let hasPasswordInKeychain: Bool?
    let hasAccessTokenInKeychain: Bool?

    var id: UUID { server.id }
}

enum ICloudServerListSyncResolver {
    static func resolve(
        localServers: [ServerConfig],
        localUpdatedAt: TimeInterval,
        remotePayload: ICloudServerListPayload?
    ) -> ICloudServerListSyncResolution? {
        guard let remotePayload else { return nil }
        guard remotePayload.updatedAt > localUpdatedAt else { return nil }

        let mergedServers = remotePayload.servers.map { remote in
            guard let local = localServers.first(where: { $0.id == remote.id }) else {
                return remote
            }

            var hydrated = remote
            hydrated.passwordSecret = local.passwordSecret
            hydrated.accessToken = local.accessToken
            if let localAccess = local.lastAccessed, let remoteAccess = remote.lastAccessed {
                hydrated.lastAccessed = max(localAccess, remoteAccess)
            } else {
                hydrated.lastAccessed = remote.lastAccessed ?? local.lastAccessed
            }
            return hydrated
        }

        let removedServerIDs = localServers.map(\.id).filter { localID in
            remotePayload.servers.contains(where: { $0.id == localID }) == false
        }

        return ICloudServerListSyncResolution(
            servers: mergedServers,
            removedServerIDs: removedServerIDs,
            updatedAt: remotePayload.updatedAt
        )
    }
}

class AppNetworkService: ObservableObject {
    static let shared = AppNetworkService()
    static let didUpdateServersNotification = Notification.Name("AppNetworkServiceDidUpdateServers")
    
    @Published var savedServers: [ServerConfig] = []
    
    var servers: [ServerConfig] {
        return savedServers
    }
    
    private let serversKey = "saved_servers"
    private let serverListUpdatedAtKey = "saved_servers_updated_at"
    private let credentialKeyPrefix = "server_credential"
    private let accessTokenKeyPrefix = "server_access_token"
    private let iCloudServerListSyncEnabledKey = "enableICloudServerListSync"
    private let lastICloudServerListSyncAtKey = "lastICloudServerListSyncAt"
    private let persistedServerListSnapshotFileName = "saved_servers_snapshot_v1.json"
    
    // SMB Client cache
    private var smbClients: [UUID: SMB2Manager] = [:]
    private let plexProbeSessionDelegate = PlexProbeTrustDelegate()

    // Plex probe session that trusts self-signed TLS certificates.
    // Used only during connection testing/probing.
    private lazy var plexProbeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        return URLSession(configuration: config, delegate: plexProbeSessionDelegate, delegateQueue: nil)
    }()
    
    // WebDAV Manager
    private let webdavManager = WebDAVManager()
    private let alistManager = AListManager()
    private let iCloudSyncService = ICloudServerListSyncService.shared
    private var iCloudPullDebounceWorkItem: DispatchWorkItem?
    private var lastICloudPullAttemptAt: TimeInterval = 0
    private var lastAppliedICloudPayloadUpdatedAt: TimeInterval = 0
    private var isApplyingICloudServerList = false
    private let minimumForegroundICloudPullInterval: TimeInterval = 8
    private let iCloudExternalChangeDebounceInterval: TimeInterval = 0.6
    private let maximumTrustedICloudFutureSkew: TimeInterval = 60 * 60 * 24
    
    init() {
        loadServers()
        registerForICloudSyncNotifications()
        reconcileICloudServerList(pushLocalIfNeeded: true)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDidUpdateServersNotification(_:)),
            name: Self.didUpdateServersNotification,
            object: nil
        )
    }

    @objc private func handleDidUpdateServersNotification(_ notification: Notification) {
        if let sender = notification.object as AnyObject?, sender === self {
            return
        }
        loadServers()
    }

    func reloadServers() {
        loadServers()
    }
    
    func addServer(_ server: ServerConfig) {
        savedServers.append(server)
        saveServers()
    }
    
    func deleteServer(_ server: ServerConfig) {
        savedServers.removeAll { $0.id == server.id }
        cleanupRemovedServerData(for: server)
        saveServers()
    }

    func clearAllServers() {
        let serversToDelete = savedServers
        guard !serversToDelete.isEmpty else { return }

        for server in serversToDelete {
            cleanupRemovedServerData(for: server)
        }

        savedServers.removeAll()
        saveServers()
    }

    func clearServers(of type: ServerConfig.ServerType) {
        let serversToDelete = savedServers.filter { $0.type == type }
        guard !serversToDelete.isEmpty else { return }

        for server in serversToDelete {
            cleanupRemovedServerData(for: server)
        }

        savedServers.removeAll { $0.type == type }
        saveServers()
    }

    func clearNonIPTVServers() {
        let serversToDelete = savedServers.filter { $0.type != .iptv }
        guard !serversToDelete.isEmpty else { return }

        for server in serversToDelete {
            cleanupRemovedServerData(for: server)
        }

        savedServers.removeAll { $0.type != .iptv }
        saveServers()
    }
    
    func updateServer(_ server: ServerConfig) {
        if let index = savedServers.firstIndex(where: { $0.id == server.id }) {
            var updated = server
            if updated.passwordSecret == nil {
                updated.passwordSecret = savedServers[index].passwordSecret ?? KeychainService.get(for: passwordKey(for: server.id))
            }
            if updated.accessToken == nil {
                updated.accessToken = savedServers[index].accessToken ?? KeychainService.get(for: accessTokenKey(for: server.id))
            }
            savedServers[index] = updated
            if updated.type == .smb {
                smbClients.removeValue(forKey: updated.id) // Invalidate cached client
            }
            saveServers()
        }
    }

    func recordServerAccess(_ serverId: UUID, date: Date = Date()) {
        guard let index = savedServers.firstIndex(where: { $0.id == serverId }) else { return }
        if let last = savedServers[index].lastAccessed, abs(last.timeIntervalSince(date)) < 5 {
            return
        }
        if Thread.isMainThread {
            savedServers[index].lastAccessed = date
            saveServers()
        } else {
            DispatchQueue.main.async {
                guard let idx = self.savedServers.firstIndex(where: { $0.id == serverId }) else { return }
                self.savedServers[idx].lastAccessed = date
                self.saveServers()
            }
        }
    }
    
    func moveServer(from source: IndexSet, to destination: Int) {
        savedServers.move(fromOffsets: source, toOffset: destination)
        saveServers()
    }
    
    func persistServers() {
        saveServers()
    }

    func exportServerBackupData() throws -> Data {
        let payload = ServerBackupPayload(
            app: "GenPlayer",
            version: 1,
            exportedAt: Date().timeIntervalSince1970,
            includesSensitiveValues: false,
            servers: savedServers.map { ServerBackupEntry(server: persistableServer(from: $0)) }
        )
        return try JSONEncoder().encode(payload)
    }

    func importServers(from data: Data) throws -> ServerImportResult {
        let importedEntries = try decodeServerBackupEntries(from: data)
        var existingFingerprints = Set(savedServers.map(serverImportFingerprint))
        var importedCount = 0
        var skippedCount = 0

        for entry in importedEntries {
            var server = entry.serverConfig()
            let fingerprint = serverImportFingerprint(server)
            if existingFingerprints.contains(fingerprint) {
                skippedCount += 1
                continue
            }

            server.id = UUID()
            savedServers.append(server)
            existingFingerprints.insert(fingerprint)
            importedCount += 1
        }

        if importedCount > 0 {
            saveServers()
        }

        return ServerImportResult(importedCount: importedCount, skippedCount: skippedCount)
    }
    
    private var localServerListUpdatedAt: TimeInterval {
        let userDefaultsValue = UserDefaults.standard.double(forKey: serverListUpdatedAtKey)
        let mirroredValue = persistedServerListSnapshot()?.updatedAt ?? 0
        return max(userDefaultsValue, mirroredValue)
    }

    func currentICloudServerListDebugState() -> ICloudServerListDebugState {
        let persistedServers = persistedLocalServerSnapshot()
        let runtimeServers = savedServers.map { server in
            ICloudServerListDebugServerEntry(
                server: persistableServer(from: server),
                hasPasswordInKeychain: (KeychainService.get(for: passwordKey(for: server.id))?.isEmpty == false),
                hasAccessTokenInKeychain: (KeychainService.get(for: accessTokenKey(for: server.id))?.isEmpty == false)
            )
        }
        let remotePayload = iCloudSyncService.pullPayload()
        let now = Date().timeIntervalSince1970
        let remoteFutureSkew = remotePayload.map { max(0, $0.updatedAt - now) }

        let remoteSnapshotStatus: ICloudServerListDebugState.RemoteSnapshotStatus
        switch remotePayload {
        case nil:
            remoteSnapshotStatus = .missing
        case let payload? where trustedICloudPayload(payload) != nil:
            remoteSnapshotStatus = .trusted
        default:
            remoteSnapshotStatus = .ignoredFutureTimestamp
        }

        return ICloudServerListDebugState(
            localUpdatedAt: localServerListUpdatedAt,
            remoteUpdatedAt: remotePayload?.updatedAt,
            lastAppliedRemoteUpdatedAt: lastAppliedICloudPayloadUpdatedAt,
            remoteSnapshotStatus: remoteSnapshotStatus,
            remoteFutureSkew: remoteFutureSkew,
            localPersistedServers: persistedServers.map {
                ICloudServerListDebugServerEntry(
                    server: $0,
                    hasPasswordInKeychain: nil,
                    hasAccessTokenInKeychain: nil
                )
            },
            localRuntimeServers: runtimeServers,
            remoteServers: (remotePayload?.servers ?? []).map {
                ICloudServerListDebugServerEntry(
                    server: $0,
                    hasPasswordInKeychain: nil,
                    hasAccessTokenInKeychain: nil
                )
            }
        )
    }

    private func persistedLocalServerSnapshot() -> [ServerConfig] {
        persistedServerListSnapshot()?.servers ?? []
    }

    private func persistedServerListSnapshot() -> PersistedServerListSnapshot? {
        let mirroredSnapshot = mirroredPersistedServerListSnapshot()
        let legacySnapshot = legacyPersistedServerListSnapshot()

        switch (mirroredSnapshot, legacySnapshot) {
        case (nil, nil):
            return nil
        case let (snapshot?, nil), let (nil, snapshot?):
            return snapshot
        case let (mirrored?, legacy?):
            if mirrored.updatedAt == legacy.updatedAt {
                return mirrored
            }
            return mirrored.updatedAt > legacy.updatedAt ? mirrored : legacy
        }
    }

    private func mirroredPersistedServerListSnapshot() -> PersistedServerListSnapshot? {
        guard let url = persistedServerListSnapshotFileURL(),
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(PersistedServerListSnapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }

    private func legacyPersistedServerListSnapshot() -> PersistedServerListSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: serversKey),
              let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) else {
            return nil
        }

        return PersistedServerListSnapshot(
            updatedAt: UserDefaults.standard.double(forKey: serverListUpdatedAtKey),
            servers: decoded
        )
    }

    private func persistedServerListSnapshotFileURL() -> URL? {
        let fileManager = FileManager.default
        guard let applicationSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }

        return applicationSupportDirectory
            .appendingPathComponent("NetworkService", isDirectory: true)
            .appendingPathComponent(persistedServerListSnapshotFileName)
    }

    @discardableResult
    private func persistServerListSnapshot(_ snapshot: PersistedServerListSnapshot) -> Bool {
        let encoder = JSONEncoder()
        guard let encodedSnapshot = try? encoder.encode(snapshot),
              let encodedServers = try? encoder.encode(snapshot.servers) else {
            return false
        }

        if let url = persistedServerListSnapshotFileURL() {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                try encodedSnapshot.write(to: url, options: .atomic)
            } catch {
                print("[NetworkService] Failed to mirror server snapshot to disk: \(error.localizedDescription)")
                return false
            }
        }

        UserDefaults.standard.set(encodedServers, forKey: serversKey)
        UserDefaults.standard.set(snapshot.updatedAt, forKey: serverListUpdatedAtKey)
        UserDefaults.standard.synchronize()
        return true
    }

    private func trustedICloudPayload(_ payload: ICloudServerListPayload?) -> ICloudServerListPayload? {
        guard let payload else { return nil }
        let now = Date().timeIntervalSince1970
        guard payload.updatedAt <= now + maximumTrustedICloudFutureSkew else {
            return nil
        }
        return payload
    }

    private func resolvedServerListUpdatedAt(
        requestedAt: TimeInterval,
        shouldPushToICloud: Bool,
        remotePayload: ICloudServerListPayload? = nil
    ) -> TimeInterval {
        guard shouldPushToICloud, isICloudServerListSyncEnabled else {
            return requestedAt
        }

        let remoteUpdatedAt = trustedICloudPayload(remotePayload ?? iCloudSyncService.pullPayload())?.updatedAt ?? 0
        guard remoteUpdatedAt > 0 else { return requestedAt }
        return max(requestedAt, remoteUpdatedAt + 1)
    }

    private func saveServers(
        updatedAt: TimeInterval? = nil,
        shouldPushToICloud: Bool = true
    ) {
        var keychainBackups: [String: String?] = [:]
        var didFailToPersistSensitiveValues = false
        let requestedUpdatedAt = updatedAt ?? Date().timeIntervalSince1970
        let effectiveUpdatedAt = resolvedServerListUpdatedAt(
            requestedAt: requestedUpdatedAt,
            shouldPushToICloud: shouldPushToICloud
        )

        for server in savedServers {
            let passwordStorageKey = passwordKey(for: server.id)
            let tokenStorageKey = accessTokenKey(for: server.id)

            if keychainBackups[passwordStorageKey] == nil {
                keychainBackups[passwordStorageKey] = KeychainService.get(for: passwordStorageKey)
            }
            if keychainBackups[tokenStorageKey] == nil {
                keychainBackups[tokenStorageKey] = KeychainService.get(for: tokenStorageKey)
            }

            let effectivePassword = server.passwordSecret ?? keychainBackups[passwordStorageKey] ?? nil
            let effectiveToken = server.accessToken ?? keychainBackups[tokenStorageKey] ?? nil

            guard writeSensitiveValue(effectivePassword, for: passwordStorageKey),
                  writeSensitiveValue(effectiveToken, for: tokenStorageKey) else {
                rollbackKeychain(from: keychainBackups)
                didFailToPersistSensitiveValues = true
                break
            }
        }

        let persistableServers = savedServers.map { persistableServer(from: $0) }
        let snapshot = PersistedServerListSnapshot(
            updatedAt: effectiveUpdatedAt,
            servers: persistableServers
        )

        guard persistServerListSnapshot(snapshot) else {
            rollbackKeychain(from: keychainBackups)
            print("[NetworkService] Failed to persist local server snapshot, rolled back sensitive values.")
            return
        }

        if shouldPushToICloud && isICloudServerListSyncEnabled {
            iCloudSyncService.pushServerList(
                persistableServers,
                updatedAt: effectiveUpdatedAt,
                privacySpace: PrivacySpaceService.shared.currentSnapshot
            )
            markICloudServerListSyncCompleted()
        }

        if didFailToPersistSensitiveValues {
            print("[NetworkService] Failed to save sensitive values to Keychain. Persisted the non-sensitive server snapshot and rolled back Keychain changes.")
        }

        NotificationCenter.default.post(name: Self.didUpdateServersNotification, object: self)
    }
    
    private func loadServers() {
        guard let snapshot = persistedServerListSnapshot() else {
            return
        }

        let decoded = snapshot.servers
        let persistedUpdatedAt = snapshot.updatedAt

        var didMigrateLegacySecrets = false
        let hydrated = decoded.map { server in
            var working = server
            if migrateLegacySensitiveValuesIfNeeded(for: &working) {
                didMigrateLegacySecrets = true
            }
            return hydratedServer(from: working)
        }

        self.savedServers = hydrated

        if legacyPersistedServerListSnapshot() != snapshot || mirroredPersistedServerListSnapshot() != snapshot {
            _ = persistServerListSnapshot(snapshot)
        }

        if didMigrateLegacySecrets {
            saveServers(
                updatedAt: persistedUpdatedAt > 0 ? persistedUpdatedAt : nil,
                shouldPushToICloud: false
            )
        }
    }

    private func persistableServer(from server: ServerConfig) -> ServerConfig {
        var persistable = server
        persistable.passwordSecret = nil
        persistable.accessToken = nil
        return persistable
    }

    func hydratedServer(from server: ServerConfig) -> ServerConfig {
        var hydrated = server
        hydrated.passwordSecret = server.passwordSecret ?? KeychainService.get(for: passwordKey(for: server.id))
        hydrated.accessToken = server.accessToken ?? KeychainService.get(for: accessTokenKey(for: server.id))
        return hydrated
    }

    private func writeSensitiveValue(_ value: String?, for key: String) -> Bool {
        if let value, !value.isEmpty {
            return KeychainService.set(value, for: key)
        }

        KeychainService.delete(for: key)
        return true
    }

    private func rollbackKeychain(from backups: [String: String?]) {
        for (key, value) in backups {
            if let value {
                _ = KeychainService.set(value, for: key)
            } else {
                KeychainService.delete(for: key)
            }
        }
    }

    private func migrateLegacySensitiveValuesIfNeeded(for server: inout ServerConfig) -> Bool {
        var migrated = false

        if let plaintextPassword = server.passwordSecret, !plaintextPassword.isEmpty,
           KeychainService.get(for: passwordKey(for: server.id)) == nil,
           KeychainService.set(plaintextPassword, for: passwordKey(for: server.id)) {
            migrated = true
        }

        if let plaintextToken = server.accessToken, !plaintextToken.isEmpty,
           KeychainService.get(for: accessTokenKey(for: server.id)) == nil,
           KeychainService.set(plaintextToken, for: accessTokenKey(for: server.id)) {
            migrated = true
        }

        if migrated {
            server.passwordSecret = nil
            server.accessToken = nil
        }

        return migrated
    }

    private func deleteSensitiveValues(for server: ServerConfig) {
        KeychainService.delete(for: passwordKey(for: server.id))
        KeychainService.delete(for: accessTokenKey(for: server.id))
    }

    private func cleanupRemovedServerData(for server: ServerConfig) {
        smbClients.removeValue(forKey: server.id)
        deleteSensitiveValues(for: server)
        HistoryService.shared.clearHistory(for: server)
        FavoriteService.shared.clearFavorites(for: server)
        Task { @MainActor in
            OfflineMediaIndexStore.shared.clearIndex(for: server.id)
        }
        PrivacySpaceService.shared.remove(server: server)
        if server.type == .iptv {
            IPTVService.shared.clearCache(for: server.id)
            EPGService.shared.clearCache(for: server.id)
            IPTVArtworkService.shared.clearSnapshots(for: server.id)
        }
    }

    private func registerForICloudSyncNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleICloudStoreDidChangeExternally(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePrivacySpaceMarksDidChange(_:)),
            name: PrivacySpaceService.didChangeMarksNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationWillEnterForeground(_:)),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func handleICloudStoreDidChangeExternally(_ notification: Notification) {
        scheduleICloudPull(trigger: .externalChange)
    }

    @objc private func handlePrivacySpaceMarksDidChange(_ notification: Notification) {
        guard isICloudServerListSyncEnabled else { return }
        guard !isApplyingICloudServerList else { return }
        saveServers()
    }

    @objc private func handleApplicationWillEnterForeground(_ notification: Notification) {
        scheduleICloudPull(trigger: .willEnterForeground)
    }

    private func reconcileICloudServerList(
        pushLocalIfNeeded: Bool,
        forceRefreshCurrentSnapshotVersion: Bool = false
    ) {
        guard isICloudServerListSyncEnabled else { return }
        let remotePayload = iCloudSyncService.pullPayload()
        let trustedRemotePayload = trustedICloudPayload(remotePayload)
        applyICloudServerListIfEnabled(remotePayload: trustedRemotePayload)

        let shouldPushCurrentServers = shouldPushCurrentServersToICloud(remotePayload: remotePayload)
        let shouldRefreshCurrentVersion = forceRefreshCurrentSnapshotVersion && !savedServers.isEmpty

        guard pushLocalIfNeeded,
              (shouldPushCurrentServers || shouldRefreshCurrentVersion) else {
            return
        }

        let requestedUpdatedAt: TimeInterval
        if shouldPushCurrentServers {
            requestedUpdatedAt = localServerListUpdatedAt > 0
                ? localServerListUpdatedAt
                : Date().timeIntervalSince1970
        } else {
            requestedUpdatedAt = Date().timeIntervalSince1970
        }
        let effectiveUpdatedAt = resolvedServerListUpdatedAt(
            requestedAt: requestedUpdatedAt,
            shouldPushToICloud: true,
            remotePayload: trustedRemotePayload
        )
        iCloudSyncService.pushServerList(
            savedServers.map { persistableServer(from: $0) },
            updatedAt: effectiveUpdatedAt,
            privacySpace: PrivacySpaceService.shared.currentSnapshot
        )
        _ = persistServerListSnapshot(
            PersistedServerListSnapshot(
                updatedAt: effectiveUpdatedAt,
                servers: savedServers.map { persistableServer(from: $0) }
            )
        )
        markICloudServerListSyncCompleted()
    }

    private func shouldPushCurrentServersToICloud(remotePayload: ICloudServerListPayload?) -> Bool {
        let persistableServers = savedServers.map { persistableServer(from: $0) }
        let currentPrivacySpace = PrivacySpaceService.shared.currentSnapshot

        if let remotePayload,
           trustedICloudPayload(remotePayload) == nil {
            return persistableServers != remotePayload.servers ||
                shouldPushPrivacySpaceSnapshot(
                    current: currentPrivacySpace,
                    remote: remotePayload.privacySpace
                )
        }

        let remotePayload = trustedICloudPayload(remotePayload)

        guard let remotePayload else {
            return !persistableServers.isEmpty || !currentPrivacySpace.isEmpty
        }

        if shouldPushPrivacySpaceSnapshot(
            current: currentPrivacySpace,
            remote: remotePayload.privacySpace
        ), localServerListUpdatedAt >= remotePayload.updatedAt {
            return true
        }

        if persistableServers != remotePayload.servers,
           localServerListUpdatedAt >= remotePayload.updatedAt {
            return true
        }

        return localServerListUpdatedAt > remotePayload.updatedAt
    }

    private func shouldPushPrivacySpaceSnapshot(
        current: PrivacySpaceSnapshot,
        remote: PrivacySpaceSnapshot?
    ) -> Bool {
        guard let remote else {
            return !current.isEmpty
        }
        return current != remote
    }

    private func invalidateCachesForUpdatedServers(
        oldServers: [ServerConfig],
        newServers: [ServerConfig]
    ) {
        for newServer in newServers where newServer.type == .smb {
            guard let oldServer = oldServers.first(where: { $0.id == newServer.id }) else { continue }
            guard persistableServer(from: oldServer) != persistableServer(from: newServer) else { continue }
            smbClients.removeValue(forKey: newServer.id)
        }
    }

    private func decodeServerBackupEntries(from data: Data) throws -> [ServerBackupEntry] {
        let decoder = JSONDecoder()

        if let payload = try? decoder.decode(ServerBackupPayload.self, from: data) {
            return payload.servers
        }

        if let legacyServers = try? decoder.decode([ServerConfig].self, from: data) {
            return legacyServers.map { ServerBackupEntry(server: persistableServer(from: $0)) }
        }

        throw NSError(
            domain: "GenPlayer",
            code: 2001,
            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Unsupported server backup format.", comment: "")]
        )
    }

    private func serverImportFingerprint(_ server: ServerConfig) -> String {
        let normalizedAddress = server.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedUsername = server.username?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedWorkgroup = server.workgroup?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let normalizedPort = server.port ?? ServerConfig.defaultPort(for: server.type, useSSL: server.useSSL)
        return [
            server.type.rawValue,
            normalizedAddress,
            String(normalizedPort),
            server.useSSL ? "1" : "0",
            normalizedUsername,
            normalizedWorkgroup
        ].joined(separator: "|")
    }

    private func passwordKey(for serverId: UUID) -> String {
        "\(credentialKeyPrefix)_\(serverId.uuidString)"
    }

    private func accessTokenKey(for serverId: UUID) -> String {
        "\(accessTokenKeyPrefix)_\(serverId.uuidString)"
    }
    
    // MARK: - SMB Connection
    
    private func createSMBClient(for server: ServerConfig) throws -> SMB2Manager {
        var components = URLComponents()
        components.scheme = "smb"
        
        var cleanAddress = server.address.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanAddress.hasPrefix("smb://") {
            cleanAddress = String(cleanAddress.dropFirst(6))
        }

        cleanAddress = RuntimeNetworkAddressResolver.runtimeAddress(from: cleanAddress)
        
        components.host = cleanAddress
        
        guard let url = components.url else {
            throw NSError(domain: "GenPlayer", code: 1001, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid server address", comment: "") + ": \(server.address)"])
        }
        
        let credential = URLCredential(
            user: server.username ?? "guest",
            password: server.passwordSecret ?? "",
            persistence: .forSession
        )
        
        guard let client = SMB2Manager(url: url, credential: credential) else {
            throw NSError(domain: "GenPlayer", code: 1002, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to initialize SMB client", comment: "")])
        }
        
        return client
    }
    
    private func getClient(for server: ServerConfig) throws -> SMB2Manager {
        if let client = smbClients[server.id] {
            return client
        }
        
        let client = try createSMBClient(for: server)
        smbClients[server.id] = client
        return client
    }
    
    func clearServerAuthTokens(for serverId: UUID) {
        if let index = savedServers.firstIndex(where: { $0.id == serverId }) {
            savedServers[index].accessToken = nil
            savedServers[index].userId = nil
            saveServers()
        }
        KeychainService.delete(for: accessTokenKey(for: serverId))
    }

    // MARK: - Connection Testing
    
    func testConnection(_ server: ServerConfig) async throws -> ServerConfig {
        var updatedServer = server
        
        do {
            switch server.type {
            case .smb:
                // Create a fresh client to test current credentials (bypass cache)
                let client = try createSMBClient(for: server)
                let _ = try await client.listShares()

            case .webdav:
                // WebDAV manager uses provided server config directly, so it's safe
                let _ = try await webdavManager.listFiles(server: server, at: "/")

            case .alist:
                let token = try await alistManager.login(server: server)
                updatedServer.accessToken = token
                let _ = try await alistManager.listFiles(server: server, at: "/", token: token)

            case .pan115:
                let cookie = server.passwordSecret ?? server.accessToken ?? ""
                guard !cookie.isEmpty else {
                    throw NSError(domain: "Pan115", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Missing 115 Cookie", comment: "")])
                }
                let ok = try await Pan115Manager.shared.checkLogin(cookie: cookie)
                guard ok else {
                    throw NSError(domain: "Pan115", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("115 Cookie is invalid or expired", comment: "")])
                }

            case .onedrive:
                let ok = try await OneDriveManager.shared.testConnection(server: server)
                guard ok else {
                    throw NSError(domain: "OneDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("OneDrive connection failed or token expired", comment: "")])
                }

            case .googledrive:
                let ok = try await GoogleDriveManager.shared.testConnection(server: server)
                guard ok else {
                    throw NSError(domain: "GoogleDrive", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Google Drive connection failed or token expired", comment: "")])
                }

            case .ftp:
                try await FTPBrowserService.shared.testConnection(server: server)
                
            case .nfs:
                try await NFSBrowserService.shared.testConnection(server: server)
                
            case .sftp:
                try await SFTPBrowserService.shared.testConnection(server: server)
                
            case .jellyfin:
                if let username = server.username, !username.isEmpty,
                   let password = server.passwordSecret {
                    let result = try await JellyfinService.shared.login(server: server, username: username, password: password)
                    updatedServer.accessToken = result.accessToken
                    updatedServer.userId = result.user.id
                } else {
                    throw NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Please provide username and password to test Jellyfin connection", comment: "")])
                }
                
            case .emby:
                if let username = server.username, !username.isEmpty,
                   let password = server.passwordSecret {
                    let result = try await EmbyService.shared.login(server: server, username: username, password: password)
                    updatedServer.accessToken = result.accessToken
                    updatedServer.userId = result.user.id
                } else {
                    throw NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Please provide username and password to test Emby connection", comment: "")])
                }
                
            case .plex:
                let token1 = server.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
                let token2 = server.passwordSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
                let validToken1 = token1?.isEmpty == false ? token1 : nil
                let validToken2 = token2?.isEmpty == false ? token2 : nil
                let token = validToken1 ?? validToken2
                updatedServer = try await testPlexConnection(server, token: token)
                if updatedServer.accessToken == nil, let token {
                    updatedServer.accessToken = token
                }
            case .iptv:
                do {
                    _ = try await IPTVService.shared.fetchPlaylist(for: server, forceRefresh: true)
                } catch {
                    if IPTVService.shared.cachedPlaylist(for: server.id) == nil {
                        throw error
                    }
                }
            case .vod:
                // Validate the actual paged catalog, not only its optional category list.
                let result = try await VODService.shared.fetchList(server: server, page: 1)
                MediaServerSummaryService.shared.updateSummary(
                    for: server.id,
                    libraryCount: result.totalCount
                )
            }

            return updatedServer
        } catch {
            let isAuthError: Bool = {
                if let jErr = error as? JellyfinError, case .unauthorized = jErr { return true }
                if let eErr = error as? EmbyError, case .unauthorized = eErr { return true }
                if let pErr = error as? PlexError, case .unauthorized = pErr { return true }
                let ns = error as NSError
                return ns.code == 401 || ns.code == 403
            }()
            if isAuthError {
                clearServerAuthTokens(for: server.id)
            }

            // Map common errors to user-friendly messages
            let nsError = error as NSError

            // Check for POSIX error 1 (EPERM) or 13 (EACCES)
            // Code 1 often means Local Network Permission denied, but can also be "Operation not permitted" for bad auth in some libraries.
            // Code 13 is standard "Permission denied".
            if nsError.domain == NSPOSIXErrorDomain && (nsError.code == 1 || nsError.code == 13) {
                throw NSError(
                    domain: "GenPlayer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Access Denied. Please check your username/password. If credentials are correct, ensure GenPlayer has Local Network access permission in Settings.", comment: "")]
                )
            }

            if let mappedError = mapNetworkConnectionError(error, server: server) {
                throw mappedError
            }
            
            // Re-throw with original or slightly improved message
            throw error
        }
    }

    private func mapNetworkConnectionError(_ error: Error, server: ServerConfig) -> NSError? {
        let nsError = error as NSError
        let configuredHost = URLComponents(string: server.fullURL)?.host ?? server.address

        let failingHost: String? = {
            if let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
                return url.host
            }
            if let urlString = nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String {
                return URL(string: urlString)?.host
            }
            return nil
        }()

        if nsError.domain == NSURLErrorDomain {
            let certCodes: Set<Int> = [
                NSURLErrorServerCertificateUntrusted,
                NSURLErrorServerCertificateHasBadDate,
                NSURLErrorServerCertificateHasUnknownRoot,
                NSURLErrorServerCertificateNotYetValid,
                NSURLErrorSecureConnectionFailed
            ]
            if certCodes.contains(nsError.code) {
                return tlsCertificateError(configuredHost: configuredHost, failingHost: failingHost, code: nsError.code)
            }

            if nsError.code == NSURLErrorTimedOut {
                return NSError(
                    domain: "GenPlayer",
                    code: nsError.code,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Connection timed out. Please check server address, port, and network status.", comment: "")]
                )
            }
        }

        let localized = nsError.localizedDescription.lowercased()
        if localized.contains("certificate")
            || localized.contains("ssl")
            || localized.contains("tls")
            || localized.contains("证书")
            || localized.contains("安全连接") {
            return tlsCertificateError(configuredHost: configuredHost, failingHost: failingHost, code: nsError.code)
        }

        return nil
    }

    private func tlsCertificateError(configuredHost: String, failingHost: String?, code: Int) -> NSError {
        if let failingHost, !failingHost.isEmpty, failingHost != configuredHost {
            return NSError(
                domain: "GenPlayer",
                code: code,
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        format: NSLocalizedString("TLS certificate validation failed. Configured host \"%1$@\" was redirected to \"%2$@\". Please use the final host directly, or fix reverse proxy TLS/SNI settings.", comment: ""),
                        configuredHost,
                        failingHost
                    )
                ]
            )
        }

        return NSError(
            domain: "GenPlayer",
            code: code,
            userInfo: [
                NSLocalizedDescriptionKey: String(
                    format: NSLocalizedString("TLS certificate validation failed for \"%@\". Please verify certificate validity, hostname matching, and full certificate chain (including intermediate CA).", comment: ""),
                    configuredHost
                )
            ]
        )
    }

    // MARK: - Remote Browsing
    
    /// Fetch contents at the given path
    /// - For SMB: path "/" returns list of shares, path "/ShareName/Folder" returns files
    /// - For WebDAV: path is relative to baseURL
    func fetchContents(for server: ServerConfig, at path: String = "/") async throws -> [VideoFile] {
        switch server.type {
        case .smb:
            let client = try getClient(for: server)
            
            if path == "/" {
                return try await listShares(client: client, server: server)
            } else {
                return try await listDirectory(client: client, server: server, path: path)
            }
            
        case .webdav:
            return try await webdavManager.listFiles(server: server, at: path)
        case .alist:
            return try await performAListOperation(for: server) { token in
                try await self.alistManager.listFiles(server: server, at: path, token: token)
            }

        case .pan115:
            let cookie = server.passwordSecret ?? server.accessToken ?? ""
            return try await Pan115Manager.shared.listFiles(server: server, at: path, cookie: cookie)

        case .onedrive:
            return try await OneDriveManager.shared.listFiles(server: server, at: path)

        case .googledrive:
            return try await GoogleDriveManager.shared.listFiles(server: server, at: path)

        case .ftp:
            return try await FTPBrowserService.shared.listFiles(server: server, at: path)

        case .nfs:
            return try await NFSBrowserService.shared.listFiles(server: server, at: path)
            
        case .sftp:
            return try await SFTPBrowserService.shared.listFiles(server: server, at: path)
            
        default:
            throw NSError(
                domain: "AppNetworkService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Browsing is not supported for this server type yet", comment: "")]
            )
        }
    }
    
    private func listShares(client: SMB2Manager, server: ServerConfig) async throws -> [VideoFile] {
        // AMMSMB2 listShares likely handles strictly necessary connections internally.
        // Explicitly connecting to IPC$ might fail for some configs (e.g. macOS Guest).
        
        let shares = try await client.listShares()
        
        // Filter out system shares (those ending with $)
        // listShares returns [(name: String, comment: String)]
        let userShares = shares.filter { !$0.name.hasSuffix("$") }
        
        return userShares.compactMap { share in
            // Percent-encode share name to handle spaces, Chinese characters, etc.
            let encodedShareName = share.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? share.name
            guard let shareURL = URL(string: "smb://\(server.address)/\(encodedShareName)") else {
                return nil
            }
            var file = VideoFile(
                name: share.name,
                url: shareURL,
                type: .folder,
                size: 0,
                date: Date(),
                duration: nil
            )
            file.isRemote = true
            file.serverType = server.type
            file.jellyfinServerId = server.id.uuidString
            return file
        }
    }
    
    private func listDirectory(client: SMB2Manager, server: ServerConfig, path: String) async throws -> [VideoFile] {
        // Extract share name and relative path
        // Path format: "/ShareName" or "/ShareName/Folder/SubFolder"
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let shareName = components.first else {
            return []
        }
        
        let relativePath = components.dropFirst().joined(separator: "/")
        
        // Connect to the share
        try await client.connectShare(name: String(shareName))
        
        // List directory contents
        let entries = try await client.contentsOfDirectory(atPath: relativePath.isEmpty ? "" : relativePath)
        
        var files: [VideoFile] = []
        
        for entry in entries {
            guard let name = entry[.nameKey] as? String,
                  name != "." && name != ".." else {
                continue
            }
            
            let resourceType = entry[.fileResourceTypeKey] as? URLFileResourceType
            let isDirectory = resourceType == .directory
            let size = entry[.fileSizeKey] as? Int64 ?? 0
            let modDate = entry[.contentModificationDateKey] as? Date ?? Date()
            
            // Determine file type
            let fileType: VideoFile.FileType
            if isDirectory {
                fileType = .folder
            } else {
                fileType = VideoFile.FileType.determineType(from: URL(fileURLWithPath: name))
            }
            
            // Construct full path for URL
            let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
            // Build SMB URL with credentials for VLC playback
            let smbURL = buildSMBURL(server: server, path: fullPath)
            
            var file = VideoFile(
                name: name,
                url: smbURL,
                type: fileType,
                size: size,
                date: modDate,
                duration: nil
            )
            file.isRemote = true
            file.serverType = server.type
            file.jellyfinServerId = server.id.uuidString
            files.append(file)
        }
        
        return files
    }
    
    /// Build an SMB URL with embedded credentials for VLC playback
    private func buildSMBURL(server: ServerConfig, path: String) -> URL {
        var urlString = "smb://"
        
        // Add credentials if available
        if let username = server.username, !username.isEmpty {
            let encodedUser = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            urlString += encodedUser
            
            if let password = server.passwordSecret, !password.isEmpty {
                let encodedPass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
                urlString += ":\(encodedPass)"
            }
            urlString += "@"
        }
        
        // Keep the original host in persisted/playback-facing SMB URLs so history/favorites
        // continue to use the same identity even if runtime connections resolve .local to IP.
        urlString += server.address
        
        // Percent-encode path to handle Chinese characters, spaces, etc.
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        urlString += encodedPath
        
        
        if let url = URL(string: urlString) {
            return url
        }
        
        return URL(fileURLWithPath: path)
    }
    
    // MARK: - File Operations

    private func ensureRemoteMutationAllowed(for serverType: ServerConfig.ServerType) throws {
        guard serverType.supportsRemoteMutationOperations else {
            throw NSError(
                domain: "AppNetworkService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("This server type doesn't support file modifications.", comment: "")]
            )
        }

        guard UserDefaults.standard.bool(forKey: "allowRemoteMutationOperations") else {
            throw NSError(
                domain: "AppNetworkService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Remote file modifications are disabled in Settings > Advanced.", comment: "")]
            )
        }
    }
    
    func deleteFile(server: ServerConfig, at path: String) async throws {
        try ensureRemoteMutationAllowed(for: server.type)
        switch server.type {
        case .smb:
            let client = try getClient(for: server)
            let (share, relativePath) = parsePath(path)
            
            try await client.connectShare(name: share)
            try await client.removeItem(atPath: relativePath)
            
        case .webdav:
            try await webdavManager.deleteFile(server: server, at: path)
        case .alist:
            try await performAListOperation(for: server) { token in
                try await self.alistManager.deleteFile(server: server, at: path, token: token)
            }
        case .pan115:
            let cookie = server.passwordSecret ?? server.accessToken ?? ""
            try await Pan115Manager.shared.deleteFile(server: server, at: path, cookie: cookie)
        case .onedrive:
            try await OneDriveManager.shared.deleteItem(server: server, at: path)
        case .googledrive:
            try await GoogleDriveManager.shared.deleteItem(server: server, at: path)
        case .ftp, .sftp, .nfs:
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Delete is not supported for this server type", comment: "")])
            
        default:
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Delete is not supported for this server type", comment: "")])
        }
    }
    
    func moveFile(server: ServerConfig, fromPath: String, toPath: String) async throws {
        try ensureRemoteMutationAllowed(for: server.type)
        switch server.type {
        case .smb:
            // Note: AMSMB2 move requires source and destination to be on the same share
            let client = try getClient(for: server)
            let (share1, relativePath1) = parsePath(fromPath)
            let (share2, relativePath2) = parsePath(toPath)
            
            guard share1 == share2 else {
                throw NSError(domain: "GenPlayer", code: 1003, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Move only supported within the same share", comment: "")])
            }
            
            try await client.connectShare(name: share1)
            try await client.moveItem(atPath: relativePath1, toPath: relativePath2)
            
        case .webdav:
            let normalizedFrom = fromPath.hasPrefix("/") ? String(fromPath.dropFirst()) : fromPath
            let normalizedTo = toPath.hasPrefix("/") ? String(toPath.dropFirst()) : toPath
            try await webdavManager.moveFile(server: server, fromPath: normalizedFrom, toPath: normalizedTo)

        case .alist:
            let normalizedFrom = fromPath.hasPrefix("/") ? String(fromPath.dropFirst()) : fromPath
            let normalizedTo = toPath.hasPrefix("/") ? String(toPath.dropFirst()) : toPath
            try await performAListOperation(for: server) { token in
                try await self.alistManager.moveFile(server: server, fromPath: normalizedFrom, toPath: normalizedTo, token: token)
            }

        case .ftp, .sftp, .nfs:
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Move is not supported for this server type", comment: "")])
            
        default:
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Move is not supported for this server type", comment: "")])
        }
    }
    
    private struct PlexProbeCandidate {
        let useSSL: Bool
        let port: Int
        let baseURL: URL
    }

    private func testPlexConnection(_ server: ServerConfig, token: String?) async throws -> ServerConfig {
        guard URLComponents(string: server.fullURL) != nil else {
            throw NSError(
                domain: "GenPlayer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid Plex server address", comment: "")]
            )
        }

        let cleanedToken: String? = {
            guard let token = token?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
                return nil
            }
            return token
        }()

        guard let cleanedToken else {
            throw NSError(
                domain: "GenPlayer",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Plex server is reachable, but authorization failed. Please check token/sign-in.", comment: "")]
            )
        }

        let probePaths: [String] = ["/library/sections"]
        let candidates = plexProbeCandidates(for: server)

        var sawUnauthorized = false
        var lastStatusCode: Int?
        var lastError: Error?

        for candidate in candidates {
            for path in probePaths {
                guard let url = plexProbeURL(baseURL: candidate.baseURL, path: path) else { continue }

                do {
                    let statusCode = try await plexStatusCode(
                        url: url,
                        token: cleanedToken
                    )

                    if (200...299).contains(statusCode) {
                        var resolved = server
                        resolved.useSSL = candidate.useSSL
                        resolved.port = candidate.port
                        return resolved
                    }

                    if statusCode == 401 || statusCode == 403 {
                        sawUnauthorized = true
                    }
                    lastStatusCode = statusCode
                } catch {
                    lastError = error
                }
            }
        }

        if sawUnauthorized {
            throw NSError(
                domain: "GenPlayer",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Plex server is reachable, but authorization failed. Please check token/sign-in.", comment: "")]
            )
        }

        if let code = lastStatusCode {
            let description: String
            if code == 502 || code == 503 || code == 504 {
                description = NSLocalizedString("Plex server is reachable, but unavailable (gateway/service error). Please check HTTPS and port settings.", comment: "")
            } else {
                description = String(format: NSLocalizedString("Plex server responded with status code %d", comment: ""), code)
            }
            throw NSError(
                domain: "GenPlayer",
                code: code,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }

        if let lastError {
            throw lastError
        }

        throw NSError(
            domain: "GenPlayer",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Plex server returned an invalid response", comment: "")]
        )
    }

    private func plexProbeCandidates(for server: ServerConfig) -> [PlexProbeCandidate] {
        guard let base = URLComponents(string: server.fullURL),
              let host = base.host else {
            return []
        }

        let configuredUseSSL = (base.scheme?.lowercased() == "https")
        let configuredPort = server.port ?? base.port ?? ServerConfig.defaultPort(for: .plex, useSSL: configuredUseSSL)
        let basePath = base.path == "/" ? "" : base.path
        let fallbackCombos: [(Bool, Int)] = [
            (configuredUseSSL, configuredPort),
            (!configuredUseSSL, configuredPort),
            (false, 32400),
            (true, 32400),
            (true, 443)
        ]

        var seen = Set<String>()
        var candidates: [PlexProbeCandidate] = []

        for (useSSL, port) in fallbackCombos {
            let key = "\(useSSL ? "https" : "http"):\(port)"
            if seen.contains(key) {
                continue
            }
            seen.insert(key)

            var components = URLComponents()
            components.scheme = useSSL ? "https" : "http"
            components.host = host
            components.port = port
            components.path = basePath

            guard let url = components.url else { continue }
            candidates.append(PlexProbeCandidate(useSSL: useSSL, port: port, baseURL: url))
        }

        return candidates
    }

    private func plexProbeURL(baseURL: URL, path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let basePath = components.path
        if basePath.isEmpty || basePath == "/" {
            components.path = normalizedPath
        } else {
            let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            components.path = "\(trimmedBase)\(normalizedPath)"
        }
        return components.url
    }

    private func plexStatusCode(url: URL, token: String?) async throws -> Int {
        let systemVersion = await MainActor.run { UIDevice.current.systemVersion }
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let clientIdentifier = plexClientIdentifier()

        var requestURL = url
        if let token, !token.isEmpty,
           var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = components.queryItems ?? []
            if !items.contains(where: { $0.name == "X-Plex-Token" }) {
                items.append(URLQueryItem(name: "X-Plex-Token", value: token))
            }
            components.queryItems = items
            if let withToken = components.url {
                requestURL = withToken
            }
        }

        var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: requestURL))
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("GenPlayer", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("GenPlayer-iOS", forHTTPHeaderField: "X-Plex-Device")
        request.setValue(systemVersion, forHTTPHeaderField: "X-Plex-Platform-Version")
        request.setValue(appVersion, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")

        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }

        // Use a session that trusts self-signed certificates.
        // Plex Media Server uses self-signed TLS certs for local network access
        // and may redirect HTTP → HTTPS, so we must accept them during probing.
        let (_, response) = try await plexProbeSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(
                domain: "GenPlayer",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Plex server returned an invalid response", comment: "")]
            )
        }
        return httpResponse.statusCode
    }

    private func plexClientIdentifier() -> String {
        let key = "PlexDeviceId"
        if let stored = UserDefaults.standard.string(forKey: key), !stored.isEmpty {
            return stored
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }

    func createFolder(server: ServerConfig, at path: String) async throws {
        try ensureRemoteMutationAllowed(for: server.type)
        switch server.type {
        case .smb:
            let client = try getClient(for: server)
            let (share, relativePath) = parsePath(path)
            
            guard !share.isEmpty else {
                throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid SMB destination", comment: "")])
            }
            
            try await client.connectShare(name: share)
            try await client.createDirectory(atPath: relativePath)
            
        case .webdav:
            let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
            try await webdavManager.createFolder(server: server, at: normalizedPath)
            
        case .alist:
            let normalizedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
            try await performAListOperation(for: server) { token in
                try await self.alistManager.createFolder(server: server, at: normalizedPath, token: token)
            }

        case .pan115:
            let cookie = server.passwordSecret ?? server.accessToken ?? ""
            let normalized = Pan115Manager.shared.normalizePath(path)
            let parentPath = (normalized as NSString).deletingLastPathComponent
            let name = (normalized as NSString).lastPathComponent
            try await Pan115Manager.shared.createDirectory(server: server, at: parentPath, name: name, cookie: cookie)

        case .onedrive:
            let normalized = OneDriveManager.shared.normalizePath(path)
            let parentPath = (normalized as NSString).deletingLastPathComponent
            let name = (normalized as NSString).lastPathComponent
            try await OneDriveManager.shared.createFolder(server: server, at: parentPath, name: name)

        case .googledrive:
            let normalized = GoogleDriveManager.shared.normalizePath(path)
            let parentPath = (normalized as NSString).deletingLastPathComponent
            let name = (normalized as NSString).lastPathComponent
            try await GoogleDriveManager.shared.createFolder(server: server, at: parentPath, name: name)

        default:
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Create folder is not supported for this server type", comment: "")])
        }
    }
    
    func downloadFile(
        server: ServerConfig,
        at path: String,
        progress: ((Int64, Int64) -> Void)?
    ) async throws -> URL {
        switch server.type {
        case .smb:
            let client = try getClient(for: server)
            let (share, relativePath) = parsePath(path)

            try await client.connectShare(name: share)

            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)

            let fileName = URL(fileURLWithPath: path).lastPathComponent
            let destinationURL = tempDir.appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try await client.downloadItem(atPath: relativePath, to: destinationURL, progress: { downloaded, total in
                progress?(Int64(downloaded), Int64(total))
                return !Task.isCancelled
            })
            return destinationURL

        case .webdav:
            // WebDAV currently downloads via URLSession.data(for:), without byte-level callback
            return try await webdavManager.downloadFile(server: server, at: path)
            
        case .alist:
            return try await performAListOperation(for: server) { token in
                try await self.alistManager.downloadFile(server: server, at: path, token: token)
            }

        case .pan115:
            let cookie = server.passwordSecret ?? server.accessToken ?? ""
            let directURL = try await Pan115Manager.shared.rawDownloadURL(server: server, at: path, cookie: cookie)
            var req = URLRequest(url: directURL)
            req.setValue(Pan115Manager.defaultUserAgent, forHTTPHeaderField: "User-Agent")
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            return try await performHTTPDownload(request: req, suggestedFilename: fileName, progress: progress)

        case .onedrive:
            let directURL = try await OneDriveManager.shared.rawDownloadURL(server: server, at: path)
            let req = URLRequest(url: directURL)
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            return try await performHTTPDownload(request: req, suggestedFilename: fileName, progress: progress)

        case .googledrive:
            return try await GoogleDriveManager.shared.downloadFile(server: server, at: path, progress: progress)

        case .ftp:
            return try await FTPBrowserService.shared.downloadFile(server: server, at: path, progress: progress)

        case .sftp:
            return try await SFTPBrowserService.shared.downloadFile(server: server, at: path, progress: progress)
            
        case .nfs:
#if canImport(NFSKit)
            return try await NFSBrowserService.shared.downloadFile(server: server, at: path, progress: progress)
#else
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Download not supported for this server type (NFSKit missing)", comment: "")])
#endif

        case .jellyfin, .emby, .plex:
            return try await downloadMediaServerFile(server: server, at: path, progress: progress)
        case .iptv, .vod:
            throw NSError(domain: "NetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Download is not supported for this server type.", comment: "")])
        }
    }

    func downloadFile(server: ServerConfig, at path: String) async throws -> URL {
        try await downloadFile(server: server, at: path, progress: nil)
    }

    // MARK: - AList Helpers
    private func isAListTokenError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == "AListManager" {
            if nsError.code == 401 || nsError.code == 403 {
                return true
            }
        }
        let message = nsError.localizedDescription.lowercased()
        if message.contains("token is expired") ||
           message.contains("invalid token") ||
           message.contains("authentication failed") ||
           message.contains("unauthorized") {
            return true
        }
        if message.contains("token") && message.contains("expire") {
            return true
        }
        return false
    }

    private func getAListToken(for server: ServerConfig, forceRefresh: Bool = false) async throws -> String {
        let currentServer = savedServers.first(where: { $0.id == server.id }) ?? server
        if !forceRefresh, let token = currentServer.accessToken, !token.isEmpty {
            return token
        }
        
        do {
            let newToken = try await alistManager.login(server: currentServer)
            var updatedServer = currentServer
            updatedServer.accessToken = newToken
            updateServer(updatedServer)
            return newToken
        } catch {
            if forceRefresh || currentServer.accessToken != nil {
                var updatedServer = currentServer
                updatedServer.accessToken = nil
                updateServer(updatedServer)
            }
            throw error
        }
    }

    private func performAListOperation<T>(for server: ServerConfig, operation: (String) async throws -> T) async throws -> T {
        let token = try await getAListToken(for: server, forceRefresh: false)
        do {
            return try await operation(token)
        } catch {
            if isAListTokenError(error) {
                let freshToken = try await getAListToken(for: server, forceRefresh: true)
                return try await operation(freshToken)
            }
            throw error
        }
    }

    func resolvedPlaybackFile(_ file: VideoFile) async throws -> VideoFile {
        guard file.isRemote,
              let serverID = file.jellyfinServerId,
              let server = savedServers.first(where: { $0.id.uuidString == serverID }) else {
            return file
        }

        let path = file.serverPath ?? file.url.path
        guard !path.isEmpty else { return file }

        var resolvedFile = file
        if resolvedFile.serverPath == nil || resolvedFile.serverPath?.isEmpty == true {
            resolvedFile.serverPath = path
        }

        if server.type == .alist {
            resolvedFile.url = try await performAListOperation(for: server) { token in
                try await self.alistManager.playbackURL(server: server, at: path, token: token)
            }
            return resolvedFile
        } else if server.type == .pan115 {
            let cookie = server.passwordSecret ?? server.accessToken ?? ""
            let pickCode = file.jellyfinItemId
            resolvedFile.url = try await Pan115Manager.shared.playbackURL(server: server, at: path, pickcode: pickCode, cookie: cookie)
            return resolvedFile
        } else if server.type == .onedrive {
            resolvedFile.url = try await OneDriveManager.shared.rawDownloadURL(server: server, at: path)
            return resolvedFile
        } else if server.type == .googledrive {
            resolvedFile.url = try await GoogleDriveManager.shared.playbackURL(server: server, at: path, fileId: file.jellyfinItemId)
            return resolvedFile
        }

        return file
    }

    func downloadRequest(server: ServerConfig, at path: String) -> URLRequest? {
        switch server.type {
        case .webdav:
            return webdavManager.downloadRequest(server: server, at: path)
        case .alist:
            // Sync call is not supported, fallback to async in call site or throw.
            // Wait, downloadRequest is not async. Let's return nil and rely on the async fallback if implemented.
            // We can't await in non-async func. We'll return nil here.
            return nil
        case .jellyfin, .emby, .plex:
            return mediaServerDownloadRequest(server: server, path: path)
        default:
            return nil
        }
    }

    private func downloadMediaServerFile(
        server: ServerConfig,
        at path: String,
        progress: ((Int64, Int64) -> Void)?
    ) async throws -> URL {
        guard let request = mediaServerDownloadRequest(server: server, path: path) else {
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid media download URL", comment: "")])
        }
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        return try await performHTTPDownload(request: request, suggestedFilename: fileName.isEmpty ? nil : fileName, progress: progress)
    }

    private func mediaServerDownloadRequest(server: ServerConfig, path: String) -> URLRequest? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }

        let url: URL?
        if let absoluteURL = URL(string: trimmedPath), absoluteURL.scheme != nil {
            url = absoluteURL
        } else {
            let baseURL = server.fullURL
            let joined = trimmedPath.hasPrefix("/") ? "\(baseURL)\(trimmedPath)" : "\(baseURL)/\(trimmedPath)"
            url = URL(string: joined)
        }

        guard let url else { return nil }

        var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
        request.timeoutInterval = 300

        switch server.type {
        case .plex:
            applyPlexDownloadHeaders(to: &request, server: server)
        case .jellyfin, .emby:
            if let token = server.accessToken, !token.isEmpty {
                let authHeader = mediaBrowserAuthHeader(token: token)
                request.setValue(authHeader, forHTTPHeaderField: "Authorization")
                request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
                request.setValue(token, forHTTPHeaderField: "X-MediaBrowser-Token")
            }
        default:
            break
        }

        return request
    }

    private func applyPlexDownloadHeaders(to request: inout URLRequest, server: ServerConfig) {
        let systemVersion = UIDevice.current.systemVersion
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let clientIdentifier = plexClientIdentifier()
        let token = server.accessToken?.isEmpty == false ? server.accessToken : server.passwordSecret

        request.setValue("GenPlayer", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("GenPlayer-iOS", forHTTPHeaderField: "X-Plex-Device")
        request.setValue(systemVersion, forHTTPHeaderField: "X-Plex-Platform-Version")
        request.setValue(appVersion, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")

        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
    }

    private func mediaBrowserAuthHeader(token: String) -> String {
        let rawDeviceName = UIDevice.current.name
        let encodedDeviceName = rawDeviceName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawDeviceName
        let deviceIdKey = "MediaServerDownloadDeviceId"
        let deviceId: String
        if let stored = UserDefaults.standard.string(forKey: deviceIdKey), !stored.isEmpty {
            deviceId = stored
        } else {
            let generated = UUID().uuidString
            UserDefaults.standard.set(generated, forKey: deviceIdKey)
            deviceId = generated
        }

        return "MediaBrowser Client=\"GenPlayer\", Device=\"\(encodedDeviceName)\", DeviceId=\"\(deviceId)\", Version=\"1.0\", Token=\"\(token)\""
    }

    private func performHTTPDownload(
        request: URLRequest,
        suggestedFilename: String? = nil,
        progress: ((Int64, Int64) -> Void)?
    ) async throws -> URL {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true, attributes: nil)

        let url = request.url
        let baseName: String
        if let explicit = suggestedFilename, !explicit.isEmpty {
            baseName = explicit
        } else {
            baseName = url?.lastPathComponent.isEmpty == false ? url!.lastPathComponent : UUID().uuidString
        }
        let hasExtension = !(url?.pathExtension ?? "").isEmpty || baseName.contains(".")
        let fileName = hasExtension ? baseName : "\(baseName).bin"
        let destinationURL = tempDirectory.appendingPathComponent(fileName)

        let delegate = HTTPDownloadSessionDelegate(destinationURL: destinationURL, progressHandler: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        return try await withTaskCancellationHandler(operation: {
            defer { session.finishTasksAndInvalidate() }
            return try await withCheckedThrowingContinuation { continuation in
                delegate.installContinuation(continuation)
                let task = session.downloadTask(with: request)
                delegate.task = task
                task.resume()
            }
        }, onCancel: {
            delegate.cancel()
            session.invalidateAndCancel()
        })
    }
    
    var isICloudServerListSyncEnabled: Bool {
        UserDefaults.standard.bool(forKey: iCloudServerListSyncEnabledKey)
    }

    func setICloudServerListSyncEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: iCloudServerListSyncEnabledKey)
        if enabled {
            reconcileICloudServerList(pushLocalIfNeeded: true)
        }
    }

    func syncServerListNow() {
        iCloudPullDebounceWorkItem?.cancel()
        reconcileICloudServerList(
            pushLocalIfNeeded: true,
            forceRefreshCurrentSnapshotVersion: true
        )
    }

    private func applyICloudServerListIfEnabled(remotePayload: ICloudServerListPayload? = nil) {
        guard isICloudServerListSyncEnabled else { return }
        guard !isApplyingICloudServerList else { return }
        let resolvedPayload = trustedICloudPayload(remotePayload ?? iCloudSyncService.pullPayload())
        if let payload = resolvedPayload {
            if payload.updatedAt <= localServerListUpdatedAt { return }
            if payload.updatedAt <= lastAppliedICloudPayloadUpdatedAt { return }
        }

        guard let resolution = ICloudServerListSyncResolver.resolve(
            localServers: savedServers,
            localUpdatedAt: localServerListUpdatedAt,
            remotePayload: resolvedPayload
        ) else {
            return
        }

        isApplyingICloudServerList = true
        defer { isApplyingICloudServerList = false }
        let previousServers = savedServers
        invalidateCachesForUpdatedServers(oldServers: previousServers, newServers: resolution.servers)
        previousServers
            .filter { resolution.removedServerIDs.contains($0.id) }
            .forEach { cleanupRemovedServerData(for: $0) }
        if let privacySpace = resolvedPayload?.privacySpace {
            PrivacySpaceService.shared.replaceMarks(
                with: privacySpace,
                postChangeNotification: false
            )
        }

        savedServers = resolution.servers.map { hydratedServer(from: $0) }
        lastAppliedICloudPayloadUpdatedAt = resolution.updatedAt
        saveServers(updatedAt: resolution.updatedAt, shouldPushToICloud: false)
        markICloudServerListSyncCompleted()
    }

    private func markICloudServerListSyncCompleted(at timestamp: TimeInterval = Date().timeIntervalSince1970) {
        guard FileManager.default.ubiquityIdentityToken != nil else { return }
        UserDefaults.standard.set(timestamp, forKey: lastICloudServerListSyncAtKey)
    }

    private enum ICloudPullTrigger {
        case externalChange
        case willEnterForeground
    }

    private func scheduleICloudPull(trigger: ICloudPullTrigger) {
        guard isICloudServerListSyncEnabled else { return }

        let now = Date().timeIntervalSince1970
        switch trigger {
        case .willEnterForeground:
            guard now - lastICloudPullAttemptAt >= minimumForegroundICloudPullInterval else { return }
            lastICloudPullAttemptAt = now
            DispatchQueue.main.async { [weak self] in
                self?.applyICloudServerListIfEnabled()
            }
        case .externalChange:
            iCloudPullDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lastICloudPullAttemptAt = Date().timeIntervalSince1970
                self.applyICloudServerListIfEnabled()
            }
            iCloudPullDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(
                deadline: .now() + iCloudExternalChangeDebounceInterval,
                execute: workItem
            )
        }
    }

    // MARK: - Helper Parsing
    
    private func parsePath(_ path: String) -> (String, String) {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let shareName = components.first else { return ("", "") }
        let relative = components.dropFirst().joined(separator: "/")
        return (String(shareName), relative)
    }
}


private final class ICloudServerListSyncService {
    static let shared = ICloudServerListSyncService()

    private let store = NSUbiquitousKeyValueStore.default
    private let payloadKey = "icloud_server_list_payload_v1"

    private init() {}

    func pushServerList(
        _ servers: [ServerConfig],
        updatedAt: TimeInterval = Date().timeIntervalSince1970,
        privacySpace: PrivacySpaceSnapshot? = PrivacySpaceService.shared.currentSnapshot
    ) {
        let payload = ICloudServerListPayload(
            updatedAt: updatedAt,
            servers: servers,
            privacySpace: privacySpace
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        store.set(data, forKey: payloadKey)
        store.synchronize()
    }

    func pullPayload() -> ICloudServerListPayload? {
        store.synchronize()
        guard let data = store.data(forKey: payloadKey),
              let payload = try? JSONDecoder().decode(ICloudServerListPayload.self, from: data) else {
            return nil
        }
        return payload
    }
}


enum DownloadTaskStatus: String, Codable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case canceled
}

enum DownloadResumeCapability: String, Codable {
    case resumable
    case restartOnly
    case unknown

    init(serverType: ServerConfig.ServerType) {
        switch serverType {
        case .jellyfin, .emby, .plex, .webdav, .alist, .onedrive, .googledrive:
            self = .resumable
        case .smb, .pan115, .ftp, .sftp, .nfs:
            self = .restartOnly
        case .iptv, .vod:
            self = .unknown
        }
    }

    init(sourceType: DownloadSourceType) {
        switch sourceType {
        case .jellyfin, .emby, .plex, .webdav, .alist, .onedrive, .googledrive:
            self = .resumable
        case .smb, .pan115, .ftp, .sftp, .nfs:
            self = .restartOnly
        case .localImport, .unknown:
            self = .unknown
        }
    }
}

enum DownloadBackgroundCapability: String, Codable {
    case backgroundTransfer
    case foregroundOnly
    case unknown

    init(serverType: ServerConfig.ServerType) {
        switch serverType {
        case .jellyfin, .emby, .plex, .webdav, .alist, .onedrive, .googledrive:
            self = .backgroundTransfer
        case .smb, .pan115, .ftp, .sftp, .nfs:
            self = .foregroundOnly
        case .iptv, .vod:
            self = .unknown
        }
    }

    init(sourceType: DownloadSourceType) {
        switch sourceType {
        case .jellyfin, .emby, .plex, .webdav, .alist, .onedrive, .googledrive:
            self = .backgroundTransfer
        case .smb, .pan115, .ftp, .sftp, .nfs:
            self = .foregroundOnly
        case .localImport, .unknown:
            self = .unknown
        }
    }
}

enum DownloadSourceType: String, Codable {
    case jellyfin
    case emby
    case plex
    case smb
    case webdav
    case alist
    case pan115 = "115"
    case onedrive
    case googledrive
    case ftp
    case sftp
    case nfs
    case localImport
    case unknown

    init(serverType: ServerConfig.ServerType) {
        switch serverType {
        case .jellyfin: self = .jellyfin
        case .emby: self = .emby
        case .plex: self = .plex
        case .smb: self = .smb
        case .webdav: self = .webdav
        case .alist: self = .alist
        case .pan115: self = .pan115
        case .onedrive: self = .onedrive
        case .googledrive: self = .googledrive
        case .ftp: self = .ftp
        case .sftp: self = .sftp
        case .nfs: self = .nfs
        case .iptv, .vod: self = .unknown
        }
    }

    var displayName: String {
        switch self {
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        case .smb: return "SMB"
        case .webdav: return "WebDAV"
        case .alist: return "AList"
        case .pan115: return "115"
        case .onedrive: return "OneDrive"
        case .googledrive: return "Google Drive"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        case .nfs: return "NFS"
        case .localImport: return NSLocalizedString("Local", comment: "")
        case .unknown: return NSLocalizedString("Unknown", comment: "")
        }
    }

    var serverType: ServerConfig.ServerType? {
        switch self {
        case .jellyfin: return .jellyfin
        case .emby: return .emby
        case .plex: return .plex
        case .smb: return .smb
        case .webdav: return .webdav
        case .alist: return .alist
        case .pan115: return .pan115
        case .onedrive: return .onedrive
        case .googledrive: return .googledrive
        case .ftp: return .ftp
        case .sftp: return .sftp
        case .nfs: return .nfs
        case .localImport, .unknown: return nil
        }
    }
}

enum DownloadJobKind: String, Codable {
    case singleMedia
    case seasonPack
    case fileBatch
}

enum DownloadAggregateState: Equatable {
    case notDownloaded
    case queued(completed: Int, total: Int)
    case downloading(completed: Int, total: Int)
    case partiallyDownloaded(completed: Int, total: Int)
    case downloaded
    case failed(completed: Int, total: Int)
}

struct DownloadJobDescriptor {
    let id: UUID
    let kind: DownloadJobKind
    let sourceType: DownloadSourceType
    let title: String
    let groupTitle: String?
    let collectionId: String?
    let seriesId: String?
    let seasonId: String?

    init(
        id: UUID = UUID(),
        kind: DownloadJobKind,
        sourceType: DownloadSourceType,
        title: String,
        groupTitle: String? = nil,
        collectionId: String? = nil,
        seriesId: String? = nil,
        seasonId: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.sourceType = sourceType
        self.title = title
        self.groupTitle = groupTitle
        self.collectionId = collectionId
        self.seriesId = seriesId
        self.seasonId = seasonId
    }
}

struct DownloadMediaBatchItem {
    let remoteItemId: String?
    let remotePath: String
    let fileName: String
    let displayTitle: String
    let totalBytes: Int64?
    let collectionId: String?
    let seriesId: String?
    let seasonId: String?
    let groupIndex: Int
}

struct DownloadRemoteFileBatchItem {
    let remotePath: String
    let fileName: String
    let displayTitle: String
    let totalBytes: Int64?
    let groupIndex: Int
}

struct DownloadJobGroup: Identifiable {
    enum Bucket {
        case active
        case completed
        case failed
    }

    let id: UUID
    let kind: DownloadJobKind
    let sourceType: DownloadSourceType
    let title: String
    let groupTitle: String?
    let serverId: UUID
    let serverName: String
    let createdAt: Date
    let tasks: [DownloadTaskItem]

    var itemCount: Int { tasks.count }
    var completedCount: Int { tasks.filter { $0.status == .completed }.count }
    var failedCount: Int { tasks.filter { $0.status == .failed }.count }
    var pausedCount: Int { tasks.filter { $0.status == .paused }.count }
    var canceledCount: Int { tasks.filter { $0.status == .canceled }.count }
    var queuedCount: Int { tasks.filter { $0.status == .queued }.count }
    var downloadingCount: Int { tasks.filter { $0.status == .downloading }.count }
    var activeCount: Int { tasks.filter(\.isActive).count }
    var isExpandable: Bool { tasks.count > 1 }

    var bucket: Bucket? {
        if activeCount > 0 {
            return .active
        }
        if failedCount > 0 || canceledCount > 0 {
            return .failed
        }
        if completedCount > 0 {
            return .completed
        }
        return nil
    }

    var primaryStatus: DownloadTaskStatus {
        if downloadingCount > 0 { return .downloading }
        if queuedCount > 0 { return .queued }
        if pausedCount > 0 { return .paused }
        if failedCount > 0 { return .failed }
        if canceledCount > 0 { return .canceled }
        if completedCount > 0 { return .completed }
        return .canceled
    }

    var aggregateProgress: Double {
        let totals = tasks.reduce((downloaded: Int64(0), total: Int64(0))) { partial, task in
            let downloaded = partial.downloaded + max(task.bytesDownloaded, 0)
            let total = partial.total + max(max(task.bytesTotal, task.bytesDownloaded), 0)
            return (downloaded, total)
        }

        if totals.total > 0 {
            return min(1.0, Double(totals.downloaded) / Double(totals.total))
        }

        guard !tasks.isEmpty else { return 0 }
        return Double(completedCount) / Double(tasks.count)
    }

    var totalBytes: Int64 {
        tasks.reduce(0) { $0 + max(max($1.bytesTotal, $1.bytesDownloaded), 0) }
    }

    // Only live transfers contribute; persisted completed tasks may retain old samples.
    var speedBytesPerSec: Double {
        tasks.reduce(0.0) { total, task in
            guard task.status == .downloading else { return total }
            return total + max(task.speedBytesPerSec, 0)
        }
    }

    var downloadedBytes: Int64 {
        tasks.reduce(0) { $0 + max($1.bytesDownloaded, 0) }
    }
}

private enum HTTPManagedDownloadInterruption: Error {
    case paused(Data?)
}

private final class ManagedHTTPDownload: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    private let request: URLRequest
    private let progressHandler: ((Int64, Int64) -> Void)?
    private let destinationURL: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var didFinish = false
    private var pauseRequested = false
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()

    init(request: URLRequest, progressHandler: ((Int64, Int64) -> Void)?) {
        self.request = request
        self.progressHandler = progressHandler

        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true, attributes: nil)

        let suggestedName = request.url?.lastPathComponent.isEmpty == false ? request.url!.lastPathComponent : UUID().uuidString
        let hasExtension = !(request.url?.pathExtension ?? "").isEmpty || suggestedName.contains(".")
        let fileName = hasExtension ? suggestedName : "\(suggestedName).bin"
        self.destinationURL = tempDirectory.appendingPathComponent(fileName)
    }

    func start(resumeData: Data?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            self.didFinish = false
            self.pauseRequested = false
            lock.unlock()

            let downloadTask: URLSessionDownloadTask
            if let resumeData, !resumeData.isEmpty {
                downloadTask = session.downloadTask(withResumeData: resumeData)
            } else {
                downloadTask = session.downloadTask(with: request)
            }
            task = downloadTask
            downloadTask.resume()
        }
    }

    func pause() {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        pauseRequested = true
        let activeTask = task
        lock.unlock()

        activeTask?.cancel(byProducingResumeData: { [weak self] resumeData in
            self?.finish(with: .failure(HTTPManagedDownloadInterruption.paused(resumeData)))
        })
    }

    func cancel() {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        pauseRequested = false
        let activeTask = task
        lock.unlock()

        activeTask?.cancel()
    }

    private func finish(with result: Result<URL, Error>) {
        lock.lock()
        guard !didFinish, let continuation else {
            lock.unlock()
            return
        }
        didFinish = true
        self.continuation = nil
        lock.unlock()

        continuation.resume(with: result)
        session.finishTasksAndInvalidate()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler?(totalBytesWritten, max(0, totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try DownloadFileValidation.validateHTTP(response: downloadTask.response, fileURL: location)
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: location, to: destinationURL)
            finish(with: .success(destinationURL))
        } catch {
            finish(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }

        let nsError = error as NSError
        if pauseRequested,
           nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled {
            return
        }

        finish(with: .failure(error))
    }
}

private final class HTTPDownloadSessionDelegate: NSObject, URLSessionDownloadDelegate, URLSessionTaskDelegate {
    private let progressHandler: ((Int64, Int64) -> Void)?
    private let destinationURL: URL
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var didFinish = false

    var task: URLSessionDownloadTask?

    init(destinationURL: URL, progressHandler: ((Int64, Int64) -> Void)?) {
        self.destinationURL = destinationURL
        self.progressHandler = progressHandler
    }

    func installContinuation(_ continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func cancel() {
        task?.cancel()
    }

    private func resumeOnce(with result: Result<URL, Error>) {
        lock.lock()
        guard !didFinish, let continuation else {
            lock.unlock()
            return
        }
        didFinish = true
        self.continuation = nil
        lock.unlock()

        continuation.resume(with: result)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler?(totalBytesWritten, max(0, totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try DownloadFileValidation.validateHTTP(response: downloadTask.response, fileURL: location)
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: location, to: destinationURL)
            resumeOnce(with: .success(destinationURL))
        } catch {
            resumeOnce(with: .failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            resumeOnce(with: .failure(error))
        }
    }
}

struct DownloadTaskItem: Identifiable, Codable {
    let id: UUID
    let serverId: UUID
    let serverName: String
    var jobId: UUID
    var jobKind: DownloadJobKind
    var sourceType: DownloadSourceType
    let fileName: String
    var displayTitle: String
    var groupTitle: String?
    let remotePath: String
    var remoteItemId: String?
    var collectionId: String?
    var seriesId: String?
    var seasonId: String?
    var groupIndex: Int
    let createdAt: Date

    var status: DownloadTaskStatus
    var resumeCapability: DownloadResumeCapability
    var backgroundCapability: DownloadBackgroundCapability
    var progress: Double
    var bytesDownloaded: Int64
    var bytesTotal: Int64
    var speedBytesPerSec: Double
    var resumeData: Data?
    var backgroundSessionTaskIdentifier: Int?
    var stagingFilePath: String?
    var localFilePath: String?
    var errorMessage: String?

    var isActive: Bool { status == .queued || status == .downloading || status == .paused }
    var isRunning: Bool { status == .queued || status == .downloading }

    enum CodingKeys: String, CodingKey {
        case id, serverId, serverName, jobId, jobKind, sourceType
        case fileName, displayTitle, groupTitle, remotePath, remoteItemId
        case collectionId, seriesId, seasonId, groupIndex, createdAt
        case status, resumeCapability, backgroundCapability, progress, bytesDownloaded, bytesTotal, speedBytesPerSec
        case resumeData, backgroundSessionTaskIdentifier, stagingFilePath, localFilePath, errorMessage
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(serverName, forKey: .serverName)
        try container.encode(jobId, forKey: .jobId)
        try container.encode(jobKind, forKey: .jobKind)
        try container.encode(sourceType, forKey: .sourceType)
        try container.encode(fileName, forKey: .fileName)
        try container.encode(displayTitle, forKey: .displayTitle)
        try container.encodeIfPresent(groupTitle, forKey: .groupTitle)
        try container.encode(remotePath, forKey: .remotePath)
        try container.encodeIfPresent(remoteItemId, forKey: .remoteItemId)
        try container.encodeIfPresent(collectionId, forKey: .collectionId)
        try container.encodeIfPresent(seriesId, forKey: .seriesId)
        try container.encodeIfPresent(seasonId, forKey: .seasonId)
        try container.encode(groupIndex, forKey: .groupIndex)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(status, forKey: .status)
        try container.encode(resumeCapability, forKey: .resumeCapability)
        try container.encode(backgroundCapability, forKey: .backgroundCapability)
        try container.encode(progress, forKey: .progress)
        try container.encode(bytesDownloaded, forKey: .bytesDownloaded)
        try container.encode(bytesTotal, forKey: .bytesTotal)
        try container.encode(speedBytesPerSec, forKey: .speedBytesPerSec)
        try container.encodeIfPresent(resumeData, forKey: .resumeData)
        try container.encodeIfPresent(backgroundSessionTaskIdentifier, forKey: .backgroundSessionTaskIdentifier)
        try container.encodeIfPresent(stagingFilePath, forKey: .stagingFilePath)
        try container.encodeIfPresent(errorMessage, forKey: .errorMessage)

        if let localFilePath {
            try container.encode(Self.relativeLocalPath(forRawPath: localFilePath) ?? localFilePath, forKey: .localFilePath)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        serverId = try container.decode(UUID.self, forKey: .serverId)
        serverName = try container.decode(String.self, forKey: .serverName)
        jobId = try container.decodeIfPresent(UUID.self, forKey: .jobId) ?? id
        jobKind = try container.decodeIfPresent(DownloadJobKind.self, forKey: .jobKind) ?? .singleMedia
        sourceType = try container.decodeIfPresent(DownloadSourceType.self, forKey: .sourceType) ?? .unknown
        fileName = try container.decode(String.self, forKey: .fileName)
        displayTitle = try container.decodeIfPresent(String.self, forKey: .displayTitle) ?? fileName
        groupTitle = try container.decodeIfPresent(String.self, forKey: .groupTitle)
        remotePath = try container.decode(String.self, forKey: .remotePath)
        remoteItemId = try container.decodeIfPresent(String.self, forKey: .remoteItemId)
        collectionId = try container.decodeIfPresent(String.self, forKey: .collectionId)
        seriesId = try container.decodeIfPresent(String.self, forKey: .seriesId)
        seasonId = try container.decodeIfPresent(String.self, forKey: .seasonId)
        groupIndex = try container.decodeIfPresent(Int.self, forKey: .groupIndex) ?? 0
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        status = try container.decode(DownloadTaskStatus.self, forKey: .status)
        resumeCapability = try container.decodeIfPresent(DownloadResumeCapability.self, forKey: .resumeCapability) ?? DownloadResumeCapability(sourceType: sourceType)
        backgroundCapability = try container.decodeIfPresent(DownloadBackgroundCapability.self, forKey: .backgroundCapability) ?? DownloadBackgroundCapability(sourceType: sourceType)
        progress = try container.decode(Double.self, forKey: .progress)
        bytesDownloaded = try container.decode(Int64.self, forKey: .bytesDownloaded)
        bytesTotal = try container.decode(Int64.self, forKey: .bytesTotal)
        speedBytesPerSec = try container.decode(Double.self, forKey: .speedBytesPerSec)
        resumeData = try container.decodeIfPresent(Data.self, forKey: .resumeData)
        backgroundSessionTaskIdentifier = try container.decodeIfPresent(Int.self, forKey: .backgroundSessionTaskIdentifier)
        stagingFilePath = try container.decodeIfPresent(String.self, forKey: .stagingFilePath)
        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)

        if let storedPath = try container.decodeIfPresent(String.self, forKey: .localFilePath) {
            localFilePath = Self.restoreLocalPath(from: storedPath)
        } else {
            localFilePath = nil
        }
    }

    init(
        id: UUID,
        serverId: UUID,
        serverName: String,
        jobId: UUID,
        jobKind: DownloadJobKind,
        sourceType: DownloadSourceType,
        fileName: String,
        displayTitle: String,
        groupTitle: String?,
        remotePath: String,
        remoteItemId: String?,
        collectionId: String?,
        seriesId: String?,
        seasonId: String?,
        groupIndex: Int,
        createdAt: Date,
        status: DownloadTaskStatus,
        resumeCapability: DownloadResumeCapability,
        backgroundCapability: DownloadBackgroundCapability,
        progress: Double,
        bytesDownloaded: Int64,
        bytesTotal: Int64,
        speedBytesPerSec: Double,
        resumeData: Data?,
        backgroundSessionTaskIdentifier: Int?,
        stagingFilePath: String?,
        localFilePath: String?,
        errorMessage: String?
    ) {
        self.id = id
        self.serverId = serverId
        self.serverName = serverName
        self.jobId = jobId
        self.jobKind = jobKind
        self.sourceType = sourceType
        self.fileName = fileName
        self.displayTitle = displayTitle
        self.groupTitle = groupTitle
        self.remotePath = remotePath
        self.remoteItemId = remoteItemId
        self.collectionId = collectionId
        self.seriesId = seriesId
        self.seasonId = seasonId
        self.groupIndex = groupIndex
        self.createdAt = createdAt
        self.status = status
        self.resumeCapability = resumeCapability
        self.backgroundCapability = backgroundCapability
        self.progress = progress
        self.bytesDownloaded = bytesDownloaded
        self.bytesTotal = bytesTotal
        self.speedBytesPerSec = speedBytesPerSec
        self.resumeData = resumeData
        self.backgroundSessionTaskIdentifier = backgroundSessionTaskIdentifier
        self.stagingFilePath = stagingFilePath
        self.localFilePath = localFilePath
        self.errorMessage = errorMessage
    }

    private static func restoreLocalPath(from storedPath: String) -> String {
        if storedPath.hasPrefix("/") || storedPath.contains("://") {
            return URL(fileURLWithPath: storedPath).standardizedFileURL.path
        }
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return storedPath
        }
        return documentsURL.appendingPathComponent(storedPath).standardizedFileURL.path
    }

    static func relativeLocalPath(forRawPath rawPath: String) -> String? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let documentsPath = documentsURL.standardizedFileURL.path
        let standardizedPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard standardizedPath.hasPrefix(documentsPath) else {
            return nil
        }

        let suffix = String(standardizedPath.dropFirst(documentsPath.count))
        return suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
    }
}

@MainActor
class DownloadCenterService: ObservableObject {
    static let shared = DownloadCenterService()

    struct DownloadedStorageSummary {
        let fileCount: Int
        let recordCount: Int
        let totalBytes: Int64
    }

    @Published private(set) var tasks: [DownloadTaskItem] = []

    private enum TerminationReason {
        case pause
        case cancel
    }

    private struct DownloadSpeedSample {
        var lastObservedBytes: Int64
        var lastPublishedAt: Date
        var sampledBytes: Int64
        var lastSpeedSampleAt: Date
        var smoothedSpeedBytesPerSec: Double

        init(initialBytes: Int64, now: Date = Date()) {
            lastObservedBytes = initialBytes
            lastPublishedAt = now
            sampledBytes = 0
            lastSpeedSampleAt = now
            smoothedSpeedBytesPerSec = 0
        }
    }

    private let networkService = AppNetworkService.shared
    private let backgroundDownloadManager = BackgroundDownloadSessionManager.shared
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var activeHTTPDownloads: [UUID: ManagedHTTPDownload] = [:]
    private var backgroundSpeedSamples: [UUID: DownloadSpeedSample] = [:]
    private var terminationReasons: [UUID: TerminationReason] = [:]
    private var pauseMessageOverrides: [UUID: String] = [:]
    private let persistenceURL: URL
    private let persistenceQueue = DispatchQueue(label: "com.genplayer.download.persistence", qos: .utility)
    private var lifecycleObservers: [NSObjectProtocol] = []
    private let downloadPolicyNetworkMonitor = NWPathMonitor()
    private let downloadPolicyNetworkQueue = DispatchQueue(label: "com.genplayer.download-policy.network")
    private var currentNetworkPath: NWPath?
#if os(iOS)
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid
#endif

    var maxConcurrentDownloads: Int {
        get {
            let value = UserDefaults.standard.integer(forKey: "maxConcurrentDownloads")
            return value > 0 ? value : 3
        }
        set {
            let clamped = max(1, min(5, newValue))
            UserDefaults.standard.set(clamped, forKey: "maxConcurrentDownloads")
            drainQueue()
        }
    }

    func drainQueue() {
        if activeDownloadPolicyBlock() != nil {
            return
        }

        let currentlyDownloadingCount = tasks.filter { $0.status == .downloading }.count
        let availableSlots = maxConcurrentDownloads - currentlyDownloadingCount
        guard availableSlots > 0 else { return }

        let queuedTasks = tasks
            .filter { $0.status == .queued }
            .sorted {
                if $0.createdAt == $1.createdAt {
                    return $0.groupIndex < $1.groupIndex
                }
                return $0.createdAt < $1.createdAt
            }

        for task in queuedTasks.prefix(availableSlots) {
            guard let server = networkService.servers.first(where: { $0.id == task.serverId }) else {
                updateTask(task.id) {
                    $0.status = .failed
                    $0.errorMessage = NSLocalizedString("Server not found", comment: "")
                }
                continue
            }
            startDownload(for: task.id, server: server)
        }
    }

    private init() {
        let fileManager = FileManager.default
        let appDir = Self.makePersistenceDirectory(fileManager: fileManager)
        let newPersistenceURL = appDir.appendingPathComponent("download_tasks.json")
        Self.migrateLegacyPersistenceIfNeeded(fileManager: fileManager, to: newPersistenceURL)
        persistenceURL = newPersistenceURL
        backgroundDownloadManager.delegate = self
        loadPersistedTasks()
        migrateTrackedDownloadDirectoriesIfNeeded()
        reconcileMissingLocalFiles()
        OfflineMediaIndexStore.shared.rebuildIndex(from: tasks)
        configureLifecycleObservers()
        configureDownloadPolicyMonitoring()
        restoreBackgroundDownloads()
    }

    private static func makePersistenceDirectory(fileManager: FileManager) -> URL {
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appDir = appSupport.appendingPathComponent("GenPlayer", isDirectory: true)
            try? fileManager.createDirectory(at: appDir, withIntermediateDirectories: true)
            return appDir
        }

        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fallbackDir = documents.appendingPathComponent("GenPlayer", isDirectory: true)
        try? fileManager.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
        return fallbackDir
    }

    private static func migrateLegacyPersistenceIfNeeded(fileManager: FileManager, to newURL: URL) {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        let legacyDir = documents.appendingPathComponent("GenPlayer", isDirectory: true)
        let legacyURL = legacyDir.appendingPathComponent("download_tasks.json")
        if !fileManager.fileExists(atPath: newURL.path),
           fileManager.fileExists(atPath: legacyURL.path) {
            do {
                try fileManager.moveItem(at: legacyURL, to: newURL)
            } catch {
                try? fileManager.copyItem(at: legacyURL, to: newURL)
            }
        }

        if let entries = try? fileManager.contentsOfDirectory(atPath: legacyDir.path), entries.isEmpty {
            try? fileManager.removeItem(at: legacyDir)
        }
    }

    var activeTasks: [DownloadTaskItem] { tasks.filter { $0.isActive } }
    var completedTasks: [DownloadTaskItem] { tasks.filter { $0.status == .completed } }
    var failedTasks: [DownloadTaskItem] { tasks.filter { $0.status == .failed || $0.status == .canceled } }

    var jobs: [DownloadJobGroup] {
        let grouped = Dictionary(grouping: tasks) { $0.jobId }
        return grouped.compactMap { jobId, groupedTasks in
            guard let anchor = groupedTasks.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
            return DownloadJobGroup(
                id: jobId,
                kind: anchor.jobKind,
                sourceType: anchor.sourceType,
                title: anchor.groupTitle ?? anchor.displayTitle,
                groupTitle: anchor.groupTitle,
                serverId: anchor.serverId,
                serverName: anchor.serverName,
                createdAt: anchor.createdAt,
                tasks: groupedTasks.sorted {
                    if $0.groupIndex == $1.groupIndex {
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.groupIndex < $1.groupIndex
                }
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    var activeJobs: [DownloadJobGroup] {
        jobs.filter { $0.bucket == .active }
    }

    var completedJobs: [DownloadJobGroup] {
        jobs.filter { $0.bucket == .completed }
    }

    var failedJobs: [DownloadJobGroup] {
        jobs.filter { $0.bucket == .failed }
    }

    func downloadedStorageSummary() -> DownloadedStorageSummary {
        let completedTasks = tasks.filter { $0.status == .completed }
        let uniqueURLs = uniqueExistingLocalFileURLs(for: completedTasks)
        let totalBytes = uniqueURLs.reduce(Int64(0)) { partialResult, url in
            let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partialResult + Int64(fileSize)
        }

        return DownloadedStorageSummary(
            fileCount: uniqueURLs.count,
            recordCount: completedTasks.count,
            totalBytes: totalBytes
        )
    }

    func isTrackedLocalDownload(_ url: URL) -> Bool {
        let standardizedPath = url.standardizedFileURL.path
        return tasks.contains { task in
            guard task.status == .completed,
                  let path = task.localFilePath,
                  !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else { return false }
            return URL(fileURLWithPath: path).standardizedFileURL.path == standardizedPath
        }
    }

    func isDownloaded(serverId: UUID, remotePath: String) -> Bool {
        if OfflineMediaIndexStore.shared.isDownloaded(serverId: serverId, remotePath: remotePath) {
            return true
        }
        guard let task = bestTask(serverId: serverId, remotePath: remotePath),
              task.status == .completed,
              let path = task.localFilePath,
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return false
        }
        OfflineMediaIndexStore.shared.registerCompleted(task: task)
        return true
    }

    func isDownloaded(file: VideoFile) -> Bool {
        OfflineMediaIndexStore.shared.isDownloaded(file: file)
    }

    func localFileURL(for file: VideoFile) -> URL? {
        guard file.isRemote,
              let serverIdString = file.jellyfinServerId,
              let serverId = UUID(uuidString: serverIdString) else {
            return nil
        }

        if let remoteItemId = file.jellyfinItemId,
           let url = localFileURL(serverId: serverId, remoteItemId: remoteItemId) {
            return url
        }

        return localFileURL(serverId: serverId, remotePath: file.url.path)
    }

    func localPlaybackFile(for file: VideoFile) -> VideoFile? {
        guard let localURL = localFileURL(for: file) else { return nil }

        let resourceValues = try? localURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let resolvedType = VideoFile.FileType.determineType(from: localURL)
        let playbackType = resolvedType == .unknown ? file.type : resolvedType

        var localFile = VideoFile(
            name: file.name,
            url: localURL,
            type: playbackType,
            size: Int64(resourceValues?.fileSize ?? Int(clamping: file.size)),
            date: resourceValues?.contentModificationDate ?? file.date,
            isRemote: false,
            duration: file.duration,
            lastPlayedPosition: file.lastPlayedPosition,
            videoAspectRatioHint: file.videoAspectRatioHint,
            lastAudioTrack: file.lastAudioTrack,
            lastSubtitleTrack: file.lastSubtitleTrack,
            jellyfinItemId: file.jellyfinItemId,
            jellyfinServerId: file.jellyfinServerId,
            serverType: file.serverType,
            itemCount: file.itemCount,
            seriesId: file.seriesId,
            seasonId: file.seasonId,
            preferredAudioTrackQuery: file.preferredAudioTrackQuery,
            preferredSubtitleTrackQuery: file.preferredSubtitleTrackQuery,
            disableSubtitlesOnStart: file.disableSubtitlesOnStart,
            externalSubtitleCandidates: file.externalSubtitleCandidates
        )
        localFile.preferredAudioTrackOrdinal = file.preferredAudioTrackOrdinal
        localFile.preferredSubtitleTrackOrdinal = file.preferredSubtitleTrackOrdinal
        localFile.preferredPlaybackQualityID = file.preferredPlaybackQualityID
        localFile.availablePlaybackQualityOptions = file.availablePlaybackQualityOptions
        localFile.serverMediaStreams = file.serverMediaStreams
        localFile.serverContainer = file.serverContainer
        localFile.serverSize = file.serverSize
        localFile.serverBitrate = file.serverBitrate
        localFile.serverPath = file.serverPath
        localFile.remotePlaybackMethod = file.remotePlaybackMethod
        localFile.shouldResetRemotePlayedStateOnPlaybackStart = file.shouldResetRemotePlayedStateOnPlaybackStart
        return localFile
    }

    func completedTask(for localFileURL: URL) -> DownloadTaskItem? {
        let targetURL = localFileURL.standardizedFileURL.resolvingSymlinksInPath()
        let targetPath = targetURL.path
        let targetFileName = localFileURL.lastPathComponent
        return tasks.first { task in
            guard task.status == .completed,
                  let localPath = task.localFilePath,
                  !localPath.isEmpty else {
                return false
            }
            let taskURL = URL(fileURLWithPath: localPath).standardizedFileURL.resolvingSymlinksInPath()
            if taskURL.path == targetPath {
                return true
            }
            // 相对路径匹配：应对 Documents 目录迁移/重装场景
            if taskURL.lastPathComponent == targetFileName {
                let rel1 = DownloadTaskItem.relativeLocalPath(forRawPath: targetPath)
                let rel2 = DownloadTaskItem.relativeLocalPath(forRawPath: taskURL.path)
                if let rel1, let rel2, rel1 == rel2 {
                    return true
                }
            }
            return false
        }
    }


    func hydratedPlaybackFile(for localFile: VideoFile) -> VideoFile? {
        guard localFile.url.isFileURL else { return nil }
        guard let task = completedTask(for: localFile.url) else { return nil }

        let server = AppNetworkService.shared.servers.first(where: { $0.id == task.serverId })
        let serverType = server?.type ?? task.sourceType.serverType

        var hydrated = localFile
        if hydrated.jellyfinItemId == nil || hydrated.jellyfinItemId?.isEmpty == true {
            hydrated.jellyfinItemId = task.remoteItemId
        }
        if hydrated.jellyfinServerId == nil || hydrated.jellyfinServerId?.isEmpty == true {
            hydrated.jellyfinServerId = task.serverId.uuidString
        }
        if hydrated.serverType == nil {
            hydrated.serverType = serverType
        }
        if hydrated.seriesId == nil || hydrated.seriesId?.isEmpty == true {
            hydrated.seriesId = task.seriesId
        }
        if hydrated.seasonId == nil || hydrated.seasonId?.isEmpty == true {
            hydrated.seasonId = task.seasonId
        }
        if hydrated.serverPath == nil || hydrated.serverPath?.isEmpty == true {
            hydrated.serverPath = task.remotePath
        }
        return hydrated
    }


    func isDownloaded(serverId: UUID, remoteItemId: String) -> Bool {
        if OfflineMediaIndexStore.shared.isDownloaded(serverId: serverId, remoteItemId: remoteItemId) {
            return true
        }
        let normalized = remoteItemId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let task = bestTask(serverId: serverId, remoteItemId: normalized),
              task.status == .completed,
              let path = task.localFilePath,
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return false
        }
        OfflineMediaIndexStore.shared.registerCompleted(task: task)
        return true
    }

    func taskStatus(serverId: UUID, remoteItemId: String) -> DownloadTaskStatus? {
        let normalized = remoteItemId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return bestTask(serverId: serverId, remoteItemId: normalized)?.status
    }

    func taskStatus(serverId: UUID, remotePath: String) -> DownloadTaskStatus? {
        let normalized = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        return bestTask(serverId: serverId, remotePath: normalized)?.status
    }

    func localFileURL(serverId: UUID, remoteItemId: String) -> URL? {
        if let url = OfflineMediaIndexStore.shared.localFileURL(serverId: serverId, remoteItemId: remoteItemId) {
            return url
        }
        let normalized = remoteItemId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let task = bestTask(serverId: serverId, remoteItemId: normalized),
              let url = validatedLocalFileURL(for: task) else {
            return nil
        }
        OfflineMediaIndexStore.shared.registerCompleted(task: task)
        return url
    }

    func localFileURL(serverId: UUID, remotePath: String) -> URL? {
        if let url = OfflineMediaIndexStore.shared.localFileURL(serverId: serverId, remotePath: remotePath) {
            return url
        }
        let normalized = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              let task = bestTask(serverId: serverId, remotePath: normalized),
              let url = validatedLocalFileURL(for: task) else {
            return nil
        }
        OfflineMediaIndexStore.shared.registerCompleted(task: task)
        return url
    }

    func aggregateState(serverId: UUID, remoteItemIds: [String]) -> DownloadAggregateState {
        let normalized = Array(Set(remoteItemIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !normalized.isEmpty else { return .notDownloaded }

        let matches = normalized.compactMap { bestTask(serverId: serverId, remoteItemId: $0) }
        return aggregateState(for: matches, totalExpected: normalized.count)
    }

    func aggregateStateForRemotePaths(serverId: UUID, remotePaths: [String]) -> DownloadAggregateState {
        let normalized = Array(Set(remotePaths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !normalized.isEmpty else { return .notDownloaded }

        let matches = normalized.compactMap { bestTask(serverId: serverId, remotePath: $0) }
        return aggregateState(for: matches, totalExpected: normalized.count)
    }

    @discardableResult
    func enqueueMediaDownload(
        server: ServerConfig,
        remoteItemId: String,
        fileName: String,
        totalBytes: Int64?,
        displayTitle: String? = nil,
        groupTitle: String? = nil,
        collectionId: String? = nil,
        seriesId: String? = nil,
        seasonId: String? = nil
    ) -> Bool {
        let normalized = remoteItemId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        let descriptor = DownloadJobDescriptor(
            kind: .singleMedia,
            sourceType: DownloadSourceType(serverType: server.type),
            title: groupTitle ?? displayTitle ?? fileName,
            groupTitle: groupTitle,
            collectionId: collectionId ?? normalized,
            seriesId: seriesId,
            seasonId: seasonId
        )
        let item = DownloadMediaBatchItem(
            remoteItemId: normalized,
            remotePath: mediaStreamDownloadPath(for: normalized),
            fileName: fileName,
            displayTitle: displayTitle ?? fileName,
            totalBytes: totalBytes,
            collectionId: collectionId ?? normalized,
            seriesId: seriesId,
            seasonId: seasonId,
            groupIndex: 0
        )
        return enqueueMediaBatch(server: server, items: [item], job: descriptor) > 0
    }

    private func mediaStreamDownloadPath(for remoteItemId: String) -> String {
        "/Videos/\(remoteItemId)/stream?Static=true&download=1"
    }

    @discardableResult
    func enqueueMediaBatch(server: ServerConfig, items: [DownloadMediaBatchItem], job: DownloadJobDescriptor) -> Int {
        let createdAt = Date()
        let queuedItems = items.compactMap { item -> DownloadTaskItem? in
            let normalizedRemotePath = item.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedRemotePath.isEmpty else { return nil }

            if let remoteItemId = item.remoteItemId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !remoteItemId.isEmpty,
               let status = taskStatus(serverId: server.id, remoteItemId: remoteItemId),
               status == .queued || status == .downloading || status == .paused || status == .completed {
                return nil
            }

            if let status = taskStatus(serverId: server.id, remotePath: normalizedRemotePath),
               status == .queued || status == .downloading || status == .paused || status == .completed {
                return nil
            }

            return DownloadTaskItem(
                id: UUID(),
                serverId: server.id,
                serverName: server.name,
                jobId: job.id,
                jobKind: job.kind,
                sourceType: job.sourceType,
                fileName: item.fileName,
                displayTitle: item.displayTitle,
                groupTitle: job.title,
                remotePath: normalizedRemotePath,
                remoteItemId: item.remoteItemId?.trimmingCharacters(in: .whitespacesAndNewlines),
                collectionId: item.collectionId ?? job.collectionId,
                seriesId: item.seriesId ?? job.seriesId,
                seasonId: item.seasonId ?? job.seasonId,
                groupIndex: item.groupIndex,
                createdAt: createdAt,
                status: .queued,
                resumeCapability: DownloadResumeCapability(serverType: server.type),
                backgroundCapability: DownloadBackgroundCapability(serverType: server.type),
                progress: 0,
                bytesDownloaded: 0,
                bytesTotal: item.totalBytes ?? 0,
                speedBytesPerSec: 0,
                resumeData: nil,
                backgroundSessionTaskIdentifier: nil,
                stagingFilePath: nil,
                localFilePath: nil,
                errorMessage: nil
            )
        }

        guard !queuedItems.isEmpty else { return 0 }
        tasks.insert(contentsOf: queuedItems.reversed(), at: 0)
        persistTasks()
        drainQueue()
        return queuedItems.count
    }

    @discardableResult
    func enqueueRemoteFileBatch(
        server: ServerConfig,
        items: [DownloadRemoteFileBatchItem],
        job: DownloadJobDescriptor
    ) -> Int {
        let createdAt = Date()
        let queuedItems = items.compactMap { item -> DownloadTaskItem? in
            let normalizedRemotePath = item.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedRemotePath.isEmpty else { return nil }
            if let status = taskStatus(serverId: server.id, remotePath: normalizedRemotePath),
               status == .queued || status == .downloading || status == .paused || status == .completed {
                return nil
            }

            return DownloadTaskItem(
                id: UUID(),
                serverId: server.id,
                serverName: server.name,
                jobId: job.id,
                jobKind: job.kind,
                sourceType: job.sourceType,
                fileName: item.fileName,
                displayTitle: item.displayTitle,
                groupTitle: job.title,
                remotePath: normalizedRemotePath,
                remoteItemId: nil,
                collectionId: job.collectionId,
                seriesId: job.seriesId,
                seasonId: job.seasonId,
                groupIndex: item.groupIndex,
                createdAt: createdAt,
                status: .queued,
                resumeCapability: DownloadResumeCapability(serverType: server.type),
                backgroundCapability: DownloadBackgroundCapability(serverType: server.type),
                progress: 0,
                bytesDownloaded: 0,
                bytesTotal: item.totalBytes ?? 0,
                speedBytesPerSec: 0,
                resumeData: nil,
                backgroundSessionTaskIdentifier: nil,
                stagingFilePath: nil,
                localFilePath: nil,
                errorMessage: nil
            )
        }

        guard !queuedItems.isEmpty else { return 0 }
        tasks.insert(contentsOf: queuedItems.reversed(), at: 0)
        persistTasks()
        drainQueue()
        return queuedItems.count
    }

    private func taskMatches(_ task: DownloadTaskItem, remoteItemId: String, localFilePath: String?) -> Bool {
        if let explicitRemoteItemId = task.remoteItemId?.trimmingCharacters(in: .whitespacesAndNewlines),
           explicitRemoteItemId.caseInsensitiveCompare(remoteItemId) == .orderedSame {
            return true
        }

        let itemToken = "/Items/\(remoteItemId)"
        let streamToken = "/Videos/\(remoteItemId)/"
        let fallbackToken = "__\(remoteItemId)__"

        if task.remotePath.localizedCaseInsensitiveContains(itemToken) ||
            task.remotePath.localizedCaseInsensitiveContains(streamToken) ||
            task.remotePath.localizedCaseInsensitiveContains(remoteItemId) {
            return true
        }

        if task.fileName.localizedCaseInsensitiveContains(fallbackToken) ||
            task.fileName.localizedCaseInsensitiveContains(remoteItemId) {
            return true
        }

        guard let localFilePath, !localFilePath.isEmpty else { return false }
        let localName = URL(fileURLWithPath: localFilePath).lastPathComponent
        return localName.localizedCaseInsensitiveContains(fallbackToken) ||
            localName.localizedCaseInsensitiveContains(remoteItemId)
    }

    func enqueueDownload(
        server: ServerConfig,
        remotePath: String,
        fileName: String,
        totalBytes: Int64?,
        displayTitle: String? = nil,
        groupTitle: String? = nil
    ) {
        let descriptor = DownloadJobDescriptor(
            kind: .fileBatch,
            sourceType: DownloadSourceType(serverType: server.type),
            title: groupTitle ?? displayTitle ?? fileName,
            groupTitle: groupTitle
        )
        _ = enqueueRemoteFileBatch(
            server: server,
            items: [
                DownloadRemoteFileBatchItem(
                    remotePath: remotePath,
                    fileName: fileName,
                    displayTitle: displayTitle ?? fileName,
                    totalBytes: totalBytes,
                    groupIndex: 0
                )
            ],
            job: descriptor
        )
    }

    func pause(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        pauseMessageOverrides[id] = nil

        switch tasks[index].status {
        case .paused, .completed:
            return
        case .queued:
            let hasCheckpoint = tasks[index].resumeCapability == .resumable &&
                (tasks[index].resumeData?.isEmpty == false)
            tasks[index].status = .paused
            tasks[index].speedBytesPerSec = 0
            tasks[index].backgroundSessionTaskIdentifier = nil
            tasks[index].errorMessage = hasCheckpoint
                ? NSLocalizedString("Paused. Tap resume to continue.", comment: "")
                : NSLocalizedString("Paused. Resuming will restart the download.", comment: "")
            persistTasks()
            drainQueue()
        case .downloading:
            terminationReasons[id] = .pause
            tasks[index].speedBytesPerSec = 0
            persistTasks()

            if tasks[index].backgroundCapability == .backgroundTransfer {
                backgroundDownloadManager.pauseDownload(id: id)
            } else if let activeHTTPDownload = activeHTTPDownloads[id] {
                activeHTTPDownload.pause()
            } else {
                runningTasks[id]?.cancel()
            }
        case .failed, .canceled:
            return
        }
    }

    func resume(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        guard networkService.servers.first(where: { $0.id == tasks[index].serverId }) != nil else { return }
        pauseMessageOverrides[id] = nil

        if let block = activeDownloadPolicyBlock() {
            updateTask(id) {
                applyDownloadPolicyPausedState(to: &$0, message: block.message)
            }
            return
        }

        let canResumeFromCheckpoint = tasks[index].resumeCapability == .resumable &&
            (tasks[index].resumeData?.isEmpty == false)

        tasks[index].status = .queued
        tasks[index].speedBytesPerSec = 0
        tasks[index].errorMessage = nil
        tasks[index].localFilePath = nil
        tasks[index].backgroundSessionTaskIdentifier = nil

        if !canResumeFromCheckpoint {
            tasks[index].progress = 0
            tasks[index].bytesDownloaded = 0
            tasks[index].resumeData = nil
        }

        persistTasks()
        drainQueue()
    }

    func cancel(_ id: UUID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        pauseMessageOverrides[id] = nil

        if tasks[index].isRunning {
            terminationReasons[id] = .cancel

            if tasks[index].backgroundCapability == .backgroundTransfer {
                backgroundDownloadManager.cancelDownload(id: id)
            } else if let activeHTTPDownload = activeHTTPDownloads[id] {
                activeHTTPDownload.cancel()
            } else {
                runningTasks[id]?.cancel()
            }
            return
        }

        tasks[index].status = .canceled
        tasks[index].progress = 0
        tasks[index].bytesDownloaded = 0
        tasks[index].speedBytesPerSec = 0
        tasks[index].resumeData = nil
        tasks[index].backgroundSessionTaskIdentifier = nil
        tasks[index].stagingFilePath = nil
        tasks[index].localFilePath = nil
        tasks[index].errorMessage = NSLocalizedString("Canceled by user", comment: "")
        persistTasks()
        drainQueue()
    }

    func retry(_ id: UUID) {
        resume(id)
    }

    func pause(jobId: UUID) {
        let ids = tasks.filter { $0.jobId == jobId && ($0.status == .queued || $0.status == .downloading) }.map(\.id)
        for id in ids {
            pause(id)
        }
    }

    func resume(jobId: UUID) {
        let ids = tasks.filter { $0.jobId == jobId && ($0.status == .paused || $0.status == .failed || $0.status == .canceled) }.map(\.id)
        for id in ids {
            resume(id)
        }
    }

    func cancel(jobId: UUID) {
        let ids = tasks.filter { $0.jobId == jobId && $0.isActive }.map(\.id)
        for id in ids {
            cancel(id)
        }
    }

    func retry(jobId: UUID) {
        let ids = tasks.filter { $0.jobId == jobId && ($0.status == .failed || $0.status == .canceled) }.map(\.id)
        for id in ids {
            retry(id)
        }
    }

    func removeRecord(_ id: UUID, deleteLocalFile: Bool) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = tasks[index]
        if deleteLocalFile, let path = task.localFilePath {
            let fileURL = URL(fileURLWithPath: path)
            try? FileManager.default.removeItem(at: fileURL)
            Self.removeEmptyDownloadDirectories(
                afterRemoving: fileURL,
                rootDirectory: downloadsRootDirectory(fileManager: .default)
            )
        }
        if let stagingPath = task.stagingFilePath, !stagingPath.isEmpty {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: stagingPath))
        }
        if task.backgroundCapability == .backgroundTransfer {
            backgroundDownloadManager.cancelDownload(id: id)
        }
        backgroundSpeedSamples[id] = nil
        activeHTTPDownloads[id]?.cancel()
        activeHTTPDownloads[id] = nil
        terminationReasons[id] = nil
        runningTasks[id]?.cancel()
        runningTasks[id] = nil
        tasks.remove(at: index)
        OfflineMediaIndexStore.shared.unregister(task: task)
        persistTasks()
        drainQueue()
    }

    func removeJob(_ jobId: UUID, deleteLocalFile: Bool) {
        let ids = tasks.filter { $0.jobId == jobId }.map(\.id)
        for id in ids {
            removeRecord(id, deleteLocalFile: deleteLocalFile)
        }
    }

    func removeRecords(createdOn day: Date, statuses: [DownloadTaskStatus], deleteLocalFiles: Bool) {
        let ids = taskIDs(createdOn: day, statuses: statuses)
        for id in ids {
            removeRecord(id, deleteLocalFile: deleteLocalFiles)
        }
    }

    func removeRecords(statuses: [DownloadTaskStatus], deleteLocalFiles: Bool) {
        let ids = tasks.compactMap { task -> UUID? in
            statuses.contains(task.status) ? task.id : nil
        }
        for id in ids {
            removeRecord(id, deleteLocalFile: deleteLocalFiles)
        }
    }

    func clearDownloadedContent() {
        removeRecords(statuses: [.completed], deleteLocalFiles: true)
    }

    func pauseRecords(createdOn day: Date, statuses: [DownloadTaskStatus]) {
        let ids = taskIDs(createdOn: day, statuses: statuses)
        for id in ids {
            pause(id)
        }
    }

    func resumeRecords(createdOn day: Date, statuses: [DownloadTaskStatus]) {
        let ids = taskIDs(createdOn: day, statuses: statuses)
        for id in ids {
            resume(id)
        }
    }

    func cancelRecords(createdOn day: Date, statuses: [DownloadTaskStatus]) {
        let ids = taskIDs(createdOn: day, statuses: statuses)
        for id in ids {
            cancel(id)
        }
    }

    private func taskIDs(createdOn day: Date, statuses: [DownloadTaskStatus]) -> [UUID] {
        let calendar = Calendar.current
        return tasks.compactMap { task -> UUID? in
            guard statuses.contains(task.status),
                  calendar.isDate(task.createdAt, inSameDayAs: day) else { return nil }
            return task.id
        }
    }

    private func uniqueExistingLocalFileURLs(for tasks: [DownloadTaskItem]) -> [URL] {
        let uniquePaths = Array(Set(tasks.compactMap { task -> String? in
            guard let path = task.localFilePath, !path.isEmpty else { return nil }
            let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            guard FileManager.default.fileExists(atPath: standardizedPath) else { return nil }
            return standardizedPath
        })).sorted()

        return uniquePaths.map { URL(fileURLWithPath: $0) }
    }

    func updateTrackedLocalFileLocation(from oldURL: URL, to newURL: URL) {
        let missingMessage = NSLocalizedString("Downloaded file was removed from local storage.", comment: "")
        let oldPath = oldURL.standardizedFileURL.path
        let newPath = newURL.standardizedFileURL.path
        let oldDirectoryPrefix = oldPath.hasSuffix("/") ? oldPath : oldPath + "/"
        var didChange = false

        for index in tasks.indices {
            guard let path = tasks[index].localFilePath, !path.isEmpty else { continue }

            let trackedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            if trackedPath == oldPath {
                tasks[index].localFilePath = newPath
            } else if trackedPath.hasPrefix(oldDirectoryPrefix) {
                let suffix = String(trackedPath.dropFirst(oldDirectoryPrefix.count))
                tasks[index].localFilePath = newURL.appendingPathComponent(suffix).standardizedFileURL.path
            } else {
                continue
            }

            if tasks[index].status == .failed, tasks[index].errorMessage == missingMessage {
                tasks[index].status = .completed
            }
            if tasks[index].status == .completed {
                tasks[index].errorMessage = nil
            }
            didChange = true
        }

        if didChange {
            persistTasks()
        }
    }

    func reconcileMissingLocalFiles() {
        let fileManager = FileManager.default
        var didChange = false

        for index in tasks.indices {
            guard let path = tasks[index].localFilePath,
                  !path.isEmpty,
                  !fileManager.fileExists(atPath: path) else { continue }

            if tasks[index].status == .completed {
                tasks[index].status = .failed
                tasks[index].errorMessage = NSLocalizedString("Downloaded file was removed from local storage.", comment: "")
                didChange = true
            }
        }

        if didChange {
            persistTasks()
        }
    }

    private func checkpointAvailable(for task: DownloadTaskItem, resumeData: Data? = nil) -> Bool {
        guard task.resumeCapability == .resumable else { return false }
        return (resumeData ?? task.resumeData)?.isEmpty == false
    }

    private func pausedMessage(
        for _: DownloadResumeCapability,
        checkpointAvailable: Bool,
        interrupted: Bool
    ) -> String {
        switch (interrupted, checkpointAvailable) {
        case (true, true):
            return NSLocalizedString("Download was interrupted. Tap resume to continue.", comment: "")
        case (true, false):
            return NSLocalizedString("Download was interrupted. Resume will restart the download.", comment: "")
        case (false, true):
            return NSLocalizedString("Paused. Tap resume to continue.", comment: "")
        case (false, false):
            return NSLocalizedString("Paused. Resuming will restart the download.", comment: "")
        }
    }

    private func applyPausedState(
        to task: inout DownloadTaskItem,
        resumeData: Data?,
        interrupted: Bool,
        messageOverride: String? = nil
    ) {
        let hasCheckpoint = checkpointAvailable(for: task, resumeData: resumeData)
        task.status = .paused
        task.speedBytesPerSec = 0
        task.localFilePath = nil
        task.resumeData = hasCheckpoint ? resumeData : nil
        task.backgroundSessionTaskIdentifier = nil
        task.stagingFilePath = nil
        task.errorMessage = messageOverride ?? pausedMessage(
            for: task.resumeCapability,
            checkpointAvailable: hasCheckpoint,
            interrupted: interrupted
        )

        if hasCheckpoint {
            if task.bytesTotal > 0 {
                task.progress = min(1.0, Double(task.bytesDownloaded) / Double(task.bytesTotal))
            }
        } else {
            task.progress = 0
            task.bytesDownloaded = 0
        }
    }

    private func applyDownloadPolicyPausedState(to task: inout DownloadTaskItem, message: String) {
        task.status = .paused
        task.speedBytesPerSec = 0
        task.localFilePath = nil
        task.backgroundSessionTaskIdentifier = nil
        task.stagingFilePath = nil
        task.errorMessage = message
    }

    private func applyCanceledState(to task: inout DownloadTaskItem) {
        task.status = .canceled
        task.progress = 0
        task.bytesDownloaded = 0
        task.speedBytesPerSec = 0
        task.resumeData = nil
        task.backgroundSessionTaskIdentifier = nil
        task.stagingFilePath = nil
        task.localFilePath = nil
        task.errorMessage = NSLocalizedString("Canceled by user", comment: "")
    }

    private func resumeData(from error: Error) -> Data? {
        let nsError = error as NSError
        return nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
    }

    private func scheduleDownloadCompletionNotification(for task: DownloadTaskItem) {
#if os(iOS)
        guard AppSettings.shared.notifyWhenDownloadsFinish else { return }
        guard UIApplication.shared.applicationState != .active else { return }

        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized ||
                    settings.authorizationStatus == .provisional else {
                return
            }

            let content = UNMutableNotificationContent()
            content.title = NSLocalizedString("Download Complete", comment: "")
            content.body = String(
                format: NSLocalizedString("%@ is ready offline.", comment: ""),
                task.displayTitle
            )
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: "download-complete-\(task.id.uuidString)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)
        }
#endif
    }

    private func configureLifecycleObservers() {
#if os(iOS)
        let center = NotificationCenter.default

        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshBackgroundExecutionAssertion()
            }
        })

        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.endBackgroundExecutionAssertion()
                self?.applyDownloadPolicyToActiveTasksIfNeeded()
            }
        })

        lifecycleObservers.append(center.addObserver(
            forName: Notification.Name.NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyDownloadPolicyToActiveTasksIfNeeded()
            }
        })

        lifecycleObservers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.applyDownloadPolicyToActiveTasksIfNeeded()
            }
        })
#endif
    }

    private func configureDownloadPolicyMonitoring() {
        downloadPolicyNetworkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.currentNetworkPath = path
                self?.applyDownloadPolicyToActiveTasksIfNeeded()
            }
        }
        downloadPolicyNetworkMonitor.start(queue: downloadPolicyNetworkQueue)
    }

    private struct DownloadPolicyBlock {
        let message: String
    }

    private func activeDownloadPolicyBlock() -> DownloadPolicyBlock? {
        if AppSettings.shared.pauseDownloadsInLowPowerMode,
           ProcessInfo.processInfo.isLowPowerModeEnabled {
            return DownloadPolicyBlock(
                message: NSLocalizedString("Paused while Low Power Mode is on. Tap resume after turning it off.", comment: "")
            )
        }

        if AppSettings.shared.downloadOverWiFiOnly,
           let path = currentNetworkPath,
           !allowsDownloadUnderWiFiOnlyPolicy(path) {
            return DownloadPolicyBlock(
                message: NSLocalizedString("Waiting for Wi-Fi. Tap resume after connecting to Wi-Fi.", comment: "")
            )
        }

        return nil
    }

    private func allowsDownloadUnderWiFiOnlyPolicy(_ path: NWPath) -> Bool {
        path.status == .satisfied &&
            (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet))
    }

    private func applyDownloadPolicyToActiveTasksIfNeeded() {
        if let block = activeDownloadPolicyBlock() {
            let candidates = tasks
                .filter { $0.status == .queued || $0.status == .downloading }
                .map(\.id)

            for id in candidates {
                pauseForDownloadPolicy(id, message: block.message)
            }
        } else {
            drainQueue()
        }
    }

    private func pauseForDownloadPolicy(_ id: UUID, message: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }

        switch tasks[index].status {
        case .queued:
            updateTask(id) {
                applyDownloadPolicyPausedState(to: &$0, message: message)
            }
        case .downloading:
            pauseMessageOverrides[id] = message
            terminationReasons[id] = .pause
            updateTask(id) {
                $0.speedBytesPerSec = 0
                $0.errorMessage = message
            }

            if tasks[index].backgroundCapability == .backgroundTransfer {
                backgroundDownloadManager.pauseDownload(id: id)
            } else if let activeHTTPDownload = activeHTTPDownloads[id] {
                activeHTTPDownload.pause()
            } else {
                runningTasks[id]?.cancel()
            }
        case .paused, .completed, .failed, .canceled:
            break
        }
    }

#if os(iOS)
    private func refreshBackgroundExecutionAssertion() {
        let shouldHoldAssertion = UIApplication.shared.applicationState == .background && !runningTasks.isEmpty
        if shouldHoldAssertion {
            beginBackgroundExecutionAssertion()
        } else {
            endBackgroundExecutionAssertion()
        }
    }

    private func beginBackgroundExecutionAssertion() {
        guard backgroundTaskIdentifier == .invalid else { return }

        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "GenPlayer.Downloads") { [weak self] in
            Task { @MainActor in
                self?.handleBackgroundExecutionExpiration()
            }
        }
    }

    private func endBackgroundExecutionAssertion() {
        guard backgroundTaskIdentifier != .invalid else { return }

        let identifier = backgroundTaskIdentifier
        backgroundTaskIdentifier = .invalid
        UIApplication.shared.endBackgroundTask(identifier)
    }

    private func handleBackgroundExecutionExpiration() {
        let activeIDs = Array(runningTasks.keys)
        for id in activeIDs {
            terminationReasons[id] = .pause
            if let activeHTTPDownload = activeHTTPDownloads[id] {
                activeHTTPDownload.pause()
            } else {
                runningTasks[id]?.cancel()
            }
        }

        endBackgroundExecutionAssertion()
    }
#else
    private func refreshBackgroundExecutionAssertion() {}
#endif

    private func restoreBackgroundDownloads() {
        let candidateTasks = tasks.filter { $0.backgroundCapability == .backgroundTransfer }
        guard !candidateTasks.isEmpty else {
            recoverInterruptedTasks(preservingActiveBackgroundTransfers: [])
            drainQueue()
            return
        }

        backgroundDownloadManager.reconnectPersistedDownloads(persistedTasks: candidateTasks) { [weak self] activeIDs in
            Task { @MainActor in
                self?.recoverInterruptedTasks(preservingActiveBackgroundTransfers: activeIDs)
                self?.drainQueue()
            }
        }
    }

    private func startDownload(for id: UUID, server: ServerConfig) {
        guard let taskItem = tasks.first(where: { $0.id == id }) else { return }

        if let block = activeDownloadPolicyBlock() {
            updateTask(id) {
                applyDownloadPolicyPausedState(to: &$0, message: block.message)
            }
            return
        }

        if taskItem.backgroundCapability == .backgroundTransfer,
           let request = networkService.downloadRequest(server: server, at: taskItem.remotePath) {
            startBackgroundDownload(for: taskItem, request: request)
            return
        }

        guard runningTasks[id] == nil else { return }

        updateTask(id) {
            $0.status = .downloading
            $0.errorMessage = nil
            $0.speedBytesPerSec = 0
            $0.backgroundSessionTaskIdentifier = nil
        }

        let work = Task {
            let currentTask = tasks.first(where: { $0.id == id }) ?? taskItem
            var lastObservedBytes: Int64 = currentTask.bytesDownloaded
            var lastPublishedAt = Date()
            var sampledBytes: Int64 = 0
            var lastSpeedSampleAt = Date()
            var smoothedSpeedBytesPerSec = 0.0

            defer {
                activeHTTPDownloads[id] = nil
                terminationReasons[id] = nil
                pauseMessageOverrides[id] = nil
                runningTasks[id] = nil
                refreshBackgroundExecutionAssertion()
                DownloadCenterService.shared.drainQueue()
            }

            do {
                let progressHandler: (Int64, Int64) -> Void = { [weak self] downloaded, total in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.tasks.first(where: { $0.id == id })?.status == .downloading else { return }
                        let now = Date()
                        let deltaBytes = max(0, downloaded - lastObservedBytes)
                        lastObservedBytes = downloaded
                        sampledBytes += deltaBytes

                        let speedSampleElapsed = now.timeIntervalSince(lastSpeedSampleAt)
                        let shouldRefreshSpeed = speedSampleElapsed >= 0.9 || (total > 0 && downloaded >= total)

                        if shouldRefreshSpeed {
                            let instantaneousSpeed = Double(sampledBytes) / max(0.001, speedSampleElapsed)
                            smoothedSpeedBytesPerSec = smoothedSpeedBytesPerSec == 0
                                ? instantaneousSpeed
                                : (smoothedSpeedBytesPerSec * 0.65) + (instantaneousSpeed * 0.35)
                            sampledBytes = 0
                            lastSpeedSampleAt = now
                        }

                        let publishElapsed = now.timeIntervalSince(lastPublishedAt)
                        let shouldPublishProgress = publishElapsed >= 0.35 || shouldRefreshSpeed || (total > 0 && downloaded >= total)
                        guard shouldPublishProgress else { return }

                        lastPublishedAt = now

                        self.updateTask(id, shouldPersist: false) {
                            $0.bytesDownloaded = downloaded
                            if total > 0 { $0.bytesTotal = total }
                            if $0.bytesTotal > 0 {
                                $0.progress = min(1.0, Double(downloaded) / Double($0.bytesTotal))
                            }
                            if shouldRefreshSpeed {
                                $0.speedBytesPerSec = smoothedSpeedBytesPerSec
                            }
                        }
                    }
                }

                let tempURL: URL
                if let request = networkService.downloadRequest(server: server, at: currentTask.remotePath) {
                    let managedDownload = ManagedHTTPDownload(request: request, progressHandler: progressHandler)
                    activeHTTPDownloads[id] = managedDownload

                    do {
                        tempURL = try await managedDownload.start(resumeData: currentTask.resumeData)
                    } catch HTTPManagedDownloadInterruption.paused(let resumeData) {
                        updateTask(id) {
                            applyPausedState(
                                to: &$0,
                                resumeData: resumeData,
                                interrupted: false,
                                messageOverride: pauseMessageOverrides[id]
                            )
                        }
                        return
                    }
                } else {
                    tempURL = try await networkService.downloadFile(
                        server: server,
                        at: currentTask.remotePath,
                        progress: progressHandler
                    )
                }

                if let terminationReason = terminationReasons[id] {
                    try? FileManager.default.removeItem(at: tempURL)
                    updateTask(id) {
                        switch terminationReason {
                        case .pause:
                            applyPausedState(
                                to: &$0,
                                resumeData: nil,
                                interrupted: false,
                                messageOverride: pauseMessageOverrides[id]
                            )
                        case .cancel:
                            applyCanceledState(to: &$0)
                        }
                    }
                    return
                }

                if Task.isCancelled {
                    try? FileManager.default.removeItem(at: tempURL)
                    updateTask(id) {
                        applyPausedState(to: &$0, resumeData: nil, interrupted: true)
                    }
                    return
                }

                let completedBytes = try DownloadFileValidation.validateFile(at: tempURL)
                let destinationURL = try self.persistDownloadedFile(
                    from: tempURL,
                    task: tasks.first(where: { $0.id == id }) ?? taskItem
                )

                updateTask(id) {
                    $0.status = .completed
                    $0.progress = 1
                    $0.resumeData = nil
                    $0.backgroundSessionTaskIdentifier = nil
                    $0.stagingFilePath = nil
                    $0.localFilePath = destinationURL.path
                    $0.errorMessage = nil
                    $0.bytesTotal = completedBytes
                    $0.bytesDownloaded = completedBytes
                    $0.speedBytesPerSec = 0
                }
                if let completedTask = tasks.first(where: { $0.id == id }) {
                    scheduleDownloadCompletionNotification(for: completedTask)
                }
            } catch {
                if let terminationReason = terminationReasons[id] {
                    updateTask(id) {
                        switch terminationReason {
                        case .pause:
                            applyPausedState(
                                to: &$0,
                                resumeData: resumeData(from: error),
                                interrupted: false,
                                messageOverride: pauseMessageOverrides[id]
                            )
                        case .cancel:
                            applyCanceledState(to: &$0)
                        }
                    }
                } else if let resumeData = resumeData(from: error) {
                    updateTask(id) {
                        applyPausedState(to: &$0, resumeData: resumeData, interrupted: true)
                    }
                } else if Task.isCancelled {
                    updateTask(id) {
                        applyPausedState(to: &$0, resumeData: nil, interrupted: true)
                    }
                } else {
                    updateTask(id) {
                        $0.status = .failed
                        $0.errorMessage = error.localizedDescription
                        $0.speedBytesPerSec = 0
                        $0.resumeData = nil
                        $0.backgroundSessionTaskIdentifier = nil
                        $0.stagingFilePath = nil
                        $0.localFilePath = nil
                    }
                }
            }
        }

        runningTasks[id] = work
        refreshBackgroundExecutionAssertion()
    }

    private func startBackgroundDownload(for taskItem: DownloadTaskItem, request: URLRequest) {
        guard taskItem.backgroundCapability == .backgroundTransfer else { return }
        guard taskItem.status == .queued || taskItem.status == .paused || taskItem.status == .failed || taskItem.status == .canceled else { return }

        let now = Date()
        backgroundSpeedSamples[taskItem.id] = DownloadSpeedSample(initialBytes: taskItem.bytesDownloaded, now: now)

        let sessionTaskIdentifier = backgroundDownloadManager.startDownload(
            id: taskItem.id,
            request: request,
            resumeData: taskItem.resumeData
        )

        updateTask(taskItem.id) {
            $0.status = .downloading
            $0.errorMessage = nil
            $0.speedBytesPerSec = 0
            $0.backgroundSessionTaskIdentifier = sessionTaskIdentifier
        }
    }

    private func persistDownloadedFile(from tempURL: URL, task: DownloadTaskItem) throws -> URL {
        let fileManager = FileManager.default
        let expectedBytes: Int64?
        switch task.sourceType {
        case .smb, .ftp, .sftp, .nfs:
            expectedBytes = task.bytesTotal > 0 ? task.bytesTotal : nil
        default:
            expectedBytes = nil // HTTP artifacts were checked against the actual response.
        }
        do {
            try DownloadFileValidation.validateFile(at: tempURL, expectedBytes: expectedBytes)
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
        let server = networkService.servers.first(where: { $0.id == task.serverId })
        let destinationDirectory = downloadDestinationDirectory(for: task, server: server, fileManager: fileManager)
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationURL = uniqueDownloadDestinationURL(
            in: destinationDirectory,
            preferredFileName: task.fileName,
            currentLocation: nil,
            fileManager: fileManager
        )

        do {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } catch {
            try fileManager.copyItem(at: tempURL, to: destinationURL)
            try? fileManager.removeItem(at: tempURL)
        }

        return destinationURL
    }

    private func migrateTrackedDownloadDirectoriesIfNeeded() {
        let fileManager = FileManager.default
        let downloadsRootPath = downloadsRootDirectory(fileManager: fileManager).standardizedFileURL.path
        var didChange = false

        for index in tasks.indices {
            guard tasks[index].status == .completed,
                  let rawPath = tasks[index].localFilePath,
                  !rawPath.isEmpty else {
                continue
            }

            let currentURL = URL(fileURLWithPath: rawPath).standardizedFileURL
            guard currentURL.path.hasPrefix(downloadsRootPath),
                  fileManager.fileExists(atPath: currentURL.path) else {
                continue
            }

            let server = networkService.servers.first(where: { $0.id == tasks[index].serverId })
            let destinationDirectory = downloadDestinationDirectory(for: tasks[index], server: server, fileManager: fileManager)

            do {
                try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                let destinationURL = uniqueDownloadDestinationURL(
                    in: destinationDirectory,
                    preferredFileName: currentURL.lastPathComponent,
                    currentLocation: currentURL,
                    fileManager: fileManager
                )

                if destinationURL.standardizedFileURL.path == currentURL.path {
                    continue
                }

                do {
                    try fileManager.moveItem(at: currentURL, to: destinationURL)
                } catch {
                    try fileManager.copyItem(at: currentURL, to: destinationURL)
                    try? fileManager.removeItem(at: currentURL)
                }

                tasks[index].localFilePath = destinationURL.path
                didChange = true
            } catch {
                continue
            }
        }

        if didChange {
            persistTasks()
        }
    }

    // Walk only the deleted file's ancestors; never scan or remove Downloads itself.
    static func removeEmptyDownloadDirectories(afterRemoving fileURL: URL, rootDirectory: URL) {
        let root = rootDirectory.standardizedFileURL
        var directory = fileURL.standardizedFileURL.deletingLastPathComponent()
        guard directory.pathComponents.count > root.pathComponents.count,
              directory.pathComponents.starts(with: root.pathComponents) else { return }

        // Refuse symbolic-link ancestors so cleanup cannot follow a redirected directory.
        var ancestor = directory
        while true {
            guard let values = try? ancestor.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { return }
            if ancestor.path == root.path { break }
            ancestor = ancestor.deletingLastPathComponent()
        }

        while directory.pathComponents.count > root.pathComponents.count {
            // rmdir atomically refuses nonempty directories, including hidden files and
            // files that another download wrote after cleanup started. Never recurse.
            let removed = directory.withUnsafeFileSystemRepresentation { path in
                guard let path = path else { return false }
                return Darwin.rmdir(path) == 0
            }
            guard removed else { return }
            directory = directory.deletingLastPathComponent()
        }
    }

    private func downloadsRootDirectory(fileManager: FileManager) -> URL {
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
    }

    private func downloadDestinationDirectory(
        for task: DownloadTaskItem,
        server: ServerConfig?,
        fileManager: FileManager
    ) -> URL {
        let serverRoot = serverDownloadDirectory(for: task, server: server, fileManager: fileManager)
        let storageComponents = downloadStorageSubdirectories(for: task)
        return storageComponents.reduce(serverRoot) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }
    }

    private func serverDownloadDirectory(
        for task: DownloadTaskItem,
        server: ServerConfig?,
        fileManager: FileManager
    ) -> URL {
        let serverTypeName = server?.type.rawValue.capitalized ?? task.sourceType.rawValue.capitalized
        let serverName = server?.name ?? task.serverName
        let typeDirectory = sanitizedPathComponent(serverTypeName, fallback: "Servers")
        let serverDirectory = sanitizedPathComponent(serverName, fallback: task.serverId.uuidString)

        return downloadsRootDirectory(fileManager: fileManager)
            .appendingPathComponent(typeDirectory, isDirectory: true)
            .appendingPathComponent(serverDirectory, isDirectory: true)
    }

    private func downloadStorageSubdirectories(for task: DownloadTaskItem) -> [String] {
        switch task.sourceType {
        case .jellyfin, .emby, .plex:
            return mediaServerStorageSubdirectories(for: task)
        case .smb, .webdav, .alist, .pan115, .onedrive, .googledrive, .ftp, .sftp, .nfs:
            return remoteFileStorageSubdirectories(for: task)
        case .localImport:
            return ["Local Imports"]
        case .unknown:
            return ["Others"]
        }
    }

    private func mediaServerStorageSubdirectories(for task: DownloadTaskItem) -> [String] {
        guard let seriesFolder = inferredSeriesFolderName(for: task) else {
            return ["Movies"]
        }

        var components = ["TV Shows", seriesFolder]
        if let seasonFolder = inferredSeasonFolderName(for: task) {
            components.append(seasonFolder)
        }
        return components
    }

    private func remoteFileStorageSubdirectories(for task: DownloadTaskItem) -> [String] {
        let parentComponents = remoteParentDirectoryComponents(for: task)
        return ["Files"] + parentComponents
    }

    private func remoteParentDirectoryComponents(for task: DownloadTaskItem) -> [String] {
        let normalizedPath = task.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else { return [] }

        let pathString: String
        if let absoluteURL = URL(string: normalizedPath), absoluteURL.scheme != nil {
            pathString = absoluteURL.path
        } else {
            pathString = normalizedPath
        }

        let rawComponents = pathString
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/")
            .map(String.init)

        guard rawComponents.count > 1 else { return [] }
        return rawComponents.dropLast().map {
            sanitizedPathComponent($0, fallback: "Folder")
        }
    }

    private func inferredSeriesFolderName(for task: DownloadTaskItem) -> String? {
        guard let episodeTitlePrefix = episodeTitlePrefix(from: task.fileName)
            ?? episodeTitlePrefix(from: task.displayTitle)
            ?? episodeTitlePrefix(from: task.groupTitle) else {
            return nil
        }

        if task.seriesId != nil || task.seasonId != nil || looksLikeEpisodeTitle(task.fileName) {
            return sanitizedPathComponent(episodeTitlePrefix, fallback: "TV Show")
        }
        return nil
    }

    private func inferredSeasonFolderName(for task: DownloadTaskItem) -> String? {
        if let seasonNumber = seasonNumber(from: task.fileName) ?? seasonNumber(from: task.displayTitle) {
            return String(format: "Season %02d", seasonNumber)
        }
        return nil
    }

    private func episodeTitlePrefix(from rawValue: String?) -> String? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        let stem = URL(fileURLWithPath: rawValue).deletingPathExtension().lastPathComponent
        guard let range = stem.range(of: #" - S\d{1,2}E\d{1,3}\b"#, options: .regularExpression) else {
            return nil
        }

        let prefix = String(stem[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? nil : prefix
    }

    private func looksLikeEpisodeTitle(_ rawValue: String?) -> Bool {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return false
        }

        let stem = URL(fileURLWithPath: rawValue).deletingPathExtension().lastPathComponent
        return stem.range(of: #"\bS\d{1,2}E\d{1,3}\b"#, options: .regularExpression) != nil
    }

    private func seasonNumber(from rawValue: String?) -> Int? {
        guard let rawValue = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty,
              let range = rawValue.range(of: #"\bS(\d{1,2})E\d{1,3}\b"#, options: .regularExpression) else {
            return nil
        }

        let match = String(rawValue[range])
        guard let seasonRange = match.range(of: #"S(\d{1,2})"#, options: .regularExpression) else {
            return nil
        }

        return Int(match[seasonRange].dropFirst())
    }

    private func uniqueDownloadDestinationURL(
        in directory: URL,
        preferredFileName: String,
        currentLocation: URL?,
        fileManager: FileManager
    ) -> URL {
        let sanitizedName = sanitizedDownloadFileName(preferredFileName)
        let sourceURL = URL(fileURLWithPath: sanitizedName)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        let normalizedCurrentPath = currentLocation?.standardizedFileURL.path

        var destinationURL = directory.appendingPathComponent(sanitizedName)
        var counter = 1

        while fileManager.fileExists(atPath: destinationURL.path) &&
                destinationURL.standardizedFileURL.path != normalizedCurrentPath {
            let nextName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            destinationURL = directory.appendingPathComponent(nextName)
            counter += 1
        }

        return destinationURL
    }

    private func sanitizedDownloadFileName(_ rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = trimmed
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        return sanitized.isEmpty ? UUID().uuidString : sanitized
    }

    private func sanitizedPathComponent(_ rawValue: String, fallback: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let replaced = rawValue.components(separatedBy: invalidCharacters).joined(separator: "_")
        let normalizedWhitespace = replaced.replacingOccurrences(
            of: #"\s+"#,
            with: " ",
            options: .regularExpression
        )
        let trimmed = normalizedWhitespace.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func updateTask(_ id: UUID, shouldPersist: Bool = true, mutate: (inout DownloadTaskItem) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let oldStatus = tasks[index].status
        mutate(&tasks[index])
        let updatedTask = tasks[index]
        if shouldPersist {
            persistTasks()
        }
        if updatedTask.status == .completed {
            OfflineMediaIndexStore.shared.registerCompleted(task: updatedTask)
        } else if oldStatus == .completed && updatedTask.status != .completed {
            OfflineMediaIndexStore.shared.unregister(task: updatedTask)
        }
    }

    private func loadPersistedTasks() {
        guard let data = try? Data(contentsOf: persistenceURL),
              let decoded = try? JSONDecoder().decode([DownloadTaskItem].self, from: data) else { return }
        tasks = normalizePersistedTasks(decoded).sorted { $0.createdAt > $1.createdAt }
        persistTasks()
    }

    private func recoverInterruptedTasks(preservingActiveBackgroundTransfers activeBackgroundTransfers: Set<UUID>) {
        var didChange = false

        for index in tasks.indices {
            tasks[index].speedBytesPerSec = 0

            if activeBackgroundTransfers.contains(tasks[index].id) {
                tasks[index].status = .downloading
                tasks[index].errorMessage = nil
                didChange = true
                continue
            }

            switch tasks[index].status {
            case .queued, .downloading:
                applyPausedState(to: &tasks[index], resumeData: tasks[index].resumeData, interrupted: true)
                didChange = true
            case .paused:
                if tasks[index].errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    tasks[index].errorMessage = pausedMessage(
                        for: tasks[index].resumeCapability,
                        checkpointAvailable: checkpointAvailable(for: tasks[index]),
                        interrupted: false
                    )
                    didChange = true
                }
            case .completed, .failed, .canceled:
                break
            }
        }

        if didChange {
            persistTasks()
        }
    }

    private func persistTasks() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        let targetURL = persistenceURL
        persistenceQueue.async {
            try? data.write(to: targetURL, options: .atomic)
        }
    }

    private func normalizePersistedTasks(_ decoded: [DownloadTaskItem]) -> [DownloadTaskItem] {
        decoded.map { task in
            var normalized = task
            if normalized.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                normalized.displayTitle = normalized.fileName
            }
            if normalized.sourceType == .unknown,
               let serverType = networkService.servers.first(where: { $0.id == normalized.serverId })?.type {
                normalized.sourceType = DownloadSourceType(serverType: serverType)
            }
            if normalized.jobKind == .singleMedia && normalized.groupTitle == nil {
                normalized.groupTitle = normalized.displayTitle
            }
            if normalized.resumeCapability == .unknown {
                normalized.resumeCapability = DownloadResumeCapability(sourceType: normalized.sourceType)
            }
            if normalized.backgroundCapability == .unknown {
                normalized.backgroundCapability = DownloadBackgroundCapability(sourceType: normalized.sourceType)
            }
            if normalized.status != .queued && normalized.status != .downloading {
                normalized.backgroundSessionTaskIdentifier = nil
            }
            if normalized.status == .completed {
                normalized.progress = 1
                normalized.resumeData = nil
                normalized.backgroundSessionTaskIdentifier = nil
                normalized.stagingFilePath = nil
            } else if normalized.status == .canceled {
                normalized.resumeData = nil
                normalized.backgroundSessionTaskIdentifier = nil
                normalized.stagingFilePath = nil
            } else if normalized.bytesTotal > 0 {
                normalized.progress = min(1.0, Double(normalized.bytesDownloaded) / Double(normalized.bytesTotal))
            }
            return normalized
        }
    }

    private func bestTask(serverId: UUID, remoteItemId: String) -> DownloadTaskItem? {
        bestTask { task in
            guard task.serverId == serverId else { return false }
            return taskMatches(task, remoteItemId: remoteItemId, localFilePath: task.localFilePath)
        }
    }

    private func bestTask(serverId: UUID, remotePath: String) -> DownloadTaskItem? {
        bestTask { task in
            task.serverId == serverId && task.remotePath == remotePath
        }
    }

    private func bestTask(where predicate: (DownloadTaskItem) -> Bool) -> DownloadTaskItem? {
        tasks.filter(predicate).sorted(by: isPreferredTask(_:over:)).first
    }

    private func validatedLocalFileURL(for task: DownloadTaskItem?) -> URL? {
        guard let task,
              task.status == .completed,
              let path = task.localFilePath,
              !path.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private func isPreferredTask(_ lhs: DownloadTaskItem, over rhs: DownloadTaskItem) -> Bool {
        let lhsRank = statusRank(lhs.status)
        let rhsRank = statusRank(rhs.status)
        if lhsRank == rhsRank {
            return lhs.createdAt > rhs.createdAt
        }
        return lhsRank < rhsRank
    }

    private func statusRank(_ status: DownloadTaskStatus) -> Int {
        switch status {
        case .downloading: return 0
        case .queued: return 1
        case .paused: return 2
        case .completed: return 3
        case .failed: return 4
        case .canceled: return 5
        }
    }

    private func aggregateState(for matches: [DownloadTaskItem], totalExpected: Int) -> DownloadAggregateState {
        guard !matches.isEmpty else { return .notDownloaded }

        let completed = matches.filter { $0.status == .completed }.count
        let failed = matches.filter { $0.status == .failed || $0.status == .canceled }.count
        let downloading = matches.filter { $0.status == .downloading }.count
        let queued = matches.filter { $0.status == .queued }.count
        let paused = matches.filter { $0.status == .paused }.count

        if completed == totalExpected {
            return .downloaded
        }
        if downloading > 0 {
            return .downloading(completed: completed, total: totalExpected)
        }
        if queued > 0 || paused > 0 {
            return .queued(completed: completed, total: totalExpected)
        }
        if completed > 0 {
            return .partiallyDownloaded(completed: completed, total: totalExpected)
        }
        if failed > 0 {
            return .failed(completed: completed, total: totalExpected)
        }
        return .notDownloaded
    }
}

extension DownloadCenterService: @preconcurrency BackgroundDownloadSessionManagerDelegate {
    func backgroundDownloadSessionManager(
        _ manager: BackgroundDownloadSessionManager,
        didReconnectDownload id: UUID,
        sessionTaskIdentifier: Int,
        bytesDownloaded: Int64,
        totalBytes: Int64
    ) {
        guard let task = tasks.first(where: { $0.id == id }) else {
            manager.cancelDownload(id: id)
            return
        }
        guard task.status == .queued || task.status == .downloading else {
            manager.cancelDownload(id: id)
            return
        }

        backgroundSpeedSamples[id] = DownloadSpeedSample(initialBytes: bytesDownloaded)
        updateTask(id) {
            $0.status = .downloading
            $0.errorMessage = nil
            $0.speedBytesPerSec = 0
            $0.backgroundSessionTaskIdentifier = sessionTaskIdentifier
            $0.bytesDownloaded = max($0.bytesDownloaded, bytesDownloaded)
            if totalBytes > 0 {
                $0.bytesTotal = max($0.bytesTotal, totalBytes)
            }
            if $0.bytesTotal > 0 {
                $0.progress = min(1.0, Double($0.bytesDownloaded) / Double($0.bytesTotal))
            }
        }
    }

    func backgroundDownloadSessionManager(
        _ manager: BackgroundDownloadSessionManager,
        didUpdateDownload id: UUID,
        bytesDownloaded: Int64,
        totalBytes: Int64
    ) {
        guard let existingTask = tasks.first(where: { $0.id == id }) else {
            manager.cancelDownload(id: id)
            return
        }
        guard existingTask.status == .queued || existingTask.status == .downloading else {
            if existingTask.status == .completed {
                manager.cancelDownload(id: id)
            }
            return
        }

        var sample = backgroundSpeedSamples[id] ?? DownloadSpeedSample(
            initialBytes: max(existingTask.bytesDownloaded, bytesDownloaded)
        )

        let now = Date()
        let deltaBytes = max(0, bytesDownloaded - sample.lastObservedBytes)
        sample.lastObservedBytes = bytesDownloaded
        sample.sampledBytes += deltaBytes

        let speedSampleElapsed = now.timeIntervalSince(sample.lastSpeedSampleAt)
        let shouldRefreshSpeed = speedSampleElapsed >= 0.9 || (totalBytes > 0 && bytesDownloaded >= totalBytes)

        if shouldRefreshSpeed {
            let instantaneousSpeed = Double(sample.sampledBytes) / max(0.001, speedSampleElapsed)
            sample.smoothedSpeedBytesPerSec = sample.smoothedSpeedBytesPerSec == 0
                ? instantaneousSpeed
                : (sample.smoothedSpeedBytesPerSec * 0.65) + (instantaneousSpeed * 0.35)
            sample.sampledBytes = 0
            sample.lastSpeedSampleAt = now
        }

        let publishElapsed = now.timeIntervalSince(sample.lastPublishedAt)
        let shouldPublishProgress = publishElapsed >= 0.35 || shouldRefreshSpeed || (totalBytes > 0 && bytesDownloaded >= totalBytes)

        if shouldPublishProgress {
            sample.lastPublishedAt = now
            updateTask(id, shouldPersist: false) {
                $0.status = .downloading
                $0.bytesDownloaded = bytesDownloaded
                if totalBytes > 0 {
                    $0.bytesTotal = totalBytes
                }
                if $0.bytesTotal > 0 {
                    $0.progress = min(1.0, Double(bytesDownloaded) / Double($0.bytesTotal))
                }
                if shouldRefreshSpeed {
                    $0.speedBytesPerSec = sample.smoothedSpeedBytesPerSec
                }
            }
        }

        backgroundSpeedSamples[id] = sample
    }

    func backgroundDownloadSessionManager(
        _ manager: BackgroundDownloadSessionManager,
        didFinishDownloading id: UUID,
        to stagingURL: URL
    ) {
        guard let task = tasks.first(where: { $0.id == id }) else {
            try? FileManager.default.removeItem(at: stagingURL)
            manager.cancelDownload(id: id)
            return
        }
        guard (task.status == .queued || task.status == .downloading), terminationReasons[id] == nil else {
            try? FileManager.default.removeItem(at: stagingURL)
            return
        }

        updateTask(id) {
            $0.stagingFilePath = stagingURL.path
        }

        do {
            let completedBytes = try DownloadFileValidation.validateFile(at: stagingURL)
            let destinationURL = try persistDownloadedFile(
                from: stagingURL,
                task: task
            )

            updateTask(id) {
                $0.status = .completed
                $0.progress = 1
                $0.resumeData = nil
                $0.backgroundSessionTaskIdentifier = nil
                $0.stagingFilePath = nil
                $0.localFilePath = destinationURL.path
                $0.errorMessage = nil
                $0.bytesTotal = completedBytes
                $0.bytesDownloaded = completedBytes
                $0.speedBytesPerSec = 0
            }
            if let completedTask = tasks.first(where: { $0.id == id }) {
                scheduleDownloadCompletionNotification(for: completedTask)
            }
        } catch {
            removeStagingFile(for: id)
            updateTask(id) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
                $0.speedBytesPerSec = 0
                $0.resumeData = nil
                $0.backgroundSessionTaskIdentifier = nil
                $0.stagingFilePath = nil
                $0.localFilePath = nil
            }
        }
        drainQueue()
    }

    func backgroundDownloadSessionManager(
        _ manager: BackgroundDownloadSessionManager,
        didCompleteDownload id: UUID,
        error: Error?,
        resumeData: Data?
    ) {
        defer {
            backgroundSpeedSamples[id] = nil
            terminationReasons[id] = nil
            pauseMessageOverrides[id] = nil
            drainQueue()
        }

        guard let task = tasks.first(where: { $0.id == id }) else {
            removeStagingFile(for: id)
            return
        }

        if task.status == .completed {
            updateTask(id) {
                $0.backgroundSessionTaskIdentifier = nil
                $0.resumeData = nil
                $0.stagingFilePath = nil
                $0.errorMessage = nil
            }
            return
        }

        if let terminationReason = terminationReasons[id] {
            removeStagingFile(for: id)
            updateTask(id) {
                switch terminationReason {
                case .pause:
                    applyPausedState(
                        to: &$0,
                        resumeData: resumeData,
                        interrupted: false,
                        messageOverride: pauseMessageOverrides[id]
                    )
                case .cancel:
                    applyCanceledState(to: &$0)
                }
            }
            return
        }

        guard let error else {
            updateTask(id) {
                $0.backgroundSessionTaskIdentifier = nil
                $0.resumeData = nil
                $0.stagingFilePath = nil
            }
            return
        }

        removeStagingFile(for: id)

        let nsError = error as NSError
        if let resumeData {
            updateTask(id) {
                applyPausedState(to: &$0, resumeData: resumeData, interrupted: true)
            }
        } else if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
            updateTask(id) {
                applyPausedState(to: &$0, resumeData: nil, interrupted: true)
            }
        } else {
            updateTask(id) {
                $0.status = .failed
                $0.errorMessage = error.localizedDescription
                $0.speedBytesPerSec = 0
                $0.resumeData = nil
                $0.backgroundSessionTaskIdentifier = nil
                $0.stagingFilePath = nil
                $0.localFilePath = nil
            }
        }
    }

    private func removeStagingFile(for id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }),
              let stagingPath = task.stagingFilePath,
              !stagingPath.isEmpty else { return }

        try? FileManager.default.removeItem(at: URL(fileURLWithPath: stagingPath))
        let directoryURL = URL(fileURLWithPath: stagingPath).deletingLastPathComponent()
        try? FileManager.default.removeItem(at: directoryURL)
    }
}

// MARK: - Plex Probe TLS Trust Delegate

/// URLSession delegate used during Plex connection probing that trusts
/// self-signed TLS certificates. Plex Media Server generates self-signed
/// certs for local network HTTPS and may redirect HTTP → HTTPS.
private final class PlexProbeTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
