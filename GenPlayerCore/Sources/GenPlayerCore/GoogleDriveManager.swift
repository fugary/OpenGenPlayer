import Foundation
import CommonCrypto
import Security
import Network
import Darwin

public final class GoogleDriveManager {
    public static let shared = GoogleDriveManager()

    // Public builds supply their own OAuth registrations via Info.plist.
    public static let defaultClientId = PublicOAuthConfiguration.value("GenPlayerGoogleClientID")
    public static let deviceClientId = PublicOAuthConfiguration.value("GenPlayerGoogleDeviceClientID")
    public static let deviceClientSecret: String? = PublicOAuthConfiguration.optional("GenPlayerGoogleDeviceClientSecret")
    #if os(tvOS)
    public static let defaultClientSecret = deviceClientSecret
    public static let defaultRedirectURI = "http://localhost"
    public static let callbackScheme = "http"
    #else
    public static let defaultClientSecret: String? = nil
    public static let callbackScheme = PublicOAuthConfiguration.value("GenPlayerGoogleCallbackScheme")
    public static let defaultRedirectURI = callbackScheme + ":/oauth2redirect"
    #endif

    public static let scopes = "https://www.googleapis.com/auth/drive.readonly https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile openid"

    public static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    public static let tokenEndpoint = "https://oauth2.googleapis.com/token"
    public static let deviceCodeEndpoint = "https://oauth2.googleapis.com/device/code"
    public static let userinfoEndpoint = "https://www.googleapis.com/oauth2/v3/userinfo"
    public static let driveBaseURL = "https://www.googleapis.com/drive/v3"

    private let pathMappingLock = NSLock()
    private var pathIdMap: [String: String] = [:]

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let fallbackISO8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private init() {}

    // MARK: - PKCE & OAuth Flow

    public struct PKCEPair {
        public let verifier: String
        public let challenge: String
    }

