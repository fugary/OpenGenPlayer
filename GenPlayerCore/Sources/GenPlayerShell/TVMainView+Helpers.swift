#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


enum TVRowFocusStyle {
    static func focusedFill(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.white.opacity(0.94)
    }

    static func primary(
        showsFocus: Bool,
        isEnabled: Bool,
        colorScheme: ColorScheme,
        isDestructive: Bool = false
    ) -> Color {
        guard isEnabled else { return TVShellStyle.secondary.opacity(0.46) }
        if isDestructive { return Color.red.opacity(showsFocus ? 0.95 : 0.92) }
        if showsFocus {
            return colorScheme == .dark ? Color.black.opacity(0.88) : TVShellStyle.primary
        }
        return TVShellStyle.primary
    }

    static func secondary(showsFocus: Bool, isEnabled: Bool, colorScheme: ColorScheme) -> Color {
        guard isEnabled else { return TVShellStyle.secondary.opacity(0.34) }
        if showsFocus {
            return colorScheme == .dark ? Color.black.opacity(0.60) : TVShellStyle.secondary
        }
        return TVShellStyle.secondary
    }
}



struct TVAppBrandMark: View {
    let width: CGFloat
    let height: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: min(width, height) * 0.18, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(red: 0.44, green: 0.04, blue: 0.76),
                            Color(red: 0.12, green: 0.12, blue: 0.52),
                            Color(red: 0.02, green: 0.26, blue: 0.58)
                        ]),
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    )
                )

            TVAppPlayNetworkMark()
                .frame(width: width * 0.70, height: height * 0.74)
                .offset(x: width * 0.02)
        }
        .frame(width: width, height: height)
        .shadow(color: Color.black.opacity(0.18), radius: height * 0.16, x: 0, y: height * 0.08)
        .accessibilityHidden(true)
    }
}



struct TVAppPlayNetworkMark: View {
    private static let points: [(CGFloat, CGFloat)] = [
        (0.17, 0.22),
        (0.31, 0.37),
        (0.50, 0.29),
        (0.65, 0.41),
        (0.79, 0.39),
        (0.30, 0.56),
        (0.50, 0.50),
        (0.64, 0.63),
        (0.79, 0.58),
        (0.18, 0.80),
        (0.47, 0.82),
        (0.56, 0.12),
        (0.08, 0.48)
    ]
    private static let edges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (1, 5), (5, 6), (6, 7), (7, 8),
        (5, 9), (9, 10), (6, 10), (0, 12),
        (12, 5), (11, 2), (11, 3), (2, 6),
        (3, 7), (4, 8), (1, 6), (2, 7)
    ]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let resolvedPoints = Self.points.map { point in
                CGPoint(x: point.0 * size.width, y: point.1 * size.height)
            }
            let lineWidth = max(1.0, size.height * 0.040)
            let nodeSize = max(3.0, size.height * 0.135)

            ZStack {
                TVRoundedPlayShape()
                    .fill(Color.white.opacity(0.96))

                ZStack {
                    ForEach(Self.edges.indices, id: \.self) { index in
                        let edge = Self.edges[index]
                        Path { path in
                            path.move(to: resolvedPoints[edge.0])
                            path.addLine(to: resolvedPoints[edge.1])
                        }
                        .stroke(
                            Color(red: 0.18, green: 0.07, blue: 0.48).opacity(0.92),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
                        )
                    }

                    ForEach(resolvedPoints.indices, id: \.self) { index in
                        Circle()
                            .fill(Color(red: 0.34, green: 0.06, blue: 0.68).opacity(0.96))
                            .frame(width: nodeSize, height: nodeSize)
                            .position(resolvedPoints[index])
                    }
                }
                .clipShape(TVRoundedPlayShape())
            }
        }
    }
}



struct TVRoundedPlayShape: Shape {
    func path(in rect: CGRect) -> Path {
        let points = [
            CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.04),
            CGPoint(x: rect.minX + rect.width * 0.88, y: rect.midY),
            CGPoint(x: rect.minX + rect.width * 0.08, y: rect.minY + rect.height * 0.96)
        ]
        return roundedPolygonPath(points: points, radius: min(rect.width, rect.height) * 0.16)
    }

    private func roundedPolygonPath(points: [CGPoint], radius: CGFloat) -> Path {
        var path = Path()
        guard points.count > 2 else { return path }

        for index in points.indices {
            let previous = points[(index - 1 + points.count) % points.count]
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let previousLength = hypot(current.x - previous.x, current.y - previous.y)
            let nextLength = hypot(current.x - next.x, current.y - next.y)
            let cornerRadius = min(radius, previousLength * 0.42, nextLength * 0.42)
            let previousUnit = CGPoint(
                x: (previous.x - current.x) / previousLength,
                y: (previous.y - current.y) / previousLength
            )
            let nextUnit = CGPoint(
                x: (next.x - current.x) / nextLength,
                y: (next.y - current.y) / nextLength
            )
            let start = CGPoint(
                x: current.x + previousUnit.x * cornerRadius,
                y: current.y + previousUnit.y * cornerRadius
            )
            let end = CGPoint(
                x: current.x + nextUnit.x * cornerRadius,
                y: current.y + nextUnit.y * cornerRadius
            )

            if index == points.startIndex {
                path.move(to: start)
            } else {
                path.addLine(to: start)
            }
            path.addQuadCurve(to: end, control: current)
        }

        path.closeSubpath()
        return path
    }
}



@ViewBuilder
func tvDestructiveContextMenuButton(
    title: String,
    systemImageName: String,
    action: @escaping () -> Void
) -> some View {
    if #available(tvOS 15.0, *) {
        Button(role: .destructive, action: action) {
            Label(title, systemImage: systemImageName)
        }
    } else {
        Button(action: action) {
            Label {
                Text(title)
                    .foregroundColor(.red)
            } icon: {
                Image(systemName: systemImageName)
                    .foregroundColor(.red)
            }
        }
    }
}



@ViewBuilder
func tvDestructiveMenuButton(title: String, systemImageName: String, action: @escaping () -> Void) -> some View {
    if #available(tvOS 15.0, *) {
        Button(role: .destructive, action: action) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImageName)
            }
        }
    } else {
        Button(action: action) {
            TVDestructiveMenuLabel(title: title, systemImageName: systemImageName)
        }
    }
}



@ViewBuilder
func tvDeleteHistoryMenuButton(file: VideoFile, action: @escaping () -> Void) -> some View {
    tvDestructiveMenuButton(
        title: platformShellString("Delete Record"),
        systemImageName: "trash",
        action: action
    )
}



@ViewBuilder
func tvRemoveFavoriteMenuButton(item: FavoriteItem, action: @escaping () -> Void) -> some View {
    tvDestructiveMenuButton(
        title: platformShellString("Remove Favorite"),
        systemImageName: "star.slash",
        action: action
    )
}



func tvDeleteHistoryAlert(for file: VideoFile, action: @escaping () -> Void) -> Alert {
    Alert(
        title: Text(platformShellString("Delete Record")),
        message: Text(tvDisplayTitle(for: file)),
        primaryButton: .destructive(Text(platformShellString("Delete"))) {
            action()
        },
        secondaryButton: .cancel(Text(platformShellString("Cancel")))
    )
}



func tvRemoveFavoriteAlert(for item: FavoriteItem, action: @escaping () -> Void) -> Alert {
    Alert(
        title: Text(platformShellString("Remove Favorite")),
        message: Text(tvDisplayTitle(for: item.file)),
        primaryButton: .destructive(Text(platformShellString("Remove Favorite"))) {
            action()
        },
        secondaryButton: .cancel(Text(platformShellString("Cancel")))
    )
}



struct TVDownloadFilterBar: View {
    @Binding var selectedFilter: TVDownloadListFilter
    let activeCount: Int
    let completedCount: Int
    let failedCount: Int

    var body: some View {
        Picker("", selection: $selectedFilter) {
            ForEach(TVDownloadListFilter.allCases, id: \.self) { filter in
                Label {
                    Text(title(for: filter))
                } icon: {
                    Image(systemName: filter.systemImageName)
                }
                .tag(filter)
            }
        }
        .pickerStyle(SegmentedPickerStyle())
        .frame(width: 640, alignment: .leading)
        .tvFocusSectionIfAvailable()
    }

    private func count(for filter: TVDownloadListFilter) -> Int {
        switch filter {
        case .active:
            return activeCount
        case .completed:
            return completedCount
        case .failed:
            return failedCount
        }
    }

    private func title(for filter: TVDownloadListFilter) -> String {
        "\(platformShellString(filter.titleKey)) \(count(for: filter))"
    }
}



struct TVDownloadSelectedFilterSummary: View {
    let filter: TVDownloadListFilter
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: filter.systemImageName)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(iconColor)
                .frame(width: 38, height: 38)
                .background(
                    Circle()
                        .fill(iconColor.opacity(0.16))
                )

            Text(platformShellString(filter.titleKey))
                .font(.system(size: 26, weight: .heavy))
                .foregroundColor(TVShellStyle.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.78)

            Text("\(count)")
                .font(.system(size: 20, weight: .heavy, design: .monospaced))
                .foregroundColor(TVShellStyle.secondary)
                .padding(.horizontal, 11)
                .frame(height: 32)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .frame(minWidth: 190, alignment: .leading)
        .frame(height: 58)
        .accessibilityElement(children: .combine)
    }

    private var iconColor: Color {
        switch filter {
        case .active:
            return TVShellStyle.accentSoft
        case .completed:
            return Color(red: 0.48, green: 0.88, blue: 0.62)
        case .failed:
            return Color(red: 1.0, green: 0.48, blue: 0.40)
        }
    }
}



extension EnvironmentValues {
    var tvSettingsInlinePresentation: Bool {
        get { self[TVSettingsInlinePresentationKey.self] }
        set { self[TVSettingsInlinePresentationKey.self] = newValue }
    }

    var tvSettingsGoBack: (() -> Void)? {
        get { self[TVSettingsGoBackKey.self] }
        set { self[TVSettingsGoBackKey.self] = newValue }
    }

    var tvSettingsNavigationTransitionNamespace: Namespace.ID? {
        get { self[TVSettingsNavigationTransitionNamespaceKey.self] }
        set { self[TVSettingsNavigationTransitionNamespaceKey.self] = newValue }
    }
}



enum TVICloudServerListSyncAvailability {
    static var isAvailable: Bool {
        // Server-list sync uses iCloud key-value storage, not an iCloud Documents container.
        true
    }
}



func tvTestServerConnectionWithTimeout(_ server: ServerConfig) async throws -> ServerConfig {
    let connectionTask = Task {
        try await tvTestServerConnection(server)
    }

    return try await withThrowingTaskGroup(of: ServerConfig.self) { group in
        group.addTask {
            let result = try await connectionTask.value
            return result
        }

        group.addTask {
            try await Task.sleep(nanoseconds: 15_000_000_000)
            connectionTask.cancel()
            throw NSError(
                domain: "GenPlayerShell",
                code: NSURLErrorTimedOut,
                userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection timed out")]
            )
        }

        do {
            if let first = try await group.next() {
                group.cancelAll()
                return first
            } else {
                throw CancellationError()
            }
        } catch {
            group.cancelAll()
            connectionTask.cancel()
            throw error
        }
    }
}



@ViewBuilder
func tvServerHomeDestination(for server: ServerConfig) -> some View {
    if server.type == .vod {
        TVVODLibraryView(server: server)
    } else if server.type.tvIsMediaLibraryServer {
        TVMediaLibraryBrowserView(server: server, title: server.name, parentNode: nil)
    } else {
        TVRemoteBrowserView(server: server, path: "/", rootTitle: server.name)
    }
}



final class TVSpotlightCarouselFocusView: UIView {
    var onMoveLeft: (() -> Void)?
    var onMoveRight: (() -> Void)?
    var onSelect: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?

    override var canBecomeFocused: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    func configureView() {
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusChanged?(isFocused)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var didHandlePress = false

        for press in presses {
            switch press.type {
            case .select:
                onSelect?()
                didHandlePress = true
            case .leftArrow:
                onMoveLeft?()
                didHandlePress = true
            case .rightArrow:
                onMoveRight?()
                didHandlePress = true
            default:
                break
            }
        }

        if !didHandlePress {
            super.pressesBegan(presses, with: event)
        }
    }
}



@ViewBuilder
func tvMediaLibraryDestination(server: ServerConfig, node: TVMediaLibraryNode) -> some View {
    let rawType = node.rawItemType.lowercased()
    if rawType == "episode" || rawType == "season" {
        if tvTrimmedText(node.seriesId) != nil {
            TVMediaLibraryResolvedSeriesNodeView(server: server, node: node)
        } else {
            TVLibraryLeafDetailView(server: server, node: node)
        }
    } else if node.isSeries {
        TVSeriesDetailView(server: server, node: node)
    } else if node.isFolder {
        TVMediaLibraryBrowserView(server: server, title: tvDisplayTitle(from: node.name, type: .folder), parentNode: node)
    } else {
        TVLibraryLeafDetailView(server: server, node: node)
    }
}



func tvFetchMediaLibraryContinueWatchingItems(
    server: ServerConfig,
    limit: Int
) async throws -> [TVMediaLibraryFeaturedItem] {
    guard limit > 0 else { return [] }

    switch server.type {
    case .jellyfin:
        return try await tvFetchJellyfinContinueWatchingItems(server: server, limit: limit)
    case .emby:
        return try await tvFetchEmbyContinueWatchingItems(server: server, limit: limit)
    case .plex:
        return try await tvFetchPlexContinueWatchingItems(server: server, limit: limit)
    default:
        return []
    }
}



func tvFetchMediaLibraryFavoriteNodes(
    server: ServerConfig,
    limit: Int = 50
) async throws -> [TVMediaLibraryNode] {
    guard limit > 0 else { return [] }

    switch server.type {
    case .jellyfin, .emby:
        return try await tvFetchJellyfinLikeFavoriteNodes(server: server, limit: limit)
    case .plex:
        return try await tvFetchPlexFavoriteNodes(server: server, limit: limit)
    default:
        return []
    }
}



func tvFetchJellyfinLikeFavoriteNodes(
    server: ServerConfig,
    limit: Int = 50
) async throws -> [TVMediaLibraryNode] {
    let authenticatedServer = try await tvPreparedMediaLibraryServer(server: server)
    guard let userId = try await tvResolvedMediaLibraryUserId(server: authenticatedServer), !userId.isEmpty else {
        return []
    }

    let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items") else {
        throw URLError(.badURL)
    }

    components.queryItems = [
        URLQueryItem(name: "Recursive", value: "true"),
        URLQueryItem(name: "Filters", value: "IsFavorite"),
        URLQueryItem(name: "Fields", value: tvJellyfinLikeRichItemFields),
        URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode,Video,MusicAlbum,MusicArtist"),
        URLQueryItem(name: "SortBy", value: "SortName"),
        URLQueryItem(name: "SortOrder", value: "Ascending"),
        URLQueryItem(name: "Limit", value: String(limit))
    ]

    guard let url = components.url else {
        throw URLError(.badURL)
    }

    let root = try await tvFetchMediaLibraryJSONObject(from: url, server: authenticatedServer)
    var nodes = tvJellyfinLikeNodes(from: root, baseURL: baseURL, parentNode: nil, shouldSort: false)
    for i in 0..<nodes.count {
        nodes[i].isFavorite = true
    }
    return nodes
}



func tvFetchPlexFavoriteNodes(
    server: ServerConfig,
    limit: Int = 50
) async throws -> [TVMediaLibraryNode] {
    let serverIdStr = server.id.uuidString
    let serverFavs = FavoriteService.shared.favorites.filter { fav in
        fav.file.jellyfinServerId == serverIdStr
    }
    return serverFavs.prefix(limit).map { fav in
        tvPlexFavoriteNode(from: fav, server: server)
    }
}



func tvPlexFavoriteNode(from favoriteItem: FavoriteItem, server: ServerConfig) -> TVMediaLibraryNode {
    let file = favoriteItem.file
    let id = file.jellyfinItemId ?? favoriteItem.id
    return TVMediaLibraryNode(
        id: id,
        name: file.name,
        type: file.type,
        isFolder: file.type == .folder,
        remotePath: file.serverPath ?? file.url.path,
        posterURL: file.customArtworkURL,
        summary: nil,
        metadataLine: file.tvFormatBadgeText,
        isLibraryRoot: false,
        libraryCollectionType: nil,
        backdropURL: nil,
        logoURL: nil,
        genres: [],
        year: nil,
        premiereDate: nil,
        runtimeTicks: file.duration != nil ? Int64(file.duration! * 10_000_000) : nil,
        rating: nil,
        communityRating: nil,
        childCount: nil,
        people: [],
        rawItemType: file.type == .folder ? "Folder" : "Movie",
        seriesId: file.seriesId,
        seasonId: file.seasonId,
        seriesName: nil,
        indexNumber: nil,
        parentIndexNumber: nil,
        isFavorite: true,
        isPlayed: nil,
        playbackPositionSeconds: file.lastPlayedPosition,
        playbackProgress: nil,
        videoWidth: nil,
        videoHeight: nil,
        mediaSize: file.size,
        mediaContainer: file.serverContainer,
        downloadRemotePath: file.serverPath
    )
}



func tvFetchMediaLibraryCategoryInfo(
    server: ServerConfig,
    node: TVMediaLibraryNode
) async -> (previewURL: URL?, totalCount: Int?) {
    do {
        let authenticatedServer = try await tvPreparedMediaLibraryServer(server: server)
        if server.type == .plex {
            let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard var components = URLComponents(string: "\(baseURL)/library/sections/\(node.id)/all") else {
                return (nil, nil)
            }
            components.queryItems = [
                URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
                URLQueryItem(name: "X-Plex-Container-Size", value: "1")
            ]
            guard let url = components.url else { return (nil, nil) }
            let root = try await tvFetchMediaLibraryJSONObject(from: url, server: authenticatedServer)
            let container = (root["MediaContainer"] as? [String: Any]) ?? root
            let totalCount = (container["totalSize"] as? Int) ?? (container["size"] as? Int)
            var previewURL: URL? = nil
            if let metadata = (container["Metadata"] as? [[String: Any]]) ?? (root["Metadata"] as? [[String: Any]]), let first = metadata.first {
                let artPath = (first["art"] as? String) ?? (first["thumb"] as? String)
                if let artPath, !artPath.isEmpty {
                    let cleaned = artPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    previewURL = URL(string: "\(baseURL)/\(cleaned)")
                }
            }
            return (previewURL, totalCount)
        } else {
            guard let userId = try await tvResolvedMediaLibraryUserId(server: authenticatedServer), !userId.isEmpty else {
                return (nil, nil)
            }
            let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items") else {
                return (nil, nil)
            }
            var includeItemTypes: String? = nil
            if let type = node.libraryCollectionType?.lowercased() {
                switch type {
                case "movies", "movie": includeItemTypes = "Movie"
                case "tvshows", "series", "show": includeItemTypes = "Series"
                case "music", "audio": includeItemTypes = "MusicAlbum,Audio"
                case "boxsets", "collections": includeItemTypes = "BoxSet"
                case "playlists": includeItemTypes = "Playlist"
                default: break
                }
            }
            var queryItems = [
                URLQueryItem(name: "ParentId", value: node.id),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "Limit", value: "1"),
                URLQueryItem(name: "SortBy", value: "DateCreated"),
                URLQueryItem(name: "SortOrder", value: "Descending"),
                URLQueryItem(name: "EnableImageTypes", value: "Backdrop,Primary,Thumb"),
                URLQueryItem(name: "Fields", value: "PrimaryImageAspectRatio")
            ]
            if let types = includeItemTypes, !types.isEmpty {
                queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: types))
            }
            components.queryItems = queryItems
            guard let url = components.url else { return (nil, nil) }
            let root = try await tvFetchMediaLibraryJSONObject(from: url, server: authenticatedServer)
            let totalCount = (root["TotalRecordCount"] as? Int) ?? (root["TotalRecordCount"] as? Int64).map(Int.init)
            var previewURL: URL? = nil
            if let items = root["Items"] as? [[String: Any]], let first = items.first {
                let itemId = (first["Id"] as? String) ?? (first["Id"] as? Int).map(String.init) ?? ""
                let isEmby = server.type == .emby
                if let backdropTags = first["BackdropImageTags"] as? [String], let tag = backdropTags.first, !tag.isEmpty {
                    let path = isEmby
                        ? "/Items/\(itemId)/Images/Backdrop/0?tag=\(tag)&maxWidth=800"
                        : "/Items/\(itemId)/Images/Backdrop/0?tag=\(tag)&fillWidth=800&quality=90"
                    previewURL = URL(string: "\(baseURL)\(path)")
                } else if let imageTags = first["ImageTags"] as? [String: Any], let primaryTag = imageTags["Primary"] as? String, !primaryTag.isEmpty {
                    let path = isEmby
                        ? "/Items/\(itemId)/Images/Primary?tag=\(primaryTag)&maxWidth=800"
                        : "/Items/\(itemId)/Images/Primary?tag=\(primaryTag)&fillWidth=800&quality=90"
                    previewURL = URL(string: "\(baseURL)\(path)")
                }
            }
            return (previewURL, totalCount)
        }
    } catch {
        return (nil, nil)
    }
}



func tvMediaLibraryCollectionIcon(for collectionType: String?, nodeName: String) -> String {
    let lowerType = collectionType?.lowercased() ?? ""
    let lowerName = nodeName.lowercased()

    if lowerType == "movies" || lowerType == "movie" || lowerName.contains("movie") || lowerName.contains("电影") || lowerName.contains("電影") {
        return "film.fill"
    } else if lowerType == "tvshows" || lowerType == "series" || lowerType == "show" || lowerName.contains("tv") || lowerName.contains("剧") || lowerName.contains("劇") {
        return "tv.fill"
    } else if lowerType == "anime" || lowerName.contains("anime") || lowerName.contains("动漫") || lowerName.contains("動畫") {
        return "sparkles.tv.fill"
    } else if lowerType == "boxsets" || lowerType == "collections" || lowerType == "boxset" || lowerName.contains("collection") || lowerName.contains("合集") {
        return "square.stack.3d.up.fill"
    } else if lowerType == "playlists" || lowerType == "playlist" || lowerName.contains("playlist") || lowerName.contains("播放列表") {
        return "music.note.list"
    } else if lowerType == "music" || lowerType == "audio" || lowerName.contains("music") || lowerName.contains("音乐") || lowerName.contains("音樂") {
        return "music.note"
    } else if lowerType == "photos" || lowerType == "photo" || lowerName.contains("photo") || lowerName.contains("相册") || lowerName.contains("照片") {
        return "photo.fill"
    }
    return "folder.fill"
}



func tvFetchMediaLibraryFallbackSpotlightItems(
    server: ServerConfig,
    rootNodes: [TVMediaLibraryNode],
    limit: Int
) async -> [TVMediaLibraryFeaturedItem] {
    guard limit > 0 else { return [] }

    var items: [TVMediaLibraryFeaturedItem] = []
    var seenIds = Set<String>()

    for rootNode in rootNodes where items.count < limit {
        do {
            let previewNodes = try await tvFetchMediaLibraryNodes(
                server: server,
                parentNode: rootNode,
                limit: tvMediaLibraryShelfPreviewFetchLimit
            )
            let sourceTitle = tvDisplayTitle(from: rootNode.name, type: .folder)

            for node in previewNodes {
                guard node.backdropURL != nil || node.posterURL != nil else { continue }
                guard seenIds.insert(node.id).inserted else { continue }
                items.append(
                    TVMediaLibraryFeaturedItem(
                        node: node,
                        progress: node.playbackProgress,
                        sourceTitle: sourceTitle,
                        sourceSystemImageName: tvMediaLibrarySpotlightSourceIconName(for: rootNode)
                    )
                )
                if items.count >= limit {
                    return items
                }
            }
        } catch {
            continue
        }
    }

    return items
}



func tvMediaLibrarySpotlightSourceIconName(for node: TVMediaLibraryNode) -> String {
    switch node.libraryCollectionType?.lowercased() {
    case "movies":
        return "film.fill"
    case "tvshows":
        return "tv.fill"
    case "music":
        return "music.note"
    case "boxsets":
        return "square.stack.3d.up.fill"
    case "playlists":
        return "list.bullet.rectangle.fill"
    case "photos", "homevideos":
        return "photo.fill"
    default:
        return node.type.tvSystemImageName
    }
}



