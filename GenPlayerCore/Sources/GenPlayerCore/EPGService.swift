import Foundation
import Combine

public final class EPGService: ObservableObject {
    public static let shared = EPGService()
    
    @Published public private(set) var epgTables: [UUID: EPGTable] = [:]
    @Published public private(set) var loadingServers: Set<UUID> = []
    @Published public private(set) var errorMessages: [UUID: String] = [:]
    
    private let fileManager = FileManager.default
    private let lock = NSLock()
    private let cacheTTL: TimeInterval = 12 * 3600 // 12 hours cache
    
    private var baseStorageURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let epgDir = appSupport.appendingPathComponent("IPTV", isDirectory: true).appendingPathComponent("EPG", isDirectory: true)
        if !fileManager.fileExists(atPath: epgDir.path) {
            try? fileManager.createDirectory(at: epgDir, withIntermediateDirectories: true, attributes: nil)
        }
        return epgDir
    }
    
    private init() {
        // Pre-load cached EPG tables into memory if available
        loadCachedTables()
    }
    
    // MARK: - Query APIs
    
    public func cachedTable(for serverId: UUID) -> EPGTable? {
        lock.lock()
        defer { lock.unlock() }
        return epgTables[serverId]
    }
    
    public func currentProgramme(for channel: IPTVChannel, in serverId: UUID, at date: Date = Date()) -> EPGProgramme? {
        guard let table = cachedTable(for: serverId) else { return nil }
        return table.currentProgramme(for: channel, at: date)
    }
    
    public func nextProgramme(for channel: IPTVChannel, in serverId: UUID, at date: Date = Date()) -> EPGProgramme? {
        guard let table = cachedTable(for: serverId) else { return nil }
        return table.nextProgramme(for: channel, at: date)
    }
    
    public func programmes(for channel: IPTVChannel, in serverId: UUID, on date: Date = Date()) -> [EPGProgramme] {
        guard let table = cachedTable(for: serverId) else { return [] }
        return table.programmes(for: channel, on: date)
    }
    
    public func channelInfo(for channel: IPTVChannel, in serverId: UUID) -> EPGChannelInfo? {
        guard let table = cachedTable(for: serverId) else { return nil }
        return table.channelInfo(for: channel)
    }
    
    public func iconURL(for channel: IPTVChannel, in serverId: UUID) -> URL? {
        guard let table = cachedTable(for: serverId) else { return nil }
        return table.iconURL(for: channel)
    }
    
    public func hasProgrammes(for channel: IPTVChannel, in serverId: UUID) -> Bool {
        guard let table = cachedTable(for: serverId) else { return false }
        return !table.allProgrammes(for: channel).isEmpty
    }

    public func hasEPG(for serverId: UUID) -> Bool {
        guard let table = cachedTable(for: serverId) else { return false }
        return !table.programmesByChannel.isEmpty
    }

    public func hasAvailableEPG(
        channelId: String?,
        channelName: String,
        url: URL,
        serverIdStr: String?,
        serverType: ServerConfig.ServerType?,
        isLiveStream: Bool,
        in server: ServerConfig?
    ) -> Bool {
        guard isLiveStream || serverType == .iptv else { return false }
        let resolvedServerId: UUID?
        if let serverIdStr = serverIdStr, let uuid = UUID(uuidString: serverIdStr) {
            resolvedServerId = uuid
        } else {
            resolvedServerId = server?.id
        }
        guard let serverId = resolvedServerId else { return false }
        let dummy = IPTVChannel(
            id: channelId ?? "",
            name: channelName,
            url: url
        )
        return hasProgrammes(for: dummy, in: serverId)
    }

    public func hasAvailableEPG(for file: VideoFile, in server: ServerConfig?) -> Bool {
        hasAvailableEPG(
            channelId: file.jellyfinItemId,
            channelName: file.name,
            url: file.url,
            serverIdStr: file.jellyfinServerId,
            serverType: file.serverType,
            isLiveStream: file.isLiveStream,
            in: server
        )
    }

    public func hasAvailableEPG(for item: MediaItem, in server: ServerConfig?) -> Bool {
        hasAvailableEPG(
            channelId: item.jellyfinItemId,
            channelName: item.title,
            url: item.url,
            serverIdStr: item.jellyfinServerId,
            serverType: item.serverType,
            isLiveStream: item.isLiveStream,
            in: server
        )
    }
    
    // MARK: - Fetch & Parse
    
    @discardableResult
    public func fetchEPG(
        for server: ServerConfig,
        playlist: IPTVPlaylist? = nil,
        forceRefresh: Bool = false
    ) async throws -> EPGTable? {
        let serverId = server.id
        
        // 1. Resolve Target EPG URL
        var targetEPGURL: URL? = nil
        if let customStr = server.customEPGURL?.trimmingCharacters(in: .whitespacesAndNewlines), !customStr.isEmpty {
            targetEPGURL = URL(string: customStr)
        }
        if targetEPGURL == nil {
            targetEPGURL = playlist?.epgURL ?? IPTVService.shared.cachedPlaylist(for: serverId)?.epgURL
        }
        
        guard let epgURL = targetEPGURL else {
            return nil
        }
        
        // 2. Check Disk / Memory Cache freshness
        if !forceRefresh {
            if let cached = cachedTable(for: serverId),
               Date().timeIntervalSince(cached.lastUpdated) < cacheTTL {
                return cached
            }
            if let diskTable = loadCachedTable(for: serverId),
               Date().timeIntervalSince(diskTable.lastUpdated) < cacheTTL {
                await MainActor.run {
                    self.epgTables[serverId] = diskTable
                }
                return diskTable
            }
        }
        
        // 3. Mark Loading State
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
            var request = URLRequest(url: epgURL)
            request.timeoutInterval = 45
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) GenPlayer/1.0", forHTTPHeaderField: "User-Agent")
            request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
            
            let (data, response) = try await URLSession.shared.data(for: request)
            
            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode >= 400 {
                throw NSError(domain: "EPGService", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(httpResp.statusCode)"])
            }
            
            // 4. Decompress if gzipped
            let rawXMLData: Data
            if GzipDecompressor.isGzipped(data: data) || epgURL.pathExtension.lowercased() == "gz" {
                rawXMLData = try GzipDecompressor.decompress(data: data)
            } else {
                rawXMLData = data
            }
            
            // 5. Parse XMLTV on background thread
            let epgTable = await Task.detached(priority: .userInitiated) { () -> EPGTable in
                let (channels, programmes) = XMLTVParser.parse(data: rawXMLData)
                return EPGTable(
                    serverId: serverId,
                    epgURL: epgURL,
                    lastUpdated: Date(),
                    channelsById: channels,
                    programmesByChannel: programmes
                )
            }.value
            
            // 6. Save & Publish
            saveCachedTable(epgTable, for: serverId)
            
            await MainActor.run {
                self.epgTables[serverId] = epgTable
            }
            
            return epgTable
        } catch {
            await MainActor.run {
                self.errorMessages[serverId] = error.localizedDescription
            }
            NSLog("[EPGService] Failed to fetch EPG for %@: %@", server.name, error.localizedDescription)
            throw error
        }
    }
    
    // MARK: - Persistence
    
    private func cacheFileURL(for serverId: UUID) -> URL {
        baseStorageURL.appendingPathComponent("epg_\(serverId.uuidString).json")
    }
    
    private func saveCachedTable(_ table: EPGTable, for serverId: UUID) {
        let fileURL = cacheFileURL(for: serverId)
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try JSONEncoder().encode(table)
                try data.write(to: fileURL, options: .atomic)
            } catch {
                NSLog("[EPGService] Failed to write cache for %@: %@", serverId.uuidString, error.localizedDescription)
            }
        }
    }
    
    private func loadCachedTable(for serverId: UUID) -> EPGTable? {
        let fileURL = cacheFileURL(for: serverId)
        guard let data = try? Data(contentsOf: fileURL),
              let table = try? JSONDecoder().decode(EPGTable.self, from: data) else {
            return nil
        }
        return table
    }
    
    private func loadCachedTables() {
        guard let files = try? fileManager.contentsOfDirectory(at: baseStorageURL, includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix("epg_") && file.pathExtension == "json" {
            let filename = file.deletingPathExtension().lastPathComponent
            let idStr = filename.replacingOccurrences(of: "epg_", with: "")
            if let uuid = UUID(uuidString: idStr),
               let data = try? Data(contentsOf: file),
               let table = try? JSONDecoder().decode(EPGTable.self, from: data) {
                self.epgTables[uuid] = table
            }
        }
    }
    
    public func clearCache(for serverId: UUID) {
        lock.lock()
        epgTables.removeValue(forKey: serverId)
        lock.unlock()
        let fileURL = cacheFileURL(for: serverId)
        try? fileManager.removeItem(at: fileURL)
    }
}
