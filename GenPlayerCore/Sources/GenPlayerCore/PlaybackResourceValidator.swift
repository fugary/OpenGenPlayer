import Foundation

public enum PlaybackValidationError: LocalizedError, Equatable {
    case localFileNotFound(URL)
    case resourceNotFound(String)
    case serverUnreachable(String)
    case generalError(String)
    
    public var errorDescription: String? {
        switch self {
        case .localFileNotFound:
            return NSLocalizedString("The local file does not exist or has been deleted.", comment: "")
        case .resourceNotFound(let detail):
            if detail.isEmpty {
                return NSLocalizedString("The media resource has been deleted or does not exist on the server.", comment: "")
            }
            return detail
        case .serverUnreachable(let message):
            return message
        case .generalError(let message):
            return message
        }
    }
    
    public var isResourceNotFound: Bool {
        switch self {
        case .localFileNotFound, .resourceNotFound:
            return true
        default:
            return false
        }
    }
}

public enum PlaybackResourceValidator {
    /// Validates whether a VideoFile can be played before opening the player.
    /// Returns the validated VideoFile (which may have updated server or resolved offline file).
    @MainActor
    public static func validatePlayback(
        for file: VideoFile,
        timeoutNanoseconds: UInt64 = 6_000_000_000
    ) async throws -> VideoFile {
        // 1. Check local download center offline file if applicable
        if let localFile = DownloadCenterService.shared.localPlaybackFile(for: file) {
            if FileManager.default.fileExists(atPath: localFile.url.path) {
                return localFile
            }
            // If offline file was recorded as downloaded but physically missing on disk, fallback to original if remote
            if !file.isRemote {
                throw PlaybackValidationError.localFileNotFound(localFile.url)
            }
        }
        
        // 2. Check local file
        if !file.isRemote {
            let path = file.url.path
            guard FileManager.default.fileExists(atPath: path) else {
                throw PlaybackValidationError.localFileNotFound(file.url)
            }
            return file
        }
        
        // 3. Check remote media server (Jellyfin / Emby / Plex)
        if let server = file.resolvedServer {
            // Check specific item if itemId is present
            if let itemId = file.jellyfinItemId, !itemId.isEmpty {
                try await validateRemoteItemExistence(server: server, itemId: itemId)
            }
            return file
        }
        
        // 4. Other remote protocols (WebDAV / SMB / Stream etc.)
        return file
    }
    
    private static func validateRemoteItemExistence(
        server: ServerConfig,
        itemId: String
    ) async throws {
        var endpointURLString = ""
        var headers: [String: String] = [:]
        
        let serverBase = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        switch server.type {
        case .jellyfin:
            let token = server.accessToken ?? ""
            endpointURLString = "\(serverBase)/Items/\(itemId)"
            if !token.isEmpty {
                headers["X-Emby-Token"] = token
                headers["Authorization"] = "MediaBrowser Token=\"\(token)\", Client=\"GenPlayer\", Device=\"Apple\", DeviceId=\"GenPlayer\", Version=\"1.0.0\""
            }
        case .emby:
            let token = server.accessToken ?? ""
            let userId = server.userId ?? ""
            if !userId.isEmpty {
                endpointURLString = "\(serverBase)/emby/Users/\(userId)/Items/\(itemId)"
            } else {
                endpointURLString = "\(serverBase)/emby/Items/\(itemId)"
            }
            if !token.isEmpty {
                headers["X-Emby-Token"] = token
            }
        case .plex:
            let token = server.accessToken ?? server.passwordSecret ?? ""
            endpointURLString = "\(serverBase)/library/metadata/\(itemId)"
            if !token.isEmpty {
                headers["X-Plex-Token"] = token
            }
            headers["Accept"] = "application/json"
        default:
            return
        }
        
        guard let url = URL(string: endpointURLString) else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 4.0)
        request.httpMethod = "GET"
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse {
                if httpResponse.statusCode == 404 {
                    throw PlaybackValidationError.resourceNotFound(
                        NSLocalizedString("The media resource has been deleted or does not exist on the server.", comment: "")
                    )
                }
            }
        } catch let error as PlaybackValidationError {
            throw error
        } catch {
            if (error as NSError).code == 404 {
                throw PlaybackValidationError.resourceNotFound(
                    NSLocalizedString("The media resource has been deleted or does not exist on the server.", comment: "")
                )
            }
            // For non-404 transient errors (timeout/offline), allow playback attempt to proceed rather than blocking
        }
    }
}
