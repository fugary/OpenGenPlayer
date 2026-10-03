#if os(macOS)
import AppKit
typealias UIImage = NSImage
extension NSImage {
    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        return bitmapRep.representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }
}
#else
import UIKit
#endif
import CryptoKit

class ImageCacheManager {
    static let shared = ImageCacheManager()
    
    private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    private init() {
        // Set memory cache limits (e.g. 50MB)
        memoryCache.totalCostLimit = 1024 * 1024 * 50
        
        // Setup disk cache directory
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("GenPlayerImageCache")
        
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    // MARK: - Core Functions
    
    func getImage(for url: URL) -> UIImage? {
        let primaryKey = canonicalCacheKey(for: url)
        if let image = getImage(forKey: primaryKey) {
            return image
        }

        for legacyKey in legacyCacheKeys(for: url) where legacyKey != primaryKey {
            if let image = getImage(forKey: legacyKey) {
                // Migrate older URL-based cache entries to the new stable key on read.
                saveImage(image, forKey: primaryKey)
                return image
            }
        }

        return nil
    }

    func getImage(forKey key: String) -> UIImage? {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            return nil
        }
        
        // 1. Check memory cache
        if let image = memoryCache.object(forKey: normalizedKey as NSString) {
            return image
        }
        
        // 2. Check disk cache
        let fileURL = getCacheFileURL(forKey: normalizedKey)
        if let data = try? Data(contentsOf: fileURL), var image = UIImage(data: data) {
            let lowerKey = normalizedKey.lowercased()
            let isLogoOrArt = lowerKey.contains("logo") || lowerKey.contains("art")
            if isLogoOrArt && !imageHasAlpha(image) {
                // Remove legacy cached JPEG logo that lacks alpha transparency so it re-downloads fresh PNG
                try? fileManager.removeItem(at: fileURL)
                return nil
            }
            // Store back to memory cache for faster subsequent access
            let cost = Int(image.size.width * image.size.height * 4) // approximation
            memoryCache.setObject(image, forKey: normalizedKey as NSString, cost: cost)
            return image
        }
        
        return nil
    }
    
    func saveImage(_ image: UIImage, for url: URL) {
        saveImage(image, forKey: canonicalCacheKey(for: url))
    }

    func saveImage(_ image: UIImage, forKey key: String) {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else {
            return
        }
        let lowerKey = normalizedKey.lowercased()
        let isLogoOrArt = lowerKey.contains("logo") || lowerKey.contains("art")
        let finalImage = isLogoOrArt ? image.removingWhiteBackground() : image

        let cost = Int(finalImage.size.width * finalImage.size.height * 4)
        
        // 1. Save to memory cache
        memoryCache.setObject(finalImage, forKey: normalizedKey as NSString, cost: cost)
        
        // 2. Save to disk cache asynchronously
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            let fileURL = self.getCacheFileURL(forKey: normalizedKey)
            let isTransparent = isLogoOrArt || self.imageHasAlpha(finalImage)
            let data = isTransparent ? (finalImage.pngData() ?? finalImage.jpegData(compressionQuality: 0.8)) : (finalImage.jpegData(compressionQuality: 0.8) ?? finalImage.pngData())
            if let data {
                try? data.write(to: fileURL)
            }
        }
    }

    private func imageHasAlpha(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let alphaInfo = cgImage.alphaInfo
        return alphaInfo == .first || alphaInfo == .last || alphaInfo == .premultipliedFirst || alphaInfo == .premultipliedLast
    }
    
    // MARK: - Cache Management
    
    func clearCache() {
        memoryCache.removeAllObjects()
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let fileURLs = try self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                for fileURL in fileURLs {
                    try self.fileManager.removeItem(at: fileURL)
                }
            } catch {
                print("Error clearing disk cache: \(error)")
            }
        }
    }
    
    func calculateCacheSize(completion: @escaping (Int64) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(0)
                return
            }
            var totalSize: Int64 = 0
            do {
                let fileURLs = try self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)
                for fileURL in fileURLs {
                    if let resources = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                       let fileSize = resources.fileSize {
                        totalSize += Int64(fileSize)
                    }
                }
            } catch {
                print("Error calculating cache size: \(error)")
            }
            
            DispatchQueue.main.async {
                completion(totalSize)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func getCacheFileURL(for url: URL) -> URL {
        getCacheFileURL(forKey: canonicalCacheKey(for: url))
    }

    private func getCacheFileURL(forKey key: String) -> URL {
        let hashedName = md5(key)
        return cacheDirectory.appendingPathComponent(hashedName)
    }
    
    private func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func canonicalCacheKey(for url: URL) -> String {
        if let embeddedKey = MediaImageCacheIdentity.cacheKey(from: url) {
            return embeddedKey
        }

        return url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func legacyCacheKeys(for url: URL) -> [String] {
        var keys: [String] = []
        let rawKey = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawKey.isEmpty {
            keys.append(rawKey)
        }

        if var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           components.fragment != nil {
            components.fragment = nil
            if let withoutFragment = components.url?.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines),
               !withoutFragment.isEmpty {
                keys.append(withoutFragment)
            }
        }

        var seen = Set<String>()
        return keys.filter { seen.insert($0).inserted }
    }
}

