import Foundation
import Combine

public class FavoriteService: ObservableObject {
    public static let shared = FavoriteService()

    @Published public private(set) var favorites: [FavoriteItem] = []

    private let favoritesKey = "favorites_items"

    private init() {
        loadFavorites()
    }

    public func refresh() {
        loadFavorites()
    }

    public func isFavorite(file: VideoFile, folderPath: String? = nil) -> Bool {
        let candidate = FavoriteItem(file: file, folderPath: folderPath)
        return favorites.contains(where: { $0.id == candidate.id })
    }

    public func toggleFavorite(file: VideoFile, folderPath: String? = nil) {
        let item = FavoriteItem(file: file, folderPath: folderPath)
        if let index = favorites.firstIndex(where: { $0.id == item.id }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(item, at: 0)
        }
        favorites.sort { $0.addedDate > $1.addedDate }
        saveFavorites()
    }

    public func remove(_ item: FavoriteItem) {
        favorites.removeAll(where: { $0.id == item.id })
        saveFavorites()
    }

    public func remove(file: VideoFile) {
        favorites.removeAll(where: {
            $0.file.id == file.id ||
            $0.file.url == file.url ||
            (file.jellyfinItemId != nil && $0.file.jellyfinItemId == file.jellyfinItemId)
        })
        saveFavorites()
    }

    public func clearFavorites(for server: ServerConfig) {
        favorites.removeAll { item in
            belongsToServer(item.file, server: server)
        }
        saveFavorites()
    }

    public func clearAll() {
        favorites.removeAll()
        saveFavorites()
    }

    private func belongsToServer(_ file: VideoFile, server: ServerConfig) -> Bool {
        guard file.isRemote else { return false }
        // Note: resolvedServer implementation should eventually move to Core or use a lookup protocol.
        // For now, if we can't resolve it cleanly in Core, we might need a delegate.
        return file.jellyfinServerId == server.id.uuidString
    }

    private func saveFavorites() {
        if let encoded = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(encoded, forKey: favoritesKey)
        }
    }

    private func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: favoritesKey),
              let decoded = try? JSONDecoder().decode([FavoriteItem].self, from: data) else {
            favorites = []
            return
        }
        
        var didHydrateServerInfo = false
        var didNormalizeLocalPath = false
        var didNormalizeRemoteLibraryFavorites = false
        let loaded = decoded
            .filter { item in
                if item.file.isRemote {
                    return true
                }
                return FileManager.default.fileExists(atPath: item.file.url.path)
            }
            .map { item -> FavoriteItem in
                // Using jellyfinServerId for hydration check in Core
                guard item.file.isRemote, item.file.jellyfinServerId == nil else {
                    var normalized = item
                    let normalizedFolderPath = FavoriteItem.normalizedFolderPath(for: normalized.file, folderPath: normalized.folderPath)
                    if normalized.folderPath != normalizedFolderPath {
                        normalized.folderPath = normalizedFolderPath
                        didNormalizeLocalPath = true
                    }

                    let normalizedID = FavoriteItem.makeID(file: normalized.file, folderPath: normalized.folderPath)
                    if normalized.id != normalizedID {
                        normalized.id = normalizedID
                        didNormalizeLocalPath = true
                    }
                    let normalizedRemoteFavorite = normalizeRemoteLibraryFavorite(normalized)
                    if normalizedRemoteFavorite.id != normalized.id ||
                        normalizedRemoteFavorite.folderPath != normalized.folderPath ||
                        normalizedRemoteFavorite.file.jellyfinItemId != normalized.file.jellyfinItemId {
                        didNormalizeRemoteLibraryFavorites = true
                    }
                    return normalizedRemoteFavorite
                }
                
                // If we are in Core, we might not have the full AppNetworkService singleton list yet.
                // We'll return it as is and let the App layer hydrate if needed, or implement a lookup here.
                return item
            }
            .reduce(into: [FavoriteItem]()) { result, item in
                if result.contains(where: { $0.id == item.id }) {
                    didNormalizeLocalPath = true
                } else {
                    result.append(item)
                }
            }
            .sorted(by: { $0.addedDate > $1.addedDate })
         
        favorites = loaded
        if didHydrateServerInfo || didNormalizeLocalPath || didNormalizeRemoteLibraryFavorites {
            saveFavorites()
        }
    }

    private func normalizeRemoteLibraryFavorite(_ item: FavoriteItem) -> FavoriteItem {
        guard item.file.isRemote else { return item }
        let serverType = item.file.serverType
        guard let seriesId = item.file.seriesId, !seriesId.isEmpty else { return item }

        let identityPath: String
        if let serverType = serverType {
            switch serverType {
            case .jellyfin:
                identityPath = "__jellyfin_item__/\(seriesId)"
            case .emby:
                identityPath = "__emby_item__/\(seriesId)"
            case .plex:
                identityPath = "__plex_item__/\(seriesId)"
            default:
                return item
            }
        } else {
            return item
        }

        let currentItemId = item.file.jellyfinItemId ?? ""
        if currentItemId == seriesId && item.folderPath == identityPath {
            return item
        }

        var normalized = item
        normalized.file.jellyfinItemId = seriesId
        normalized.folderPath = identityPath
        normalized.id = FavoriteItem.makeID(file: normalized.file, folderPath: normalized.folderPath)
        return normalized
    }
}
