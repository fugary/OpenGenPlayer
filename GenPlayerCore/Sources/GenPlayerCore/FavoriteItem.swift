import Foundation

public struct FavoriteItem: Identifiable, Codable, Hashable {
    public var id: String
    public var file: VideoFile
    public var addedDate: Date
    /// For folder quick-jump. Local favorites persist relative paths when possible.
    public var folderPath: String?

    public init(file: VideoFile, folderPath: String? = nil) {
        self.file = file
        self.addedDate = Date()
        self.folderPath = Self.normalizedFolderPath(for: file, folderPath: folderPath)
        self.id = Self.makeID(file: file, folderPath: self.folderPath)
    }

    public static func makeID(file: VideoFile, folderPath: String? = nil) -> String {
        let serverPart = file.isRemote
            ? (file.jellyfinServerId ?? file.jellyfinItemId ?? file.url.host ?? "remote")
            : "local"
        let pathPart = normalizedIdentityPath(for: file, folderPath: folderPath)
        return "\(serverPart)|\(pathPart)"
    }

    public static func normalizedFolderPath(for file: VideoFile, folderPath: String?) -> String? {
        guard let folderPath, !folderPath.isEmpty else { return nil }
        guard !file.isRemote else { return folderPath }
        return relativeLocalPath(forRawPath: folderPath) ?? folderPath
    }

    private static func normalizedIdentityPath(for file: VideoFile, folderPath: String?) -> String {
        if let normalizedFolderPath = normalizedFolderPath(for: file, folderPath: folderPath), !normalizedFolderPath.isEmpty {
            return normalizedFolderPath
        }
        if file.isRemote {
            return file.url.absoluteString
        }
        return relativeLocalPath(for: file.url) ?? file.url.path
    }

    private static func relativeLocalPath(for url: URL) -> String? {
        relativeLocalPath(forRawPath: url.standardizedFileURL.path)
    }

    private static func relativeLocalPath(forRawPath rawPath: String) -> String? {
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let documentsPath = documentsURL.standardizedFileURL.path
        let standardizedPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        guard standardizedPath.hasPrefix(documentsPath) else {
            if let range = standardizedPath.range(of: "/Documents/") {
                return String(standardizedPath[range.upperBound...])
            }
            if standardizedPath.hasSuffix("/Documents") {
                return ""
            }
            return nil
        }

        let suffix = String(standardizedPath.dropFirst(documentsPath.count))
        return suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
    }
}
