#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift



struct TVMediaLibraryPerson: Identifiable {
    let id: String
    let name: String
    let role: String?
    let type: String  // Actor, Director, Writer, etc.
    let imageURL: URL?
}



struct TVMediaLibraryPersonDetails {
    let biography: String?
    let birthDate: String?
    let deathDate: String?
    let placeOfBirth: String?
    let externalIDs: String?

    var detailRows: [(key: String, value: String)] {
        var rows: [(key: String, value: String)] = []
        if let birthDate {
            rows.append(("Platform Shell TV Detail Born", birthDate))
        }
        if let deathDate {
            rows.append(("Platform Shell TV Detail Died", deathDate))
        }
        if let placeOfBirth {
            rows.append(("Platform Shell TV Detail Place of Birth", placeOfBirth))
        }
        if let externalIDs {
            rows.append(("Platform Shell TV Detail External IDs", externalIDs))
        }
        return rows
    }

    var hasContent: Bool {
        biography != nil || !detailRows.isEmpty
    }
}



struct TVMediaLibraryNode: Identifiable {
    let id: String
    let name: String
    let type: VideoFile.FileType
    let isFolder: Bool
    let remotePath: String?
    let posterURL: URL?
    let backdropURL: URL?
    var logoURL: URL?
    let summary: String?
    let metadataLine: String?
    let genres: [String]
    let year: Int?
    let premiereDate: String?
    let runtimeTicks: Int64?
    let rating: String?
    let communityRating: Double?
    let childCount: Int?
    let episodeCount: Int?
    let people: [TVMediaLibraryPerson]
    let rawItemType: String
    let seriesId: String?
    let seasonId: String?
    let seriesName: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    var isFavorite: Bool?
    var isPlayed: Bool?
    var playbackPositionSeconds: TimeInterval?
    var playbackProgress: Double?
    let videoWidth: Int?
    let videoHeight: Int?
    let mediaSize: Int64?
    let mediaContainer: String?
    let downloadRemotePath: String?
    let isLibraryRoot: Bool
    let libraryCollectionType: String?

    /// True when the node represents a multi-season container (Series/Show)
    var isSeries: Bool {
        let lower = rawItemType.lowercased()
        return lower == "series" || lower == "show"
    }

    var itemCount: Int? {
        childCount
    }

    var jellyfinLibraryType: JellyfinLibrary.LibraryType {
        let lower = (libraryCollectionType ?? rawItemType).lowercased()
        switch lower {
        case "movies", "movie": return .movies
        case "tvshows", "series", "show": return .tvShows
        case "music", "musicalbum", "audio": return .music
        case "homevideos", "photos", "photo": return .photos
        case "boxsets", "collections", "boxset": return .collections
        case "playlists": return .playlists
        default: return .mixed
        }
    }

    /// True when the node represents a single season
    var isSeason: Bool {
        rawItemType.lowercased() == "season"
    }

    /// True when this library node should be shown in the "My Media" overview shelf
    var isUserVisibleLibrary: Bool {
        let lowerCollection = libraryCollectionType?.lowercased() ?? ""
        let lowerRaw = rawItemType.lowercased()
        if lowerCollection == "livetv" || lowerRaw == "livetv" {
            return false
        }
        return true
    }

    /// True when this library node should be expanded as an individual shelf section on the home page
    var showsHomeShelfSection: Bool {
        guard isUserVisibleLibrary else { return false }
        let lowerCollection = libraryCollectionType?.lowercased() ?? ""
        let lowerRaw = rawItemType.lowercased()
        if lowerCollection == "boxsets" || lowerCollection == "playlists" || lowerRaw == "boxset" || lowerRaw == "playlist" {
            return false
        }
        return true
    }

    init(
        id: String,
        name: String,
        type: VideoFile.FileType,
        isFolder: Bool,
        remotePath: String?,
        posterURL: URL?,
        summary: String?,
        metadataLine: String?,
        isLibraryRoot: Bool,
        libraryCollectionType: String?,
        backdropURL: URL? = nil,
        logoURL: URL? = nil,
        genres: [String] = [],
        year: Int? = nil,
        premiereDate: String? = nil,
        runtimeTicks: Int64? = nil,
        rating: String? = nil,
        communityRating: Double? = nil,
        childCount: Int? = nil,
        episodeCount: Int? = nil,
        people: [TVMediaLibraryPerson] = [],
        rawItemType: String = "",
        seriesId: String? = nil,
        seasonId: String? = nil,
        seriesName: String? = nil,
        indexNumber: Int? = nil,
        parentIndexNumber: Int? = nil,
        isFavorite: Bool? = nil,
        isPlayed: Bool? = nil,
        playbackPositionSeconds: TimeInterval? = nil,
        playbackProgress: Double? = nil,
        videoWidth: Int? = nil,
        videoHeight: Int? = nil,
        mediaSize: Int64? = nil,
        mediaContainer: String? = nil,
        downloadRemotePath: String? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isFolder = isFolder
        self.remotePath = remotePath
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.logoURL = logoURL
        self.summary = summary
        self.metadataLine = metadataLine
        self.genres = genres
        self.year = year
        self.premiereDate = premiereDate
        self.runtimeTicks = runtimeTicks
        self.rating = rating
        self.communityRating = communityRating
        self.childCount = childCount
        self.episodeCount = episodeCount
        self.people = people
        self.rawItemType = rawItemType
        self.seriesId = seriesId
        self.seasonId = seasonId
        self.seriesName = seriesName
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.isFavorite = isFavorite
        self.isPlayed = isPlayed
        self.playbackPositionSeconds = playbackPositionSeconds
        self.playbackProgress = playbackProgress
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.mediaSize = mediaSize
        self.mediaContainer = mediaContainer
        self.downloadRemotePath = downloadRemotePath
        self.isLibraryRoot = isLibraryRoot
        self.libraryCollectionType = libraryCollectionType
    }
}




struct TVMediaLibraryFeaturedItem: Identifiable {
    let id: String
    let node: TVMediaLibraryNode
    let progress: Double?
    let lastPlayedAt: Date?
    let sourceTitle: String?
    let sourceSystemImageName: String?

    init(
        node: TVMediaLibraryNode,
        progress: Double?,
        lastPlayedAt: Date? = nil,
        sourceTitle: String? = nil,
        sourceSystemImageName: String? = nil
    ) {
        self.id = node.id
        self.node = node
        self.progress = progress
        self.lastPlayedAt = lastPlayedAt
        self.sourceTitle = sourceTitle
        self.sourceSystemImageName = sourceSystemImageName
    }
}



struct TVTransientAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}



let tvMediaLibraryContinueWatchingLimit = 12
let tvMediaLibrarySpotlightFallbackLimit = 6
let tvMediaLibraryShelfPreviewFetchLimit = 24
let tvMediaLibraryShelfPreviewDisplayLimit = 10

enum TVMediaLibraryLayout {
    static let posterWidth: CGFloat = 240
    static let posterHeight: CGFloat = 360
    static let posterCornerRadius: CGFloat = 14
    static let posterTextSpacing: CGFloat = 10
    static let posterTitleHeight: CGFloat = 52
    static let posterSubtitleHeight: CGFloat = 22
    static let posterTextHeight: CGFloat = 78
    static let posterCardHeight: CGFloat = posterHeight + posterTextSpacing + posterTextHeight
    static let posterGridColumnMinimum: CGFloat = 240
    static let posterGridColumnMaximum: CGFloat = 260
    static let posterGridColumnSpacing: CGFloat = 36
    static let posterGridRowSpacing: CGFloat = 38
    static let posterGridColumnsPerRow = 6
    static let posterFocusScale: CGFloat = 1.042

    static let featuredWidth: CGFloat = 380
    static let featuredHeight: CGFloat = 214
    static let featuredTextHeight: CGFloat = 78
    static let featuredCardHeight: CGFloat = featuredHeight + posterTextSpacing + featuredTextHeight
}



struct TVMediaLibraryBrowserView: View {
    let server: ServerConfig
    let title: String
    let parentNode: TVMediaLibraryNode?
    let targetItemIdToResolve: String?
    let targetFallbackFile: VideoFile?