enum MediaImageCacheIdentity {
    private static let fragmentPrefix = "genplayer-image-cache:"

    static func mediaServerImage(
        server: ServerConfig,
        itemId: String,
        imageType: String,
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        quality: Int? = nil,
        versionTag: String? = nil
    ) -> String {
        let normalizedItemId = normalizedComponent(itemId)
        let normalizedImageType = normalizedComponent(imageType)
        let widthComponent = maxWidth.map { "w\($0)" } ?? "w_"
        let heightComponent = maxHeight.map { "h\($0)" } ?? "h_"
        let qualityComponent = quality.map { "q\($0)" } ?? "q_"
        let versionComponent = normalizedOptionalComponent(versionTag)
        return "\(server.type.rawValue)|\(server.id.uuidString.lowercased())|item|\(normalizedItemId)|\(normalizedImageType)|\(widthComponent)|\(heightComponent)|\(qualityComponent)|v\(versionComponent)"
    }

    static func plexImage(server: ServerConfig, imagePath: String, versionTag: String? = nil) -> String {
        let normalizedPath = normalizedPathIdentity(imagePath)
        let versionComponent = normalizedOptionalComponent(versionTag)
        return "\(server.type.rawValue)|\(server.id.uuidString.lowercased())|image|\(normalizedPath)|v\(versionComponent)"
    }

    static func apply(cacheKey: String, to url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }

