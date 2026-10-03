import Foundation

/// Restores account credentials only at playback time; does not change the history/favorite file.
public enum FilePlaybackCredentials {
    public static func matchingServer(for file: VideoFile, in servers: [ServerConfig]) -> ServerConfig? {
        if let id = file.jellyfinServerId {
            // An explicit identity must never fall back to another account on the same NAS.
            return servers.first { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }
        }
        let scheme = file.url.scheme?.lowercased()
        let type = file.serverType ?? ["smb": .smb, "ftp": .ftp, "ftps": .ftp, "sftp": .sftp, "nfs": .nfs][scheme ?? ""]
        guard let type, let host = file.url.host else { return nil }
        let candidates = servers.filter { server in
            guard server.type == type else { return false }
            let base = type == .smb ? (server.address.contains("://") ? server.address : "smb://" + server.address) : server.fullURL
            guard let endpoint = URLComponents(string: base), endpoint.host?.caseInsensitiveCompare(host) == .orderedSame else { return false }
            let defaultPort = ServerConfig.defaultPort(for: type, useSSL: scheme == "https" || scheme == "ftps")
            return (file.url.port ?? defaultPort) == (server.port ?? endpoint.port ?? defaultPort)
        }
        // Old records without an ID cannot safely choose between multiple saved accounts.
        return candidates.count == 1 ? candidates[0] : nil
    }

    public static func runtimeURL(_ url: URL, server: ServerConfig?) -> URL {
        guard let server, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        let scheme = parts.scheme?.lowercased()
        switch server.type {
        case .smb: guard scheme == "smb" else { return url }
        case .ftp: guard scheme == "ftp" || scheme == "ftps" else { return url }
        case .sftp: guard scheme == "sftp" else { return url }
        case .webdav: guard scheme == "http" || scheme == "https" else { return url }
        default: return url
        }
        var username = server.username
        if server.type == .smb, let user = username, !user.isEmpty,
           !user.contains(";"), !user.contains("\\"), let domain = server.workgroup, !domain.isEmpty {
            username = domain + ";" + user
        }
        parts.user = username?.isEmpty == false ? username : nil
        parts.password = parts.user == nil ? nil : server.passwordSecret
        return parts.url ?? url
    }
}
