import Foundation

public struct ServerConfig: Identifiable, Codable, Equatable {
    public var id: UUID = UUID()
    public var name: String
    public var address: String  // Host or host+basePath (e.g., "192.168.1.1", "nas.local", "nas.local/plex")
    public var port: Int?       // Optional port (default varies by type)
    public var useSSL: Bool = false  // For WebDAV: http vs https
    public var type: ServerType
    public var username: String?
    // Sensitive value. Runtime use only; persisted to Keychain by AppNetworkService.
    public var passwordSecret: String?
    public var workgroup: String?
    
    // Jellyfin specific
    // Sensitive value. Runtime use only; persisted to Keychain by AppNetworkService.
    public var accessToken: String?  // Jellyfin/Emby access token from login
    public var userId: String?       // Jellyfin user ID
    
    // IPTV specific
    public var customEPGURL: String?
    
    public var vodSources: [VODSourceConfig]?

    public var lastAccessed: Date?
    
    public init(id: UUID = UUID(), name: String, address: String, port: Int? = nil, useSSL: Bool = false, type: ServerType, username: String? = nil, passwordSecret: String? = nil, workgroup: String? = nil, accessToken: String? = nil, userId: String? = nil, customEPGURL: String? = nil, lastAccessed: Date? = nil) {
        self.id = id
        self.name = name
        self.address = address
        self.port = port
        self.useSSL = useSSL
        self.type = type
        self.username = username
        self.passwordSecret = passwordSecret
        self.workgroup = workgroup
        self.accessToken = accessToken
        self.userId = userId
        self.customEPGURL = customEPGURL
        self.lastAccessed = lastAccessed
    }
    
    /// Computed full URL for WebDAV connections
    public var fullURL: String {
        switch type {
        case .webdav:
            let defaultScheme = useSSL ? "https" : "http"
            let defaultPort = ServerConfig.defaultPort(for: type, useSSL: useSSL)
            guard let parsed = parsedHTTPAddress(defaultScheme: defaultScheme, defaultPort: defaultPort) else {
                let effectivePort = port ?? defaultPort
                return "\(defaultScheme)://\(address):\(effectivePort)/"
            }
            let basePath = parsed.basePath.isEmpty ? "" : parsed.basePath
            return "\(parsed.scheme)://\(parsed.host):\(parsed.port)\(basePath)/"
        case .smb:
            // SMB doesn't need scheme in address, AMSMB2 handles it
            return address
        case .ftp, .sftp, .nfs:
            let scheme = type.rawValue
            let defaultPort = ServerConfig.defaultPort(for: type, useSSL: useSSL)
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("://"), let components = URLComponents(string: trimmed), let host = components.host {
                let path = components.path.isEmpty ? "" : components.path
                let resolvedPort = port ?? components.port ?? defaultPort
                return "\(scheme)://\(host):\(resolvedPort)\(path)"
            }
            let effectivePort = port ?? defaultPort
            return "\(scheme)://\(trimmed):\(effectivePort)"
        case .jellyfin, .emby, .plex, .alist:
            let defaultScheme = useSSL ? "https" : "http"
            let defaultPort = ServerConfig.defaultPort(for: type, useSSL: useSSL)
            guard let parsed = parsedHTTPAddress(defaultScheme: defaultScheme, defaultPort: defaultPort) else {
                let effectivePort = port ?? defaultPort
                return "\(defaultScheme)://\(address):\(effectivePort)"
            }
            return "\(parsed.scheme)://\(parsed.host):\(parsed.port)\(parsed.basePath)"
        case .pan115:
            return "https://115.com"
        case .onedrive:
            return "https://graph.microsoft.com"
        case .googledrive:
            return "https://www.googleapis.com/drive/v3"
        case .iptv, .vod:
            let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.contains("://") || trimmed.hasPrefix("/") {
                return trimmed
            }
            let defaultScheme = useSSL ? "https" : "http"
            if let port = port {
                return "\(defaultScheme)://\(trimmed):\(port)"
            }
            return "\(defaultScheme)://\(trimmed)"
        }
    }
    
    /// Default port for server type
    public static func defaultPort(for type: ServerType, useSSL: Bool) -> Int {
        switch type {
        case .smb: return 445
        case .webdav: return useSSL ? 443 : 80
        case .ftp: return 21
        case .sftp: return 22
        case .nfs: return 2049
        case .jellyfin, .emby: return useSSL ? 8920 : 8096
        case .plex: return 32400
        case .alist: return 5244
        case .pan115, .onedrive, .googledrive: return 443
        case .iptv, .vod: return useSSL ? 443 : 80
        }
    }
    
