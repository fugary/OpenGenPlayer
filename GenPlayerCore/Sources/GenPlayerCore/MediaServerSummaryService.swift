import Foundation
import Combine

public struct MediaServerSummary: Codable, Equatable, Hashable {
    public let serverId: UUID
    public let libraryCount: Int
    public let movieCount: Int
    public let seriesCount: Int
    public let episodeCount: Int
    public let lastUpdated: Date
    
    public init(
        serverId: UUID,
        libraryCount: Int,
        movieCount: Int = 0,
        seriesCount: Int = 0,
        episodeCount: Int = 0,
        lastUpdated: Date = Date()
    ) {
        self.serverId = serverId
        self.libraryCount = libraryCount
        self.movieCount = movieCount
        self.seriesCount = seriesCount
        self.episodeCount = episodeCount
        self.lastUpdated = lastUpdated
    }
    
    enum CodingKeys: String, CodingKey {
        case serverId, libraryCount, movieCount, seriesCount, episodeCount, lastUpdated
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.serverId = try container.decode(UUID.self, forKey: .serverId)
        self.libraryCount = try container.decodeIfPresent(Int.self, forKey: .libraryCount) ?? 0
        self.movieCount = try container.decodeIfPresent(Int.self, forKey: .movieCount) ?? 0
        self.seriesCount = try container.decodeIfPresent(Int.self, forKey: .seriesCount) ?? 0
        self.episodeCount = try container.decodeIfPresent(Int.self, forKey: .episodeCount) ?? 0
        self.lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? Date()
    }
}

public final class MediaServerSummaryService: ObservableObject {
    public static let shared = MediaServerSummaryService()
    
    @Published public private(set) var summaries: [UUID: MediaServerSummary] = [:]
    @Published public private(set) var loadingServers: Set<UUID> = []
    
    private let fileManager = FileManager.default
    private let lock = NSLock()
    