func tvFetchJellyfinHomeCarousel(server: ServerConfig) async throws -> [TVMediaLibraryFeaturedItem] {
    let server = try await tvPreparedMediaLibraryServer(server: server)
    guard let userId = try await tvResolvedMediaLibraryUserId(server: server) else { return [] }
    let entries = try await JellyfinHomeCarousel.load(server: server, userId: userId, token: server.accessToken ?? "")
    return entries.map { entry in
        let featured = tvJellyfinContinueWatchingFeaturedItem(from: entry.item, server: server)
        return TVMediaLibraryFeaturedItem(node: featured.node, progress: featured.progress, lastPlayedAt: featured.lastPlayedAt,
            sourceTitle: platformShellString(entry.source.titleKey), sourceSystemImageName: entry.source.systemImage)
    }
}

func tvFetchJellyfinContinueWatchingItems(
    server: ServerConfig,
    limit: Int
) async throws -> [TVMediaLibraryFeaturedItem] {
    let authenticatedServer = try await tvPreparedMediaLibraryServer(server: server)
    guard let userId = try await tvResolvedMediaLibraryUserId(server: authenticatedServer), !userId.isEmpty else {
        throw NSError(
            domain: "GenPlayerShell",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
        )
    }

    let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let fields = "Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,Genres,ProviderIds,PrimaryImageTag,ImageTags,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ParentThumbItemId,ParentThumbImageTag,ProductionYear,PremiereDate,OfficialRating,RunTimeTicks,IndexNumber,ParentIndexNumber"
    guard
        let resumeURL = URL(string: "\(baseURL)/Users/\(userId)/Items/Resume?UserId=\(userId)&Limit=\(limit)&Fields=\(fields)&MediaTypes=Video"),
        let fallbackURL = URL(string: "\(baseURL)/Users/\(userId)/Items?Recursive=true&Filters=IsResumable&SortBy=DatePlayed&SortOrder=Descending&Limit=\(limit)&Fields=\(fields)&MediaTypes=Video")
    else {
        throw URLError(.badURL)
    }

    var lastError: Error?
    for url in [resumeURL, fallbackURL] {
        do {
            let response: JellyfinItemsResponse = try await tvFetchMediaLibraryDecodable(from: url, server: authenticatedServer)
            if !response.items.isEmpty {
                return response.items.map {
                    tvJellyfinContinueWatchingFeaturedItem(from: $0, server: authenticatedServer)
                }
            }
        } catch {
            lastError = error
        }
    }

    if let lastError {
        throw lastError
    }
    return []
}



func tvFetchEmbyContinueWatchingItems(
    server: ServerConfig,
    limit: Int
) async throws -> [TVMediaLibraryFeaturedItem] {
    let authenticatedServer = try await tvPreparedMediaLibraryServer(server: server)
    guard let userId = try await tvResolvedMediaLibraryUserId(server: authenticatedServer), !userId.isEmpty else {
        throw NSError(
            domain: "GenPlayerShell",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
        )
    }

    let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let fields = "Overview,MediaSources,UserData,SeriesId,SeriesName,SeasonId,SeasonName,Genres,ProviderIds,PrimaryImageTag,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ProductionYear,PremiereDate,OfficialRating,RunTimeTicks,IndexNumber,ParentIndexNumber"
    guard let url = URL(string: "\(baseURL)/Users/\(userId)/Items/Resume?Limit=\(limit)&Fields=\(fields)&MediaTypes=Video") else {
        throw URLError(.badURL)
    }

    let response: EmbyItemsResponse = try await tvFetchMediaLibraryDecodable(from: url, server: authenticatedServer)
    return response.items.map {
        tvEmbyContinueWatchingFeaturedItem(from: $0, server: authenticatedServer)
    }
}



func tvFetchPlexContinueWatchingItems(
    server: ServerConfig,
    limit: Int
) async throws -> [TVMediaLibraryFeaturedItem] {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: baseURL + "/hubs/home/continueWatching") else {
        throw URLError(.badURL)
    }
    components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
    guard let url = components.url else {
        throw URLError(.badURL)
    }

    let root = try await tvFetchMediaLibraryJSONObject(from: url, server: server)
    let items = tvPlexContinueWatchingItems(from: root, limit: limit)
    return items.map { tvPlexContinueWatchingFeaturedItem(from: $0, server: server) }
}



func tvFetchMediaLibraryJSONObject(
    from url: URL,
    server: ServerConfig
) async throws -> [String: Any] {
    let request = tvMediaLibraryRequest(url: url, server: server)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        throw NSError(
            domain: "GenPlayerShell",
            code: (response as? HTTPURLResponse)?.statusCode ?? -1,
            userInfo: [NSLocalizedDescriptionKey: tvMediaLibraryErrorMessage(for: (response as? HTTPURLResponse)?.statusCode)]
        )
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(
            domain: "GenPlayerShell",
            code: NSURLErrorCannotDecodeContentData,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection Failed")]
        )
    }
    return json
}



func tvFetchMediaLibraryDecodable<Response: Decodable>(
    from url: URL,
    server: ServerConfig
) async throws -> Response {
    let request = tvMediaLibraryRequest(url: url, server: server)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        throw NSError(
            domain: "GenPlayerShell",
            code: (response as? HTTPURLResponse)?.statusCode ?? -1,
            userInfo: [NSLocalizedDescriptionKey: tvMediaLibraryErrorMessage(for: (response as? HTTPURLResponse)?.statusCode)]
        )
    }

    return try JSONDecoder().decode(Response.self, from: data)
}



func tvSetMediaLibraryFavorite(
    server: ServerConfig,
    itemId: String,
    isFavorite: Bool
) async throws {
    try await tvSetJellyfinLikeUserItemFlag(
        server: server,
        itemId: itemId,
        flagPath: "FavoriteItems",
        enabled: isFavorite
    )
}



func tvSetMediaLibraryPlayed(
    server: ServerConfig,
    itemId: String,
    isPlayed: Bool
) async throws {
    switch server.type {
    case .jellyfin, .emby:
        try await tvSetJellyfinLikeUserItemFlag(
            server: server,
            itemId: itemId,
            flagPath: "PlayedItems",
            enabled: isPlayed
        )
    case .plex:
        let authenticatedServer = try await tvPreparedMediaLibraryServer(server: server)
        guard let token = tvTrimmedText(authenticatedServer.accessToken) ?? tvTrimmedText(authenticatedServer.passwordSecret) else {
            throw NSError(
                domain: "GenPlayerShell",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
            )
        }
        let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = isPlayed ? "/:/scrobble" : "/:/unscrobble"
        guard var components = URLComponents(string: "\(baseURL)\(path)") else { throw URLError(.badURL) }
        components.queryItems = [
            URLQueryItem(name: "key", value: itemId),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = tvMediaLibraryRequest(url: url, server: authenticatedServer)
        request.httpMethod = "GET"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(
                domain: "GenPlayerShell",
                code: statusCode,
                userInfo: [NSLocalizedDescriptionKey: tvMediaLibraryErrorMessage(for: statusCode)]
            )
        }
    default:
        break
    }
}



func tvReportMediaPlaybackProgress(
    server: ServerConfig,
    itemId: String,
    positionTicks: Int64,
    durationTicks: Int64?,
    isPaused: Bool,
    eventName: String? = nil,
    playSessionId: String? = nil,
    mediaSourceId: String? = nil,
    playMethod: String = "DirectPlay"
) async throws {
    switch server.type {
    case .jellyfin, .emby:
        let executeReport = { (targetServer: ServerConfig) async throws in
            guard let token = tvTrimmedText(targetServer.accessToken) else {
                throw NSError(domain: "GenPlayerShell", code: 401, userInfo: [NSLocalizedDescriptionKey: "Missing access token"])
            }
            
            let baseURL = targetServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var endpoint = "Sessions/Playing/Progress"
            if eventName == "start" {
                endpoint = "Sessions/Playing"
            } else if eventName == "stop" {
                endpoint = "Sessions/Playing/Stopped"
            }
            
            guard var components = URLComponents(string: "\(baseURL)/\(endpoint)") else {
                throw URLError(.badURL)
            }
            components.queryItems = [URLQueryItem(name: "api_key", value: token)]
            guard let url = components.url else {
                throw URLError(.badURL)
            }
            
            var request = tvMediaLibraryRequest(url: url, server: targetServer)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            
            var body: [String: Any] = [
                "ItemId": itemId,
                "PositionTicks": positionTicks,
                "CanSeek": true,
                "PlayMethod": playMethod
            ]
            
            if let userId = tvTrimmedText(targetServer.userId) {
                body["UserId"] = userId
            }
            body["DeviceId"] = "GenPlayerTV"
            body["Client"] = "GenPlayer-tvOS"
            
            if eventName != "stop" {
                body["IsPaused"] = isPaused
            }
            
            if let eventName, !eventName.isEmpty, eventName != "start", eventName != "stop" {
                body["EventName"] = eventName
            }
            if let playSessionId, !playSessionId.isEmpty {
                body["PlaySessionId"] = playSessionId
            }
            if let mediaSourceId, !mediaSourceId.isEmpty {
                body["MediaSourceId"] = mediaSourceId
            }
            
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NSError(domain: "GenPlayerShell", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    throw NSError(domain: "GenPlayerShell", code: 401, userInfo: [NSLocalizedDescriptionKey: "Unauthorized"])
                }
                throw NSError(domain: "GenPlayerShell", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Server error \(httpResponse.statusCode)"])
            }
        }
        
        do {
            let preparedServer = try await tvPreparedMediaLibraryServer(server: server)
            try await executeReport(preparedServer)
            print("[ServerSync] ✅ reportProgress succeeded (type=\(server.type), event=\(eventName ?? "periodic"), itemId=\(itemId), ticks=\(positionTicks), paused=\(isPaused), playSessionId=\(playSessionId ?? "nil"))")
        } catch {
            let nsError = error as NSError
            if nsError.code == 401,
               let username = tvTrimmedText(server.username),
               let password = tvTrimmedText(server.passwordSecret) {
                print("[ServerSync] 🔄 Token expired (401), attempting silent re-login for \(server.name)...")
                do {
                    let reloadedServer = try await tvAuthenticateMediaLibraryServer(server: server, username: username, password: password)
                    await MainActor.run {
                        if AppNetworkService.shared.servers.contains(where: { $0.id == reloadedServer.id }) {
                            AppNetworkService.shared.updateServer(reloadedServer)
                        }
                    }
                    try await executeReport(reloadedServer)
                    print("[ServerSync] ✅ reportProgress succeeded after re-login (type=\(server.type), event=\(eventName ?? "periodic"), itemId=\(itemId))")
                } catch {
                    print("[ServerSync] ❌ Failed to report progress after re-login (reason=\(eventName ?? "periodic")): \(error)")
                    throw error
                }
            } else {
                print("[ServerSync] ❌ Failed to report progress (reason=\(eventName ?? "periodic")): \(error)")
                throw error
            }
        }
        
    case .plex:
        guard let token = tvTrimmedText(server.accessToken) ?? tvTrimmedText(server.passwordSecret) else {
            print("[ServerSync] ⚠️ Missing Plex token for server \(server.name)")
            return
        }
        let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: "\(baseURL)/:/timeline") else {
            throw URLError(.badURL)
        }
        
        var state = "playing"
        if eventName == "stop" {
            state = "stopped"
        } else if isPaused {
            state = "paused"
        }
        
        let positionMillis = positionTicks / 10000
        var queryItems = [
            URLQueryItem(name: "ratingKey", value: itemId),
            URLQueryItem(name: "key", value: "/library/metadata/\(itemId)"),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
            URLQueryItem(name: "time", value: "\(max(0, positionMillis))"),
            URLQueryItem(name: "playbackTime", value: "\(max(0, positionMillis))"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "X-Plex-Token", value: token)
        ]
        
        if let durationTicks, durationTicks > 0 {
            queryItems.append(URLQueryItem(name: "duration", value: "\(durationTicks / 10000)"))
        }
        
        components.queryItems = queryItems
        guard let url = components.url else { throw URLError(.badURL) }
        
        var request = tvMediaLibraryRequest(url: url, server: server)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let sessionIdentifier = playSessionId, !sessionIdentifier.isEmpty {
            request.setValue(sessionIdentifier, forHTTPHeaderField: "X-Plex-Session-Identifier")
        }
        
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                print("[ServerSync] ❌ Plex reportTimeline failed with status \(httpResponse.statusCode)")
                throw NSError(domain: "GenPlayerShell", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Plex report failed"])
            }
            print("[ServerSync] ✅ Plex reportTimeline succeeded (event=\(eventName ?? state), itemId=\(itemId), pos=\(positionMillis)ms)")
        } catch {
            print("[ServerSync] ❌ Plex reportTimeline error: \(error)")
            throw error
        }
        
    default:
        break
    }
}



func tvSetJellyfinLikeUserItemFlag(
    server: ServerConfig,
    itemId: String,
    flagPath: String,
    enabled: Bool
) async throws {
    let authenticatedServer = try await tvPreparedMediaLibraryServer(server: server)
    guard let userId = try await tvResolvedMediaLibraryUserId(server: authenticatedServer), !userId.isEmpty else {
        throw NSError(
            domain: "GenPlayerShell",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
        )
    }

    let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(baseURL)/Users/\(userId)/\(flagPath)/\(itemId)") else {
        throw URLError(.badURL)
    }

    var request = tvMediaLibraryRequest(url: url, server: authenticatedServer)
    request.httpMethod = enabled ? "POST" : "DELETE"
    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        throw NSError(
            domain: "GenPlayerShell",
            code: (response as? HTTPURLResponse)?.statusCode ?? -1,
            userInfo: [NSLocalizedDescriptionKey: tvMediaLibraryErrorMessage(for: (response as? HTTPURLResponse)?.statusCode)]
        )
    }
}



func tvPlexContinueWatchingItems(
    from root: [String: Any],
    limit: Int
) -> [PlexItem] {
    guard
        let container = root["MediaContainer"] as? [String: Any]
    else {
        return []
    }

    if let direct = container["Metadata"] as? [[String: Any]], !direct.isEmpty {
        return Array(direct.prefix(limit)).map(PlexItem.init(dictionary:))
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
}



func tvJellyfinContinueWatchingFeaturedItem(
    from item: JellyfinItem,
    server: ServerConfig
) -> TVMediaLibraryFeaturedItem {
    let mediaProbe = tvMediaSourceProbe(from: item.mediaSources)
    let node = TVMediaLibraryNode(
        id: item.id,
        name: item.displayTitle,
        type: tvFileType(from: item.type),
        isFolder: item.isContainer,
        remotePath: nil,
        posterURL: tvJellyfinContinueWatchingPosterURL(for: item, server: server),
        summary: item.overview,
        metadataLine: tvContinueWatchingMetadataLine(
            leading: item.subtitle,
            runtimeText: tvDurationText(ticks: item.runTimeTicks),
            rating: item.officialRating
        ),
        isLibraryRoot: false,
        libraryCollectionType: nil,
        backdropURL: tvJellyfinContinueWatchingBackdropURL(for: item, server: server),
        logoURL: tvJellyfinLogoURL(for: item, server: server),
        year: item.productionYear,
        premiereDate: item.premiereDate,
        runtimeTicks: item.runTimeTicks,
        rating: item.officialRating,
        communityRating: item.communityRating,
        childCount: item.childCount ?? item.recursiveItemCount,
        rawItemType: item.type,
        seriesId: item.seriesId,
        seasonId: item.seasonId,
        seriesName: item.seriesName,
        indexNumber: item.indexNumber,
        parentIndexNumber: item.parentIndexNumber,
        isFavorite: item.userData?.isFavorite,
        isPlayed: item.userData?.played,
        playbackPositionSeconds: item.userData?.playbackPositionTicks.map { TimeInterval($0) / 10_000_000.0 },
        playbackProgress: item.userData?.playedPercentage.map { min(max($0 / 100.0, 0), 1) },
        videoWidth: mediaProbe.width,
        videoHeight: mediaProbe.height,
        mediaSize: mediaProbe.size,
        mediaContainer: mediaProbe.container
    )
    let progress = item.userData?
        .resumeDecision(runtimeTicks: item.runTimeTicks)
        .progressSnapshot?
        .displayedProgress
    return TVMediaLibraryFeaturedItem(node: node, progress: progress,
        lastPlayedAt: MediaHomeCarouselSelection.date(item.userData?.lastPlayedDate))
}



func tvEmbyContinueWatchingFeaturedItem(
    from item: EmbyItem,
    server: ServerConfig
) -> TVMediaLibraryFeaturedItem {
    let mediaProbe = tvMediaSourceProbe(from: item.mediaSources)
    let node = TVMediaLibraryNode(
        id: item.id,
        name: item.displayTitle,
        type: tvFileType(from: item.type),
        isFolder: item.isContainer,
        remotePath: nil,
        posterURL: tvEmbyContinueWatchingPosterURL(for: item, server: server),
        summary: item.overview,
        metadataLine: tvContinueWatchingMetadataLine(
            leading: item.subtitle,
            runtimeText: tvDurationText(ticks: item.runTimeTicks),
            rating: item.officialRating
        ),
        isLibraryRoot: false,
        libraryCollectionType: nil,
        backdropURL: tvEmbyContinueWatchingBackdropURL(for: item, server: server),
        logoURL: tvEmbyLogoURL(for: item, server: server),
        year: item.productionYear,
        premiereDate: item.premiereDate,
        runtimeTicks: item.runTimeTicks,
        rating: item.officialRating,
        communityRating: item.communityRating,
        childCount: item.childCount ?? item.recursiveItemCount,
        rawItemType: item.type,
        seriesId: item.seriesId,
        seasonId: item.seasonId,
        seriesName: item.seriesName,
        indexNumber: item.indexNumber,
        parentIndexNumber: item.parentIndexNumber,
        isFavorite: item.userData?.isFavorite,
        isPlayed: item.userData?.played,
        playbackPositionSeconds: item.userData?.playbackPositionTicks.map { TimeInterval($0) / 10_000_000.0 },
        playbackProgress: item.userData?.playedPercentage.map { min(max($0 / 100.0, 0), 1) },
        videoWidth: mediaProbe.width,
        videoHeight: mediaProbe.height,
        mediaSize: mediaProbe.size,
        mediaContainer: mediaProbe.container
    )
    let progress = item.userData?
        .resumeDecision(runtimeTicks: item.runTimeTicks)
        .progressSnapshot?
        .displayedProgress
    return TVMediaLibraryFeaturedItem(node: node, progress: progress,
        lastPlayedAt: MediaHomeCarouselSelection.date(item.userData?.lastPlayedDate))
}



func tvPlexContinueWatchingFeaturedItem(
    from item: PlexItem,
    server: ServerConfig
) -> TVMediaLibraryFeaturedItem {
    let leading = item.grandparentTitle ?? item.parentTitle ?? item.secondaryTitle
    let node = TVMediaLibraryNode(
        id: item.id,
        name: item.displayTitle,
        type: tvFileType(from: item.type),
        isFolder: item.isContainer,
        remotePath: nil,
        posterURL: tvPlexContinueWatchingPosterURL(for: item, server: server),
        summary: item.summary,
        metadataLine: tvContinueWatchingMetadataLine(
            leading: leading,
            runtimeText: tvDurationText(milliseconds: item.durationMillis),
            rating: item.contentRating
        ),
        isLibraryRoot: false,
        libraryCollectionType: nil,
        backdropURL: tvPlexImageURL(
            baseURL: server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            imagePath: item.backdropPath
        ),
        year: item.year,
        premiereDate: tvPlexDateString(from: item.originallyAvailableAt),
        rating: item.contentRating,
        communityRating: item.rating ?? item.audienceRating,
        childCount: item.leafCount ?? item.childCount,
        rawItemType: item.type,
        seriesId: item.grandparentRatingKey ?? item.parentRatingKey,
        seasonId: item.parentRatingKey,
        seriesName: item.grandparentTitle,
        indexNumber: item.index,
        parentIndexNumber: item.parentIndex,
        isPlayed: item.isPlayed,
        playbackPositionSeconds: item.playbackPositionSeconds,
        playbackProgress: item.playbackProgress,
        videoWidth: item.maxVideoWidth,
        videoHeight: item.maxVideoHeight,
        mediaSize: item.mediaSize,
        mediaContainer: item.mediaContainer,
        downloadRemotePath: tvPlexDownloadPath(for: item)
    )
    let progress = item.resumeDecision.progressSnapshot?.displayedProgress
    return TVMediaLibraryFeaturedItem(node: node, progress: progress, lastPlayedAt: item.lastViewedAt)
}



func tvContinueWatchingMetadataLine(
    leading: String?,
    runtimeText: String?,
    rating: String?
) -> String? {
    var tokens: [String] = []
    if let leading = tvTrimmedText(leading) {
        tokens.append(leading)
    }
    if let runtimeText = tvTrimmedText(runtimeText) {
        tokens.append(runtimeText)
    }
    if let rating = tvTrimmedText(rating) {
        tokens.append(rating)
    }
    return tokens.isEmpty ? nil : tokens.joined(separator: " • ")
}



func tvJellyfinContinueWatchingPosterURL(
    for item: JellyfinItem,
    server: ServerConfig
) -> URL? {
    if item.type == "Episode", let seriesId = tvTrimmedText(item.seriesId) {
        return tvJellyfinImageURL(server: server, itemId: seriesId, imageType: "Primary", maxWidth: 800)
    }
    if let itemId = tvTrimmedText(item.id) {
        if item.primaryImageTag != nil || item.imageTags?["Primary"] != nil {
            return tvJellyfinImageURL(server: server, itemId: itemId, imageType: "Primary", maxWidth: 800)
        }
        if item.imageTags?["Thumb"] != nil {
            return tvJellyfinImageURL(server: server, itemId: itemId, imageType: "Thumb", maxWidth: 800)
        }
    }
    if let parentThumbItemId = tvTrimmedText(item.parentThumbItemId), item.parentThumbImageTag != nil {
        return tvJellyfinImageURL(server: server, itemId: parentThumbItemId, imageType: "Thumb", maxWidth: 800)
    }
    if let parentBackdropItemId = tvTrimmedText(item.parentBackdropItemId), item.parentBackdropImageTags?.isEmpty == false {
        return tvJellyfinImageURL(server: server, itemId: parentBackdropItemId, imageType: "Backdrop", maxWidth: 1280)
    }
    return nil
}



func tvJellyfinContinueWatchingBackdropURL(
    for item: JellyfinItem,
    server: ServerConfig
) -> URL? {
    if let itemId = tvTrimmedText(item.id), item.backdropImageTags?.isEmpty == false {
        return tvJellyfinImageURL(server: server, itemId: itemId, imageType: "Backdrop", maxWidth: 1920)
    }
    if let parentBackdropItemId = tvTrimmedText(item.parentBackdropItemId), item.parentBackdropImageTags?.isEmpty == false {
        return tvJellyfinImageURL(server: server, itemId: parentBackdropItemId, imageType: "Backdrop", maxWidth: 1920)
    }
    if item.type == "Episode", let seriesId = tvTrimmedText(item.seriesId) {
        return tvJellyfinImageURL(server: server, itemId: seriesId, imageType: "Backdrop", maxWidth: 1920)
    }
    return tvJellyfinContinueWatchingPosterURL(for: item, server: server)
}



func tvEmbyContinueWatchingPosterURL(
    for item: EmbyItem,
    server: ServerConfig
) -> URL? {
    if item.type == "Episode", let seriesId = tvTrimmedText(item.seriesId) {
        return tvEmbyImageURL(server: server, itemId: seriesId, imageType: "Primary", maxWidth: 800)
    }
    if let itemId = tvTrimmedText(item.id), item.primaryImageTag != nil {
        return tvEmbyImageURL(server: server, itemId: itemId, imageType: "Primary", maxWidth: 800)
    }
    if let parentBackdropItemId = tvTrimmedText(item.parentBackdropItemId), item.parentBackdropImageTags?.isEmpty == false {
        return tvEmbyImageURL(server: server, itemId: parentBackdropItemId, imageType: "Backdrop", maxWidth: 1280)
    }
    if let seriesId = tvTrimmedText(item.seriesId) {
        return tvEmbyImageURL(server: server, itemId: seriesId, imageType: "Primary", maxWidth: 800)
    }
    return nil
}



func tvEmbyContinueWatchingBackdropURL(
    for item: EmbyItem,
    server: ServerConfig
) -> URL? {
    if let itemId = tvTrimmedText(item.id), item.backdropImageTags?.isEmpty == false {
        return tvEmbyImageURL(server: server, itemId: itemId, imageType: "Backdrop", maxWidth: 1920)
    }
    if let parentBackdropItemId = tvTrimmedText(item.parentBackdropItemId), item.parentBackdropImageTags?.isEmpty == false {
        return tvEmbyImageURL(server: server, itemId: parentBackdropItemId, imageType: "Backdrop", maxWidth: 1920)
    }
    if item.type == "Episode", let seriesId = tvTrimmedText(item.seriesId) {
        return tvEmbyImageURL(server: server, itemId: seriesId, imageType: "Backdrop", maxWidth: 1920)
    }
    return tvEmbyContinueWatchingPosterURL(for: item, server: server)
}

func tvJellyfinLogoURL(
    for item: JellyfinItem,
    server: ServerConfig
) -> URL? {
    if let itemId = tvTrimmedText(item.id), item.imageTags?["Logo"] != nil {
        return tvJellyfinImageURL(server: server, itemId: itemId, imageType: "Logo", maxWidth: 600)
    }
    if let parentLogoId = tvTrimmedText(item.parentBackdropItemId) {
        return tvJellyfinImageURL(server: server, itemId: parentLogoId, imageType: "Logo", maxWidth: 600)
    }
    if item.type == "Episode", let seriesId = tvTrimmedText(item.seriesId) {
        return tvJellyfinImageURL(server: server, itemId: seriesId, imageType: "Logo", maxWidth: 600)
    }
    return nil
}

func tvEmbyLogoURL(
    for item: EmbyItem,
    server: ServerConfig
) -> URL? {
    if let itemId = tvTrimmedText(item.id), item.imageTags?["Logo"] != nil {
        return tvEmbyImageURL(server: server, itemId: itemId, imageType: "Logo", maxWidth: 600)
    }
    if let parentLogoId = tvTrimmedText(item.parentLogoItemId) {
        return tvEmbyImageURL(server: server, itemId: parentLogoId, imageType: "Logo", maxWidth: 600)
    }
    if let seriesId = tvTrimmedText(item.seriesId) {
        return tvEmbyImageURL(server: server, itemId: seriesId, imageType: "Logo", maxWidth: 600)
    }
    return nil
}



func tvPlexContinueWatchingPosterURL(
    for item: PlexItem,
    server: ServerConfig
) -> URL? {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    if let path = item.posterPath, !path.isEmpty {
        return URL(string: baseURL + path)
    }
    if let path = item.backdropPath, !path.isEmpty {
        return URL(string: baseURL + path)
    }
    return nil
}



func tvMediaSourceProbe(from mediaSources: [JellyfinMediaSource]?) -> TVMediaSourceProbe {
    let sources = mediaSources ?? []
    let bestSource = sources.max { lhs, rhs in
        tvMediaSourcePixelCount(width: lhs.videoStream?.width, height: lhs.videoStream?.height)
            < tvMediaSourcePixelCount(width: rhs.videoStream?.width, height: rhs.videoStream?.height)
    }
    return TVMediaSourceProbe(
        width: bestSource?.videoStream?.width,
        height: bestSource?.videoStream?.height,
        size: bestSource?.size,
        container: tvMediaContainerText(bestSource?.container)
    )
}



func tvMediaSourceProbe(from mediaSources: [EmbyMediaSource]?) -> TVMediaSourceProbe {
    let sources = mediaSources ?? []
    let bestSource = sources.max { lhs, rhs in
        tvMediaSourcePixelCount(width: lhs.videoStream?.width, height: lhs.videoStream?.height)
            < tvMediaSourcePixelCount(width: rhs.videoStream?.width, height: rhs.videoStream?.height)
    }
    return TVMediaSourceProbe(
        width: bestSource?.videoStream?.width,
        height: bestSource?.videoStream?.height,
        size: bestSource?.size,
        container: tvMediaContainerText(bestSource?.container)
    )
}



func tvMediaSourceProbe(from rawMediaSources: Any?) -> TVMediaSourceProbe {
    let sources = rawMediaSources as? [[String: Any]] ?? []
    var bestWidth: Int?
    var bestHeight: Int?
    var bestSize: Int64?
    var bestContainer: String?
    var bestPixels = 0

    for source in sources {
        let streams = source["MediaStreams"] as? [[String: Any]] ?? []
        let videoStream = streams.first { stream in
            (stream["Type"] as? String)?.caseInsensitiveCompare("Video") == .orderedSame
        }
        let width = tvIntValue(videoStream?["Width"])
        let height = tvIntValue(videoStream?["Height"])
        let pixels = tvMediaSourcePixelCount(width: width, height: height)
        if pixels >= bestPixels {
            bestPixels = pixels
            bestWidth = width
            bestHeight = height
            bestSize = tvInt64Value(source["Size"])
            bestContainer = tvMediaContainerText(source["Container"] as? String)
        }
    }

    return TVMediaSourceProbe(
        width: bestWidth,
        height: bestHeight,
        size: bestSize,
        container: bestContainer
    )
}



func tvMediaSourcePixelCount(width: Int?, height: Int?) -> Int {
    guard let width, let height, width > 0, height > 0 else { return 0 }
    return width * height
}



func tvMediaContainerText(_ rawValue: String?) -> String? {
    guard let value = rawValue?.split(separator: ",").first else { return nil }
    let cleaned = String(value).trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.isEmpty ? nil : cleaned.lowercased()
}



func tvPlexDownloadPath(for item: PlexItem) -> String? {
    guard let partKey = item.mediaPartKey, !partKey.isEmpty else {
        return nil
    }
    if partKey.contains("?") {
        return "\(partKey)&download=1"
    }
    return "\(partKey)?download=1"
}



func tvPlexDateString(from date: Date?) -> String? {
    guard let date else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}



func tvJellyfinImageURL(
    server: ServerConfig,
    itemId: String,
    imageType: String,
    maxWidth: Int
) -> URL? {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/Items/\(itemId)/Images/\(imageType)") else {
        return nil
    }

    var queryItems = [URLQueryItem(name: "maxWidth", value: String(maxWidth))]
    if let token = tvTrimmedText(server.accessToken) {
        queryItems.append(URLQueryItem(name: "api_key", value: token))
    }
    components.queryItems = queryItems
    return components.url
}



