import Foundation
import Network

public enum RuntimeNetworkAddressResolver {
    private static let lock = NSLock()
    private static var dnsCache: [String: String] = [:]

    public static func runtimeAddress(from address: String) -> String {
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

    public static func runtimeURL(from url: URL) -> URL {
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

public struct ServerBackupPayload: Codable {
    public let app: String
    public let version: Int
    public let exportedAt: TimeInterval
    public let includesSensitiveValues: Bool
    public let servers: [ServerBackupEntry]
    
    public init(app: String, version: Int, exportedAt: TimeInterval, includesSensitiveValues: Bool, servers: [ServerBackupEntry]) {
        self.app = app
        self.version = version
        self.exportedAt = exportedAt
        self.includesSensitiveValues = includesSensitiveValues
        self.servers = servers
    }
}

public struct ServerBackupEntry: Codable {
    public var name: String
    public var address: String
    public var port: Int?
    public var useSSL: Bool
    public var type: ServerConfig.ServerType
    public var username: String?
    public var workgroup: String?
    public var lastAccessed: Date?

    public init(server: ServerConfig) {
        self.name = server.name
        self.address = server.address
        self.port = server.port
        self.useSSL = server.useSSL
        self.type = server.type
        self.username = server.username
        self.workgroup = server.workgroup
        self.lastAccessed = server.lastAccessed
    }

    public func serverConfig() -> ServerConfig {
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

public struct ServerImportResult {
    public let importedCount: Int
    public let skippedCount: Int
    
    public init(importedCount: Int, skippedCount: Int) {
        self.importedCount = importedCount
        self.skippedCount = skippedCount
    }
}

public struct ICloudServerListPayload: Codable, Equatable {
    public let updatedAt: TimeInterval
    public let servers: [ServerConfig]
    public let privacySpace: PrivacySpaceSnapshot?
    
    public init(
        updatedAt: TimeInterval,
        servers: [ServerConfig],
        privacySpace: PrivacySpaceSnapshot? = nil
    ) {
        self.updatedAt = updatedAt
        self.servers = servers
        self.privacySpace = privacySpace
    }
}

public struct PersistedServerListSnapshot: Codable, Equatable {
    public let updatedAt: TimeInterval
    public let servers: [ServerConfig]
    
    public init(updatedAt: TimeInterval, servers: [ServerConfig]) {
        self.updatedAt = updatedAt
        self.servers = servers
    }
}

public struct ICloudServerListSyncResolution: Equatable {
    public let servers: [ServerConfig]
    public let removedServerIDs: [UUID]
    public let updatedAt: TimeInterval
    
    public init(servers: [ServerConfig], removedServerIDs: [UUID], updatedAt: TimeInterval) {
        self.servers = servers
        self.removedServerIDs = removedServerIDs
        self.updatedAt = updatedAt
    }
}

public struct ICloudServerListDebugState: Equatable {
    public enum RemoteSnapshotStatus: Equatable {
        case missing
        case trusted
        case ignoredFutureTimestamp
    }

    public let localUpdatedAt: TimeInterval
    public let remoteUpdatedAt: TimeInterval?
    public let lastAppliedRemoteUpdatedAt: TimeInterval
    public let remoteSnapshotStatus: RemoteSnapshotStatus
    public let remoteFutureSkew: TimeInterval?
    public let localPersistedServers: [ICloudServerListDebugServerEntry]
    public let localRuntimeServers: [ICloudServerListDebugServerEntry]
    public let remoteServers: [ICloudServerListDebugServerEntry]
    
    public init(localUpdatedAt: TimeInterval, remoteUpdatedAt: TimeInterval?, lastAppliedRemoteUpdatedAt: TimeInterval, remoteSnapshotStatus: RemoteSnapshotStatus, remoteFutureSkew: TimeInterval?, localPersistedServers: [ICloudServerListDebugServerEntry], localRuntimeServers: [ICloudServerListDebugServerEntry], remoteServers: [ICloudServerListDebugServerEntry]) {
        self.localUpdatedAt = localUpdatedAt
        self.remoteUpdatedAt = remoteUpdatedAt
        self.lastAppliedRemoteUpdatedAt = lastAppliedRemoteUpdatedAt
        self.remoteSnapshotStatus = remoteSnapshotStatus
        self.remoteFutureSkew = remoteFutureSkew
        self.localPersistedServers = localPersistedServers
        self.localRuntimeServers = localRuntimeServers
        self.remoteServers = remoteServers
    }
}

public struct ICloudServerListDebugServerEntry: Identifiable, Equatable {
    public let server: ServerConfig
    public let hasPasswordInKeychain: Bool?
    public let hasAccessTokenInKeychain: Bool?

    public var id: UUID { server.id }
    
    public init(server: ServerConfig, hasPasswordInKeychain: Bool?, hasAccessTokenInKeychain: Bool?) {
        self.server = server
        self.hasPasswordInKeychain = hasPasswordInKeychain
        self.hasAccessTokenInKeychain = hasAccessTokenInKeychain
    }
}

public enum ICloudServerListSyncResolver {
    public static func resolve(
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
