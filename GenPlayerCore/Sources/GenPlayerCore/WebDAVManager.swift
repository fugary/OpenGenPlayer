import Foundation

/// Native WebDAV client implementation
/// Uses direct URLSession PROPFIND requests instead of third-party library
public class WebDAVManager {
    public init() {}

    private func requestBaseURL(for server: ServerConfig) -> URL? {
        let runtimeBase = RuntimeNetworkAddressResolver.runtimeAddress(from: server.fullURL)
        return URL(string: runtimeBase)
    }

    private func requestURL(server: ServerConfig, at path: String) -> URL? {
        guard let baseURL = requestBaseURL(for: server),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let basePath = normalizedBasePath(from: components.path)
        let relativePath = normalizedServerPath(path, server: server)
        let requestPath: String

        if relativePath == "/" {
            requestPath = basePath.isEmpty ? "/" : "\(basePath)/"
        } else if basePath.isEmpty {
            requestPath = relativePath
        } else {
            requestPath = "\(basePath)\(relativePath)"
        }

        components.path = requestPath
        return components.url
    }
    
    // MARK: - List Files (Native PROPFIND)
    
    /// List files at the given path using native PROPFIND
    public func listFiles(server: ServerConfig, at path: String) async throws -> [VideoFile] {
        guard let fullURL = requestURL(server: server, at: path) else {
            throw NSError(domain: "WebDAVManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid baseURL"])
        }
        
        print("[WebDAVManager] PROPFIND to: \(fullURL.absoluteString)")
        
        var request = URLRequest(url: fullURL)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        
        // Add Basic Auth
        addBasicAuth(to: &request, server: server)
        