    public static func generatePKCE() -> PKCEPair {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        guard let verifierData = verifier.data(using: .ascii) else {
            return PKCEPair(verifier: verifier, challenge: verifier)
        }

        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        verifierData.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(verifierData.count), &hash)
        }

        let challenge = Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        return PKCEPair(verifier: verifier, challenge: challenge)
    }

    public static func buildAuthorizationURL(
        challenge: String,
        state: String = UUID().uuidString,
        clientId: String = defaultClientId,
        redirectURI: String = defaultRedirectURI
    ) -> URL? {
        var components = URLComponents(string: authEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return components?.url
    }

    public struct TokenResponse {
        public let accessToken: String
        public let refreshToken: String
        public let expiresIn: Int
        public let displayName: String
    }

    public func exchangeCodeForTokens(
        code: String,
        verifier: String,
        clientId: String = defaultClientId,
        clientSecret: String? = defaultClientSecret,
        redirectURI: String = defaultRedirectURI
    ) async throws -> TokenResponse {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid token endpoint"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyParameters: [String: String] = [
            "client_id": clientId,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "code_verifier": verifier
        ]
        if let secret = clientSecret, !secret.isEmpty {
            bodyParameters["client_secret"] = secret
        }

        request.httpBody = bodyParameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
                ?? (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "GoogleDriveManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse token response"])
        }

        let refreshToken = json["refresh_token"] as? String ?? ""
        let expiresIn = json["expires_in"] as? Int ?? 3600
        let userName = await fetchUserProfile(accessToken: accessToken) ?? "Google Drive"

        return TokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: expiresIn,
            displayName: userName
        )
    }

    public func refreshAccessToken(
        refreshToken: String,
        clientId: String = defaultClientId,
        clientSecret: String? = defaultClientSecret
    ) async throws -> (accessToken: String, refreshToken: String) {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid token endpoint"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyParameters: [String: String] = [
            "client_id": clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        if let secret = clientSecret, !secret.isEmpty {
            bodyParameters["client_secret"] = secret
        }

        request.httpBody = bodyParameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
                ?? (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? "Failed to refresh token"
            throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid refresh token response"])
        }

        let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
        return (accessToken, newRefreshToken)
    }

    // MARK: - Device Code Flow (tvOS)

    public struct DeviceCodeInfo {
        public let userCode: String
        public let deviceCode: String
        public let verificationURI: String
        public let expiresIn: Int
        public let interval: Int

        public var verificationURL: URL? {
            URL(string: verificationURI)
        }
    }

    public enum DeviceCodePollStatus {
        case waiting
        case slowDown
        case expired
        case success(accessToken: String, refreshToken: String, displayName: String)
        case error(String)
    }

    public func startDeviceCodeFlow(
        clientId: String = deviceClientId
    ) async throws -> DeviceCodeInfo {
        guard let url = URL(string: Self.deviceCodeEndpoint) else {
            throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid device code endpoint"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParameters: [String: String] = [
            "client_id": clientId,
            "scope": Self.scopes
        ]

        request.httpBody = bodyParameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userCode = json["user_code"] as? String,
              let deviceCode = json["device_code"] as? String,
              let verificationURI = (json["verification_url"] as? String) ?? (json["verification_uri"] as? String) else {
            let errorMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String
                ?? (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? "Device code request failed"
            throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        let expiresIn = json["expires_in"] as? Int ?? 1800
        let interval = json["interval"] as? Int ?? 5

        return DeviceCodeInfo(
            userCode: userCode,
            deviceCode: deviceCode,
            verificationURI: verificationURI,
            expiresIn: expiresIn,
            interval: interval
        )
    }

    public func pollDeviceCode(
        deviceCode: String,
        clientId: String = deviceClientId,
        clientSecret: String? = deviceClientSecret
    ) async -> DeviceCodePollStatus {
        guard let url = URL(string: Self.tokenEndpoint) else {
            return .error("Invalid token endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyParameters: [String: String] = [
            "client_id": clientId,
            "device_code": deviceCode,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
        ]
        if let secret = clientSecret, !secret.isEmpty {
            bodyParameters["client_secret"] = secret
        }

        request.httpBody = bodyParameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .error("Invalid server response")
            }

            if let error = json["error"] as? String {
                switch error {
                case "authorization_pending":
                    return .waiting
                case "slow_down":
                    return .slowDown
                case "expired_token":
                    return .expired
                default:
                    let desc = json["error_description"] as? String ?? error
                    return .error(desc)
                }
            }

            if let accessToken = json["access_token"] as? String {
                let refreshToken = json["refresh_token"] as? String ?? ""
                let userName = await fetchUserProfile(accessToken: accessToken) ?? "Google Drive"
                return .success(accessToken: accessToken, refreshToken: refreshToken, displayName: userName)
            }

            return .error("No tokens in response")
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - User Profile

    public func fetchUserProfile(accessToken: String) async -> String? {
        guard let url = URL(string: Self.userinfoEndpoint) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (json["name"] as? String) ?? (json["email"] as? String)
    }

    // MARK: - Token Validation & Retrieval

    public func getValidAccessToken(for server: ServerConfig, forceRefresh: Bool = false) async throws -> String {
        if !forceRefresh, let token = server.accessToken, !token.isEmpty {
            if await testToken(token) {
                return token
            }
        }

        guard let refreshToken = server.passwordSecret, !refreshToken.isEmpty else {
            throw NSError(
                domain: "GoogleDriveManager",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Missing Google Drive Refresh Token. Please log in again.", comment: "")]
            )
        }

        let (newAccessToken, newRefreshToken) = try await refreshAccessToken(refreshToken: refreshToken)
        await MainActor.run {
            AppNetworkService.shared.updateServerTokens(server.id, accessToken: newAccessToken, refreshToken: newRefreshToken)
        }
        return newAccessToken
    }

    public func testConnection(server: ServerConfig) async throws -> Bool {
        let token = try await getValidAccessToken(for: server)
        return await testToken(token)
    }

    private func testToken(_ token: String) async -> Bool {
        guard let url = URL(string: "\(Self.driveBaseURL)/about?fields=user") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 8.0
        guard let (_, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            return false
        }
        return true
    }

    // MARK: - Cache Helpers

    public func normalizePath(_ path: String) -> String {
        var p = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !p.hasPrefix("/") { p = "/" + p }
        while p.contains("//") { p = p.replacingOccurrences(of: "//", with: "/") }
        if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    private func cacheKey(serverId: UUID, path: String) -> String {
        "\(serverId.uuidString):\(normalizePath(path))"
    }

    public func fileId(forPath path: String, serverId: UUID) -> String? {
        pathMappingLock.lock()
        defer { pathMappingLock.unlock() }
        return pathIdMap[cacheKey(serverId: serverId, path: path)]
    }

    public func setFileId(_ id: String, forPath path: String, serverId: UUID) {
        pathMappingLock.lock()
        defer { pathMappingLock.unlock() }
        pathIdMap[cacheKey(serverId: serverId, path: path)] = id
    }

    public func clearCache(for serverId: UUID) {
        pathMappingLock.lock()
        let prefix = "\(serverId.uuidString):"
        pathIdMap = pathIdMap.filter { !$0.key.hasPrefix(prefix) }
        pathMappingLock.unlock()
    }

    // MARK: - Google Drive API Operations

    public func listFiles(server: ServerConfig, at path: String) async throws -> [VideoFile] {
        let token = try await getValidAccessToken(for: server)
        let normalizedPath = normalizePath(path)

        let parentId: String
        if normalizedPath == "/" {
            parentId = "root"
            setFileId("root", forPath: "/", serverId: server.id)
        } else if let cachedId = fileId(forPath: normalizedPath, serverId: server.id) {
            parentId = cachedId
        } else {
            // Need to resolve parent ID along the path hierarchy
            parentId = try await resolveFolderId(forPath: normalizedPath, server: server, token: token)
            setFileId(parentId, forPath: normalizedPath, serverId: server.id)
        }

        var allFiles: [VideoFile] = []
        var pageToken: String? = nil

        repeat {
            var components = URLComponents(string: "\(Self.driveBaseURL)/files")
            let query = "'\(parentId)' in parents and trashed = false"
            components?.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "nextPageToken, files(id, name, mimeType, size, modifiedTime, thumbnailLink, iconLink, shortcutDetails)"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
            ]
            if let token = pageToken {
                components?.queryItems?.append(URLQueryItem(name: "pageToken", value: token))
            }

            guard let targetURL = components?.url else {
                throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid Google Drive directory URL"])
            }

            var request = URLRequest(url: targetURL)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "GoogleDriveManager", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed to list Google Drive files (HTTP \(code))"])
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["files"] as? [[String: Any]] else {
                break
            }

            for item in items {
                guard let rawName = item["name"] as? String,
                      let itemId = item["id"] as? String,
                      let mimeType = item["mimeType"] as? String else { continue }

                var isFolder = (mimeType == "application/vnd.google-apps.folder")
                var resolvedId = itemId

                if mimeType == "application/vnd.google-apps.shortcut",
                   let shortcut = item["shortcutDetails"] as? [String: Any],
                   let targetId = shortcut["targetId"] as? String,
                   let targetMime = shortcut["targetMimeType"] as? String {
                    resolvedId = targetId
                    isFolder = (targetMime == "application/vnd.google-apps.folder")
                }

                let itemPath = normalizedPath == "/" ? "/\(rawName)" : "\(normalizedPath)/\(rawName)"
                setFileId(resolvedId, forPath: itemPath, serverId: server.id)

                let sizeString = item["size"] as? String ?? ""
                let size = Int64(sizeString) ?? 0

                var date = Date()
                if let dateStr = item["modifiedTime"] as? String {
                    date = Self.iso8601Formatter.date(from: dateStr) ?? Self.fallbackISO8601Formatter.date(from: dateStr) ?? Date()
                }

                var thumbnailURL: URL?
                if let thumbStr = item["thumbnailLink"] as? String {
                    thumbnailURL = URL(string: thumbStr)
                }

                let fileURL = URL(fileURLWithPath: itemPath)
                let fileType: VideoFile.FileType
                if isFolder {
                    fileType = .folder
                } else {
                    fileType = VideoFile.FileType.determineType(from: URL(fileURLWithPath: rawName))
                }

                var videoFile = VideoFile(
                    name: rawName,
                    url: fileURL,
                    type: fileType,
                    size: size,
                    date: date,
                    isRemote: true,
                    serverType: .googledrive,
                    customArtworkURL: thumbnailURL,
                    itemCount: nil
                )
                videoFile.jellyfinServerId = server.id.uuidString
                videoFile.serverPath = itemPath
                videoFile.jellyfinItemId = resolvedId

                allFiles.append(videoFile)
            }

            pageToken = json["nextPageToken"] as? String
        } while pageToken != nil && !pageToken!.isEmpty

        return allFiles.sorted { f1, f2 in
            if f1.type == .folder && f2.type != .folder { return true }
            if f1.type != .folder && f2.type == .folder { return false }
            return f1.name.localizedStandardCompare(f2.name) == .orderedAscending
        }
    }

    private func resolveFolderId(forPath path: String, server: ServerConfig, token: String) async throws -> String {
        let components = path.split(separator: "/").map(String.init)
        var currentId = "root"
        var currentPath = ""

        for comp in components {
            currentPath += "/\(comp)"
            if let cached = fileId(forPath: currentPath, serverId: server.id) {
                currentId = cached
                continue
            }

            // Search for folder in currentId
            var urlComp = URLComponents(string: "\(Self.driveBaseURL)/files")
            let escapedName = comp.replacingOccurrences(of: "'", with: "\\'")
            let q = "'\(currentId)' in parents and name = '\(escapedName)' and trashed = false and mimeType = 'application/vnd.google-apps.folder'"
            urlComp?.queryItems = [
                URLQueryItem(name: "q", value: q),
                URLQueryItem(name: "fields", value: "files(id)"),
                URLQueryItem(name: "pageSize", value: "1"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
            ]

            guard let url = urlComp?.url else {
                throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid resolution URL"])
            }

            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = json["files"] as? [[String: Any]],
                  let first = files.first,
                  let foundId = first["id"] as? String else {
                throw NSError(domain: "GoogleDriveManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Folder not found: \(comp)"])
            }

            currentId = foundId
            setFileId(currentId, forPath: currentPath, serverId: server.id)
        }

        return currentId
    }

    // MARK: - Streaming & Local Proxy Playback URL

    public func playbackURL(server: ServerConfig, at path: String, fileId: String? = nil) async throws -> URL {
        let normalized = normalizePath(path)
        let resolvedFileId = try await resolveAudioFileID(server: server, path: path, fileId: fileId)

        GoogleDriveStreamServer.shared.registerServer(server)
        let port = try GoogleDriveStreamServer.shared.startIfNeeded()

        let rawFileName = (normalized as NSString).lastPathComponent
        let safeFileName = rawFileName.isEmpty ? "media.mp4" : rawFileName
        let encodedFileName = safeFileName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "media.mp4"

        guard var comp = URLComponents(string: "http://127.0.0.1:\(port)/stream/\(encodedFileName)") else {
            throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid stream URL components"])
        }
        comp.queryItems = [
            URLQueryItem(name: "serverId", value: server.id.uuidString),
            URLQueryItem(name: "fileId", value: resolvedFileId)
        ]
        guard let streamURL = comp.url else {
            throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid stream URL"])
        }
        return streamURL
    }

    private func resolveAudioFileID(server: ServerConfig, path: String, fileId: String?) async throws -> String {
        let normalized = normalizePath(path)
        let resolvedFileId: String
        if let fid = fileId, !fid.isEmpty {
            resolvedFileId = fid
        } else if let cached = self.fileId(forPath: normalized, serverId: server.id) {
            resolvedFileId = cached
        } else {
            let token = try await getValidAccessToken(for: server)
            let parentPath = (normalized as NSString).deletingLastPathComponent
            let fileName = (normalized as NSString).lastPathComponent
            let parentId = parentPath == "/" || parentPath.isEmpty ? "root" : try await resolveFolderId(forPath: parentPath, server: server, token: token)

            var comp = URLComponents(string: "\(Self.driveBaseURL)/files")
            let escapedName = fileName.replacingOccurrences(of: "'", with: "\\'")
            comp?.queryItems = [
                URLQueryItem(name: "q", value: "'\(parentId)' in parents and name = '\(escapedName)' and trashed = false"),
                URLQueryItem(name: "fields", value: "files(id)"),
                URLQueryItem(name: "pageSize", value: "1")
            ]
            guard let url = comp?.url else { throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid file lookup URL"]) }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = json["files"] as? [[String: Any]],
                  let first = files.first,
                  let fid = first["id"] as? String else {
                throw NSError(domain: "GoogleDriveManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "File not found: \(fileName)"])
            }
            resolvedFileId = fid
            setFileId(fid, forPath: normalized, serverId: server.id)
        }

        return resolvedFileId
    }

    #if os(macOS) || os(iOS) || os(tvOS)
    /// Direct authenticated ranges bypass the playback proxy and its buffering.
    func audioRangeRequest(server: ServerConfig, path: String, fileID: String?, forceRefresh: Bool) async throws -> URLRequest {
        let id = try await resolveAudioFileID(server: server, path: path, fileId: fileID)
        guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              let url = URL(string: "\(Self.driveBaseURL)/files/\(id)?alt=media") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await getValidAccessToken(for: server, forceRefresh: forceRefresh))", forHTTPHeaderField: "Authorization")
        return request
    }
    #endif

    // MARK: - Direct File Download (for Download Center)

    public func downloadFile(
        server: ServerConfig,
        at path: String,
        progress: ((Int64, Int64) -> Void)?
    ) async throws -> URL {
        let token = try await getValidAccessToken(for: server)
        let normalized = normalizePath(path)
        let fileId: String
        if let cached = self.fileId(forPath: normalized, serverId: server.id) {
            fileId = cached
        } else {
            let parentPath = (normalized as NSString).deletingLastPathComponent
            let fileName = (normalized as NSString).lastPathComponent
            let parentId = parentPath == "/" || parentPath.isEmpty ? "root" : try await resolveFolderId(forPath: parentPath, server: server, token: token)

            var comp = URLComponents(string: "\(Self.driveBaseURL)/files")
            let escapedName = fileName.replacingOccurrences(of: "'", with: "\\'")
            comp?.queryItems = [
                URLQueryItem(name: "q", value: "'\(parentId)' in parents and name = '\(escapedName)' and trashed = false"),
                URLQueryItem(name: "fields", value: "files(id)"),
                URLQueryItem(name: "pageSize", value: "1")
            ]
            guard let url = comp?.url else { throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid file URL"]) }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = json["files"] as? [[String: Any]],
                  let first = files.first,
                  let fid = first["id"] as? String else {
                throw NSError(domain: "GoogleDriveManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "File not found"])
            }
            fileId = fid
            setFileId(fid, forPath: normalized, serverId: server.id)
        }

        guard let downloadURL = URL(string: "\(Self.driveBaseURL)/files/\(fileId)?alt=media") else {
            throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid download URL"])
        }

        var request = URLRequest(url: downloadURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let destinationURL = tempDir.appendingPathComponent(fileName)

        return try await performDownload(request: request, destinationURL: destinationURL, progress: progress)
    }

    private func performDownload(
        request: URLRequest,
        destinationURL: URL,
        progress: ((Int64, Int64) -> Void)?
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(configuration: .default)
            let task = session.downloadTask(with: request) { tempURL, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let tempURL = tempURL else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    continuation.resume(throwing: NSError(domain: "GoogleDriveManager", code: code, userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \(code))"]))
                    return
                }
                do {
                    try DownloadFileValidation.validateHTTP(response: response, fileURL: tempURL)
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destinationURL)
                    continuation.resume(returning: destinationURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
        }
    }

    // MARK: - File Mutations

    public func createFolder(server: ServerConfig, at parentPath: String, name: String) async throws {
        let token = try await getValidAccessToken(for: server)
        let normalizedParent = normalizePath(parentPath)
        let parentId: String
        if normalizedParent == "/" {
            parentId = "root"
        } else if let cached = fileId(forPath: normalizedParent, serverId: server.id) {
            parentId = cached
        } else {
            parentId = try await resolveFolderId(forPath: normalizedParent, server: server, token: token)
            setFileId(parentId, forPath: normalizedParent, serverId: server.id)
        }

        guard let createURL = URL(string: "\(Self.driveBaseURL)/files?supportsAllDrives=true") else {
            throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid create URL"])
        }

        var request = URLRequest(url: createURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parentId]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "GoogleDriveManager", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed to create folder (HTTP \(code))"])
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let newId = json["id"] as? String {
            let createdPath = normalizedParent == "/" ? "/\(name)" : "\(normalizedParent)/\(name)"
            setFileId(newId, forPath: createdPath, serverId: server.id)
        }
    }

    public func deleteItem(server: ServerConfig, at path: String) async throws {
        let token = try await getValidAccessToken(for: server)
        let normalizedPath = normalizePath(path)
        let fileId: String
        if let cached = self.fileId(forPath: normalizedPath, serverId: server.id) {
            fileId = cached
        } else {
            let parentPath = (normalizedPath as NSString).deletingLastPathComponent
            let fileName = (normalizedPath as NSString).lastPathComponent
            let parentId = parentPath == "/" || parentPath.isEmpty ? "root" : try await resolveFolderId(forPath: parentPath, server: server, token: token)

            var comp = URLComponents(string: "\(Self.driveBaseURL)/files")
            let escapedName = fileName.replacingOccurrences(of: "'", with: "\\'")
            comp?.queryItems = [
                URLQueryItem(name: "q", value: "'\(parentId)' in parents and name = '\(escapedName)' and trashed = false"),
                URLQueryItem(name: "fields", value: "files(id)"),
                URLQueryItem(name: "pageSize", value: "1")
            ]
            guard let url = comp?.url else { throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid delete URL"]) }
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = json["files"] as? [[String: Any]],
                  let first = files.first,
                  let fid = first["id"] as? String else {
                throw NSError(domain: "GoogleDriveManager", code: 404, userInfo: [NSLocalizedDescriptionKey: "Item not found to delete"])
            }
            fileId = fid
        }

        guard let deleteURL = URL(string: "\(Self.driveBaseURL)/files/\(fileId)?supportsAllDrives=true") else {
            throw NSError(domain: "GoogleDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid delete URL"])
        }

        var request = URLRequest(url: deleteURL)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "GoogleDriveManager", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed to delete item (HTTP \(code))"])
        }

        pathMappingLock.lock()
        pathIdMap.removeValue(forKey: cacheKey(serverId: server.id, path: normalizedPath))
        pathMappingLock.unlock()
    }
}

// MARK: - Google Drive Local HTTP Streaming Relay Server

public final class GoogleDriveStreamServer: NSObject {
    public static let shared = GoogleDriveStreamServer()

    private var listeningSocket: Int32 = -1
    public private(set) var port: Int = 0
    private var acceptSource: DispatchSourceRead?
    private let serverQueue = DispatchQueue(label: "com.genplayer.googledrive.streamserver", qos: .userInitiated)
    private var activeSessions: [UUID: GoogleDriveStreamClientSession] = [:]
    private var registeredServers: [UUID: ServerConfig] = [:]
    private let lock = NSLock()

    private override init() {
        super.init()
    }

    deinit {
        stop()
    }

    public func registerServer(_ server: ServerConfig) {
        lock.lock()
        registeredServers[server.id] = server
        lock.unlock()
    }

    public func getServer(id: UUID) -> ServerConfig? {
        lock.lock()
        let server = registeredServers[id]
        lock.unlock()
        return server ?? AppNetworkService.shared.servers.first(where: { $0.id == id })
    }

    public func startIfNeeded() throws -> Int {
        lock.lock()
        defer { lock.unlock() }

        if listeningSocket >= 0 && port > 0 {
            return port
        }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            let err = errno
            throw NSError(domain: "GoogleDriveStreamServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to create loopback socket: \(err)"])
        }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(0)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindRes = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindRes == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: "GoogleDriveStreamServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to bind loopback socket: \(err)"])
        }

        guard Darwin.listen(fd, 64) == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: "GoogleDriveStreamServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to listen on socket: \(err)"])
        }

        var actualAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getSockRes = withUnsafeMutablePointer(to: &actualAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &addrLen)
            }
        }
        guard getSockRes == 0 else {
            let err = errno
            Darwin.close(fd)
            throw NSError(domain: "GoogleDriveStreamServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "Failed to get socket name: \(err)"])
        }

        let assignedPort = Int(UInt16(bigEndian: actualAddr.sin_port))
        self.port = assignedPort
        self.listeningSocket = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: serverQueue)
        source.setEventHandler { [weak self] in
            self?.acceptConnections()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        self.acceptSource = source
        return assignedPort
    }

    public func stop() {
        lock.lock()
        acceptSource?.cancel()
        acceptSource = nil
        listeningSocket = -1
        port = 0
        let sessions = Array(activeSessions.values)
        activeSessions.removeAll()
        lock.unlock()

        for session in sessions {
            session.closeSession()
        }
    }

    private func acceptConnections() {
        lock.lock()
        let listenFd = listeningSocket
        lock.unlock()
        guard listenFd >= 0 else { return }

        while true {
            var clientAddr = sockaddr_in()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.accept(listenFd, $0, &clientAddrLen)
                }
            }
            if clientFd < 0 {
                break
            }

            var nosig: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))

            var sendTimeout = timeval(tv_sec: 60, tv_usec: 0)
            setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))

            let sessionId = UUID()
            let session = GoogleDriveStreamClientSession(
                id: sessionId,
                clientFd: clientFd,
                queue: serverQueue
            ) { [weak self] id in
                self?.removeSession(id)
            }

            lock.lock()
            activeSessions[sessionId] = session
            lock.unlock()

            session.start()
        }
    }

    private func removeSession(_ id: UUID) {
        lock.lock()
        activeSessions.removeValue(forKey: id)
        lock.unlock()
    }
}

