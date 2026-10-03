import Foundation
#if os(iOS)
import UIKit
#endif

enum PlexLibrarySortOption: String, CaseIterable {
    case title = "titleSort"
    case dateAdded = "addedAt"
    case releaseDate = "originallyAvailableAt"
    case year = "year"
    case rating = "rating"
    case duration = "duration"

    var localizedTitle: String {
        switch self {
        case .title:
            return NSLocalizedString("Name", comment: "")
        case .dateAdded:
            return NSLocalizedString("Date Added", comment: "")
        case .releaseDate:
            return NSLocalizedString("Release Date", comment: "")
        case .year:
            return NSLocalizedString("Release Year", comment: "")
        case .rating:
            return NSLocalizedString("Rating", comment: "")
        case .duration:
            return NSLocalizedString("Runtime", comment: "")
        }
    }
}

class PlexService {
    static let shared = PlexService()
    
    private let session: URLSession
    private let trustedSession: URLSession
    private let clientName = "GenPlayer"
    private let clientVersion = "1.0"
    private let discoverProviderBaseURL = "https://discover.provider.plex.tv"
    private let metadataProviderBaseURL = "https://metadata.provider.plex.tv"
    private let deviceId: String
    private let deviceName: String
    /// Delegate that trusts self-signed certificates for Plex connections.
    /// Plex Media Server uses self-signed certs for local HTTPS and often
    /// redirects HTTP → HTTPS automatically, so we must accept them.
    private let trustedSessionDelegate = PlexSessionDelegate()
    