func tvEmbyImageURL(
    server: ServerConfig,
    itemId: String,
    imageType: String,
    maxWidth: Int
) -> URL? {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/Items/\(itemId)/Images/\(imageType)") else {
        return nil
    }

    var queryItems = [URLQueryItem(name: "MaxWidth", value: String(maxWidth))]
    if let token = tvTrimmedText(server.accessToken) {
        queryItems.append(URLQueryItem(name: "api_key", value: token))
    }
    components.queryItems = queryItems
    return components.url
}


func tvFetchMediaLibraryNodes(
    server: ServerConfig,
    parentNode: TVMediaLibraryNode?,
    limit: Int? = nil,
    sortPreference: TVMediaLibrarySortPreference? = nil
) async throws -> [TVMediaLibraryNode] {
    switch server.type {
    case .jellyfin, .emby:
        return try await tvFetchJellyfinLikeNodes(
            server: server,
            parentNode: parentNode,
            limit: limit,
            sortPreference: sortPreference
        )
    case .plex:
        return try await tvFetchPlexNodes(
            server: server,
            parentNode: parentNode,
            limit: limit,
            sortPreference: sortPreference
        )
    default:
        return []
    }
}



func tvFetchMediaLibraryNode(
    server: ServerConfig,
    itemId: String
) async throws -> TVMediaLibraryNode? {
    let trimmedItemId = itemId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedItemId.isEmpty else { return nil }

    switch server.type {
    case .jellyfin, .emby:
        return try await tvFetchJellyfinLikeMediaLibraryNode(server: server, itemId: trimmedItemId)
    case .plex:
        return try await tvFetchPlexMediaLibraryNode(server: server, itemId: trimmedItemId)
    default:
        return nil
    }
}



func tvFetchJellyfinLikeMediaLibraryNode(
    server: ServerConfig,
    itemId: String
) async throws -> TVMediaLibraryNode? {
    let authenticatedServer = try await tvPreparedMediaLibraryServer(server: server)
    guard let userId = try await tvResolvedMediaLibraryUserId(server: authenticatedServer), !userId.isEmpty else {
        throw NSError(
            domain: "GenPlayerShell",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
        )
    }

    let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items/\(itemId)") else {
        throw URLError(.badURL)
    }
    components.queryItems = [
        URLQueryItem(name: "Fields", value: tvJellyfinLikeRichItemFields)
    ]
    guard let url = components.url else {
        throw URLError(.badURL)
    }

    let item = try await tvFetchMediaLibraryJSONObject(from: url, server: authenticatedServer)
    return tvJellyfinLikeNode(from: item, baseURL: baseURL, parentNode: nil)
}



func tvFetchPlexMediaLibraryNode(
    server: ServerConfig,
    itemId: String
) async throws -> TVMediaLibraryNode? {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(baseURL)/library/metadata/\(itemId)") else {
        throw URLError(.badURL)
    }

    let root = try await tvFetchMediaLibraryJSONObject(from: url, server: server)
    guard let item = tvPlexMetadataItems(from: root, limit: 1).first else {
        return nil
    }
    return tvPlexMediaLibraryNode(from: item, server: server, baseURL: baseURL)
}



func tvSearchMediaLibraryNodes(
    server: ServerConfig,
    scopeNode: TVMediaLibraryNode?,
    query: String,
    limit: Int = 50
) async throws -> [TVMediaLibraryNode] {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedQuery.isEmpty else { return [] }

    switch server.type {
    case .jellyfin:
        return try await tvSearchJellyfinNodes(
            server: server,
            scopeNode: scopeNode,
            query: trimmedQuery,
            limit: limit
        )
    case .emby:
        return try await tvSearchEmbyNodes(
            server: server,
            scopeNode: scopeNode,
            query: trimmedQuery,
            limit: limit
        )
    case .plex:
        return try await tvSearchPlexNodes(
            server: server,
            scopeNode: scopeNode,
            query: trimmedQuery,
            limit: limit
        )
    default:
        return []
    }
}



func tvSearchJellyfinNodes(
    server: ServerConfig,
    scopeNode: TVMediaLibraryNode?,
    query: String,
    limit: Int
) async throws -> [TVMediaLibraryNode] {
    let authenticatedServer = try await tvPreparedMediaLibraryServer(server: server)
    guard let userId = try await tvResolvedMediaLibraryUserId(server: authenticatedServer), !userId.isEmpty else {
        throw NSError(
            domain: "GenPlayerShell",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
        )
    }

    let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items") else {
        throw URLError(.badURL)
    }

    var queryItems = [
        URLQueryItem(name: "Recursive", value: "true"),
        URLQueryItem(name: "SearchTerm", value: query),
        URLQueryItem(
            name: "Fields",
            value: "Path,Type,MediaType,CollectionType,Overview,ProductionYear,PremiereDate,MediaSources,RunTimeTicks,OfficialRating,ChildCount,RecursiveItemCount,PrimaryImageTag,ImageTags,PrimaryImageItemId,ParentThumbItemId,ParentThumbImageTag,ParentBackdropItemId,ParentBackdropImageTags,SeriesId,SeriesName,SeasonId,SeasonName,IndexNumber,ParentIndexNumber"
        ),
        URLQueryItem(name: "SortBy", value: "SortName"),
        URLQueryItem(name: "SortOrder", value: "Ascending"),
        URLQueryItem(name: "Limit", value: String(max(1, limit)))
    ]

    if let scopeNode {
        queryItems.append(URLQueryItem(name: "ParentId", value: scopeNode.id))
        if scopeNode.isLibraryRoot,
           let includeTypes = tvJellyfinLikeBrowseIncludeTypes(for: scopeNode.libraryCollectionType) {
            queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: includeTypes.joined(separator: ",")))
        }
    }

    components.queryItems = queryItems
    guard let url = components.url else {
        throw URLError(.badURL)
    }

    let response: JellyfinItemsResponse = try await tvFetchMediaLibraryDecodable(
        from: url,
        server: authenticatedServer
    )

    return response.items
        .map { item in
            let mediaProbe = tvMediaSourceProbe(from: item.mediaSources)
            return TVMediaLibraryNode(
                id: item.id,
                name: item.displayTitle,
                type: tvFileType(from: item.type),
                isFolder: item.isContainer,
                remotePath: nil,
                posterURL: tvJellyfinContinueWatchingPosterURL(for: item, server: authenticatedServer),
                summary: item.overview,
                metadataLine: tvCompactMetadataLine(
                    mediaType: item.type,
                    year: item.productionYear,
                    runtimeText: tvDurationText(ticks: item.runTimeTicks),
                    rating: item.officialRating,
                    childCount: item.childCount ?? item.recursiveItemCount
                ),
                isLibraryRoot: false,
                libraryCollectionType: nil,
                year: item.productionYear,
                premiereDate: item.premiereDate,
                runtimeTicks: item.runTimeTicks,
                rating: item.officialRating,
                communityRating: item.communityRating,
                childCount: item.childCount ?? item.recursiveItemCount,
                rawItemType: item.type,
                seriesId: item.seriesId,
                seasonId: item.seasonId,
                seriesName: item.seriesName,
                indexNumber: item.indexNumber,
                parentIndexNumber: item.parentIndexNumber,
                isFavorite: item.userData?.isFavorite,
                isPlayed: item.userData?.played,
                playbackPositionSeconds: item.userData?.playbackPositionTicks.map { TimeInterval($0) / 10_000_000.0 },
                playbackProgress: item.userData?.playedPercentage.map { min(max($0 / 100.0, 0), 1) },
                videoWidth: mediaProbe.width,
                videoHeight: mediaProbe.height,
                mediaSize: mediaProbe.size,
                mediaContainer: mediaProbe.container
            )
        }
        .sorted(by: tvMediaLibraryNodeSort)
}



func tvSearchEmbyNodes(
    server: ServerConfig,
    scopeNode: TVMediaLibraryNode?,
    query: String,
    limit: Int
) async throws -> [TVMediaLibraryNode] {
    let authenticatedServer = try await tvPreparedMediaLibraryServer(server: server)
    guard let userId = try await tvResolvedMediaLibraryUserId(server: authenticatedServer), !userId.isEmpty else {
        throw NSError(
            domain: "GenPlayerShell",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
        )
    }

    let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items") else {
        throw URLError(.badURL)
    }

    var queryItems = [
        URLQueryItem(name: "Recursive", value: "true"),
        URLQueryItem(name: "SearchTerm", value: query),
        URLQueryItem(
            name: "Fields",
            value: "Path,Type,MediaType,CollectionType,Overview,ProductionYear,PremiereDate,MediaSources,RunTimeTicks,OfficialRating,ChildCount,RecursiveItemCount,PrimaryImageTag,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,SeriesId,SeriesName,SeasonId,SeasonName,IndexNumber,ParentIndexNumber"
        ),
        URLQueryItem(name: "SortBy", value: "SortName"),
        URLQueryItem(name: "SortOrder", value: "Ascending"),
        URLQueryItem(name: "Limit", value: String(max(1, limit)))
    ]

    if let scopeNode {
        queryItems.append(URLQueryItem(name: "ParentId", value: scopeNode.id))
        if scopeNode.isLibraryRoot,
           let includeTypes = tvJellyfinLikeBrowseIncludeTypes(for: scopeNode.libraryCollectionType) {
            queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: includeTypes.joined(separator: ",")))
        }
    }

    components.queryItems = queryItems
    guard let url = components.url else {
        throw URLError(.badURL)
    }

    let response: EmbyItemsResponse = try await tvFetchMediaLibraryDecodable(
        from: url,
        server: authenticatedServer
    )

    return response.items
        .map { item in
            let mediaProbe = tvMediaSourceProbe(from: item.mediaSources)
            return TVMediaLibraryNode(
                id: item.id,
                name: item.displayTitle,
                type: tvFileType(from: item.type),
                isFolder: item.isContainer,
                remotePath: nil,
                posterURL: tvEmbyContinueWatchingPosterURL(for: item, server: authenticatedServer),
                summary: item.overview,
                metadataLine: tvCompactMetadataLine(
                    mediaType: item.type,
                    year: item.productionYear,
                    runtimeText: tvDurationText(ticks: item.runTimeTicks),
                    rating: item.officialRating,
                    childCount: item.childCount ?? item.recursiveItemCount
                ),
                isLibraryRoot: false,
                libraryCollectionType: nil,
                year: item.productionYear,
                premiereDate: item.premiereDate,
                runtimeTicks: item.runTimeTicks,
                rating: item.officialRating,
                communityRating: item.communityRating,
                childCount: item.childCount ?? item.recursiveItemCount,
                rawItemType: item.type,
                seriesId: item.seriesId,
                seasonId: item.seasonId,
                seriesName: item.seriesName,
                indexNumber: item.indexNumber,
                parentIndexNumber: item.parentIndexNumber,
                isFavorite: item.userData?.isFavorite,
                isPlayed: item.userData?.played,
                playbackPositionSeconds: item.userData?.playbackPositionTicks.map { TimeInterval($0) / 10_000_000.0 },
                playbackProgress: item.userData?.playedPercentage.map { min(max($0 / 100.0, 0), 1) },
                videoWidth: mediaProbe.width,
                videoHeight: mediaProbe.height,
                mediaSize: mediaProbe.size,
                mediaContainer: mediaProbe.container
            )
        }
        .sorted(by: tvMediaLibraryNodeSort)
}



func tvSearchPlexNodes(
    server: ServerConfig,
    scopeNode: TVMediaLibraryNode?,
    query: String,
    limit: Int
) async throws -> [TVMediaLibraryNode] {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let sectionId = tvPlexSearchSectionId(from: scopeNode)

    let items: [PlexItem]
    if let sectionId {
        guard var components = URLComponents(string: baseURL + "/hubs/search") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "sectionId", value: sectionId),
            URLQueryItem(name: "limit", value: String(max(limit, 12)))
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let root = try await tvFetchMediaLibraryJSONObject(from: url, server: server)
        let rawItems = tvPlexSearchItems(from: root, limit: max(limit * 3, 120))
        let filtered = rawItems.filter {
            $0.librarySectionIdString == sectionId || $0.librarySectionIdString == nil
        }
        items = filtered.isEmpty ? Array(rawItems.prefix(limit)) : Array(filtered.prefix(limit))
    } else {
        guard var components = URLComponents(string: baseURL + "/library/search") else {
            throw URLError(.badURL)
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query)
        ]
        guard let url = components.url else {
            throw URLError(.badURL)
        }

        let root = try await tvFetchMediaLibraryJSONObject(from: url, server: server)
        items = Array(tvPlexSearchItems(from: root, limit: limit).prefix(limit))
    }

    return items
        .map { tvPlexMediaLibraryNode(from: $0, server: server, baseURL: baseURL) }
        .sorted(by: tvMediaLibraryNodeSort)
}



private let tvJellyfinLikeRichItemFields = [
    "Path",
    "Type",
    "MediaType",
    "CollectionType",
    "UserData",
    "Overview",
    "ProductionYear",
    "PremiereDate",
    "MediaSources",
    "RunTimeTicks",
    "OfficialRating",
    "CommunityRating",
    "Genres",
    "People",
    "ChildCount",
    "RecursiveItemCount",
    "PrimaryImageTag",
    "ImageTags",
    "PrimaryImageItemId",
    "ParentThumbItemId",
    "ParentThumbImageTag",
    "ParentBackdropItemId",
    "ParentBackdropImageTags",
    "BackdropImageTags",
    "SeriesId",
    "SeriesName",
    "SeasonId",
    "SeasonName",
    "IndexNumber",
    "ParentIndexNumber"
].joined(separator: ",")

func tvFetchPersonItems(
    server: ServerConfig,
    personId: String,
    sortBy: String = "DateCreated",
    sortOrder: String = "Descending",
    limit: Int
) async throws -> [TVMediaLibraryNode] {
    switch server.type {
    case .jellyfin, .emby:
        return try await tvFetchJellyfinLikePersonItems(server: server, personId: personId, sortBy: sortBy, sortOrder: sortOrder, limit: limit)
    case .plex:
        return try await tvFetchPlexPersonItems(server: server, personId: personId, limit: limit)
    default:
        return []
    }
}



func tvFetchPersonDetails(
    server: ServerConfig,
    personId: String
) async throws -> TVMediaLibraryPersonDetails? {
    switch server.type {
    case .jellyfin, .emby:
        return try await tvFetchJellyfinLikePersonDetails(server: server, personId: personId)
    default:
        return nil
    }
}



func tvFetchSimilarItems(
    server: ServerConfig,
    node: TVMediaLibraryNode,
    limit: Int
) async throws -> [TVMediaLibraryNode] {
    switch server.type {
    case .jellyfin, .emby:
        return try await tvFetchJellyfinLikeSimilarItems(server: server, node: node, limit: limit)
    case .plex:
        return try await tvFetchPlexSimilarItems(server: server, itemId: node.id, limit: limit)
    default:
        return []
    }
}



func tvFetchJellyfinLikePersonDetails(
    server: ServerConfig,
    personId: String
) async throws -> TVMediaLibraryPersonDetails? {
    let authenticatedServer = try await tvPreparedMediaLibraryServer(server: server)
    guard let userId = try await tvResolvedMediaLibraryUserId(server: authenticatedServer), !userId.isEmpty else {
        throw NSError(
            domain: "GenPlayerShell",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
        )
    }

    let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items/\(personId)") else {
        throw URLError(.badURL)
    }
    components.queryItems = [
        URLQueryItem(name: "Fields", value: "Overview,PremiereDate,EndDate,ProductionLocations,ProviderIds")
    ]
    guard let url = components.url else {
        throw URLError(.badURL)
    }

    let item = try await tvFetchMediaLibraryJSONObject(from: url, server: authenticatedServer)
    let details = TVMediaLibraryPersonDetails(
        biography: tvCleanedPersonDetailText(item["Overview"] as? String),
        birthDate: tvPersonDetailDateText(item["PremiereDate"] as? String),
        deathDate: tvPersonDetailDateText(item["EndDate"] as? String),
        placeOfBirth: tvPersonLocationText(from: item["ProductionLocations"] as? [String]),
        externalIDs: tvProviderSummaryText(item["ProviderIds"] as? [String: Any])
    )
    return details.hasContent ? details : nil
}



func tvFetchJellyfinLikePersonItems(
    server: ServerConfig,
    personId: String,
    sortBy: String = "DateCreated",
    sortOrder: String = "Descending",
    limit: Int
) async throws -> [TVMediaLibraryNode] {
    let authenticatedServer = try await tvPreparedMediaLibraryServer(server: server)
    guard let userId = try await tvResolvedMediaLibraryUserId(server: authenticatedServer), !userId.isEmpty else {
        throw NSError(
            domain: "GenPlayerShell",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
        )
    }

    let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items") else {
        throw URLError(.badURL)
    }
    // For fields that need local re-sort, pass a neutral server sort and fetch more items.
    let serverSortBy = (sortBy == "PremiereDate" || sortBy == "ProductionYear") ? "SortName" : sortBy
    components.queryItems = [
        URLQueryItem(name: "Recursive", value: "true"),
        URLQueryItem(name: "PersonIds", value: personId),
        URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode"),
        URLQueryItem(name: "Fields", value: tvJellyfinLikeRichItemFields),
        URLQueryItem(name: "Limit", value: String(max(1, limit))),
        URLQueryItem(name: "SortBy", value: serverSortBy),
        URLQueryItem(name: "SortOrder", value: sortOrder)
    ]
    guard let url = components.url else {
        throw URLError(.badURL)
    }

    let root = try await tvFetchMediaLibraryJSONObject(from: url, server: authenticatedServer)
    let nodes = tvJellyfinLikeNodes(from: root, baseURL: baseURL, parentNode: nil, shouldSort: false)
        .filter { $0.rawItemType.lowercased() != "person" }
    return tvUniqueMediaLibraryNodes(nodes)
}



func tvCleanedPersonDetailText(_ value: String?) -> String? {
    guard let value else { return nil }

    let normalizedBreaks = value
        .replacingOccurrences(of: "<br />", with: "\n")
        .replacingOccurrences(of: "<br/>", with: "\n")
        .replacingOccurrences(of: "<br>", with: "\n")
    let withoutTags = normalizedBreaks.replacingOccurrences(
        of: "<[^>]+>",
        with: " ",
        options: .regularExpression
    )
    let trimmed = withoutTags
        .replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    return trimmed.isEmpty ? nil : trimmed
}