// MARK: - Google Drive Stream Client Session

private final class GoogleDriveStreamClientSession: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
    let id: UUID
    private var clientFd: Int32
    private let queue: DispatchQueue
    private let onClose: (UUID) -> Void
    private var readSource: DispatchSourceRead?
    private var incomingData = Data()
    private var session: URLSession?
    private var currentTask: URLSessionDataTask?
    private let lock = NSLock()
    private var isClosed = false

    private var clientMethod: String = "GET"
    private var clientRange: String?
    private var serverConfig: ServerConfig?
    private var fileId: String = ""
    private var currentToken: String = ""
    private var hasRetriedWithFreshToken = false

    init(id: UUID, clientFd: Int32, queue: DispatchQueue, onClose: @escaping (UUID) -> Void) {
        self.id = id
        self.clientFd = clientFd
        self.queue = queue
        self.onClose = onClose
        super.init()
    }

    func start() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            guard !self.isClosed, self.clientFd >= 0 else {
                self.lock.unlock()
                return
            }
            let fd = self.clientFd
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: self.queue)
            source.setEventHandler { [weak self] in
                self?.readClientData()
            }
            source.resume()
            self.readSource = source
            self.lock.unlock()
        }
    }

    private func readClientData() {
        lock.lock()
        let fd = clientFd
        lock.unlock()
        guard fd >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.recv(fd, &buffer, buffer.count, 0)
        if bytesRead > 0 {
            incomingData.append(buffer, count: bytesRead)
            if incomingData.count > 65536 {
                sendError(statusCode: 431, message: "Request Header Fields Too Large")
                return
            }
            if let headerEnd = incomingData.range(of: Data([0x0D, 0x0A, 0x0D, 0x0A])) {
                let headerData = incomingData.subdata(in: 0..<headerEnd.lowerBound)
                lock.lock()
                readSource?.cancel()
                readSource = nil
                let flags = fcntl(fd, F_GETFL, 0)
                _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK)
                lock.unlock()

                processClientRequest(headerData: headerData)
            }
        } else if bytesRead == 0 {
            closeSession()
        } else {
            if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                closeSession()
            }
        }
    }

    private func processClientRequest(headerData: Data) {
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            sendError(statusCode: 400, message: "Bad Request")
            return
        }

        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(statusCode: 400, message: "Bad Request")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendError(statusCode: 400, message: "Bad Request")
            return
        }

        let method = parts[0].uppercased()
        guard method == "GET" || method == "HEAD" else {
            sendError(statusCode: 405, message: "Method Not Allowed")
            return
        }
        self.clientMethod = method

        let pathAndQuery = parts[1]
        guard let components = URLComponents(string: pathAndQuery) else {
            sendError(statusCode: 400, message: "Bad Request")
            return
        }

        var serverIdString: String?
        var requestedFileId: String?
        for item in components.queryItems ?? [] {
            if item.name == "serverId" { serverIdString = item.value }
            if item.name == "fileId" { requestedFileId = item.value }
        }

        guard let sIdStr = serverIdString, let serverUUID = UUID(uuidString: sIdStr),
              let fid = requestedFileId, !fid.isEmpty else {
            sendError(statusCode: 400, message: "Missing serverId or fileId")
            return
        }

        self.fileId = fid

        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 && pair[0].caseInsensitiveCompare("Range") == .orderedSame {
                self.clientRange = pair[1]
                break
            }
        }

        guard let server = GoogleDriveStreamServer.shared.getServer(id: serverUUID) else {
            sendError(statusCode: 404, message: "Server Not Found")
            return
        }
        self.serverConfig = server

        Task {
            do {
                let token = try await GoogleDriveManager.shared.getValidAccessToken(for: server)
                self.currentToken = token
                self.startUpstreamTask(server: server, fileId: fid, token: token)
            } catch {
                print("[GoogleDriveStreamServer] Token resolution error: \(error.localizedDescription)")
                self.sendError(statusCode: 401, message: "Authentication Failed: \(error.localizedDescription)")
            }
        }
    }

    private func startUpstreamTask(server: ServerConfig, fileId: String, token: String) {
        lock.lock()
        guard !isClosed, clientFd >= 0 else {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let upstreamURL = URL(string: "\(GoogleDriveManager.driveBaseURL)/files/\(fileId)?alt=media&supportsAllDrives=true") else {
            sendError(statusCode: 400, message: "Invalid URL")
            return
        }

        var req = URLRequest(url: upstreamURL)
        req.httpMethod = clientMethod
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let range = clientRange {
            req.setValue(range, forHTTPHeaderField: "Range")
        }
        req.setValue("GenPlayer/1.0", forHTTPHeaderField: "User-Agent")

        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 86400.0

        let urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        lock.lock()
        self.session = urlSession
        let task = urlSession.dataTask(with: req)
        self.currentTask = task
        lock.unlock()

        task.resume()
    }

    // MARK: - URLSession Delegates

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        var redirectedReq = request
        // Crucial: Apple URLSession strips Authorization across different domains (googleapis.com -> googleusercontent.com).
        // We must re-attach Bearer token and Range header so Google CDN authorizes the stream.
        redirectedReq.setValue("Bearer \(self.currentToken)", forHTTPHeaderField: "Authorization")
        if let range = self.clientRange {
            redirectedReq.setValue(range, forHTTPHeaderField: "Range")
        }
        completionHandler(redirectedReq)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            closeSession()
            return
        }

        let statusCode = http.statusCode

        if statusCode == 401 && !hasRetriedWithFreshToken, let server = serverConfig {
            hasRetriedWithFreshToken = true
            completionHandler(.cancel)
            Task {
                do {
                    let freshToken = try await GoogleDriveManager.shared.getValidAccessToken(for: server, forceRefresh: true)
                    self.currentToken = freshToken
                    self.startUpstreamTask(server: server, fileId: self.fileId, token: freshToken)
                } catch {
                    self.sendError(statusCode: 401, message: "Token refresh failed: \(error.localizedDescription)")
                }
            }
            return
        }

        let statusText = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        var headerString = "HTTP/1.1 \(statusCode) \(statusText)\r\n"

        let headersToForward = [
            "Content-Type", "Content-Length", "Content-Range",
            "Accept-Ranges", "ETag", "Last-Modified"
        ]
        for key in headersToForward {
            if let value = http.value(forHTTPHeaderField: key) {
                headerString += "\(key): \(value)\r\n"
            }
        }
        if http.value(forHTTPHeaderField: "Accept-Ranges") == nil {
            headerString += "Accept-Ranges: bytes\r\n"
        }
        headerString += "Connection: keep-alive\r\n\r\n"

        if let headerData = headerString.data(using: .utf8) {
            if !writeToSocket(headerData) {
                completionHandler(.cancel)
                closeSession()
                return
            }
        }

        if clientMethod == "HEAD" {
            completionHandler(.cancel)
            closeSession()
            return
        }

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if !writeToSocket(data) {
            dataTask.cancel()
            closeSession()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        closeSession()
    }

    // MARK: - Socket Operations

    private func writeToSocket(_ data: Data) -> Bool {
        lock.lock()
        let fd = clientFd
        lock.unlock()
        guard fd >= 0 else { return false }

        return data.withUnsafeBytes { rawBuffer in
            guard let ptr = rawBuffer.baseAddress else { return true }
            var written = 0
            let total = rawBuffer.count
            while written < total {
                let chunk = total - written
                let n = Darwin.send(fd, ptr + written, chunk, 0)
                if n < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                written += n
            }
            return true
        }
    }

    private func sendError(statusCode: Int, message: String) {
        let body = "\(statusCode) \(message)\n"
        let response = "HTTP/1.1 \(statusCode) \(message)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        if let data = response.data(using: .utf8) {
            _ = writeToSocket(data)
        }
        closeSession()
    }

    func closeSession() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        readSource?.cancel()
        readSource = nil
        let fd = clientFd
        clientFd = -1
        let task = currentTask
        currentTask = nil
        let s = session
        session = nil
        lock.unlock()

        task?.cancel()
        s?.invalidateAndCancel()
        if fd >= 0 {
            Darwin.close(fd)
        }
        onClose(id)
    }
}
