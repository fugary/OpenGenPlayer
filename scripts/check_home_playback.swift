import Foundation

// Only the input record shape is stubbed. Requests, decoding, selection and credential handling are production code.
public struct VideoFile {
    var url: URL
    var jellyfinServerId: String?
    var serverType: ServerConfig.ServerType?
}

final class FixtureProtocol: URLProtocol {
    static var handler: (URLRequest) -> (Int, [[String: Any]]) = { _ in (200, []) }
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        let (status, items) = Self.handler(request)
        let data = try! JSONSerialization.data(withJSONObject: ["Items": items])
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct Checks {
    static func item(_ id: String, type: String = "Movie", artwork: Bool = true) -> [String: Any] {
        var value: [String: Any] = ["Id": id, "Name": id, "Type": type]
        if artwork { value["PrimaryImageTag"] = "image" }
        return value
    }
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        print("PASS: " + message)
    }
    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let server = ServerConfig(name: "fixture", address: "fixture.invalid", type: .jellyfin)
        FixtureProtocol.handler = { request in
            let url = request.url!
            if url.path.hasSuffix("Resume") { return (200, [item("movie"), item("episode", type: "Episode"), item("no-art", artwork: false)]) }
            if url.path.hasSuffix("NextUp") { return (200, [item("episode", type: "Episode"), item("next", type: "Episode")]) }
            return (200, (0..<24).map { item("latest-\($0)", type: "Series") })
        }
        let result = try await JellyfinHomeCarousel.load(server: server, userId: "user", token: "fixture-token", session: session)
        check(result.count == 12 && Set(result.map(\.id)).count == 12, "12-item cap and cross-source deduplication")
        check(Array(result.prefix(3).map(\.id)) == ["movie", "episode", "next"], "mixed movie/episode resume items retained in server order before next-up/latest")
        check(result[0].source == .resume && result[2].source == .nextUp && result[3].source == .latest, "source labels preserved")
        check(FixtureProtocol.requests.count == 3 && FixtureProtocol.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token" }, "bounded shared requests carry authentication")
        let latestQuery = URLComponents(url: FixtureProtocol.requests.last!.url!, resolvingAgainstBaseURL: false)!.queryItems!
        check(latestQuery.contains(URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series")) && latestQuery.contains(URLQueryItem(name: "SortBy", value: "DateCreated")), "latest fallback uses explicit movie/series scope and ordering")

        FixtureProtocol.requests = []
        FixtureProtocol.handler = { request in
            if request.url!.path.hasSuffix("Resume") { return (503, []) }
            if request.url!.path.hasSuffix("NextUp") { return (503, []) }
            let filters = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            return filters.contains(URLQueryItem(name: "Filters", value: "IsResumable")) ? (200, [item("fallback")]) : (200, [item("latest")])
        }
        let fallback = try await JellyfinHomeCarousel.load(server: server, userId: "user", token: "token", session: session)
        check(fallback.map(\.id) == ["fallback", "latest"] && FixtureProtocol.requests.count == 4, "resume endpoint failure falls back and failed next-up does not block latest")
        FixtureProtocol.requests = []
        FixtureProtocol.handler = { _ in (200, (0..<12).map { item("resume-\($0)") }) }
        let full = try await JellyfinHomeCarousel.load(server: server, userId: "user", token: "token", session: session)
        check(full.count == 12 && FixtureProtocol.requests.count == 1, "full resume response avoids extra requests")
        FixtureProtocol.handler = { _ in (200, []) }
        let empty = try await JellyfinHomeCarousel.load(server: server, userId: "user", token: "token", session: session)
        check(empty.isEmpty, "empty server data does not create placeholder carousel entries")
        let cancelled = Task { try await JellyfinHomeCarousel.load(server: server, userId: "user", token: "token", session: session) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("cancellation ignored") } catch is CancellationError {} catch { throw error }
        check(true, "cancelled homepage load cannot return stale results")

        func episode(_ id: String, series: String, date: String? = nil) throws -> JellyfinItem {
            var raw = item(id, type: "Episode")
            raw["SeriesId"] = series
            if let date { raw["UserData"] = ["LastPlayedDate": date] }
            return try JSONDecoder().decode(JellyfinItem.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        let older = try episode("episode-old", series: "show-A", date: "2026-10-01T10:00:00Z")
        let newer = try episode("episode-new", series: "show-A", date: "2026-10-03T10:00:00.1234567Z")
        let other = try episode("episode-B", series: "show-B", date: "2026-10-02T10:00:00Z")
        let series = try JSONDecoder().decode(JellyfinItem.self, from: JSONSerialization.data(withJSONObject: item("show-A", type: "Series")))
        let nextA = try episode("next-A", series: "show-A")
        let selected = JellyfinHomeCarousel.select([(.resume, [older, other, newer]), (.nextUp, [nextA]), (.latest, [series])])
        check(selected.map(\.id) == ["episode-new", "episode-B"], "one hero per show keeps latest played episode and excludes next-up/series duplicates")
        check(selected[0].item.userData?.lastPlayedDate == "2026-10-03T10:00:00.1234567Z", "last-played metadata survives decoding")
        let noDate1 = try episode("no-date-first", series: "show-C")
        let noDate2 = try episode("no-date-second", series: "show-C")
        check(JellyfinHomeCarousel.select([(.resume, [noDate1, noDate2])]).map(\.id) == ["no-date-first"], "missing last-played date preserves server ordering")
        let missingID1 = try JSONDecoder().decode(JellyfinItem.self, from: JSONSerialization.data(withJSONObject: item("unrelated1", type: "Episode")))
        let missingID2 = try JSONDecoder().decode(JellyfinItem.self, from: JSONSerialization.data(withJSONObject: item("unrelated2", type: "Episode")))
        check(JellyfinHomeCarousel.select([(.resume, [missingID1, missingID2])]).count == 2, "missing series identity never merges unrelated episodes by title")
        check(MediaHomeCarouselSelection.identity(itemID: "episode", seriesID: "123", itemType: "episode") == MediaHomeCarouselSelection.identity(itemID: "/library/metadata/123", seriesID: nil, itemType: "show"), "Plex ratingKey and metadata path resolve to the same show identity")
        let embyUser = try JSONDecoder().decode(EmbyUserData.self, from: Data("{\"LastPlayedDate\":\"2026-10-03T10:00:00Z\"}".utf8))
        check(MediaHomeCarouselSelection.date(embyUser.lastPlayedDate) != nil, "Emby last-played metadata is decoded for the shared show selection")
        let plexOld = PlexItem(dictionary: ["ratingKey": "p-old", "title": "Episode", "type": "episode", "grandparentRatingKey": "show-p", "lastViewedAt": 100])
        let plexNew = PlexItem(dictionary: ["ratingKey": "p-new", "title": "Episode", "type": "episode", "grandparentRatingKey": "show-p", "lastViewedAt": 200])
        let plexResult = MediaHomeCarouselSelection.unique([plexOld, plexNew], limit: 12,
            identity: { MediaHomeCarouselSelection.identity(itemID: $0.id, seriesID: $0.grandparentRatingKey, itemType: $0.type) },
            lastPlayedAt: { $0.lastViewedAt })
        check(plexResult.count == 1 && plexResult[0].id == "p-new", "Plex uses lastViewedAt to retain the most recently watched episode")
        let active = RemotePlaybackResumeDecision.fromServerPlaybackState(playbackTicks: 44_000_000, runtimeTicks: 100_000_000, playedPercentage: nil).progressSnapshot!
        check(Int(active.displayedProgress * 100) == 44 && !active.isFinished, "active hero progress uses the same 44-percent resume calculation")
        let complete = RemotePlaybackResumeDecision.fromServerPlaybackState(playbackTicks: 95_000_000, runtimeTicks: 100_000_000, playedPercentage: nil).progressSnapshot!
        check(complete.isFinished, "completed hero does not advertise continuing a finished item")

        let id = UUID()
        var smb = ServerConfig(id: id, name: "NAS", address: "nas.invalid", type: .smb, username: "new user", passwordSecret: "新:#@/?密码", workgroup: "WORKGROUP")
        let original = URL(string: "smb://old:expired@nas.invalid/share/film%20%231.mp4")!
        let file = VideoFile(url: original, jellyfinServerId: id.uuidString, serverType: .smb)
        let matching = FilePlaybackCredentials.matchingServer(for: file, in: [server, smb])
        let runtime = FilePlaybackCredentials.runtimeURL(original, server: matching)
        let parts = URLComponents(url: runtime, resolvingAgainstBaseURL: false)!
        check(parts.user == "WORKGROUP;new user" && parts.password == smb.passwordSecret && parts.percentEncodedPath == URLComponents(url: original, resolvingAgainstBaseURL: false)!.percentEncodedPath, "SMB uses current domain/account/password without changing escaped file path")
        check(file.url == original, "credential restoration does not mutate persisted record")
        smb.username = nil; smb.passwordSecret = nil
        let guest = URLComponents(url: FilePlaybackCredentials.runtimeURL(original, server: smb), resolvingAgainstBaseURL: false)!
        check(guest.user == nil && guest.password == nil, "guest server removes stale historical credentials")
        let deleted = VideoFile(url: original, jellyfinServerId: UUID().uuidString, serverType: .smb)
        check(FilePlaybackCredentials.matchingServer(for: deleted, in: [smb]) == nil, "deleted explicit server ID never switches accounts")
        let legacy = VideoFile(url: original, jellyfinServerId: nil, serverType: .smb)
        let another = ServerConfig(name: "other", address: "nas.invalid", type: .smb)
        check(FilePlaybackCredentials.matchingServer(for: legacy, in: [smb, another]) == nil, "ambiguous legacy accounts are not guessed")
        check(FilePlaybackCredentials.matchingServer(for: legacy, in: [server, smb])?.id == id, "legacy lookup is restricted to matching protocol/host/port")
        for (type, scheme) in [(ServerConfig.ServerType.webdav, "https"), (.ftp, "ftps"), (.sftp, "sftp")] {
            let account = ServerConfig(name: "account", address: "nas.invalid", type: type, username: "user", passwordSecret: "new")
            let url = URL(string: "\(scheme)://old:expired@nas.invalid/path/movie.mkv")!
            let result = URLComponents(url: FilePlaybackCredentials.runtimeURL(url, server: account), resolvingAgainstBaseURL: false)!
            check(result.user == "user" && result.password == "new" && result.path == "/path/movie.mkv", "\(type) restores current credentials and retains media path")
        }
        check(FilePlaybackCredentials.runtimeURL(original, server: server) == original, "media-server token is never injected as file-server credentials")
    }
}
