import Foundation

public class AListManager {
    public init() {}
    
    // MARK: - Models
    
    private struct BaseResponse<T: Decodable>: Decodable {
        let code: Int
        let message: String
        let data: T?
    }
    
    private struct TokenData: Decodable {
        let token: String
    }
    
    private struct ListData: Decodable {
        let content: [FileEntry]?
    }
    
    private struct FileEntry: Decodable {
        let name: String
        let size: Int64
        let is_dir: Bool
        let modified: String?
        let thumb: String?
        let raw_url: String?
    }
    
    // MARK: - Helpers
    
    private func requestBaseURL(for server: ServerConfig) -> URL? {
        let runtimeBase = RuntimeNetworkAddressResolver.runtimeAddress(from: server.fullURL)
        return URL(string: runtimeBase)
    }
    
    private func apiURL(server: ServerConfig, endpoint: String) -> URL? {
        guard let baseURL = requestBaseURL(for: server) else { return nil }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path ?? ""
        let normalizedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        let normalizedEndpoint = endpoint.hasPrefix("/") ? endpoint : "/\(endpoint)"
        components?.path = normalizedBase + normalizedEndpoint
        return components?.url
    }
    
    private func performRequest<T: Decodable>(url: URL, method: String, body: [String: Any]? = nil, token: String? = nil) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        if let token = token, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        
        if let body = body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "AListManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        if httpResponse.statusCode == 401 {
            throw NSError(domain: "AListManager", code: 401, userInfo: [NSLocalizedDescriptionKey: "Authentication failed"])
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NSError(domain: "AListManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP Error \(httpResponse.statusCode)"])
        }
        
        // Handle empty responses for some AList ops (like delete/mkdir that return null data)
        if data.isEmpty {
            if let emptyObj = try? JSONDecoder().decode(T.self, from: "{}".data(using: .utf8)!) {
                return emptyObj
            }
        }
        
        let baseResponse = try JSONDecoder().decode(BaseResponse<T>.self, from: data)
        guard baseResponse.code == 200 else {
            throw NSError(domain: "AListManager", code: baseResponse.code, userInfo: [NSLocalizedDescriptionKey: baseResponse.message])
        }
        
        if let responseData = baseResponse.data {
            return responseData
        } else {
            // If data is null but code is 200, return empty object if T is optional or can be decoded from {}
            if let emptyObj = try? JSONDecoder().decode(T.self, from: "{}".data(using: .utf8)!) {
                return emptyObj
            }
            throw NSError(domain: "AListManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing data in response"])
        }
    }
    
    // Empty object for endpoints that don't return data
    private struct EmptyData: Decodable {}
    
    // MARK: - Auth
    
    public func login(server: ServerConfig) async throws -> String {
        guard let url = apiURL(server: server, endpoint: "/api/auth/login") else {
            throw NSError(domain: "AListManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        let username = server.username ?? ""
        let password = server.passwordSecret ?? ""
        
        let body: [String: Any] = [
            "username": username,
            "password": password
        ]
        
        let tokenData: TokenData = try await performRequest(url: url, method: "POST", body: body)
        return tokenData.token
    }
    
    // MARK: - List Files
    
    public func listFiles(server: ServerConfig, at path: String, token: String) async throws -> [VideoFile] {
        guard let url = apiURL(server: server, endpoint: "/api/fs/list") else {
            throw NSError(domain: "AListManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        let normalizedPath = path.isEmpty ? "/" : (path.hasPrefix("/") ? path : "/\(path)")
        
        let body: [String: Any] = [
            "path": normalizedPath,
            "password": "",
            "page": 1,
            "per_page": 0,
            "refresh": false
        ]
        
        let listData: ListData = try await performRequest(url: url, method: "POST", body: body, token: token)
        let entries = listData.content ?? []
        
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let strictFormatter = ISO8601DateFormatter()
        
        var files = entries.map { entry in
            var date: Date? = nil
            if let modified = entry.modified {
                date = dateFormatter.date(from: modified) ?? strictFormatter.date(from: modified)
            }
            
            let itemPath = normalizedPath == "/" ? "/\(entry.name)" : "\(normalizedPath)/\(entry.name)"
            let type: VideoFile.FileType = entry.is_dir ? .folder : VideoFile.FileType.determineType(from: URL(fileURLWithPath: itemPath))
            
            let url = URL(fileURLWithPath: itemPath)
            var file = VideoFile(
                name: entry.name,
                url: url,
                type: type,
                size: entry.size,
                date: date ?? Date(),
                duration: nil
            )
            file.isRemote = true
            file.serverType = .alist
            file.jellyfinServerId = server.id.uuidString
            file.serverPath = itemPath
            return file
        }

        return files
    }
    
    // MARK: - Get File Detail
    
    public func fileURL(server: ServerConfig, at path: String, token: String) async throws -> URL {
        guard let url = apiURL(server: server, endpoint: "/api/fs/get") else {
            throw NSError(domain: "AListManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        
        let normalizedPath = path.isEmpty ? "/" : (path.hasPrefix("/") ? path : "/\(path)")
        let body: [String: Any] = ["path": normalizedPath, "password": ""]
        
        let detail: FileEntry = try await performRequest(url: url, method: "POST", body: body, token: token)
        guard let rawURL = detail.raw_url,
              let resolvedURL = resolvedRawURL(rawURL, server: server) else {
            throw NSError(domain: "AListManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "No raw URL available"])
        }
        return resolvedURL
    }

    /// Resolves AList's raw URL only when the user opens a file.
    public func playbackURL(server: ServerConfig, at path: String, token: String) async throws -> URL {
        try await fileURL(server: server, at: path, token: token)
    }
    
    public func downloadRequest(server: ServerConfig, at path: String, token: String) async throws -> URLRequest {
        let downloadURL = try await fileURL(server: server, at: path, token: token)
        
        var request = URLRequest(url: downloadURL)
        request.httpMethod = "GET"
        if let baseHost = requestBaseURL(for: server)?.host,
           let downloadHost = downloadURL.host,
           downloadHost.caseInsensitiveCompare(baseHost) == .orderedSame,
           !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func resolvedRawURL(_ rawURL: String, server: ServerConfig) -> URL? {
        let trimmedRawURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRawURL.isEmpty else { return nil }
        if let absoluteURL = URL(string: trimmedRawURL), absoluteURL.scheme != nil {
            return absoluteURL
        }
        guard let baseURL = requestBaseURL(for: server) else { return nil }
        return URL(string: trimmedRawURL, relativeTo: baseURL)?.absoluteURL
    }
    
    public func downloadFile(server: ServerConfig, at path: String, token: String) async throws -> URL {
        let request = try await downloadRequest(server: server, at: path, token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "AListManager", code: statusCode, userInfo: [NSLocalizedDescriptionKey: "Download failed (HTTP \(statusCode))"])
        }
        
        let fileName = (path as NSString).lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        let tempURL = tempDir.appendingPathComponent(fileName)
        
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try FileManager.default.removeItem(at: tempURL)
        }
        
        try data.write(to: tempURL)
        do {
            try DownloadFileValidation.validateHTTP(response: response, fileURL: tempURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        return tempURL
    }
    
    // MARK: - Other File Ops
    
    public func deleteFile(server: ServerConfig, at path: String, token: String) async throws {
        guard let url = apiURL(server: server, endpoint: "/api/fs/remove") else { throw NSError(domain: "AListManager", code: -1, userInfo: [:]) }
        let normalizedPath = path.isEmpty ? "/" : (path.hasPrefix("/") ? path : "/\(path)")
        let directory = (normalizedPath as NSString).deletingLastPathComponent
        let name = (normalizedPath as NSString).lastPathComponent
        let body: [String: Any] = ["names": [name], "dir": directory]
        let _: EmptyData = try await performRequest(url: url, method: "POST", body: body, token: token)
    }
    
    public func createFolder(server: ServerConfig, at path: String, token: String) async throws {
        guard let url = apiURL(server: server, endpoint: "/api/fs/mkdir") else { throw NSError(domain: "AListManager", code: -1, userInfo: [:]) }
        let normalizedPath = path.isEmpty ? "/" : (path.hasPrefix("/") ? path : "/\(path)")
        let body: [String: Any] = ["path": normalizedPath]
        let _: EmptyData = try await performRequest(url: url, method: "POST", body: body, token: token)
    }
    
    public func moveFile(server: ServerConfig, fromPath: String, toPath: String, token: String) async throws {
        guard let url = apiURL(server: server, endpoint: "/api/fs/move") else { throw NSError(domain: "AListManager", code: -1, userInfo: [:]) }
        let normalizedFrom = fromPath.isEmpty ? "/" : (fromPath.hasPrefix("/") ? fromPath : "/\(fromPath)")
        let normalizedTo = toPath.isEmpty ? "/" : (toPath.hasPrefix("/") ? toPath : "/\(toPath)")
        
        let srcDir = (normalizedFrom as NSString).deletingLastPathComponent
        let srcName = (normalizedFrom as NSString).lastPathComponent
        let dstDir = (normalizedTo as NSString).deletingLastPathComponent
        let dstName = (normalizedTo as NSString).lastPathComponent
        
        if srcDir == dstDir && srcName != dstName {
            // Rename
            guard let renameUrl = apiURL(server: server, endpoint: "/api/fs/rename") else { throw NSError(domain: "AListManager", code: -1, userInfo: [:]) }
            let body: [String: Any] = ["name": dstName, "path": normalizedFrom]
            let _: EmptyData = try await performRequest(url: renameUrl, method: "POST", body: body, token: token)
        } else {
            // Move
            let body: [String: Any] = ["names": [srcName], "src_dir": srcDir, "dst_dir": dstDir]
            let _: EmptyData = try await performRequest(url: url, method: "POST", body: body, token: token)
            // If name changed during move
            if srcName != dstName {
                guard let renameUrl = apiURL(server: server, endpoint: "/api/fs/rename") else { return }
                let newPath = "\(dstDir)/\(srcName)"
                let renameBody: [String: Any] = ["name": dstName, "path": newPath]
                let _: EmptyData? = try? await performRequest(url: renameUrl, method: "POST", body: renameBody, token: token)
            }
        }
    }
}
