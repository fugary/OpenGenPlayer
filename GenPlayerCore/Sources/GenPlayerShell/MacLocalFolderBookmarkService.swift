#if os(macOS)
import Foundation
import AppKit
import Combine

public struct MacAuthorizedFolder: Identifiable, Codable, Equatable {
    public let id: UUID
    public var name: String
    public var path: String
    public var bookmarkData: Data?
    public var isDefault: Bool
    public var dateAdded: Date
    public var customIconName: String?

    public init(
        id: UUID = UUID(),
        name: String,
        path: String,
        bookmarkData: Data? = nil,
        isDefault: Bool = false,
        dateAdded: Date = Date(),
        customIconName: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmarkData = bookmarkData
        self.isDefault = isDefault
        self.dateAdded = dateAdded
        self.customIconName = customIconName
    }

    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    public var isExternalDrive: Bool {
        path.hasPrefix("/Volumes/") && !path.hasPrefix("/Volumes/Macintosh HD")
    }
}

public enum MacFolderAccessStatus: Equatable {
    case accessible
    case needsReauthorization
    case notFound
}

public final class MacLocalFolderBookmarkService: ObservableObject {
    public static let shared = MacLocalFolderBookmarkService()

    @Published public private(set) var authorizedFolders: [MacAuthorizedFolder] = []
    
    private let storageKey = "MacAuthorizedFolderBookmarks_v1"
    private var activeSecurityScopedURLs: [UUID: URL] = [:]
    private let lock = NSLock()

    private init() {
        loadSavedFolders()
        ensureDefaultFolders()
        activateAllAuthorizedFolders()
    }

    deinit {
        stopAllAccessing()
    }

    // MARK: - Persistence & Loading