    @Environment(\.tvBrowsingNavigation) private var browsingNavigation
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject private var networkService = AppNetworkService.shared
    private let playbackCoordinator = TVPlaybackCoordinator.shared
    @State private var nodes: [TVMediaLibraryNode] = []
    @State private var continueWatchingItems: [TVMediaLibraryFeaturedItem] = []
    @State private var fallbackSpotlightItems: [TVMediaLibraryFeaturedItem] = []
    @State private var favoriteNodes: [TVMediaLibraryNode] = []
    @State private var continueWatchingTask: Task<Void, Never>?
    @State private var fallbackSpotlightTask: Task<Void, Never>?
    @State private var favoritesTask: Task<Void, Never>?
    @State private var didAttemptLoadContinueWatching = false
    @State private var didAttemptLoadFallbackSpotlight = false
    @State private var didAttemptLoadFavorites = false
    @State private var spotlightIndex = 0
    @State private var spotlightCarouselTask: Task<Void, Never>?
    @State private var isSpotlightHeroFocused = false
    @State private var spotlightNavigationNode: TVMediaLibraryNode?
    @State private var isSpotlightNavigationActive = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isTestingConnection = false
    @State private var connectionAlert: TVTransientAlert?
    @State private var testTask: Task<Void, Never>?
    @State private var isTargetResolutionActive = false
    @State private var didActivateTargetResolution = false
    @State private var sortField: TVMediaLibrarySortField = .name
    @State private var sortOrder: TVMediaLibrarySortOrder = .ascending
    @State private var selectedGenre: String? = nil
    @AppStorage("tvMediaLibraryDisplayMode") private var displayModeRaw: String = LibraryDisplayMode.poster.rawValue
    @AppStorage("tvMediaLibraryViewMode") private var isGridLayout = true
    @State private var focusedHeaderAction: TVHeaderActionFocus?

    private var myMediaNodes: [TVMediaLibraryNode] {
        nodes.filter { $0.isUserVisibleLibrary }
    }

    private var shelfNodes: [TVMediaLibraryNode] {
        nodes.filter { $0.showsHomeShelfSection }
    }

    private var availableGenres: [String] {
        var set = Set<String>()
        var list: [String] = []
        for node in nodes {
            for g in node.genres {
                let trimmed = g.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && set.insert(trimmed).inserted {
                    list.append(trimmed)
                }
            }
        }
        return list.sorted()
    }

    private var displayedNodes: [TVMediaLibraryNode] {
        if let selectedGenre = selectedGenre, !selectedGenre.isEmpty {
            return nodes.filter { $0.genres.contains(selectedGenre) }
        }
        return nodes
    }

    private var displayMode: LibraryDisplayMode {
        get {
            if let mode = LibraryDisplayMode(rawValue: displayModeRaw) {
                return mode
            }
            return isGridLayout ? .poster : .list
        }
        nonmutating set {
            displayModeRaw = newValue.rawValue
            isGridLayout = (newValue != .list)
        }
    }

    init(
        server: ServerConfig,
        title: String,
        parentNode: TVMediaLibraryNode?,
        targetItemIdToResolve: String? = nil,
        targetFallbackFile: VideoFile? = nil
    ) {
        self.server = server
        self.title = title
        self.parentNode = parentNode
        self.targetItemIdToResolve = targetItemIdToResolve
        self.targetFallbackFile = targetFallbackFile
    }

    private var isRootBrowser: Bool {
        parentNode == nil
    }

    private var currentServer: ServerConfig {
        networkService.servers.first(where: { $0.id == server.id }) ?? server
    }

    private var currentTitle: String {
        isRootBrowser ? currentServer.name : title
    }

    private var rootSpotlightItems: [TVMediaLibraryFeaturedItem] {
        let candidates = currentServer.type == .jellyfin ? fallbackSpotlightItems
            : (continueWatchingItems.isEmpty ? fallbackSpotlightItems : continueWatchingItems)
        return MediaHomeCarouselSelection.unique(candidates, limit: candidates.count,
            identity: { MediaHomeCarouselSelection.identity(itemID: $0.node.id, seriesID: $0.node.seriesId, itemType: $0.node.rawItemType) },
            lastPlayedAt: { $0.lastPlayedAt })
    }

    private var spotlightItem: TVMediaLibraryFeaturedItem? {
        guard isRootBrowser, !rootSpotlightItems.isEmpty else { return nil }
        let safeIndex = min(max(spotlightIndex, 0), rootSpotlightItems.count - 1)
        return rootSpotlightItems[safeIndex]
    }

    private var continueWatchingShelfItems: [TVMediaLibraryFeaturedItem] {
        isRootBrowser ? continueWatchingItems : []
    }

    private var usesRootSpotlightHero: Bool {
        isRootBrowser && spotlightItem != nil
    }

    private var supportsSortControls: Bool {
        guard parentNode?.isLibraryRoot == true else { return false }
        switch currentServer.type {
        case .jellyfin, .emby, .plex:
            return true
        default:
            return false
        }
    }

    private var sortPreference: TVMediaLibrarySortPreference? {
        guard supportsSortControls else { return nil }
        return TVMediaLibrarySortPreference(field: sortField, order: sortOrder)
    }