func tvPersonDetailDateText(_ rawValue: String?) -> String? {
    guard let rawValue = tvCleanedPersonDetailText(rawValue) else { return nil }

    let displayFormatter = DateFormatter()
    displayFormatter.locale = .current
    displayFormatter.dateStyle = .medium
    displayFormatter.timeStyle = .none

    let formatters: [DateFormatter] = [
        tvPersonDetailDateFormatter(for: "yyyy-MM-dd'T'HH:mm:ss.SSSSSSSXXXXX"),
        tvPersonDetailDateFormatter(for: "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX"),
        tvPersonDetailDateFormatter(for: "yyyy-MM-dd'T'HH:mm:ssXXXXX"),
        tvPersonDetailDateFormatter(for: "yyyy-MM-dd")
    ]

    for formatter in formatters {
        if let date = formatter.date(from: rawValue) {
            return displayFormatter.string(from: date)
        }
    }

    if rawValue.count >= 10 {
        let prefix = String(rawValue.prefix(10))
        if let date = tvPersonDetailDateFormatter(for: "yyyy-MM-dd").date(from: prefix) {
            return displayFormatter.string(from: date)
        }
        return prefix
    }

    return rawValue
}



func tvPersonDetailDateFormatter(for dateFormat: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = dateFormat
    return formatter
}



func tvPersonLocationText(from values: [String]?) -> String? {
    let locations = (values ?? [])
        .compactMap { tvCleanedPersonDetailText($0) }
    let uniqueLocations = Array(NSOrderedSet(array: locations)) as? [String] ?? locations
    guard !uniqueLocations.isEmpty else { return nil }
    return uniqueLocations.joined(separator: " · ")
}



func tvProviderSummaryText(_ providerIds: [String: Any]?) -> String? {
    let names = (providerIds ?? [:]).compactMap { key, value -> String? in
        guard tvCleanedPersonDetailText(value as? String) != nil else { return nil }
        return tvProviderDisplayName(for: key)
    }
    .sorted()

    guard !names.isEmpty else { return nil }
    return names.joined(separator: " · ")
}



func tvProviderDisplayName(for key: String) -> String {
    switch key.lowercased() {
    case "imdb":
        return "IMDb"
    case "tmdb":
        return "TMDb"
    case "tvdb":
        return "TVDB"
    case "musicbrainzartist":
        return "MusicBrainz"
    default:
        return key.uppercased()
    }
}



func tvFetchJellyfinLikeSimilarItems(
    server: ServerConfig,
    node: TVMediaLibraryNode,
    limit: Int
) async throws -> [TVMediaLibraryNode] {
    let authenticatedServer = try await tvPreparedMediaLibraryServer(server: server)
    guard let userId = try await tvResolvedMediaLibraryUserId(server: authenticatedServer), !userId.isEmpty else {
        throw NSError(
            domain: "GenPlayerShell",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
        )
    }

    let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/Items/\(node.id)/Similar") else {
        throw URLError(.badURL)
    }
    components.queryItems = [
        URLQueryItem(name: "UserId", value: userId),
        URLQueryItem(name: "Limit", value: String(max(1, limit))),
        URLQueryItem(name: "Fields", value: tvJellyfinLikeRichItemFields)
    ]
    guard let url = components.url else {
        throw URLError(.badURL)
    }

    let root = try await tvFetchMediaLibraryJSONObject(from: url, server: authenticatedServer)
    let nodes = tvJellyfinLikeNodes(from: root, baseURL: baseURL, parentNode: nil, shouldSort: false)
    let officialNodes = tvUniqueMediaLibraryNodes(nodes, excludingID: node.id)
    if !officialNodes.isEmpty {
        return Array(officialNodes.prefix(limit))
    }

    return try await tvFetchJellyfinLikeFallbackSimilarItems(
        server: authenticatedServer,
        userId: userId,
        baseURL: baseURL,
        node: node,
        limit: limit
    )
}



func tvFetchJellyfinLikeFallbackSimilarItems(
    server: ServerConfig,
    userId: String,
    baseURL: String,
    node: TVMediaLibraryNode,
    limit: Int
) async throws -> [TVMediaLibraryNode] {
    guard var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items") else {
        throw URLError(.badURL)
    }

    var queryItems = [
        URLQueryItem(name: "Recursive", value: "true"),
        URLQueryItem(name: "Fields", value: tvJellyfinLikeRichItemFields),
        URLQueryItem(name: "Limit", value: String(max(limit * 2, limit))),
        URLQueryItem(name: "SortBy", value: "DateCreated"),
        URLQueryItem(name: "SortOrder", value: "Descending")
    ]

    if let includeTypes = tvJellyfinLikeSimilarIncludeTypes(for: node) {
        queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: includeTypes))
    }
    if !node.genres.isEmpty {
        queryItems.append(URLQueryItem(name: "Genres", value: node.genres.prefix(3).joined(separator: ",")))
    }

    components.queryItems = queryItems
    guard let url = components.url else {
        throw URLError(.badURL)
    }

    let root = try await tvFetchMediaLibraryJSONObject(from: url, server: server)
    let nodes = tvJellyfinLikeNodes(from: root, baseURL: baseURL, parentNode: nil, shouldSort: false)
    return Array(tvUniqueMediaLibraryNodes(nodes, excludingID: node.id).prefix(limit))
}



func tvJellyfinLikeSimilarIncludeTypes(for node: TVMediaLibraryNode) -> String? {
    switch node.rawItemType.lowercased() {
    case "series":
        return "Series"
    case "season":
        return "Season"
    case "episode":
        return "Episode"
    case "movie", "video":
        return "Movie"
    case "audio":
        return "Audio"
    default:
        switch node.type {
        case .audio:
            return "Audio"
        case .video:
            return "Movie,Series,Episode"
        default:
            return nil
        }
    }
}



func tvFetchPlexPersonItems(
    server: ServerConfig,
    personId: String,
    limit: Int
) async throws -> [TVMediaLibraryNode] {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let normalizedPersonId = tvPlexPersonIdentifier(from: personId)
    guard !normalizedPersonId.isEmpty,
          var components = URLComponents(string: "\(baseURL)/library/people/\(normalizedPersonId)/media") else {
        return []
    }
    components.queryItems = [
        URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
        URLQueryItem(name: "X-Plex-Container-Size", value: String(max(1, limit)))
    ]
    guard let url = components.url else {
        throw URLError(.badURL)
    }

    let root = try await tvFetchMediaLibraryJSONObject(from: url, server: server)
    let items = tvPlexMetadataItems(from: root, limit: limit)
    let nodes = items
        .filter { $0.isPlayable || $0.isContainer }
        .map { tvPlexMediaLibraryNode(from: $0, server: server, baseURL: baseURL) }
    return tvUniqueMediaLibraryNodes(nodes)
}



func tvFetchPlexSimilarItems(
    server: ServerConfig,
    itemId: String,
    limit: Int
) async throws -> [TVMediaLibraryNode] {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/hubs/metadata/\(itemId)/related") else {
        throw URLError(.badURL)
    }
    components.queryItems = [
        URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
        URLQueryItem(name: "X-Plex-Container-Size", value: String(max(1, limit)))
    ]
    guard let url = components.url else {
        throw URLError(.badURL)
    }

    let root = try await tvFetchMediaLibraryJSONObject(from: url, server: server)
    let items = tvPlexMetadataItems(from: root, limit: limit * 2)
        .filter { $0.id != itemId }
    let nodes = items.map {
        tvPlexMediaLibraryNode(from: $0, server: server, baseURL: baseURL)
    }
    return Array(tvUniqueMediaLibraryNodes(nodes, excludingID: itemId).prefix(limit))
}



func tvJellyfinLikeNodes(
    from root: [String: Any],
    baseURL: String,
    parentNode: TVMediaLibraryNode?,
    shouldSort: Bool
) -> [TVMediaLibraryNode] {
    guard let items = root["Items"] as? [[String: Any]] else {
        return []
    }
    let nodes = items.compactMap {
        tvJellyfinLikeNode(from: $0, baseURL: baseURL, parentNode: parentNode)
    }
    return shouldSort ? nodes.sorted(by: tvMediaLibraryNodeSort) : nodes
}



func tvJellyfinLikeNode(
    from item: [String: Any],
    baseURL: String,
    parentNode: TVMediaLibraryNode?
) -> TVMediaLibraryNode? {
    guard let id = tvTrimmedText(item["Id"] as? String),
          let name = tvTrimmedText(item["Name"] as? String) else {
        return nil
    }

    let collectionType = item["CollectionType"] as? String
    let rawItemType = tvTrimmedText(item["Type"] as? String)
    let rawMediaType = tvTrimmedText(item["MediaType"] as? String)
    let displayMediaType = rawItemType ?? rawMediaType ?? collectionType ?? ""
    let folderProbeType = rawItemType ?? collectionType ?? rawMediaType ?? ""
    let isFolder = (item["IsFolder"] as? Bool) ?? tvJellyfinLikeFolderTypes.contains(folderProbeType.lowercased())
    let runtimeTicks = tvInt64Value(item["RunTimeTicks"])
    let mediaProbe = tvMediaSourceProbe(from: item["MediaSources"])
    let userState = tvJellyfinLikeUserState(from: item)
    let childCount = tvIntValue(item["ChildCount"]) ?? tvIntValue(item["RecursiveItemCount"])
    let episodeCount = tvIntValue(item["RecursiveItemCount"])
    let metadataLine = tvCompactMetadataLine(
        mediaType: displayMediaType,
        year: tvIntValue(item["ProductionYear"]),
        runtimeText: tvDurationText(ticks: runtimeTicks),
        rating: item["OfficialRating"] as? String,
        childCount: childCount,
        episodeCount: episodeCount
    )

    return TVMediaLibraryNode(
        id: id,
        name: name,
        type: tvFileType(from: displayMediaType),
        isFolder: isFolder,
        remotePath: item["Path"] as? String,
        posterURL: tvJellyfinLikeNodePosterURL(item: item, baseURL: baseURL, fallbackItemId: id),
        summary: item["Overview"] as? String,
        metadataLine: metadataLine,
        isLibraryRoot: parentNode == nil,
        libraryCollectionType: collectionType,
        backdropURL: tvJellyfinLikeNodeBackdropURL(item: item, baseURL: baseURL, fallbackItemId: id),
        logoURL: tvJellyfinLikeNodeLogoURL(item: item, baseURL: baseURL, fallbackItemId: id),
        genres: item["Genres"] as? [String] ?? [],
        year: tvIntValue(item["ProductionYear"]),
        premiereDate: item["PremiereDate"] as? String,
        runtimeTicks: runtimeTicks,
        rating: item["OfficialRating"] as? String,
        communityRating: tvDoubleValue(item["CommunityRating"]),
        childCount: childCount,
        episodeCount: episodeCount,
        people: tvParseJellyfinLikePeople(from: item["People"] as? [[String: Any]] ?? [], baseURL: baseURL),
        rawItemType: rawItemType ?? rawMediaType ?? "",
        seriesId: item["SeriesId"] as? String,
        seasonId: item["SeasonId"] as? String,
        seriesName: item["SeriesName"] as? String,
        indexNumber: tvIntValue(item["IndexNumber"]),
        parentIndexNumber: tvIntValue(item["ParentIndexNumber"]),
        isFavorite: userState.isFavorite,
        isPlayed: userState.isPlayed,
        playbackPositionSeconds: userState.playbackPositionSeconds,
        playbackProgress: userState.playbackProgress,
        videoWidth: mediaProbe.width,
        videoHeight: mediaProbe.height,
        mediaSize: mediaProbe.size,
        mediaContainer: mediaProbe.container
    )
}



func tvPlexMetadataItems(from root: [String: Any], limit: Int) -> [PlexItem] {
    guard limit > 0,
          let container = root["MediaContainer"] as? [String: Any] else {
        return []
    }

    var items: [PlexItem] = []
    var seen = Set<String>()

    func append(_ dictionaries: [[String: Any]]) {
        for dictionary in dictionaries {
            let item = PlexItem(dictionary: dictionary)
            guard seen.insert(item.id).inserted else { continue }
            items.append(item)
            if items.count >= limit {
                return
            }
        }
    }

    append(container["Metadata"] as? [[String: Any]] ?? [])
    if items.count < limit {
        for hub in container["Hub"] as? [[String: Any]] ?? [] {
            append(hub["Metadata"] as? [[String: Any]] ?? [])
            if items.count >= limit {
                break
            }
        }
    }

    return items
}



func tvPlexMediaLibraryNode(
    from item: PlexItem,
    server: ServerConfig,
    baseURL: String
) -> TVMediaLibraryNode {
    TVMediaLibraryNode(
        id: item.id,
        name: item.displayTitle,
        type: tvFileType(from: item.type),
        isFolder: item.isContainer,
        remotePath: tvPlexRemotePath(for: item),
        posterURL: tvPlexImageURL(baseURL: baseURL, imagePath: item.posterPath),
        summary: item.summary,
        metadataLine: tvCompactMetadataLine(
            mediaType: item.type,
            year: item.year,
            runtimeText: tvDurationText(milliseconds: item.durationMillis),
            rating: item.contentRating,
            childCount: item.leafCount ?? item.childCount
        ),
        isLibraryRoot: false,
        libraryCollectionType: nil,
        backdropURL: tvPlexImageURL(baseURL: baseURL, imagePath: item.backdropPath),
        genres: item.genres,
        year: item.year,
        premiereDate: tvPlexDateString(from: item.originallyAvailableAt),
        runtimeTicks: nil,
        rating: item.contentRating,
        communityRating: item.rating ?? item.audienceRating,
        childCount: item.leafCount ?? item.childCount,
        people: tvParsePlexPeople(from: item.people, baseURL: baseURL),
        rawItemType: item.type,
        seriesId: item.grandparentRatingKey ?? item.parentRatingKey,
        seasonId: item.parentRatingKey,
        seriesName: item.grandparentTitle,
        indexNumber: item.index,
        parentIndexNumber: item.parentIndex,
        isPlayed: item.isPlayed,
        playbackPositionSeconds: item.playbackPositionSeconds,
        playbackProgress: item.playbackProgress,
        videoWidth: item.maxVideoWidth,
        videoHeight: item.maxVideoHeight,
        mediaSize: item.mediaSize,
        mediaContainer: item.mediaContainer,
        downloadRemotePath: tvPlexDownloadPath(for: item)
    )
}



func tvParsePlexPeople(
    from people: [PlexPerson],
    baseURL: String
) -> [TVMediaLibraryPerson] {
    people.map { person in
        TVMediaLibraryPerson(
            id: person.id,
            name: person.name,
            role: person.role,
            type: person.type ?? "Actor",
            imageURL: tvPlexImageURL(baseURL: baseURL, imagePath: person.thumb)
        )
    }
}



func tvPlexImageURL(baseURL: String, imagePath: String?) -> URL? {
    guard let imagePath = tvTrimmedText(imagePath) else {
        return nil
    }
    if imagePath.hasPrefix("http://") || imagePath.hasPrefix("https://") {
        return URL(string: imagePath)
    }
    let separator = imagePath.hasPrefix("/") ? "" : "/"
    return URL(string: "\(baseURL)\(separator)\(imagePath)")
}



func tvPlexRemotePath(for item: PlexItem) -> String? {
    guard item.isContainer else { return nil }
    if item.id.hasPrefix("/") {
        return item.id.hasSuffix("/children") ? item.id : "\(item.id)/children"
    }
    return "/library/metadata/\(item.id)/children"
}



func tvPlexPersonIdentifier(from rawValue: String) -> String {
    let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if let range = trimmed.range(of: "/library/people/") {
        let suffix = trimmed[range.upperBound...]
        return suffix.split(separator: "/").first.map(String.init) ?? ""
    }
    return trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}



func tvUniqueMediaLibraryNodes(
    _ nodes: [TVMediaLibraryNode],
    excludingID: String? = nil
) -> [TVMediaLibraryNode] {
    var seen = Set<String>()
    return nodes.filter { node in
        if let excludingID, node.id == excludingID {
            return false
        }
        return seen.insert(node.id).inserted
    }
}



func tvIntValue(_ value: Any?) -> Int? {
    if let intValue = value as? Int {
        return intValue
    }
    if let number = value as? NSNumber {
        return number.intValue
    }
    if let string = value as? String {
        return Int(string)
    }
    return nil
}



func tvInt64Value(_ value: Any?) -> Int64? {
    if let int64Value = value as? Int64 {
        return int64Value
    }
    if let intValue = value as? Int {
        return Int64(intValue)
    }
    if let number = value as? NSNumber {
        return number.int64Value
    }
    if let string = value as? String {
        return Int64(string)
    }
    return nil
}



func tvDoubleValue(_ value: Any?) -> Double? {
    if let doubleValue = value as? Double {
        return doubleValue
    }
    if let number = value as? NSNumber {
        return number.doubleValue
    }
    if let string = value as? String {
        return Double(string)
    }
    return nil
}



func tvBoolValue(_ value: Any?) -> Bool? {
    if let boolValue = value as? Bool {
        return boolValue
    }
    if let number = value as? NSNumber {
        return number.boolValue
    }
    if let string = value as? String {
        switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return nil
        }
    }
    return nil
}



func tvJellyfinLikeUserState(from item: [String: Any]) -> TVMediaLibraryUserState {
    let userData = item["UserData"] as? [String: Any] ?? [:]
    let positionTicks = tvInt64Value(userData["PlaybackPositionTicks"])
    let runtimeTicks = tvInt64Value(item["RunTimeTicks"])
    let rawProgress = tvDoubleValue(userData["PlayedPercentage"]).map { min(max($0 / 100.0, 0), 1) }
    let calculatedProgress: Double?
    if let positionTicks, positionTicks > 0,
       let runtimeTicks, runtimeTicks > 0 {
        calculatedProgress = min(max(Double(positionTicks) / Double(runtimeTicks), 0), 1)
    } else {
        calculatedProgress = nil
    }

    return TVMediaLibraryUserState(
        isFavorite: tvBoolValue(userData["IsFavorite"]),
        isPlayed: tvBoolValue(userData["Played"]),
        playbackPositionSeconds: positionTicks.map { TimeInterval($0) / 10_000_000.0 },
        playbackProgress: rawProgress ?? calculatedProgress
    )
}



func tvFetchJellyfinLikeNodes(
    server: ServerConfig,
    parentNode: TVMediaLibraryNode?,
    limit: Int? = nil,
    sortPreference: TVMediaLibrarySortPreference? = nil
) async throws -> [TVMediaLibraryNode] {
    let authenticatedServer = try await tvPreparedMediaLibraryServer(server: server)

    guard let userId = try await tvResolvedMediaLibraryUserId(server: authenticatedServer), !userId.isEmpty else {
        throw NSError(
            domain: "GenPlayerShell",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
        )
    }

    let baseURL = authenticatedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    var components: URLComponents?
    if let parentNode {
        components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items")
        var queryItems = [
            URLQueryItem(name: "ParentId", value: parentNode.id),
            URLQueryItem(
                name: "Fields",
                value: tvJellyfinLikeRichItemFields
            )
        ]
        if parentNode.isLibraryRoot {
            queryItems.append(URLQueryItem(name: "Recursive", value: "true"))
            if let includeTypes = tvJellyfinLikeBrowseIncludeTypes(for: parentNode.libraryCollectionType) {
                queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: includeTypes.joined(separator: ",")))
            }
            if limit != nil {
                queryItems.append(URLQueryItem(name: "SortBy", value: "DateCreated"))
                queryItems.append(URLQueryItem(name: "SortOrder", value: "Descending"))
            } else if let sortPreference {
                queryItems.append(URLQueryItem(name: "SortBy", value: sortPreference.jellyfinSortBy))
                queryItems.append(URLQueryItem(name: "SortOrder", value: sortPreference.jellyfinSortOrder))
            } else {
                queryItems.append(URLQueryItem(name: "SortBy", value: "SortName"))
                queryItems.append(URLQueryItem(name: "SortOrder", value: "Ascending"))
            }
        } else {
            queryItems.append(URLQueryItem(name: "Recursive", value: "false"))
            queryItems.append(
                URLQueryItem(
                    name: "IncludeItemTypes",
                    value: "Folder,CollectionFolder,Series,Season,Movie,Episode,MusicAlbum,Audio,MusicArtist,Photo"
                )
            )
        }
        if let limit, limit > 0 {
            queryItems.append(URLQueryItem(name: "Limit", value: String(limit)))
        }
        components?.queryItems = queryItems
    } else {
        components = URLComponents(string: "\(baseURL)/Users/\(userId)/Views")
        var queryItems = [
            URLQueryItem(
                name: "Fields",
                value: "Path,Type,CollectionType,Overview,ProductionYear,ChildCount,RecursiveItemCount,ImageTags,PrimaryImageItemId"
            )
        ]
        if let limit, limit > 0 {
            queryItems.append(URLQueryItem(name: "Limit", value: String(limit)))
        }
        components?.queryItems = queryItems
    }

    guard let url = components?.url else {
        throw URLError(.badURL)
    }

    let request = tvMediaLibraryRequest(url: url, server: authenticatedServer)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        throw NSError(
            domain: "GenPlayerShell",
            code: (response as? HTTPURLResponse)?.statusCode ?? -1,
            userInfo: [NSLocalizedDescriptionKey: tvMediaLibraryErrorMessage(for: (response as? HTTPURLResponse)?.statusCode)]
        )
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = json["Items"] as? [[String: Any]] else {
        return []
    }

    let nodes: [TVMediaLibraryNode] = items.compactMap { item -> TVMediaLibraryNode? in
        guard let id = item["Id"] as? String,
              let name = item["Name"] as? String else {
            return nil
        }
        let collectionType = item["CollectionType"] as? String
        let rawItemType = tvTrimmedText(item["Type"] as? String)
        let rawMediaType = tvTrimmedText(item["MediaType"] as? String)
        let displayMediaType = rawItemType ?? rawMediaType ?? collectionType ?? ""
        let folderProbeType = rawItemType ?? collectionType ?? rawMediaType ?? ""
        let isFolder = (item["IsFolder"] as? Bool) ?? tvJellyfinLikeFolderTypes.contains(folderProbeType.lowercased())
        let posterURL = tvJellyfinLikeNodePosterURL(
            item: item,
            baseURL: baseURL,
            fallbackItemId: id
        )
        let backdropURL = tvJellyfinLikeNodeBackdropURL(
            item: item,
            baseURL: baseURL,
            fallbackItemId: id
        )
        let genres = (item["Genres"] as? [String]) ?? []
        let year = tvIntValue(item["ProductionYear"])
        let premiereDate = item["PremiereDate"] as? String
        let runtimeTicks = tvInt64Value(item["RunTimeTicks"])
        let mediaProbe = tvMediaSourceProbe(from: item["MediaSources"])
        let officialRating = item["OfficialRating"] as? String
        let communityRating = tvDoubleValue(item["CommunityRating"])
        let childCount = tvIntValue(item["ChildCount"])
        let episodeCount = tvIntValue(item["RecursiveItemCount"])
        let metadataLine = tvCompactMetadataLine(
            mediaType: displayMediaType,
            year: year,
            runtimeText: tvDurationText(ticks: runtimeTicks),
            rating: officialRating,
            childCount: childCount ?? episodeCount,
            episodeCount: episodeCount
        )
        let userState = tvJellyfinLikeUserState(from: item)
        let people: [TVMediaLibraryPerson] = tvParseJellyfinLikePeople(
            from: item["People"] as? [[String: Any]] ?? [],
            baseURL: baseURL
        )
        return TVMediaLibraryNode(
            id: id,
            name: name,
            type: tvFileType(from: displayMediaType),
            isFolder: isFolder,
            remotePath: item["Path"] as? String,
            posterURL: posterURL,
            summary: item["Overview"] as? String,
            metadataLine: metadataLine,
            isLibraryRoot: parentNode == nil,
            libraryCollectionType: collectionType,
            backdropURL: backdropURL,
            logoURL: tvJellyfinLikeNodeLogoURL(item: item, baseURL: baseURL, fallbackItemId: id),
            genres: genres,
            year: year,
            premiereDate: premiereDate,
            runtimeTicks: runtimeTicks,
            rating: officialRating,
            communityRating: communityRating,
            childCount: childCount ?? episodeCount,
            episodeCount: episodeCount,
            people: people,
            rawItemType: rawItemType ?? rawMediaType ?? "",
            seriesId: item["SeriesId"] as? String,
            seasonId: item["SeasonId"] as? String,
            seriesName: item["SeriesName"] as? String,
            indexNumber: tvIntValue(item["IndexNumber"]),
            parentIndexNumber: tvIntValue(item["ParentIndexNumber"]),
            isFavorite: userState.isFavorite,
            isPlayed: userState.isPlayed,
            playbackPositionSeconds: userState.playbackPositionSeconds,
            playbackProgress: userState.playbackProgress,
            videoWidth: mediaProbe.width,
            videoHeight: mediaProbe.height,
            mediaSize: mediaProbe.size,
            mediaContainer: mediaProbe.container
        )
    }

    if parentNode == nil {
        Task {
            await MediaServerSummaryService.shared.refreshSummary(for: server)
        }
    }

    if parentNode?.isLibraryRoot == true {
        return nodes
    }

    return nodes.sorted { lhs, rhs in
        tvMediaLibraryNodeSort(lhs, rhs)
    }
}



