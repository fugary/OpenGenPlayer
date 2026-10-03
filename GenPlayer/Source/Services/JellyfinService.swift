import Foundation
#if os(iOS)
import UIKit
import GenPlayerShell
#endif

class JellyfinService {
    
    static let shared = JellyfinService()
    
    private let session: URLSession
    private let clientName = "GenPlayer"
    private let clientVersion = "1.0"
    private let deviceId: String
    private let deviceName: String
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
        
        // Generate stable device ID
        if let keychainId = KeychainService.get(for: "JellyfinDeviceId") {
            self.deviceId = keychainId
        } else if let storedId = UserDefaults.standard.string(forKey: "JellyfinDeviceId") {
            self.deviceId = storedId
            _ = KeychainService.set(storedId, for: "JellyfinDeviceId")
        } else {
            let newId = UUID().uuidString
            _ = KeychainService.set(newId, for: "JellyfinDeviceId")
            UserDefaults.standard.set(newId, forKey: "JellyfinDeviceId")
            self.deviceId = newId
        }
        
        self.deviceName = UIDevice.current.name
    }
    
    // MARK: - Auth Header
    
    private func authHeader(token: String? = nil) -> String {
        var parts = [
            "Client=\"\(clientName)\"",
            "Device=\"\(deviceName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceName)\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(clientVersion)\""
        ]
        if let token = token {
            parts.append("Token=\"\(token)\"")
        }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    private func runtimeRequest(for url: URL) -> URLRequest {
        URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
    }
    
    // MARK: - Authentication
    
    /// Login to Jellyfin server and get access token
    func login(server: ServerConfig, username: String, password: String) async throws -> JellyfinAuthResult {
        let baseURL = server.fullURL
        let urlString = "\(baseURL)/Users/AuthenticateByName"
        print("[Jellyfin] Login URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            print("[Jellyfin] Invalid URL")
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        
        let body = JellyfinAuthRequest(username: username, pw: password)
        request.httpBody = try JSONEncoder().encode(body)
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw JellyfinError.invalidResponse
            }
            
            if httpResponse.statusCode == 401 {
                throw JellyfinError.unauthorized
            }
            
            guard httpResponse.statusCode == 200 else {
                throw JellyfinError.serverError(httpResponse.statusCode)
            }
            
            let result = try JSONDecoder().decode(JellyfinAuthResult.self, from: data)
            print("[Jellyfin] Login success, userId: \(result.user.id)")
            return result
        } catch let error as JellyfinError {
            throw error
        } catch {
            print("[Jellyfin] Network error: \(error)")
            throw error
        }
    }
    
    // MARK: - Libraries
    
    /// Get user's media libraries/views
    func getLibraries(server: ServerConfig, userId: String, token: String) async throws -> [JellyfinLibrary] {
        let baseURL = server.fullURL
        guard let url = URL(string: "\(baseURL)/Users/\(userId)/Views") else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw JellyfinError.invalidResponse
            }
            
            print("[Jellyfin] getLibraries Status: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode == 401 {
                throw JellyfinError.unauthorized
            }
            
            guard httpResponse.statusCode == 200 else {
                if let errorBody = String(data: data, encoding: .utf8) {
                     print("[Jellyfin] Error Body: \(errorBody)")
                }
                throw JellyfinError.serverError(httpResponse.statusCode)
            }
            
            let result = try JSONDecoder().decode(JellyfinViewsResponse.self, from: data)
            return result.items
        } catch let error as DecodingError {
            print("[Jellyfin] Decoding error in getLibraries: \(error)")
            throw JellyfinError.decodingError
        } catch {
            print("[Jellyfin] Error in getLibraries: \(error)")
            throw error
        }
    }

    /// Get total count of items in a library
    func getLibraryItemCount(server: ServerConfig, userId: String, token: String, libraryId: String, libraryType: JellyfinLibrary.LibraryType? = nil) async -> Int? {
        let baseURL = server.fullURL
        var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items")
        var queryItems = [
            URLQueryItem(name: "ParentId", value: libraryId),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "0")
        ]
        if let types = libraryType?.browseIncludeTypes, !types.isEmpty {
            queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: types.joined(separator: ",")))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            return nil
        }
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = (json["TotalRecordCount"] as? Int) ?? (json["TotalRecordCount"] as? Int64).map(Int.init) else {
            return nil
        }
        return total
    }
    
    // MARK: - Items
    
    /// Get latest items in a library
    func getLatestItems(server: ServerConfig, userId: String, token: String, libraryId: String, limit: Int = 20) async throws -> [JellyfinItem] {
        let baseURL = server.fullURL
        guard let url = URL(string: "\(baseURL)/Users/\(userId)/Items/Latest?ParentId=\(libraryId)&Limit=\(limit)&Fields=Overview,MediaSources,UserData,Genres,ProviderIds") else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        do {
            let (data, rawResponse) = try await session.data(for: request)
            if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
                throw JellyfinError.unauthorized
            }
            let items = try JSONDecoder().decode([JellyfinItem].self, from: data)
            return items
        } catch let error as DecodingError {
            print("[Jellyfin] Decoding error in getLatestItems: \(error)")
            throw JellyfinError.decodingError
        } catch {
            throw error
        }
    }

    /// Get home shelf items in a library, aligned with library-detail filtering semantics.
    func getHomeShelfItems(
        server: ServerConfig,
        userId: String,
        token: String,
        library: JellyfinLibrary,
        limit: Int = 18
    ) async throws -> [JellyfinItem] {
        let response = try await getItems(
            server: server,
            userId: userId,
            token: token,
            libraryId: library.id,
            includeTypes: library.libraryType.browseIncludeTypes,
            sortBy: "DateCreated",
            sortOrder: "Descending",
            limit: limit
        )
        return response.items
    }
    
    /// Get items in a library with pagination
    func getItems(server: ServerConfig, userId: String, token: String, libraryId: String? = nil,
                  includeTypes: [String]? = nil, searchTerm: String? = nil,
                  sortBy: String = "SortName", sortOrder: String = "Ascending",
                  genres: String? = nil, years: String? = nil,
                  startIndex: Int = 0, limit: Int = 50, recursive: Bool = true) async throws -> JellyfinItemsResponse {
        let baseURL = server.fullURL
        let fields = "Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,ChildCount,RecursiveItemCount,Genres,ProviderIds,PrimaryImageTag,ImageTags,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ParentThumbItemId,ParentThumbImageTag,ProductionYear,PremiereDate,CommunityRating,OfficialRating,RunTimeTicks,IndexNumber,ParentIndexNumber"
        var urlString = "\(baseURL)/Users/\(userId)/Items?Recursive=\(recursive ? "true" : "false")&Fields=\(fields)&SortBy=\(sortBy)&SortOrder=\(sortOrder)&StartIndex=\(startIndex)&Limit=\(limit)"
        
        if let libraryId = libraryId {
            urlString += "&ParentId=\(libraryId)"
        }
        if let types = includeTypes, !types.isEmpty {
            urlString += "&IncludeItemTypes=\(types.joined(separator: ","))"
        }
        if let genres = genres, !genres.isEmpty {
            urlString += "&Genres=\(genres.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? genres)"
        }
        if let years = years, !years.isEmpty {
            urlString += "&Years=\(years.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? years)"
        }
        if let searchTerm = searchTerm?.trimmingCharacters(in: .whitespacesAndNewlines),
           !searchTerm.isEmpty,
           let encodedQuery = searchTerm.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            urlString += "&SearchTerm=\(encodedQuery)"
        }
        
        guard let url = URL(string: urlString) else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        do {
            let (data, rawResponse) = try await session.data(for: request)
            if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
                throw JellyfinError.unauthorized
            }
            let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
            return response
        } catch let error as DecodingError {
            print("[Jellyfin] Decoding error in getItems: \(error)")
            throw JellyfinError.decodingError
        } catch {
            throw error
        }
    }
    
    func getLibraryFilterOptions(server: ServerConfig, token: String, parentId: String?) async throws -> (genres: [String], years: [String]) {
        let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        
        async let genresReq: [String] = {
            var comp = URLComponents(string: "\(baseURL)/Genres")
            var items = [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,MusicAlbum,Audio,Episode")
            ]
            if let parentId = parentId { items.append(URLQueryItem(name: "ParentId", value: parentId)) }
            comp?.queryItems = items
            
            guard let url = comp?.url else { return [] }
            var request = runtimeRequest(for: url)
            request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let resItems = json["Items"] as? [[String: Any]] else { return [] }
                return resItems.compactMap { $0["Name"] as? String }
            } catch {
                return []
            }
        }()
        
        async let yearsReq: [String] = {
            var comp = URLComponents(string: "\(baseURL)/Years")
            var items = [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,MusicAlbum,Audio,Episode")
            ]
            if let parentId = parentId { items.append(URLQueryItem(name: "ParentId", value: parentId)) }
            comp?.queryItems = items
            
            guard let url = comp?.url else { return [] }
            var request = runtimeRequest(for: url)
            request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let resItems = json["Items"] as? [[String: Any]] else { return [] }
                return resItems.compactMap { $0["Name"] as? String }.sorted(by: >)
            } catch {
                return []
            }
        }()
        
        let (g, y) = await (genresReq, yearsReq)
        return (g, y)
    }

    
    /// Get continue watching / resume items
    func getContinueWatching(server: ServerConfig, userId: String, token: String, limit: Int = 12) async throws -> [JellyfinItem] {
        let baseURL = server.fullURL
        let fields = "Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,Genres,ProviderIds,PrimaryImageTag,ImageTags,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ParentThumbItemId,ParentThumbImageTag,ProductionYear,IndexNumber,ParentIndexNumber"
        let resumeURL = URL(string: "\(baseURL)/Users/\(userId)/Items/Resume?UserId=\(userId)&Limit=\(limit)&Fields=\(fields)&MediaTypes=Video")
        let fallbackURL = URL(string: "\(baseURL)/Users/\(userId)/Items?Recursive=true&Filters=IsResumable&SortBy=DatePlayed&SortOrder=Descending&Limit=\(limit)&Fields=\(fields)&MediaTypes=Video")
        guard let resumeURL, let fallbackURL else {
            throw JellyfinError.invalidURL
        }

        let resumeItems = try await fetchItems(url: resumeURL, token: token)
        if !resumeItems.isEmpty {
            return resumeItems
        }

        return try await fetchItems(url: fallbackURL, token: token)
    }
    
    /// Get next up episodes for TV shows
    func getNextUp(server: ServerConfig, userId: String, token: String, limit: Int = 12) async throws -> [JellyfinItem] {
        let baseURL = server.fullURL
        let fields = "Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,Genres,ProviderIds,PrimaryImageTag,ImageTags,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ParentThumbItemId,ParentThumbImageTag,ProductionYear,IndexNumber,ParentIndexNumber"
        guard let url = URL(string: "\(baseURL)/Shows/NextUp?UserId=\(userId)&Limit=\(limit)&Fields=\(fields)") else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw JellyfinError.unauthorized
        }
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        return response.items
    }
    
    /// Get next up episode for a specific series
    func getNextUp(server: ServerConfig, userId: String, token: String, seriesId: String) async throws -> [JellyfinItem] {
        let baseURL = server.fullURL
        let fields = "Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,Genres,ProviderIds,PrimaryImageTag,ImageTags,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ParentThumbItemId,ParentThumbImageTag,ProductionYear,IndexNumber,ParentIndexNumber"
        guard let url = URL(string: "\(baseURL)/Shows/NextUp?UserId=\(userId)&SeriesId=\(seriesId)&Limit=1&Fields=\(fields)") else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw JellyfinError.unauthorized
        }
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        return response.items
    }
    
    // MARK: - Playback
    
    /// Get stream URL for an item
    func getStreamURL(
        server: ServerConfig,
        itemId: String,
        token: String,
        mediaSourceId: String? = nil
    ) -> URL? {
        let baseURL = server.fullURL
        guard var components = URLComponents(string: "\(baseURL)/Videos/\(itemId)/stream") else {
            return nil
        }

        var queryItems = [
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "api_key", value: token)
        ]
        if let mediaSourceId, !mediaSourceId.isEmpty {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
        }
        components.queryItems = queryItems
        return components.url
    }

    func resolvePlaybackURL(
        server: ServerConfig,
        itemId: String,
        token: String,
        mediaSource: JellyfinMediaSource? = nil,
        playbackQuality: RemotePlaybackQualityOption = .auto,
        playSessionId: String? = nil
    ) -> URL? {
        if let mediaSource {
            if playbackQuality.prefersConstrainedPlayback,
               let transcodingURL = resolvedTranscodingURL(
                    server: server,
                    token: token,
                    mediaSource: mediaSource,
                    playbackQuality: playbackQuality
               ) {
                print("[Jellyfin] Using server transcoding URL for quality=\(playbackQuality.id), source=\(mediaSource.id)")
                return transcodingURL
            }

            if playbackQuality.prefersConstrainedPlayback,
               let manualURL = manualTranscodingURL(
                    server: server,
                    itemId: itemId,
                    token: token,
                    mediaSource: mediaSource,
                    playbackQuality: playbackQuality,
                    playSessionId: playSessionId
               ) {
                print("[Jellyfin] Using manual HLS transcode URL for quality=\(playbackQuality.id), source=\(mediaSource.id)")
                return manualURL
            }

            if let directStreamURL = resolvedDirectStreamURL(
                server: server,
                token: token,
                mediaSource: mediaSource
            ) {
                return directStreamURL
            }

            if let transcodingURL = resolvedTranscodingURL(
                server: server,
                token: token,
                mediaSource: mediaSource,
                playbackQuality: playbackQuality
            ) {
                return transcodingURL
            }
        }

        return getStreamURL(
            server: server,
            itemId: itemId,
            token: token,
            mediaSourceId: mediaSource?.id
        )
    }

    func rebuildPlaybackURL(
        server: ServerConfig,
        itemId: String,
        token: String,
        mediaSourceId: String?,
        playbackQuality: RemotePlaybackQualityOption,
        playSessionId: String? = nil
    ) -> URL? {
        let normalizedMediaSourceId = mediaSourceId?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if playbackQuality.prefersConstrainedPlayback,
           let normalizedMediaSourceId,
           !normalizedMediaSourceId.isEmpty {
            let rebuiltURL = manualTranscodingURL(
                server: server,
                itemId: itemId,
                token: token,
                mediaSourceId: normalizedMediaSourceId,
                playbackQuality: playbackQuality,
                playSessionId: playSessionId
            )
            if rebuiltURL != nil {
                print("[Jellyfin] Rebuilt manual playback URL for quality=\(playbackQuality.id), source=\(normalizedMediaSourceId)")
            }
            return rebuiltURL
        }

        let rebuiltURL = getStreamURL(
            server: server,
            itemId: itemId,
            token: token,
            mediaSourceId: normalizedMediaSourceId
        )
        if rebuiltURL != nil {
            print("[Jellyfin] Rebuilt direct playback URL for quality=\(playbackQuality.id), source=\(normalizedMediaSourceId ?? "nil"))")
        }
        return rebuiltURL
    }
    
    /// Get playback info with media sources
    func getPlaybackInfo(
        server: ServerConfig,
        itemId: String,
        userId: String,
        token: String,
        playbackQuality: RemotePlaybackQualityOption = .auto,
        startTimeTicks: Int64? = nil,
        mediaSourceId: String? = nil,
        currentPlaySessionId: String? = nil
    ) async throws -> JellyfinPlaybackInfo {
        let baseURL = server.fullURL
        guard var components = URLComponents(string: "\(baseURL)/Items/\(itemId)/PlaybackInfo") else {
            throw JellyfinError.invalidURL
        }
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "IsPlayback", value: "true"),
            URLQueryItem(name: "AutoOpenLiveStream", value: "true"),
            URLQueryItem(name: "EnableDirectPlay", value: playbackQuality.allowsDirectPlay ? "true" : "false"),
            URLQueryItem(name: "EnableDirectStream", value: playbackQuality.allowsDirectStream ? "true" : "false"),
            URLQueryItem(name: "EnableTranscoding", value: playbackQuality.allowsTranscoding ? "true" : "false")
        ]
        if let startTimeTicks, startTimeTicks > 0 {
            queryItems.append(URLQueryItem(name: "StartTimeTicks", value: String(startTimeTicks)))
        }
        if let mediaSourceId, !mediaSourceId.isEmpty {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
        }
        if let currentPlaySessionId, !currentPlaySessionId.isEmpty {
            queryItems.append(URLQueryItem(name: "CurrentPlaySessionId", value: currentPlaySessionId))
        }
        if playbackQuality.prefersConstrainedPlayback {
            queryItems.append(URLQueryItem(name: "AllowVideoStreamCopy", value: "false"))
        }
        if let maxStreamingBitrate = playbackQuality.maxStreamingBitrate {
            queryItems.append(URLQueryItem(name: "MaxStreamingBitrate", value: String(maxStreamingBitrate)))
        }
        if let maxWidth = playbackQuality.maxWidth {
            queryItems.append(URLQueryItem(name: "MaxWidth", value: String(maxWidth)))
        }
        if let maxHeight = playbackQuality.maxHeight {
            queryItems.append(URLQueryItem(name: "MaxHeight", value: String(maxHeight)))
        }
        queryItems.append(contentsOf: playbackClientQueryItems(token: token))
        components.queryItems = queryItems
        guard let url = components.url else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.httpMethod = "POST"
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: playbackInfoRequestBody(for: playbackQuality, userId: userId),
            options: []
        )

        if playbackQuality.prefersConstrainedPlayback {
            print(
                "[Jellyfin] PlaybackInfo request quality=\(playbackQuality.id) " +
                "bitrate=\(playbackQuality.maxStreamingBitrate ?? 0) " +
                "size=\(playbackQuality.maxWidth ?? 0)x\(playbackQuality.maxHeight ?? 0) " +
                "mediaSourceId=\(mediaSourceId ?? "nil") playSessionId=\(currentPlaySessionId ?? "nil")"
            )
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw JellyfinError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if let body = String(data: data, encoding: .utf8), !body.isEmpty {
                print("[Jellyfin] getPlaybackInfo failed body: \(body.prefix(300))")
            }
            throw JellyfinError.serverError(httpResponse.statusCode)
        }

        guard !data.isEmpty else {
            return JellyfinPlaybackInfo(mediaSources: [], playSessionId: nil)
        }

        do {
            let result = try JSONDecoder().decode(JellyfinPlaybackInfo.self, from: data)
            #if os(iOS)
            IOSSubtitleIntelligence.rememberPlaybackMetadata(data, provider: "jellyfin", serverID: server.id.uuidString, itemID: itemId)
            #endif
            return result
        } catch {
            if let body = String(data: data, encoding: .utf8), !body.isEmpty {
                print("[Jellyfin] getPlaybackInfo decode failed body: \(body.prefix(300))")
            }
            throw JellyfinError.decodingError
        }
    }

    func externalSubtitleCandidates(
        server: ServerConfig,
        itemId: String,
        mediaSources: [JellyfinMediaSource],
        token: String,
        mediaSourceId: String? = nil
    ) -> [ExternalSubtitleCandidate] {
        var seen = Set<String>()
        let sources: [JellyfinMediaSource]
        if let mediaSourceId = mediaSourceId,
           !mediaSourceId.isEmpty,
           let matchedSource = mediaSources.first(where: { $0.id.caseInsensitiveCompare(mediaSourceId) == .orderedSame }) {
            sources = [matchedSource]
        } else {
            // Keep the preferred source first for ordering, but aggregate all sources
            // to avoid dropping externally deliverable subtitles from non-preferred sources.
            if let preferred = preferredPlaybackSource(from: mediaSources) {
                sources = [preferred] + mediaSources.filter { $0.id.caseInsensitiveCompare(preferred.id) != .orderedSame }
            } else {
                sources = mediaSources
            }
        }

        return sources.flatMap { source in
            (source.mediaStreams ?? []).compactMap { stream in
                guard isExternallyDeliverableSubtitle(stream) else { return nil }
                guard let url = subtitleURL(
                    server: server,
                    itemId: itemId,
                    mediaSourceId: source.id,
                    stream: stream,
                    token: token
                ) else {
                    return nil
                }

                let key = url.absoluteString
                guard seen.insert(key).inserted else { return nil }
                return ExternalSubtitleCandidate(
                    url: url,
                    displayName: subtitleDisplayName(stream: stream)
                )
            }
        }
    }

    func preferredPlaybackSource(
        from mediaSources: [JellyfinMediaSource],
        playbackQuality: RemotePlaybackQualityOption = .auto
    ) -> JellyfinMediaSource? {
        let pool: [JellyfinMediaSource]
        if playbackQuality.prefersConstrainedPlayback {
            let transcodingCandidates = mediaSources.filter { isTranscodingCapable($0) }
            pool = transcodingCandidates.isEmpty ? mediaSources : transcodingCandidates
        } else {
            let candidates = mediaSources.filter { playbackURLAvailabilityScore(for: $0) > 0 }
            pool = candidates.isEmpty ? mediaSources : candidates
        }

        return pool.max { lhs, rhs in
            let lhsScore = playbackSelectionScore(for: lhs, playbackQuality: playbackQuality)
            let rhsScore = playbackSelectionScore(for: rhs, playbackQuality: playbackQuality)
            if lhsScore == rhsScore {
                return playbackSelectionTrackCount(in: lhs.mediaStreams ?? []) < playbackSelectionTrackCount(in: rhs.mediaStreams ?? [])
            }
            return lhsScore < rhsScore
        } ?? mediaSources.first
    }

    func preferredPlaybackStreams(
        from mediaSources: [JellyfinMediaSource],
        playbackQuality: RemotePlaybackQualityOption = .auto
    ) -> [JellyfinMediaStream] {
        preferredPlaybackSource(from: mediaSources, playbackQuality: playbackQuality)?.mediaStreams ?? []
    }

    func qualityOptions(from mediaSources: [JellyfinMediaSource]) -> [RemotePlaybackQualityOption] {
        let maxWidth = mediaSources.compactMap { $0.videoStream?.width }.max()
        let maxHeight = mediaSources.compactMap { $0.videoStream?.height }.max()
        let supportsTranscoding = mediaSources.contains {
            $0.supportsTranscoding == true || (($0.transcodingUrl?.isEmpty == false))
        }
        return RemotePlaybackQualityCatalog.options(
            maxVideoWidth: maxWidth,
            maxVideoHeight: maxHeight,
            supportsTranscoding: supportsTranscoding
        )
    }

    func playbackMethod(
        for mediaSource: JellyfinMediaSource?,
        resolvedURL: URL?,
        playbackQuality: RemotePlaybackQualityOption
    ) -> RemotePlaybackMethod {
        let loweredURL = resolvedURL?.absoluteString.lowercased() ?? ""
        if loweredURL.contains("transcode") || loweredURL.contains("m3u8") {
            return .transcode
        }
        if playbackQuality.prefersConstrainedPlayback,
           mediaSource?.transcodingUrl?.isEmpty == false {
            return .transcode
        }
        if mediaSource?.directStreamUrl?.isEmpty == false {
            return .directStream
        }
        return .directPlay
    }
    
    // MARK: - Images
    
    /// Get primary image URL for an item
    func getImageURL(
        server: ServerConfig,
        itemId: String,
        imageType: String = "Primary",
        maxWidth: Int = 400,
        versionTag: String? = nil
    ) -> URL? {
        let baseURL = server.fullURL
        let formatQuery = (imageType == "Logo" || imageType == "Art") ? "&format=png" : ""
        var urlString = "\(baseURL)/Items/\(itemId)/Images/\(imageType)?maxWidth=\(maxWidth)\(formatQuery)"
        if let token = server.accessToken, !token.isEmpty {
            urlString += "&api_key=\(token)"
        }
        return URL(string: urlString).map {
            let runtimeURL = RuntimeNetworkAddressResolver.runtimeURL(from: $0)
            let cacheKey = MediaImageCacheIdentity.mediaServerImage(
                server: server,
                itemId: itemId,
                imageType: imageType,
                maxWidth: maxWidth,
                versionTag: versionTag
            )
            return MediaImageCacheIdentity.apply(cacheKey: cacheKey, to: runtimeURL)
        }
    }
    
    /// Get backdrop image URL
    func getBackdropURL(
        server: ServerConfig,
        itemId: String,
        maxWidth: Int = 1280,
        versionTag: String? = nil
    ) -> URL? {
        let baseURL = server.fullURL
        var urlString = "\(baseURL)/Items/\(itemId)/Images/Backdrop?maxWidth=\(maxWidth)"
        if let token = server.accessToken, !token.isEmpty {
            urlString += "&api_key=\(token)"
        }
        return URL(string: urlString).map {
            let runtimeURL = RuntimeNetworkAddressResolver.runtimeURL(from: $0)
            let cacheKey = MediaImageCacheIdentity.mediaServerImage(
                server: server,
                itemId: itemId,
                imageType: "Backdrop",
                maxWidth: maxWidth,
                versionTag: versionTag
            )
            return MediaImageCacheIdentity.apply(cacheKey: cacheKey, to: runtimeURL)
        }
    }

    func fetchSeekPreviewManifest(
        server: ServerConfig,
        itemId: String,
        userId: String?,
        token: String,
        mediaSourceId: String?,
        duration: TimeInterval?
    ) async -> MediaBrowserSeekPreviewManifest? {
        guard let url = seekPreviewItemDetailsURL(
            server: server,
            itemId: itemId,
            userId: userId,
            token: token
        ) else {
            return nil
        }

        do {
            var request = runtimeRequest(for: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8.0
            request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return MediaBrowserTrickplayManifestParser.parse(
                itemPayload: payload,
                preferredMediaSourceId: mediaSourceId,
                duration: duration
            )
        } catch {
            return nil
        }
    }

    func fetchSeekPreviewTileImage(
        server: ServerConfig,
        itemId: String,
        token: String,
        mediaSourceId: String?,
        width: Int,
        tileIndex: Int
    ) async -> UIImage? {
        guard let url = seekPreviewTileURL(
            server: server,
            itemId: itemId,
            token: token,
            mediaSourceId: mediaSourceId,
            width: width,
            tileIndex: tileIndex
        ) else {
            return nil
        }

        do {
            var request = runtimeRequest(for: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8.0
            request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            request.setValue("image/jpeg,image/*;q=0.9", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    func fetchSeekPreviewChapterImage(
        server: ServerConfig,
        itemId: String,
        token: String,
        chapterIndex: Int,
        imageTag: String?
    ) async -> UIImage? {
        guard let url = seekPreviewChapterImageURL(
            server: server,
            itemId: itemId,
            token: token,
            chapterIndex: chapterIndex,
            imageTag: imageTag
        ) else {
            return nil
        }

        do {
            var request = runtimeRequest(for: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 8.0
            request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            request.setValue("image/jpeg,image/*;q=0.9", forHTTPHeaderField: "Accept")

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    private func seekPreviewChapterImageURL(
        server: ServerConfig,
        itemId: String,
        token: String,
        chapterIndex: Int,
        imageTag: String?
    ) -> URL? {
        guard var components = URLComponents(
            string: "\(server.fullURL)/Items/\(itemId)/Images/Chapter/\(chapterIndex)"
        ) else {
            return nil
        }

        var queryItems = [
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "maxWidth", value: "480")
        ]
        if let tag = imageTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: tag))
        }
        components.queryItems = queryItems
        return components.url
    }

    private func isExternallyDeliverableSubtitle(_ stream: JellyfinMediaStream) -> Bool {
        let normalizedType = stream.type.lowercased()
        guard normalizedType == "subtitle" || normalizedType.contains("subtitle") || normalizedType.contains("caption") else {
            return false
        }

        if stream.isExternal == true {
            return true
        }
        if let deliveryUrl = stream.deliveryUrl, !deliveryUrl.isEmpty {
            return true
        }
        if let method = stream.deliveryMethod?.lowercased(), method.contains("external") {
            return true
        }
        return false
    }

    private func subtitleURL(
        server: ServerConfig,
        itemId: String,
        mediaSourceId: String,
        stream: JellyfinMediaStream,
        token: String
    ) -> URL? {
        if let rawDeliveryUrl = stream.deliveryUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawDeliveryUrl.isEmpty {
            return resolvedSubtitleURL(server: server, rawValue: rawDeliveryUrl, token: token)
        }

        guard let index = stream.index else { return nil }
        let codec = normalizedSubtitleFileExtension(from: stream.codec)
        return URL(string: "\(server.fullURL)/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(index)/Stream.\(codec)?api_key=\(token)")
    }

    private func resolvedSubtitleURL(server: ServerConfig, rawValue: String, token: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let baseURL = server.fullURL
        let absoluteString: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            absoluteString = trimmed
        } else if trimmed.hasPrefix("/") {
            absoluteString = "\(baseURL)\(trimmed)"
        } else {
            absoluteString = "\(baseURL)/\(trimmed)"
        }

        guard let url = URL(string: absoluteString),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return URL(string: absoluteString)
        }

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name.lowercased() == "api_key" }) {
            queryItems.append(URLQueryItem(name: "api_key", value: token))
        }
        components.queryItems = queryItems
        return components.url
    }

    private func seekPreviewItemDetailsURL(
        server: ServerConfig,
        itemId: String,
        userId: String?,
        token: String
    ) -> URL? {
        let baseURL = server.fullURL
        let path: String
        if let userId = userId?.trimmingCharacters(in: .whitespacesAndNewlines), !userId.isEmpty {
            path = "/Users/\(userId)/Items/\(itemId)"
        } else {
            path = "/Items/\(itemId)"
        }

        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "Fields", value: "Trickplay,MediaSources"),
            URLQueryItem(name: "api_key", value: token)
        ]
        return components.url
    }

    private func seekPreviewTileURL(
        server: ServerConfig,
        itemId: String,
        token: String,
        mediaSourceId: String?,
        width: Int,
        tileIndex: Int
    ) -> URL? {
        guard var components = URLComponents(
            string: "\(server.fullURL)/Videos/\(itemId)/Trickplay/\(width)/\(tileIndex).jpg"
        ) else {
            return nil
        }

        var queryItems = [URLQueryItem(name: "api_key", value: token)]
        if let mediaSourceId = mediaSourceId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !mediaSourceId.isEmpty {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
        }
        components.queryItems = queryItems
        return components.url
    }

    private func normalizedSubtitleFileExtension(from codec: String?) -> String {
        switch codec?.lowercased() {
        case "subrip":
            return "srt"
        case let value where value?.isEmpty == false:
            return value!
        default:
            return "srt"
        }
    }

    private func subtitleDisplayName(stream: JellyfinMediaStream) -> String {
        formattedSubtitleDisplayName(
            title: stream.displayTitle,
            alternateTitle: stream.title,
            displayLanguage: stream.displayLanguage,
            language: stream.language,
            codec: stream.codec,
            isDefault: stream.isDefault,
            isForced: stream.isForced
        )
    }

    private func formattedSubtitleDisplayName(
        title: String?,
        alternateTitle: String?,
        displayLanguage: String?,
        language: String?,
        codec: String?,
        isDefault: Bool?,
        isForced: Bool?
    ) -> String {
        let cleanedTitle = cleanedSubtitlePresentationMetadataValue(title)
        let cleanedAlternateTitle = cleanedSubtitlePresentationMetadataValue(alternateTitle)
        let cleanedDisplayLanguage = cleanedSubtitleLanguageMetadataValue(displayLanguage)
        let cleanedLanguage = cleanedSubtitleLanguageMetadataValue(language)
        let cleanedCodec = cleanedSubtitleMetadataValue(codec)?.uppercased()
        let normalizedTitle = normalizedSubtitleMetadataValue(cleanedTitle)

        var parts: [String] = []
        if let cleanedTitle,
           !cleanedTitle.isEmpty,
           !isGenericSubtitleDisplayTitle(cleanedTitle, codec: cleanedCodec) {
            parts.append(cleanedTitle)
        }

        if let cleanedAlternateTitle,
           !cleanedAlternateTitle.isEmpty,
           !normalizedTitle.contains(normalizedSubtitleMetadataValue(cleanedAlternateTitle)),
           !parts.contains(where: { normalizedSubtitleMetadataValue($0) == normalizedSubtitleMetadataValue(cleanedAlternateTitle) }),
           !isGenericSubtitleDisplayTitle(cleanedAlternateTitle, codec: cleanedCodec) {
            parts.append(cleanedAlternateTitle)
        }

        if let cleanedDisplayLanguage,
           !cleanedDisplayLanguage.isEmpty,
           !normalizedTitle.contains(normalizedSubtitleMetadataValue(cleanedDisplayLanguage)),
           !parts.contains(where: { normalizedSubtitleMetadataValue($0) == normalizedSubtitleMetadataValue(cleanedDisplayLanguage) }) {
            parts.append(cleanedDisplayLanguage)
        }

        if let cleanedLanguage,
           !cleanedLanguage.isEmpty,
           !normalizedTitle.contains(normalizedSubtitleMetadataValue(cleanedLanguage)),
           !parts.contains(where: { normalizedSubtitleMetadataValue($0) == normalizedSubtitleMetadataValue(cleanedLanguage) }) {
            parts.append(cleanedLanguage)
        }

        var flagParts: [String] = []
        if isDefault == true, !normalizedTitle.contains("default") {
            flagParts.append(NSLocalizedString("Default", comment: ""))
        }
        if isForced == true, !normalizedTitle.contains("forced") {
            flagParts.append(NSLocalizedString("Forced", comment: ""))
        }
        if !flagParts.isEmpty {
            parts.append(flagParts.joined(separator: " "))
        }

        if let cleanedCodec,
           !cleanedCodec.isEmpty,
           !normalizedTitle.contains(normalizedSubtitleMetadataValue(cleanedCodec)),
           !parts.contains(where: { normalizedSubtitleMetadataValue($0) == normalizedSubtitleMetadataValue(cleanedCodec) }) {
            parts.append(cleanedCodec)
        }

        if parts.isEmpty {
            return cleanedTitle
                ?? cleanedAlternateTitle
                ?? cleanedDisplayLanguage
                ?? cleanedLanguage
                ?? cleanedCodec
                ?? NSLocalizedString("Subtitle", comment: "")
        }
        return parts.joined(separator: " · ")
    }

    private func cleanedSubtitleMetadataValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func cleanedSubtitleLanguageMetadataValue(_ value: String?) -> String? {
        guard let cleaned = cleanedSubtitlePresentationMetadataValue(value) else { return nil }

        return cleaned
    }

    private func cleanedSubtitlePresentationMetadataValue(_ value: String?) -> String? {
        guard let cleaned = cleanedSubtitleMetadataValue(value) else { return nil }

        let lowered = cleaned
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let placeholderValues: Set<String> = [
            "und", "undefined", "unknown", "undetermined", "n/a", "na", "none", "null",
            "未定义", "未指定", "未知", "不明", "未設定", "未設置"
        ]

        return placeholderValues.contains(lowered) ? nil : cleaned
    }

    private func isGenericSubtitleDisplayTitle(_ title: String, codec: String?) -> Bool {
        var normalized = normalizedSubtitleMetadataValue(title)
        if let codec, !codec.isEmpty {
            normalized = normalized.replacingOccurrences(of: normalizedSubtitleMetadataValue(codec), with: "")
        }

        let genericTokens = ["default", "forced", "subtitle", "captions", "caption", "external", "internal"]
        genericTokens.forEach { token in
            normalized = normalized.replacingOccurrences(of: token, with: "")
        }
        return normalized.isEmpty
    }

    private func normalizedSubtitleMetadataValue(_ value: String?) -> String {
        guard let value = value?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased() else {
            return ""
        }
        return String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private func playbackSelectionTrackCount(in streams: [JellyfinMediaStream]) -> Int {
        streams.filter { stream in
            let type = stream.type.lowercased()
            return type == "audio"
                || type.contains("audio")
                || type == "subtitle"
                || type.contains("subtitle")
                || type.contains("caption")
        }.count
    }

    private func isTranscodingCapable(_ mediaSource: JellyfinMediaSource) -> Bool {
        if mediaSource.supportsTranscoding == true {
            return true
        }
        if let transcodingURL = mediaSource.transcodingUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !transcodingURL.isEmpty {
            return true
        }
        return false
    }

    private func playbackSelectionScore(
        for mediaSource: JellyfinMediaSource,
        playbackQuality: RemotePlaybackQualityOption
    ) -> Int {
        var score = playbackURLAvailabilityScore(for: mediaSource)
        if playbackQuality.prefersConstrainedPlayback {
            score += isTranscodingCapable(mediaSource) ? 1_000 : -1_000
        }
        return score
    }

    private func playbackURLAvailabilityScore(for mediaSource: JellyfinMediaSource) -> Int {
        var score = 0
        if let directStreamURL = mediaSource.directStreamUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directStreamURL.isEmpty {
            score += 100
        }
        if let path = mediaSource.path?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            score += 10
        }
        return score
    }

    private func resolvedDirectStreamURL(
        server: ServerConfig,
        token: String,
        mediaSource: JellyfinMediaSource
    ) -> URL? {
        guard let rawValue = mediaSource.directStreamUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        let absoluteString: String
        if rawValue.hasPrefix("http://") || rawValue.hasPrefix("https://") {
            absoluteString = rawValue
        } else if rawValue.hasPrefix("/") {
            absoluteString = "\(server.fullURL)\(rawValue)"
        } else {
            absoluteString = "\(server.fullURL)/\(rawValue)"
        }

        guard let url = URL(string: absoluteString),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return URL(string: absoluteString)
        }

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name.lowercased() == "api_key" }) {
            queryItems.append(URLQueryItem(name: "api_key", value: token))
        }
        if !queryItems.contains(where: { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame }),
           !mediaSource.id.isEmpty {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSource.id))
        }
        components.queryItems = queryItems
        return components.url
    }

    private func resolvedTranscodingURL(
        server: ServerConfig,
        token: String,
        mediaSource: JellyfinMediaSource,
        playbackQuality: RemotePlaybackQualityOption
    ) -> URL? {
        guard let rawValue = mediaSource.transcodingUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }

        let absoluteString: String
        if rawValue.hasPrefix("http://") || rawValue.hasPrefix("https://") {
            absoluteString = rawValue
        } else if rawValue.hasPrefix("/") {
            absoluteString = "\(server.fullURL)\(rawValue)"
        } else {
            absoluteString = "\(server.fullURL)/\(rawValue)"
        }

        guard let url = URL(string: absoluteString),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return URL(string: absoluteString)
        }

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name.lowercased() == "api_key" }) {
            queryItems.append(URLQueryItem(name: "api_key", value: token))
        }
        queryItems = appendedPlaybackQualityQueryItems(queryItems, for: playbackQuality)
        components.queryItems = queryItems
        return components.url
    }

    private func manualTranscodingURL(
        server: ServerConfig,
        itemId: String,
        token: String,
        mediaSource: JellyfinMediaSource,
        playbackQuality: RemotePlaybackQualityOption,
        playSessionId: String?
    ) -> URL? {
        manualTranscodingURL(
            server: server,
            itemId: itemId,
            token: token,
            mediaSourceId: mediaSource.id,
            playbackQuality: playbackQuality,
            playSessionId: playSessionId
        )
    }

    private func manualTranscodingURL(
        server: ServerConfig,
        itemId: String,
        token: String,
        mediaSourceId: String,
        playbackQuality: RemotePlaybackQualityOption,
        playSessionId: String?
    ) -> URL? {
        guard playbackQuality.prefersConstrainedPlayback else {
            return nil
        }

        guard var components = URLComponents(string: "\(server.fullURL)/Videos/\(itemId)/master.m3u8") else {
            return nil
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "MediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "Container", value: "ts"),
            URLQueryItem(name: "TranscodingContainer", value: "ts"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "VideoCodec", value: "h264"),
            URLQueryItem(name: "AudioCodec", value: "aac,mp3,ac3,eac3"),
            URLQueryItem(name: "api_key", value: token)
        ]
        if let playSessionId, !playSessionId.isEmpty {
            queryItems.append(URLQueryItem(name: "PlaySessionId", value: playSessionId))
        }
        queryItems = appendedPlaybackQualityQueryItems(queryItems, for: playbackQuality)
        components.queryItems = queryItems
        return components.url
    }

    private func appendedPlaybackQualityQueryItems(
        _ queryItems: [URLQueryItem],
        for quality: RemotePlaybackQualityOption
    ) -> [URLQueryItem] {
        var updated = queryItems
        let containsKey: (String) -> Bool = { key in
            updated.contains(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })
        }

        if let maxStreamingBitrate = quality.maxStreamingBitrate {
            if !containsKey("MaxStreamingBitrate") {
                updated.append(URLQueryItem(name: "MaxStreamingBitrate", value: String(maxStreamingBitrate)))
            }
            if !containsKey("VideoBitrate") {
                updated.append(URLQueryItem(name: "VideoBitrate", value: String(maxStreamingBitrate)))
            }
        }
        if let maxWidth = quality.maxWidth, !containsKey("MaxWidth") {
            updated.append(URLQueryItem(name: "MaxWidth", value: String(maxWidth)))
        }
        if let maxHeight = quality.maxHeight, !containsKey("MaxHeight") {
            updated.append(URLQueryItem(name: "MaxHeight", value: String(maxHeight)))
        }
        return updated
    }

    private func playbackInfoRequestBody(
        for quality: RemotePlaybackQualityOption,
        userId: String
    ) -> [String: Any] {
        var body: [String: Any] = [
            "UserId": userId,
            "IsPlayback": true,
            "AutoOpenLiveStream": true,
            "EnableDirectPlay": quality.allowsDirectPlay,
            "EnableDirectStream": quality.allowsDirectStream,
            "EnableTranscoding": quality.allowsTranscoding,
            "DeviceProfile": playbackDeviceProfile(for: quality)
        ]

        if quality.prefersConstrainedPlayback {
            body["AllowVideoStreamCopy"] = false
            body["AllowAudioStreamCopy"] = false
        }
        if let maxStreamingBitrate = quality.maxStreamingBitrate {
            body["MaxStreamingBitrate"] = maxStreamingBitrate
        }
        if let maxWidth = quality.maxWidth {
            body["MaxWidth"] = maxWidth
        }
        if let maxHeight = quality.maxHeight {
            body["MaxHeight"] = maxHeight
        }

        return body
    }

    private func playbackDeviceProfile(for quality: RemotePlaybackQualityOption) -> [String: Any] {
        var profile: [String: Any] = [
            "Name": clientName,
            "Id": deviceId,
            "MaxStaticBitrate": 200_000_000,
            "MaxStreamingBitrate": 200_000_000,
            "MusicStreamingTranscodingBitrate": 192_000,
            "DirectPlayProfiles": [
                [
                    "Type": "Video",
                    "Container": "mp4,mkv,mov,m4v,ts,mpegts,webm,avi"
                ],
                [
                    "Type": "Audio",
                    "Container": "mp3,flac,aac,m4a,ogg,wav"
                ]
            ],
            "TranscodingProfiles": [
                [
                    "Type": "Video",
                    "Container": "ts",
                    "Protocol": "hls",
                    "Context": "Streaming",
                    "VideoCodec": "h264",
                    "AudioCodec": "aac,mp3,ac3,eac3",
                    "MaxAudioChannels": "6",
                    "MinSegments": 1,
                    "BreakOnNonKeyFrames": false,
                    "CopyTimestamps": true
                ]
            ],
            "SubtitleProfiles": [
                [
                    "Format": "vtt",
                    "Method": "Hls"
                ],
                [
                    "Format": "srt",
                    "Method": "External"
                ],
                [
                    "Format": "ass",
                    "Method": "External"
                ],
                [
                    "Format": "ssa",
                    "Method": "External"
                ]
            ],
            "CodecProfiles": playbackCodecProfiles(for: quality)
        ]

        if let maxWidth = quality.maxWidth {
            profile["MaxStaticWidth"] = maxWidth
        }
        if let maxHeight = quality.maxHeight {
            profile["MaxStaticHeight"] = maxHeight
        }

        return profile
    }

    private func playbackCodecProfiles(for quality: RemotePlaybackQualityOption) -> [[String: Any]] {
        var conditions: [[String: Any]] = []
        if let maxWidth = quality.maxWidth {
            conditions.append([
                "Condition": "LessThanEqual",
                "Property": "Width",
                "Value": String(maxWidth),
                "IsRequired": false
            ])
        }
        if let maxHeight = quality.maxHeight {
            conditions.append([
                "Condition": "LessThanEqual",
                "Property": "Height",
                "Value": String(maxHeight),
                "IsRequired": false
            ])
        }

        guard !conditions.isEmpty else {
            return []
        }

        return [
            [
                "Type": "Video",
                "Conditions": conditions
            ],
            [
                "Type": "Video",
                "Codec": "h264",
                "Conditions": conditions
            ],
            [
                "Type": "Video",
                "Codec": "hevc",
                "Conditions": conditions
            ]
        ]
    }

    private func playbackClientQueryItems(token: String) -> [URLQueryItem] {
        let language = Locale.preferredLanguages.first ?? "en"
        return [
            URLQueryItem(name: "X-Emby-Client", value: clientName),
            URLQueryItem(name: "X-Emby-Device-Name", value: deviceName),
            URLQueryItem(name: "X-Emby-Device-Id", value: deviceId),
            URLQueryItem(name: "X-Emby-Client-Version", value: clientVersion),
            URLQueryItem(name: "X-Emby-Token", value: token),
            URLQueryItem(name: "X-Emby-Language", value: language),
            URLQueryItem(name: "reqformat", value: "json")
        ]
    }
    
    // MARK: - Progress Reporting
    
    /// Report playback started
    func reportPlaying(server: ServerConfig, itemId: String, userId: String, token: String, positionTicks: Int64 = 0, playSessionId: String? = nil, mediaSourceId: String? = nil, playMethod: String = "DirectPlay") async throws {
        let baseURL = server.fullURL
        guard var components = URLComponents(string: "\(baseURL)/Sessions/Playing") else {
            throw JellyfinError.invalidURL
        }
        var queryItems = playbackClientQueryItems(token: token)
        if !queryItems.contains(where: { $0.name == "api_key" }) {
            queryItems.append(URLQueryItem(name: "api_key", value: token))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.httpMethod = "POST"
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue(authHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "CanSeek": true,
            "IsPaused": false,
            "PlayMethod": playMethod
        ]
        if !userId.isEmpty {
            body["UserId"] = userId
        }
        if !deviceId.isEmpty {
            body["DeviceId"] = deviceId
        }
        if !clientName.isEmpty {
            body["Client"] = clientName
        }
        if let playSessionId, !playSessionId.isEmpty {
            body["PlaySessionId"] = playSessionId
        }
        if let mediaSourceId, !mediaSourceId.isEmpty {
            body["MediaSourceId"] = mediaSourceId
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await performPlaybackReport(request, endpoint: "Playing")
    }
    
    /// Report playback progress to server
    func reportProgress(server: ServerConfig, itemId: String, userId: String, token: String, positionTicks: Int64, isPaused: Bool, eventName: String? = nil, playSessionId: String? = nil, mediaSourceId: String? = nil, playMethod: String = "DirectPlay") async throws {
        let baseURL = server.fullURL
        guard var components = URLComponents(string: "\(baseURL)/Sessions/Playing/Progress") else {
            throw JellyfinError.invalidURL
        }
        var queryItems = playbackClientQueryItems(token: token)
        if !queryItems.contains(where: { $0.name == "api_key" }) {
            queryItems.append(URLQueryItem(name: "api_key", value: token))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.httpMethod = "POST"
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue(authHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "IsPaused": isPaused,
            "CanSeek": true,
            "PlayMethod": playMethod
        ]
        if !userId.isEmpty {
            body["UserId"] = userId
        }
        if !deviceId.isEmpty {
            body["DeviceId"] = deviceId
        }
        if !clientName.isEmpty {
            body["Client"] = clientName
        }
        if let eventName, !eventName.isEmpty {
            body["EventName"] = eventName
        }
        if let playSessionId, !playSessionId.isEmpty {
            body["PlaySessionId"] = playSessionId
        }
        if let mediaSourceId, !mediaSourceId.isEmpty {
            body["MediaSourceId"] = mediaSourceId
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await performPlaybackReport(request, endpoint: "Progress")
    }
    
    /// Report playback stopped
    func reportStopped(server: ServerConfig, itemId: String, userId: String, token: String, positionTicks: Int64, playSessionId: String? = nil, mediaSourceId: String? = nil, playMethod: String = "DirectPlay") async throws {
        let baseURL = server.fullURL
        guard var components = URLComponents(string: "\(baseURL)/Sessions/Playing/Stopped") else {
            throw JellyfinError.invalidURL
        }
        var queryItems = playbackClientQueryItems(token: token)
        if !queryItems.contains(where: { $0.name == "api_key" }) {
            queryItems.append(URLQueryItem(name: "api_key", value: token))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.httpMethod = "POST"
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue(authHeader(token: token), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "CanSeek": true,
            "PlayMethod": playMethod
        ]
        if !userId.isEmpty {
            body["UserId"] = userId
        }
        if !deviceId.isEmpty {
            body["DeviceId"] = deviceId
        }
        if !clientName.isEmpty {
            body["Client"] = clientName
        }
        if let playSessionId, !playSessionId.isEmpty {
            body["PlaySessionId"] = playSessionId
        }
        if let mediaSourceId, !mediaSourceId.isEmpty {
            body["MediaSourceId"] = mediaSourceId
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        try await performPlaybackReport(request, endpoint: "Stopped")
    }
    
    // MARK: - TV Shows & Playlists
    
    func getSeasons(server: ServerConfig, userId: String, token: String, seriesId: String) async throws -> [JellyfinItem] {
        let itemsResponse = try await getItems(server: server, userId: userId, token: token, libraryId: seriesId, includeTypes: ["Season"])
        return itemsResponse.items
    }
    
    func getEpisodes(server: ServerConfig, userId: String, token: String, seriesId: String, seasonId: String) async throws -> [JellyfinItem] {
        // Use the generic /Items endpoint with SeasonId as ParentId, which is more robust
        let response = try await getItems(
            server: server,
            userId: userId,
            token: token,
            libraryId: seasonId,
            includeTypes: ["Episode"],
            sortBy: "IndexNumber"
        )
        return response.items
    }
    
    func getPlaylistItems(server: ServerConfig, userId: String, token: String, playlistId: String) async throws -> [JellyfinItem] {
        let baseURL = server.fullURL
        let fields = "Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,ChildCount,RecursiveItemCount,Genres,ProviderIds,PrimaryImageTag,ImageTags,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ParentThumbItemId,ParentThumbImageTag,ProductionYear,CommunityRating,OfficialRating,RunTimeTicks,IndexNumber,ParentIndexNumber"
        guard let url = URL(string: "\(baseURL)/Playlists/\(playlistId)/Items?UserId=\(userId)&Fields=\(fields)") else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw JellyfinError.unauthorized
        }
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        return response.items
    }
    
    func getPagedPlaylistItems(server: ServerConfig, userId: String, token: String, playlistId: String, startIndex: Int = 0, limit: Int = 100) async throws -> JellyfinItemsResponse {
        let baseURL = server.fullURL
        let fields = "Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,ChildCount,RecursiveItemCount,Genres,ProviderIds,PrimaryImageTag,ImageTags,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ParentThumbItemId,ParentThumbImageTag,ProductionYear,CommunityRating,OfficialRating,RunTimeTicks,IndexNumber,ParentIndexNumber"
        guard let url = URL(string: "\(baseURL)/Playlists/\(playlistId)/Items?UserId=\(userId)&Fields=\(fields)&StartIndex=\(startIndex)&Limit=\(limit)") else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw JellyfinError.unauthorized
        }
        return try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
    }

    func getDirectChildren(server: ServerConfig, userId: String, token: String, parentId: String, recursive: Bool = false) async throws -> [JellyfinItem] {
        let response = try await getItems(
            server: server,
            userId: userId,
            token: token,
            libraryId: parentId,
            sortBy: "SortName",
            sortOrder: "Ascending",
            limit: 200,
            recursive: recursive
        )
        return response.items
    }
    
    /// Get favorite items
    func getFavorites(server: ServerConfig, userId: String, token: String, limit: Int = 50) async throws -> [JellyfinItem] {
        let baseURL = server.fullURL
        let urlString = "\(baseURL)/Users/\(userId)/Items?Recursive=true&Filters=IsFavorite&Fields=Overview,MediaSources,UserData,Genres,ProviderIds&Limit=\(limit)"
        
        guard let url = URL(string: urlString) else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw JellyfinError.unauthorized
        }
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        return response.items
    }
    
    /// Search items
    func searchItems(server: ServerConfig, userId: String, token: String, query: String, limit: Int = 50) async throws -> [JellyfinItem] {
        let baseURL = server.fullURL
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "\(baseURL)/Users/\(userId)/Items?Recursive=true&SearchTerm=\(encodedQuery)&Fields=Overview,MediaSources,UserData,Genres,ProviderIds&Limit=\(limit)"
        
        guard let url = URL(string: urlString) else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw JellyfinError.unauthorized
        }
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        return response.items
    }
    
    /// Toggle favorite status
    func toggleFavorite(server: ServerConfig, itemId: String, userId: String, token: String, isFavorite: Bool) async throws {
        let baseURL = server.fullURL
        let method = isFavorite ? "POST" : "DELETE"
        let urlString = "\(baseURL)/Users/\(userId)/FavoriteItems/\(itemId)"
        
        guard let url = URL(string: urlString) else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.httpMethod = method
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let _ = try await session.data(for: request)
    }

    /// Toggle played (watched) status
    func togglePlayed(server: ServerConfig, itemId: String, userId: String, token: String, isPlayed: Bool) async throws {
        let baseURL = server.fullURL
        let method = isPlayed ? "POST" : "DELETE"
        let urlString = "\(baseURL)/Users/\(userId)/PlayedItems/\(itemId)"

        guard let url = URL(string: urlString) else {
            throw JellyfinError.invalidURL
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = method
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw JellyfinError.serverError(httpResponse.statusCode)
        }
    }

    /// Delete item from server
    func deleteItem(server: ServerConfig, itemId: String, token: String) async throws {
        let baseURL = server.fullURL
        let urlString = "\(baseURL)/Items/\(itemId)"

        guard let url = URL(string: urlString) else {
            throw JellyfinError.invalidURL
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = "DELETE"
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw JellyfinError.serverError(httpResponse.statusCode)
        }
    }
    
    // MARK: - Metadata (People & Similar)
    
    /// Get people associated with an item
    /// Get people associated with an item
    func getPeople(server: ServerConfig, itemId: String, token: String) async throws -> [JellyfinPerson] {
        let baseURL = server.fullURL
        
        // Use the Item details endpoint with Fields=People because /Items/{Id}/People (404s)
        let userId = server.userId ?? ""
        let endpoint = userId.isEmpty ? "/Items/\(itemId)" : "/Users/\(userId)/Items/\(itemId)"
        
        guard let url = URL(string: "\(baseURL)\(endpoint)?Fields=People,PrimaryImageAspectRatio") else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        do {
            let (data, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("[Jellyfin] GetPeople (ItemDetails) Status: \(httpResponse.statusCode)")
            }
            
            // Decode as full item to get people
            let item = try JSONDecoder().decode(JellyfinItem.self, from: data)
            let people = item.people ?? []
            print("[Jellyfin] Loaded \(people.count) people via Item Details for \(itemId)")
            return people
        } catch {
            print("[Jellyfin] Error loading people via Item Details: \(error)")
            throw error
        }
    }
    
    /// Get items for a specific person
    func getPersonItems(
        server: ServerConfig,
        personId: String,
        userId: String,
        token: String,
        sortBy: String = "DateCreated",
        sortOrder: String = "Descending",
        startIndex: Int = 0,
        limit: Int = 50
    ) async throws -> [JellyfinItem] {
        let baseURL = server.fullURL
        let fields = "Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,ChildCount,RecursiveItemCount,Genres,ProviderIds,PrimaryImageTag,ImageTags,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ParentThumbItemId,ParentThumbImageTag,ProductionYear,PremiereDate,CommunityRating,OfficialRating,RunTimeTicks,IndexNumber,ParentIndexNumber"
        let urlString = "\(baseURL)/Users/\(userId)/Items?Recursive=true&PersonIds=\(personId)&Fields=\(fields)&StartIndex=\(startIndex)&Limit=\(limit)&SortBy=\(sortBy)&SortOrder=\(sortOrder)"
        
        guard let url = URL(string: urlString) else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        return response.items
    }
    
    /// Get similar items
    func getSimilarItems(server: ServerConfig, itemId: String, userId: String, token: String, limit: Int = 12) async throws -> [JellyfinItem] {
        let baseURL = server.fullURL
        guard let url = URL(string: "\(baseURL)/Items/\(itemId)/Similar?UserId=\(userId)&Limit=\(limit)&Fields=Overview,MediaSources,UserData,Genres,ProviderIds") else {
            throw JellyfinError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, _) = try await session.data(for: request)
        let response = try JSONDecoder().decode(JellyfinItemsResponse.self, from: data)
        return response.items
    }

    /// Get one item detail for history-image fallback resolution.
    /// Uses the same image-related fields as home Continue Watching cards.
    func getItemDetails(server: ServerConfig, itemId: String, token: String) async throws -> JellyfinItem {
        let baseURL = server.fullURL
        let fields = "Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,Genres,ProviderIds,PrimaryImageTag,ImageTags,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ParentThumbItemId,ParentThumbImageTag,ProductionYear,IndexNumber,ParentIndexNumber,PremiereDate,EndDate,ProductionLocations,HomePageUrl"
        let userId = server.userId ?? ""
        let endpoint = userId.isEmpty ? "/Items/\(itemId)" : "/Users/\(userId)/Items/\(itemId)"

        guard let url = URL(string: "\(baseURL)\(endpoint)?Fields=\(fields)") else {
            throw JellyfinError.invalidURL
        }

        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw JellyfinError.unauthorized
        }
        guard httpResponse.statusCode == 200 else {
            throw JellyfinError.serverError(httpResponse.statusCode)
        }

        do {
            let result = try JSONDecoder().decode(JellyfinItem.self, from: data)
            #if os(iOS)
            IOSSubtitleIntelligence.rememberPlaybackMetadata(data, provider: "jellyfin", serverID: server.id.uuidString, itemID: itemId)
            #endif
            return result
        } catch {
            throw JellyfinError.decodingError
        }
    }

    private func fetchItems(url: URL, token: String) async throws -> [JellyfinItem] {
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            throw JellyfinError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw JellyfinError.serverError(httpResponse.statusCode)
        }

        do {
            return try JSONDecoder().decode(JellyfinItemsResponse.self, from: data).items
        } catch {
            throw JellyfinError.decodingError
        }
    }

    private func performPlaybackReport(_ request: URLRequest, endpoint: String) async throws {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw JellyfinError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw JellyfinError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let body = String(data: data, encoding: .utf8), !body.isEmpty {
                print("[Jellyfin] report\(endpoint) failed body: \(body.prefix(300))")
            }
            if let requestURL = request.url?.absoluteString {
                print("[Jellyfin] report\(endpoint) failed url: \(requestURL)")
            }
            if let requestBody = request.httpBody,
               let requestBodyString = String(data: requestBody, encoding: .utf8),
               !requestBodyString.isEmpty {
                print("[Jellyfin] report\(endpoint) failed requestBody: \(requestBodyString.prefix(500))")
            }
            throw JellyfinError.serverError(httpResponse.statusCode)
        }
    }
}

// MARK: - Errors

enum JellyfinError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case serverError(Int)
    case decodingError
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return NSLocalizedString("Invalid server URL", comment: "")
        case .invalidResponse:
            return NSLocalizedString("Invalid server response", comment: "")
        case .unauthorized:
            return NSLocalizedString("Invalid username or password", comment: "")
        case .serverError(let code):
            return String(format: NSLocalizedString("Server error: %d", comment: ""), code)
        case .decodingError:
            return NSLocalizedString("Failed to parse server response", comment: "")
        }
    }
}