    private init() {
        let standardConfig = URLSessionConfiguration.default
        standardConfig.timeoutIntervalForRequest = 30
        session = URLSession(configuration: standardConfig)

        let trustedConfig = URLSessionConfiguration.default
        trustedConfig.timeoutIntervalForRequest = 30
        trustedSession = URLSession(configuration: trustedConfig, delegate: trustedSessionDelegate, delegateQueue: nil)
        
        if let storedId = UserDefaults.standard.string(forKey: "PlexDeviceId") {
            deviceId = storedId
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: "PlexDeviceId")
            deviceId = newId
        }
        deviceName = UIDevice.current.name
    }

    struct PlexPlaybackDecision {
        let streams: [[String: Any]]
        let container: String?
        let bitrate: Int?
        let playbackMethod: RemotePlaybackMethod?
    }

    private func runtimeRequest(for url: URL) -> URLRequest {
        URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
    }

    private func performDataRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        guard let host = request.url?.host?.lowercased() else {
            return try await session.data(for: request)
        }

        let providerHosts: Set<String> = [
            "plex.tv",
            "app.plex.tv",
            "discover.provider.plex.tv",
            "metadata.provider.plex.tv"
        ]

        let activeSession = providerHosts.contains(host) ? session : trustedSession
        return try await activeSession.data(for: request)
    }
    
    func getLibraries(server: ServerConfig) async throws -> [PlexLibrary] {
        let root = try await requestJSON(server: server, path: "/library/sections")
        let container = mediaContainer(from: root)
        let directories = container["Directory"] as? [[String: Any]] ?? []
        return directories.compactMap(PlexLibrary.init(dictionary:))
    }

    func createLoginPin() async throws -> PlexPin {
        guard let url = URL(string: "https://plex.tv/api/v2/pins?strong=true") else {
            throw PlexError.invalidResponse
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(to: &request)

        let (data, response) = try await performDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw PlexError.invalidResponse
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let id = json["id"] as? Int,
            let code = json["code"] as? String
        else {
            throw PlexError.invalidResponse
        }

        return PlexPin(id: id, code: code, authToken: json["authToken"] as? String)
    }

    func buildLoginURL(for pin: PlexPin) -> URL? {
        var components = URLComponents(string: "https://app.plex.tv/auth")

        var fragmentComponents = URLComponents()
        fragmentComponents.queryItems = [
            URLQueryItem(name: "clientID", value: deviceId),
            URLQueryItem(name: "code", value: pin.code),
            URLQueryItem(name: "context[device][product]", value: clientName),
            URLQueryItem(name: "context[device][version]", value: clientVersion),
            URLQueryItem(name: "context[device][platform]", value: "iOS"),
            URLQueryItem(name: "context[device][platformVersion]", value: UIDevice.current.systemVersion),
            URLQueryItem(name: "context[device][device]", value: "iPhone"),
            URLQueryItem(name: "context[device][deviceName]", value: deviceName)
        ]

        if let query = fragmentComponents.percentEncodedQuery, !query.isEmpty {
            // Plex PIN login requires hash query format: /auth#?clientID=...&code=...
            components?.fragment = "?\(query)"
        }

        return components?.url
    }

    func pollLoginPin(id: Int, code: String) async throws -> PlexPin {
        var components = URLComponents(string: "https://plex.tv/api/v2/pins/\(id)")
        components?.queryItems = [
            URLQueryItem(name: "code", value: code)
        ]

        guard let url = components?.url else {
            throw PlexError.invalidResponse
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(to: &request)

        let (data, response) = try await performDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            throw PlexError.invalidResponse
        }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pinId = json["id"] as? Int,
            let code = json["code"] as? String
        else {
            throw PlexError.invalidResponse
        }

        return PlexPin(id: pinId, code: code, authToken: json["authToken"] as? String)
    }
    
    func getRecentlyAdded(server: ServerConfig, libraryId: String, limit: Int = 24) async throws -> [PlexItem] {
        let root = try await requestJSON(
            server: server,
            path: "/library/sections/\(libraryId)/recentlyAdded",
            queryItems: [
                URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)")
            ]
        )
        return parseMetadataItems(from: mediaContainer(from: root), limit: limit)
    }
    
    func getContinueWatching(server: ServerConfig, limit: Int = 20) async throws -> [PlexItem] {
        do {
            let root = try await requestJSON(
                server: server,
                path: "/hubs/home/continueWatching",
                queryItems: [URLQueryItem(name: "limit", value: "\(limit)")]
            )
            let container = mediaContainer(from: root)
            
            if let direct = container["Metadata"] as? [[String: Any]], !direct.isEmpty {
                return direct.prefix(limit).map(PlexItem.init(dictionary:))
            }
            
            let hubs = container["Hub"] as? [[String: Any]] ?? []
            var merged: [PlexItem] = []
            var seen = Set<String>()
            for hub in hubs {
                let metadata = hub["Metadata"] as? [[String: Any]] ?? []
                for dict in metadata {
                    let item = PlexItem(dictionary: dict)
                    if seen.insert(item.id).inserted {
                        merged.append(item)
                    }
                    if merged.count >= limit {
                        return merged
                    }
                }
            }
            return merged
        } catch PlexError.serverError(let code) where code == 404 {
            return []
        }
    }

    func getWatchlist(
        server: ServerConfig,
        filter: String = "all",
        sort: String? = "watchlistedAt:desc",
        limit: Int = 20,
        type: String? = nil
    ) async throws -> [PlexItem] {
        let trimmedFilter = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedFilter = trimmedFilter.isEmpty ? "all" : trimmedFilter

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(max(limit, 1))"),
            URLQueryItem(name: "includeCollections", value: "1"),
            URLQueryItem(name: "includeExternalMedia", value: "1")
        ]
        if let sort = sort?.trimmingCharacters(in: .whitespacesAndNewlines), !sort.isEmpty {
            queryItems.append(URLQueryItem(name: "sort", value: sort))
        }
        if let type = type?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty {
            queryItems.append(URLQueryItem(name: "type", value: type))
        }

        guard let url = buildProviderURL(
            baseURLString: discoverProviderBaseURL,
            path: "/library/sections/watchlist/\(resolvedFilter)",
            queryItems: queryItems
        ) else {
            throw PlexError.invalidURL
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(to: &request, server: server)

        let (data, response) = try await performDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw PlexError.unauthorized
            }
            if httpResponse.statusCode == 404 {
                return []
            }
            throw PlexError.serverError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlexError.invalidResponse
        }

        return parseMetadataItems(from: mediaContainer(from: json), limit: limit)
            .filter { item in
                let itemType = item.type.lowercased()
                return itemType == "movie" || itemType == "show"
            }
    }
    
    func getMetadataItem(server: ServerConfig, itemId: String) async throws -> PlexItem? {
        let root = try await requestJSON(server: server, path: "/library/metadata/\(itemId)")
        let items = parseMetadataItems(from: mediaContainer(from: root), limit: 1)
        return items.first
    }

    func resolveMetadataItem(server: ServerConfig, item: PlexItem) async throws -> PlexItem? {
        do {
            if let directMatch = try await getMetadataItem(server: server, itemId: item.id) {
                return directMatch
            }
        } catch PlexError.serverError(let code) where code == 404 {
            // Watchlist/discover items can carry provider-side IDs that do not
            // exist on the connected PMS. Fall back to local library search.
        }

        let query = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return nil
        }

        let candidates = try await searchAllLibraryItems(server: server, query: query, limit: 200)
        return bestMatchingLibraryItem(for: item, in: candidates)
    }

    func getLibraryCollections(
        server: ServerConfig,
        libraryId: String,
        startIndex: Int = 0,
        limit: Int = 100
    ) async throws -> [PlexItem] {
        do {
            let root = try await requestJSON(
                server: server,
                path: "/library/sections/\(libraryId)/collections",
                queryItems: [
                    URLQueryItem(name: "X-Plex-Container-Start", value: "\(startIndex)"),
                    URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)")
                ]
            )
            return parseMetadataItems(from: mediaContainer(from: root), limit: limit)
        } catch PlexError.serverError(let code) where code == 404 || code == 400 {
            // Fallback for some Plex servers where /collections might not exist
            do {
                let fallbackRoot = try await requestJSON(
                    server: server,
                    path: "/library/sections/\(libraryId)/all",
                    queryItems: [
                        URLQueryItem(name: "type", value: "18"),
                        URLQueryItem(name: "X-Plex-Container-Start", value: "\(startIndex)"),
                        URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)")
                    ]
                )
                return parseMetadataItems(from: mediaContainer(from: fallbackRoot), limit: limit)
            } catch {
                return []
            }
        }
    }

    func getCollectionItems(
        server: ServerConfig,
        collectionId: String,
        startIndex: Int = 0,
        limit: Int = 200
    ) async throws -> [PlexItem] {
        do {
            let root = try await requestJSON(
                server: server,
                path: "/library/metadata/\(collectionId)/children",
                queryItems: [
                    URLQueryItem(name: "X-Plex-Container-Start", value: "\(startIndex)"),
                    URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)")
                ]
            )
            return parseMetadataItems(from: mediaContainer(from: root), limit: limit)
        } catch PlexError.serverError(let code) where code == 404 || code == 400 {
            return []
        }
    }

    func getLibraryItems(
        server: ServerConfig,
        library: PlexLibrary,
        sortBy: String,
        sortOrder: String,
        searchQuery: String = "",
        genre: String? = nil,
        year: String? = nil,
        startIndex: Int = 0,
        limit: Int = 100
    ) async throws -> [PlexItem] {
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty || genre != nil || year != nil else {
            do {
                let searchResults = try await searchLibraryItems(
                    server: server,
                    library: library,
                    query: trimmedQuery,
                    limit: limit
                )
                let filtered = filterLibraryItems(searchResults, for: library, isSearching: true)
                return sortLibraryItems(filtered, sortBy: sortBy, sortOrder: sortOrder).prefix(limit).map { $0 }
            } catch PlexError.serverError(let code) where code == 400 || code == 404 {
                return []
            }
        }

        let queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(startIndex)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)"),
            URLQueryItem(
                name: "sort",
                value: "\(sortBy):\(sortOrder == "Ascending" ? "asc" : "desc")"
            )
        ] + PlexLibraryFilters.queryItems(genre: genre, year: year, search: trimmedQuery)

        do {
            let root = try await requestJSON(
                server: server,
                path: "/library/sections/\(library.id)/all",
                queryItems: queryItems
            )
            let items = parseMetadataItems(from: mediaContainer(from: root), limit: limit)
            return filterLibraryItems(items, for: library, isSearching: false)
        } catch PlexError.serverError(let code)
            where code == 400 || code == 404 {
            return []
        }
    }

    func getLibraryFilterChoices(
        server: ServerConfig, library: PlexLibrary, field: PlexLibraryFilterField
    ) async throws -> [PlexLibraryFilterChoice] {
        guard ["movie", "show"].contains(library.type.lowercased()) else { return [] }
        let root = try await requestJSON(server: server, path: "/library/sections/\(library.id)/\(field.rawValue)")
        let rows = mediaContainer(from: root)["Directory"] as? [[String: Any]] ?? []
        return PlexLibraryFilters.choices(from: rows, field: field)
    }

    func searchLibraries(
        server: ServerConfig,
        libraries: [PlexLibrary],
        query: String,
        limitPerLibrary: Int = 24
    ) async throws -> [String: [PlexItem]] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [:] }

        var grouped: [String: [PlexItem]] = [:]
        for library in libraries {
            let items = try await searchLibraryItems(
                server: server,
                library: library,
                query: trimmedQuery,
                limit: limitPerLibrary
            )
            let filtered = filterLibraryItems(items, for: library, isSearching: true)
            guard !filtered.isEmpty else { continue }
            grouped[library.id] = Array(
                sortLibraryItems(
                    filtered,
                    sortBy: PlexLibrarySortOption.dateAdded.rawValue,
                    sortOrder: "Descending"
                ).prefix(limitPerLibrary)
            )
        }
        return grouped
    }

    func getChildren(server: ServerConfig, itemId: String, limit: Int = 200) async throws -> [PlexItem] {
        let root = try await requestJSON(
            server: server,
            path: "/library/metadata/\(itemId)/children",
            queryItems: [
                URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)")
            ]
        )
        return parseMetadataItems(from: mediaContainer(from: root), limit: limit)
    }

    func getRelatedItems(server: ServerConfig, itemId: String, limit: Int = 20) async throws -> [PlexItem] {
        do {
            let root = try await requestJSON(
                server: server,
                path: "/hubs/metadata/\(itemId)/related",
                queryItems: [
                    URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
                    URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)")
                ]
            )
            let container = mediaContainer(from: root)

            var merged: [PlexItem] = []
            var seen = Set<String>()

            let direct = container["Metadata"] as? [[String: Any]] ?? []
            for dict in direct {
                let parsed = PlexItem(dictionary: dict)
                guard parsed.id != itemId else { continue }
                if seen.insert(parsed.id).inserted {
                    merged.append(parsed)
                }
                if merged.count >= limit {
                    return merged
                }
            }

            let hubs = container["Hub"] as? [[String: Any]] ?? []
            for hub in hubs {
                let metadata = hub["Metadata"] as? [[String: Any]] ?? []
                for dict in metadata {
                    let parsed = PlexItem(dictionary: dict)
                    guard parsed.id != itemId else { continue }
                    if seen.insert(parsed.id).inserted {
                        merged.append(parsed)
                    }
                    if merged.count >= limit {
                        return merged
                    }
                }
            }

            return merged
        } catch PlexError.serverError(let code) where code == 404 {
            return []
        }
    }

    func getPersonMedia(server: ServerConfig, personId: String, startIndex: Int = 0, limit: Int = 24) async throws -> [PlexItem] {
        do {
            let root = try await requestJSON(
                server: server,
                path: "/library/people/\(personId)/media",
                queryItems: [
                    URLQueryItem(name: "X-Plex-Container-Start", value: "\(startIndex)"),
                    URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)")
                ]
            )
            return parseMetadataItems(from: mediaContainer(from: root), limit: limit)
        } catch PlexError.serverError(let code) where code == 404 {
            return []
        }
    }
    
    func getImageURL(server: ServerConfig, imagePath: String?, versionTag: String? = nil) -> URL? {
        guard let imagePath, !imagePath.isEmpty else { return nil }
        if imagePath.hasPrefix("http://") || imagePath.hasPrefix("https://") {
            return URL(string: imagePath).map {
                let runtimeURL = RuntimeNetworkAddressResolver.runtimeURL(from: $0)
                let cacheKey = MediaImageCacheIdentity.plexImage(
                    server: server,
                    imagePath: imagePath,
                    versionTag: versionTag
                )
                return MediaImageCacheIdentity.apply(cacheKey: cacheKey, to: runtimeURL)
            }
        }
        return buildURL(server: server, path: imagePath, queryItems: []).map {
            let runtimeURL = RuntimeNetworkAddressResolver.runtimeURL(from: $0)
            let cacheKey = MediaImageCacheIdentity.plexImage(
                server: server,
                imagePath: imagePath,
                versionTag: versionTag
            )
            return MediaImageCacheIdentity.apply(cacheKey: cacheKey, to: runtimeURL)
        }
    }
    
    func getStreamURL(server: ServerConfig, item: PlexItem) -> URL? {
        guard let partKey = item.mediaPartKey, !partKey.isEmpty else {
            return nil
        }
        return buildURL(server: server, path: partKey, queryItems: [])
    }

    func getDownloadPath(item: PlexItem) -> String? {
        guard let partKey = item.mediaPartKey, !partKey.isEmpty else {
            return nil
        }
        if partKey.contains("?") {
            return "\(partKey)&download=1"
        }
        return "\(partKey)?download=1"
    }

    func fetchSeekPreviewImage(
        server: ServerConfig,
        partId: String,
        offsetMilliseconds: Int64,
        bifType: String = "sd"
    ) async -> UIImage? {
        guard let url = buildURL(
            server: server,
            path: "/library/parts/\(partId)/indexes/\(bifType)/\(max(0, offsetMilliseconds))",
            queryItems: []
        ) else {
            return nil
        }

        do {
            var request = runtimeRequest(for: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 1.2
            request.setValue("image/jpeg,image/*;q=0.9", forHTTPHeaderField: "Accept")
            applyPlexHeaders(to: &request, server: server)

            let (data, response) = try await performDataRequest(request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode) else {
                return nil
            }

            return UIImage(data: data)
        } catch {
            return nil
        }
    }

    func qualityOptions(for item: PlexItem) -> [RemotePlaybackQualityOption] {
        RemotePlaybackQualityCatalog.options(
            maxVideoWidth: item.maxVideoWidth,
            maxVideoHeight: item.maxVideoHeight,
            supportsTranscoding: item.isPlayable && item.mediaPartKey?.isEmpty == false
        )
    }

    func resolvePlaybackURL(
        server: ServerConfig,
        item: PlexItem,
        playbackQuality: RemotePlaybackQualityOption,
        startPosition: TimeInterval? = nil
    ) -> URL? {
        if !playbackQuality.prefersConstrainedPlayback {
            return getStreamURL(server: server, item: item)
        }

        guard item.isPlayable else {
            return getStreamURL(server: server, item: item)
        }

        return buildTranscodeURL(
            server: server,
            item: item,
            playbackQuality: playbackQuality,
            startPosition: startPosition
        )
    }

    func getPlaybackDecision(
        server: ServerConfig,
        item: PlexItem,
        playbackQuality: RemotePlaybackQualityOption,
        startPosition: TimeInterval? = nil
    ) async throws -> PlexPlaybackDecision? {
        guard item.isPlayable, playbackQuality.prefersConstrainedPlayback else {
            return nil
        }

        guard let url = buildURL(
            server: server,
            path: "/video/:/transcode/universal/decision",
            queryItems: transcodeQueryItems(
                item: item,
                playbackQuality: playbackQuality,
                startPosition: startPosition
            )
        ) else {
            throw PlexError.invalidURL
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexClientProfileHeaders(to: &request)
        applyPlexHeaders(to: &request, server: server)

        let (data, response) = try await performDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw PlexError.unauthorized
            }
            throw PlexError.serverError(httpResponse.statusCode)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlexError.invalidResponse
        }

        return parsePlaybackDecision(from: json)
    }

    func playbackMethod(
        for playbackQuality: RemotePlaybackQualityOption,
        resolvedURL: URL
    ) -> RemotePlaybackMethod {
        if !playbackQuality.prefersConstrainedPlayback {
            return .directPlay
        }

        let path = resolvedURL.path.lowercased()
        if path.contains("/transcode/") || resolvedURL.absoluteString.lowercased().contains("start.m3u8") {
            return .transcode
        }

        return .directPlay
    }

    func setPlayed(server: ServerConfig, itemId: String, isPlayed: Bool) async throws {
        let path = isPlayed ? "/:/scrobble" : "/:/unscrobble"
        guard let url = buildURL(
            server: server,
            path: path,
            queryItems: [
                URLQueryItem(name: "key", value: itemId),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
            ]
        ) else {
            throw PlexError.invalidURL
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = "GET"
        applyPlexHeaders(to: &request, server: server)

        let (_, response) = try await performDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw PlexError.unauthorized
            }
            throw PlexError.serverError(httpResponse.statusCode)
        }
    }

    /// Delete item from Plex server
    func deleteItem(server: ServerConfig, ratingKey: String) async throws {
        guard let url = buildURL(server: server, path: "/library/metadata/\(ratingKey)", queryItems: []) else {
            throw PlexError.invalidURL
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = "DELETE"
        applyPlexHeaders(to: &request, server: server)

        let (_, response) = try await performDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw PlexError.unauthorized
            }
            throw PlexError.serverError(httpResponse.statusCode)
        }
    }

    func reportTimeline(
        server: ServerConfig,
        itemId: String,
        positionMillis: Int64,
        durationMillis: Int64?,
        state: String,
        sessionIdentifier: String
    ) async throws {
        var queryItems = [
            URLQueryItem(name: "ratingKey", value: itemId),
            URLQueryItem(name: "key", value: "/library/metadata/\(itemId)"),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "time", value: "\(max(0, positionMillis))"),
            URLQueryItem(name: "playbackTime", value: "\(max(0, positionMillis))"),
            URLQueryItem(name: "state", value: state)
        ]
        if let durationMillis, durationMillis > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: "\(durationMillis)"))
        }

        guard let url = buildURL(server: server, path: "/:/timeline", queryItems: queryItems) else {
            throw PlexError.invalidURL
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(sessionIdentifier, forHTTPHeaderField: "X-Plex-Session-Identifier")
        applyPlexHeaders(to: &request, server: server)

        let (_, response) = try await performDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw PlexError.unauthorized
            }
            throw PlexError.serverError(httpResponse.statusCode)
        }
    }

    func updatePlayProgress(
        server: ServerConfig,
        itemId: String,
        positionMillis: Int64,
        state: String
    ) async throws {
        guard let url = buildURL(
            server: server,
            path: "/:/progress",
            queryItems: [
                URLQueryItem(name: "key", value: "/library/metadata/\(itemId)"),
                URLQueryItem(name: "time", value: "\(max(0, positionMillis))"),
                URLQueryItem(name: "state", value: state)
            ]
        ) else {
            throw PlexError.invalidURL
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(to: &request, server: server)

        let (_, response) = try await performDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw PlexError.unauthorized
            }
            throw PlexError.serverError(httpResponse.statusCode)
        }
    }

    func setWatchlisted(server: ServerConfig, guid: String, isWatchlisted: Bool) async throws {
        guard let ratingKey = watchlistRatingKey(from: guid),
              let url = buildProviderURL(
                baseURLString: discoverProviderBaseURL,
                path: isWatchlisted ? "/actions/addToWatchlist" : "/actions/removeFromWatchlist",
                queryItems: [URLQueryItem(name: "ratingKey", value: ratingKey)]
              ) else {
            throw PlexError.invalidResponse
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(to: &request, server: server)

        let (_, response) = try await performDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw PlexError.unauthorized
            }
            throw PlexError.serverError(httpResponse.statusCode)
        }
    }

    func isWatchlisted(server: ServerConfig, guid: String) async throws -> Bool {
        guard let ratingKey = watchlistRatingKey(from: guid),
              let url = buildProviderURL(
                baseURLString: metadataProviderBaseURL,
                path: "/library/metadata/\(ratingKey)/userState",
                queryItems: []
              ) else {
            throw PlexError.invalidResponse
        }

        var request = runtimeRequest(for: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(to: &request, server: server)

        let (data, response) = try await performDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                throw PlexError.unauthorized
            }
            if httpResponse.statusCode == 404 {
                return false
            }
            throw PlexError.serverError(httpResponse.statusCode)
        }

        return parseWatchlistedState(from: data)
    }

    func buildPlayableVideoFile(
        server: ServerConfig,
        item: PlexItem,
        startPosition: TimeInterval? = nil,
        audioQuery: String? = nil,
        subtitleQuery: String? = nil,
        disableSubtitles: Bool = false,
        playbackQuality: RemotePlaybackQualityOption = .auto
    ) -> VideoFile? {
        guard let streamURL = resolvePlaybackURL(
            server: server,
            item: item,
            playbackQuality: playbackQuality,
            startPosition: startPosition
        ) else {
            return nil
        }
        let resumeDecision = item.resumeDecision

        var file = VideoFile(
            name: item.displayTitle,
            url: streamURL,
            type: .video,
            size: 0,
            date: Date(),
            isRemote: true,
            duration: item.durationSeconds,
            lastPlayedPosition: startPosition ?? resumeDecision.startPosition,
            lastAudioTrack: nil,
            lastSubtitleTrack: nil,
            jellyfinItemId: item.id,
            jellyfinServerId: server.id.uuidString,
            serverType: .plex
        )
        file.shouldResetRemotePlayedStateOnPlaybackStart =
            (startPosition ?? resumeDecision.startPosition ?? 0) <= 0.5 &&
            resumeDecision.shouldResetPlayedStateOnStart
        file.preferredAudioTrackQuery = audioQuery
        file.preferredSubtitleTrackQuery = subtitleQuery
        file.preferredPlaybackQualityID = playbackQuality.id
        file.availablePlaybackQualityOptions = qualityOptions(for: item)
        file.disableSubtitlesOnStart = disableSubtitles
        if !item.mediaStreams.isEmpty {
            file.serverMediaStreams = item.mediaStreams.map { $0.toDictionary() }
        }
        file.serverContainer = item.mediaContainer
        file.serverSize = item.mediaSize
        file.serverBitrate = item.mediaBitrate
        file.serverPath = item.mediaFilePath
        file.remotePlaybackMethod = playbackMethod(for: playbackQuality, resolvedURL: streamURL)
        return file
    }
    
    // MARK: - Internal
    
    private func parseMetadataItems(from container: [String: Any], limit: Int) -> [PlexItem] {
        let metadata = container["Metadata"] as? [[String: Any]] ?? []
        return metadata.prefix(limit).map(PlexItem.init(dictionary:))
    }

    private func parseSearchItems(from container: [String: Any], limit: Int) -> [PlexItem] {
        var items: [PlexItem] = []
        var seen = Set<String>()

        let searchResults = container["SearchResult"] as? [[String: Any]] ?? []
        for result in searchResults {
            let metadataEntries: [[String: Any]]
            if let metadata = result["Metadata"] as? [String: Any] {
                metadataEntries = [metadata]
            } else if let metadata = result["Metadata"] as? [[String: Any]] {
                metadataEntries = metadata
            } else {
                metadataEntries = []
            }

            for dictionary in metadataEntries {
                let item = PlexItem(dictionary: dictionary)
                guard seen.insert(item.id).inserted else { continue }
                items.append(item)
                if items.count >= limit {
                    return items
                }
            }
        }

        if items.isEmpty {
            return parseMetadataItems(from: container, limit: limit)
        }

        return items
    }

    private func parseHubMetadataItems(from container: [String: Any], limit: Int) -> [PlexItem] {
        var items: [PlexItem] = []
        var seen = Set<String>()

        let directMetadata = container["Metadata"] as? [[String: Any]] ?? []
        for dictionary in directMetadata {
            let item = PlexItem(dictionary: dictionary)
            guard seen.insert(item.id).inserted else { continue }
            items.append(item)
            if items.count >= limit {
                return items
            }
        }

        let hubs = container["Hub"] as? [[String: Any]] ?? []
        for hub in hubs {
            let metadataEntries = hub["Metadata"] as? [[String: Any]] ?? []
            for dictionary in metadataEntries {
                let item = PlexItem(dictionary: dictionary)
                guard seen.insert(item.id).inserted else { continue }
                items.append(item)
                if items.count >= limit {
                    return items
                }
            }
        }

        return items
    }

    private func filterLibraryItems(_ items: [PlexItem], for library: PlexLibrary, isSearching: Bool) -> [PlexItem] {
        let libraryType = library.type.lowercased()

        switch libraryType {
        case "movie":
            return items.filter { item in
                let type = item.type.lowercased()
                return type == "movie" || type == "video" || item.isPlayable || (isSearching && type == "clip")
            }
        case "show":
            return items.filter { item in
                let type = item.type.lowercased()
                if isSearching {
                    return type == "show" || type == "season" || type == "episode"
                }
                return type == "show"
            }
        default:
            return items
        }
    }

    private func searchAllLibraryItems(
        server: ServerConfig,
        query: String,
        limit: Int
    ) async throws -> [PlexItem] {
        let root = try await requestJSON(
            server: server,
            path: "/library/search",
            queryItems: [
                URLQueryItem(name: "query", value: query)
            ]
        )
        return parseSearchItems(from: mediaContainer(from: root), limit: limit)
    }

    private func searchLibraryItems(
        server: ServerConfig,
        library: PlexLibrary,
        query: String,
        limit: Int
    ) async throws -> [PlexItem] {
        if let sectionId = Int(library.id) {
            let hubRoot = try await requestJSON(
                server: server,
                path: "/hubs/search",
                queryItems: [
                    URLQueryItem(name: "query", value: query),
                    URLQueryItem(name: "sectionId", value: "\(sectionId)"),
                    URLQueryItem(name: "limit", value: "\(max(limit, 12))")
                ]
            )
            let hubItems = parseHubMetadataItems(from: mediaContainer(from: hubRoot), limit: max(limit * 3, 120))
            let sectionItems = hubItems.filter {
                $0.librarySectionIdString == library.id || $0.librarySectionIdString == nil
            }
            if !sectionItems.isEmpty {
                return Array(sectionItems.prefix(limit))
            }
        }

        let globalItems = try await searchAllLibraryItems(
            server: server,
            query: query,
            limit: 500
        )
        return Array(globalItems.filter { $0.librarySectionIdString == library.id }.prefix(limit))
    }

    private func bestMatchingLibraryItem(for seedItem: PlexItem, in candidates: [PlexItem]) -> PlexItem? {
        let normalizedType = seedItem.type.lowercased()
        let typedCandidates = candidates.filter { $0.type.lowercased() == normalizedType }
        let searchPool = typedCandidates.isEmpty ? candidates : typedCandidates

        if let seedGUID = normalizedGuid(seedItem.guid),
           let guidMatch = searchPool.first(where: { normalizedGuid($0.guid) == seedGUID }) {
            return guidMatch
        }

        if !seedItem.providerIds.isEmpty,
           let providerMatch = searchPool.first(where: {
               providerIdsMatch(seed: seedItem.providerIds, candidate: $0.providerIds)
           }) {
            return providerMatch
        }

        let normalizedSeedTitle = normalizedMatchText(seedItem.title)
        if let year = seedItem.year,
           let titleAndYearMatch = searchPool.first(where: {
               normalizedMatchText($0.title) == normalizedSeedTitle && $0.year == year
           }) {
            return titleAndYearMatch
        }

        if let titleMatch = searchPool.first(where: { normalizedMatchText($0.title) == normalizedSeedTitle }) {
            return titleMatch
        }

        return searchPool.first
    }

    private func providerIdsMatch(seed: [String: String], candidate: [String: String]) -> Bool {
        for (key, value) in seed {
            guard !value.isEmpty else { continue }
            if candidate[key] == value {
                return true
            }
        }
        return false
    }

    private func normalizedMatchText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func normalizedGuid(_ guid: String?) -> String? {
        guard let guid else { return nil }
        let normalized = guid.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return normalized.isEmpty ? nil : normalized
    }

    private func sortLibraryItems(_ items: [PlexItem], sortBy: String, sortOrder: String) -> [PlexItem] {
        let isAscending = sortOrder == "Ascending"
        return items.sorted { lhs, rhs in
            switch sortBy {
            case PlexLibrarySortOption.title.rawValue:
                return compareTitles(lhs.title, rhs.title, ascending: isAscending)
            case PlexLibrarySortOption.releaseDate.rawValue:
                return compare(lhs.originallyAvailableAt, rhs.originallyAvailableAt, ascending: isAscending, fallbackLeft: lhs.title, fallbackRight: rhs.title)
            case PlexLibrarySortOption.year.rawValue:
                return compare(lhs.year, rhs.year, ascending: isAscending, fallbackLeft: lhs.title, fallbackRight: rhs.title)
            case PlexLibrarySortOption.rating.rawValue:
                return compare(lhs.rating, rhs.rating, ascending: isAscending, fallbackLeft: lhs.title, fallbackRight: rhs.title)
            case PlexLibrarySortOption.duration.rawValue:
                return compare(lhs.durationMillis, rhs.durationMillis, ascending: isAscending, fallbackLeft: lhs.title, fallbackRight: rhs.title)
            case PlexLibrarySortOption.dateAdded.rawValue:
                fallthrough
            default:
                return compare(lhs.addedAt, rhs.addedAt, ascending: isAscending, fallbackLeft: lhs.title, fallbackRight: rhs.title)
            }
        }
    }

    private func compareTitles(_ lhs: String, _ rhs: String, ascending: Bool) -> Bool {
        switch lhs.localizedCaseInsensitiveCompare(rhs) {
        case .orderedAscending:
            return ascending
        case .orderedDescending:
            return !ascending
        case .orderedSame:
            return lhs < rhs
        @unknown default:
            return lhs < rhs
        }
    }

    private func compare<T: Comparable>(
        _ lhs: T?,
        _ rhs: T?,
        ascending: Bool,
        fallbackLeft: String,
        fallbackRight: String
    ) -> Bool {
        switch (lhs, rhs) {
        case let (left?, right?):
            if left == right {
                return compareTitles(fallbackLeft, fallbackRight, ascending: true)
            }
            return ascending ? left < right : left > right
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return compareTitles(fallbackLeft, fallbackRight, ascending: true)
        }
    }
    
    private func requestJSON(server: ServerConfig, path: String, queryItems: [URLQueryItem] = []) async throws -> [String: Any] {
        guard let url = buildURL(server: server, path: path, queryItems: queryItems) else {
            throw PlexError.invalidURL
        }
        
        var request = runtimeRequest(for: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyPlexHeaders(to: &request, server: server)
        
        let (data, response) = try await performDataRequest(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexError.invalidResponse
        }
        
        if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
            throw PlexError.unauthorized
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw PlexError.serverError(httpResponse.statusCode)
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlexError.invalidResponse
        }
        return json
    }
    
    private func mediaContainer(from root: [String: Any]) -> [String: Any] {
        if let container = root["MediaContainer"] as? [String: Any] {
            return container
        }
        return root
    }
    
    private func buildURL(server: ServerConfig, path: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: server.fullURL) else {
            return nil
        }
        
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let basePath = components.path
        if basePath.isEmpty || basePath == "/" {
            components.path = normalizedPath
        } else {
            let trimmedBase = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
            components.path = "\(trimmedBase)\(normalizedPath)"
        }
        
        var allQueryItems = queryItems
        if let token = resolvedToken(from: server), !token.isEmpty {
            let hasToken = allQueryItems.contains(where: { $0.name == "X-Plex-Token" })
            if !hasToken {
                allQueryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
            }
        }
        if !allQueryItems.isEmpty {
            components.queryItems = allQueryItems
        }
        
        return components.url
    }

    private func buildProviderURL(baseURLString: String, path: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(string: baseURLString) else {
            return nil
        }

        components.path = path.hasPrefix("/") ? path : "/\(path)"
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        return components.url
    }

    private func buildTranscodeURL(
        server: ServerConfig,
        item: PlexItem,
        playbackQuality: RemotePlaybackQualityOption,
        startPosition: TimeInterval?
    ) -> URL? {
        buildURL(
            server: server,
            path: "/video/:/transcode/universal/start.m3u8",
            queryItems: transcodeQueryItems(
                item: item,
                playbackQuality: playbackQuality,
                startPosition: startPosition
            )
        )
    }

    private func transcodeQueryItems(
        item: PlexItem,
        playbackQuality: RemotePlaybackQualityOption,
        startPosition: TimeInterval?
    ) -> [URLQueryItem] {
        let sessionIdentifier = UUID().uuidString
        let sourceWidth = max(item.maxVideoWidth ?? playbackQuality.maxWidth ?? 0, 1)
        let sourceHeight = max(item.maxVideoHeight ?? playbackQuality.maxHeight ?? 0, 1)
        let targetWidth = playbackQuality.maxWidth ?? sourceWidth
        let targetHeight = playbackQuality.maxHeight ?? sourceHeight
        let fittedResolution = fittedVideoResolution(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: targetWidth,
            targetHeight: targetHeight
        )

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "path", value: "/library/metadata/\(item.id)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "transcodeSessionId", value: sessionIdentifier),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "copyts", value: "1"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "location", value: "wan"),
            URLQueryItem(name: "directPlay", value: playbackQuality.allowsDirectPlay ? "1" : "0"),
            URLQueryItem(name: "directStream", value: playbackQuality.allowsDirectStream ? "1" : "0"),
            URLQueryItem(name: "directStreamAudio", value: playbackQuality.allowsDirectStream ? "1" : "0"),
            URLQueryItem(name: "hasMDE", value: playbackQuality.allowsDirectPlay ? "1" : "0"),
            URLQueryItem(name: "autoAdjustQuality", value: playbackQuality.preset == .auto ? "1" : "0"),
            URLQueryItem(name: "videoQuality", value: "\(plexVideoQualityValue(for: playbackQuality))"),
            URLQueryItem(name: "videoResolution", value: "\(fittedResolution.width)x\(fittedResolution.height)"),
            URLQueryItem(name: "mediaBufferSize", value: "102400"),
            URLQueryItem(name: "secondsPerSegment", value: "5"),
            URLQueryItem(name: "disableResolutionRotation", value: "1"),
            URLQueryItem(name: "subtitles", value: "auto"),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: deviceId),
            URLQueryItem(name: "X-Plex-Product", value: clientName),
            URLQueryItem(name: "X-Plex-Version", value: clientVersion),
            URLQueryItem(name: "X-Plex-Platform", value: "iOS"),
            URLQueryItem(name: "X-Plex-Platform-Version", value: UIDevice.current.systemVersion),
            URLQueryItem(name: "X-Plex-Device", value: deviceName),
            URLQueryItem(name: "X-Plex-Device-Name", value: deviceName),
            URLQueryItem(name: "X-Plex-Client-Profile-Name", value: "generic"),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionIdentifier)
        ]

        if let bitrate = playbackQuality.maxStreamingBitrate {
            let kbps = max(1, bitrate / 1000)
            queryItems.append(URLQueryItem(name: "videoBitrate", value: "\(kbps)"))
            queryItems.append(URLQueryItem(name: "peakBitrate", value: "\(kbps)"))
        }

        if let startPosition, startPosition > 0 {
            queryItems.append(URLQueryItem(name: "offset", value: String(format: "%.3f", startPosition)))
        }

        return queryItems
    }

    private func fittedVideoResolution(
        sourceWidth: Int,
        sourceHeight: Int,
        targetWidth: Int,
        targetHeight: Int
    ) -> (width: Int, height: Int) {
        guard sourceWidth > 0, sourceHeight > 0, targetWidth > 0, targetHeight > 0 else {
            return (max(targetWidth, 1), max(targetHeight, 1))
        }

        let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
        let targetAspect = Double(targetWidth) / Double(targetHeight)

        let resolvedWidth: Int
        let resolvedHeight: Int
        if sourceAspect > targetAspect {
            resolvedWidth = min(sourceWidth, targetWidth)
            resolvedHeight = Int((Double(resolvedWidth) / sourceAspect).rounded(.down))
        } else {
            resolvedHeight = min(sourceHeight, targetHeight)
            resolvedWidth = Int((Double(resolvedHeight) * sourceAspect).rounded(.down))
        }

        return (
            width: max(resolvedWidth / 2 * 2, 2),
            height: max(resolvedHeight / 2 * 2, 2)
        )
    }

    private func plexVideoQualityValue(for playbackQuality: RemotePlaybackQualityOption) -> Int {
        switch playbackQuality.preset {
        case .auto:
            return 60
        case .original:
            return 80
        case .p1080:
            return 60
        case .p720:
            return 50
        case .p480:
            return 40
        }
    }

    private func parsePlaybackDecision(from root: [String: Any]) -> PlexPlaybackDecision? {
        let container = mediaContainer(from: root)
        let metadata = (container["Metadata"] as? [[String: Any]])?.first
        let media = (metadata?["Media"] as? [[String: Any]])?.first
        let part = (media?["Part"] as? [[String: Any]])?.first
        let streams = ((part?["Stream"] as? [[String: Any]]) ?? []).compactMap(normalizedDecisionStream(from:))

        let playbackMethod = playbackMethod(fromDecisionText:
            PlexValue.string(media?["decision"]) ??
            PlexValue.string(container["generalDecisionText"]) ??
            PlexValue.string(container["mdeDecisionText"]) ??
            PlexValue.string(container["directPlayDecisionText"])
        )

        return PlexPlaybackDecision(
            streams: streams,
            container: PlexValue.string(media?["container"]),
            bitrate: PlexValue.int(media?["bitrate"]),
            playbackMethod: playbackMethod
        )
    }

    private func normalizedDecisionStream(from stream: [String: Any]) -> [String: Any]? {
        guard let streamType = PlexValue.int(stream["streamType"]) else {
            return nil
        }

        let type: String
        switch streamType {
        case 1:
            type = "Video"
        case 2:
            type = "Audio"
        case 3:
            type = "Subtitle"
        default:
            type = "Unknown"
        }

        var result: [String: Any] = ["Type": type]

        if let codec = PlexValue.string(stream["codec"]), !codec.isEmpty {
            result["Codec"] = codec
        }
        if let language = PlexValue.string(stream["language"]), !language.isEmpty {
            result["Language"] = language
        }
        if let width = PlexValue.int(stream["width"]), width > 0 {
            result["Width"] = width
        }
        if let height = PlexValue.int(stream["height"]), height > 0 {
            result["Height"] = height
        }
        if let bitrate = PlexValue.int(stream["bitrate"]), bitrate > 0 {
            result["BitRate"] = bitrate
        }
        if let channels = PlexValue.int(stream["channels"]), channels > 0 {
            result["Channels"] = channels
        }
        if let channelLayout = PlexValue.string(stream["audioChannelLayout"]), !channelLayout.isEmpty {
            result["ChannelLayout"] = channelLayout
        }
        if let profile = PlexValue.string(stream["profile"]), !profile.isEmpty {
            result["Profile"] = profile
        }
        if let level = PlexValue.int(stream["level"]) {
            result["Level"] = level
        }
        if let bitDepth = PlexValue.int(stream["bitDepth"]) {
            result["BitDepth"] = bitDepth
        }
        if let pixelFormat = PlexValue.string(stream["pixelFormat"]), !pixelFormat.isEmpty {
            result["PixelFormat"] = pixelFormat
        }
        if let videoRange = PlexValue.string(stream["colorRange"]), !videoRange.isEmpty {
            result["VideoRange"] = videoRange
        }
        if let frameRate = PlexValue.double(stream["frameRate"]), frameRate > 0 {
            result["RealFrameRate"] = frameRate
        }

        let displayTitle = PlexValue.string(stream["displayTitle"])
            ?? PlexValue.string(stream["extendedDisplayTitle"])
            ?? PlexValue.string(stream["title"])
        if let displayTitle, !displayTitle.isEmpty {
            result["DisplayTitle"] = displayTitle
            result["Title"] = displayTitle
        }

        if PlexValue.bool(stream["default"]) {
            result["IsDefault"] = true
        }
        if PlexValue.bool(stream["forced"]) {
            result["IsForced"] = true
        }

        return result
    }

    private func playbackMethod(fromDecisionText decisionText: String?) -> RemotePlaybackMethod? {
        guard let decision = decisionText?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !decision.isEmpty else {
            return nil
        }

        if decision.contains("transcode") {
            return .transcode
        }
        if decision.contains("direct stream") || decision.contains("directstream") || decision.contains("copy") {
            return .directStream
        }
        if decision.contains("direct play") || decision.contains("directplay") {
            return .directPlay
        }

        return nil
    }

    private func watchlistRatingKey(from guid: String) -> String? {
        let trimmedGuid = guid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedGuid.isEmpty else { return nil }
        return trimmedGuid.split(separator: "/").last.map(String.init)
    }

    private func parseWatchlistedState(from data: Data) -> Bool {
        if let json = try? JSONSerialization.jsonObject(with: data, options: []),
           let dictionary = json as? [String: Any],
           let watchlisted = watchlistedStateValue(in: dictionary) {
            return watchlisted
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return false
        }
        guard let range = text.range(of: "watchlistedAt=\"") else {
            return false
        }
        let valueStart = range.upperBound
        guard let valueEnd = text[valueStart...].firstIndex(of: "\"") else {
            return false
        }
        let rawValue = String(text[valueStart..<valueEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        return !rawValue.isEmpty && rawValue != "0"
    }

    private func watchlistedStateValue(in dictionary: [String: Any]) -> Bool? {
        if let value = normalizedWatchlistedState(from: dictionary["watchlistedAt"]) {
            return value
        }

        if let mediaContainer = dictionary["MediaContainer"] as? [String: Any],
           let value = watchlistedStateValue(in: mediaContainer) {
            return value
        }

        if let userState = dictionary["UserState"] as? [String: Any],
           let value = normalizedWatchlistedState(from: userState["watchlistedAt"]) {
            return value
        }

        if let userStates = dictionary["UserState"] as? [[String: Any]] {
            for userState in userStates {
                if let value = normalizedWatchlistedState(from: userState["watchlistedAt"]) {
                    return value
                }
            }
        }

        if let metadata = dictionary["Metadata"] as? [[String: Any]] {
            for item in metadata {
                if let value = normalizedWatchlistedState(from: item["watchlistedAt"]) {
                    return value
                }
            }
        }

        return nil
    }

    private func normalizedWatchlistedState(from rawValue: Any?) -> Bool? {
        guard let rawValue else { return nil }

        if rawValue is NSNull {
            return false
        }
        if let number = rawValue as? NSNumber {
            return number.doubleValue > 0
        }
        if let string = rawValue as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "0" || trimmed.lowercased() == "null" {
                return false
            }
            return true
        }

        return false
    }
    
    private func resolvedToken(from server: ServerConfig) -> String? {
        if let token = server.accessToken, !token.isEmpty {
            return token
        }
        if let token = server.passwordSecret, !token.isEmpty {
            return token
        }
        return nil
    }

    private func applyPlexHeaders(to request: inout URLRequest, server: ServerConfig? = nil) {
        request.setValue(clientName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(clientVersion, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(deviceName, forHTTPHeaderField: "X-Plex-Device")
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(UIDevice.current.systemVersion, forHTTPHeaderField: "X-Plex-Platform-Version")
        request.setValue(deviceId, forHTTPHeaderField: "X-Plex-Client-Identifier")
        if let server,
           let token = resolvedToken(from: server),
           !token.isEmpty {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
    }

    private func applyPlexClientProfileHeaders(to request: inout URLRequest) {
        request.setValue("generic", forHTTPHeaderField: "X-Plex-Client-Profile-Name")
    }
}

struct PlexPin {
    let id: Int
    let code: String
    let authToken: String?
}


enum PlexError: LocalizedError {
    case invalidURL
    case invalidResponse
    case unauthorized
    case serverError(Int)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return NSLocalizedString("Invalid Plex server address", comment: "")
        case .invalidResponse:
            return NSLocalizedString("Plex server returned an invalid response", comment: "")
        case .unauthorized:
            return NSLocalizedString("Plex server is reachable, but authorization failed. Please check token/sign-in.", comment: "")
        case .serverError(let code):
            return String(format: NSLocalizedString("Plex server responded with status code %d", comment: ""), code)
        }
    }
}

// MARK: - Plex TLS Trust Delegate

/// URLSession delegate that trusts self-signed certificates for Plex connections.
///
/// Plex Media Server uses self-signed TLS certificates for local network access
/// and frequently redirects HTTP requests to HTTPS. Without accepting these
/// certificates, local Plex connections fail with TLS validation errors even
/// when the user has configured the server as plain HTTP.
private class PlexSessionDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Trust the server certificate unconditionally.
        // Plex generates self-signed certificates for local network access,
        // so standard certificate validation will always fail for these hosts.
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
    }
}
