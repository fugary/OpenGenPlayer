import Foundation
#if os(iOS)
import UIKit
import GenPlayerShell
#endif

class EmbyService {
    
    static let shared = EmbyService()
    
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
        if let keychainId = KeychainService.get(for: "EmbyDeviceId") {
            self.deviceId = keychainId
        } else if let storedId = UserDefaults.standard.string(forKey: "EmbyDeviceId") {
            self.deviceId = storedId
            _ = KeychainService.set(storedId, for: "EmbyDeviceId")
        } else {
            let newId = UUID().uuidString
            _ = KeychainService.set(newId, for: "EmbyDeviceId")
            UserDefaults.standard.set(newId, forKey: "EmbyDeviceId")
            self.deviceId = newId
        }
        
#if os(iOS)
        self.deviceName = UIDevice.current.name
#else
        self.deviceName = ProcessInfo.processInfo.hostName
#endif
    }
    
    // MARK: - Auth Header
    
    private func authHeader(token: String? = nil) -> String {
        var parts = [
            "Client=\"\(clientName)\"",
            "Device=\"\(deviceName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? deviceName)\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(clientVersion)\""
        ]
        // Emby authentication header format
        // Authorization: MediaBrowser Client="...", Device="...", DeviceId="...", Version="...", UserId="..."
        // Token typically goes in X-Emby-Token header, but MediaBrowser header is also supported.
        // Let's stick to the Jellyfin style first as they are similar.
        if let token = token {
            parts.append("Token=\"\(token)\"")
        }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }

    private func runtimeRequest(for url: URL) -> URLRequest {
        URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
    }
    
    // MARK: - Authentication
    
    func login(server: ServerConfig, username: String, password: String) async throws -> EmbyAuthResult {
        let baseURL = server.fullURL
        let urlString = "\(baseURL)/Users/AuthenticateByName"
        print("[Emby] Login URL: \(urlString)")
        
        guard let url = URL(string: urlString) else {
            throw EmbyError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authHeader(), forHTTPHeaderField: "Authorization")
        
        let body = EmbyAuthRequest(username: username, pw: password)
        request.httpBody = try JSONEncoder().encode(body)
        
        do {
            let (data, response) = try await session.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw EmbyError.invalidResponse
            }
            
            if httpResponse.statusCode == 401 {
                throw EmbyError.unauthorized
            }
            
            guard httpResponse.statusCode == 200 else {
                throw EmbyError.serverError(httpResponse.statusCode)
            }
            
            let result = try JSONDecoder().decode(EmbyAuthResult.self, from: data)
            print("[Emby] Login success, userId: \(result.user.id)")
            return result
        } catch let error as EmbyError {
            throw error
        } catch {
            print("[Emby] Network error: \(error)")
            throw error
        }
    }
    
    // MARK: - Libraries
    
    func getLibraries(server: ServerConfig, userId: String, token: String) async throws -> [EmbyLibrary] {
        let baseURL = server.fullURL
        guard let url = URL(string: "\(baseURL)/Users/\(userId)/Views") else {
            throw EmbyError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        do {
            let (data, rawResponse) = try await session.data(for: request)
            if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
                throw EmbyError.unauthorized
            }
            let response = try JSONDecoder().decode(EmbyViewsResponse.self, from: data)
            return response.items
        } catch {
            throw error
        }
    }
    
    func getLibraryItems(server: ServerConfig, userId: String, token: String, parentId: String) async throws -> [EmbyItem] {
        let response = try await getItems(
            server: server,
            userId: userId,
            token: token,
            libraryId: parentId,
            limit: 100 // Fetch reasonably large number for now
        )
        return response.items
    }

    /// Get total count of items in a library
    func getLibraryItemCount(server: ServerConfig, userId: String, token: String, libraryId: String, libraryType: EmbyLibrary.LibraryType? = nil) async -> Int? {
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
    
    func getLatestItems(server: ServerConfig, userId: String, token: String, libraryId: String, limit: Int = 20) async throws -> [EmbyItem] {
        let baseURL = server.fullURL
        guard let url = URL(string: "\(baseURL)/Users/\(userId)/Items/Latest?ParentId=\(libraryId)&Limit=\(limit)&Fields=Overview,MediaSources,UserData,Genres,ProviderIds") else {
            throw EmbyError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await session.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw EmbyError.unauthorized
        }
        let items = try JSONDecoder().decode([EmbyItem].self, from: data)
        return items
    }

    func getHomeShelfItems(
        server: ServerConfig,
        userId: String,
        token: String,
        library: EmbyLibrary,
        limit: Int = 18
    ) async throws -> [EmbyItem] {
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
    
    func getItems(server: ServerConfig, userId: String, token: String, libraryId: String? = nil,
                  includeTypes: [String]? = nil, searchTerm: String? = nil,
                  sortBy: String = "SortName", sortOrder: String = "Ascending",
                  genres: String? = nil, years: String? = nil,
                  startIndex: Int = 0, limit: Int = 50, recursive: Bool = true) async throws -> EmbyItemsResponse {
        let baseURL = server.fullURL
        var urlString = "\(baseURL)/Users/\(userId)/Items?Recursive=\(recursive ? "true" : "false")&Fields=Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,ChildCount,RecursiveItemCount,Genres,ProviderIds,PrimaryImageTag,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ProductionYear,PremiereDate,CommunityRating,OfficialRating,RunTimeTicks,IndexNumber,ParentIndexNumber&SortBy=\(sortBy)&SortOrder=\(sortOrder)&StartIndex=\(startIndex)&Limit=\(limit)"
        
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
            throw EmbyError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw EmbyError.unauthorized
        }
        let response = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
        return response
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

    func getContinueWatching(server: ServerConfig, userId: String, token: String, limit: Int = 12) async throws -> [EmbyItem] {
        let baseURL = server.fullURL
        let fields = "Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,Genres,ProviderIds,PrimaryImageTag,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ProductionYear,OfficialRating,IndexNumber,ParentIndexNumber,ChildCount,RecursiveItemCount"
        guard let url = URL(string: "\(baseURL)/Users/\(userId)/Items/Resume?Limit=\(limit)&Fields=\(fields)&MediaTypes=Video") else {
            throw EmbyError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw EmbyError.unauthorized
        }
        let response = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
        return response.items
    }
    
    func getNextUp(
        server: ServerConfig,
        userId: String,
        token: String,
        limit: Int = 12,
        seriesId: String? = nil
    ) async throws -> [EmbyItem] {
        let baseURL = server.fullURL
        guard var components = URLComponents(string: "\(baseURL)/Shows/NextUp") else {
            throw EmbyError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(
                name: "Fields",
                value: "Overview,MediaSources,UserData,SeriesId,SeasonId,Genres,ProviderIds"
            )
        ]
        if let seriesId, !seriesId.isEmpty {
            queryItems.append(URLQueryItem(name: "SeriesId", value: seriesId))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw EmbyError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw EmbyError.unauthorized
        }
        let response = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
        if let seriesId, !seriesId.isEmpty {
            return response.items.filter { $0.seriesId == seriesId }
        }
        return response.items
    }
    
    // MARK: - Images
    
    func getImageURL(
        server: ServerConfig,
        itemId: String,
        imageType: String = "Primary",
        maxWidth: Int? = nil,
        maxHeight: Int? = nil,
        quality: Int? = nil,
        versionTag: String? = nil
    ) -> URL? {
        let baseURL = server.fullURL
        let urlString = "\(baseURL)/Items/\(itemId)/Images/\(imageType)"
        
        var queryItems: [URLQueryItem] = []
        if let versionTag = versionTag?.trimmingCharacters(in: .whitespacesAndNewlines),
           !versionTag.isEmpty {
            queryItems.append(URLQueryItem(name: "Tag", value: versionTag))
        }
        if imageType == "Logo" || imageType == "Art" {
            queryItems.append(URLQueryItem(name: "Format", value: "png"))
        }
        if let maxWidth = maxWidth {
            queryItems.append(URLQueryItem(name: "MaxWidth", value: String(maxWidth)))
        }
        if let maxHeight = maxHeight {
            queryItems.append(URLQueryItem(name: "MaxHeight", value: String(maxHeight)))
        }
        if let quality = quality {
            queryItems.append(URLQueryItem(name: "Quality", value: String(quality)))
        }
        
        if let token = server.accessToken {
            queryItems.append(URLQueryItem(name: "api_key", value: token))
        }
        
        guard var components = URLComponents(string: urlString) else {
            return URL(string: urlString)
        }
        
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        
        return components.url.map {
            let runtimeURL = RuntimeNetworkAddressResolver.runtimeURL(from: $0)
            let cacheKey = MediaImageCacheIdentity.mediaServerImage(
                server: server,
                itemId: itemId,
                imageType: imageType,
                maxWidth: maxWidth,
                maxHeight: maxHeight,
                quality: quality,
                versionTag: versionTag
            )
            return MediaImageCacheIdentity.apply(cacheKey: cacheKey, to: runtimeURL)
        }
    }
    
    func getBackdropURL(server: ServerConfig, itemId: String, versionTag: String? = nil) -> URL? {
        return getImageURL(
            server: server,
            itemId: itemId,
            imageType: "Backdrop",
            maxWidth: 1920,
            versionTag: versionTag
        )
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
            URLQueryItem(name: "Fields", value: "Trickplay,MediaSources,Chapters"),
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

    // MARK: - Playback
    
    func getPlaybackInfo(
        server: ServerConfig,
        itemId: String,
        userId: String,
        token: String,
        playbackQuality: RemotePlaybackQualityOption = .auto,
        startTimeTicks: Int64? = nil,
        mediaSourceId: String? = nil,
        currentPlaySessionId: String? = nil
    ) async throws -> EmbyPlaybackInfo {
        let baseURL = server.fullURL
        guard var components = URLComponents(string: "\(baseURL)/Items/\(itemId)/PlaybackInfo") else {
            throw EmbyError.invalidURL
        }
        
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "UserId", value: userId),
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "AutoOpenLiveStream", value: "true")
        ]
        
        if let startTimeTicks, startTimeTicks > 0 {
            queryItems.append(URLQueryItem(name: "StartTimeTicks", value: String(startTimeTicks)))
        }
        if let mediaSourceId, !mediaSourceId.isEmpty {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
        }
        if let psid = currentPlaySessionId, !psid.isEmpty {
            queryItems.append(URLQueryItem(name: "PlaySessionId", value: psid))
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
            throw EmbyError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.httpMethod = "POST"
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        var body = playbackInfoRequestBody(for: playbackQuality, userId: userId)
        if let psid = currentPlaySessionId, !psid.isEmpty {
            body["CurrentPlaySessionId"] = psid
        }
        if let mediaSourceId, !mediaSourceId.isEmpty {
            body["MediaSourceId"] = mediaSourceId
        }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        if playbackQuality.prefersConstrainedPlayback {
            print(
                "[Emby] PlaybackInfo request quality=\(playbackQuality.id) " +
                "bitrate=\(playbackQuality.maxStreamingBitrate ?? 0) " +
                "size=\(playbackQuality.maxWidth ?? 0)x\(playbackQuality.maxHeight ?? 0) " +
                "mediaSourceId=\(mediaSourceId ?? "nil") playSessionId=\(currentPlaySessionId ?? "nil")"
            )
        }
        
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbyError.invalidResponse
        }
        
        if httpResponse.statusCode == 401 {
            throw EmbyError.unauthorized
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw EmbyError.serverError(httpResponse.statusCode)
        }
        
        guard !data.isEmpty else {
            return EmbyPlaybackInfo(mediaSources: [], playSessionId: nil)
        }
        
        let result = try JSONDecoder().decode(EmbyPlaybackInfo.self, from: data)
        #if os(iOS)
        IOSSubtitleIntelligence.rememberPlaybackMetadata(data, provider: "emby", serverID: server.id.uuidString, itemID: itemId)
        #endif
        return result
    }
    
    func getStreamURL(
        server: ServerConfig,
        itemId: String,
        token: String,
        mediaSourceId: String? = nil,
        container: String? = nil,
        playSessionId: String? = nil
    ) -> URL? {
        let baseURL = server.fullURL
        guard var components = URLComponents(string: "\(baseURL)/Videos/\(itemId)/\(streamPathComponent(container: container))") else {
            return nil
        }

        var queryItems = [
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "api_key", value: token)
        ]
        if let mediaSourceId, !mediaSourceId.isEmpty {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
        }
        if let psid = playSessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !psid.isEmpty {
            queryItems.append(URLQueryItem(name: "PlaySessionId", value: psid))
        }
        components.queryItems = queryItems
        return components.url
    }

    func resolvePlaybackURL(
        server: ServerConfig,
        itemId: String,
        token: String,
        mediaSource: EmbyMediaSource? = nil,
        playbackQuality: RemotePlaybackQualityOption = .auto,
        playSessionId: String? = nil,
        startTimeTicks: Int64? = nil
    ) -> URL? {
        let finalPlaySessionId = (playSessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ? UUID().uuidString : playSessionId!
        
        if let mediaSource {
            if playbackQuality.prefersConstrainedPlayback,
               let manualURL = manualTranscodingURL(
                    server: server,
                    itemId: itemId,
                    token: token,
                    mediaSource: mediaSource,
                    playbackQuality: playbackQuality,
                    playSessionId: finalPlaySessionId,
                    startTimeTicks: startTimeTicks
               ) {
                print("[Emby] Using manual single-stream transcode URL for quality=\(playbackQuality.id), source=\(mediaSource.id), session=\(finalPlaySessionId)")
                return manualURL
            }

            if playbackQuality.prefersConstrainedPlayback,
               let transcodingURL = resolvedTranscodingURL(
                    server: server,
                    token: token,
                    mediaSource: mediaSource,
                    playbackQuality: playbackQuality,
                    playSessionId: finalPlaySessionId
               ) {
                print("[Emby] Using server transcoding URL for quality=\(playbackQuality.id), source=\(mediaSource.id), session=\(finalPlaySessionId)")
                return transcodingURL
            }

            if let directStreamURL = resolvedDirectStreamURL(
                server: server,
                token: token,
                mediaSource: mediaSource,
                playSessionId: finalPlaySessionId
            ) {
                return directStreamURL
            }

            if let transcodingURL = resolvedTranscodingURL(
                server: server,
                token: token,
                mediaSource: mediaSource,
                playbackQuality: playbackQuality,
                playSessionId: finalPlaySessionId
            ) {
                return transcodingURL
            }
        }

        return getStreamURL(
            server: server,
            itemId: itemId,
            token: token,
            mediaSourceId: mediaSource?.id,
            container: preferredStreamContainer(for: mediaSource),
            playSessionId: finalPlaySessionId
        )
    }

    func rebuildPlaybackURL(
        server: ServerConfig,
        itemId: String,
        token: String,
        mediaSourceId: String?,
        playbackQuality: RemotePlaybackQualityOption,
        mediaSourceContainer: String? = nil,
        playSessionId: String? = nil,
        startTimeTicks: Int64? = nil
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
                playSessionId: playSessionId,
                startTimeTicks: startTimeTicks
            )
            if rebuiltURL != nil {
                print("[Emby] Rebuilt manual single-stream playback URL for quality=\(playbackQuality.id), source=\(normalizedMediaSourceId)")
            }
            return rebuiltURL
        }

        let rebuiltURL = getStreamURL(
            server: server,
            itemId: itemId,
            token: token,
            mediaSourceId: normalizedMediaSourceId,
            container: mediaSourceContainer,
            playSessionId: playSessionId
        )
        if rebuiltURL != nil {
            print("[Emby] Rebuilt direct playback URL for quality=\(playbackQuality.id), source=\(normalizedMediaSourceId ?? "nil")")
        }
        return rebuiltURL
    }

    // MARK: - UI Helpers

    func externalSubtitleCandidates(
        server: ServerConfig,
        itemId: String,
        mediaSources: [EmbyMediaSource],
        token: String,
        mediaSourceId: String? = nil
    ) -> [ExternalSubtitleCandidate] {
        var seen = Set<String>()
        let sources: [EmbyMediaSource]
        if let mediaSourceId = mediaSourceId,
           !mediaSourceId.isEmpty,
           let matchedSource = mediaSources.first(where: { $0.id.caseInsensitiveCompare(mediaSourceId) == .orderedSame }) {
            sources = [matchedSource]
        } else {
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

    func preferredPlaybackStreams(
        from mediaSources: [EmbyMediaSource],
        playbackQuality: RemotePlaybackQualityOption = .auto
    ) -> [EmbyMediaStream] {
        preferredPlaybackSource(from: mediaSources, playbackQuality: playbackQuality)?.mediaStreams ?? []
    }

    func preferredPlaybackSource(
        from mediaSources: [EmbyMediaSource],
        playbackQuality: RemotePlaybackQualityOption = .auto
    ) -> EmbyMediaSource? {
        let pool: [EmbyMediaSource]
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

    func qualityOptions(from mediaSources: [EmbyMediaSource]) -> [RemotePlaybackQualityOption] {
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
        for mediaSource: EmbyMediaSource?,
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

    // MARK: - Private Helpers (UI Support)

    private func isExternallyDeliverableSubtitle(_ stream: EmbyMediaStream) -> Bool {
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
        stream: EmbyMediaStream,
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

    private func subtitleDisplayName(stream: EmbyMediaStream) -> String {
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

    private func playbackSelectionTrackCount(in streams: [EmbyMediaStream]) -> Int {
        streams.filter { stream in
            let type = stream.type.lowercased()
            return type == "audio"
                || type.contains("audio")
                || type == "subtitle"
                || type.contains("subtitle")
                || type.contains("caption")
        }.count
    }

    private func isTranscodingCapable(_ mediaSource: EmbyMediaSource) -> Bool {
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
        for mediaSource: EmbyMediaSource,
        playbackQuality: RemotePlaybackQualityOption
    ) -> Int {
        var score = playbackURLAvailabilityScore(for: mediaSource)
        if playbackQuality.prefersConstrainedPlayback {
            score += isTranscodingCapable(mediaSource) ? 1_000 : -1_000
        }
        return score
    }

    private func playbackURLAvailabilityScore(for mediaSource: EmbyMediaSource) -> Int {
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
        mediaSource: EmbyMediaSource,
        playSessionId: String? = nil
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

        if components.path.hasSuffix("/stream"),
           let container = preferredStreamContainer(for: mediaSource) {
            components.path += ".\(container)"
        }

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name.lowercased() == "api_key" }) {
            queryItems.append(URLQueryItem(name: "api_key", value: token))
        }
        if !queryItems.contains(where: { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame }),
           !mediaSource.id.isEmpty {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSource.id))
        }
        if !queryItems.contains(where: { $0.name.caseInsensitiveCompare("DeviceId") == .orderedSame }) {
            queryItems.append(URLQueryItem(name: "DeviceId", value: deviceId))
        }
        if let psid = playSessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !psid.isEmpty {
            queryItems.append(URLQueryItem(name: "PlaySessionId", value: psid))
        }
        components.queryItems = queryItems
        return components.url
    }

    private func resolvedTranscodingURL(
        server: ServerConfig,
        token: String,
        mediaSource: EmbyMediaSource,
        playbackQuality: RemotePlaybackQualityOption,
        playSessionId: String? = nil
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
        if !queryItems.contains(where: { $0.name.caseInsensitiveCompare("DeviceId") == .orderedSame }) {
            queryItems.append(URLQueryItem(name: "DeviceId", value: deviceId))
        }
        if let psid = playSessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !psid.isEmpty {
            queryItems.append(URLQueryItem(name: "PlaySessionId", value: psid))
        }
        queryItems = appendedPlaybackQualityQueryItems(queryItems, for: playbackQuality)
        components.queryItems = queryItems
        return components.url
    }

    private func manualTranscodingURL(
        server: ServerConfig,
        itemId: String,
        token: String,
        mediaSource: EmbyMediaSource,
        playbackQuality: RemotePlaybackQualityOption,
        playSessionId: String?,
        startTimeTicks: Int64?
    ) -> URL? {
        manualTranscodingURL(
            server: server,
            itemId: itemId,
            token: token,
            mediaSourceId: mediaSource.id,
            playbackQuality: playbackQuality,
            playSessionId: playSessionId,
            startTimeTicks: startTimeTicks
        )
    }

    private func manualTranscodingURL(
        server: ServerConfig,
        itemId: String,
        token: String,
        mediaSourceId: String,
        playbackQuality: RemotePlaybackQualityOption,
        playSessionId: String?,
        startTimeTicks: Int64?
    ) -> URL? {
        guard playbackQuality.prefersConstrainedPlayback else {
            return nil
        }

        guard var components = URLComponents(string: "\(server.fullURL)/Videos/\(itemId)/stream.ts") else {
            return nil
        }

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "MediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "DeviceId", value: deviceId),
            URLQueryItem(name: "Static", value: "false"),
            URLQueryItem(name: "EnableAutoStreamCopy", value: "false"),
            URLQueryItem(name: "VideoCodec", value: "h264"),
            URLQueryItem(name: "AudioCodec", value: "aac,mp3,ac3,eac3"),
            URLQueryItem(name: "api_key", value: token)
        ]
        if let psid = playSessionId?.trimmingCharacters(in: .whitespacesAndNewlines), !psid.isEmpty {
            queryItems.append(URLQueryItem(name: "PlaySessionId", value: psid))
        }
        if let startTimeTicks, startTimeTicks > 0 {
            queryItems.append(URLQueryItem(name: "StartTimeTicks", value: String(startTimeTicks)))
        }
        queryItems = appendedPlaybackQualityQueryItems(queryItems, for: playbackQuality)
        components.queryItems = queryItems
        return components.url
    }

    private func appendedPlaybackQualityQueryItems(
        _ queryItems: [URLQueryItem],
        for quality: RemotePlaybackQualityOption
    ) -> [URLQueryItem] {
        var items = queryItems
        let containsKey: (String) -> Bool = { key in
            items.contains(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })
        }

        if let bitrate = quality.maxStreamingBitrate {
            if !containsKey("MaxStreamingBitrate") {
                items.append(URLQueryItem(name: "MaxStreamingBitrate", value: String(bitrate)))
            }
            if !containsKey("VideoBitrate") {
                items.append(URLQueryItem(name: "VideoBitrate", value: String(bitrate)))
            }
            if !containsKey("AudioBitrate") {
                items.append(URLQueryItem(name: "AudioBitrate", value: "320000"))
            }
        }
        if let maxWidth = quality.maxWidth, !containsKey("MaxWidth") {
            items.append(URLQueryItem(name: "MaxWidth", value: String(maxWidth)))
        }
        if let maxHeight = quality.maxHeight, !containsKey("MaxHeight") {
            items.append(URLQueryItem(name: "MaxHeight", value: String(maxHeight)))
        }
        return items
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

    private func preferredStreamContainer(for mediaSource: EmbyMediaSource?) -> String? {
        if let container = normalizedContainerIdentifier(from: mediaSource?.container) {
            return container
        }
        guard let rawPath = mediaSource?.path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        let pathExtension = URL(fileURLWithPath: rawPath).pathExtension
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return pathExtension.isEmpty ? nil : pathExtension
    }

    private func streamPathComponent(container: String?) -> String {
        guard let container = normalizedContainerIdentifier(from: container) else {
            return "stream"
        }
        return "stream.\(container)"
    }

    private func normalizedContainerIdentifier(from container: String?) -> String? {
        guard let rawContainer = container?
            .split(separator: ",")
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawContainer.isEmpty else {
            return nil
        }
        return rawContainer.lowercased()
    }
    
    // MARK: - Progress Reporting (Stub for now)
    
    func reportPlaying(server: ServerConfig, itemId: String, userId: String, token: String, positionTicks: Int64 = 0, playSessionId: String? = nil, mediaSourceId: String? = nil, playMethod: String = "DirectPlay") async throws {
        let baseURL = server.fullURL
        guard var components = URLComponents(string: "\(baseURL)/Sessions/Playing") else { throw EmbyError.invalidURL }
        var queryItems = playbackClientQueryItems(token: token)
        if !queryItems.contains(where: { $0.name == "api_key" }) {
            queryItems.append(URLQueryItem(name: "api_key", value: token))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw EmbyError.invalidURL }
        
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
    
    func reportProgress(server: ServerConfig, itemId: String, userId: String, token: String, positionTicks: Int64, isPaused: Bool, eventName: String? = nil, playSessionId: String? = nil, mediaSourceId: String? = nil, playMethod: String = "DirectPlay") async throws {
        let baseURL = server.fullURL
        guard var components = URLComponents(string: "\(baseURL)/Sessions/Playing/Progress") else { throw EmbyError.invalidURL }
        var queryItems = playbackClientQueryItems(token: token)
        if !queryItems.contains(where: { $0.name == "api_key" }) {
            queryItems.append(URLQueryItem(name: "api_key", value: token))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw EmbyError.invalidURL }
        
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
    
    func reportStopped(server: ServerConfig, itemId: String, userId: String, token: String, positionTicks: Int64, playSessionId: String? = nil, mediaSourceId: String? = nil, playMethod: String = "DirectPlay") async throws {
        let baseURL = server.fullURL
        guard var components = URLComponents(string: "\(baseURL)/Sessions/Playing/Stopped") else { throw EmbyError.invalidURL }
        var queryItems = playbackClientQueryItems(token: token)
        if !queryItems.contains(where: { $0.name == "api_key" }) {
            queryItems.append(URLQueryItem(name: "api_key", value: token))
        }
        components.queryItems = queryItems
        guard let url = components.url else { throw EmbyError.invalidURL }
        
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
    
    // MARK: - Helpers
    
    func getSeasons(server: ServerConfig, userId: String, token: String, seriesId: String) async throws -> [EmbyItem] {
        let itemsResponse = try await getItems(server: server, userId: userId, token: token, libraryId: seriesId, includeTypes: ["Season"])
        return itemsResponse.items
    }
    
    func getEpisodes(server: ServerConfig, userId: String, token: String, seriesId: String, seasonId: String) async throws -> [EmbyItem] {
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

    func getDirectChildren(server: ServerConfig, userId: String, token: String, parentId: String, recursive: Bool = false) async throws -> [EmbyItem] {
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
    
    func getFavorites(server: ServerConfig, userId: String, token: String, limit: Int = 50) async throws -> [EmbyItem] {
        let baseURL = server.fullURL
        let urlString = "\(baseURL)/Users/\(userId)/Items?Recursive=true&Filters=IsFavorite&Fields=Overview,MediaSources,UserData,Genres,ProviderIds&Limit=\(limit)"
        
        guard let url = URL(string: urlString) else {
            throw EmbyError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw EmbyError.unauthorized
        }
        let response = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
        return response.items
    }

    func toggleFavorite(server: ServerConfig, itemId: String, userId: String, token: String, isFavorite: Bool) async throws {
        let baseURL = server.fullURL
        let method = isFavorite ? "POST" : "DELETE"
        let urlString = "\(baseURL)/Users/\(userId)/FavoriteItems/\(itemId)"

        guard let url = URL(string: urlString) else {
            throw EmbyError.invalidURL
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = method
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbyError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw EmbyError.serverError(httpResponse.statusCode)
        }
    }

    func togglePlayed(server: ServerConfig, itemId: String, userId: String, token: String, isPlayed: Bool) async throws {
        let baseURL = server.fullURL
        let method = isPlayed ? "POST" : "DELETE"
        let urlString = "\(baseURL)/Users/\(userId)/PlayedItems/\(itemId)"

        guard let url = URL(string: urlString) else {
            throw EmbyError.invalidURL
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = method
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbyError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw EmbyError.serverError(httpResponse.statusCode)
        }
    }

    /// Delete item from server
    func deleteItem(server: ServerConfig, itemId: String, token: String) async throws {
        let baseURL = server.fullURL
        let urlString = "\(baseURL)/Items/\(itemId)"

        guard let url = URL(string: urlString) else {
            throw EmbyError.invalidURL
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = "DELETE"
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbyError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw EmbyError.serverError(httpResponse.statusCode)
        }
    }
    
    func searchItems(server: ServerConfig, userId: String, token: String, query: String, limit: Int = 50) async throws -> [EmbyItem] {
        let baseURL = server.fullURL
        let encodedQuery = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let urlString = "\(baseURL)/Users/\(userId)/Items?Recursive=true&SearchTerm=\(encodedQuery)&Fields=Overview,MediaSources,UserData,Genres,ProviderIds&Limit=\(limit)"
        
        guard let url = URL(string: urlString) else {
            throw EmbyError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw EmbyError.unauthorized
        }
        let response = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
        return response.items
    }
    
    // MARK: - Metadata (People & Similar)
    
    func getPeople(server: ServerConfig, itemId: String, token: String) async throws -> [EmbyPerson] {
        let baseURL = server.fullURL
        
        // Use the Item details endpoint with Fields=People
        let userId = server.userId ?? ""
        let endpoint = userId.isEmpty ? "/Items/\(itemId)" : "/Users/\(userId)/Items/\(itemId)"
        
        guard let url = URL(string: "\(baseURL)\(endpoint)?Fields=People,PrimaryImageAspectRatio") else {
            throw EmbyError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        do {
            let (data, _) = try await session.data(for: request)
            
            // Decode as full item to get people
            let item = try JSONDecoder().decode(EmbyItem.self, from: data)
            let people = item.people ?? []
            return people
        } catch {
            print("Failed to load people: \(error)")
            // Return empty list instead of throwing to avoid breaking UI
            return []
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
    ) async throws -> [EmbyItem] {
        let baseURL = server.fullURL
        let fields = "Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,ChildCount,RecursiveItemCount,Genres,ProviderIds,PrimaryImageTag,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ProductionYear,PremiereDate,CommunityRating,OfficialRating,RunTimeTicks,IndexNumber,ParentIndexNumber"
        let urlString = "\(baseURL)/Users/\(userId)/Items?Recursive=true&PersonIds=\(personId)&Fields=\(fields)&StartIndex=\(startIndex)&Limit=\(limit)&SortBy=\(sortBy)&SortOrder=\(sortOrder)"
        
        guard let url = URL(string: urlString) else {
            throw EmbyError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw EmbyError.unauthorized
        }
        let response = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
        return response.items
    }
    
    func getSimilarItems(server: ServerConfig, itemId: String, userId: String, token: String, limit: Int = 12) async throws -> [EmbyItem] {
        let baseURL = server.fullURL
        guard let url = URL(string: "\(baseURL)/Items/\(itemId)/Similar?UserId=\(userId)&Limit=\(limit)&Fields=Overview,MediaSources,UserData,Genres,ProviderIds") else {
            throw EmbyError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw EmbyError.unauthorized
        }
        let response = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
        return response.items
    }
    
    func getItemDetails(server: ServerConfig, userId: String, itemId: String, token: String) async throws -> EmbyItem {
        let baseURL = server.fullURL
        guard let url = URL(string: "\(baseURL)/Users/\(userId)/Items/\(itemId)?Fields=Overview,MediaSources,UserData,SeriesId,SeasonId,ChildCount,Genres,ProviderIds,People,PrimaryImageAspectRatio,PremiereDate,EndDate,ProductionLocations,HomePageUrl") else {
            throw EmbyError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.setValue(authHeader(token: token), forHTTPHeaderField: "Authorization")
        
        let (data, rawResponse) = try await session.data(for: request)
        if let httpResponse = rawResponse as? HTTPURLResponse, httpResponse.statusCode == 401 {
            throw EmbyError.unauthorized
        }
        let result = try JSONDecoder().decode(EmbyItem.self, from: data)
        #if os(iOS)
        IOSSubtitleIntelligence.rememberPlaybackMetadata(data, provider: "emby", serverID: server.id.uuidString, itemID: itemId)
        #endif
        return result
    }

    private func performPlaybackReport(_ request: URLRequest, endpoint: String) async throws {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmbyError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            throw EmbyError.unauthorized
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            if let body = String(data: data, encoding: .utf8), !body.isEmpty {
                print("[Emby] report\(endpoint) failed body: \(body.prefix(300))")
            }
            throw EmbyError.serverError(httpResponse.statusCode)
        }
    }
}

enum EmbyError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case serverError(Int)
    case decodingError
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return NSLocalizedString("Invalid server URL", comment: "")
        case .invalidResponse: return NSLocalizedString("Invalid server response", comment: "")
        case .unauthorized: return NSLocalizedString("Invalid username or password", comment: "")
        case .serverError(let code): return String(format: NSLocalizedString("Server error: %d", comment: ""), code)
        case .decodingError: return NSLocalizedString("Failed to parse server response", comment: "")
        }
    }
}
