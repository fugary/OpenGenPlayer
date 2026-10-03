import Foundation
import CommonCrypto
import Security

public final class OneDriveManager {
    public static let shared = OneDriveManager()

    public static let clientId = PublicOAuthConfiguration.value("GenPlayerOneDriveClientID")
    public static let redirectURI = "genplayer://oauth/onedrive"
    public static let scopes = "Files.Read.All offline_access User.Read"

    public static let authEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    public static let tokenEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
    public static let deviceCodeEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode"
    public static let graphBaseURL = "https://graph.microsoft.com/v1.0"

    private let pathMappingLock = NSLock()
    private var pathIdMap: [String: String] = [:]
    private var pathDownloadUrlMap: [String: (url: URL, expiration: Date)] = [:]

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

    public static func buildAuthorizationURL(challenge: String, state: String = UUID().uuidString) -> URL? {
        var components = URLComponents(string: authEndpoint)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        return components?.url
    }

    public struct TokenResponse {
        public let accessToken: String
        public let refreshToken: String
        public let expiresIn: Int
        public let displayName: String
    }

    public func exchangeCodeForTokens(code: String, verifier: String) async throws -> TokenResponse {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw NSError(domain: "OneDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid token endpoint"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParameters: [String: String] = [
            "client_id": Self.clientId,
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "code_verifier": verifier,
            "scope": Self.scopes
        ]

        request.httpBody = bodyParameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OneDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String ?? "HTTP \(httpResponse.statusCode)"
            throw NSError(domain: "OneDriveManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            throw NSError(domain: "OneDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to parse token response"])
        }

        let expiresIn = json["expires_in"] as? Int ?? 3600
        let userName = await fetchUserProfile(accessToken: accessToken) ?? "OneDrive"

        return TokenResponse(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresIn: expiresIn,
            displayName: userName
        )
    }

    public func refreshAccessToken(refreshToken: String) async throws -> (accessToken: String, refreshToken: String) {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw NSError(domain: "OneDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid token endpoint"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParameters: [String: String] = [
            "client_id": Self.clientId,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": Self.scopes
        ]

        request.httpBody = bodyParameters
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String ?? "Failed to refresh token"
            throw NSError(domain: "OneDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = json["access_token"] as? String else {
            throw NSError(domain: "OneDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid refresh token response"])
        }

        let newRefreshToken = json["refresh_token"] as? String ?? refreshToken
        return (accessToken, newRefreshToken)
    }

    // MARK: - Device Code Flow (tvOS / Alternative)

    public struct DeviceCodeInfo {
        public let userCode: String
        public let deviceCode: String
        public let verificationURI: String
        public let expiresIn: Int
        public let interval: Int
        public let message: String

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

    public func startDeviceCodeFlow() async throws -> DeviceCodeInfo {
        guard let url = URL(string: Self.deviceCodeEndpoint) else {
            throw NSError(domain: "OneDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid device code endpoint"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParameters: [String: String] = [
            "client_id": Self.clientId,
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
              let verificationURI = json["verification_uri"] as? String else {
            let errorMsg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error_description"] as? String ?? "Device code request failed"
            throw NSError(domain: "OneDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: errorMsg])
        }

        let expiresIn = json["expires_in"] as? Int ?? 900
        let interval = json["interval"] as? Int ?? 5
        let message = json["message"] as? String ?? "Please visit \(verificationURI) and enter \(userCode)"

        return DeviceCodeInfo(
            userCode: userCode,
            deviceCode: deviceCode,
            verificationURI: verificationURI,
            expiresIn: expiresIn,
            interval: interval,
            message: message
        )
    }

    public func pollDeviceCode(deviceCode: String) async -> DeviceCodePollStatus {
        guard let url = URL(string: Self.tokenEndpoint) else {
            return .error("Invalid token endpoint")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let bodyParameters: [String: String] = [
            "client_id": Self.clientId,
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": deviceCode
        ]

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

            if let accessToken = json["access_token"] as? String,
               let refreshToken = json["refresh_token"] as? String {
                let userName = await fetchUserProfile(accessToken: accessToken) ?? "OneDrive"
                return .success(accessToken: accessToken, refreshToken: refreshToken, displayName: userName)
            }

            return .error("No tokens in response")
        } catch {
            return .error(error.localizedDescription)
        }
    }

    // MARK: - User Profile

    public func fetchUserProfile(accessToken: String) async -> String? {
        guard let url = URL(string: "\(Self.graphBaseURL)/me") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["displayName"] as? String ?? json["userPrincipalName"] as? String
    }

    // MARK: - Token Validation & Retrieval

    public func getValidAccessToken(for server: ServerConfig) async throws -> String {
        if let token = server.accessToken, !token.isEmpty {
            // Probe with current token
            if await testToken(token) {
                return token
            }
        }

        // Refresh token is stored in passwordSecret
        guard let refreshToken = server.passwordSecret, !refreshToken.isEmpty else {
            throw NSError(domain: "OneDriveManager", code: 401, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Missing OneDrive Refresh Token. Please log in again.", comment: "")])
        }

        let (newAccessToken, newRefreshToken) = try await refreshAccessToken(refreshToken: refreshToken)
        await MainActor.run {
            AppNetworkService.shared.updateServerTokens(server.id, accessToken: newAccessToken, refreshToken: newRefreshToken)
        }
        return newAccessToken
    }

    public func testConnection(server: ServerConfig) async throws -> Bool {
        let token = try await getValidAccessToken(for: server)
        guard let url = URL(string: "\(Self.graphBaseURL)/me/drive/root") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            return false
        }
        return true
    }

    private func testToken(_ token: String) async -> Bool {
        guard let url = URL(string: "\(Self.graphBaseURL)/me/drive/root") else { return false }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 6.0
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
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
        defer { pathMappingLock.unlock() }
        let prefix = "\(serverId.uuidString):"
        pathIdMap = pathIdMap.filter { !$0.key.hasPrefix(prefix) }
        pathDownloadUrlMap = pathDownloadUrlMap.filter { !$0.key.hasPrefix(prefix) }
    }

    // MARK: - Microsoft Graph API Operations

    public func listFiles(server: ServerConfig, at path: String) async throws -> [VideoFile] {
        let token = try await getValidAccessToken(for: server)
        let normalizedPath = normalizePath(path)

        var requestURL: URL?
        if normalizedPath == "/" {
            requestURL = URL(string: "\(Self.graphBaseURL)/me/drive/root/children?$top=1000")
        } else if let cachedId = fileId(forPath: normalizedPath, serverId: server.id) {
            requestURL = URL(string: "\(Self.graphBaseURL)/me/drive/items/\(cachedId)/children?$top=1000")
        } else {
            let relativePath = String(normalizedPath.dropFirst())
            let encodedPath = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
            requestURL = URL(string: "\(Self.graphBaseURL)/me/drive/root:/\(encodedPath):/children?$top=1000")
        }

        guard let targetURL = requestURL else {
            throw NSError(domain: "OneDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid directory URL"])
        }

        var request = URLRequest(url: targetURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "OneDriveManager", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed to list OneDrive files (HTTP \(code))"])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["value"] as? [[String: Any]] else {
            return []
        }

        var files: [VideoFile] = []

        for item in values {
            guard let name = item["name"] as? String, let itemId = item["id"] as? String else { continue }
            let isFolder = (item["folder"] != nil)
            let itemPath = normalizedPath == "/" ? "/\(name)" : "\(normalizedPath)/\(name)"
            setFileId(itemId, forPath: itemPath, serverId: server.id)

            let size = item["size"] as? Int64 ?? 0
            var date = Date()
            if let dateStr = item["lastModifiedDateTime"] as? String {
                date = Self.iso8601Formatter.date(from: dateStr) ?? Self.fallbackISO8601Formatter.date(from: dateStr) ?? Date()
            }

            var downloadURL: URL?
            if let directString = item["@microsoft.graph.downloadUrl"] as? String, let directURL = URL(string: directString) {
                downloadURL = directURL
                pathMappingLock.lock()
                pathDownloadUrlMap[cacheKey(serverId: server.id, path: itemPath)] = (directURL, Date().addingTimeInterval(3600))
                pathMappingLock.unlock()
            }

            var thumbnailURL: URL?
            if let thumbnails = item["thumbnails"] as? [[String: Any]], let first = thumbnails.first {
                if let medium = first["medium"] as? [String: Any], let urlStr = medium["url"] as? String {
                    thumbnailURL = URL(string: urlStr)
                } else if let large = first["large"] as? [String: Any], let urlStr = large["url"] as? String {
                    thumbnailURL = URL(string: urlStr)
                }
            }

            let fileURL = URL(fileURLWithPath: itemPath)

            let fileType: VideoFile.FileType
            if isFolder {
                fileType = .folder
            } else {
                fileType = VideoFile.FileType.determineType(from: URL(fileURLWithPath: name))
            }

            var videoFile = VideoFile(
                name: name,
                url: fileURL,
                type: fileType,
                size: size,
                date: date,
                isRemote: true,
                serverType: .onedrive,
                customArtworkURL: thumbnailURL,
                itemCount: isFolder ? (item["folder"] as? [String: Any])?["childCount"] as? Int : nil
            )
            videoFile.jellyfinServerId = server.id.uuidString
            videoFile.serverPath = itemPath

            files.append(videoFile)
        }

        return files.sorted { f1, f2 in
            if f1.type == .folder && f2.type != .folder { return true }
            if f1.type != .folder && f2.type == .folder { return false }
            return f1.name.localizedStandardCompare(f2.name) == .orderedAscending
        }
    }

    public func rawDownloadURL(server: ServerConfig, at path: String, forceRefresh: Bool = false) async throws -> URL {
        let normalizedPath = normalizePath(path)
        let key = cacheKey(serverId: server.id, path: normalizedPath)

        pathMappingLock.lock()
        if !forceRefresh, let cached = pathDownloadUrlMap[key], cached.expiration > Date() {
            pathMappingLock.unlock()
            return cached.url
        }
        pathMappingLock.unlock()

        let token = try await getValidAccessToken(for: server)
        var itemURL: URL?

        if let cachedId = fileId(forPath: normalizedPath, serverId: server.id) {
            itemURL = URL(string: "\(Self.graphBaseURL)/me/drive/items/\(cachedId)")
        } else {
            let relativePath = String(normalizedPath.dropFirst())
            let encodedPath = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
            itemURL = URL(string: "\(Self.graphBaseURL)/me/drive/root:/\(encodedPath)")
        }

        guard let targetURL = itemURL else {
            throw NSError(domain: "OneDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid file URL"])
        }

        var request = URLRequest(url: targetURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "OneDriveManager", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed to get OneDrive download URL (HTTP \(code))"])
        }

        if let id = json["id"] as? String {
            setFileId(id, forPath: normalizedPath, serverId: server.id)
        }

        guard let downloadUrlString = json["@microsoft.graph.downloadUrl"] as? String,
              let downloadURL = URL(string: downloadUrlString) else {
            throw NSError(domain: "OneDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download URL not available for this item"])
        }

        pathMappingLock.lock()
        pathDownloadUrlMap[key] = (downloadURL, Date().addingTimeInterval(3600))
        pathMappingLock.unlock()

        return downloadURL
    }

    public func createFolder(server: ServerConfig, at parentPath: String, name: String) async throws {
        let token = try await getValidAccessToken(for: server)
        let normalizedParent = normalizePath(parentPath)

        var createURL: URL?
        if normalizedParent == "/" {
            createURL = URL(string: "\(Self.graphBaseURL)/me/drive/root/children")
        } else if let cachedId = fileId(forPath: normalizedParent, serverId: server.id) {
            createURL = URL(string: "\(Self.graphBaseURL)/me/drive/items/\(cachedId)/children")
        } else {
            let relativePath = String(normalizedParent.dropFirst())
            let encodedPath = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
            createURL = URL(string: "\(Self.graphBaseURL)/me/drive/root:/\(encodedPath):/children")
        }

        guard let targetURL = createURL else {
            throw NSError(domain: "OneDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid parent directory URL"])
        }

        var request = URLRequest(url: targetURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "name": name,
            "folder": [String: Any](),
            "@microsoft.graph.conflictBehavior": "rename"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let desc = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any]
            let message = desc?["message"] as? String ?? "Failed to create folder (HTTP \(code))"
            throw NSError(domain: "OneDriveManager", code: code, userInfo: [NSLocalizedDescriptionKey: message])
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

        var deleteURL: URL?
        if let cachedId = fileId(forPath: normalizedPath, serverId: server.id) {
            deleteURL = URL(string: "\(Self.graphBaseURL)/me/drive/items/\(cachedId)")
        } else {
            let relativePath = String(normalizedPath.dropFirst())
            let encodedPath = relativePath.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relativePath
            deleteURL = URL(string: "\(Self.graphBaseURL)/me/drive/root:/\(encodedPath)")
        }

        guard let targetURL = deleteURL else {
            throw NSError(domain: "OneDriveManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid file URL"])
        }

        var request = URLRequest(url: targetURL)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "OneDriveManager", code: code, userInfo: [NSLocalizedDescriptionKey: "Failed to delete item (HTTP \(code))"])
        }

        pathMappingLock.lock()
        pathIdMap.removeValue(forKey: cacheKey(serverId: server.id, path: normalizedPath))
        pathDownloadUrlMap.removeValue(forKey: cacheKey(serverId: server.id, path: normalizedPath))
        pathMappingLock.unlock()
    }
}
