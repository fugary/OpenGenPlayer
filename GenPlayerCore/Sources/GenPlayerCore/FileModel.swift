import Foundation
public struct VideoFile: Identifiable, Codable {
    // Use URL path as stable identifier to preserve navigation state across refreshes
    public var id: String { url.path }
    
    public let name: String
    public var url: URL
    public let type: FileType
    public let size: Int64
    public var date: Date
    public var isRemote: Bool = false
    public var itemCount: Int? = nil // Number of items in a folder
    
    // Server Info
    public var serverType: ServerConfig.ServerType?
    public var customArtworkURL: URL?
    public var isLiveStream: Bool { serverType == .iptv }
    
    // Jellyfin specific sync info
    public var jellyfinItemId: String?
    public var jellyfinServerId: String?
    public var seriesId: String?
    public var seasonId: String?
    
    // Playback state
    public var duration: TimeInterval?
    public var lastPlayedPosition: TimeInterval?
    public var videoAspectRatioHint: Double?
    public var lastAudioTrack: Int?
    public var lastSubtitleTrack: Int?

    // Transient pre-play preferences (not persisted)
    public var preferredAudioTrackQuery: String?
    public var preferredSubtitleTrackQuery: String?
    public var preferredAudioTrackOrdinal: Int?
    public var preferredSubtitleTrackOrdinal: Int?
    public var preferredPlaybackQualityID: String?
    public var availablePlaybackQualityOptions: [RemotePlaybackQualityOption] = []
    public var disableSubtitlesOnStart: Bool = false
    
    // Transient server metadata (NOT Codable; only set in memory for MediaInfo display)
    public var serverMediaStreams: [[String: Any]]?
    public var serverContainer: String?
    public var serverSize: Int64?
    public var serverBitrate: Int?
    public var serverPath: String?
    public var mediaSourceId: String?
    public var remotePlaybackMethod: RemotePlaybackMethod?
    public var shouldResetRemotePlayedStateOnPlaybackStart: Bool = false
    public var externalSubtitleCandidates: [ExternalSubtitleCandidate] = []
    
public enum FileType: String, Codable {
        case video
        case audio
        case subtitle
        case image
        case folder
        case document
        case unknown
        
        public static let videoExtensions = ["mp4", "mov", "mkv", "avi", "wmv", "flv", "webm", "m4v", "ts", "mpg", "mpeg", "m2ts", "3gp", "rmvb"]
        public static let audioExtensions = ["mp3", "wav", "m4a", "aac", "flac", "ogg", "wma"]
        public static let subtitleExtensions = ["srt", "ass", "ssa", "vtt", "sub"]
        public static let imageExtensions = ["jpg", "jpeg", "png", "gif", "heic", "bmp", "tiff"]
        static let textDocumentExtensions = [
            "txt", "log", "md", "json", "xml", "csv", "tsv",
            "yaml", "yml", "ini", "cfg", "conf",
            "plist", "strings", "nfo", "cue", "lrc"
        ]
        static let documentExtensions = [
            "pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx",
            "rtf", "pages", "numbers", "key"
        ] + textDocumentExtensions
        static let textPreviewExtensions = subtitleExtensions + textDocumentExtensions
        
        public static var allSupportedExtensions: [String] {
            videoExtensions + audioExtensions
        }

        public static func supportsTextPreview(for url: URL) -> Bool {
            textPreviewExtensions.contains(url.pathExtension.lowercased())
        }
        
        public static func determineType(from url: URL) -> FileType {
            let ext = url.pathExtension.lowercased()
            if videoExtensions.contains(ext) { return .video }
            if audioExtensions.contains(ext) { return .audio }
            if subtitleExtensions.contains(ext) { return .subtitle }
            if imageExtensions.contains(ext) { return .image }
            if documentExtensions.contains(ext) { return .document }
            return .unknown
        }
    }

    public var supportsTextPreview: Bool {
        FileType.supportsTextPreview(for: url)
    }