func tvFetchPlexNodes(
    server: ServerConfig,
    parentNode: TVMediaLibraryNode?,
    limit: Int? = nil,
    sortPreference: TVMediaLibrarySortPreference? = nil
) async throws -> [TVMediaLibraryNode] {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let path: String
    if let parentPath = parentNode?.remotePath, !parentPath.isEmpty {
        path = parentPath
    } else {
        path = "/library/sections"
    }

    guard var components = URLComponents(string: baseURL + path) else {
        throw URLError(.badURL)
    }
    var queryItems = components.queryItems ?? []
    if let sortPreference,
       parentNode?.isLibraryRoot == true,
       limit == nil {
        queryItems.append(URLQueryItem(name: "sort", value: sortPreference.plexSortParameter))
    }
    if let limit, limit > 0 {
        queryItems.append(URLQueryItem(name: "X-Plex-Container-Start", value: "0"))
        queryItems.append(URLQueryItem(name: "X-Plex-Container-Size", value: String(limit)))
    }
    if !queryItems.isEmpty {
        components.queryItems = queryItems
    }

    guard let url = components.url else {
        throw URLError(.badURL)
    }

    let request = tvMediaLibraryRequest(url: url, server: server)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        throw NSError(
            domain: "GenPlayerShell",
            code: (response as? HTTPURLResponse)?.statusCode ?? -1,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection Failed")]
        )
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let container = json["MediaContainer"] as? [String: Any] else {
        return []
    }

    let directories = (container["Directory"] as? [[String: Any]]) ?? []
    let videos = (container["Metadata"] as? [[String: Any]]) ?? []
    let items = directories + videos

    let nodes: [TVMediaLibraryNode] = items.compactMap { item -> TVMediaLibraryNode? in
        let key = (item["key"] as? String) ?? (item["ratingKey"] as? String) ?? ""
        let name = (item["title"] as? String) ?? (item["grandparentTitle"] as? String) ?? key
        guard !key.isEmpty, !name.isEmpty else { return nil }
        let plexItem = PlexItem(dictionary: item)
        let type = (item["type"] as? String) ?? ""
        let isFolder = tvPlexFolderTypes.contains(type.lowercased()) || item["Directory"] != nil
        let leafCount = item["leafCount"] as? Int
        let childCount = item["childCount"] as? Int
        let metadataLine = tvCompactMetadataLine(
            mediaType: type,
            year: item["year"] as? Int,
            runtimeText: tvDurationText(milliseconds: item["duration"] as? Int64),
            rating: tvCompactRatingString(item["rating"]),
            childCount: childCount ?? leafCount,
            episodeCount: leafCount
        )
        let posterKey = (item["thumb"] as? String) ?? (item["art"] as? String)

        let remotePath: String
        if path == "/library/sections" {
            remotePath = "/library/sections/\(key)/all"
        } else if key.hasPrefix("/") {
            if isFolder {
                remotePath = key.hasSuffix("/children") ? key : "\(key)/children"
            } else {
                remotePath = key
            }
        } else {
            remotePath = "/library/metadata/\(key)/children"
        }

        return TVMediaLibraryNode(
            id: key,
            name: name,
            type: tvFileType(from: type),
            isFolder: isFolder,
            remotePath: remotePath,
            posterURL: tvPlexImageURL(baseURL: baseURL, imagePath: posterKey),
            summary: item["summary"] as? String,
            metadataLine: metadataLine,
            isLibraryRoot: false,
            libraryCollectionType: nil,
            backdropURL: tvPlexImageURL(baseURL: baseURL, imagePath: plexItem.backdropPath),
            genres: plexItem.genres,
            year: plexItem.year,
            premiereDate: tvPlexDateString(from: plexItem.originallyAvailableAt),
            runtimeTicks: nil,
            rating: plexItem.contentRating,
            communityRating: plexItem.rating ?? plexItem.audienceRating,
            childCount: plexItem.leafCount ?? plexItem.childCount,
            episodeCount: leafCount,
            people: tvParsePlexPeople(from: plexItem.people, baseURL: baseURL),
            rawItemType: type,
            seriesId: plexItem.grandparentRatingKey ?? plexItem.parentRatingKey,
            seasonId: plexItem.parentRatingKey,
            seriesName: plexItem.grandparentTitle,
            indexNumber: plexItem.index,
            parentIndexNumber: plexItem.parentIndex,
            isPlayed: plexItem.isPlayed,
            playbackPositionSeconds: plexItem.playbackPositionSeconds,
            playbackProgress: plexItem.playbackProgress,
            videoWidth: plexItem.maxVideoWidth,
            videoHeight: plexItem.maxVideoHeight,
            mediaSize: plexItem.mediaSize,
            mediaContainer: plexItem.mediaContainer,
            downloadRemotePath: tvPlexDownloadPath(for: plexItem)
        )
    }

    if parentNode == nil {
        Task {
            await MediaServerSummaryService.shared.refreshSummary(for: server)
        }
    }

    if parentNode?.isLibraryRoot == true {
        return nodes
    }

    return nodes.sorted { lhs, rhs in
        tvMediaLibraryNodeSort(lhs, rhs)
    }
}



func tvMediaLibraryNodeSort(_ lhs: TVMediaLibraryNode, _ rhs: TVMediaLibraryNode) -> Bool {
    if lhs.isFolder != rhs.isFolder {
        return lhs.isFolder && !rhs.isFolder
    }
    if let lhsParentIndex = lhs.parentIndexNumber,
       let rhsParentIndex = rhs.parentIndexNumber,
       lhsParentIndex != rhsParentIndex {
        return lhsParentIndex < rhsParentIndex
    }
    if let lhsIndex = lhs.indexNumber,
       let rhsIndex = rhs.indexNumber,
       lhsIndex != rhsIndex {
        return lhsIndex < rhsIndex
    }
    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
}



func tvPlexSearchSectionId(from scopeNode: TVMediaLibraryNode?) -> String? {
    guard let remotePath = scopeNode?.remotePath else { return nil }
    let components = remotePath.split(separator: "/")
    guard components.count >= 3 else { return nil }
    guard components[0] == "library", components[1] == "sections" else { return nil }
    let sectionId = String(components[2])
    return sectionId.isEmpty ? nil : sectionId
}



func tvPlexSearchItems(from root: [String: Any], limit: Int) -> [PlexItem] {
    guard let container = root["MediaContainer"] as? [String: Any] else {
        return []
    }

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



func tvJellyfinLikeBrowseIncludeTypes(for collectionType: String?) -> [String]? {
    switch collectionType?.lowercased() {
    case "movies":
        return ["Movie"]
    case "tvshows":
        return ["Series"]
    case "music":
        return ["MusicAlbum"]
    case "boxsets":
        return ["BoxSet"]
    case "playlists":
        return ["Playlist"]
    case "photos", "homevideos", nil:
        return nil
    default:
        return nil
    }
}



func tvJellyfinLikeNodePosterURL(
    item: [String: Any],
    baseURL: String,
    fallbackItemId: String
) -> URL? {
    if let primaryImageItemId = tvTrimmedText(item["PrimaryImageItemId"] as? String) {
        return URL(
            string: "\(baseURL)/Items/\(primaryImageItemId)/Images/Primary?maxHeight=900&maxWidth=600&quality=90"
        )
    }

    if let primaryImageTag = tvTrimmedText(item["PrimaryImageTag"] as? String), !primaryImageTag.isEmpty {
        return URL(
            string: "\(baseURL)/Items/\(fallbackItemId)/Images/Primary?maxHeight=900&maxWidth=600&quality=90"
        )
    }

    if let imageTags = item["ImageTags"] as? [String: String], tvTrimmedText(imageTags["Primary"]) != nil {
        return URL(
            string: "\(baseURL)/Items/\(fallbackItemId)/Images/Primary?maxHeight=900&maxWidth=600&quality=90"
        )
    }

    if let parentThumbItemId = tvTrimmedText(item["ParentThumbItemId"] as? String),
       tvTrimmedText(item["ParentThumbImageTag"] as? String) != nil {
        return URL(
            string: "\(baseURL)/Items/\(parentThumbItemId)/Images/Thumb?maxHeight=900&maxWidth=600&quality=90"
        )
    }

    if let parentBackdropItemId = tvTrimmedText(item["ParentBackdropItemId"] as? String),
       let backdropTags = item["ParentBackdropImageTags"] as? [String],
       !backdropTags.isEmpty {
        return URL(
            string: "\(baseURL)/Items/\(parentBackdropItemId)/Images/Backdrop?maxWidth=1280"
        )
    }

    return nil
}



func tvJellyfinLikeNodeLogoURL(
    item: [String: Any],
    baseURL: String,
    fallbackItemId: String
) -> URL? {
    if let imageTags = item["ImageTags"] as? [String: String], imageTags["Logo"] != nil {
        return URL(
            string: "\(baseURL)/Items/\(fallbackItemId)/Images/Logo?maxWidth=600&quality=90"
        )
    }

    if let parentLogoItemId = tvTrimmedText(item["ParentLogoItemId"] as? String),
       let parentLogoImageTag = tvTrimmedText(item["ParentLogoImageTag"] as? String),
       !parentLogoImageTag.isEmpty {
        return URL(
            string: "\(baseURL)/Items/\(parentLogoItemId)/Images/Logo?maxWidth=600&quality=90"
        )
    }

    if let type = item["Type"] as? String, (type == "Episode" || type == "Season"),
       let seriesId = tvTrimmedText(item["SeriesId"] as? String), !seriesId.isEmpty {
        return URL(
            string: "\(baseURL)/Items/\(seriesId)/Images/Logo?maxWidth=600&quality=90"
        )
    }

    return nil
}

func tvJellyfinLikeNodeBackdropURL(
    item: [String: Any],
    baseURL: String,
    fallbackItemId: String
) -> URL? {
    if let backdropTags = item["BackdropImageTags"] as? [String], !backdropTags.isEmpty {
        return URL(
            string: "\(baseURL)/Items/\(fallbackItemId)/Images/Backdrop?maxWidth=1920&quality=90"
        )
    }

    if let parentBackdropItemId = tvTrimmedText(item["ParentBackdropItemId"] as? String),
       let parentBackdropTags = item["ParentBackdropImageTags"] as? [String],
       !parentBackdropTags.isEmpty {
        return URL(
            string: "\(baseURL)/Items/\(parentBackdropItemId)/Images/Backdrop?maxWidth=1920&quality=90"
        )
    }

    if let primaryImageTag = tvTrimmedText(item["PrimaryImageTag"] as? String), !primaryImageTag.isEmpty {
        return URL(
            string: "\(baseURL)/Items/\(fallbackItemId)/Images/Primary?maxWidth=1920&quality=90"
        )
    }

    return nil
}



func tvParseJellyfinLikePeople(
    from rawPeople: [[String: Any]],
    baseURL: String
) -> [TVMediaLibraryPerson] {
    rawPeople.compactMap { person -> TVMediaLibraryPerson? in
        guard let name = person["Name"] as? String else { return nil }
        let personId = person["Id"] as? String ?? UUID().uuidString
        let role = person["Role"] as? String
        let personType = (person["Type"] as? String) ?? "Actor"
        var imageURL: URL?
        if let primaryTag = person["PrimaryImageTag"] as? String, !primaryTag.isEmpty {
            imageURL = URL(
                string: "\(baseURL)/Items/\(personId)/Images/Primary?maxWidth=200&tag=\(primaryTag)&quality=80"
            )
        }
        return TVMediaLibraryPerson(
            id: personId,
            name: name,
            role: role,
            type: personType,
            imageURL: imageURL
        )
    }
}



func tvMediaLibraryShelfPreviewNodes(
    from nodes: [TVMediaLibraryNode],
    limit: Int
) -> [TVMediaLibraryNode] {
    guard limit > 0 else { return [] }
    let prioritized = nodes.enumerated().sorted { lhs, rhs in
        let lhsPriority = tvMediaLibraryShelfPriority(for: lhs.element)
        let rhsPriority = tvMediaLibraryShelfPriority(for: rhs.element)
        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }
        return lhs.offset < rhs.offset
    }.map { $0.element }
    return Array(prioritized.prefix(limit))
}



func tvMediaLibraryShelfPriority(for node: TVMediaLibraryNode) -> Int {
    if node.posterURL != nil {
        return 0
    }
    if !node.isFolder {
        return 1
    }
    return 2
}



private let tvJellyfinLikeFolderTypes: Set<String> = [
    "folder", "collectionfolder", "series", "season", "musicartist", "musicalbum", "boxset", "playlist"
]

private let tvPlexFolderTypes: Set<String> = [
    "show", "season", "artist", "album", "collection", "genre", "directory", "photoalbum"
]

func tvServerSupportsMediaLibrary(_ server: ServerConfig) -> Bool {
    switch server.type {
    case .jellyfin, .emby, .plex:
        return true
    default:
        return false
    }
}



func tvFileType(from rawType: String) -> VideoFile.FileType {
    switch rawType.lowercased() {
    case "movie", "episode", "video", "clip":
        return .video
    case "song", "audio", "track":
        return .audio
    case "photo", "image":
        return .image
    case "subtitle":
        return .subtitle
    case "folder", "collectionfolder", "series", "season", "musicartist", "musicalbum", "artist", "album", "show":
        return .folder
    default:
        return .document
    }
}



func tvResolvedMediaLibraryUserId(server: ServerConfig) async throws -> String? {
    if let userId = tvTrimmedText(server.userId) {
        return userId
    }
    guard server.type == .jellyfin || server.type == .emby else {
        return nil
    }
    guard let token = tvTrimmedText(server.accessToken) else {
        return nil
    }

    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(baseURL)/Users/Me") else {
        return nil
    }

    var request = tvMediaLibraryRequest(url: url, server: server)
    request.setValue(token, forHTTPHeaderField: "X-Emby-Token")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json["Id"] as? String
}



func tvTestServerConnection(_ server: ServerConfig) async throws -> ServerConfig {
    switch server.type {
    case .jellyfin, .emby:
        var verifiedServer = try await tvPreparedMediaLibraryServer(server: server, forceCredentialRefresh: true)
        guard let userId = try await tvResolvedMediaLibraryUserId(server: verifiedServer), !userId.isEmpty else {
            throw NSError(
                domain: "GenPlayerShell",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
            )
        }

        try await tvValidateMediaLibraryRootAccess(server: verifiedServer, userId: userId)

        if verifiedServer.userId != userId {
            verifiedServer.userId = userId
            await MainActor.run {
                if AppNetworkService.shared.servers.contains(where: { $0.id == verifiedServer.id }) {
                    AppNetworkService.shared.updateServer(verifiedServer)
                }
            }
        }

        return verifiedServer
    default:
        return try await AppNetworkService.shared.testConnection(server)
    }
}



func tvApplyMediaLibraryHeaders(to request: inout URLRequest, server: ServerConfig) {
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    switch server.type {
    case .jellyfin, .emby:
        if let token = tvTrimmedText(server.accessToken) {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            request.setValue(token, forHTTPHeaderField: "X-MediaBrowser-Token")
            let auth = "MediaBrowser Client=\"GenPlayer-tvOS\", Device=\"Apple TV\", DeviceId=\"GenPlayerTV\", Version=\"1.0\", Token=\"\(token)\""
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        } else {
            let auth = "MediaBrowser Client=\"GenPlayer-tvOS\", Device=\"Apple TV\", DeviceId=\"GenPlayerTV\", Version=\"1.0\""
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        }
    case .plex:
        request.setValue("GenPlayer", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("tvOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("GenPlayer-tvOS", forHTTPHeaderField: "X-Plex-Device")
        request.setValue("GenPlayerTV", forHTTPHeaderField: "X-Plex-Client-Identifier")
        if let token = tvTrimmedText(server.accessToken) ?? tvTrimmedText(server.passwordSecret) {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
    case .vod:
        request.setValue(VODService.defaultUserAgent, forHTTPHeaderField: "User-Agent")
    default:
        break
    }
}



func tvMediaLibraryRequest(url: URL, server: ServerConfig) -> URLRequest {
    var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
    tvApplyMediaLibraryHeaders(to: &request, server: server)
    return request
}



func tvApplyMediaLibraryImageHeaders(to request: inout URLRequest, server: ServerConfig) {
    request.timeoutInterval = 20

    switch server.type {
    case .jellyfin, .emby:
        if let token = tvTrimmedText(server.accessToken) {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            request.setValue(token, forHTTPHeaderField: "X-MediaBrowser-Token")
            let auth = "MediaBrowser Client=\"GenPlayer-tvOS\", Device=\"Apple TV\", DeviceId=\"GenPlayerTV\", Version=\"1.0\", Token=\"\(token)\""
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        } else {
            let auth = "MediaBrowser Client=\"GenPlayer-tvOS\", Device=\"Apple TV\", DeviceId=\"GenPlayerTV\", Version=\"1.0\""
            request.setValue(auth, forHTTPHeaderField: "Authorization")
            request.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        }
    case .plex:
        request.setValue("GenPlayer", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("tvOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("GenPlayer-tvOS", forHTTPHeaderField: "X-Plex-Device")
        request.setValue("GenPlayerTV", forHTTPHeaderField: "X-Plex-Client-Identifier")
        if let token = tvTrimmedText(server.accessToken) ?? tvTrimmedText(server.passwordSecret) {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
    default:
        break
    }
}



func tvPreparedMediaLibraryServer(
    server: ServerConfig,
    forceCredentialRefresh: Bool = false
) async throws -> ServerConfig {
    guard server.type == .jellyfin || server.type == .emby else {
        return server
    }

    if !forceCredentialRefresh, let token = tvTrimmedText(server.accessToken) {
        if let userId = tvTrimmedText(server.userId) {
            var verifiedServer = server
            verifiedServer.accessToken = token
            verifiedServer.userId = userId
            return verifiedServer
        }

        if let resolvedUserId = try await tvResolvedMediaLibraryUserId(server: server), !resolvedUserId.isEmpty {
            var verifiedServer = server
            verifiedServer.accessToken = token
            verifiedServer.userId = resolvedUserId
            await MainActor.run {
                if AppNetworkService.shared.servers.contains(where: { $0.id == verifiedServer.id }) {
                    AppNetworkService.shared.updateServer(verifiedServer)
                }
            }
            return verifiedServer
        }

        if !tvHasText(server.username) || !tvHasText(server.passwordSecret) {
            return server
        }
    }

    guard let username = tvTrimmedText(server.username),
          let password = tvTrimmedText(server.passwordSecret) else {
        return server
    }

    let verifiedServer = try await tvAuthenticateMediaLibraryServer(
        server: server,
        username: username,
        password: password
    )

    if verifiedServer.accessToken != server.accessToken ||
        verifiedServer.userId != server.userId ||
        verifiedServer.port != server.port ||
        verifiedServer.useSSL != server.useSSL {
        await MainActor.run {
            if AppNetworkService.shared.servers.contains(where: { $0.id == verifiedServer.id }) {
                AppNetworkService.shared.updateServer(verifiedServer)
            }
        }
    }

    return verifiedServer
}



func tvAuthenticateMediaLibraryServer(
    server: ServerConfig,
    username: String,
    password: String
) async throws -> ServerConfig {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(baseURL)/Users/AuthenticateByName") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(tvMediaLibraryAuthorizationHeader(), forHTTPHeaderField: "Authorization")

    if server.type == .jellyfin {
        request.httpBody = try JSONEncoder().encode(JellyfinAuthRequest(username: username, pw: password))
    } else {
        request.httpBody = try JSONEncoder().encode(EmbyAuthRequest(username: username, pw: password))
    }

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw NSError(
            domain: "GenPlayerShell",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection Failed")]
        )
    }

    if http.statusCode == 401 {
        await MainActor.run {
            AppNetworkService.shared.clearServerAuthTokens(for: server.id)
        }
        throw NSError(
            domain: "GenPlayerShell",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Invalid username or password")]
        )
    }

    guard (200...299).contains(http.statusCode) else {
        throw NSError(
            domain: "GenPlayerShell",
            code: http.statusCode,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection Failed")]
        )
    }

    var verifiedServer = server
    if server.type == .jellyfin {
        let result = try JSONDecoder().decode(JellyfinAuthResult.self, from: data)
        verifiedServer.accessToken = result.accessToken
        verifiedServer.userId = result.user.id
    } else {
        let result = try JSONDecoder().decode(EmbyAuthResult.self, from: data)
        verifiedServer.accessToken = result.accessToken
        verifiedServer.userId = result.user.id
    }

    return verifiedServer
}



func tvValidateMediaLibraryRootAccess(server: ServerConfig, userId: String) async throws {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(baseURL)/Users/\(userId)/Views") else {
        throw URLError(.badURL)
    }

    var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
    tvApplyMediaLibraryHeaders(to: &request, server: server)

    let (_, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else {
        throw NSError(
            domain: "GenPlayerShell",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection Failed")]
        )
    }

    guard (200...299).contains(http.statusCode) else {
        let messageKey = (http.statusCode == 401 || http.statusCode == 403)
            ? "Platform Shell TV Library Server Sign In Hint"
            : "Connection Failed"
        throw NSError(
            domain: "GenPlayerShell",
            code: http.statusCode,
            userInfo: [NSLocalizedDescriptionKey: platformShellString(messageKey)]
        )
    }
}



func tvMediaLibraryErrorMessage(for statusCode: Int?) -> String {
    switch statusCode {
    case 401?, 403?:
        return platformShellString("Platform Shell TV Library Server Sign In Hint")
    default:
        return platformShellString("Connection Failed")
    }
}



func tvMediaLibraryAuthorizationHeader() -> String {
    "MediaBrowser Client=\"GenPlayer-tvOS\", Device=\"Apple TV\", DeviceId=\"GenPlayerTV\", Version=\"1.0\""
}



@MainActor
final class TVStoredMediaPresentationManager: ObservableObject {
    static let shared = TVStoredMediaPresentationManager()
    @Published var presentation: TVStoredMediaPresentation? {
        didSet { if presentation != nil { server = nil } }
    }
    @Published var server: ServerConfig? {
        didSet { if server != nil { presentation = nil } }
    }
    var isBrowsing: Bool { server != nil || presentation != nil }

    func closeBrowsing() {
        server = nil
        presentation = nil
    }
}



@ViewBuilder
func tvStoredMediaDestination(
    for file: VideoFile,
    intent: TVStoredMediaDestinationIntent
) -> some View {
    TVPrivacyProtectedContent(
        title: tvDisplayTitle(for: file),
        isProtected: tvRequiresPrivacyAccess(file: file)
    ) {
        if tvShouldUseLocalFolderBrowser(for: file, intent: intent) {
            TVLocalBrowserView(
                url: tvLocalFolderNavigationURL(for: file, intent: intent),
                rootTitle: platformShellString("Local"),
                targetFileURL: tvLocalFolderTargetFileURL(for: file, intent: intent)
            )
        } else if let server = file.tvResolvedServer(from: AppNetworkService.shared.servers),
           file.isRemote ||
           tvTrimmedText(file.serverPath) != nil ||
           (server.type.tvIsMediaLibraryServer && tvPreferredLibraryTargetItemId(for: file) != nil) {
            if server.type.tvIsMediaLibraryServer,
               let itemId = tvPreferredLibraryTargetItemId(for: file) {
                TVMediaLibraryResolvedItemView(
                    server: server,
                    itemId: itemId,
                    fallbackFile: file
                )
            } else if server.type.tvSupportsFileBrowsing {
                TVRemoteBrowserView(
                    server: server,
                    path: tvRemoteFolderNavigationPath(for: file, intent: intent),
                    rootTitle: tvDisplayTitle(for: file),
                    targetFilePath: tvRemoteFolderTargetFilePath(for: file, intent: intent)
                )
            } else {
                TVMediaDetailView(file: file)
            }
        } else {
            TVMediaDetailView(file: file)
        }
    }
}



func tvPreferredLibraryTargetItemId(for file: VideoFile) -> String? {
    if let seriesId = tvTrimmedText(file.seriesId) {
        return seriesId
    }
    return tvTrimmedText(file.jellyfinItemId)
}



func tvShouldUseLocalFolderBrowser(
    for file: VideoFile,
    intent: TVStoredMediaDestinationIntent
) -> Bool {
    guard file.url.isFileURL, !file.tvHasRemoteOrigin else { return false }
    switch intent {
    case .revealParent:
        return true
    case .openItem:
        return true
    }
}



func tvLocalFolderNavigationURL(
    for file: VideoFile,
    intent: TVStoredMediaDestinationIntent
) -> URL {
    if file.type == .folder && intent == .openItem {
        return file.url.standardizedFileURL
    }
    return file.url.deletingLastPathComponent().standardizedFileURL
}



func tvLocalFolderTargetFileURL(
    for file: VideoFile,
    intent: TVStoredMediaDestinationIntent
) -> URL? {
    if file.type == .folder && intent == .openItem {
        return nil
    }
    return file.url.standardizedFileURL
}



func tvRemoteFolderNavigationPath(
    for file: VideoFile,
    intent: TVStoredMediaDestinationIntent
) -> String {
    let remotePath = tvTrimmedText(file.serverPath) ?? file.url.path
    let rawPath: String
    if file.type == .folder && intent == .openItem {
        rawPath = remotePath
    } else {
        rawPath = URL(fileURLWithPath: remotePath).deletingLastPathComponent().path
    }
    return tvNormalizedRemotePath(rawPath)
}



func tvRemoteFolderTargetFilePath(
    for file: VideoFile,
    intent: TVStoredMediaDestinationIntent
) -> String? {
    if file.type == .folder && intent == .openItem {
        return nil
    }
    return tvNormalizedRemotePath(tvTrimmedText(file.serverPath) ?? file.remoteDownloadPath)
}



struct TVHeaderActionFocus: Equatable {
    let id: String
    let title: String
    var isDestructive: Bool = false
}



struct TVDetailActionHeader: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var headerAccessory: AnyView?

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        headerAccessory: AnyView? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.headerAccessory = headerAccessory
    }

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 14) {
                    if let systemImage, !systemImage.isEmpty {
                        Image(systemName: systemImage)
                            .font(.system(size: 44, weight: .heavy))
                            .foregroundColor(TVShellStyle.primary.opacity(0.88))
                    }

                    Text(title)
                        .font(.system(size: 56, weight: .heavy))
                        .foregroundColor(TVShellStyle.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                }

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.headline.weight(.medium))
                        .foregroundColor(TVShellStyle.secondary)
                        .lineLimit(2)
                }
            }

            if let headerAccessory {
                headerAccessory
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
        .tvFocusSectionIfAvailable()
    }
}