    private func loadSavedFolders() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else {
            return
        }
        do {
            let folders = try JSONDecoder().decode([MacAuthorizedFolder].self, from: data)
            self.authorizedFolders = folders
        } catch {
            print("[MacLocalFolderBookmarkService] Failed to decode saved folders: \(error)")
        }
    }

    private func saveFolders() {
        do {
            let data = try JSONEncoder().encode(authorizedFolders)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            print("[MacLocalFolderBookmarkService] Failed to encode folders: \(error)")
        }
    }

    // MARK: - Default Folders Setup

    private func ensureDefaultFolders() {
        let fileManager = FileManager.default
        var updated = false

        // 1. Documents Folder
        if let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            if matchingFolderIndices(for: docsURL).isEmpty {
                let bookmark = createBookmarkData(for: docsURL)
                let docsFolder = MacAuthorizedFolder(
                    name: "Documents",
                    path: docsURL.path,
                    bookmarkData: bookmark,
                    isDefault: true,
                    customIconName: "doc.text.fill"
                )
                authorizedFolders.append(docsFolder)
                updated = true
            }
        }

        // 2. Downloads Folder (App Documents/Downloads or System Downloads if accessible)
        if let docsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let downloadsURL = docsURL.appendingPathComponent("Downloads", isDirectory: true)
            if !fileManager.fileExists(atPath: downloadsURL.path) {
                try? fileManager.createDirectory(at: downloadsURL, withIntermediateDirectories: true, attributes: nil)
            }
            if matchingFolderIndices(for: downloadsURL).isEmpty {
                let bookmark = createBookmarkData(for: downloadsURL)
                let dlFolder = MacAuthorizedFolder(
                    name: "Downloads",
                    path: downloadsURL.path,
                    bookmarkData: bookmark,
                    isDefault: true,
                    customIconName: "arrow.down.circle.fill"
                )
                authorizedFolders.append(dlFolder)
                updated = true
            }
        }

        // 3. User Movies Folder (Check if already present or can be referenced)
        if let moviesURL = fileManager.urls(for: .moviesDirectory, in: .userDomainMask).first {
            if matchingFolderIndices(for: moviesURL).isEmpty {
                let bookmark = createBookmarkData(for: moviesURL)
                let moviesFolder = MacAuthorizedFolder(
                    name: "Movies",
                    path: moviesURL.path,
                    bookmarkData: bookmark,
                    isDefault: true,
                    customIconName: "film.fill"
                )
                authorizedFolders.append(moviesFolder)
                updated = true
            }
        }

        if updated {
            saveFolders()
        }
    }

    // MARK: - Security Scoped Bookmarks

    public func createBookmarkData(for url: URL) -> Data? {
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            return bookmark
        } catch {
            print("[MacLocalFolderBookmarkService] Failed to create bookmark for \(url.path): \(error)")
            return nil
        }
    }

    public func resolveURL(for folder: MacAuthorizedFolder) -> URL {
        lock.lock()
        defer { lock.unlock() }

        if let active = activeSecurityScopedURLs[folder.id] {
            return active
        }

        let fallbackURL = URL(fileURLWithPath: folder.path)
        guard let bookmarkData = folder.bookmarkData else {
            return fallbackURL
        }

        var isStale = false
        do {
            let resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                if let newBookmark = createBookmarkData(for: resolvedURL) {
                    if let index = authorizedFolders.firstIndex(where: { $0.id == folder.id }) {
                        authorizedFolders[index].bookmarkData = newBookmark
                        saveFolders()
                    }
                }
            }

            if resolvedURL.startAccessingSecurityScopedResource() {
                activeSecurityScopedURLs[folder.id] = resolvedURL
            }
            return resolvedURL
        } catch {
            print("[MacLocalFolderBookmarkService] Failed resolving bookmark for \(folder.name): \(error)")
            return fallbackURL
        }
    }

    public func stopAccessing(folderId: UUID) {
        lock.lock()
        defer { lock.unlock() }

        if let active = activeSecurityScopedURLs.removeValue(forKey: folderId) {
            active.stopAccessingSecurityScopedResource()
        }
    }

    public func stopAllAccessing() {
        lock.lock()
        defer { lock.unlock() }

        for (_, url) in activeSecurityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
        activeSecurityScopedURLs.removeAll()
    }

    // MARK: - Folder Management Operations

    private func matchingFolderIndices(for url: URL) -> [Int] {
        // Sandbox standard-folder links and a URL selected in NSOpenPanel can
        // name the same directory through different paths. Never match by name.
        let selectedPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        return authorizedFolders.indices.filter { index in
            let existingURL = URL(fileURLWithPath: authorizedFolders[index].path)
            return existingURL.resolvingSymlinksInPath().standardizedFileURL.path == selectedPath
        }
    }

    private func refreshBookmarks(at indices: [Int], with bookmark: Data) {
        // Evict every old scope before publishing the updated authorization.
        // Keep each record's identity, path, display name and other metadata.
        for index in indices {
            stopAccessing(folderId: authorizedFolders[index].id)
        }
        for index in indices {
            authorizedFolders[index].bookmarkData = bookmark
        }
        saveFolders()
        for index in indices {
            _ = resolveURL(for: authorizedFolders[index])
        }
    }

    @discardableResult
    public func addFolder(url: URL, customName: String? = nil) -> MacAuthorizedFolder? {
        let path = url.path
        // Create from the original selected URL, which carries the new grant.
        // Failure must not discard a usable old bookmark or claim authorization.
        guard let bookmark = createBookmarkData(for: url) else { return nil }
        let matchingIndices = matchingFolderIndices(for: url)
        if let existingIndex = matchingIndices.first(where: { authorizedFolders[$0].path == path }) ?? matchingIndices.first {
            refreshBookmarks(at: matchingIndices, with: bookmark)
            return authorizedFolders[existingIndex]
        }

        let name = customName ?? (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent)
        
        var iconName = "folder.fill"
        if url.path.contains("/Movies") {
            iconName = "film.fill"
        } else if url.path.contains("/Downloads") {
            iconName = "arrow.down.circle.fill"
        } else if url.path.contains("/Music") {
            iconName = "music.note.list"
        } else if url.path.hasPrefix("/Volumes/") {
            iconName = "externaldrive.fill"
        }

        let folder = MacAuthorizedFolder(
            name: name,
            path: path,
            bookmarkData: bookmark,
            isDefault: false,
            customIconName: iconName
        )

        authorizedFolders.append(folder)
        saveFolders()
        _ = resolveURL(for: folder)
        return authorizedFolders[authorizedFolders.count - 1]
    }

    public func removeFolder(_ folder: MacAuthorizedFolder) {
        stopAccessing(folderId: folder.id)
        authorizedFolders.removeAll(where: { $0.id == folder.id })
        saveFolders()
    }

    public func renameFolder(_ folder: MacAuthorizedFolder, newName: String) {
        guard let index = authorizedFolders.firstIndex(where: { $0.id == folder.id }) else { return }
        authorizedFolders[index].name = newName
        saveFolders()
    }

    public func activateAllAuthorizedFolders() {
        for folder in authorizedFolders {
            _ = resolveURL(for: folder)
        }
    }

    @discardableResult
    public func ensureAccess(for url: URL) -> Bool {
        guard let matchingAuth = findMatchingAuthorizedFolder(for: url) else {
            return false
        }
        let resolved = resolveURL(for: matchingAuth)
        return isDirectoryAccessible(resolved)
    }

    public func checkAccessStatus(for folder: MacAuthorizedFolder) -> MacFolderAccessStatus {
        let fileManager = FileManager.default
        let resolvedURL = resolveURL(for: folder)
        
        var isDir: ObjCBool = false
        if !fileManager.fileExists(atPath: resolvedURL.path, isDirectory: &isDir) || !isDir.boolValue {
            if !fileManager.fileExists(atPath: folder.path, isDirectory: &isDir) || !isDir.boolValue {
                return .notFound
            }
        }
        
        do {
            _ = try fileManager.contentsOfDirectory(at: resolvedURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            return .accessible
        } catch {
            return .needsReauthorization
        }
    }

    private func isDirectoryAccessible(_ url: URL) -> Bool {
        do {
            _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            return true
        } catch {
            return false
        }
    }

    public func promptReauthorizeFolder(_ folder: MacAuthorizedFolder, onSuccess: ((URL) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = platformShellString("Re-authorize")
        panel.title = String(format: platformShellString("Re-authorize \"%@\""), folder.name)
        panel.message = platformShellString("Select the folder to re-authorize access in GenPlayer.")
        
        let existingURL = URL(fileURLWithPath: folder.path)
        if FileManager.default.fileExists(atPath: existingURL.path) {
            panel.directoryURL = existingURL
        }

        if panel.runModal() == .OK, let selectedURL = panel.url {
            guard let index = authorizedFolders.firstIndex(where: { $0.id == folder.id }),
                  let newBookmark = createBookmarkData(for: selectedURL) else { return }
            var matchingIndices = matchingFolderIndices(for: selectedURL)
            if !matchingIndices.contains(index) {
                // Preserve the existing ability to reassign a moved folder.
                // An equivalent selected path needs only a new bookmark.
                stopAccessing(folderId: folder.id)
                authorizedFolders[index].path = selectedURL.path
                matchingIndices.append(index)
            }
            refreshBookmarks(at: matchingIndices, with: newBookmark)
            onSuccess?(selectedURL)
        }
    }

    public func promptAddFolders(onSuccess: (([MacAuthorizedFolder]) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = true
        panel.prompt = platformShellString("Select Folder")
        panel.title = platformShellString("Add Local Folder")

        if panel.runModal() == .OK {
            var addedList: [MacAuthorizedFolder] = []
            for url in panel.urls {
                if let added = addFolder(url: url) {
                    addedList.append(added)
                }
            }
            onSuccess?(addedList)
        }
    }

    public func findMatchingAuthorizedFolder(for fileURL: URL) -> MacAuthorizedFolder? {
        let filePath = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        func matchingDistance(to directoryURL: URL) -> Int? {
            let directoryPaths = [directoryURL.path, directoryURL.resolvingSymlinksInPath().standardizedFileURL.path]
            return directoryPaths.compactMap { directoryPath -> Int? in
                [fileURL.path, filePath].compactMap { path -> Int? in
                    if path == directoryPath { return 0 }
                    let prefix = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
                    guard path.hasPrefix(prefix) else { return nil }
                    return path.dropFirst(prefix.count).split(separator: "/").count
                }
                .min()
            }.min()
        }

        var closestFolder: MacAuthorizedFolder?
        var closestDistance = Int.max
        for folder in authorizedFolders {
            // Callers may use the stored sandbox link or the bookmark's resolved URL.
            // Retain lexical matching too: missing children may not resolve symlinks.
            let storedDistance = matchingDistance(to: URL(fileURLWithPath: folder.path))
            let resolvedDistance = storedDistance == 0 ? nil : matchingDistance(to: resolveURL(for: folder))
            guard let distance = [storedDistance, resolvedDistance].compactMap({ $0 }).min() else { continue }

            // Compare relative depth, not path length: a sandbox alias can be
            // much longer than an explicitly authorized child directory's path.
            if distance < closestDistance {
                closestFolder = folder
                closestDistance = distance
                if distance == 0 { break }
            }
        }
        return closestFolder
    }
}
#endif