    // Explicit CodingKeys
public enum CodingKeys: String, CodingKey {
        case name, url, type, size, date, isRemote, duration, lastPlayedPosition, videoAspectRatioHint, lastAudioTrack, lastSubtitleTrack
        case jellyfinItemId, jellyfinServerId, serverType, customArtworkURL, itemCount, seriesId, seasonId, externalSubtitleCandidates
    }
    
    // Custom encoding to handle relative paths for local files
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(type, forKey: .type)
        try container.encode(size, forKey: .size)
        try container.encode(date, forKey: .date)
        try container.encode(isRemote, forKey: .isRemote)
        try container.encodeIfPresent(itemCount, forKey: .itemCount)
        try container.encode(externalSubtitleCandidates, forKey: .externalSubtitleCandidates)
        try container.encodeIfPresent(duration, forKey: .duration)
        try container.encodeIfPresent(lastPlayedPosition, forKey: .lastPlayedPosition)
        try container.encodeIfPresent(videoAspectRatioHint, forKey: .videoAspectRatioHint)
        try container.encodeIfPresent(lastAudioTrack, forKey: .lastAudioTrack)
        try container.encodeIfPresent(lastSubtitleTrack, forKey: .lastSubtitleTrack)
        try container.encodeIfPresent(serverType, forKey: .serverType)
        try container.encodeIfPresent(customArtworkURL, forKey: .customArtworkURL)
        try container.encodeIfPresent(jellyfinItemId, forKey: .jellyfinItemId)
        try container.encodeIfPresent(jellyfinServerId, forKey: .jellyfinServerId)
        try container.encodeIfPresent(seriesId, forKey: .seriesId)
        try container.encodeIfPresent(seasonId, forKey: .seasonId)
        