struct TVHeaderActionDescriptionText: View {
    let text: String?
    var width: CGFloat = 360
    var isDestructive = false
    var alignment: Alignment = .leading

    var body: some View {
        Text(text ?? "")
            .font(.system(size: 24, weight: .bold))
            .foregroundColor(isDestructive ? Color.red.opacity(0.95) : TVShellStyle.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .multilineTextAlignment(alignment == .leading ? .leading : .trailing)
            .frame(width: width, alignment: alignment)
            .opacity(text == nil ? 0 : 1)
            .animation(.easeOut(duration: 0.12), value: text)
    }
}



struct TVHeaderIconActionButton: View {
    let title: String
    let systemImageName: String
    var isDestructive = false
    let onFocusChange: (String, Bool) -> Void

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    @Environment(\.colorScheme) private var colorScheme

    private var foregroundColor: Color {
        guard isEnabled else { return TVShellStyle.secondary.opacity(0.44) }
        if isDestructive && !showsFocus {
            return Color.red.opacity(0.95)
        }
        if showsFocus {
            return TVRowFocusStyle.primary(showsFocus: true, isEnabled: isEnabled, colorScheme: colorScheme)
        }
        return TVShellStyle.primary
    }

    private var fillColor: Color {
        if showsFocus {
            return TVRowFocusStyle.focusedFill(for: colorScheme)
        }
        return TVShellStyle.surface
    }

    var body: some View {
        Image(systemName: systemImageName)
            .font(.system(size: 23, weight: .bold))
            .foregroundColor(foregroundColor)
            .frame(width: 58, height: 58)
            .contentShape(Circle())
            .background(
                Circle()
                    .fill(fillColor)
            )
            .overlay(
                Circle()
                    .stroke(showsFocus ? Color.clear : TVShellStyle.glassStroke, lineWidth: 1)
            )

            .scaleEffect(showsFocus ? 1.055 : 1.0)
            .shadow(
                color: showsFocus ? Color.black.opacity(0.22) : .clear,
                radius: showsFocus ? 14 : 0,
                x: 0,
                y: showsFocus ? 7 : 0
            )
            .animation(.easeOut(duration: 0.16), value: showsFocus)
            .modifier(TVFocusedCardLayerModifier())
            .accessibilityLabel(Text(title))
            .onChange(of: isFocused) { focused in
                onFocusChange(title, focused && isEnabled)
            }
    }
}



struct TVHeaderActionPill: View {
    let title: String
    let systemImageName: String
    let width: CGFloat
    var isDestructive = false

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var foregroundColor: Color {
        guard isEnabled else { return TVShellStyle.secondary.opacity(0.45) }
        if isDestructive && !showsFocus {
            return Color.red.opacity(0.95)
        }
        return showsFocus ? Color.black.opacity(0.90) : TVShellStyle.primary
    }

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImageName)
                .font(.system(size: 22, weight: .bold))

            Text(title)
                .font(.system(size: 20, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.74)
        }
        .foregroundColor(foregroundColor)
        .frame(width: width, height: 58)
        .contentShape(Capsule(style: .continuous))
        .background(
            Capsule(style: .continuous)
                .fill(showsFocus ? Color.white.opacity(0.94) : TVShellStyle.surface)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(showsFocus ? Color.clear : TVShellStyle.glassStroke, lineWidth: 1)
        )
        .overlay(TVFocusedBlockOverlay(cornerRadius: 29, showsFocus: showsFocus, outerLineWidth: 2.8, innerInset: 3))
        .scaleEffect(showsFocus ? 1.025 : 1.0)
        .shadow(color: showsFocus ? Color.black.opacity(0.22) : .clear, radius: showsFocus ? 14 : 0, x: 0, y: showsFocus ? 7 : 0)
        .animation(.easeOut(duration: 0.16), value: showsFocus)
        .modifier(TVFocusedCardLayerModifier())
    }
}



enum TVPageContentMetrics {
    static let horizontalPadding: CGFloat = 64
    static let heroHorizontalPadding: CGFloat = 128
}



final class TVImageCache {
    static let shared = TVImageCache()

    private static let embeddedCacheKeyPrefix = "genplayer-image-cache:"

    private let memoryCache = NSCache<NSString, UIImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL

    private init() {
        memoryCache.totalCostLimit = 1024 * 1024 * 50

        let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        cacheDirectory = baseURL.appendingPathComponent("GenPlayerImageCache", isDirectory: true)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func image(for url: URL) -> UIImage? {
        image(forKey: cacheKey(for: url))
    }

    func save(_ image: UIImage, for url: URL) {
        save(image, forKey: cacheKey(for: url))
    }

    func clearCache(completion: (() -> Void)? = nil) {
        memoryCache.removeAllObjects()

        DispatchQueue.global(qos: .userInitiated).async { [cacheDirectory, fileManager] in
            do {
                if fileManager.fileExists(atPath: cacheDirectory.path) {
                    try fileManager.removeItem(at: cacheDirectory)
                }
                try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            } catch {
                print("Error clearing tv image cache: \(error)")
            }

            DispatchQueue.main.async {
                completion?()
            }
        }
    }

    func calculateCacheSize(completion: @escaping (Int64) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [cacheDirectory, fileManager] in
            var totalSize: Int64 = 0

            if let enumerator = fileManager.enumerator(
                at: cacheDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let fileURL as URL in enumerator {
                    guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                          values.isRegularFile == true,
                          let fileSize = values.fileSize else {
                        continue
                    }
                    totalSize += Int64(fileSize)
                }
            }

            DispatchQueue.main.async {
                completion(totalSize)
            }
        }
    }

    func image(forKey key: String) -> UIImage? {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return nil }

        if let image = memoryCache.object(forKey: normalizedKey as NSString) {
            return image
        }

        let fileURL = cacheFileURL(forKey: normalizedKey)
        guard let data = try? Data(contentsOf: fileURL),
              let image = UIImage(data: data) else {
            return nil
        }

        memoryCache.setObject(image, forKey: normalizedKey as NSString, cost: image.cacheCost)
        return image
    }

    func save(_ image: UIImage, forKey key: String) {
        let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedKey.isEmpty else { return }

        memoryCache.setObject(image, forKey: normalizedKey as NSString, cost: image.cacheCost)

        DispatchQueue.global(qos: .utility).async { [cacheDirectory] in
            let fileURL = cacheDirectory.appendingPathComponent(Self.hashedFileName(for: normalizedKey))
            guard let data = image.jpegData(compressionQuality: 0.84) else { return }
            try? data.write(to: fileURL, options: [.atomic])
        }
    }

    private func cacheFileURL(forKey key: String) -> URL {
        cacheDirectory.appendingPathComponent(Self.hashedFileName(for: key))
    }

    private func cacheKey(for url: URL) -> String {
        if let embeddedKey = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
           embeddedKey.hasPrefix(Self.embeddedCacheKeyPrefix) {
            let value = String(embeddedKey.dropFirst(Self.embeddedCacheKeyPrefix.count))
            if !value.isEmpty {
                return value
            }
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.fragment = nil
        if let queryItems = components.queryItems {
            components.queryItems = queryItems.filter { item in
                let name = item.name.lowercased()
                return name != "api_key" && name != "x-plex-token"
            }
        }

        return components.url?.absoluteString ?? url.absoluteString
    }

    private static func hashedFileName(for key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}



extension UIImage {
    var cacheCost: Int {
        max(1, Int(size.width * size.height * scale * scale * 4))
    }
}



func tvCleanupTemporaryDownload(at fileURL: URL) {
    let containerURL = fileURL.deletingLastPathComponent()
    try? FileManager.default.removeItem(at: fileURL)
    try? FileManager.default.removeItem(at: containerURL)
}



struct TVFavoriteGroup: Identifiable {
    let id: String
    let title: String
    let items: [FavoriteItem]
    let server: ServerConfig?
}



@MainActor
func tvRestoreDownloadedRemoteOrigin(
    for file: VideoFile,
    servers: [ServerConfig],
    downloadCenter: DownloadCenterService = .shared
) -> VideoFile {
    guard file.url.isFileURL else { return file }
    if file.tvResolvedServer(from: servers) != nil {
        return file
    }

    let localPath = file.url.standardizedFileURL.path
    guard let task = downloadCenter.tasks.first(where: { task in
        guard task.status == .completed,
              let taskPath = task.localFilePath,
              !taskPath.isEmpty else {
            return false
        }
        return URL(fileURLWithPath: taskPath).standardizedFileURL.path == localPath
    }) else {
        return file
    }

    let server = servers.first(where: { $0.id == task.serverId })
    guard let serverType = server?.type ?? task.sourceType.tvServerType else {
        return file
    }

    var restoredFile = file
    restoredFile.jellyfinServerId = task.serverId.uuidString
    restoredFile.serverType = serverType
    if tvTrimmedText(restoredFile.jellyfinItemId) == nil {
        restoredFile.jellyfinItemId = task.remoteItemId
    }
    if tvTrimmedText(restoredFile.seriesId) == nil {
        restoredFile.seriesId = task.seriesId
    }
    if tvTrimmedText(restoredFile.seasonId) == nil {
        restoredFile.seasonId = task.seasonId
    }
    if tvTrimmedText(restoredFile.serverPath) == nil {
        restoredFile.serverPath = task.remotePath
    }
    return restoredFile
}



enum TVShellGrouping {
    @MainActor
    static func historyGroups(history: [VideoFile], servers: [ServerConfig]) -> [TVHistoryGroup] {
        var groups: [TVHistoryGroup] = []
        let restoredHistory = history.map { tvRestoreDownloadedRemoteOrigin(for: $0, servers: servers) }

        let localItems = restoredHistory
            .filter { !$0.tvHasRemoteOrigin }
            .sorted { $0.date > $1.date }
        if !localItems.isEmpty {
            groups.append(TVHistoryGroup(id: "local", title: platformShellString("Local"), items: localItems, server: nil))
        }

        let remoteItems = restoredHistory
            .filter(\.tvHasRemoteOrigin)
            .sorted { $0.date > $1.date }
        var byServer: [UUID: [VideoFile]] = [:]
        var unmatched: [VideoFile] = []

        for item in remoteItems {
            if let server = item.tvResolvedServer(from: servers) {
                byServer[server.id, default: []].append(item)
            } else {
                unmatched.append(item)
            }
        }

        for server in servers {
            if let items = byServer[server.id], !items.isEmpty {
                groups.append(TVHistoryGroup(id: "server-\(server.id.uuidString)", title: server.name, items: items, server: server))
            }
        }

        if !unmatched.isEmpty {
            groups.append(TVHistoryGroup(id: "remote", title: platformShellString("Network"), items: unmatched, server: nil))
        }

        return groups
    }

    @MainActor
    static func favoriteGroups(favorites: [FavoriteItem], servers: [ServerConfig]) -> [TVFavoriteGroup] {
        var groups: [TVFavoriteGroup] = []
        let restoredFavorites = favorites.map { item -> FavoriteItem in
            var restoredItem = item
            restoredItem.file = tvRestoreDownloadedRemoteOrigin(for: item.file, servers: servers)
            return restoredItem
        }

        let localItems = restoredFavorites
            .filter { !$0.file.tvHasRemoteOrigin }
            .sorted { $0.addedDate > $1.addedDate }
        if !localItems.isEmpty {
            groups.append(TVFavoriteGroup(id: "local", title: platformShellString("Local"), items: localItems, server: nil))
        }

        let remoteItems = restoredFavorites
            .filter { $0.file.tvHasRemoteOrigin }
            .sorted { $0.addedDate > $1.addedDate }
        var byServer: [UUID: [FavoriteItem]] = [:]
        var unmatched: [FavoriteItem] = []

        for item in remoteItems {
            if let server = item.file.tvResolvedServer(from: servers) {
                byServer[server.id, default: []].append(item)
            } else {
                unmatched.append(item)
            }
        }

        for server in servers {
            if let items = byServer[server.id], !items.isEmpty {
                groups.append(TVFavoriteGroup(id: "server-\(server.id.uuidString)", title: server.name, items: items, server: server))
            }
        }

        if !unmatched.isEmpty {
            groups.append(TVFavoriteGroup(id: "remote", title: platformShellString("Network"), items: unmatched, server: nil))
        }

        return groups
    }
}



func tvGroupSubtitle(for server: ServerConfig?) -> String? {
    server?.type.displayName
}



extension VideoFile {
    var tvHasRemoteOrigin: Bool {
        if isRemote { return true }
        if tvTrimmedText(jellyfinServerId) != nil { return true }
        return serverType != nil
    }

    func tvResolvedServer(from servers: [ServerConfig]) -> ServerConfig? {
        if let serverId = jellyfinServerId,
           let uuid = UUID(uuidString: serverId),
           let matched = servers.first(where: { $0.id == uuid }) {
            return matched
        }

        guard isRemote else { return nil }

        guard let host = url.host?.lowercased() else { return nil }

        func matches(_ server: ServerConfig, requireType: Bool) -> Bool {
            if requireType, let preferredType = serverType, server.type != preferredType {
                return false
            }

            let serverHost = (URLComponents(string: server.fullURL)?.host ?? server.address)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard host == serverHost else { return false }

            if let filePort = url.port {
                let serverPort = URLComponents(string: server.fullURL)?.port
                    ?? server.port
                    ?? ServerConfig.defaultPort(for: server.type, useSSL: server.useSSL)
                return filePort == serverPort
            }

            return true
        }

        return servers.first(where: { matches($0, requireType: true) })
            ?? servers.first(where: { matches($0, requireType: false) })
    }
}



extension ServerConfig.ServerType {
    static var tvAllCases: [ServerConfig.ServerType] {
        [.smb, .webdav, .alist, .ftp, .sftp, .nfs, .jellyfin, .emby, .plex, .iptv]
    }

    var tvHeroAccentColor: Color {
        switch self {
        case .jellyfin:
            return Color(red: 0.62, green: 0.84, blue: 0.38)
        case .emby:
            return Color(red: 0.24, green: 0.74, blue: 0.46)
        case .plex:
            return Color(red: 0.95, green: 0.66, blue: 0.19)
        case .smb, .webdav, .ftp, .sftp, .nfs:
            return Color(red: 0.36, green: 0.62, blue: 0.98)
        case .alist:
            return Color(red: 0.0, green: 0.70, blue: 0.85)
        case .pan115:
            return Color(red: 0.22, green: 0.45, blue: 0.98)
        case .onedrive:
            return Color(red: 0.0, green: 0.47, blue: 0.83)
        case .googledrive:
            return Color(red: 0.96, green: 0.72, blue: 0.15)
        case .iptv:
            return Color(red: 0.38, green: 0.34, blue: 0.88)
        case .vod:
            return Color(red: 0.18, green: 0.52, blue: 0.92)
        }
    }

    var tvHeroSecondaryAccentColor: Color {
        switch self {
        case .jellyfin:
            return Color(red: 0.18, green: 0.38, blue: 0.22)
        case .emby:
            return Color(red: 0.10, green: 0.32, blue: 0.24)
        case .plex:
            return Color(red: 0.36, green: 0.24, blue: 0.08)
        case .smb, .webdav, .ftp, .sftp, .nfs:
            return Color(red: 0.12, green: 0.22, blue: 0.42)
        case .alist:
            return Color(red: 0.05, green: 0.30, blue: 0.38)
        case .pan115:
            return Color(red: 0.10, green: 0.16, blue: 0.45)
        case .onedrive:
            return Color(red: 0.04, green: 0.22, blue: 0.42)
        case .googledrive:
            return Color(red: 0.45, green: 0.28, blue: 0.05)
        case .iptv:
            return Color(red: 0.24, green: 0.18, blue: 0.68)
        case .vod:
            return Color(red: 0.08, green: 0.28, blue: 0.65)
        }
    }

    var tvSupportsFileBrowsing: Bool {
        switch self {
        case .smb, .webdav, .alist, .pan115, .onedrive, .googledrive, .ftp, .sftp, .nfs:
            return true
        case .jellyfin, .emby, .plex, .iptv, .vod:
            return false
        }
    }

    var tvSupportsConnectionTest: Bool {
        switch self {
        case .smb, .webdav, .alist, .pan115, .onedrive, .googledrive, .ftp, .sftp, .nfs, .jellyfin, .emby, .plex, .iptv, .vod:
            return true
        }
    }

    var tvShowsSSLToggle: Bool {
        switch self {
        case .webdav, .alist, .jellyfin, .emby, .plex, .vod:
            return true
        case .smb, .pan115, .onedrive, .googledrive, .ftp, .sftp, .nfs, .iptv:
            return false
        }
    }

    var tvIsMediaLibraryServer: Bool {
        switch self {
        case .jellyfin, .emby, .plex, .vod:
            return true
        case .smb, .webdav, .alist, .pan115, .onedrive, .googledrive, .ftp, .sftp, .nfs, .iptv:
            return false
        }
    }

    var tvProtocolSubtitle: String {
        switch self {
        case .smb:
            return "SMB / Samba / Windows File Sharing"
        case .webdav:
            return "WebDAV (Nextcloud, ownCloud, NAS)"
        case .alist:
            return "AList Multi-Storage Service"
        case .pan115:
            return "115 Cloud Storage"
        case .onedrive:
            return "Microsoft OneDrive Cloud Storage"
        case .googledrive:
            return "Google Drive Cloud Storage"
        case .ftp:
            return "FTP File Transfer Protocol"
        case .sftp:
            return "SFTP SSH File Transfer Protocol"
        case .nfs:
            return "NFS Network File System"
        case .jellyfin:
            return "Jellyfin Media Server"
        case .emby:
            return "Emby Media Server"
        case .plex:
            return "Plex Media Server"
        case .iptv:
            return "IPTV Live Channels & M3U Playlist"
        case .vod:
            return "Web VOD Open Streaming Protocol"
        }
    }
}



extension VideoFile.FileType {
    var tvSystemImageName: String {
        switch self {
        case .video:
            return "film"
        case .audio:
            return "music.note"
        case .subtitle, .document:
            return "doc.text"
        case .image:
            return "photo"
        case .folder:
            return "folder"
        case .unknown:
            return "questionmark.folder"
        }
    }
}



extension VideoFile {
    var tvNormalizedExtension: String {
        URL(fileURLWithPath: name).pathExtension.lowercased()
    }

    var tvFileIconName: String {
        switch type {
        case .folder:
            return "folder.fill"
        case .video:
            return "play.rectangle.fill"
        case .audio:
            return "music.note"
        case .subtitle:
            return "captions.bubble.fill"
        case .image:
            return "photo.fill"
        case .document:
            if tvNormalizedExtension == "pdf" { return "doc.richtext.fill" }
            if ["xls", "xlsx", "csv", "tsv", "ods", "numbers"].contains(tvNormalizedExtension) {
                return "tablecells.fill"
            }
            if ["ppt", "pptx", "odp", "key"].contains(tvNormalizedExtension) {
                return "chart.bar.fill"
            }
            if ["doc", "docx", "rtf", "odt", "pages"].contains(tvNormalizedExtension) {
                return "doc.text.fill"
            }
            return "doc.text"
        case .unknown:
            if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz"].contains(tvNormalizedExtension) {
                return "archivebox.fill"
            }
            if ["psd", "ai", "sketch", "fig", "xd"].contains(tvNormalizedExtension) {
                return "paintpalette.fill"
            }
            if ["ttf", "otf", "woff", "woff2"].contains(tvNormalizedExtension) {
                return "textformat"
            }
            return "doc.fill"
        }
    }

    var tvFileIconColor: Color {
        switch type {
        case .folder:
            return Color(red: 0.36, green: 0.60, blue: 0.98)
        case .video:
            return Color(red: 0.76, green: 0.53, blue: 0.98)
        case .audio:
            return Color(red: 0.96, green: 0.53, blue: 0.72)
        case .subtitle:
            return Color(red: 0.98, green: 0.70, blue: 0.35)
        case .image:
            return Color(red: 0.42, green: 0.82, blue: 0.58)
        case .document:
            if tvNormalizedExtension == "pdf" { return .red }
            if ["xls", "xlsx", "csv", "tsv", "ods", "numbers"].contains(tvNormalizedExtension) {
                return Color(red: 0.32, green: 0.76, blue: 0.45)
            }
            if ["ppt", "pptx", "odp", "key"].contains(tvNormalizedExtension) {
                return Color(red: 0.97, green: 0.62, blue: 0.28)
            }
            if ["doc", "docx", "rtf", "odt", "pages"].contains(tvNormalizedExtension) {
                return Color(red: 0.35, green: 0.65, blue: 0.99)
            }
            return Color.white.opacity(0.78)
        case .unknown:
            if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz"].contains(tvNormalizedExtension) {
                return Color(UIColor.systemBrown)
            }
            if ["psd", "ai", "sketch", "fig", "xd"].contains(tvNormalizedExtension) {
                return Color(red: 0.40, green: 0.77, blue: 0.84)
            }
            if ["ttf", "otf", "woff", "woff2"].contains(tvNormalizedExtension) {
                return Color(red: 0.46, green: 0.73, blue: 0.98)
            }
            return Color.white.opacity(0.72)
        }
    }

    var tvFormatBadgeText: String? {
        guard type != .folder else { return nil }
        let uppercasedExtension = tvNormalizedExtension.uppercased()
        guard !uppercasedExtension.isEmpty else { return nil }
        return uppercasedExtension.count > 4 ? String(uppercasedExtension.prefix(4)) : uppercasedExtension
    }

    var tvDecorativeSymbolName: String {
        switch type {
        case .folder:
            return "folder"
        case .video:
            return "play.rectangle"
        case .audio:
            return "waveform"
        case .subtitle:
            return "captions.bubble"
        case .image:
            return "photo"
        case .document:
            return "doc.text"
        case .unknown:
            return "doc"
        }
    }

    var tvPlaybackBadgeSystemImage: String {
        if let serverType {
            switch serverType {
            case .jellyfin, .emby, .plex, .vod:
                if type == .folder {
                    return "folder.fill"
                }
                return type == .audio ? "music.note" : "play.fill"
            case .smb, .webdav, .alist, .pan115, .onedrive, .googledrive, .ftp, .sftp, .nfs, .iptv:
                break
            }
        }

        if jellyfinItemId != nil {
            if type == .folder {
                return "folder.fill"
            }
            return type == .audio ? "music.note" : "play.fill"
        }

        if type == .unknown {
            if itemCount != nil {
                return "folder.fill"
            }
            if isRemote {
                return "play.fill"
            }
        }

        return tvFileIconName
    }

    var tvDurationText: String? {
        guard let duration, duration > 0 else { return nil }
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}