        // PROPFIND body
        let propfindBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
            <D:allprop/>
        </D:propfind>
        """
        request.httpBody = propfindBody.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "WebDAVManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
        }
        
        if httpResponse.statusCode == 401 {
            throw NSError(domain: "WebDAVManager", code: 401, userInfo: [NSLocalizedDescriptionKey: "Authentication failed"])
        }
        
        guard httpResponse.statusCode == 207 else {
            throw NSError(domain: "WebDAVManager", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Unexpected status: \(httpResponse.statusCode)"])
        }
        
        // Parse the XML response
        let parser = WebDAVResponseParser(data: data, basePath: path)
        let entries = parser.parse()
        
        print("[WebDAVManager] Parsed \(entries.count) entries")
        
        // Convert to VideoFile
        let videoFiles = entries.compactMap { entry -> VideoFile? in
            return convertToVideoFile(entry, server: server, parentPath: path)
        }
        
        print("[WebDAVManager] Converted to \(videoFiles.count) video files")
        return videoFiles
    }
    
    // MARK: - Download File (Native GET)

    public func downloadRequest(server: ServerConfig, at path: String) -> URLRequest? {
        guard let fullURL = requestURL(server: server, at: path) else {
            return nil
        }

        var request = URLRequest(url: fullURL)
        request.httpMethod = "GET"
        addBasicAuth(to: &request, server: server)
        return request
    }
    
    public func downloadFile(server: ServerConfig, at path: String) async throws -> URL {
        guard let request = downloadRequest(server: server, at: path) else {
            throw NSError(domain: "WebDAVManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid baseURL"])
        }
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw NSError(domain: "WebDAVManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download failed"])
        }
        
        // Save to temp file
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        
        // Create a unique temp directory for this download to prevent pollution
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
    
    // MARK: - Delete File (Native DELETE)
    
    public func deleteFile(server: ServerConfig, at path: String) async throws {
        guard let fullURL = requestURL(server: server, at: path) else {
            throw NSError(domain: "WebDAVManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid baseURL"])
        }

        var request = URLRequest(url: fullURL)
        request.httpMethod = "DELETE"
        addBasicAuth(to: &request, server: server)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 204 else {
            throw NSError(domain: "WebDAVManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Delete failed"])
        }
    }
    
    // MARK: - Move File (Native MOVE)
    
    public func moveFile(server: ServerConfig, fromPath: String, toPath: String) async throws {
        guard let sourceURL = requestURL(server: server, at: fromPath),
              let destURL = requestURL(server: server, at: toPath) else {
            throw NSError(domain: "WebDAVManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid baseURL"])
        }

        var request = URLRequest(url: sourceURL)
        request.httpMethod = "MOVE"
        request.setValue(destURL.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("T", forHTTPHeaderField: "Overwrite")
        addBasicAuth(to: &request, server: server)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 201 else {
            throw NSError(domain: "WebDAVManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Move failed"])
        }
    }
    
    // MARK: - Create Folder (Native MKCOL)
    
    public func createFolder(server: ServerConfig, at path: String) async throws {
        guard let fullURL = requestURL(server: server, at: path) else {
            throw NSError(domain: "WebDAVManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid baseURL"])
        }

        var request = URLRequest(url: fullURL)
        request.httpMethod = "MKCOL"
        addBasicAuth(to: &request, server: server)
        
        let (_, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) || httpResponse.statusCode == 201 else {
            throw NSError(domain: "WebDAVManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Create folder failed"])
        }
    }
    
    // MARK: - Private Helpers
    
    private func addBasicAuth(to request: inout URLRequest, server: ServerConfig) {
        if let username = server.username, !username.isEmpty {
            let password = server.passwordSecret ?? ""
            let credentials = "\(username):\(password)"
            if let credData = credentials.data(using: .utf8) {
                let base64 = credData.base64EncodedString()
                request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
            }
        }
    }
    
    private func convertToVideoFile(_ entry: WebDAVEntry, server: ServerConfig, parentPath: String) -> VideoFile? {
        let normalizedEntryPath = normalizedServerPath(entry.href, server: server)
        let normalizedParentPath = normalizedServerPath(parentPath, server: server)
        let fileName = entry.name
        
        // Skip hidden files and parent references
        if fileName.hasPrefix(".") || fileName == ".." || fileName.isEmpty {
            return nil
        }

        // Skip the directory itself based on server-relative path.
        if normalizedEntryPath == normalizedParentPath {
            return nil
        }

        // Build playback URL
        let playbackURL = buildPlaybackURL(server: server, path: normalizedEntryPath)
        
        // Determine file type
        let fileType: VideoFile.FileType
        if entry.isCollection {
            fileType = .folder
        } else {
            fileType = VideoFile.FileType.determineType(from: URL(fileURLWithPath: fileName))
        }
        
        var file = VideoFile(
            name: fileName,
            url: playbackURL,
            type: fileType,
            size: entry.contentLength,
            date: entry.lastModified ?? Date(),
            duration: nil
        )
        file.isRemote = true
        file.serverType = server.type
        file.jellyfinServerId = server.id.uuidString
        file.serverPath = normalizedEntryPath
        
        return file
    }
    
    private func buildPlaybackURL(server: ServerConfig, path: String) -> URL {
        guard let fullURL = requestURL(server: server, at: path),
              var components = URLComponents(url: fullURL, resolvingAgainstBaseURL: false) else {
            return URL(fileURLWithPath: path)
        }
        
        // Add credentials for VLC playback
        if let username = server.username, !username.isEmpty {
            components.user = username
            if let password = server.passwordSecret, !password.isEmpty {
                components.password = password
            }
        }

        return components.url ?? URL(fileURLWithPath: path)
    }

    private func normalizedBasePath(from path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else {
            return ""
        }
        var normalized = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func normalizedServerPath(_ rawPath: String, server: ServerConfig) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "/"
        }

        let rawURL = URL(string: trimmed)
        let decodedPath = (rawURL?.path ?? trimmed).removingPercentEncoding ?? (rawURL?.path ?? trimmed)
        var normalized = decodedPath.hasPrefix("/") ? decodedPath : "/\(decodedPath)"

        while normalized.contains("//") {
            normalized = normalized.replacingOccurrences(of: "//", with: "/")
        }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }

        let basePath = normalizedBasePath(from: requestBaseURL(for: server)?.path ?? "")
        guard !basePath.isEmpty else {
            return normalized.isEmpty ? "/" : normalized
        }

        if normalized == basePath {
            return "/"
        }
        if normalized.hasPrefix("\(basePath)/") {
            let stripped = String(normalized.dropFirst(basePath.count))
            return stripped.isEmpty ? "/" : stripped
        }

        return normalized.isEmpty ? "/" : normalized
    }
}

// MARK: - WebDAV XML Parser

public struct WebDAVEntry {
    public var href: String = ""
    public var name: String = ""
    public var isCollection: Bool = false
    public var contentLength: Int64 = 0
    public var lastModified: Date?
    public var contentType: String?
}

public class WebDAVResponseParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let basePath: String
    
    private var entries: [WebDAVEntry] = []
    private var currentEntry: WebDAVEntry?
    private var currentElement: String = ""
    private var currentText: String = ""
    
    // Track nested elements
    private var inResponse = false
    private var inPropstat = false
    private var inProp = false
    
    public init(data: Data, basePath: String) {
        self.data = data
        self.basePath = basePath
        super.init()
    }
    
    public func parse() -> [WebDAVEntry] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return entries
    }
    
    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String : String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        currentElement = localName.lowercased()
        currentText = ""
        
        switch currentElement {
        case "response":
            inResponse = true
            currentEntry = WebDAVEntry()
        case "propstat":
            inPropstat = true
        case "prop":
            inProp = true
        case "collection":
            currentEntry?.isCollection = true
        default:
            break
        }
    }
    
    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        let element = localName.lowercased()
        let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        switch element {
        case "response":
            if let entry = currentEntry, !entry.href.isEmpty {
                // Extract name from href
                var finalEntry = entry
                let decodedHref = entry.href.removingPercentEncoding ?? entry.href
                finalEntry.name = URL(fileURLWithPath: decodedHref).lastPathComponent
                if finalEntry.name.isEmpty {
                    finalEntry.name = decodedHref
                }
                entries.append(finalEntry)
            }
            currentEntry = nil
            inResponse = false
        case "propstat":
            inPropstat = false
        case "prop":
            inProp = false
        case "href":
            if inResponse {
                currentEntry?.href = text.removingPercentEncoding ?? text
            }
        case "getcontentlength":
            if inProp {
                currentEntry?.contentLength = Int64(text) ?? 0
            }
        case "getlastmodified":
            if inProp {
                currentEntry?.lastModified = parseHTTPDate(text)
            }
        case "getcontenttype":
            if inProp {
                currentEntry?.contentType = text
            }
        default:
            break
        }
        
        currentText = ""
    }
    
    private func parseHTTPDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        
        // Try RFC 1123 format: "Sun, 06 Nov 1994 08:49:37 GMT"
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: string) {
            return date
        }
        
        // Try ISO 8601 format
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.date(from: string)
    }
}
