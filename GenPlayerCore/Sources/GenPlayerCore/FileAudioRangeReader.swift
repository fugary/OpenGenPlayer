#if os(macOS) || os(iOS) || os(tvOS)
import Foundation

/// A lazy, independent file connection. It never enters the download center or
/// consumes the playback connection. Failed/expired requests reopen on retry.
public actor FileAudioRangeReader {
    private let url: URL, provider: String?, serverID: String?, path: String?, itemID: String?
    private let gate = AudioReadGate()
    private var source: (any AudioRangeSource)?
    private var version: AudioFileVersion?
    private var renewAuthorization = false

    public init(url: URL, provider: String?, serverID: String?, path: String?, itemID: String?) {
        self.url = url; self.provider = provider; self.serverID = serverID; self.path = path; self.itemID = itemID
    }

    public nonisolated static func supports(provider: String?, url: URL) -> Bool {
        let scheme = url.scheme?.lowercased() ?? ""
        switch provider {
        case "webdav", "alist", "115", "onedrive", "googledrive", nil:
            return ["http", "https"].contains(scheme)
        case "ftp": return ["ftp", "ftps"].contains(scheme)
        case "sftp": return scheme == "sftp"
        case "nfs": return scheme == "nfs"
        default: return false
        }
    }

    public func metadata() async throws -> AudioFileVersion {
        await gate.acquire()
        do {
            try Task.checkCancellation()
            let source = try await connectedSource()
            let value = try await source.metadata()
            if let version, value != version { throw AudioRangeFailure.changed }
            version = value
            try Task.checkCancellation()
            await gate.release()
            return value
        } catch { source = nil; renewAuthorization = true; await gate.release(); throw error }
    }

    public func read(offset: UInt64, count: Int) async throws -> Data {
        await gate.acquire()
        do {
            try Task.checkCancellation()
            guard let version, count > 0, count <= 1024 * 1024, offset < version.size,
                  UInt64(count) <= version.size - offset else { throw AudioRangeFailure.invalidResponse }
            let source = try await connectedSource()
            let bytes = try await source.read(offset: offset, count: count)
            guard bytes.count == count else { throw AudioRangeFailure.invalidResponse }
            try Task.checkCancellation()
            await gate.release()
            return bytes
        } catch { source = nil; renewAuthorization = true; await gate.release(); throw error }
    }

    private func connectedSource() async throws -> any AudioRangeSource {
        if let source { return source }
        let candidate = try await makeSource()
        let value = try await candidate.metadata()
        if let version, version != value { throw AudioRangeFailure.changed }
        version = value; source = candidate
        return candidate
    }

    private func makeSource() async throws -> any AudioRangeSource {
        guard Self.supports(provider: provider, url: url) else { throw AudioRangeFailure.unsupported }
        let serverID = serverID, provider = provider
        let server = await MainActor.run {
            AppNetworkService.shared.servers.first { $0.id == serverID.flatMap(UUID.init(uuidString:)) && $0.type.rawValue == provider }
        }
        switch provider {
        case "ftp":
            guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
            if let server { parts.user = server.username; parts.password = server.passwordSecret }
            guard let endpoint = parts.url else { throw URLError(.badURL) }
            return FTPAudioRangeSource(url: endpoint)
        case "sftp":
            guard let server else { throw URLError(.userAuthenticationRequired) }
            return SFTPBrowserService.shared.audioRangeSource(server: server, path: path ?? url.path)
        case "nfs":
            #if canImport(NFSKit)
            return try await NFSAudioRangeSource.make(url: url, server: server)
            #else
            throw AudioRangeFailure.unsupported
            #endif
        default:
            let request = try await httpRequest(server: server)
            return HTTPAudioRangeSource { request }
        }
    }

    private func httpRequest(server: ServerConfig?) async throws -> URLRequest {
        if ["alist", "115", "onedrive", "googledrive"].contains(provider ?? ""),
           server == nil || path?.isEmpty != false {
            // A playback URL may be a transcoded stream or a proxy. Cloud audio
            // requires the original account/path, never guesses from that URL.
            throw AudioRangeFailure.unsupported
        }
        if let server, let path, !path.isEmpty {
            switch server.type {
            case .webdav:
                guard let request = WebDAVManager().downloadRequest(server: server, at: path) else { throw URLError(.badURL) }
                return request
            case .alist:
                return try await AppNetworkService.shared.aListAudioRangeRequest(server: server, path: path)
            case .pan115:
                let cookie = server.passwordSecret ?? server.accessToken ?? ""
                var request = URLRequest(url: try await Pan115Manager.shared.rawDownloadURL(server: server, at: path, pickcode: itemID, cookie: cookie, originalOnly: true))
                request.setValue(Pan115Manager.defaultUserAgent, forHTTPHeaderField: "User-Agent")
                request.setValue(cookie, forHTTPHeaderField: "Cookie")
                request.setValue("https://115.com", forHTTPHeaderField: "Referer")
                return request
            case .onedrive:
                return URLRequest(url: try await OneDriveManager.shared.rawDownloadURL(server: server, at: path, forceRefresh: renewAuthorization))
            case .googledrive:
                return try await GoogleDriveManager.shared.audioRangeRequest(server: server, path: path, fileID: itemID, forceRefresh: renewAuthorization)
            default: break
            }
        }
        // Plain HTTP sources and older WebDAV items can carry Basic credentials
        // in the playback URL. Remove userinfo before URLSession/redirect handling.
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        let user = parts.user, password = parts.password
        parts.user = nil; parts.password = nil; parts.fragment = nil
        guard let clean = parts.url else { throw URLError(.badURL) }
        var request = URLRequest(url: clean)
        if let user { request.setValue("Basic " + Data("\(user):\(password ?? "")".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization") }
        return request
    }
}
#endif