        if isRemote {
            try container.encode(url, forKey: .url)
        } else {
            // Attempt to make path relative to Documents directory
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            // Check if file is inside documents
            if url.path.hasPrefix(documentsURL.path) {
                // Get relative path string
                let docPath = documentsURL.path
                let fullPath = url.path
                if let range = fullPath.range(of: docPath) {
                    let relativePath = String(fullPath[range.upperBound...])
                    // Ensure it doesn't start with slash for cleaner relative path handling, or keep as is?
                    // Typically removing leading slash is safer for appending
                    let cleanRelative = relativePath.hasPrefix("/") ? String(relativePath.dropFirst()) : relativePath
                    try container.encode(cleanRelative, forKey: .url)
                    return
                }
            }
            // Fallback to absolute if not in documents
            try container.encode(url, forKey: .url)
        }
    }
    
    // Custom decoding to restore absolute paths
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        type = try container.decode(FileType.self, forKey: .type)
        size = try container.decode(Int64.self, forKey: .size)
        date = try container.decode(Date.self, forKey: .date)
        isRemote = try container.decodeIfPresent(Bool.self, forKey: .isRemote) ?? false
        itemCount = try container.decodeIfPresent(Int.self, forKey: .itemCount)
        duration = try container.decodeIfPresent(TimeInterval.self, forKey: .duration)
        lastPlayedPosition = try container.decodeIfPresent(TimeInterval.self, forKey: .lastPlayedPosition)
        videoAspectRatioHint = try container.decodeIfPresent(Double.self, forKey: .videoAspectRatioHint)
        lastAudioTrack = try container.decodeIfPresent(Int.self, forKey: .lastAudioTrack)
        lastSubtitleTrack = try container.decodeIfPresent(Int.self, forKey: .lastSubtitleTrack)
        serverType = try container.decodeIfPresent(ServerConfig.ServerType.self, forKey: .serverType)
        customArtworkURL = try container.decodeIfPresent(URL.self, forKey: .customArtworkURL)
        jellyfinItemId = try container.decodeIfPresent(String.self, forKey: .jellyfinItemId)
        jellyfinServerId = try container.decodeIfPresent(String.self, forKey: .jellyfinServerId)
        seriesId = try container.decodeIfPresent(String.self, forKey: .seriesId)
        seasonId = try container.decodeIfPresent(String.self, forKey: .seasonId)
        externalSubtitleCandidates = try container.decodeIfPresent([ExternalSubtitleCandidate].self, forKey: .externalSubtitleCandidates) ?? []
        
        // Handle URL
        if let urlWithError = try? container.decode(URL.self, forKey: .url) {
             // Standard URL decoding succeeded (likely absolute string or full URL)
             // Check if it looks effectively relative (file scheme but valid?)
             // Actually, if we encoded a string "Movies/foo.mp4", decoding as URL might create a relative URL (no scheme)
             
             if isRemote {
                 self.url = urlWithError
             } else {
                if urlWithError.scheme == nil {
                    // It's a relative path
                    let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                     self.url = documentsURL.appendingPathComponent(urlWithError.path)
                } else {
                     // It's absolute (e.g. from older version of app or outside docs)
                     self.url = Self.rebasedLocalURLIfNeeded(urlWithError)
                }
             }
        } else {
            // Fallback for string decoding if URL decode fails (rare but possible with some Encoders)
            let pathString = try container.decode(String.self, forKey: .url)
            if isRemote {
                self.url = URL(string: pathString) ?? URL(fileURLWithPath: pathString)
            } else {
                let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
                if pathString.hasPrefix("/") || pathString.contains("://") {
                     self.url = Self.rebasedLocalURLIfNeeded(URL(fileURLWithPath: pathString))
                } else {
                     self.url = documentsURL.appendingPathComponent(pathString)
                }
            }
        }
    }
    
    // Default initializer needs to be explicitly maintained
    public init(name: String, url: URL, type: FileType, size: Int64, date: Date, isRemote: Bool = false, duration: TimeInterval? = nil, lastPlayedPosition: TimeInterval? = nil, videoAspectRatioHint: Double? = nil, lastAudioTrack: Int? = nil, lastSubtitleTrack: Int? = nil, jellyfinItemId: String? = nil, jellyfinServerId: String? = nil, serverType: ServerConfig.ServerType? = nil, customArtworkURL: URL? = nil, itemCount: Int? = nil, seriesId: String? = nil, seasonId: String? = nil, preferredAudioTrackQuery: String? = nil, preferredSubtitleTrackQuery: String? = nil, disableSubtitlesOnStart: Bool = false, shouldResetRemotePlayedStateOnPlaybackStart: Bool = false, externalSubtitleCandidates: [ExternalSubtitleCandidate] = []) {
        self.name = name
        self.url = url
        self.type = type
        self.size = size
        self.date = date
        self.isRemote = isRemote
        self.duration = duration
        self.lastPlayedPosition = lastPlayedPosition
        self.videoAspectRatioHint = videoAspectRatioHint
        self.lastAudioTrack = lastAudioTrack
        self.lastSubtitleTrack = lastSubtitleTrack
        self.jellyfinItemId = jellyfinItemId
        self.jellyfinServerId = jellyfinServerId
        self.serverType = serverType
        self.customArtworkURL = customArtworkURL
        self.itemCount = itemCount
        self.seriesId = seriesId
        self.seasonId = seasonId
        self.preferredAudioTrackQuery = preferredAudioTrackQuery
        self.preferredSubtitleTrackQuery = preferredSubtitleTrackQuery
        self.preferredAudioTrackOrdinal = nil
        self.preferredSubtitleTrackOrdinal = nil
        self.preferredPlaybackQualityID = nil
        self.disableSubtitlesOnStart = disableSubtitlesOnStart
        self.shouldResetRemotePlayedStateOnPlaybackStart = shouldResetRemotePlayedStateOnPlaybackStart
        self.externalSubtitleCandidates = externalSubtitleCandidates
    }
    

    private static func rebasedLocalURLIfNeeded(_ originalURL: URL) -> URL {
        let standardizedURL = originalURL.standardizedFileURL
        if FileManager.default.fileExists(atPath: standardizedURL.path) {
            return standardizedURL
        }

        guard let relativePath = relativeDocumentsPath(from: standardizedURL.path),
              let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return standardizedURL
        }

        return relativePath.isEmpty
            ? documentsURL
            : documentsURL.appendingPathComponent(relativePath)
    }

    private static func relativeDocumentsPath(from rawPath: String) -> String? {
        let standardizedPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        if let range = standardizedPath.range(of: "/Documents/") {
            return String(standardizedPath[range.upperBound...])
        }
        if standardizedPath.hasSuffix("/Documents") {
            return ""
        }
        return nil
    }
    

    public var remoteDownloadPath: String {
        if let serverPath = serverPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serverPath.isEmpty {
            return serverPath
        }

        let urlPath = url.path.trimmingCharacters(in: .whitespacesAndNewlines)
        if !urlPath.isEmpty {
            return urlPath
        }

        return name
    }

    public var remoteFolderPath: String {
        let path = (remoteDownloadPath as NSString).deletingLastPathComponent
        return path.isEmpty ? "/" : path
    }


}