    public enum ServerType: String, Codable {
        case smb
        case webdav
        case ftp
        case sftp
        case nfs
        case jellyfin
        case emby
        case plex
        case alist
        case pan115 = "115"
        case onedrive
        case googledrive
        case iptv
        case vod
    }

    private func parsedHTTPAddress(defaultScheme: String, defaultPort: Int) -> (scheme: String, host: String, port: Int, basePath: String)? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = trimmed.contains("://") ? trimmed : "\(defaultScheme)://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }

        let resolvedScheme: String
        switch components.scheme?.lowercased() {
        case "https":
            resolvedScheme = "https"
        case "http":
            resolvedScheme = "http"
        default:
            resolvedScheme = defaultScheme
        }

        var path = components.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if path == "/" {
            path = ""
        } else if path.hasSuffix("/") {
            path = String(path.dropLast())
        }

        return (resolvedScheme, host, port ?? components.port ?? defaultPort, path)
    }
}

public extension ServerConfig.ServerType {
    var displayName: String {
        switch self {
        case .smb: return "SMB"
        case .webdav: return "WebDAV"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        case .nfs: return "NFS"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        case .alist: return "AList"
        case .pan115: return "115"
        case .onedrive: return "OneDrive"
        case .googledrive: return "Google Drive"
        case .iptv: return "IPTV"
        case .vod: return "Web VOD"
        }
    }

    var systemIconName: String {
        switch self {
        case .smb: return "server.rack"
        case .webdav: return "globe"
        case .ftp: return "network"
        case .sftp: return "lock.shield"
        case .nfs: return "externaldrive.connected.to.line.below"
        case .jellyfin: return "play.tv.fill"
        case .emby: return "leaf.fill"
        case .plex: return "play.square.fill"
        case .alist: return "externaldrive.badge.icloud"
        case .pan115: return "icloud.fill"
        case .onedrive: return "cloud.fill"
        case .googledrive: return "externaldrive.badge.icloud"
        case .iptv: return "play.tv.fill"
        case .vod: return "film.stack"
        }
    }

    var iconAssetName: String {
        if self == .webdav { return "webdav" }
        if self == .alist { return "alist" }
        if self == .pan115 { return "115" }
        if self == .onedrive { return "onedrive" }
        if self == .googledrive { return "googledrive" }
        return rawValue
    }

    public static let cloudTypes: [ServerConfig.ServerType] = [.alist, .pan115, .onedrive, .googledrive]
    public static let protocolTypes: [ServerConfig.ServerType] = [.smb, .webdav, .ftp, .sftp, .nfs]
    public static let mediaTypes: [ServerConfig.ServerType] = [.jellyfin, .emby, .plex, .vod]
    public static let liveTypes: [ServerConfig.ServerType] = [.iptv]

    /// Protocol-level capability only. User safety settings can further restrict this later.
    var supportsRemoteMutationOperations: Bool {
        switch self {
        case .smb, .webdav, .alist, .pan115, .onedrive, .googledrive:
            return true
        case .ftp, .sftp, .nfs, .jellyfin, .emby, .plex, .iptv, .vod:
            return false
        }
    }

    var supportsRemoteFileDownload: Bool {
        switch self {
        case .smb, .webdav, .ftp, .sftp, .nfs, .alist, .pan115, .onedrive, .googledrive:
            return true
        case .jellyfin, .emby, .plex, .iptv, .vod:
            return false
        }
    }
    
    var isMediaServer: Bool {
        switch self {
        case .jellyfin, .emby, .plex, .vod:
            return true
        default:
            return false
        }
    }

    var isFileServer: Bool {
        !isMediaServer && self != .iptv
    }

    var isCloudDrive: Bool {
        Self.cloudTypes.contains(self)
    }

    var requiresDynamicPlaybackURL: Bool {
        self == .alist || self == .pan115 || self == .onedrive || self == .googledrive
    }
    
    var isPan115: Bool {
        self == .pan115
    }

    var isOneDrive: Bool {
        self == .onedrive
    }

    var isGoogleDrive: Bool {
        self == .googledrive
    }

    public var isBeta: Bool {
        self == .googledrive || self == .onedrive || self == .pan115
    }
}


/// An endpoint inside a Web VOD server. Order defines the default enabled source.
public struct VODSourceConfig: Identifiable, Codable, Equatable {
    public var id: UUID
    public var name: String
    public var address: String
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, address: String, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.address = address
        self.isEnabled = isEnabled
    }
}
