import Foundation
import Combine

public final class VODService: ObservableObject {
    public static let shared = VODService()
    /// Kept consistent between API requests and VLC playback for VOD hosts that reject
    /// clients without a browser-like User-Agent.
    public static let defaultUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

    @Published public private(set) var cachedCategories: [UUID: [VODCategory]] = [:]
    @Published public private(set) var loadingServers: Set<UUID> = []
    @Published public private(set) var errorMessages: [UUID: String] = [:]

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        config.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            "Accept": "application/json, text/plain, */*"
        ]
        self.session = URLSession(configuration: config)
    }

    // MARK: - URL Builder

    public func endpointURL(for server: ServerConfig, queryItems: [URLQueryItem]) -> URL? {
        var baseString = server.fullURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !baseString.contains("api.php") {
            if !baseString.hasSuffix("/") {
                baseString += "/"
            }
            baseString += "api.php/provide/vod/"
        }

        guard var components = URLComponents(string: baseString) else { return nil }
        var currentItems = components.queryItems ?? []
        currentItems.append(contentsOf: queryItems)
        components.queryItems = currentItems
        return components.url
    }

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        return request
    }

    private func validateResponse(_ response: VODResponse) throws -> VODResponse {
        guard response.code?.value == 1 else {
            let message = response.msg?.trimmingCharacters(in: .whitespacesAndNewlines)
            let description = message.flatMap { $0.isEmpty ? nil : $0 }
                ?? URLError(.badServerResponse).localizedDescription
            throw NSError(
                domain: "VODService",
                code: response.code?.value ?? -1,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
        return response
    }

    // MARK: - Fetch Categories

    public func fetchCategories(server: ServerConfig, forceRefresh: Bool = false) async throws -> [VODCategory] {
        if !forceRefresh, let cached = cachedCategories[server.id], !cached.isEmpty {
            return cached
        }

        guard let url = endpointURL(for: server, queryItems: [URLQueryItem(name: "ac", value: "list")]) else {
            throw URLError(.badURL)
        }

        await MainActor.run {
            self.loadingServers.insert(server.id)
            self.errorMessages.removeValue(forKey: server.id)
        }

        defer {
            Task { @MainActor in
                self.loadingServers.remove(server.id)
            }
        }

        do {
            let (data, response) = try await session.data(for: makeRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                throw NSError(domain: "VODService", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP error: \(code)"])
            }

            let decoded = try validateResponse(JSONDecoder().decode(VODResponse.self, from: data))
            let categories = decoded.categories ?? []

            await MainActor.run {
                self.cachedCategories[server.id] = categories
            }
            return categories
        } catch {
            await MainActor.run {
                self.errorMessages[server.id] = error.localizedDescription
            }
            throw error
        }
    }

    // MARK: - Fetch Video List

    public func fetchList(
        server: ServerConfig,
        typeId: String? = nil,
        page: Int = 1
    ) async throws -> (items: [VODItem], totalPages: Int, totalCount: Int) {
        var queries = [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "pg", value: String(page))
        ]
        if let typeId = typeId, !typeId.isEmpty, typeId != "ALL" {
            queries.append(URLQueryItem(name: "t", value: typeId))
        }

        guard let url = endpointURL(for: server, queryItems: queries) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(for: makeRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "VODService", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP error: \(code)"])
        }

        let decoded = try validateResponse(JSONDecoder().decode(VODResponse.self, from: data))
        let items = decoded.list ?? []
        let totalPages = max(1, decoded.pagecount?.value ?? 1)
        let totalCount = decoded.total?.value ?? items.count

        return (items, totalPages, totalCount)
    }

    // MARK: - Search

    public func search(
        server: ServerConfig,
        keyword: String,
        page: Int = 1,
        typeId: String? = nil
    ) async throws -> (items: [VODItem], totalPages: Int, totalCount: Int) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], 1, 0) }

        var queries = [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "wd", value: trimmed),
            URLQueryItem(name: "pg", value: String(page))
        ]

        if let typeId, !typeId.isEmpty, typeId != "ALL" {
            queries.append(URLQueryItem(name: "t", value: typeId))
        }

        guard let url = endpointURL(for: server, queryItems: queries) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(for: makeRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "VODService", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP error: \(code)"])
        }

        let decoded = try validateResponse(JSONDecoder().decode(VODResponse.self, from: data))
        let items = decoded.list ?? []
        return (items, max(1, decoded.pagecount?.value ?? 1), decoded.total?.value ?? items.count)
    }

    // MARK: - Fetch Detail

    public func fetchDetail(server: ServerConfig, vodId: String) async throws -> VODItem? {
        let queries = [
            URLQueryItem(name: "ac", value: "detail"),
            URLQueryItem(name: "ids", value: vodId)
        ]
        guard let url = endpointURL(for: server, queryItems: queries) else {
            throw URLError(.badURL)
        }

        let (data, response) = try await session.data(for: makeRequest(url: url))
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "VODService", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP error: \(code)"])
        }

        let decoded = try validateResponse(JSONDecoder().decode(VODResponse.self, from: data))
        return decoded.list?.first
    }

    // MARK: - VideoFile Builder

    public func makeVideoFile(
        for episode: VODEpisode,
        item: VODItem,
        server: ServerConfig,
        source: VODPlaySource
    ) -> VideoFile {
        VideoFile(
            name: "\(item.vodName) - \(episode.name)",
            url: episode.url,
            type: .video,
            size: 0,
            date: Date(),
            isRemote: true,
            duration: nil,
            lastPlayedPosition: nil,
            jellyfinItemId: "\(server.id.uuidString)_\(item.vodId.value)_\(source.index)_\(episode.index)",
            jellyfinServerId: server.id.uuidString,
            serverType: .vod,
            customArtworkURL: item.vodPic.flatMap { URL(string: $0) },
            seriesId: item.vodId.value,
            seasonId: String(source.index)
        )
    }
}