// Custom Hashable/Equatable; skips transient server metadata fields
extension VideoFile: Hashable {
    public static func == (lhs: VideoFile, rhs: VideoFile) -> Bool {
        return lhs.url == rhs.url && lhs.name == rhs.name
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(url)
        hasher.combine(name)
    }
}

private func inferredServerTypeFromScheme(_ scheme: String?) -> ServerConfig.ServerType? {
    guard let scheme = scheme?.lowercased() else { return nil }
    switch scheme {
    case "smb": return .smb
    case "ftp": return .ftp
    case "sftp": return .sftp
    case "nfs": return .nfs
    default: return nil
    }
}

private enum ServerHostResolver {
    private static let lock = NSLock()
    private static var dnsCache: [String: String] = [:]
    
    static func candidates(for address: String) -> Set<String> {
        let normalized = normalizedHost(from: address)
        guard !normalized.isEmpty else { return [] }
        
        var result: Set<String> = [normalized]
        if !isIPAddress(normalized), let resolved = resolveHostname(normalized) {
            result.insert(resolved)
        }
        return result
    }
    
    private static func normalizedHost(from address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }
        
        if let host = URL(string: trimmed)?.host?.lowercased() {
            return host
        }
        
        if let host = URLComponents(string: "http://\(trimmed)")?.host?.lowercased() {
            return host
        }
        
        return trimmed
    }
    
    private static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") { return true } // IPv6
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
        
        var addr = info
        while true {
            if addr.pointee.ai_family == AF_INET {
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var socketAddress = addr.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                inet_ntop(AF_INET, &socketAddress.sin_addr, &buffer, socklen_t(INET_ADDRSTRLEN))
                return String(cString: buffer).lowercased()
            }
            guard let next = addr.pointee.ai_next else { break }
            addr = next
        }
        
        if info.pointee.ai_family == AF_INET6 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            var socketAddress = info.pointee.ai_addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            inet_ntop(AF_INET6, &socketAddress.sin6_addr, &buffer, socklen_t(INET6_ADDRSTRLEN))
            return String(cString: buffer).lowercased()
        }
        
        return nil
    }
}

extension VideoFile {
    public var resolvedServer: ServerConfig? {
        if let serverId = jellyfinServerId, let uuid = UUID(uuidString: serverId) {
            return AppNetworkService.shared.servers.first(where: { $0.id == uuid })
        }
        if let host = url.host {
            return AppNetworkService.shared.servers.first(where: {
                if let serverHost = URLComponents(string: $0.fullURL)?.host {
                    return serverHost.caseInsensitiveCompare(host) == .orderedSame
                }
                return $0.address.caseInsensitiveCompare(host) == .orderedSame
            })
        }
        return nil
    }
}