    var body: some View {
        TVPageScrollView(
            title: currentTitle,
            subtitle: nil,
            handlesExitCommand: true,
            showsTitle: false,
            topPadding: usesRootSpotlightHero ? 0 : nil
        ) {
            targetResolutionLink
            spotlightSelectionLink

            if usesRootSpotlightHero, let spotlightItem {
                ZStack(alignment: .top) {
                    continueWatchingSpotlightEntry(for: spotlightItem)

                    if tvServerSupportsMediaLibrary(currentServer) {
                        TVMediaLibraryTopBar(
                            server: currentServer,
                            title: currentTitle,
                            scopeNode: parentNode,
                            onRefresh: { refreshAll() },
                            onClose: dismissToServerList
                        )
                    }
                }
            } else if tvServerSupportsMediaLibrary(currentServer) {
                if isRootBrowser {
                    TVMediaLibraryTopBar(
                        server: currentServer,
                        title: currentTitle,
                        scopeNode: parentNode,
                        onRefresh: { refreshAll() },
                        onClose: dismissToServerList
                    )
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        mediaLibraryActionsToolbar
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tvFocusSectionIfAvailable()
                }
            }

            if isLoading {
                TVInfoPanel(
                    title: platformShellString("Platform Shell TV Loading"),
                    message: currentServer.name,
                    systemImageName: "hourglass"
                )
            }

            if let errorMessage {
                TVInfoPanel(
                    title: platformShellString("Connection Failed"),
                    message: errorMessage,
                    systemImageName: "exclamationmark.triangle.fill",
                    kind: .error,
                    tintColor: .red
                )

                if isRootBrowser {
                    TVCompactActionsRow {
                        Button(action: loadNodes) {
                            TVCompactActionButton(
                                title: platformShellString("Retry"),
                                systemImageName: isLoading ? "hourglass" : "arrow.clockwise"
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .disabled(isLoading)

                        TVNavigationLink(destination: TVServerEditorView(existingServer: currentServer, prefilledServer: nil)) {
                            TVCompactActionButton(
                                title: platformShellString("Edit Server"),
                                systemImageName: "slider.horizontal.3"
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())

                        Button(action: testConnection) {
                            TVCompactActionButton(
                                title: platformShellString("Test Connection"),
                                systemImageName: isTestingConnection ? "hourglass" : "network"
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .disabled(isLoading || isTestingConnection)

                        Button(action: dismissToServerList) {
                            TVCompactActionButton(
                                title: platformShellString("Saved Servers"),
                                systemImageName: "server.rack"
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())
                    }
                } else {
                    Button(action: loadNodes) {
                        TVMaintenanceButtonLabel(
                            title: platformShellString("Retry"),
                            systemImageName: isLoading ? "hourglass" : "arrow.clockwise"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                    .disabled(isLoading)
                }
            }

            if !usesRootSpotlightHero, let spotlightItem {
                continueWatchingSpotlightEntry(for: spotlightItem)
            }

            if !continueWatchingShelfItems.isEmpty {
                TVShelfSection(
                    title: platformShellString("Continue Watching"),
                    subtitle: nil,
                    systemImage: "clock.fill"
                ) {
                    ForEach(continueWatchingShelfItems) { item in
                        continueWatchingShelfEntry(for: item)
                    }
                }
            }

            if isRootBrowser && !favoriteNodes.isEmpty {
                TVShelfSection(
                    title: platformShellString("Favorites"),
                    subtitle: nil,
                    systemImage: "heart.fill"
                ) {
                    ForEach(favoriteNodes) { favNode in
                        TVNavigationLink(destination: tvDestination(for: favNode)) {
                            TVMediaLibraryPosterCard(server: currentServer, node: favNode)
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                    }
                }
            }

            if isRootBrowser && !myMediaNodes.isEmpty {
                TVShelfSection(
                    title: platformShellString("My Media"),
                    subtitle: nil,
                    systemImage: "square.grid.2x2.fill"
                ) {
                    ForEach(myMediaNodes) { node in
                        TVNavigationLink(destination: TVMediaLibraryBrowserView(server: currentServer, title: node.name, parentNode: node)) {
                            TVMediaLibraryCategoryCard(server: currentServer, node: node)
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                    }
                }
            }

            if !nodes.isEmpty {
                if isRootBrowser {
                    LazyVStack(alignment: .leading, spacing: 30) {
                        ForEach(shelfNodes) { node in
                            TVMediaLibraryRootShelfSection(server: currentServer, node: node)
                        }
                    }
                } else {
                    if !availableGenres.isEmpty {
                        genreTabsShelf
                            .padding(.bottom, 20)
                    }

                    switch displayMode {
                    case .poster:
                        TVMediaLibraryPosterGrid(items: displayedNodes) { node in
                            TVNavigationLink(destination: tvDestination(for: node)) {
                                TVMediaLibraryPosterCard(server: currentServer, node: node)
                            }
                            .buttonStyle(TVPlainButtonStyle())
                            .tvDisableSystemFocusEffect()
                        }
                    case .thumb:
                        TVMediaLibraryThumbGrid(items: displayedNodes) { node in
                            TVNavigationLink(destination: tvDestination(for: node)) {
                                TVMediaLibraryThumbCard(server: currentServer, node: node)
                            }
                            .buttonStyle(TVPlainButtonStyle())
                            .tvDisableSystemFocusEffect()
                        }
                    case .list:
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(displayedNodes) { node in
                                TVNavigationLink(destination: tvDestination(for: node)) {
                                    TVMediaLibraryListRow(server: currentServer, node: node)
                                }
                                .buttonStyle(TVPlainButtonStyle())
                                .tvDisableSystemFocusEffect()
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                        }
                        .tvFocusSectionIfAvailable()
                    }

                    if !displayedNodes.isEmpty && !isLoading {
                        let total = parentNode?.childCount ?? displayedNodes.count
                        if total > 0 {
                            Text(MediaCountFormatter.formatTotal(count: total, libraryType: parentNode?.jellyfinLibraryType ?? .mixed))
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 32)
                        }
                    }
                }
            } else if !isLoading && errorMessage == nil && continueWatchingItems.isEmpty {
                TVEmptyStateCard(
                    title: isRootBrowser
                        ? currentServer.name
                        : platformShellString("Platform Shell TV Folder Empty Title"),
                    message: isRootBrowser
                        ? platformShellString("Platform Shell TV Library Server Body")
                        : platformShellString("Platform Shell TV Folder Empty Body"),
                    systemImageName: isRootBrowser ? currentServer.type.systemIconName : "folder"
                )
            }
        }
        .navigationTitle(Text(currentTitle))
        .onAppear {
            loadSavedSortPreference()
            if nodes.isEmpty && !isLoading {
                loadNodes()
            }
            loadContinueWatchingIfNeeded()
            loadFavoritesIfNeeded()
            loadFallbackSpotlightIfNeeded()
            startSpotlightCarouselIfNeeded()
            activateTargetResolutionIfNeeded()
        }
        .onDisappear {
            continueWatchingTask?.cancel()
            continueWatchingTask = nil
            fallbackSpotlightTask?.cancel()
            fallbackSpotlightTask = nil
            favoritesTask?.cancel()
            favoritesTask = nil
            spotlightCarouselTask?.cancel()
            spotlightCarouselTask = nil
            isSpotlightHeroFocused = false
            testTask?.cancel()
            testTask = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteFavoriteStateDidChange)) { _ in
            if isRootBrowser {
                refreshFavorites()
            }
        }
        .onChange(of: isSpotlightNavigationActive) { isActive in
            if !isActive {
                spotlightNavigationNode = nil
            }
        }
        .alert(item: $connectionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(platformShellString("OK")))
            )
        }
    }

    private var genreTabsShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                TVCategoryTabButton(
                    title: platformShellString("All"),
                    count: nodes.count,
                    isSelected: selectedGenre == nil,
                    iconName: nil
                ) {
                    selectedGenre = nil
                }

                ForEach(availableGenres, id: \.self) { genre in
                    let count = nodes.filter { $0.genres.contains(genre) }.count
                    TVCategoryTabButton(
                        title: genre,
                        count: count,
                        isSelected: selectedGenre == genre,
                        iconName: nil
                    ) {
                        selectedGenre = genre
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .tvFocusSectionIfAvailable()
    }

    @ViewBuilder
    func tvDestination(for node: TVMediaLibraryNode) -> some View {
        tvMediaLibraryDestination(server: currentServer, node: node)
    }

    private var mediaLibraryActionsToolbar: some View {
        ZStack {
            HStack(alignment: .center, spacing: 18) {
                TVServerIdentityPill(server: currentServer)
                Spacer(minLength: 20)
                HStack(spacing: 16) {
                TVHeaderActionDescriptionText(
                    text: focusedHeaderAction?.title,
                    width: 280,
                    isDestructive: false,
                    alignment: .trailing
                )

                // 1st: Search
                TVNavigationLink(
                    destination: TVMediaLibrarySearchView(
                        server: currentServer,
                        title: currentTitle,
                        scopeNode: parentNode
                    )
                ) {
                    TVTopChromeIconButton(
                        title: platformShellString("Search"),
                        systemImageName: "magnifyingglass",
                        diameter: 66,
                        onFocusChange: { title, isFocused in
                            updateFocus(id: "search", title: title, isFocused: isFocused)
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()

                // 2nd: Layout Toggle
                Button(action: {
                    switch displayMode {
                    case .poster: displayMode = .thumb
                    case .thumb: displayMode = .list
                    case .list: displayMode = .poster
                    }
                }) {
                    TVTopChromeIconButton(
                        title: platformShellString(displayMode.localizedTitleKey),
                        systemImageName: displayMode.iconName,
                        diameter: 66,
                        onFocusChange: { title, isFocused in
                            updateFocus(id: "layout", title: title, isFocused: isFocused)
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()

                // 3rd: Sort
                if supportsSortControls {
                    TVNavigationLink(
                        destination: TVMediaLibrarySortView(
                            sortField: $sortField,
                            sortOrder: $sortOrder,
                            onPreferenceChanged: persistSortPreferenceAndReload
                        )
                    ) {
                        TVTopChromeIconButton(
                            title: platformShellString("Sort"),
                            systemImageName: "line.3.horizontal.decrease.circle",
                            diameter: 66,
                            onFocusChange: { title, isFocused in
                                updateFocus(id: "sort", title: title, isFocused: isFocused)
                            }
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }

                // 4th: Refresh
                Button(action: {
                    loadNodes()
                }) {
                    TVTopChromeIconButton(
                        title: platformShellString("Refresh"),
                        systemImageName: "arrow.clockwise",
                        diameter: 66,
                        onFocusChange: { title, isFocused in
                            updateFocus(id: "refresh", title: title, isFocused: isFocused)
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()

                // 5th: Home
                Button(action: returnToLibraryHome) {
                    TVTopChromeIconButton(
                        title: platformShellString("Home"),
                        systemImageName: "house",
                        diameter: 66,
                        onFocusChange: { title, isFocused in
                            updateFocus(id: "home", title: title, isFocused: isFocused)
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
            .tvFocusSectionIfAvailable()
        } // Close HStack(alignment: .center, spacing: 18)
            
            VStack(alignment: .center, spacing: 5) {
                Text(currentTitle)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvFocusSectionIfAvailable()
    }

    private func updateFocus(id: String, title: String, isFocused: Bool) {
        if isFocused {
            focusedHeaderAction = TVHeaderActionFocus(id: id, title: title, isDestructive: false)
        } else if focusedHeaderAction?.id == id {
            focusedHeaderAction = nil
        }
    }

    @ViewBuilder
    private var targetResolutionLink: some View {
        if isRootBrowser,
           let itemId = tvTrimmedText(targetItemIdToResolve),
           let fallbackFile = targetFallbackFile {
            NavigationLink(
                destination: TVMediaLibraryResolvedItemView(
                    server: currentServer,
                    itemId: itemId,
                    fallbackFile: fallbackFile
                ),
                isActive: $isTargetResolutionActive
            ) {
                EmptyView()
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var spotlightSelectionLink: some View {
        if let node = spotlightNavigationNode {
            NavigationLink(
                destination: tvDestination(for: node),
                isActive: $isSpotlightNavigationActive
            ) {
                EmptyView()
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        }
    }

    private func activateTargetResolutionIfNeeded() {
        guard isRootBrowser,
              !didActivateTargetResolution,
              tvTrimmedText(targetItemIdToResolve) != nil,
              targetFallbackFile != nil else {
            return
        }

        didActivateTargetResolution = true
        DispatchQueue.main.async {
            isTargetResolutionActive = true
        }
    }

    @ViewBuilder
    private func continueWatchingSpotlightEntry(for item: TVMediaLibraryFeaturedItem) -> some View {
        TVFullBleedHeroRow(height: TVMediaLibrarySpotlightHero.heroHeight) {
            ZStack(alignment: .bottomLeading) {
                TVMediaLibrarySpotlightHero(
                    server: currentServer,
                    item: item
                )
                .zIndex(0)

                TVSpotlightCarouselFocusHost(
                    isFocused: $isSpotlightHeroFocused,
                    onMoveLeft: { moveSpotlight(by: -1) },
                    onMoveRight: { moveSpotlight(by: 1) },
                    onSelect: { activateSpotlightPrimaryAction(for: item) }
                )
                .frame(maxWidth: .infinity)
                .frame(height: TVMediaLibrarySpotlightHero.focusHostHeight)
                .padding(.top, TVMediaLibrarySpotlightHero.focusHostTopInset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .zIndex(1)

                if let playableFile = tvPlayableLibraryFile(server: currentServer, node: item.node) {
                    Button(action: { playbackCoordinator.play(file: playableFile) }) {
                        TVSpotlightActionButtonLabel(
                            actionTitle: platformShellString(continueWatchingItems.isEmpty ? "Play" : "Continue")
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                    .padding(.leading, TVMediaLibrarySpotlightHero.contentHorizontalPadding)
                    .padding(.bottom, 70)
                    .zIndex(2)
                } else {
                    TVNavigationLink(destination: tvDestination(for: item.node)) {
                        TVSpotlightActionButtonLabel(
                            actionTitle: platformShellString("Open")
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                    .padding(.leading, TVMediaLibrarySpotlightHero.contentHorizontalPadding)
                    .padding(.bottom, 70)
                    .zIndex(2)
                }

                if rootSpotlightItems.count > 1 {
                    TVSpotlightCarouselControls(
                        currentIndex: min(max(spotlightIndex, 0), rootSpotlightItems.count - 1),
                        itemCount: rootSpotlightItems.count,
                        showsArrows: isSpotlightHeroFocused
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, TVMediaLibrarySpotlightHero.contentHorizontalPadding)
                    .padding(.bottom, 70)
                    .zIndex(3)
                }
            }
        }
        .tvFocusSectionIfAvailable()
    }

    @ViewBuilder
    private func continueWatchingShelfEntry(for item: TVMediaLibraryFeaturedItem) -> some View {
        if let playableFile = tvPlayableLibraryFile(server: currentServer, node: item.node) {
            Button(action: { playbackCoordinator.play(file: playableFile) }) {
                TVMediaLibraryFeaturedCard(server: currentServer, item: item)
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
        } else {
            TVNavigationLink(destination: tvDestination(for: item.node)) {
                TVMediaLibraryFeaturedCard(server: currentServer, item: item)
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
        }
    }

    private func refreshAll() {
        guard isRootBrowser else {
            loadNodes()
            return
        }
        didAttemptLoadContinueWatching = false
        didAttemptLoadFavorites = false
        didAttemptLoadFallbackSpotlight = false
        loadNodes()
        loadContinueWatchingIfNeeded()
        loadFavoritesIfNeeded()
    }

    private func loadNodes() {
        isLoading = true
        errorMessage = nil
        let serverToLoad = currentServer
        let currentSortPreference = sortPreference
        if isRootBrowser {
            fallbackSpotlightTask?.cancel()
            fallbackSpotlightTask = nil
            fallbackSpotlightItems = []
            didAttemptLoadFallbackSpotlight = false
        }

        Task {
            do {
                let fetched = try await tvFetchMediaLibraryNodes(
                    server: serverToLoad,
                    parentNode: parentNode,
                    sortPreference: currentSortPreference
                )

                if Task.isCancelled { return }
                await MainActor.run {
                    nodes = fetched
                    isLoading = false
                    loadFallbackSpotlightIfNeeded()
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    nodes = []
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func loadContinueWatchingIfNeeded() {
        guard isRootBrowser else { return }
        refreshContinueWatching()
    }

    private func refreshContinueWatching() {
        guard isRootBrowser else { return }
        let serverToLoad = currentServer
        continueWatchingTask?.cancel()
        continueWatchingTask = Task {
            do {
                let fetched = try await tvFetchMediaLibraryContinueWatchingItems(
                    server: serverToLoad,
                    limit: tvMediaLibraryContinueWatchingLimit
                )
                if Task.isCancelled { return }
                await MainActor.run {
                    continueWatchingItems = fetched
                    if spotlightIndex >= fetched.count {
                        spotlightIndex = 0
                    }
                    spotlightCarouselTask?.cancel()
                    spotlightCarouselTask = nil
                    startSpotlightCarouselIfNeeded()
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    continueWatchingItems = []
                    spotlightIndex = 0
                    spotlightCarouselTask?.cancel()
                    spotlightCarouselTask = nil
                    startSpotlightCarouselIfNeeded()
                }
            }
        }
    }

    private func loadFavoritesIfNeeded() {
        guard isRootBrowser, !didAttemptLoadFavorites else { return }
        didAttemptLoadFavorites = true
        refreshFavorites()
    }

    private func refreshFavorites() {
        guard isRootBrowser else { return }
        let serverToLoad = currentServer
        favoritesTask?.cancel()
        favoritesTask = Task {
            do {
                let fetched = try await tvFetchMediaLibraryFavoriteNodes(
                    server: serverToLoad,
                    limit: 50
                )
                if Task.isCancelled { return }
                await MainActor.run {
                    favoriteNodes = fetched
                    favoritesTask = nil
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    favoriteNodes = []
                    favoritesTask = nil
                }
            }
        }
    }

    private func startSpotlightCarouselIfNeeded() {
        guard isRootBrowser, rootSpotlightItems.count > 1, spotlightCarouselTask == nil else { return }

        spotlightCarouselTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                } catch {
                    return
                }

                if Task.isCancelled { return }
                await MainActor.run {
                    guard rootSpotlightItems.count > 1 else { return }
                    withAnimation(.easeInOut(duration: 0.34)) {
                        spotlightIndex = (spotlightIndex + 1) % rootSpotlightItems.count
                    }
                }
            }
        }
    }

    private func moveSpotlight(by offset: Int) {
        guard isRootBrowser, rootSpotlightItems.count > 1 else { return }

        spotlightCarouselTask?.cancel()
        spotlightCarouselTask = nil

        let count = rootSpotlightItems.count
        withAnimation(.easeInOut(duration: 0.28)) {
            spotlightIndex = (spotlightIndex + offset + count) % count
        }

        startSpotlightCarouselIfNeeded()
    }

    private func activateSpotlightPrimaryAction(for item: TVMediaLibraryFeaturedItem) {
        if let playableFile = tvPlayableLibraryFile(server: currentServer, node: item.node) {
            playbackCoordinator.play(file: playableFile)
        } else {
            openSpotlightNode(item.node)
        }
    }

    private func openSpotlightNode(_ node: TVMediaLibraryNode) {
        spotlightNavigationNode = node
        DispatchQueue.main.async {
            isSpotlightNavigationActive = true
        }
    }

    private func loadFallbackSpotlightIfNeeded() {
        guard isRootBrowser,
              !didAttemptLoadFallbackSpotlight,
              (currentServer.type == .jellyfin || !nodes.isEmpty) else {
            return
        }

        didAttemptLoadFallbackSpotlight = true
        let serverToLoad = currentServer
        let rootNodes = nodes
        fallbackSpotlightTask?.cancel()
        fallbackSpotlightTask = Task {
            let fetched: [TVMediaLibraryFeaturedItem]
            if serverToLoad.type == .jellyfin {
                fetched = (try? await tvFetchJellyfinHomeCarousel(server: serverToLoad)) ?? []
            } else {
                fetched = await tvFetchMediaLibraryFallbackSpotlightItems(
                    server: serverToLoad, rootNodes: rootNodes, limit: tvMediaLibrarySpotlightFallbackLimit)
            }

            if Task.isCancelled { return }
            await MainActor.run {
                fallbackSpotlightItems = fetched
                if serverToLoad.type == .jellyfin || continueWatchingItems.isEmpty {
                    spotlightIndex = min(spotlightIndex, max(rootSpotlightItems.count - 1, 0))
                    spotlightCarouselTask?.cancel()
                    spotlightCarouselTask = nil
                    startSpotlightCarouselIfNeeded()
                }
                fallbackSpotlightTask = nil
            }
        }
    }

    private func testConnection() {
        isTestingConnection = true
        connectionAlert = nil
        testTask?.cancel()
        let serverToTest = currentServer

        testTask = Task {
            do {
                let verifiedServer = try await withThrowingTaskGroup(of: ServerConfig.self) { group in
                    group.addTask {
                        try await tvTestServerConnection(serverToTest)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        throw NSError(
                            domain: "GenPlayerShell",
                            code: NSURLErrorTimedOut,
                            userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection timed out")]
                        )
                    }
                    guard let result = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return result
                }

                if Task.isCancelled { return }
                let summary = tvServerSummary(for: verifiedServer)
                await MainActor.run {
                    isTestingConnection = false
                    connectionAlert = TVTransientAlert(
                        title: platformShellString("Connection Successful"),
                        message: tvHasText(summary) ? summary : verifiedServer.fullURL
                    )
                    didAttemptLoadContinueWatching = false
                    didAttemptLoadFallbackSpotlight = false
                    fallbackSpotlightItems = []
                    loadNodes()
                    loadContinueWatchingIfNeeded()
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isTestingConnection = false
                    connectionAlert = TVTransientAlert(
                        title: platformShellString("Connection Failed"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func dismissToServerList() {
        if TVPlaybackCoordinator.shared.shouldSuppressExitCommands() {
            return
        }

        if tvPopNavigationIfPossible(in: browsingNavigation) {
            return
        }

        if let browsingNavigation {
            browsingNavigation.back()
        } else {
            presentationMode.wrappedValue.dismiss()
        }
    }

    private func returnToLibraryHome() {
        if TVPlaybackCoordinator.shared.shouldSuppressExitCommands() {
            return
        }

        if tvPopToRootNavigationIfPossible(in: browsingNavigation) {
            return
        }

        if let browsingNavigation {
            browsingNavigation.back()
        } else {
            presentationMode.wrappedValue.dismiss()
        }
    }

    private func persistSortPreferenceAndReload() {
        guard supportsSortControls else { return }
        saveSortPreference()
        loadNodes()
    }

    private func loadSavedSortPreference() {
        guard supportsSortControls,
              let keyPrefix = sortPreferenceKeyPrefix else {
            return
        }

        let defaults = UserDefaults.standard
        if let rawField = defaults.string(forKey: "\(keyPrefix).by"),
           let savedField = TVMediaLibrarySortField(rawValue: rawField) {
            sortField = savedField
        }
        if let rawOrder = defaults.string(forKey: "\(keyPrefix).order"),
           let savedOrder = TVMediaLibrarySortOrder(rawValue: rawOrder) {
            sortOrder = savedOrder
        }
    }

    private func saveSortPreference() {
        guard let keyPrefix = sortPreferenceKeyPrefix else { return }
        let defaults = UserDefaults.standard
        defaults.set(sortField.rawValue, forKey: "\(keyPrefix).by")
        defaults.set(sortOrder.rawValue, forKey: "\(keyPrefix).order")
    }

    private var sortPreferenceKeyPrefix: String? {
        guard let parentNode, parentNode.isLibraryRoot else { return nil }
        return "tvLibrarySort.\(currentServer.type.rawValue).\(currentServer.id.uuidString).\(parentNode.id)"
    }
}



enum TVMediaLibrarySortField: String, CaseIterable, Identifiable {
    case name = "SortName"
    case dateAdded = "DateCreated"
    case releaseDate = "PremiereDate"
    case releaseYear = "ProductionYear"
    case rating = "CommunityRating"
    case runtime = "Runtime"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name:
            return platformShellString("Name")
        case .dateAdded:
            return platformShellString("Date Added")
        case .releaseDate:
            return platformShellString("Release Date")
        case .releaseYear:
            return platformShellString("Release Year")
        case .rating:
            return platformShellString("Rating")
        case .runtime:
            return platformShellString("Runtime")
        }
    }
}



enum TVMediaLibrarySortOrder: String, CaseIterable, Identifiable {
    case ascending = "Ascending"
    case descending = "Descending"

    var id: String { rawValue }
    var title: String { platformShellString(rawValue) }
}



struct TVMediaLibrarySortPreference {
    let field: TVMediaLibrarySortField
    let order: TVMediaLibrarySortOrder

    var jellyfinSortBy: String { field.rawValue }
    var jellyfinSortOrder: String { order.rawValue }

    var plexSortParameter: String {
        let fieldName: String
        switch field {
        case .name:
            fieldName = "titleSort"
        case .dateAdded:
            fieldName = "addedAt"
        case .releaseDate:
            fieldName = "originallyAvailableAt"
        case .releaseYear:
            fieldName = "year"
        case .rating:
            fieldName = "rating"
        case .runtime:
            fieldName = "duration"
        }
        return "\(fieldName):\(order == .ascending ? "asc" : "desc")"
    }
}



struct TVMediaLibrarySortView: View {
    @Binding var sortField: TVMediaLibrarySortField
    @Binding var sortOrder: TVMediaLibrarySortOrder
    let onPreferenceChanged: () -> Void

    var body: some View {
        TVSettingsChoicePage(title: platformShellString("Sort")) {
            VStack(alignment: .leading, spacing: 28) {
                sortFieldSection
                sortOrderSection
            }
        }
    }

    private var sortFieldSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVSettingsSectionHeader(title: platformShellString("Sort By"))

            ForEach(TVMediaLibrarySortField.allCases) { option in
                Button(action: {
                    guard sortField != option else { return }
                    sortField = option
                    sortOrder = option == .name ? .ascending : .descending
                    onPreferenceChanged()
                }) {
                    TVSettingsChoiceRow(
                        title: option.title,
                        subtitle: nil,
                        isSelected: sortField == option
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
        }
    }

    private var sortOrderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVSettingsSectionHeader(title: platformShellString("Sort Order"))

            ForEach(TVMediaLibrarySortOrder.allCases) { option in
                Button(action: {
                    guard sortOrder != option else { return }
                    sortOrder = option
                    onPreferenceChanged()
                }) {
                    TVSettingsChoiceRow(
                        title: option.title,
                        subtitle: nil,
                        isSelected: sortOrder == option
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
        }
    }
}



struct TVMediaLibrarySpotlightHero: View {
    let server: ServerConfig
    let item: TVMediaLibraryFeaturedItem

    static let heroHeight: CGFloat = 760
    static let contentHorizontalPadding: CGFloat = TVPageContentMetrics.heroHorizontalPadding
    static let focusHostTopInset: CGFloat = 126
    static let focusHostHeight: CGFloat = 438
    private static let topBleed: CGFloat = 96

    private var title: String {
        tvDisplayTitle(from: item.node.name, type: item.node.type)
    }

    private var metadataText: String {
        tvMediaLibraryDisplayMetadataLine(for: item.node, includesType: true)
    }

    private var sourceTitle: String {
        item.sourceTitle ?? platformShellString("Continue Watching")
    }

    private var sourceSystemImageName: String {
        item.sourceSystemImageName ?? "play.rectangle.on.rectangle.fill"
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            backdropLayer

            readabilityScrims

            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    Image(systemName: sourceSystemImageName)
                        .font(.headline.weight(.bold))
                    Text(sourceTitle)
                        .font(.headline.weight(.bold))
                        .lineLimit(1)
                }
                .foregroundColor(TVShellStyle.accentSoft)

                Text(title)
                    .font(.system(size: 58, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.58)
                    .frame(maxWidth: 820, alignment: .leading)
                    .shadow(color: Color.black.opacity(0.48), radius: 12, x: 0, y: 5)

                Text(metadataText)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(.white.opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .frame(maxWidth: 760, alignment: .leading)

                if let summary = item.node.summary, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 23, weight: .semibold))
                        .foregroundColor(.white.opacity(0.70))
                        .lineSpacing(4)
                        .lineLimit(3)
                        .frame(maxWidth: 790, alignment: .leading)
                }

                if let progress = item.progress, progress > 0 {
                    HStack(spacing: 12) {
                        TVMediaPlaybackProgressBadge(
                            progress: progress,
                            systemImageName: "play.fill",
                            diameter: 48
                        )
                        Text("\(Int(progress * 100))%")
                            .font(.headline.weight(.bold))
                            .foregroundColor(.white.opacity(0.64))
                    }
                }
            }
            .padding(.leading, Self.contentHorizontalPadding)
            .padding(.trailing, Self.contentHorizontalPadding)
            .padding(.bottom, 154)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.heroHeight, alignment: .bottom)
        .background(Color.black)
    }

    private var heroImageURL: URL? {
        item.node.backdropURL ?? item.node.posterURL
    }

    private var placeholderSystemImageName: String {
        item.node.isFolder ? "folder.fill" : item.node.type.tvSystemImageName
    }

    private var backdropLayer: some View {
        ZStack(alignment: .bottomTrailing) {
            TVRemoteArtworkView(
                url: heroImageURL,
                server: server,
                placeholderSystemImageName: placeholderSystemImageName,
                placeholderCornerRadius: 0
            )
            .id(heroImageURL?.absoluteString ?? item.node.id)
            .scaleEffect(1.04, anchor: .center)
            .frame(maxWidth: .infinity)
            .frame(height: Self.heroHeight + Self.topBleed)
            .clipped()
            
            if let logoUrl = item.node.logoURL {
                TVRemoteLogoImage(url: logoUrl, maxHeight: 120)
                    .padding(.bottom, 180)
                    .padding(.trailing, 80)
                    .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 4)
            }
        }
    }

    private var readabilityScrims: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.black.opacity(0.74), location: 0.00),
                    .init(color: Color.black.opacity(0.54), location: 0.26),
                    .init(color: Color.black.opacity(0.24), location: 0.58),
                    .init(color: Color.black.opacity(0.04), location: 1.00)
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.black.opacity(0.48), location: 0.00),
                    .init(color: Color.black.opacity(0.12), location: 0.22),
                    .init(color: Color.clear, location: 0.48)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                gradient: Gradient(stops: [
                    .init(color: Color.clear, location: 0.00),
                    .init(color: Color.black.opacity(0.10), location: 0.48),
                    .init(color: TVShellStyle.background.opacity(0.88), location: 1.00)
                ]),
                startPoint: UnitPoint(x: 0.50, y: 0.20),
                endPoint: .bottom
            )
        }
        .frame(height: Self.heroHeight + Self.topBleed)
        .allowsHitTesting(false)
    }
}



struct TVSpotlightCarouselFocusHost: UIViewRepresentable {
    @Binding var isFocused: Bool
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void
    let onSelect: () -> Void

    func makeUIView(context: Context) -> TVSpotlightCarouselFocusView {
        let view = TVSpotlightCarouselFocusView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: TVSpotlightCarouselFocusView, context: Context) {
        uiView.onMoveLeft = onMoveLeft
        uiView.onMoveRight = onMoveRight
        uiView.onSelect = onSelect
        uiView.onFocusChanged = { focused in
            DispatchQueue.main.async {
                isFocused = focused
            }
        }
    }
}



struct TVSpotlightActionButtonLabel: View {
    let actionTitle: String

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "play.fill")
            Text(actionTitle)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .font(.system(size: 25, weight: .bold))
        .foregroundColor(showsFocus ? .black.opacity(0.90) : .white.opacity(isEnabled ? 0.92 : 0.40))
        .padding(.horizontal, 26)
        .frame(minWidth: 250, minHeight: 68)
        .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(showsFocus ? Color.white.opacity(0.94) : Color.white.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(showsFocus ? Color.clear : Color.white.opacity(0.18), lineWidth: 1)
        )
        .overlay(TVFocusedBlockOverlay(cornerRadius: 19, showsFocus: showsFocus, outerLineWidth: 3.0, innerInset: 3))
        .scaleEffect(showsFocus ? 1.025 : 1.0)
        .shadow(color: showsFocus ? Color.black.opacity(0.28) : .clear, radius: showsFocus ? 14 : 0, x: 0, y: showsFocus ? 7 : 0)
        .modifier(TVFocusedCardLayerModifier())
        .animation(.easeOut(duration: 0.16), value: showsFocus)
    }
}



struct TVSpotlightCarouselControls: View {
    let currentIndex: Int
    let itemCount: Int
    let showsArrows: Bool

    var body: some View {
        HStack(spacing: 16) {
            if showsArrows {
                TVCarouselIconButtonLabel(systemImageName: "chevron.left")
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
            }

            HStack(spacing: 10) {
                TVCarouselDots(currentIndex: currentIndex, itemCount: itemCount)

                Text("\(currentIndex + 1) / \(itemCount)")
                    .font(.caption.weight(.heavy))
                    .foregroundColor(.white.opacity(0.70))
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.42))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )

            if showsArrows {
                TVCarouselIconButtonLabel(systemImageName: "chevron.right")
                    .transition(.opacity.combined(with: .scale(scale: 0.86)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .animation(.easeOut(duration: 0.16), value: showsArrows)
    }
}



struct TVCarouselIconButton: View {
    let systemImageName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVCarouselIconButtonLabel(systemImageName: systemImageName)
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
    }
}



struct TVCarouselIconButtonLabel: View {
    let systemImageName: String

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    var body: some View {
        Image(systemName: systemImageName)
            .font(.system(size: 22, weight: .heavy))
            .foregroundColor(showsFocus ? Color.black.opacity(0.88) : .white.opacity(isEnabled ? 0.86 : 0.36))
            .frame(width: 58, height: 58)
            .contentShape(Circle())
            .background(
                Circle()
                    .fill(showsFocus ? Color.white.opacity(0.94) : Color.black.opacity(0.44))
            )
            .overlay(
                Circle()
                    .stroke(showsFocus ? Color.clear : Color.white.opacity(0.14), lineWidth: 1)
            )
            .overlay(TVFocusedBlockOverlay(cornerRadius: 29, showsFocus: showsFocus, outerLineWidth: 3.0, innerInset: 4))
            .scaleEffect(showsFocus ? 1.08 : 1.0)
            .shadow(color: Color.black.opacity(showsFocus ? 0.32 : 0.18), radius: showsFocus ? 14 : 8, x: 0, y: showsFocus ? 8 : 4)
            .modifier(TVFocusedCardLayerModifier())
            .animation(.easeOut(duration: 0.16), value: showsFocus)
    }
}



struct TVCarouselDots: View {
    let currentIndex: Int
    let itemCount: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<itemCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == currentIndex ? TVShellStyle.accentSoft : Color.white.opacity(0.30))
                    .frame(width: index == currentIndex ? 18 : 7, height: 7)
                    .animation(.easeInOut(duration: 0.18), value: currentIndex)
            }
        }
    }
}



struct TVMediaLibraryTopBar: View {
    let server: ServerConfig
    let title: String
    let scopeNode: TVMediaLibraryNode?
    var onRefresh: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        ZStack {
            HStack(spacing: 18) {
                TVServerIdentityPill(server: server)

                Spacer(minLength: 20)

                HStack(spacing: 14) {
                    TVNavigationLink(
                        destination: TVMediaLibrarySearchView(
                            server: server,
                            title: title,
                            scopeNode: scopeNode
                        )
                    ) {
                        TVTopChromeIconButton(
                            title: platformShellString("Search"),
                            systemImageName: "magnifyingglass",
                            diameter: 66
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()

                    if let onRefresh {
                        Button(action: onRefresh) {
                            TVTopChromeIconButton(
                                title: platformShellString("Refresh"),
                                systemImageName: "arrow.clockwise",
                                diameter: 66
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                    }

                    if let onClose {
                        Button(action: onClose) {
                            TVTopChromeIconButton(
                                title: platformShellString("Close"),
                                systemImageName: "rectangle.portrait.and.arrow.right",
                                diameter: 66
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                    }
                }
                .tvFocusSectionIfAvailable()
        } // Close HStack(spacing: 18)
            
            VStack(alignment: .center) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, scopeNode == nil ? 26 : 0)
        .tvFocusSectionIfAvailable()
    }
}



struct TVMediaLibrarySearchView: View {
    let server: ServerConfig
    let title: String
    let scopeNode: TVMediaLibraryNode?

    @State private var searchText = ""
    @State private var results: [TVMediaLibraryNode] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchTask: Task<Void, Never>?

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        TVPageScrollView(
            title: platformShellString("Search"),
            subtitle: tvHasText(scopeNode?.name) ? scopeNode?.name : title,
            handlesExitCommand: true
        ) {
            TVTextFieldPanel(
                title: platformShellString("Search"),
                placeholder: platformShellString("Search"),
                text: $searchText
            )

            if let errorMessage, !errorMessage.isEmpty {
                TVInfoPanel(
                    title: platformShellString("Connection Failed"),
                    message: errorMessage,
                    systemImageName: "exclamationmark.triangle.fill",
                    kind: .error,
                    tintColor: .red
                )
            } else if isLoading {
                TVInfoPanel(
                    title: platformShellString("Platform Shell TV Loading"),
                    message: trimmedSearchText,
                    systemImageName: "hourglass"
                )
            } else if trimmedSearchText.isEmpty {
                TVInfoPanel(
                    title: platformShellString("Search"),
                    message: platformShellString("Type to search"),
                    systemImageName: "magnifyingglass"
                )
            } else if results.isEmpty {
                TVInfoPanel(
                    title: platformShellString("No results found"),
                    message: trimmedSearchText,
                    systemImageName: "doc.text.magnifyingglass"
                )
            } else {
                TVMediaLibraryPosterGrid(items: results) { node in
                    TVNavigationLink(destination: tvMediaLibraryDestination(server: server, node: node)) {
                        TVMediaLibraryPosterCard(server: server, node: node)
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
            }
        }
        .navigationTitle(Text(platformShellString("Search")))
        .onChange(of: searchText) { newValue in
            scheduleSearch(for: newValue)
        }
        .onDisappear {
            searchTask?.cancel()
            searchTask = nil
        }
    }

    private func scheduleSearch(for rawValue: String) {
        let query = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        errorMessage = nil

        guard !query.isEmpty else {
            isLoading = false
            results = []
            return
        }

        isLoading = true
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    private func performSearch(query: String) async {
        do {
            let fetched = try await tvSearchMediaLibraryNodes(
                server: server,
                scopeNode: scopeNode,
                query: query
            )
            guard !Task.isCancelled else { return }

            let shouldApply = await MainActor.run {
                trimmedSearchText == query
            }
            guard shouldApply else { return }

            await MainActor.run {
                results = fetched
                isLoading = false
                errorMessage = nil
            }
        } catch {
            guard !Task.isCancelled else { return }

            let shouldApply = await MainActor.run {
                trimmedSearchText == query
            }
            guard shouldApply else { return }

            await MainActor.run {
                results = []
                isLoading = false
                errorMessage = error.localizedDescription
            }
        }
    }
}



struct TVMediaLibraryRootShelfSection: View {
    let server: ServerConfig
    let node: TVMediaLibraryNode

    @State private var previewNodes: [TVMediaLibraryNode] = []
    @State private var realItemCount: Int? = nil
    @State private var isLoading = false
    @State private var didAttemptLoad = false
    @State private var loadTask: Task<Void, Never>?

    private var sectionTitle: String {
        tvDisplayTitle(from: node.name, type: .folder)
    }

    private var sectionIcon: String {
        tvMediaLibraryCollectionIcon(for: node.libraryCollectionType, nodeName: node.name)
    }

    var body: some View {
        let browseDestination = TVMediaLibraryBrowserView(server: server, title: sectionTitle, parentNode: node)

        let countSubtitle = (realItemCount ?? node.itemCount).flatMap { count -> String? in
            guard count > 0 else { return nil }
            return MediaCountFormatter.format(count: count, libraryType: node.jellyfinLibraryType)
        }

        TVShelfSection(
            title: sectionTitle,
            subtitle: countSubtitle,
            systemImage: sectionIcon,
            headerDestination: browseDestination
        ) {
            if isLoading && previewNodes.isEmpty {
                TVMediaLibraryShelfLoadingCard()
            }

            ForEach(previewNodes) { previewNode in
                TVNavigationLink(destination: tvDestination(for: previewNode)) {
                    TVMediaLibraryPosterCard(server: server, node: previewNode)
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

        }
        .onAppear {
            loadPreviewIfNeeded()
        }
        .onDisappear {
            cancelPreviewLoad(resetForRetry: previewNodes.isEmpty)
        }
    }

    @ViewBuilder
    private func tvDestination(for previewNode: TVMediaLibraryNode) -> some View {
        tvMediaLibraryDestination(server: server, node: previewNode)
    }

    private func loadPreviewIfNeeded() {
        guard !didAttemptLoad, !isLoading else { return }

        didAttemptLoad = true
        isLoading = true
        loadTask?.cancel()
        loadTask = Task {
            async let categoryInfo = tvFetchMediaLibraryCategoryInfo(server: server, node: node)
            async let fetchedNodes = tvFetchMediaLibraryNodes(
                server: server,
                parentNode: node,
                limit: tvMediaLibraryShelfPreviewFetchLimit
            )
            do {
                let (_, count) = await categoryInfo
                let fetched = try await fetchedNodes
                if Task.isCancelled {
                    await MainActor.run {
                        if previewNodes.isEmpty {
                            isLoading = false
                            didAttemptLoad = false
                        }
                        loadTask = nil
                    }
                    return
                }
                await MainActor.run {
                    if let count, count > 0 {
                        self.realItemCount = count
                    }
                    previewNodes = tvMediaLibraryShelfPreviewNodes(
                        from: fetched,
                        limit: tvMediaLibraryShelfPreviewDisplayLimit
                    )
                    isLoading = false
                    loadTask = nil
                }
            } catch {
                if Task.isCancelled {
                    await MainActor.run {
                        if previewNodes.isEmpty {
                            isLoading = false
                            didAttemptLoad = false
                        }
                        loadTask = nil
                    }
                    return
                }
                let (_, count) = await categoryInfo
                await MainActor.run {
                    if let count, count > 0 {
                        self.realItemCount = count
                    }
                    previewNodes = []
                    isLoading = false
                    loadTask = nil
                }
            }
        }
    }

    private func cancelPreviewLoad(resetForRetry: Bool) {
        loadTask?.cancel()
        loadTask = nil
        guard resetForRetry else { return }
        isLoading = false
        didAttemptLoad = false
    }
}



struct TVMediaLibraryResolvedSeriesNodeView: View {
    let server: ServerConfig
    let node: TVMediaLibraryNode

    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @State private var seriesNode: TVMediaLibraryNode?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadTask: Task<Void, Never>?

    private var rawType: String {
        node.rawItemType.lowercased()
    }

    private var initialSeasonId: String? {
        rawType == "season" ? node.id : node.seasonId
    }

    private var initialEpisodeId: String? {
        rawType == "episode" ? node.id : nil
    }

    private var offlineFallbackFile: VideoFile? {
        tvOfflineLibraryPlaybackFile(server: server, node: node, downloadCenter: downloadCenter)
    }

    var body: some View {
        Group {
            if let seriesNode {
                TVSeriesDetailView(
                    server: server,
                    node: seriesNode,
                    initialSeasonId: initialSeasonId,
                    initialEpisodeId: initialEpisodeId
                )
            } else if !isLoading,
                      errorMessage != nil,
                      let offlineFallbackFile {
                TVMediaDetailView(file: offlineFallbackFile)
            } else {
                loadingOrErrorView
            }
        }
        .onAppear { loadIfNeeded() }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    private var loadingOrErrorView: some View {
        TVPageScrollView(
            title: tvDisplayTitle(from: node.seriesName ?? node.name, type: .video),
            subtitle: server.name,
            handlesExitCommand: true
        ) {
            if isLoading {
                TVInfoPanel(
                    title: platformShellString("Platform Shell TV Loading"),
                    message: server.name,
                    systemImageName: "hourglass"
                )
            } else if let errorMessage {
                TVFeedbackPanel(
                    title: platformShellString("Connection Failed"),
                    message: errorMessage,
                    systemImageName: "exclamationmark.triangle.fill",
                    kind: .error,
                    tintColor: .red,
                    action: TVFeedbackPanelAction(
                        title: platformShellString("Retry"),
                        systemImageName: "arrow.clockwise",
                        action: { load(force: true) }
                    )
                )
            } else {
                TVInfoPanel(
                    title: platformShellString("Platform Shell TV Loading"),
                    message: server.name,
                    systemImageName: "hourglass"
                )
            }
        }
    }

    private func loadIfNeeded() {
        guard seriesNode == nil, !isLoading else { return }
        load(force: false)
    }

    private func load(force: Bool) {
        guard force || (!isLoading && seriesNode == nil) else { return }
        guard let seriesId = tvTrimmedText(node.seriesId) else { return }
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil

        loadTask = Task {
            do {
                guard let fetched = try await tvFetchMediaLibraryNode(server: server, itemId: seriesId) else {
                    throw NSError(
                        domain: "GenPlayerShell",
                        code: NSURLErrorCannotDecodeContentData,
                        userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection Failed")]
                    )
                }

                if Task.isCancelled { return }
                await MainActor.run {
                    seriesNode = fetched
                    isLoading = false
                    errorMessage = nil
                    loadTask = nil
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    seriesNode = nil
                    isLoading = false
                    errorMessage = error.localizedDescription
                    loadTask = nil
                }
            }
        }
    }
}



struct TVMediaSourceProbe {
    let width: Int?
    let height: Int?
    let size: Int64?
    let container: String?
}



struct TVMediaLibraryUserState {
    let isFavorite: Bool?
    let isPlayed: Bool?
    let playbackPositionSeconds: TimeInterval?
    let playbackProgress: Double?
}



struct TVMediaLibraryResolvedItemView: View {
    let server: ServerConfig
    let itemId: String
    let fallbackFile: VideoFile

    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @State private var resolvedTarget: ResolvedTarget?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadTask: Task<Void, Never>?

    private enum ResolvedTarget {
        case series(TVMediaLibraryNode, seasonId: String?, episodeId: String?)
        case node(TVMediaLibraryNode)
    }

    var body: some View {
        Group {
            if let resolvedTarget {
                destination(for: resolvedTarget)
            } else if !isLoading,
                      errorMessage != nil,
                      let offlineFallbackFile {
                TVMediaDetailView(file: offlineFallbackFile)
            } else {
                loadingOrErrorView
            }
        }
        .onAppear {
            loadIfNeeded()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    @ViewBuilder
    private func destination(for target: ResolvedTarget) -> some View {
        switch target {
        case .series(let node, let seasonId, let episodeId):
            TVSeriesDetailView(
                server: server,
                node: node,
                initialSeasonId: seasonId,
                initialEpisodeId: episodeId
            )
        case .node(let node):
            tvMediaLibraryDestination(server: server, node: node)
        }
    }

    private var offlineFallbackFile: VideoFile? {
        if let localFile = downloadCenter.localPlaybackFile(for: fallbackFile) {
            return localFile
        }

        if fallbackFile.url.isFileURL,
           fallbackFile.type == .video || fallbackFile.type == .audio {
            return fallbackFile
        }

        if let exactMatch = tvDownloadedLibraryPlaybackFiles(
            server: server,
            itemId: tvTrimmedText(fallbackFile.jellyfinItemId) ?? tvTrimmedText(itemId),
            downloadCenter: downloadCenter
        ).first {
            return exactMatch
        }

        let collectionId = tvTrimmedText(fallbackFile.seriesId) ?? tvTrimmedText(itemId)
        return tvDownloadedLibraryPlaybackFiles(
            server: server,
            seriesId: collectionId,
            seasonId: tvTrimmedText(fallbackFile.seasonId),
            downloadCenter: downloadCenter
        ).first
    }

    private var loadingOrErrorView: some View {
        TVPageScrollView(
            title: tvDisplayTitle(for: fallbackFile),
            subtitle: server.name,
            handlesExitCommand: true
        ) {
            if isLoading {
                TVInfoPanel(
                    title: platformShellString("Platform Shell TV Loading"),
                    message: server.name,
                    systemImageName: "hourglass"
                )
            } else if let errorMessage {
                TVFeedbackPanel(
                    title: platformShellString("Connection Failed"),
                    message: errorMessage,
                    systemImageName: "exclamationmark.triangle.fill",
                    kind: .error,
                    tintColor: .red,
                    action: TVFeedbackPanelAction(
                        title: platformShellString("Retry"),
                        systemImageName: "arrow.clockwise",
                        action: { load(force: true) }
                    )
                )
            } else {
                TVInfoPanel(
                    title: platformShellString("Platform Shell TV Loading"),
                    message: server.name,
                    systemImageName: "hourglass"
                )
            }
        }
    }

    private func loadIfNeeded() {
        guard resolvedTarget == nil, !isLoading else { return }
        load(force: false)
    }

    private func load(force: Bool) {
        guard force || (!isLoading && resolvedTarget == nil) else { return }
        loadTask?.cancel()
        isLoading = true
        errorMessage = nil

        loadTask = Task {
            do {
                let target = try await resolveTarget()
                if Task.isCancelled { return }
                await MainActor.run {
                    resolvedTarget = target
                    isLoading = false
                    errorMessage = nil
                    loadTask = nil
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    resolvedTarget = nil
                    isLoading = false
                    errorMessage = error.localizedDescription
                    loadTask = nil
                }
            }
        }
    }

    private func resolveTarget() async throws -> ResolvedTarget {
        guard let node = try await tvFetchMediaLibraryNode(server: server, itemId: itemId) else {
            throw NSError(
                domain: "GenPlayerShell",
                code: NSURLErrorCannotDecodeContentData,
                userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection Failed")]
            )
        }

        let rawType = node.rawItemType.lowercased()
        if rawType == "episode" || rawType == "season",
           let seriesId = tvTrimmedText(node.seriesId),
           let seriesNode = try await tvFetchMediaLibraryNode(server: server, itemId: seriesId) {
            return .series(
                seriesNode,
                seasonId: rawType == "season" ? node.id : node.seasonId,
                episodeId: rawType == "episode" ? node.id : nil
            )
        }

        if node.isSeries {
            return .series(
                node,
                seasonId: fallbackSeriesSeasonId(for: node),
                episodeId: fallbackSeriesEpisodeId(for: node)
            )
        }

        return .node(node)
    }

    private func fallbackSeriesSeasonId(for node: TVMediaLibraryNode) -> String? {
        guard tvTrimmedText(fallbackFile.seriesId) == node.id || itemId == node.id else {
            return nil
        }
        return tvTrimmedText(fallbackFile.seasonId)
    }

    private func fallbackSeriesEpisodeId(for node: TVMediaLibraryNode) -> String? {
        guard tvTrimmedText(fallbackFile.seriesId) == node.id || itemId == node.id else {
            return nil
        }
        guard let episodeId = tvTrimmedText(fallbackFile.jellyfinItemId),
              episodeId != node.id else {
            return nil
        }
        return episodeId
    }
}
#endif