        components.fragment = fragmentPrefix + cacheKey
        return components.url ?? url
    }

    static func cacheKey(from url: URL) -> String? {
        guard let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
              fragment.hasPrefix(fragmentPrefix) else {
            return nil
        }

        let value = String(fragment.dropFirst(fragmentPrefix.count))
        return value.isEmpty ? nil : value
    }

    static func requestURL(from url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let fragment = components.fragment,
              fragment.hasPrefix(fragmentPrefix) else {
            return url
        }

        components.fragment = nil
        return components.url ?? url
    }

    private static func normalizedComponent(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "_" : trimmed.lowercased()
    }

    private static func normalizedOptionalComponent(_ rawValue: String?) -> String {
        guard let rawValue else { return "_" }
        return normalizedComponent(rawValue)
    }

    private static func normalizedPathIdentity(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        if var components = URLComponents(string: trimmed), components.scheme != nil {
            components.fragment = nil
            if let queryItems = components.queryItems, !queryItems.isEmpty {
                components.queryItems = queryItems.filter { item in
                    let name = item.name.lowercased()
                    return name != "x-plex-token" && name != "api_key"
                }
            }

            let scheme = components.scheme?.lowercased() ?? "https"
            let host = components.host?.lowercased() ?? "unknown"
            let path = normalizedPath(components.percentEncodedPath)
            if let query = components.percentEncodedQuery, !query.isEmpty {
                return "\(scheme)://\(host)\(path)?\(query)"
            }
            return "\(scheme)://\(host)\(path)"
        }

        return normalizedPath(trimmed)
    }

    private static func normalizedPath(_ rawPath: String) -> String {
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        var normalized = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        normalized = normalized.replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

enum ArtworkCacheKey {
    static func remoteAudioArtwork(
        serverType: ServerConfig.ServerType?,
        serverId: String?,
        serverPath: String?,
        fallbackURL: URL
    ) -> String? {
        let resolvedServerType = serverType ?? inferredServerType(from: fallbackURL)
        guard let resolvedServerType, supportsRemoteAudioArtworkCache(type: resolvedServerType) else {
            return nil
        }

        let identity = normalizedServerIdentity(serverId: serverId, fallbackURL: fallbackURL)
        let normalizedPath = normalizedRemotePath(serverPath ?? fallbackURL.path)
        return "remote-audio-artwork|\(resolvedServerType.rawValue)|\(identity)|\(normalizedPath)"
    }

    private static func supportsRemoteAudioArtworkCache(type: ServerConfig.ServerType) -> Bool {
        switch type {
        case .smb, .webdav, .ftp, .sftp, .nfs:
            return true
        default:
            return false
        }
    }

    private static func inferredServerType(from url: URL) -> ServerConfig.ServerType? {
        guard let scheme = url.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "smb":
            return .smb
        case "ftp":
            return .ftp
        case "sftp":
            return .sftp
        case "nfs":
            return .nfs
        case "http", "https":
            return .webdav
        default:
            return nil
        }
    }

    private static func normalizedServerIdentity(serverId: String?, fallbackURL: URL) -> String {
        if let serverId = serverId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serverId.isEmpty {
            return "id:\(serverId.lowercased())"
        }

        if let host = fallbackURL.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !host.isEmpty {
            return "host:\(host)"
        }

        return "host:unknown"
    }

    private static func normalizedRemotePath(_ rawPath: String) -> String {
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        var normalized = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        normalized = normalized.replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

enum RemotePreviewCacheKey {
    static func filePreview(
        serverType: ServerConfig.ServerType?,
        serverId: String?,
        serverPath: String?,
        fileType: VideoFile.FileType,
        fallbackURL: URL
    ) -> String? {
        guard supportsFilePreviewCache(for: fileType) else {
            return nil
        }

        let resolvedServerType = serverType ?? inferredServerType(from: fallbackURL)
        guard let resolvedServerType, supportsRemoteFilePreviewCache(type: resolvedServerType) else {
            return nil
        }

        let identity = normalizedServerIdentity(serverId: serverId, fallbackURL: fallbackURL)
        let normalizedPath = normalizedRemotePath(serverPath ?? fallbackURL.path)
        return "remote-file-preview|\(resolvedServerType.rawValue)|\(identity)|\(fileType.rawValue)|\(normalizedPath)"
    }

    private static func supportsFilePreviewCache(for fileType: VideoFile.FileType) -> Bool {
        fileType == .video || fileType == .image
    }

    private static func supportsRemoteFilePreviewCache(type: ServerConfig.ServerType) -> Bool {
        switch type {
        case .smb, .webdav, .ftp, .sftp, .nfs:
            return true
        default:
            return false
        }
    }

    private static func inferredServerType(from url: URL) -> ServerConfig.ServerType? {
        guard let scheme = url.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "smb":
            return .smb
        case "ftp":
            return .ftp
        case "sftp":
            return .sftp
        case "nfs":
            return .nfs
        case "http", "https":
            return .webdav
        default:
            return nil
        }
    }

    private static func normalizedServerIdentity(serverId: String?, fallbackURL: URL) -> String {
        if let serverId = serverId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serverId.isEmpty {
            return "id:\(serverId.lowercased())"
        }

        if let host = fallbackURL.host?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !host.isEmpty {
            return "host:\(host)"
        }

        return "host:unknown"
    }

    private static func normalizedRemotePath(_ rawPath: String) -> String {
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        var normalized = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        normalized = normalized.replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}

final class RemoteFileCacheService {
    static let shared = RemoteFileCacheService()

    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    private init() {
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("GenPlayer/RemoteFileCache", isDirectory: true)
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }

    func cachedFileURL(server: ServerConfig, remotePath: String, fileName: String) -> URL? {
        let destinationURL = cacheFileURL(server: server, remotePath: remotePath, fileName: fileName)
        guard fileManager.fileExists(atPath: destinationURL.path) else {
            return nil
        }
        touchFile(at: destinationURL)
        return destinationURL
    }

    func fetchFile(
        server: ServerConfig,
        remotePath: String,
        fileName: String,
        progress: ((Int64, Int64) -> Void)? = nil
    ) async throws -> URL {
        if let cached = cachedFileURL(server: server, remotePath: remotePath, fileName: fileName) {
            return cached
        }

        let tempURL = try await AppNetworkService.shared.downloadFile(server: server, at: remotePath, progress: progress)
        let destinationURL = cacheFileURL(server: server, remotePath: remotePath, fileName: fileName)

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }

        do {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } catch {
            try fileManager.copyItem(at: tempURL, to: destinationURL)
            try? fileManager.removeItem(at: tempURL)
        }

        touchFile(at: destinationURL)
        return destinationURL
    }

    func clearCache() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                if self.fileManager.fileExists(atPath: self.cacheDirectory.path) {
                    try self.fileManager.removeItem(at: self.cacheDirectory)
                }
                try self.fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("Error clearing remote file cache: \(error)")
            }
        }
    }

    func calculateCacheSize(completion: @escaping (Int64) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                completion(0)
                return
            }

            var totalSize: Int64 = 0
            if let enumerator = self.fileManager.enumerator(
                at: self.cacheDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          values.isRegularFile == true,
                          let fileSize = values.fileSize else {
                        continue
                    }
                    totalSize += Int64(fileSize)
                }
            }

            DispatchQueue.main.async {
                completion(totalSize)
            }
        }
    }

    private func cacheFileURL(server: ServerConfig, remotePath: String, fileName: String) -> URL {
        let serverDirectory = cacheDirectory.appendingPathComponent(server.remoteFileCacheFingerprint, isDirectory: true)
        let sanitizedName = sanitizeFileName(fileName)
        let sourceURL = URL(fileURLWithPath: sanitizedName)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension
        let pathHash = shortHash("\(server.remoteFileCacheFingerprint)|\(normalizedRemotePath(remotePath))")
        let outputName = ext.isEmpty
            ? "\(baseName)__\(pathHash)"
            : "\(baseName)__\(pathHash).\(ext)"
        return serverDirectory.appendingPathComponent(outputName)
    }

    private func touchFile(at url: URL) {
        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func sanitizeFileName(_ rawValue: String) -> String {
        rawValue
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func normalizedRemotePath(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        if let absoluteURL = URL(string: trimmed), absoluteURL.scheme != nil {
            var normalized = absoluteURL.path.removingPercentEncoding ?? absoluteURL.path
            if let query = absoluteURL.query, !query.isEmpty {
                normalized += "?\(query)"
            }
            return normalized
        }

        let decoded = trimmed.removingPercentEncoding ?? trimmed
        var normalized = decoded.hasPrefix("/") ? decoded : "/\(decoded)"
        normalized = normalized.replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func shortHash(_ value: String, length: Int = 10) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(length))
    }
}

private extension ServerConfig {
    var remoteFileCacheFingerprint: String {
        let normalizedEndpoint: String
        switch type {
        case .smb:
            normalizedEndpoint = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case .webdav, .ftp, .sftp, .nfs, .jellyfin, .emby, .plex, .alist, .pan115, .onedrive, .googledrive, .iptv, .vod:
            normalizedEndpoint = fullURL.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }

        let normalizedAccount = (userId ?? username ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedWorkgroup = (workgroup ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let raw = [
            type.rawValue,
            normalizedEndpoint,
            normalizedAccount,
            normalizedWorkgroup
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

extension UIImage {
    func removingWhiteBackground(minThreshold: CGFloat = 240) -> UIImage {
        guard let cgImage = self.cgImage else { return self }
        let masking: [CGFloat] = [minThreshold, 255, minThreshold, 255, minThreshold, 255]
        guard let maskedCGImage = cgImage.copy(maskingColorComponents: masking) else {
            return self
        }
        return UIImage(cgImage: maskedCGImage, scale: self.scale, orientation: self.imageOrientation)
    }
}