extension DownloadSourceType {
    var tvServerType: ServerConfig.ServerType? {
        switch self {
        case .jellyfin:
            return .jellyfin
        case .emby:
            return .emby
        case .plex:
            return .plex
        case .smb:
            return .smb
        case .webdav:
            return .webdav
        case .ftp:
            return .ftp
        case .sftp:
            return .sftp
        case .nfs:
            return .nfs
        case .alist:
            return .alist
        case .pan115:
            return .pan115
        case .onedrive:
            return .onedrive
        case .googledrive:
            return .googledrive
        case .localImport, .unknown:
            return nil
        }
    }

    var tvDisplayName: String {
        switch self {
        case .jellyfin:
            return "Jellyfin"
        case .emby:
            return "Emby"
        case .plex:
            return "Plex"
        case .smb:
            return "SMB"
        case .webdav:
            return "WebDAV"
        case .ftp:
            return "FTP"
        case .sftp:
            return "SFTP"
        case .nfs:
            return "NFS"
        case .alist:
            return "AList"
        case .pan115:
            return "115"
        case .onedrive:
            return "OneDrive"
        case .googledrive:
            return "Google Drive"
        case .localImport:
            return platformShellString("Local")
        case .unknown:
            return platformShellString("Downloads")
        }
    }

    var tvSystemImageName: String {
        switch self {
        case .jellyfin:
            return "play.tv.fill"
        case .emby:
            return "leaf.fill"
        case .plex:
            return "play.square.fill"
        case .smb:
            return "server.rack"
        case .webdav:
            return "globe"
        case .ftp, .sftp:
            return "network"
        case .nfs:
            return "externaldrive.connected.to.line.below"
        case .alist:
            return "externaldrive.badge.icloud"
        case .pan115:
            return "icloud.fill"
        case .onedrive:
            return "cloud.fill"
        case .googledrive:
            return "externaldrive.badge.icloud"
        case .localImport:
            return "folder"
        case .unknown:
            return "tray.and.arrow.down"
        }
    }
}



extension DownloadTaskStatus {
    var tvSystemImageName: String {
        switch self {
        case .queued:
            return "clock"
        case .downloading:
            return "arrow.down.circle"
        case .paused:
            return "pause.circle"
        case .completed:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        case .canceled:
            return "xmark.circle"
        }
    }

    var tvLocalizedTitle: String {
        switch self {
        case .queued:
            return platformShellString("Queued")
        case .downloading:
            return platformShellString("Downloading...")
        case .paused:
            return platformShellString("Paused")
        case .completed:
            return platformShellString("Completed")
        case .failed:
            return platformShellString("Failed")
        case .canceled:
            return platformShellString("Canceled")
        }
    }

    var tvTintColor: Color {
        switch self {
        case .queued:
            return Color(red: 0.72, green: 0.78, blue: 0.86)
        case .downloading:
            return TVShellStyle.accentSoft
        case .paused:
            return Color(red: 1.0, green: 0.74, blue: 0.34)
        case .completed:
            return Color(red: 0.48, green: 0.88, blue: 0.62)
        case .failed, .canceled:
            return Color(red: 1.0, green: 0.48, blue: 0.40)
        }
    }
}



func tvDocumentsDirectoryURL() -> URL? {
    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
}



func tvDownloadsDirectoryURL(createIfNeeded: Bool = false) -> URL? {
    guard let documentsURL = tvDocumentsDirectoryURL() else { return nil }
    let downloadsURL = documentsURL.appendingPathComponent("Downloads", isDirectory: true)
    if createIfNeeded {
        try? FileManager.default.createDirectory(at: downloadsURL, withIntermediateDirectories: true)
    }
    return downloadsURL
}



func tvDownloadedFolderURL(for job: DownloadJobGroup) -> URL? {
    let folderURLs = job.tasks.compactMap { task -> URL? in
        guard task.status == .completed,
              let path = task.localFilePath,
              !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent()
    }

    guard !folderURLs.isEmpty else { return nil }
    let uniquePaths = Array(Set(folderURLs.map { $0.standardizedFileURL.path })).sorted()
    guard let firstPath = uniquePaths.first else { return nil }
    return URL(fileURLWithPath: firstPath)
}



func tvDownloadLocationText(for job: DownloadJobGroup) -> String? {
    guard let folderURL = tvDownloadedFolderURL(for: job) else { return nil }
    guard let documentsURL = tvDocumentsDirectoryURL() else {
        return folderURL.lastPathComponent
    }

    let documentsPath = documentsURL.standardizedFileURL.path
    let folderPath = folderURL.standardizedFileURL.path
    if folderPath.hasPrefix(documentsPath) {
        let suffix = String(folderPath.dropFirst(documentsPath.count))
        let relativePath = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
        return relativePath.isEmpty ? platformShellString("Documents") : relativePath
    }
    return folderPath
}



func tvDownloadedLocalFiles(from tasks: [DownloadTaskItem]) -> [VideoFile] {
    var seenPaths = Set<String>()

    return tasks
        .filter { $0.status == .completed }
        .sorted { $0.createdAt > $1.createdAt }
        .compactMap { task in
            guard let path = task.localFilePath, !path.isEmpty else { return nil }

            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard seenPaths.insert(url.path).inserted else { return nil }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDirectory = values?.isDirectory ?? false
            let type: VideoFile.FileType = isDirectory ? .folder : VideoFile.FileType.determineType(from: url)
            let server = AppNetworkService.shared.servers.first(where: { $0.id == task.serverId })
            let serverType = server?.type ?? task.sourceType.tvServerType

            var file = VideoFile(
                name: task.displayTitle.isEmpty ? url.lastPathComponent : task.displayTitle,
                url: url,
                type: type,
                size: Int64(values?.fileSize ?? 0),
                date: values?.contentModificationDate ?? task.createdAt,
                isRemote: false,
                jellyfinItemId: task.remoteItemId,
                jellyfinServerId: serverType == nil ? nil : task.serverId.uuidString,
                serverType: serverType,
                itemCount: isDirectory ? tvLocalFolderItemCount(at: url) : nil
            )
            file.serverPath = task.remotePath
            file.seriesId = task.seriesId
            file.seasonId = task.seasonId
            return file
        }
}



func tvLocalFolderItemCount(at directoryURL: URL) -> Int? {
    guard let urls = try? FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    ) else {
        return nil
    }

    return urls.count
}



func tvPopNavigationIfPossible(in browsingNavigation: TVBrowsingNavigation? = nil) -> Bool {
    if let browsingNavigation { return browsingNavigation.pop() }
    guard let navigationController = tvActiveNavigationController(),
          navigationController.viewControllers.count > 1 else {
        return false
    }

    navigationController.popViewController(animated: true)
    return true
}



func tvPopToRootNavigationIfPossible(in browsingNavigation: TVBrowsingNavigation? = nil) -> Bool {
    if let browsingNavigation { return browsingNavigation.pop(toRoot: true) }
    guard let navigationController = tvActiveNavigationController(),
          navigationController.viewControllers.count > 1 else {
        return false
    }

    navigationController.popToRootViewController(animated: true)
    return true
}



func tvActiveNavigationController() -> UINavigationController? {
    let scenes = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .sorted { lhs, rhs in
            func rank(_ state: UIScene.ActivationState) -> Int {
                switch state {
                case .foregroundActive: return 0
                case .foregroundInactive: return 1
                case .background: return 2
                case .unattached: return 3
                @unknown default: return 4
                }
            }

            return rank(lhs.activationState) < rank(rhs.activationState)
        }

    for scene in scenes {
        let window = scene.windows.first(where: { $0.isKeyWindow })
            ?? scene.windows.first(where: { $0.windowLevel == .normal && !$0.isHidden })

        if let navigationController = tvFindNavigationController(from: window?.rootViewController) {
            return navigationController
        }
    }

    return nil
}



func tvFindNavigationController(from viewController: UIViewController?) -> UINavigationController? {
    guard let viewController else { return nil }

    if let presentedViewController = viewController.presentedViewController,
       let found = tvFindNavigationController(from: presentedViewController) {
        return found
    }

    if let tabBarController = viewController as? UITabBarController,
       let found = tvFindNavigationController(from: tabBarController.selectedViewController) {
        return found
    }

    if let navigationController = viewController as? UINavigationController {
        return tvFindNavigationController(from: navigationController.visibleViewController) ?? navigationController
    }

    for childViewController in viewController.children.reversed() {
        if let found = tvFindNavigationController(from: childViewController) {
            return found
        }
    }

    return viewController.navigationController
}



func sortVideoFiles(_ files: [VideoFile]) -> [VideoFile] {
    tvSortVideoFiles(files)
}



func tvSortVideoFiles(
    _ files: [VideoFile],
    option: TVFileSortOption = .name,
    ascending: Bool = true,
    foldersOnTop: Bool = true
) -> [VideoFile] {
    files.sorted { lhs, rhs in
        if foldersOnTop {
            if lhs.type == .folder && rhs.type != .folder {
                return true
            }
            if lhs.type != .folder && rhs.type == .folder {
                return false
            }
        }

        switch option {
        case .name:
            return tvCompareFileNames(lhs, rhs, ascending: ascending)
        case .date:
            if lhs.date != rhs.date {
                return ascending ? lhs.date < rhs.date : lhs.date > rhs.date
            }
        case .size:
            if lhs.size != rhs.size {
                return ascending ? lhs.size < rhs.size : lhs.size > rhs.size
            }
        }

        return tvCompareFileNames(lhs, rhs, ascending: true)
    }
}



func tvCompareFileNames(_ lhs: VideoFile, _ rhs: VideoFile, ascending: Bool) -> Bool {
    let result = lhs.name.localizedStandardCompare(rhs.name)
    if result != .orderedSame {
        return ascending ? result == .orderedAscending : result == .orderedDescending
    }
    return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
}



func tvLoadLocalDirectoryContents(at directoryURL: URL) throws -> [VideoFile] {
    let fileManager = FileManager.default
    let contents = try fileManager.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
        options: [.skipsHiddenFiles]
    )

    return contents.compactMap { url -> VideoFile? in
        if url.lastPathComponent.hasPrefix(".") { return nil }

        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
        let isDirectory = values?.isDirectory ?? false
        let type: VideoFile.FileType = isDirectory ? .folder : VideoFile.FileType.determineType(from: url)
        let itemCount = isDirectory ? tvLocalDirectoryItemCount(at: url, fileManager: fileManager) : nil

        return VideoFile(
            name: url.lastPathComponent,
            url: url.standardizedFileURL,
            type: type,
            size: Int64(values?.fileSize ?? 0),
            date: values?.contentModificationDate ?? Date(),
            itemCount: itemCount
        )
    }
}



func tvLocalDirectoryItemCount(at url: URL, fileManager: FileManager = .default) -> Int? {
    guard let contents = try? fileManager.contentsOfDirectory(atPath: url.path) else { return nil }
    return contents.filter { !$0.hasPrefix(".") }.count
}



func tvLocalBrowserFocusID(for url: URL) -> String {
    url.standardizedFileURL.path
}



func tvGroupedVideoFiles(
    _ files: [VideoFile],
    option: TVFileSortOption = .name,
    ascending: Bool = true,
    foldersOnTop: Bool = true
) -> [(type: VideoFile.FileType, items: [VideoFile])] {
    let sorted = tvSortVideoFiles(files, option: option, ascending: ascending, foldersOnTop: foldersOnTop)
    let preferredOrder: [VideoFile.FileType] = [.folder, .video, .audio, .image, .subtitle, .document, .unknown]
    let groupOrder: [VideoFile.FileType]

    if foldersOnTop {
        groupOrder = preferredOrder
    } else {
        var orderedTypes: [VideoFile.FileType] = []
        for item in sorted where !orderedTypes.contains(item.type) {
            orderedTypes.append(item.type)
        }
        groupOrder = orderedTypes
    }

    return groupOrder.compactMap { type in
        let groupItems = sorted.filter { $0.type == type }
        guard !groupItems.isEmpty else { return nil }
        return (type: type, items: groupItems)
    }
}



func tvFileGroupSummary(for groups: [(type: VideoFile.FileType, items: [VideoFile])]) -> String? {
    let tokens = groups.map { group in
        "\(group.items.count) \(tvMediaTypeTitle(for: group.type))"
    }
    return tokens.isEmpty ? nil : tokens.joined(separator: " · ")
}



func tvGroupedFavoriteItems(_ items: [FavoriteItem]) -> [(type: VideoFile.FileType, items: [FavoriteItem])] {
    let preferredOrder: [VideoFile.FileType] = [.folder, .video, .audio, .image, .subtitle, .document, .unknown]

    return preferredOrder.compactMap { type in
        let groupItems = items.filter { $0.file.type == type }
        guard !groupItems.isEmpty else { return nil }
        return (type: type, items: groupItems)
    }
}



func tvMediaTypeTitle(for type: VideoFile.FileType) -> String {
    switch type {
    case .folder:
        return platformShellString("Folder")
    case .video:
        return platformShellString("Video")
    case .audio:
        return platformShellString("Audio")
    case .image:
        return platformShellString("Photos")
    case .subtitle, .document:
        return platformShellString("Documents")
    case .unknown:
        return platformShellString("Files")
    }
}



func tvDisplayName(for url: URL) -> String {
    let name = url.lastPathComponent
    return name.isEmpty ? platformShellString("Local") : tvDisplayTitle(from: name, type: .folder)
}



func tvLocalBrowserRootBoundaryURL(for url: URL) -> URL {
    let directoryURL = url.standardizedFileURL
    guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.standardizedFileURL else {
        return directoryURL
    }

    let directoryPath = directoryURL.path
    let documentsPath = documentsURL.path
    if directoryPath == documentsPath || directoryPath.hasPrefix(documentsPath + "/") {
        return documentsURL
    }

    return directoryURL
}



func tvLocalParentURL(for url: URL, rootBoundaryURL: URL) -> URL? {
    let currentURL = url.standardizedFileURL
    let rootURL = rootBoundaryURL.standardizedFileURL
    guard currentURL.path != rootURL.path else { return nil }

    let parentURL = currentURL.deletingLastPathComponent().standardizedFileURL
    guard parentURL.path != currentURL.path else { return nil }
    guard parentURL.path == rootURL.path || parentURL.path.hasPrefix(rootURL.path + "/") else { return nil }
    return parentURL
}



func tvLocalFolderBreadcrumb(
    rootTitle: String,
    directoryURL: URL,
    rootBoundaryURL: URL
) -> String? {
    let directoryPath = directoryURL.standardizedFileURL.path
    let rootPath = rootBoundaryURL.standardizedFileURL.path
    guard directoryPath != rootPath else { return nil }

    let relativePath: String
    if directoryPath.hasPrefix(rootPath + "/") {
        relativePath = String(directoryPath.dropFirst(rootPath.count + 1))
    } else {
        relativePath = directoryURL.lastPathComponent
    }

    let components = relativePath
        .split(separator: "/", omittingEmptySubsequences: true)
        .map { tvDisplayTitle(from: String($0), type: .folder) }
        .filter { !$0.isEmpty }

    guard !components.isEmpty else { return nil }

    let visibleComponents: [String]
    if components.count > 3 {
        visibleComponents = ["..."] + components.suffix(3)
    } else {
        visibleComponents = components
    }

    return ([rootTitle] + visibleComponents).joined(separator: " / ")
}



func tvDisplayName(forRemotePath path: String) -> String {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
    if let last = components.last {
        return tvDisplayTitle(from: String(last), type: .folder)
    }
    return platformShellString("Network")
}



func tvNormalizedRemotePath(_ path: String) -> String {
    var trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
    trimmedPath = trimmedPath.replacingOccurrences(of: "\\", with: "/")
    while trimmedPath.contains("//") {
        trimmedPath = trimmedPath.replacingOccurrences(of: "//", with: "/")
    }
    if trimmedPath.count > 1 && trimmedPath.hasSuffix("/") {
        trimmedPath.removeLast()
    }
    guard !trimmedPath.isEmpty else { return "/" }
    return trimmedPath.hasPrefix("/") ? trimmedPath : "/" + trimmedPath
}



func tvParentRemotePath(for path: String) -> String? {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)

    guard !components.isEmpty else { return nil }
    guard components.count > 1 else { return "/" }

    return "/" + components.dropLast().joined(separator: "/")
}



func tvRemoteFolderBreadcrumb(serverName: String, path: String) -> String? {
    let components = path.split(separator: "/", omittingEmptySubsequences: true)
        .map { tvDisplayTitle(from: String($0), type: .folder) }
        .filter { !$0.isEmpty }

    guard !components.isEmpty else { return nil }

    let visibleComponents: [String]
    if components.count > 3 {
        visibleComponents = ["..."] + components.suffix(3)
    } else {
        visibleComponents = components
    }

    return ([serverName] + visibleComponents).joined(separator: " / ")
}



func tvDisplayTitle(for file: VideoFile) -> String {
    tvDisplayTitle(from: file.name, type: file.type)
}



func tvStoredMediaArtworkURL(for file: VideoFile, server: ServerConfig?) -> URL? {
    if let server, file.tvHasRemoteOrigin {
        switch server.type {
        case .jellyfin:
            if let seriesId = tvTrimmedText(file.seriesId) {
                return tvJellyfinImageURL(server: server, itemId: seriesId, imageType: "Primary", maxWidth: 800)
            }
            if let itemId = tvTrimmedText(file.jellyfinItemId) {
                return tvJellyfinImageURL(server: server, itemId: itemId, imageType: "Primary", maxWidth: 800)
            }
        case .emby:
            if let seriesId = tvTrimmedText(file.seriesId) {
                return tvEmbyImageURL(server: server, itemId: seriesId, imageType: "Primary", maxWidth: 800)
            }
            if let itemId = tvTrimmedText(file.jellyfinItemId) {
                return tvEmbyImageURL(server: server, itemId: itemId, imageType: "Primary", maxWidth: 800)
            }
        case .plex:
            return tvPlexStoredMediaArtworkURL(for: file, server: server)
        case .smb, .webdav:
            return (file.type == .image || file.type == .audio) ? file.url : nil
        case .alist, .pan115, .onedrive, .googledrive:
            return file.type == .image ? file.url : nil
        case .ftp, .sftp, .nfs:
            return file.type == .image ? file.url : nil
        case .iptv, .vod:
            return file.customArtworkURL
        }
    }

    switch file.type {
    case .video, .image, .audio:
        return file.url
    case .folder, .subtitle, .document, .unknown:
        return nil
    }
}



func tvPlexStoredMediaArtworkURL(for file: VideoFile, server: ServerConfig) -> URL? {
    let itemId = tvTrimmedText(file.seriesId) ?? tvTrimmedText(file.jellyfinItemId)
    guard let itemId else { return nil }

    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/library/metadata/\(itemId)/thumb") else {
        return nil
    }

    if let token = tvTrimmedText(server.accessToken) ?? tvTrimmedText(server.passwordSecret) {
        components.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
    }
    return components.url
}



func tvLoadGenericArtworkImage(from url: URL) async throws -> UIImage {
    if let cachedImage = TVImageCache.shared.image(for: url) {
        return cachedImage
    }

    if url.isFileURL {
        if tvIsArtworkImageURL(url),
           let image = UIImage(contentsOfFile: url.path) {
            return image
        }

        if tvIsArtworkVideoURL(url) {
            return try await tvGenerateVideoArtworkImage(from: url)
        }

        if tvIsArtworkAudioURL(url) {
            return try tvExtractAudioArtworkImage(from: url)
        }

        throw URLError(.cannotDecodeContentData)
    }

    guard tvIsArtworkImageURL(url) else {
        if tvIsArtworkVideoURL(url) {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "file" || scheme == "http" || scheme == "https" {
                if let image = await tvGenerateIndependentArtworkImage(from: url) {
                    TVImageCache.shared.save(image, for: url)
                    return image
                }
            }
            throw URLError(.cannotDecodeContentData)
        }
        if tvIsArtworkAudioURL(url) {
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "http" || scheme == "https" {
                return try tvExtractAudioArtworkImage(from: url)
            } else {
                throw URLError(.cannotDecodeContentData)
            }
        }
        throw URLError(.cannotDecodeContentData)
    }

    let request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url), timeoutInterval: 20)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse,
          (200...299).contains(http.statusCode),
          let image = UIImage(data: data) else {
        throw URLError(.cannotDecodeContentData)
    }
    TVImageCache.shared.save(image, for: url)
    return image
}



func tvGenerateVideoArtworkImage(from url: URL) async throws -> UIImage {
    let scheme = url.scheme?.lowercased() ?? ""
    let isStandardScheme = scheme == "file" || scheme == "http" || scheme == "https"

    if isStandardScheme && url.pathExtension.lowercased() != "mkv" {
        do {
            return try tvGenerateAVAssetVideoArtworkImage(from: url)
        } catch {
            if let fallbackImage = await tvGenerateIndependentArtworkImage(from: url) {
                return fallbackImage
            }
            throw error
        }
    }

    if let fallbackImage = await tvGenerateIndependentArtworkImage(from: url) {
        return fallbackImage
    }

    if isStandardScheme {
        return try tvGenerateAVAssetVideoArtworkImage(from: url)
    }

    throw URLError(.cannotDecodeContentData)
}



func tvGenerateAVAssetVideoArtworkImage(from url: URL) throws -> UIImage {
    let asset = AVURLAsset(url: url)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: 1280, height: 720)

    let duration = CMTimeGetSeconds(asset.duration)
    let targetSeconds = duration.isFinite && duration > 0 ? min(duration * 0.05, 10.0) : 1.0
    let preferredTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
    let image = try generator.copyCGImage(at: preferredTime, actualTime: nil)
    return UIImage(cgImage: image)
}



func tvExtractAudioArtworkImage(from url: URL) throws -> UIImage {
    let asset = AVURLAsset(url: url)

    if let artwork = tvExtractAudioArtworkImage(from: asset.commonMetadata) {
        return artwork
    }

    for format in asset.availableMetadataFormats {
        if let artwork = tvExtractAudioArtworkImage(from: asset.metadata(forFormat: format)) {
            return artwork
        }
    }

    throw URLError(.cannotDecodeContentData)
}



func tvExtractAudioArtworkImage(from metadataItems: [AVMetadataItem]) -> UIImage? {
    if let commonArtwork = metadataItems.first(where: { $0.commonKey == .commonKeyArtwork }),
       let image = tvDecodeAudioArtworkImage(from: commonArtwork) {
        return image
    }

    for item in metadataItems {
        let identifier = item.identifier?.rawValue.lowercased() ?? ""
        let isArtworkIdentifier = identifier.contains("artwork") ||
            identifier.contains("cover") ||
            identifier.contains("covr") ||
            identifier.contains("apic")
        if isArtworkIdentifier,
           let image = tvDecodeAudioArtworkImage(from: item) {
            return image
        }
    }

    return nil
}



func tvDecodeAudioArtworkImage(from item: AVMetadataItem) -> UIImage? {
    if let data = item.dataValue,
       let image = UIImage(data: data) {
        return image
    }
    if let data = item.value as? Data,
       let image = UIImage(data: data) {
        return image
    }
    if let image = item.value as? UIImage {
        return image
    }
    return nil
}



func tvGenerateIndependentArtworkImage(from url: URL) async -> UIImage? {
    let continuationBox = TVThumbnailContinuationBox()
    let generatorBox = TVThumbnailGeneratorBox()

    return await withTaskCancellationHandler(operation: {
        await withCheckedContinuation { continuation in
            continuationBox.store(continuation)

            DispatchQueue.main.async {
                let generator = IndependentMediaThumbnailGenerator()
                generatorBox.store(generator)
                generator.generateThumbnail(for: url) { image in
                    generatorBox.clear()
                    continuationBox.resume(with: image)
                }
            }
        }
    }, onCancel: {
        DispatchQueue.main.async {
            generatorBox.cancel()
            continuationBox.resume(with: nil)
        }
    })
}



final class TVThumbnailContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?

    func store(_ continuation: CheckedContinuation<UIImage?, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with image: UIImage?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: image)
    }
}



final class TVThumbnailGeneratorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var generator: IndependentMediaThumbnailGenerator?

    func store(_ generator: IndependentMediaThumbnailGenerator) {
        lock.lock()
        self.generator = generator
        lock.unlock()
    }

    func clear() {
        lock.lock()
        generator = nil
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let generator = self.generator
        self.generator = nil
        lock.unlock()
        generator?.cancel()
    }
}



func tvIsArtworkImageURL(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "tiff", "tif", "bmp"].contains(ext)
}



func tvIsArtworkVideoURL(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return VideoFile.FileType.videoExtensions.contains(ext)
}



func tvIsArtworkAudioURL(_ url: URL) -> Bool {
    let ext = url.pathExtension.lowercased()
    return VideoFile.FileType.audioExtensions.contains(ext)
}