    private var summariesFileURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("media_server_summaries.json")
    }
    
    private init() {
        self.summaries = loadSummaries()
    }
    
    private func loadSummaries() -> [UUID: MediaServerSummary] {
        let url = summariesFileURL
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: MediaServerSummary].self, from: data) else {
            return [:]
        }
        var result: [UUID: MediaServerSummary] = [:]
        for (key, val) in dict {
            if let uuid = UUID(uuidString: key) {
                result[uuid] = val
            }
        }
        return result
    }
    
    private func saveSummaries() {
        var strDict: [String: MediaServerSummary] = [:]
        for (key, val) in summaries {
            strDict[key.uuidString] = val
        }
        let url = summariesFileURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(strDict) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
    
    public func summary(for serverId: UUID) -> MediaServerSummary? {
        return summaries[serverId]
    }
    
    public func updateSummary(
        for serverId: UUID,
        libraryCount: Int,
        movieCount: Int = 0,
        seriesCount: Int = 0,
        episodeCount: Int = 0
    ) {
        let prev = summaries[serverId]
        let effectiveMovieCount = movieCount > 0 ? movieCount : (prev?.movieCount ?? 0)
        let effectiveSeriesCount = seriesCount > 0 ? seriesCount : (prev?.seriesCount ?? 0)
        let effectiveEpisodeCount = episodeCount > 0 ? episodeCount : (prev?.episodeCount ?? 0)
        
        let newSummary = MediaServerSummary(
            serverId: serverId,
            libraryCount: libraryCount,
            movieCount: effectiveMovieCount,
            seriesCount: effectiveSeriesCount,
            episodeCount: effectiveEpisodeCount,
            lastUpdated: Date()
        )
        
        if Thread.isMainThread {
            self.summaries[serverId] = newSummary
            self.saveSummaries()
        } else {
            DispatchQueue.main.async {
                self.summaries[serverId] = newSummary
                self.saveSummaries()
            }
        }
    }
    
    public func removeSummary(for serverId: UUID) {
        if Thread.isMainThread {
            self.summaries.removeValue(forKey: serverId)
            self.saveSummaries()
        } else {
            DispatchQueue.main.async {
                self.summaries.removeValue(forKey: serverId)
                self.saveSummaries()
            }
        }
    }
    
    public func refreshSummary(for server: ServerConfig) async {
        let serverId = server.id
        await MainActor.run {
            loadingServers.insert(serverId)
        }
        defer {
            Task { @MainActor in
                loadingServers.remove(serverId)
            }
        }
        
        let hydrated = AppNetworkService.shared.hydratedServer(from: server)
        do {
            switch hydrated.type {
            case .jellyfin, .emby:
                let result = try await fetchJellyfinLikeSummary(server: hydrated)
                updateSummary(
                    for: serverId,
                    libraryCount: result.libraryCount,
                    movieCount: result.movieCount,
                    seriesCount: result.seriesCount,
                    episodeCount: result.episodeCount
                )
            case .plex:
                let result = try await fetchPlexSummary(server: hydrated)
                updateSummary(
                    for: serverId,
                    libraryCount: result.libraryCount,
                    movieCount: result.movieCount,
                    seriesCount: result.seriesCount,
                    episodeCount: 0
                )
            case .vod:
                let result = try await VODService.shared.fetchList(server: hydrated, page: 1)
                updateSummary(
                    for: serverId,
                    libraryCount: result.totalCount
                )
            default:
                break
            }
        } catch {
            print("[MediaServerSummaryService] Failed to refresh summary for \(server.name): \(error)")
        }
    }
    
    private func fetchJellyfinLikeSummary(server: ServerConfig) async throws -> (libraryCount: Int, movieCount: Int, seriesCount: Int, episodeCount: Int) {
        guard let token = server.accessToken, !token.isEmpty else {
            throw NSError(domain: "MediaServerSummaryService", code: 401, userInfo: [NSLocalizedDescriptionKey: "No access token"])
        }
        let userId = server.userId ?? ""
        let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        // 1. Fetch Views (Libraries) and filter out non-media system collections like boxsets/playlists/livetv
        var libraryCount = 0
        let viewsEndpoint = userId.isEmpty ? "\(baseURL)/Library/MediaFolders" : "\(baseURL)/Users/\(userId)/Views"
        if let viewsURL = URL(string: viewsEndpoint) {
            var request = URLRequest(url: viewsURL)
            request.timeoutInterval = 10
            applyMediaBrowserHeaders(to: &request, token: token)
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let items = json["Items"] as? [[String: Any]] {
                let userVisibleLibraries = items.filter { item in
                    let collectionType = (item["CollectionType"] as? String)?.lowercased()
                    let type = (item["Type"] as? String)?.lowercased()
                    if collectionType == "boxsets" || collectionType == "playlists" || collectionType == "livetv" || type == "boxset" || type == "playlist" {
                        return false
                    }
                    return true
                }
                libraryCount = userVisibleLibraries.isEmpty ? items.count : userVisibleLibraries.count
            }
        }
        
        // 2. Fetch precise item counts from /Items/Counts
        var movieCount = 0
        var seriesCount = 0
        var episodeCount = 0
        
        let countsEndpoint = userId.isEmpty ? "\(baseURL)/Items/Counts" : "\(baseURL)/Items/Counts?UserId=\(userId)"
        if let countsURL = URL(string: countsEndpoint) {
            var request = URLRequest(url: countsURL)
            request.timeoutInterval = 10
            applyMediaBrowserHeaders(to: &request, token: token)
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                movieCount = (json["MovieCount"] as? Int) ?? 0
                seriesCount = (json["SeriesCount"] as? Int) ?? 0
                episodeCount = (json["EpisodeCount"] as? Int) ?? 0
            }
        }
        
        // Fallback for some Jellyfin/Emby versions where user specific counts are at /Users/{userId}/Items/Counts
        if movieCount == 0 && seriesCount == 0 && !userId.isEmpty {
            let altCountsEndpoint = "\(baseURL)/Users/\(userId)/Items/Counts"
            if let altURL = URL(string: altCountsEndpoint) {
                var request = URLRequest(url: altURL)
                request.timeoutInterval = 10
                applyMediaBrowserHeaders(to: &request, token: token)
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    movieCount = (json["MovieCount"] as? Int) ?? 0
                    seriesCount = (json["SeriesCount"] as? Int) ?? 0
                    episodeCount = (json["EpisodeCount"] as? Int) ?? 0
                }
            }
        }
        
        return (libraryCount, movieCount, seriesCount, episodeCount)
    }
    
    private func fetchPlexSummary(server: ServerConfig) async throws -> (libraryCount: Int, movieCount: Int, seriesCount: Int) {
        let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(baseURL)/library/sections") else {
            throw NSError(domain: "MediaServerSummaryService", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token = server.accessToken, !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NSError(domain: "MediaServerSummaryService", code: (response as? HTTPURLResponse)?.statusCode ?? -1, userInfo: nil)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = json["MediaContainer"] as? [String: Any],
              let directories = container["Directory"] as? [[String: Any]] else {
            return (0, 0, 0)
        }
        
        let libraryCount = directories.count
        var movieCount = 0
        var seriesCount = 0
        
        let token = server.accessToken
        let counts = await withTaskGroup(of: (type: String, size: Int).self) { group -> [(type: String, size: Int)] in
            for dir in directories {
                guard let key = dir["key"] as? String,
                      let type = dir["type"] as? String else { continue }
                guard let sectionURL = URL(string: "\(baseURL)/library/sections/\(key)/all?X-Plex-Container-Start=0&X-Plex-Container-Size=0") else { continue }
                
                group.addTask {
                    var secRequest = URLRequest(url: sectionURL)
                    secRequest.timeoutInterval = 5
                    secRequest.setValue("application/json", forHTTPHeaderField: "Accept")
                    if let token = token, !token.isEmpty {
                        secRequest.setValue(token, forHTTPHeaderField: "X-Plex-Token")
                    }
                    if let (secData, secResponse) = try? await URLSession.shared.data(for: secRequest),
                       let secHttp = secResponse as? HTTPURLResponse, (200...299).contains(secHttp.statusCode),
                       let secJson = try? JSONSerialization.jsonObject(with: secData) as? [String: Any],
                       let secContainer = secJson["MediaContainer"] as? [String: Any],
                       let totalSize = secContainer["totalSize"] as? Int {
                        return (type.lowercased(), totalSize)
                    }
                    return (type.lowercased(), 0)
                }
            }
            
            var results: [(type: String, size: Int)] = []
            for await item in group {
                results.append(item)
            }
            return results
        }
        
        for item in counts {
            if item.type == "movie" {
                movieCount += item.size
            } else if item.type == "show" {
                seriesCount += item.size
            }
        }
        
        return (libraryCount, movieCount, seriesCount)
    }
    
    private func applyMediaBrowserHeaders(to request: inout URLRequest, token: String) {
        let authHeaderValue = "MediaBrowser Client=\"GenPlayer\", Device=\"Mac\", DeviceId=\"genplayer-device\", Version=\"1.0.0\", Token=\"\(token)\""
        request.setValue(authHeaderValue, forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(authHeaderValue, forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "X-MediaBrowser-Token")
    }
    
    public func formatLastUpdated(_ date: Date) -> String {
        AppRelativeDateTimeFormatter.formatRelativeDate(date)
    }
}
