import Foundation
import AMSMB2
#if os(iOS)
import UIKit
#endif
import Network

public class AppNetworkService: ObservableObject {
    public static let shared = AppNetworkService()
    public static let didUpdateServersNotification = Notification.Name("AppNetworkServiceDidUpdateServers")

    @Published public var savedServers: [ServerConfig] = []
    
    public var servers: [ServerConfig] {
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
    private let smbClientsLock = NSRecursiveLock()
    private var smbClients: [UUID: SMB2Manager] = [:]
    
    // Dependencies
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
    
    private init() {
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

    public func reloadServers() {
        loadServers()
    }
    
    public func addServer(_ server: ServerConfig) {
        savedServers.append(server)
        saveServers()
    }
    
    public func deleteServer(_ server: ServerConfig) {
        savedServers.removeAll { $0.id == server.id }
        cleanupRemovedServerData(for: server)
        saveServers()
    }

    public func clearAllServers() {
        let serversToDelete = savedServers
        guard !serversToDelete.isEmpty else { return }

        for server in serversToDelete {
            cleanupRemovedServerData(for: server)
        }

        savedServers.removeAll()
        saveServers()
    }

    public func clearServers(of type: ServerConfig.ServerType) {
        let serversToDelete = savedServers.filter { $0.type == type }
        guard !serversToDelete.isEmpty else { return }

        for server in serversToDelete {
            cleanupRemovedServerData(for: server)
        }

        savedServers.removeAll { $0.type == type }
        saveServers()
    }

    public func clearNonIPTVServers() {
        let serversToDelete = savedServers.filter { $0.type != .iptv }
        guard !serversToDelete.isEmpty else { return }

        for server in serversToDelete {
            cleanupRemovedServerData(for: server)
        }

        savedServers.removeAll { $0.type != .iptv }
        saveServers()
    }
    
    public func updateServer(_ server: ServerConfig) {
        if let index = savedServers.firstIndex(where: { $0.id == server.id }) {
            var updated = server
            if updated.type == .vod, updated.vodSources == nil {
                updated.vodSources = savedServers[index].vodSources
            }
            if updated.passwordSecret == nil {
                updated.passwordSecret = savedServers[index].passwordSecret ?? KeychainService.get(for: passwordKey(for: server.id))
            }
            if updated.accessToken == nil {
                updated.accessToken = savedServers[index].accessToken ?? KeychainService.get(for: accessTokenKey(for: server.id))
            }
            savedServers[index] = updated
            if updated.type == .smb {
                smbClientsLock.lock()
                smbClients.removeValue(forKey: updated.id) // Invalidate cached client
                smbClientsLock.unlock()
            }
            saveServers()
        }
    }

    public func recordServerAccess(_ serverId: UUID, date: Date = Date()) {
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

    public func clearServerAuthTokens(for serverId: UUID) {
        if let index = savedServers.firstIndex(where: { $0.id == serverId }) {
            savedServers[index].accessToken = nil
            savedServers[index].userId = nil
        }
        KeychainService.delete(for: accessTokenKey(for: serverId))
        saveServers()
    }

    public func updateServerTokens(_ serverId: UUID, accessToken: String, refreshToken: String) {
        if let index = savedServers.firstIndex(where: { $0.id == serverId }) {
            savedServers[index].accessToken = accessToken
            savedServers[index].passwordSecret = refreshToken
            KeychainService.set(refreshToken, for: passwordKey(for: serverId))
            KeychainService.set(accessToken, for: accessTokenKey(for: serverId))
            saveServers()
        }
    }
    
    public func moveServer(from source: IndexSet, to destination: Int) {
        savedServers.move(fromOffsets: source, toOffset: destination)
        saveServers()
    }
    
    public func persistServers() {
        saveServers()
    }

    public func exportServerBackupData() throws -> Data {
        let payload = ServerBackupPayload(
            app: "GenPlayer",
            version: 1,
            exportedAt: Date().timeIntervalSince1970,
            includesSensitiveValues: false,
            servers: savedServers.map { ServerBackupEntry(server: persistableServer(from: $0)) }
        )
        return try JSONEncoder().encode(payload)
    }

    public func importServers(from data: Data) throws -> ServerImportResult {
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

    public func currentICloudServerListDebugState() -> ICloudServerListDebugState {
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
        #if os(macOS)
        MacLegacyContainerMigrator.migrateIfNeeded()
        #endif

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

    public func hydratedServer(from server: ServerConfig) -> ServerConfig {
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
        smbClientsLock.lock()
        smbClients.removeValue(forKey: server.id)
        smbClientsLock.unlock()
        deleteSensitiveValues(for: server)
        HistoryService.shared.clearHistory(for: server)
        FavoriteService.shared.clearFavorites(for: server)
        SearchHistoryService.shared.clearHistory(for: server.id)
        PrivacySpaceService.shared.remove(server: server)
        IPTVService.shared.clearCache(for: server.id)
        if server.type == .onedrive {
            OneDriveManager.shared.clearCache(for: server.id)
        } else if server.type == .googledrive {
            GoogleDriveManager.shared.clearCache(for: server.id)
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
#if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleApplicationWillEnterForeground(_:)),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
#endif
    }

    @objc private func handleICloudStoreDidChangeExternally(_ notification: Notification) {
        scheduleICloudPull(trigger: .externalChange)
    }

    @objc private func handlePrivacySpaceMarksDidChange(_ notification: Notification) {
        guard isICloudServerListSyncEnabled else { return }
        guard !isApplyingICloudServerList else { return }
        saveServers()
    }

#if os(iOS)
    @objc private func handleApplicationWillEnterForeground(_ notification: Notification) {
        scheduleICloudPull(trigger: .willEnterForeground)
    }
#endif

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
            
            let serverTypeChanged = oldServer.type != newServer.type
            let addressChanged = oldServer.address != newServer.address || oldServer.port != newServer.port
            let credentialsChanged = oldServer.username != newServer.username || oldServer.passwordSecret != newServer.passwordSecret

            if serverTypeChanged || addressChanged || credentialsChanged {
                smbClientsLock.lock()
                smbClients.removeValue(forKey: newServer.id)
                smbClientsLock.unlock()
            }
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
        smbClientsLock.lock()
        if let client = smbClients[server.id] {
            smbClientsLock.unlock()
            return client
        }
        smbClientsLock.unlock()
        
        let client = try createSMBClient(for: server)
        
        smbClientsLock.lock()
        smbClients[server.id] = client
        smbClientsLock.unlock()
        return client
    }
    
    // MARK: - Connection Testing
    
    public func testConnection(_ server: ServerConfig) async throws -> ServerConfig {
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
                _ = try await GoogleDriveManager.shared.testConnection(server: server)

            case .ftp:
                try await FTPBrowserService.shared.testConnection(server: server)
            case .nfs:
                try await NFSBrowserService.shared.testConnection(server: server)
            case .sftp:
                try await SFTPBrowserService.shared.testConnection(server: server)
                
                
            case .jellyfin:
                updatedServer = try await testJellyfinConnection(server)
                
            case .emby:
                updatedServer = try await testEmbyConnection(server)
                
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
                // A category response alone does not prove that this provider can return
                // playable catalog entries. Verify the paged list and cache its total for
                // the server card at the same time.
                let result = try await VODService.shared.fetchList(server: server, page: 1)
                MediaServerSummaryService.shared.updateSummary(
                    for: server.id,
                    libraryCount: result.totalCount
                )
            }
            
            return updatedServer
        } catch {
            let nsError = error as NSError
            let isAuthError = (nsError.domain == "JellyfinError" || nsError.domain == "EmbyError" || nsError.domain == "PlexError" || nsError.code == 401 || nsError.code == 403)
            if isAuthError {
                clearServerAuthTokens(for: server.id)
            }

            // Map common errors to user-friendly messages
            
            if nsError.domain == NSPOSIXErrorDomain && (nsError.code == 1 || nsError.code == 13) {
                throw NSError(
                    domain: "GenPlayer",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Access Denied. Please check your username/password. If credentials are correct, ensure Gen Player has Local Network access permission in Settings.", comment: "")]
                )
            }

            if let mappedError = mapNetworkConnectionError(error, server: server) {
                throw mappedError
            }
            
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
    
    public func fetchContents(for server: ServerConfig, at path: String = "/") async throws -> [VideoFile] {
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
        let shares = try await client.listShares()
        let userShares = shares.filter { !$0.name.hasSuffix("$") }
        
        return userShares.compactMap { share in
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
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let shareName = components.first else {
            return []
        }
        
        let relativePath = components.dropFirst().joined(separator: "/")
        try await client.connectShare(name: String(shareName))
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
            
            let fileType: VideoFile.FileType
            if isDirectory {
                fileType = .folder
            } else {
                fileType = VideoFile.FileType.determineType(from: URL(fileURLWithPath: name))
            }
            
            let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
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
    
    private func buildSMBURL(server: ServerConfig, path: String) -> URL {
        var urlString = "smb://"
        if let username = server.username, !username.isEmpty {
            let encodedUser = username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? username
            urlString += encodedUser
            if let password = server.passwordSecret, !password.isEmpty {
                let encodedPass = password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? password
                urlString += ":\(encodedPass)"
            }
            urlString += "@"
        }
        urlString += server.address
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        urlString += encodedPath
        return URL(string: urlString) ?? URL(fileURLWithPath: path)
    }
    
    // MARK: - File Operations

    private func ensureRemoteMutationAllowed(for serverType: ServerConfig.ServerType) throws {
        guard serverType.supportsRemoteMutationOperations else {
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("This server type doesn't support file modifications.", comment: "")])
        }

        guard UserDefaults.standard.bool(forKey: "allowRemoteMutationOperations") else {
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Remote file modifications are disabled in Settings > Advanced.", comment: "")])
        }
    }
    
    public func deleteFile(server: ServerConfig, at path: String) async throws {
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
        default:
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Delete not supported for this server type"])
        }
    }
    
    public func moveFile(server: ServerConfig, fromPath: String, toPath: String) async throws {
        try ensureRemoteMutationAllowed(for: server.type)
        switch server.type {
        case .smb:
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
        default:
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Move not supported for this server type"])
        }
    }
    
    private func testJellyfinConnection(_ server: ServerConfig) async throws -> ServerConfig {
        guard let urlComponents = URLComponents(string: server.fullURL), urlComponents.host != nil else {
            throw NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid server address", comment: "")])
        }
        let base = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let pingURL = URL(string: "\(base)/System/Info/Public") ?? URL(string: "\(base)/System/Info") else {
            throw NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid server address", comment: "")])
        }
        var request = URLRequest(url: pingURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8.0)
        request.httpMethod = "GET"
        if let token = server.accessToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            throw NSError(domain: "GenPlayer", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Connection failed with HTTP status", comment: "") + " \(httpResponse.statusCode)"])
        }
        return server
    }

    private func testEmbyConnection(_ server: ServerConfig) async throws -> ServerConfig {
        guard let urlComponents = URLComponents(string: server.fullURL), urlComponents.host != nil else {
            throw NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid server address", comment: "")])
        }
        let base = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let pingURL = URL(string: "\(base)/emby/System/Info/Public") ?? URL(string: "\(base)/System/Info/Public") else {
            throw NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid server address", comment: "")])
        }
        var request = URLRequest(url: pingURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 8.0)
        request.httpMethod = "GET"
        if let token = server.accessToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode >= 400 {
            throw NSError(domain: "GenPlayer", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Connection failed with HTTP status", comment: "") + " \(httpResponse.statusCode)"])
        }
        return server
    }

    private struct PlexProbeCandidate {
        let useSSL: Bool
        let port: Int
        let baseURL: URL
    }

    private func testPlexConnection(_ server: ServerConfig, token: String?) async throws -> ServerConfig {
        guard URLComponents(string: server.fullURL) != nil else {
            throw NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Invalid Plex server address", comment: "")])
        }

        guard let cleanedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines), !cleanedToken.isEmpty else {
            throw NSError(domain: "GenPlayer", code: 401, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Plex server is reachable, but authorization failed. Please check token/sign-in.", comment: "")])
        }

        let candidates = plexProbeCandidates(for: server)
        var lastStatusCode: Int?
        var lastError: Error?

        for candidate in candidates {
            guard let url = plexProbeURL(baseURL: candidate.baseURL, path: "/library/sections") else { continue }
            do {
                let statusCode = try await plexStatusCode(url: url, token: cleanedToken)
                if (200...299).contains(statusCode) {
                    var resolved = server
                    resolved.useSSL = candidate.useSSL
                    resolved.port = candidate.port
                    return resolved
                }
                lastStatusCode = statusCode
            } catch {
                lastError = error
            }
        }

        if lastStatusCode == 401 || lastStatusCode == 403 {
            throw NSError(domain: "GenPlayer", code: 401, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Plex server is reachable, but authorization failed. Please check token/sign-in.", comment: "")])
        }

        throw lastError ?? NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Plex connection failed"])
    }

    private func plexProbeCandidates(for server: ServerConfig) -> [PlexProbeCandidate] {
        guard let base = URLComponents(string: server.fullURL), let host = base.host else { return [] }
        let configuredUseSSL = (base.scheme?.lowercased() == "https")
        let configuredPort = server.port ?? base.port ?? ServerConfig.defaultPort(for: .plex, useSSL: configuredUseSSL)
        let basePath = base.path == "/" ? "" : base.path
        let combos = [(configuredUseSSL, configuredPort), (!configuredUseSSL, configuredPort), (false, 32400), (true, 32400), (true, 443)]
        var seen = Set<String>()
        var candidates: [PlexProbeCandidate] = []
        for (useSSL, port) in combos {
            let key = "\(useSSL):\(port)"
            if seen.contains(key) { continue }
            seen.insert(key)
            var components = URLComponents()
            components.scheme = useSSL ? "https" : "http"
            components.host = host
            components.port = port
            components.path = basePath
            if let url = components.url {
                candidates.append(PlexProbeCandidate(useSSL: useSSL, port: port, baseURL: url))
            }
        }
        return candidates
    }

    private func plexProbeURL(baseURL: URL, path: String) -> URL? {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let basePath = components.path
        components.path = (basePath.isEmpty || basePath == "/") ? normalizedPath : "\(basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath)\(normalizedPath)"
        return components.url
    }

    private func plexStatusCode(url: URL, token: String?) async throws -> Int {
#if os(iOS)
        let systemVersion = await MainActor.run { UIDevice.current.systemVersion }
#else
        let systemVersion = "macOS"
#endif
        let appVersion = "1.0"
        let clientIdentifier = plexClientIdentifier()

        var requestURL = url
        if let token, !token.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = components.queryItems ?? []
            if !items.contains(where: { $0.name == "X-Plex-Token" }) {
                items.append(URLQueryItem(name: "X-Plex-Token", value: token))
            }
            components.queryItems = items
            requestURL = components.url ?? url
        }

        var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: requestURL))
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("GenPlayer", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("GenPlayer-iOS", forHTTPHeaderField: "X-Plex-Device")
        request.setValue(systemVersion, forHTTPHeaderField: "X-Plex-Platform-Version")
        request.setValue(appVersion, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")

        if let token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Plex server returned an invalid response", comment: "")])
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

    public func createFolder(server: ServerConfig, at path: String) async throws {
        try ensureRemoteMutationAllowed(for: server.type)
        switch server.type {
        case .smb:
            let client = try getClient(for: server)
            let (share, relativePath) = parsePath(path)
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
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Create folder not supported for this server type"])
        }
    }
    
    public func downloadFile(server: ServerConfig, at path: String, progress: ((Int64, Int64) -> Void)? = nil) async throws -> URL {
        switch server.type {
        case .smb:
            let client = try getClient(for: server)
            let (share, relativePath) = parsePath(path)
            try await client.connectShare(name: share)
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            let fileName = URL(fileURLWithPath: path).lastPathComponent
            let destinationURL = tempDir.appendingPathComponent(fileName)
            try await client.downloadItem(atPath: relativePath, to: destinationURL, progress: { downloaded, total in
                progress?(Int64(downloaded), Int64(total))
                return !Task.isCancelled
            })
            return destinationURL
        case .webdav:
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
            if !cookie.isEmpty {
                req.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            req.setValue("https://115.com", forHTTPHeaderField: "Referer")
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
#if canImport(FilesProvider)
            return try await FTPBrowserService.shared.downloadFile(server: server, at: path, progress: progress)
#else
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download not supported for this server type (FilesProvider missing)"])
#endif
        case .sftp:
            return try await SFTPBrowserService.shared.downloadFile(server: server, at: path, progress: progress)
        case .nfs:
#if canImport(NFSKit)
            return try await NFSBrowserService.shared.downloadFile(server: server, at: path, progress: progress)
#else
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download not supported for this server type (NFSKit missing)"])
#endif
        case .jellyfin, .emby, .plex:
            return try await downloadMediaServerFile(server: server, at: path, progress: progress)
        case .iptv, .vod:
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download is not supported for this server type."])
        }
    }

    public func downloadRequest(server: ServerConfig, at path: String) -> URLRequest? {
        switch server.type {
        case .webdav:
            return webdavManager.downloadRequest(server: server, at: path)
        case .alist:
            return nil
        case .jellyfin, .emby, .plex:
            return mediaServerDownloadRequest(server: server, path: path)
        case .smb, .pan115, .ftp, .sftp, .nfs, .iptv, .onedrive, .googledrive, .vod:
            return nil
        }
    }

    private func downloadMediaServerFile(server: ServerConfig, at path: String, progress: ((Int64, Int64) -> Void)?) async throws -> URL {
        guard let request = mediaServerDownloadRequest(server: server, path: path) else {
            throw NSError(domain: "AppNetworkService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid media download URL"])
        }
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        return try await performHTTPDownload(request: request, suggestedFilename: fileName.isEmpty ? nil : fileName, progress: progress)
    }

    private func mediaServerDownloadRequest(server: ServerConfig, path: String) -> URLRequest? {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        let url = (URL(string: trimmedPath)?.scheme != nil) ? URL(string: trimmedPath) : URL(string: "\(server.fullURL)\(trimmedPath.hasPrefix("/") ? "" : "/")\(trimmedPath)")
        guard let url else { return nil }
        var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
        request.timeoutInterval = 300
        switch server.type {
        case .plex:
            applyPlexDownloadHeaders(to: &request, server: server)
        case .jellyfin, .emby:
            if let token = server.accessToken {
                let authHeader = mediaBrowserAuthHeader(token: token)
                request.setValue(authHeader, forHTTPHeaderField: "Authorization")
                request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
                request.setValue(token, forHTTPHeaderField: "X-MediaBrowser-Token")
            }
        default: break
        }
        return request
    }

    private func applyPlexDownloadHeaders(to request: inout URLRequest, server: ServerConfig) {
#if os(iOS)
        let systemVersion = UIDevice.current.systemVersion
#else
        let systemVersion = "macOS"
#endif
        let appVersion = "1.0"
        let clientIdentifier = plexClientIdentifier()
        let token = server.accessToken?.isEmpty == false ? server.accessToken : server.passwordSecret
        request.setValue("GenPlayer", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("GenPlayer-iOS", forHTTPHeaderField: "X-Plex-Device")
        request.setValue(systemVersion, forHTTPHeaderField: "X-Plex-Platform-Version")
        request.setValue(appVersion, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Plex-Token") }
    }

    private func mediaBrowserAuthHeader(token: String) -> String {
#if os(iOS)
        let rawDeviceName = UIDevice.current.name
#else
        let rawDeviceName = "Mac"
#endif
        let encodedDeviceName = rawDeviceName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rawDeviceName
        let deviceIdKey = "MediaServerDownloadDeviceId"
        let deviceId = UserDefaults.standard.string(forKey: deviceIdKey) ?? UUID().uuidString
        UserDefaults.standard.set(deviceId, forKey: deviceIdKey)
        return "MediaBrowser Client=\"GenPlayer\", Device=\"\(encodedDeviceName)\", DeviceId=\"\(deviceId)\", Version=\"1.0\", Token=\"\(token)\""
    }

    private func performHTTPDownload(request: URLRequest, suggestedFilename: String? = nil, progress: ((Int64, Int64) -> Void)?) async throws -> URL {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempDirectory, withIntermediateDirectories: true, attributes: nil)
        let baseName: String
        if let explicit = suggestedFilename, !explicit.isEmpty {
            baseName = explicit
        } else {
            baseName = request.url?.lastPathComponent.isEmpty == false ? request.url!.lastPathComponent : UUID().uuidString
        }
        let fileName = (baseName.contains(".") || !(request.url?.pathExtension ?? "").isEmpty) ? baseName : "\(baseName).bin"
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
    
    public var isICloudServerListSyncEnabled: Bool { UserDefaults.standard.bool(forKey: iCloudServerListSyncEnabledKey) }

    public func setICloudServerListSyncEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: iCloudServerListSyncEnabledKey)
        if enabled { reconcileICloudServerList(pushLocalIfNeeded: true) }
    }

    public func syncServerListNow() {
        iCloudPullDebounceWorkItem?.cancel()
        reconcileICloudServerList(pushLocalIfNeeded: true, forceRefreshCurrentSnapshotVersion: true)
    }

    private func applyICloudServerListIfEnabled(remotePayload: ICloudServerListPayload? = nil) {
        guard isICloudServerListSyncEnabled else { return }
        guard !isApplyingICloudServerList else { return }
        let resolvedPayload = trustedICloudPayload(remotePayload ?? iCloudSyncService.pullPayload())
        if let payload = resolvedPayload {
            if payload.updatedAt <= localServerListUpdatedAt { return }
            if payload.updatedAt <= lastAppliedICloudPayloadUpdatedAt { return }
        }
        guard let resolution = ICloudServerListSyncResolver.resolve(localServers: savedServers, localUpdatedAt: localServerListUpdatedAt, remotePayload: resolvedPayload) else { return }
        isApplyingICloudServerList = true
        defer { isApplyingICloudServerList = false }
        invalidateCachesForUpdatedServers(oldServers: savedServers, newServers: resolution.servers)
        savedServers.filter { resolution.removedServerIDs.contains($0.id) }.forEach { cleanupRemovedServerData(for: $0) }
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
            DispatchQueue.main.async { [weak self] in self?.applyICloudServerListIfEnabled() }
        case .externalChange:
            iCloudPullDebounceWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.lastICloudPullAttemptAt = Date().timeIntervalSince1970
                self?.applyICloudServerListIfEnabled()
            }
            iCloudPullDebounceWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + iCloudExternalChangeDebounceInterval, execute: workItem)
        }
    }
    
    private func parsePath(_ path: String) -> (String, String) {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let shareName = components.first else { return ("", "") }
        return (String(shareName), components.dropFirst().joined(separator: "/"))
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

    #if os(macOS) || os(iOS) || os(tvOS)
    func aListAudioRangeRequest(server: ServerConfig, path: String) async throws -> URLRequest {
        try await performAListOperation(for: server) { token in
            try await self.alistManager.downloadRequest(server: server, at: path, token: token)
        }
    }
    #endif

    public func resolvedPlaybackFile(_ file: VideoFile) async throws -> VideoFile {
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

    func cancel() { task?.cancel() }

    private func resumeOnce(with result: Result<URL, Error>) {
        lock.lock()
        guard !didFinish, let continuation else { lock.unlock(); return }
        didFinish = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        progressHandler?(totalBytesWritten, max(0, totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try DownloadFileValidation.validateHTTP(response: downloadTask.response, fileURL: location)
            try FileManager.default.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destinationURL.path) { try FileManager.default.removeItem(at: destinationURL) }
            try FileManager.default.moveItem(at: location, to: destinationURL)
            resumeOnce(with: .success(destinationURL))
        } catch { resumeOnce(with: .failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { resumeOnce(with: .failure(error)) }
    }
}

#if os(macOS)
public enum MacLegacyContainerMigrator {
    public static func migrateIfNeeded() {
        let migrationKey = "hasMigratedLegacyMacContainer_v1"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }
        
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let legacyContainerURL = homeDir.appendingPathComponent("Library/Containers/com.fugary.player.GenPlayer.mac/Data/Library")
        
        guard fileManager.fileExists(atPath: legacyContainerURL.path) else {
            UserDefaults.standard.set(true, forKey: migrationKey)
            return
        }
        
        // 1. Migrate saved_servers_snapshot_v1.json if current snapshot doesn't exist
        let legacySnapshotURL = legacyContainerURL.appendingPathComponent("Application Support/NetworkService/saved_servers_snapshot_v1.json")
        if let currentAppSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let currentSnapshotURL = currentAppSupport.appendingPathComponent("NetworkService/saved_servers_snapshot_v1.json")
            if !fileManager.fileExists(atPath: currentSnapshotURL.path), fileManager.fileExists(atPath: legacySnapshotURL.path) {
                try? fileManager.createDirectory(at: currentSnapshotURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.copyItem(at: legacySnapshotURL, to: currentSnapshotURL)
            }
            
            // Migrate Application Support/GenPlayer
            let legacyGenPlayerDir = legacyContainerURL.appendingPathComponent("Application Support/GenPlayer")
            let currentGenPlayerDir = currentAppSupport.appendingPathComponent("GenPlayer")
            if fileManager.fileExists(atPath: legacyGenPlayerDir.path) && !fileManager.fileExists(atPath: currentGenPlayerDir.path) {
                try? fileManager.copyItem(at: legacyGenPlayerDir, to: currentGenPlayerDir)
            }
        }
        
        // 2. Migrate UserDefaults plist (KeychainFallback_*, favorites_items, playback_history_*, etc.)
        let legacyPlistURL = legacyContainerURL.appendingPathComponent("Preferences/com.fugary.player.GenPlayer.mac.plist")
        if fileManager.fileExists(atPath: legacyPlistURL.path),
           let data = try? Data(contentsOf: legacyPlistURL),
           let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] {
            
            let userDefaults = UserDefaults.standard
            for (key, value) in plist {
                if userDefaults.object(forKey: key) == nil {
                    userDefaults.set(value, forKey: key)
                }
            }
            userDefaults.synchronize()
        }
        
        UserDefaults.standard.set(true, forKey: migrationKey)
        print("[MacLegacyContainerMigrator] Successfully migrated legacy data from com.fugary.player.GenPlayer.mac")
    }
}
#endif