@MainActor
func tvPlayableFile(
    from file: VideoFile,
    downloadCenter: DownloadCenterService
) -> VideoFile? {
    guard file.type == .video || file.type == .audio else { return nil }
    return downloadCenter.localPlaybackFile(for: file) ?? file
}



@MainActor
func tvLibraryPlaybackFile(
    server: ServerConfig,
    node: TVMediaLibraryNode
) -> VideoFile? {
    guard node.type == .video || node.type == .audio else { return nil }
    guard let fallbackURL = URL(string: server.fullURL) else { return nil }

    var file = VideoFile(
        name: node.name,
        url: fallbackURL,
        type: node.type,
        size: 0,
        date: Date(),
        isRemote: true,
        duration: node.runtimeTicks.map { TimeInterval($0) / 10_000_000.0 },
        lastPlayedPosition: node.playbackPositionSeconds,
        jellyfinItemId: node.id,
        jellyfinServerId: server.id.uuidString,
        serverType: server.type,
        seriesId: node.seriesId,
        seasonId: node.seasonId
    )
    file.serverSize = node.mediaSize
    file.serverContainer = node.mediaContainer
    return file
}



@MainActor
func tvOfflineLibraryPlaybackFile(
    server: ServerConfig,
    node: TVMediaLibraryNode,
    downloadCenter: DownloadCenterService = .shared
) -> VideoFile? {
    guard let file = tvLibraryPlaybackFile(server: server, node: node) else { return nil }
    return downloadCenter.localPlaybackFile(for: file)
}



@MainActor
func tvPlayableLibraryFile(
    server: ServerConfig,
    node: TVMediaLibraryNode
) -> VideoFile? {
    guard let file = tvLibraryPlaybackFile(server: server, node: node) else { return nil }
    return DownloadCenterService.shared.localPlaybackFile(for: file) ?? file
}



@MainActor
func tvDownloadedLibraryPlaybackFiles(
    server: ServerConfig,
    itemId: String? = nil,
    seriesId: String? = nil,
    seasonId: String? = nil,
    downloadCenter: DownloadCenterService = .shared
) -> [VideoFile] {
    let normalizedItemId = tvTrimmedText(itemId)
    let normalizedSeriesId = tvTrimmedText(seriesId)
    let normalizedSeasonId = tvTrimmedText(seasonId)

    guard normalizedItemId != nil || normalizedSeriesId != nil || normalizedSeasonId != nil else {
        return []
    }

    var seenPaths = Set<String>()
    return downloadCenter.tasks
        .filter { task in
            task.status == .completed &&
            task.serverId == server.id &&
            tvDownloadTaskMatchesLibraryScope(
                task,
                itemId: normalizedItemId,
                seriesId: normalizedSeriesId,
                seasonId: normalizedSeasonId
            )
        }
        .sorted(by: tvDownloadedLibraryTaskSort)
        .compactMap { task in
            guard let file = tvDownloadedLibraryPlaybackFile(server: server, task: task) else {
                return nil
            }
            guard seenPaths.insert(file.url.standardizedFileURL.path).inserted else {
                return nil
            }
            return file
        }
}



func tvDownloadTaskMatchesLibraryScope(
    _ task: DownloadTaskItem,
    itemId: String?,
    seriesId: String?,
    seasonId: String?
) -> Bool {
    if let itemId {
        return tvDownloadTaskMatchesLibraryID(task, id: itemId)
    }

    if let seasonId {
        return tvDownloadTaskTextMatches(task.seasonId, seasonId) ||
            tvDownloadTaskTextMatches(task.collectionId, seasonId)
    }

    if let seriesId {
        return tvDownloadTaskTextMatches(task.seriesId, seriesId) ||
            tvDownloadTaskTextMatches(task.collectionId, seriesId)
    }

    return false
}



func tvDownloadTaskMatchesLibraryID(_ task: DownloadTaskItem, id: String) -> Bool {
    tvDownloadTaskTextMatches(task.remoteItemId, id) ||
        tvDownloadTaskTextMatches(task.collectionId, id) ||
        tvDownloadTaskTextMatches(task.seriesId, id) ||
        tvDownloadTaskTextMatches(task.seasonId, id) ||
        task.remotePath.localizedCaseInsensitiveContains(id) ||
        task.fileName.localizedCaseInsensitiveContains(id)
}



func tvDownloadTaskTextMatches(_ value: String?, _ target: String) -> Bool {
    guard let value = tvTrimmedText(value) else { return false }
    return value.caseInsensitiveCompare(target) == .orderedSame
}



func tvDownloadedLibraryTaskSort(_ lhs: DownloadTaskItem, _ rhs: DownloadTaskItem) -> Bool {
    if lhs.jobId == rhs.jobId, lhs.groupIndex != rhs.groupIndex {
        return lhs.groupIndex < rhs.groupIndex
    }
    if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt < rhs.createdAt
    }
    return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
}



func tvDownloadedLibraryPlaybackFile(
    server: ServerConfig,
    task: DownloadTaskItem
) -> VideoFile? {
    guard let path = task.localFilePath,
          !path.isEmpty else {
        return nil
    }

    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
    let resolvedType = VideoFile.FileType.determineType(from: url)
    let playbackType = resolvedType == .unknown ? .video : resolvedType

    return VideoFile(
        name: task.displayTitle.isEmpty ? url.lastPathComponent : task.displayTitle,
        url: url,
        type: playbackType,
        size: Int64(values?.fileSize ?? Int(clamping: task.bytesTotal)),
        date: values?.contentModificationDate ?? task.createdAt,
        isRemote: false,
        jellyfinItemId: task.remoteItemId,
        jellyfinServerId: server.id.uuidString,
        serverType: server.type,
        seriesId: task.seriesId,
        seasonId: task.seasonId
    )
}



struct TVLocalFavoriteTarget {
    let file: VideoFile
    let identityPath: String
}



func tvLocalFavoriteTarget(
    server: ServerConfig,
    node: TVMediaLibraryNode
) -> TVLocalFavoriteTarget? {
    let rawType = node.rawItemType.lowercased()
    let targetId: String
    let targetName: String
    let targetSeriesId: String?

    if node.isSeries {
        targetId = node.id
        targetName = tvDisplayTitle(from: node.name, type: node.type)
        targetSeriesId = node.id
    } else if rawType == "episode" || rawType == "season" {
        guard let seriesId = tvTrimmedText(node.seriesId) else { return nil }
        targetId = seriesId
        targetName = tvDisplayTitle(from: node.seriesName ?? node.name, type: .video)
        targetSeriesId = seriesId
    } else {
        guard node.type == .video || node.type == .audio else { return nil }
        targetId = node.id
        targetName = tvDisplayTitle(from: node.name, type: node.type)
        targetSeriesId = node.seriesId
    }

    let identityPath: String
    let identityURLString: String
    switch server.type {
    case .jellyfin:
        identityPath = "__jellyfin_item__/\(targetId)"
        identityURLString = "\(server.fullURL)/Items/\(targetId)"
    case .emby:
        identityPath = "__emby_item__/\(targetId)"
        identityURLString = "\(server.fullURL)/Items/\(targetId)"
    case .plex:
        identityPath = "__plex_item__/\(targetId)"
        identityURLString = "\(server.fullURL)/library/metadata/\(targetId)"
    default:
        return nil
    }

    guard let identityURL = URL(string: identityURLString) else { return nil }
    let file = VideoFile(
        name: targetName,
        url: identityURL,
        type: node.type == .audio ? .audio : .video,
        size: 0,
        date: Date(),
        isRemote: true,
        duration: node.runtimeTicks.map { TimeInterval($0) / 10_000_000.0 },
        lastPlayedPosition: node.playbackPositionSeconds,
        jellyfinItemId: targetId,
        jellyfinServerId: server.id.uuidString,
        serverType: server.type,
        seriesId: targetSeriesId,
        seasonId: nil
    )
    return TVLocalFavoriteTarget(file: file, identityPath: identityPath)
}



func tvDisplayTitle(from rawName: String, type: VideoFile.FileType?) -> String {
    let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return platformShellString("Files")
    }

    let decoded = trimmed.removingPercentEncoding ?? trimmed
    let normalized = decoded.replacingOccurrences(of: "\\", with: "/")
    let name = normalized.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? decoded
    guard !name.isEmpty else { return decoded }

    guard tvShouldStripPathExtension(for: type) else {
        return name
    }

    let sourceURL = URL(fileURLWithPath: name)
    let stripped = sourceURL.deletingPathExtension().lastPathComponent
    return stripped.isEmpty ? name : stripped
}



func tvShouldStripPathExtension(for type: VideoFile.FileType?) -> Bool {
    switch type {
    case .video, .audio, .image:
        return true
    default:
        return false
    }
}



func tvTrimmedText(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}



func tvHasText(_ value: String?) -> Bool {
    tvTrimmedText(value) != nil
}



func tvServerSummary(for server: ServerConfig) -> String {
    let components = URLComponents(string: server.fullURL)
    let host = (components?.host ?? server.address)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let port = components?.port ?? server.port
    let hostWithPort: String
    if let port {
        let defaultPort = ServerConfig.defaultPort(for: server.type, useSSL: server.useSSL)
        hostWithPort = (port == defaultPort ? host : "\(host):\(port)")
    } else {
        hostWithPort = host.isEmpty ? server.type.displayName : host
    }

    if server.type == .iptv {
        if let summary = IPTVService.shared.summary(for: server.id) {
            return "\(hostWithPort) · \(summary.groupCount) \(platformShellString("Groups")) · \(summary.channelCount) \(platformShellString("Channels")) · \(IPTVService.shared.formatLastUpdated(summary.lastUpdated))"
        }
        return "\(hostWithPort) · \(platformShellString("Not loaded yet"))"
    }

    if let mediaSummary = MediaServerSummaryService.shared.summary(for: server.id) {
        if mediaSummary.movieCount > 0 || mediaSummary.seriesCount > 0 {
            var parts: [String] = [hostWithPort]
            if mediaSummary.movieCount > 0 {
                parts.append("\(mediaSummary.movieCount) \(platformShellString("Movies"))")
            }
            if mediaSummary.seriesCount > 0 {
                parts.append("\(mediaSummary.seriesCount) \(platformShellString("TV Shows"))")
            }
            parts.append(MediaServerSummaryService.shared.formatLastUpdated(mediaSummary.lastUpdated))
            return parts.joined(separator: " · ")
        }
        return "\(hostWithPort) · \(String(format: platformShellString("%d Libraries"), mediaSummary.libraryCount)) · \(MediaServerSummaryService.shared.formatLastUpdated(mediaSummary.lastUpdated))"
    }

    if let lastAccessed = server.lastAccessed {
        return "\(hostWithPort) · \(MediaServerSummaryService.shared.formatLastUpdated(lastAccessed))"
    }

    return hostWithPort
}



extension ServerConfig.ServerType {
    var tvAccentColor: Color {
        switch self {
        case .smb:
            return Color(red: 0.30, green: 0.53, blue: 0.93)
        case .webdav:
            return Color(red: 0.11, green: 0.60, blue: 0.90)
        case .ftp:
            return Color(red: 0.83, green: 0.48, blue: 0.41)
        case .sftp:
            return Color(red: 0.33, green: 0.68, blue: 0.71)
        case .nfs:
            return Color(red: 0.51, green: 0.63, blue: 0.80)
        case .jellyfin:
            return Color(red: 0.56, green: 0.37, blue: 0.91)
        case .emby:
            return Color(red: 0.24, green: 0.69, blue: 0.36)
        case .plex:
            return Color(red: 0.96, green: 0.64, blue: 0.17)
        case .alist:
            return Color(red: 0.0, green: 0.70, blue: 0.85)
        case .pan115:
            return Color(red: 0.22, green: 0.45, blue: 0.98)
        case .onedrive:
            return Color(red: 0.0, green: 0.47, blue: 0.83)
        case .googledrive:
            return Color(red: 0.96, green: 0.72, blue: 0.15)
        case .iptv:
            return Color(red: 0.38, green: 0.34, blue: 0.88)
        case .vod:
            return Color(red: 0.18, green: 0.52, blue: 0.92)
        }
    }
}



func tvCompactMetadataLine(
    mediaType: String,
    year: Int?,
    runtimeText: String?,
    rating: String?,
    childCount: Int?,
    episodeCount: Int? = nil
) -> String? {
    var tokens: [String] = []
    if let typeTitle = tvConcreteMediaKindTitle(from: mediaType) {
        tokens.append(typeTitle)
    }
    if let year, year > 0 {
        tokens.append(String(year))
    }
    if let runtimeText, !runtimeText.isEmpty {
        tokens.append(runtimeText)
    }
    if let rating, !rating.isEmpty {
        tokens.append(rating)
    }
    if let childCount, childCount > 0 {
        tokens.append(tvCompactChildCountText(mediaType: mediaType, count: childCount, episodeCount: episodeCount))
    }
    return tokens.isEmpty ? nil : tokens.joined(separator: " • ")
}



func tvMediaLibraryDisplayMetadataLine(
    for node: TVMediaLibraryNode,
    includesType: Bool = false
) -> String {
    var tokens: [String] = []
    let mediaKindTitle = tvConcreteMediaKindTitle(from: node.rawItemType)
        ?? tvConcreteMediaKindTitle(from: node.libraryCollectionType)

    if includesType, let mediaKindTitle {
        tokens.append(mediaKindTitle)
    }

    if let dateText = tvMediaLibraryDisplayDateText(for: node) {
        tokens.append(dateText)
    }

    if let resolutionText = tvMediaLibraryResolutionText(for: node) {
        tokens.append(resolutionText)
    }

    if let collectionCount = tvMediaLibraryCollectionCountText(for: node) {
        tokens.append(collectionCount)
    }

    if includesType, let rating = tvTrimmedText(node.rating) {
        tokens.append(rating)
    }

    if tokens.isEmpty, let mediaKindTitle {
        tokens.append(mediaKindTitle)
    }

    if tokens.isEmpty,
       let metadataLine = tvMediaLibrarySanitizedMetadataLine(
        from: node.metadataLine,
        includesType: includesType
       ) {
        tokens.append(metadataLine)
    }

    return tokens.joined(separator: " • ")
}



func tvMediaLibraryDisplayDateText(for node: TVMediaLibraryNode) -> String? {
    if let year = node.year, year > 0 {
        return String(year)
    }
    return tvMediaLibraryYearText(from: node.premiereDate)
}



func tvMediaLibraryReleaseDateText(for node: TVMediaLibraryNode) -> String? {
    if let premiereDate = tvMediaLibraryFormattedDateText(from: node.premiereDate) {
        return premiereDate
    }
    return tvMediaLibraryDisplayDateText(for: node)
}



func tvMediaLibraryResolutionText(for node: TVMediaLibraryNode) -> String? {
    tvMediaLibraryResolutionText(width: node.videoWidth, height: node.videoHeight)
}



func tvMediaLibraryResolutionText(width: Int?, height: Int?) -> String? {
    guard let width, let height, width > 0, height > 0 else { return nil }
    let longSide = max(width, height)
    if longSide >= 3800 { return "4K" }
    if longSide >= 1900 { return "1080P" }
    if longSide >= 1200 { return "720P" }
    return nil
}



func tvMediaLibraryYearText(from rawDate: String?) -> String? {
    guard let rawDate = tvTrimmedText(rawDate) else { return nil }
    let yearText = String(rawDate.prefix(4))
    guard yearText.count == 4, Int(yearText) != nil else { return nil }
    return yearText
}



func tvMediaLibraryFormattedDateText(from rawDate: String?) -> String? {
    guard let rawDate = tvTrimmedText(rawDate) else { return nil }
    let prefix = String(rawDate.prefix(10))
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(secondsFromGMT: 0)
    parser.dateFormat = "yyyy-MM-dd"
    guard let date = parser.date(from: prefix) else {
        return tvMediaLibraryYearText(from: rawDate)
    }

    let formatter = DateFormatter()
    formatter.locale = .current
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
}



func tvMediaLibrarySanitizedMetadataLine(
    from metadataLine: String?,
    includesType: Bool
) -> String? {
    guard let metadataLine = tvTrimmedText(metadataLine) else { return nil }
    let tokens = metadataLine
        .components(separatedBy: " • ")
        .compactMap { tvTrimmedText($0) }
        .filter { includesType || !tvMediaLibraryMetadataTokenIsMediaKind($0) }
        .filter { !tvMediaLibraryMetadataTokenIsGenericFileKind($0) }
    return tokens.isEmpty ? nil : tokens.joined(separator: " • ")
}



func tvMediaLibraryMetadataTokenIsMediaKind(_ token: String) -> Bool {
    let mediaKindTitles = [
        platformShellString("Platform Shell TV Detail Movie"),
        platformShellString("Platform Shell TV Detail Series"),
        platformShellString("Platform Shell TV Detail Season"),
        platformShellString("Platform Shell TV Detail Episode")
    ]
    return mediaKindTitles.contains(token)
}



func tvMediaLibraryMetadataTokenIsGenericFileKind(_ token: String) -> Bool {
    let genericTitles = [
        platformShellString("Video"),
        platformShellString("Documents"),
        tvMediaTypeTitle(for: .video),
        tvMediaTypeTitle(for: .document),
        tvMediaTypeTitle(for: .unknown)
    ]
    return genericTitles.contains(token)
}



func tvMediaLibraryCollectionCountText(for node: TVMediaLibraryNode) -> String? {
    guard let childCount = node.childCount, childCount > 0 else { return nil }
    let rawType = tvTrimmedText(node.rawItemType)?.lowercased()
        ?? tvTrimmedText(node.libraryCollectionType)?.lowercased()
        ?? ""

    switch rawType {
    case "series", "show":
        return tvCompactChildCountText(mediaType: "series", count: childCount, episodeCount: node.episodeCount)
    case "season":
        return tvCompactChildCountText(mediaType: "season", count: childCount)
    default:
        return nil
    }
}



func tvConcreteMediaKindTitle(from mediaType: String?) -> String? {
    guard let mediaType = tvTrimmedText(mediaType) else { return nil }
    switch mediaType.lowercased() {
    case "movie", "movies":
        return platformShellString("Platform Shell TV Detail Movie")
    case "series", "show", "shows", "tvshow", "tvshows", "seriesfolder":
        return platformShellString("Platform Shell TV Detail Series")
    case "season":
        return platformShellString("Platform Shell TV Detail Season")
    case "episode":
        return platformShellString("Platform Shell TV Detail Episode")
    case "audio", "song", "track":
        return platformShellString("Audio")
    case "photo", "image", "photos":
        return platformShellString("Photos")
    default:
        return nil
    }
}



func tvCompactTypeTitle(from mediaType: String) -> String {
    switch mediaType.lowercased() {
    case "movie":
        return platformShellString("Platform Shell TV Detail Movie")
    case "series", "show":
        return platformShellString("Platform Shell TV Detail Series")
    case "season":
        return platformShellString("Platform Shell TV Detail Season")
    case "episode":
        return platformShellString("Platform Shell TV Detail Episode")
    case "video":
        return platformShellString("Video")
    case "audio", "song", "track":
        return platformShellString("Audio")
    case "musicartist", "artist", "musicalbum", "album":
        return platformShellString("Audio")
    case "photo", "image":
        return platformShellString("Photos")
    case "folder", "collectionfolder", "directory":
        return platformShellString("Folder")
    default:
        return tvMediaTypeTitle(for: tvFileType(from: mediaType))
    }
}



func tvCompactChildCountText(mediaType: String, count: Int, episodeCount: Int? = nil) -> String {
    let lower = mediaType.lowercased()
    switch lower {
    case "series", "show":
        let singular = platformShellString("Platform Shell TV Detail Season")
        let isChinese = singular == "季"
        if isChinese {
            var text = "\(count) 季"
            if let ep = episodeCount, ep > 0 {
                text += " \(ep) 集"
            }
            return text
        } else {
            var text = "\(count)S"
            if let ep = episodeCount, ep > 0 {
                text += " \(ep)E"
            }
            return text
        }
    case "season":
        let key = count == 1 ? "Platform Shell TV Detail Episode" : "Platform Shell TV Detail Episodes"
        return "\(count) \(platformShellString(key))"
    default:
        return "\(count)"
    }
}



func tvDurationText(ticks: Int64?) -> String? {
    guard let ticks, ticks > 0 else { return nil }
    let totalSeconds = ticks / 10_000_000
    return tvDurationText(seconds: totalSeconds)
}



func tvDurationText(milliseconds: Int64?) -> String? {
    guard let milliseconds, milliseconds > 0 else { return nil }
    return tvDurationText(seconds: milliseconds / 1000)
}



func tvDurationText(seconds: Int64) -> String? {
    guard seconds > 0 else { return nil }
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 {
        return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h"
    }
    if minutes > 0 {
        return "\(minutes)m"
    }
    return "\(seconds)s"
}



func tvCompactRatingString(_ value: Any?) -> String? {
    if let string = value as? String {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    if let number = value as? NSNumber {
        return String(format: "%.1f", number.doubleValue)
    }
    return nil
}



func tvByteCountString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
}



func tvDownloadTotalBytes(for job: DownloadJobGroup) -> Int64 {
    job.tasks.reduce(0) { $0 + max(max($1.bytesTotal, $1.bytesDownloaded), 0) }
}



func tvDownloadDownloadedBytes(for job: DownloadJobGroup) -> Int64 {
    job.tasks.reduce(0) { $0 + max($1.bytesDownloaded, 0) }
}



func tvDownloadTransferText(for job: DownloadJobGroup) -> String {
    let totalBytes = tvDownloadTotalBytes(for: job)
    let downloadedBytes = tvDownloadDownloadedBytes(for: job)

    if totalBytes > 0 {
        if job.bucket == .completed {
            return tvByteCountString(totalBytes)
        }
        return "\(tvByteCountString(downloadedBytes)) / \(tvByteCountString(totalBytes))"
    }
    return tvByteCountString(downloadedBytes)
}



func tvDownloadSpeedBytesPerSec(for job: DownloadJobGroup) -> Double {
    job.speedBytesPerSec
}



func tvDownloadSpeedText(for job: DownloadJobGroup) -> String? {
    guard job.bucket == .active else { return nil }
    let speedBytesPerSec = tvDownloadSpeedBytesPerSec(for: job)
    guard speedBytesPerSec > 1 else { return nil }
    return "\(tvByteCountString(Int64(speedBytesPerSec)))/s"
}



func tvDownloadEstimatedRemainingText(for job: DownloadJobGroup) -> String? {
    guard job.bucket == .active else { return nil }
    let remainingBytes = max(Int64(0), tvDownloadTotalBytes(for: job) - tvDownloadDownloadedBytes(for: job))
    guard remainingBytes > 0 else { return nil }

    let speedBytesPerSec = tvDownloadSpeedBytesPerSec(for: job)
    guard speedBytesPerSec > 1 else { return nil }

    let seconds = Int((Double(remainingBytes) / speedBytesPerSec).rounded(.up))
    guard seconds > 0 else { return nil }
    return String(format: platformShellString("ETA %@"), tvDownloadDurationText(seconds: seconds))
}



func tvDownloadFailureText(for job: DownloadJobGroup) -> String? {
    guard job.bucket == .failed else { return nil }
    let message = job.tasks
        .first { $0.status == .failed || $0.status == .canceled }?
        .errorMessage?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let message, !message.isEmpty else { return nil }
    return message
}



func tvDownloadDurationText(seconds: Int) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainingSeconds = seconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
    }
    return String(format: "%02d:%02d", minutes, remainingSeconds)
}



func tvSettingsRootStorageValue(
    downloadedStorageSummary: DownloadCenterService.DownloadedStorageSummary,
    imageCacheSize: Int64
) -> String {
    let imageCacheBytes = max(imageCacheSize, 0)
    let downloadedBytes = max(downloadedStorageSummary.totalBytes, 0)
    let fileCount = String(format: platformShellString("%d files"), downloadedStorageSummary.fileCount)

    if imageCacheBytes > 0, downloadedBytes == 0 {
        return "\(tvByteCountString(imageCacheBytes)) · \(platformShellString("Image Cache"))"
    }

    if imageCacheBytes > 0 {
        return "\(tvByteCountString(downloadedBytes + imageCacheBytes)) · \(fileCount) + \(platformShellString("Image Cache"))"
    }

    return "\(tvByteCountString(downloadedBytes)) · \(fileCount)"
}



func tvTimestamp(_ date: Date) -> String {
    DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
}



func tvCurrentAppLocale() -> Locale {
    AppRelativeDateTimeFormatter.currentAppLocale()
}



func tvDownloadDateString(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = tvCurrentAppLocale()
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
}
#endif
