import Foundation

/// One data policy for the three Jellyfin home heroes. Presentation stays in each app shell.
public enum JellyfinHomeCarousel {
    public static let limit = 12
    public static let fields = "Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,Genres,ProviderIds,PrimaryImageTag,ImageTags,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ParentThumbItemId,ParentThumbImageTag,ProductionYear,PremiereDate,OfficialRating,RunTimeTicks,IndexNumber,ParentIndexNumber"

    public enum Source {
        case resume, nextUp, latest

        public var titleKey: String {
            switch self {
            case .resume: return "Continue Watching"
            case .nextUp: return "Next Up"
            case .latest: return "Recently Added"
            }
        }

        public var systemImage: String {
            switch self {
            case .resume: return "clock.fill"
            case .nextUp: return "play.rectangle.fill"
            case .latest: return "sparkles.tv.fill"
            }
        }
    }

    public struct Entry: Identifiable {
        public let item: JellyfinItem
        public let source: Source
        public var id: String { item.id }
    }

    public static func select(_ groups: [(Source, [JellyfinItem])]) -> [Entry] {
        let candidates = groups.flatMap { source, items in
            MediaHomeCarouselSelection.unique(items.filter(hasArtwork), limit: items.count,
                identity: { MediaHomeCarouselSelection.identity(itemID: $0.id, seriesID: $0.seriesId, itemType: $0.type) },
                lastPlayedAt: { MediaHomeCarouselSelection.date($0.userData?.lastPlayedDate) })
                .map { Entry(item: $0, source: source) }
        }
        // Source priority wins across groups: a resumable episode precedes NextUp and its Series card.
        var seen = Set<String>()
        return Array(candidates.filter { entry in
            seen.insert(MediaHomeCarouselSelection.identity(itemID: entry.item.id,
                seriesID: entry.item.seriesId, itemType: entry.item.type)).inserted
        }.prefix(limit))
    }

    private static func hasArtwork(_ item: JellyfinItem) -> Bool {
        item.primaryImageTag != nil || item.imageTags?["Primary"] != nil
            || item.imageTags?["Thumb"] != nil || item.backdropImageTags?.isEmpty == false
            || item.parentBackdropImageTags?.isEmpty == false || item.parentThumbImageTag != nil
            || (["Episode", "Season"].contains(item.type) && item.seriesId?.isEmpty == false)
    }

    public static func load(server: ServerConfig, userId: String, token: String,
                            session: URLSession = .shared) async throws -> [Entry] {
        let base = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func fetch(_ path: String, _ query: [URLQueryItem]) async throws -> [JellyfinItem] {
            try Task.checkCancellation()
            guard var components = URLComponents(string: base + path) else { throw URLError(.badURL) }
            components.queryItems = query + [URLQueryItem(name: "Fields", value: fields)]
            guard let url = components.url else { throw URLError(.badURL) }
            var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
            request.timeoutInterval = 15
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            return try JSONDecoder().decode(JellyfinItemsResponse.self, from: data).items
        }
        func available(_ path: String, _ query: [URLQueryItem]) async throws -> [JellyfinItem] {
            do { return try await fetch(path, query) }
            catch {
                try Task.checkCancellation()
                return [] // A failed source must not hide the other sources.
            }
        }
        let count = URLQueryItem(name: "Limit", value: String(limit * 4))
        let video = URLQueryItem(name: "MediaTypes", value: "Video")
        var resume = try await available("/Users/\(userId)/Items/Resume", [count, video, URLQueryItem(name: "UserId", value: userId)])
        if resume.isEmpty {
            resume = try await available("/Users/\(userId)/Items", [count, video,
                URLQueryItem(name: "Recursive", value: "true"), URLQueryItem(name: "Filters", value: "IsResumable"),
                URLQueryItem(name: "SortBy", value: "DatePlayed"), URLQueryItem(name: "SortOrder", value: "Descending")])
        }
        var groups: [(Source, [JellyfinItem])] = [(.resume, resume)]
        if select(groups).count < limit {
            let next = try await available("/Shows/NextUp", [count, URLQueryItem(name: "UserId", value: userId)])
            groups.append((.nextUp, next))
        }
        if select(groups).count < limit {
            let latest = try await available("/Users/\(userId)/Items", [
                URLQueryItem(name: "Limit", value: String(limit * 2)), URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                URLQueryItem(name: "SortBy", value: "DateCreated"), URLQueryItem(name: "SortOrder", value: "Descending")])
            groups.append((.latest, latest))
        }
        return select(groups)
    }
}

/// Home heroes represent shows, while shelves and playback queues still represent individual episodes.
public enum MediaHomeCarouselSelection {
    public static func identity(itemID: String, seriesID: String?, itemType: String) -> String {
        func canonical(_ id: String) -> String {
            let prefix = "/library/metadata/"
            return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) : id
        }
        switch itemType.lowercased() {
        case "series", "show": return "series:" + canonical(itemID)
        case "episode", "season":
            if let seriesID, !seriesID.isEmpty { return "series:" + canonical(seriesID) }
        default: break
        }
        return "item:" + canonical(itemID)
    }

    public static func date(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    /// Keep the first source's position; select its newest played episode when timestamps are available.
    /// Missing timestamps preserve server ordering, never infer recency from episode numbers or progress.
    public static func unique<Item>(_ items: [Item], limit: Int, identity: (Item) -> String,
                                    lastPlayedAt: (Item) -> Date?) -> [Item] {
        guard limit > 0 else { return [] }
        var result: [Item] = []
        var positions: [String: Int] = [:]
        for item in items {
            let key = identity(item)
            if let index = positions[key] {
                if let candidateDate = lastPlayedAt(item), let currentDate = lastPlayedAt(result[index]),
                   candidateDate > currentDate {
                    result[index] = item
                }
            } else {
                positions[key] = result.count
                result.append(item)
            }
        }
        return Array(result.prefix(limit))
    }
}
