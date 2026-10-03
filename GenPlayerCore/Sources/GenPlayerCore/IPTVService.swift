import Foundation
import Combine

public final class IPTVService: ObservableObject {
    public static let shared = IPTVService()
    
    @Published public private(set) var playlists: [UUID: IPTVPlaylist] = [:]
    @Published public private(set) var summaries: [UUID: IPTVPlaylistSummary] = [:]
    @Published public private(set) var loadingServers: Set<UUID> = []
    @Published public private(set) var errorMessages: [UUID: String] = [:]
    
    private let fileManager = FileManager.default
    private let lock = NSLock()
    
    private var baseStorageURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let iptvDir = appSupport.appendingPathComponent("IPTV", isDirectory: true)
        if !fileManager.fileExists(atPath: iptvDir.path) {
            try? fileManager.createDirectory(at: iptvDir, withIntermediateDirectories: true, attributes: nil)
        }
        return iptvDir
    }
    
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        self.summaries = loadSummaries()
        migrateLegacyFavoritesIfNeeded()
        setupFavoriteServiceObserver()
    }
    
    private func setupFavoriteServiceObserver() {
        FavoriteService.shared.$favorites
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.syncFavoritesWithLoadedPlaylists()
            }
            .store(in: &cancellables)
    }
    
    private func syncFavoritesWithLoadedPlaylists() {
        guard !playlists.isEmpty else { return }
        for (serverId, playlist) in playlists {
            let favIDs = loadFavoriteIDs(for: serverId)
            var hasChanges = false
            var updatedChannels = playlist.channels
            for i in 0..<updatedChannels.count {
                let shouldBeFav = favIDs.contains(updatedChannels[i].id)
                if updatedChannels[i].isFavorite != shouldBeFav {
                    updatedChannels[i].isFavorite = shouldBeFav
                    hasChanges = true
                }
            }
            if hasChanges {
                let updatedPlaylist = IPTVPlaylist(
                    id: playlist.id,
                    serverId: playlist.serverId,
                    name: playlist.name,
                    sourceURL: playlist.sourceURL,
                    epgURL: playlist.epgURL,
                    channels: updatedChannels,
                    groups: playlist.groups,
                    groupCounts: playlist.groupCounts,
                    lastUpdated: playlist.lastUpdated
                )
                self.playlists[serverId] = updatedPlaylist
                saveCachedPlaylist(updatedPlaylist, for: serverId)
            }
        }
    }
    
    private func migrateLegacyFavoritesIfNeeded() {
        guard let files = try? fileManager.contentsOfDirectory(at: baseStorageURL, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("favorites_") && file.pathExtension == "json" {
            let filename = file.deletingPathExtension().lastPathComponent
            let serverIdStr = filename.replacingOccurrences(of: "favorites_", with: "")
            guard let serverId = UUID(uuidString: serverIdStr),
                  let data = try? Data(contentsOf: file),
                  let legacyIDs = try? JSONDecoder().decode([String].self, from: data) else {
                try? fileManager.removeItem(at: file)
                continue
            }
            
            if let diskPlaylist = cachedPlaylist(for: serverId) {
                let idSet = Set(legacyIDs)
                // Fake server config to construct VideoFile
                let dummyServer = ServerConfig(
                    id: serverId,
                    name: diskPlaylist.name,
                    address: diskPlaylist.sourceURL?.absoluteString ?? "",
                    type: .iptv
                )
                for ch in diskPlaylist.channels where idSet.contains(ch.id) {
                    let vFile = makeVideoFile(for: ch, server: dummyServer)
                    if !FavoriteService.shared.isFavorite(file: vFile) {
                        FavoriteService.shared.toggleFavorite(file: vFile)
                    }
                }
            }
            try? fileManager.removeItem(at: file)
        }
    }
    
    private func playlistFileURL(for serverId: UUID) -> URL {
        baseStorageURL.appendingPathComponent("playlist_\(serverId.uuidString).json")
    }
    
    private var summariesFileURL: URL {
        baseStorageURL.appendingPathComponent("summaries.json")
    }
    
    // MARK: - Summary Management
    
    private func loadSummaries() -> [UUID: IPTVPlaylistSummary] {
        let url = summariesFileURL
        if let data = try? Data(contentsOf: url),
           let dict = try? JSONDecoder().decode([String: IPTVPlaylistSummary].self, from: data) {
            var result: [UUID: IPTVPlaylistSummary] = [:]
            for (key, val) in dict {
                if let uuid = UUID(uuidString: key) {
                    result[uuid] = val
                }
            }
            return result
        }
        return [:]
    }
    
    private func saveSummaries(_ dict: [UUID: IPTVPlaylistSummary]) {
        var strDict: [String: IPTVPlaylistSummary] = [:]
        for (key, val) in dict {
            strDict[key.uuidString] = val
        }
        let url = summariesFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(strDict) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
    
    public func summary(for serverId: UUID) -> IPTVPlaylistSummary? {
        return summaries[serverId]
    }
    
    public func formatLastUpdated(_ date: Date) -> String {
        AppRelativeDateTimeFormatter.formatRelativeDate(date)
    }
    
    // MARK: - Favorites Management
    
    public func loadFavoriteIDs(for serverId: UUID) -> Set<String> {
        let serverIdStr = serverId.uuidString
        let favIDs = FavoriteService.shared.favorites
            .filter { ($0.file.jellyfinServerId == serverIdStr || $0.file.resolvedServer?.id == serverId) && ($0.file.serverType == .iptv || $0.file.isLiveStream) }
            .compactMap { $0.file.jellyfinItemId }
        return Set(favIDs)
    }
    
    public func toggleFavorite(channelId: String, in server: ServerConfig) {
        let serverId = server.id
        guard let playlist = playlists[serverId] ?? cachedPlaylist(for: serverId),
              let channel = playlist.channels.first(where: { $0.id == channelId }) else {
            return
        }
        
        let videoFile = makeVideoFile(for: channel, server: server)
        FavoriteService.shared.toggleFavorite(file: videoFile)
        let isNowFavorite = FavoriteService.shared.isFavorite(file: videoFile)
        
        if var currentPlaylist = playlists[serverId] {
            if let index = currentPlaylist.channels.firstIndex(where: { $0.id == channelId }) {
                currentPlaylist.channels[index].isFavorite = isNowFavorite
                let updatedPlaylist = IPTVPlaylist(
                    id: currentPlaylist.id,
                    serverId: currentPlaylist.serverId,
                    name: currentPlaylist.name,
                    sourceURL: currentPlaylist.sourceURL,
                    epgURL: currentPlaylist.epgURL,
                    channels: currentPlaylist.channels,
                    groups: currentPlaylist.groups,
                    groupCounts: currentPlaylist.groupCounts,
                    lastUpdated: currentPlaylist.lastUpdated
                )
                
                if Thread.isMainThread {
                    self.playlists[serverId] = updatedPlaylist
                } else {
                    DispatchQueue.main.async {
                        self.playlists[serverId] = updatedPlaylist
                    }
                }
                saveCachedPlaylist(updatedPlaylist, for: serverId)
            }
        }
    }
    
    // MARK: - Cache & Persistence
    
    public func cachedPlaylist(for serverId: UUID) -> IPTVPlaylist? {
        if let memory = playlists[serverId] {
            return memory
        }
        
        let url = playlistFileURL(for: serverId)
        guard let data = try? Data(contentsOf: url),
              let diskPlaylist = try? JSONDecoder().decode(IPTVPlaylist.self, from: data) else {
            return nil
        }
        
        if Thread.isMainThread {
            self.playlists[serverId] = diskPlaylist
            if self.summaries[serverId] == nil {
                let sum = IPTVPlaylistSummary(
                    serverId: serverId,
                    channelCount: diskPlaylist.channels.count,
                    groupCount: diskPlaylist.groups.count,
                    lastUpdated: diskPlaylist.lastUpdated ?? Date()
                )
                self.summaries[serverId] = sum
                self.saveSummaries(self.summaries)
            }
        } else {
            DispatchQueue.main.async {
                self.playlists[serverId] = diskPlaylist
                if self.summaries[serverId] == nil {
                    let sum = IPTVPlaylistSummary(
                        serverId: serverId,
                        channelCount: diskPlaylist.channels.count,
                        groupCount: diskPlaylist.groups.count,
                        lastUpdated: diskPlaylist.lastUpdated ?? Date()
                    )
                    self.summaries[serverId] = sum
                    self.saveSummaries(self.summaries)
                }
            }
        }
        
        return diskPlaylist
    }
    
    private func saveCachedPlaylist(_ playlist: IPTVPlaylist, for serverId: UUID) {
        let sum = IPTVPlaylistSummary(
            serverId: serverId,
            channelCount: playlist.channels.count,
            groupCount: playlist.groups.count,
            lastUpdated: playlist.lastUpdated ?? Date()
        )
        
        if Thread.isMainThread {
            self.summaries[serverId] = sum
            self.saveSummaries(self.summaries)
        } else {
            DispatchQueue.main.async {
                self.summaries[serverId] = sum
                self.saveSummaries(self.summaries)
            }
        }
        
        let url = playlistFileURL(for: serverId)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(playlist) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
    
    public func clearCache(for serverId: UUID) {
        let playlistURL = playlistFileURL(for: serverId)
        try? fileManager.removeItem(at: playlistURL)
        EPGService.shared.clearCache(for: serverId)
        
        if Thread.isMainThread {
            self.playlists.removeValue(forKey: serverId)
            self.summaries.removeValue(forKey: serverId)
            self.errorMessages.removeValue(forKey: serverId)
            self.saveSummaries(self.summaries)
        } else {
            DispatchQueue.main.async {
                self.playlists.removeValue(forKey: serverId)
                self.summaries.removeValue(forKey: serverId)
                self.errorMessages.removeValue(forKey: serverId)
                self.saveSummaries(self.summaries)
            }
        }
    }
    
    // MARK: - Fetching & Refreshing
    
    @discardableResult
    public func fetchPlaylist(for server: ServerConfig, forceRefresh: Bool = false) async throws -> IPTVPlaylist {
        let serverId = server.id
        
        if !forceRefresh, let cached = cachedPlaylist(for: serverId) {
            Task.detached(priority: .utility) {
                try? await EPGService.shared.fetchEPG(for: server, playlist: cached, forceRefresh: false)
            }
            return cached
        }
        
        await MainActor.run {
            self.loadingServers.insert(serverId)
            self.errorMessages.removeValue(forKey: serverId)
        }
        
        defer {
            Task { @MainActor in
                self.loadingServers.remove(serverId)
            }
        }
        
        do {
            let content: String
            let rawAddress = server.address.trimmingCharacters(in: .whitespacesAndNewlines)
            
            if rawAddress.hasPrefix("/") || rawAddress.hasPrefix("file://") {
                let filePath = rawAddress.hasPrefix("file://") ? (URL(string: rawAddress)?.path ?? rawAddress) : rawAddress
                let fileURL = URL(fileURLWithPath: filePath)
                content = try String(contentsOf: fileURL, encoding: .utf8)
            } else {
                guard let url = URL(string: server.fullURL) else {
                    throw NSError(domain: "IPTVService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid IPTV URL"])
                }
                
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")
                
                let (data, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                    throw NSError(domain: "IPTVService", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResponse.statusCode)"])
                }
                
                if let utf8String = String(data: data, encoding: .utf8) {
                    content = utf8String
                } else if let latin1String = String(data: data, encoding: .isoLatin1) {
                    content = latin1String
                } else {
                    throw NSError(domain: "IPTVService", code: 422, userInfo: [NSLocalizedDescriptionKey: "Unsupported content encoding"])
                }
            }
            
            let favoriteIDs = loadFavoriteIDs(for: serverId)
            let serverName = server.name
            let serverFullURL = server.fullURL
            
            let playlist = await Task.detached(priority: .userInitiated) { () -> IPTVPlaylist in
                let parsed = M3UParser.parse(content: content)
                var channelsWithFavorites = parsed.channels
                for i in 0..<channelsWithFavorites.count {
                    if favoriteIDs.contains(channelsWithFavorites[i].id) {
                        channelsWithFavorites[i].isFavorite = true
                    }
                }
                return IPTVPlaylist(
                    id: UUID(),
                    serverId: serverId,
                    name: serverName,
                    sourceURL: URL(string: serverFullURL),
                    epgURL: parsed.epgURL,
                    channels: channelsWithFavorites,
                    groups: parsed.groups,
                    lastUpdated: Date()
                )
            }.value
            
            await MainActor.run {
                self.playlists[serverId] = playlist
            }
            self.saveCachedPlaylist(playlist, for: serverId)
            
            Task.detached(priority: .utility) {
                try? await EPGService.shared.fetchEPG(for: server, playlist: playlist, forceRefresh: forceRefresh)
            }
            
            return playlist
        } catch {
            await MainActor.run {
                self.errorMessages[serverId] = error.localizedDescription
            }
            throw error
        }
    }
    
    // MARK: - VideoFile Builder
    
    public func makeVideoFile(for channel: IPTVChannel, server: ServerConfig) -> VideoFile {
        VideoFile(
            name: channel.name,
            url: channel.url,
            type: .video,
            size: 0,
            date: Date(),
            isRemote: true,
            duration: nil,
            lastPlayedPosition: nil,
            jellyfinItemId: channel.id,
            jellyfinServerId: server.id.uuidString,
            serverType: .iptv,
            customArtworkURL: channel.logoURL
        )
    }
}
