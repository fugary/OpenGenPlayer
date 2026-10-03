import SwiftUI
import GenPlayerShell

private func isCancellationError(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

private func embyResumeDecision(
    from userData: EmbyUserData?,
    runtimeTicks: Int64?,
    playedOverride: Bool? = nil
) -> RemotePlaybackResumeDecision {
    userData?.resumeDecision(runtimeTicks: runtimeTicks, playedOverride: playedOverride) ?? .none
}

private func embyPlaybackPositionSeconds(
    from userData: EmbyUserData?,
    runtimeTicks: Int64?,
    playedOverride: Bool? = nil
) -> TimeInterval? {
    embyResumeDecision(
        from: userData,
        runtimeTicks: runtimeTicks,
        playedOverride: playedOverride
    ).startPosition
}

private func embyRuntimeSeconds(_ ticks: Int64?) -> TimeInterval? {
    guard let ticks = ticks, ticks > 0 else { return nil }
    return Double(ticks) / 10_000_000.0
}

private func embyPlaybackStartTimeTicks(_ seconds: TimeInterval?) -> Int64? {
    guard let seconds, seconds > 0 else { return nil }
    return Int64(seconds * 10_000_000.0)
}

func embyEffectiveUserData(
    for item: EmbyItem,
    serverId: UUID,
    remotePlaybackState: RemotePlaybackStateStore
) -> EmbyUserData? {
    EmbyUserData.merged(
        item.userData,
        playbackState: remotePlaybackState.snapshot(serverId: serverId, itemId: item.id)
    )
}

private func embyPreferredPlaybackSource(for item: EmbyItem) -> EmbyMediaSource? {
    let sources = item.mediaSources ?? []
    return EmbyService.shared.preferredPlaybackSource(from: sources) ?? item.mediaSources?.first
}

private func embyPreferredStreamURL(for item: EmbyItem, server: ServerConfig, token: String) -> URL? {
    let preferredSource = embyPreferredPlaybackSource(for: item)
    let startPosition = embyPlaybackPositionSeconds(from: item.userData, runtimeTicks: item.runTimeTicks)
    return EmbyService.shared.resolvePlaybackURL(
        server: server,
        itemId: item.id,
        token: token,
        mediaSource: preferredSource,
        startTimeTicks: embyPlaybackStartTimeTicks(startPosition)
    )
}

private func applyEmbyPreferredSourceMetadata(from item: EmbyItem, to file: inout VideoFile) {
    guard let source = embyPreferredPlaybackSource(for: item) else { return }
    file.serverMediaStreams = source.mediaStreams?.map { $0.toDictionary() }
    file.serverContainer = source.container
    file.serverSize = source.size
    file.serverBitrate = source.bitrate
    file.serverPath = source.path
}

private func embyMediaBitrateText(_ bitrate: Int?) -> String? {
    guard let bitrate = bitrate, bitrate > 0 else { return nil }
    if bitrate >= 1_000_000 {
        return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000.0)
    }
    return "\(max(1, bitrate / 1000)) kbps"
}

private func embyMediaFileSizeText(_ size: Int64?) -> String? {
    guard let size = size, size > 0 else { return nil }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: size)
}

private func embyResolutionBadgeText(for item: EmbyItem) -> String? {
    guard let width = embyPreferredPlaybackSource(for: item)?.videoStream?.width else { return nil }
    if width >= 3800 { return "4K" }
    if width >= 1900 { return "1080P" }
    if width >= 1200 { return "720P" }
    return nil
}

func embyDetailMetadataSegments(for item: EmbyItem) -> [String] {
    guard let source = embyPreferredPlaybackSource(for: item) else { return [] }

    var segments: [String] = []
    if let resolution = embyResolutionBadgeText(for: item) {
        segments.append(resolution)
    }
    segments += MediaTechnicalMetadata.parts(video: source.videoStream?.toDictionary() ?? [:])
    if let container = source.container?.split(separator: ",").first {
        let text = String(container).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !text.isEmpty {
            segments.append(text)
        }
    }
    if let bitrate = embyMediaBitrateText(source.bitrate) {
        segments.append(bitrate)
    }
    if let size = embyMediaFileSizeText(source.size) {
        segments.append(size)
    }
    return segments
}

private typealias EmbyResolvedNavigationTarget = (item: EmbyItem, seasonId: String?, episodeId: String?)

private func embyResolvedNavigationTarget(
    server: ServerConfig,
    userId: String,
    itemId: String,
    token: String
) async -> EmbyResolvedNavigationTarget? {
    do {
        let item = try await EmbyService.shared.getItemDetails(server: server, userId: userId, itemId: itemId, token: token)
        if item.type == "Episode", let seriesId = item.seriesId {
            let seriesItem = try await EmbyService.shared.getItemDetails(server: server, userId: userId, itemId: seriesId, token: token)
            return (seriesItem, item.seasonId, item.id)
        }
        if item.type == "Season", let seriesId = item.seriesId {
            let seriesItem = try await EmbyService.shared.getItemDetails(server: server, userId: userId, itemId: seriesId, token: token)
            return (seriesItem, item.id, nil)
        }
        return (item, nil, nil)
    } catch {
        print("Failed to resolve Emby detail target: \(error)")
        return nil
    }
}

struct EmbyLibraryView: View {
    @State var server: ServerConfig
    @ObservedObject var networkService: AppNetworkService
    var onExit: (() -> Void)? = nil
    
    @State private var libraries: [EmbyLibrary] = []
    @State private var continueWatching: [EmbyItem] = []
    @State private var nextUp: [EmbyItem] = []
    @State private var libraryItems: [String: [EmbyItem]] = [:] // libraryId -> items
    @State private var libraryCounts: [String: Int] = [:] // libraryId -> total count
    @State private var favorites: [EmbyItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var needsLogin = false
    @State private var isShowingSearch = false
    @State private var nativeSearchText = ""
    @State private var searchLaunchQuery = ""
    @State private var isSearchOverlayActive = false
    @State private var overlaySearchQuery = ""
    @State private var overlaySearchResults: [EmbyItem] = []
    @State private var isOverlaySearching = false
    @State private var overlaySearchTask: Task<Void, Never>? = nil
    @State private var titleAnchorOffset: CGFloat = .zero
    @State private var initialTitleAnchorOffset: CGFloat?
    @State private var myMediaGridWidth: CGFloat = 0
    
    var targetItemIdToResolve: String? = nil
    @State private var autoResolveItem: EmbyItem? = nil
    @State private var autoResolveSeasonId: String? = nil
    @State private var autoResolveEpisodeId: String? = nil
    @State private var isNavigatingToAutoResolve = false
    @State private var loadDataTask: Task<Void, Never>? = nil
    @State private var summaryTask: Task<Void, Never>? = nil
    private typealias AutoResolveTarget = EmbyResolvedNavigationTarget
    
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    
    private let embyService = EmbyService.shared
    @ObservedObject private var remotePlaybackState = RemotePlaybackStateStore.shared

    private struct HomeCarouselEntry: Identifiable {
        let item: EmbyItem
        let sourceTitle: String
        let sourceSystemImage: String?

        var id: String { item.id }
    }

    private var myMediaColumns: [GridItem] {
        MediaCardMetrics.libraryShelfColumns(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass,
            availableWidth: myMediaGridWidth,
            horizontalPadding: myMediaGridPadding
        )
    }
    private var myMediaGridSpacing: CGFloat {
        MediaCardMetrics.libraryShelfGridSpacing(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
    }
    private var myMediaGridPadding: CGFloat {
        MediaCardMetrics.libraryShelfPadding(
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        )
    }
    private var homeShelfLibraries: [EmbyLibrary] {
        libraries.filter { $0.libraryType.showsHomeShelfSection }
    }

    private var fallbackSpotlightLibrary: EmbyLibrary? {
        let candidates = homeShelfLibraries.filter { library in
            (libraryItems[library.id] ?? []).contains { embyCarouselBackdropImageURL(for: $0) != nil }
        }

        for family in [MediaHomeSpotlightFamily.movie, .series, .other] {
            if let library = candidates.first(where: { spotlightFamily(for: $0) == family }) {
                return library
            }
        }

        return candidates.first
    }

    private var homeCarouselEntries: [HomeCarouselEntry] {
        var entries: [HomeCarouselEntry] = []
        var seenIds = Set<String>()

        @discardableResult
        func append(
            _ items: [EmbyItem],
            sourceTitle: String,
            sourceSystemImage: String?
        ) -> Int {
            let startingCount = entries.count

            let candidates = MediaHomeCarouselSelection.unique(items, limit: items.count,
                identity: { MediaHomeCarouselSelection.identity(itemID: $0.id, seriesID: $0.seriesId, itemType: $0.type) },
                lastPlayedAt: { MediaHomeCarouselSelection.date($0.userData?.lastPlayedDate) })
            for item in candidates {
                guard entries.count < 6 else { break }
                guard embyCarouselBackdropImageURL(for: item) != nil else { continue }
                guard seenIds.insert(MediaHomeCarouselSelection.identity(itemID: item.id, seriesID: item.seriesId, itemType: item.type)).inserted else { continue }
                entries.append(
                    HomeCarouselEntry(
                        item: item,
                        sourceTitle: sourceTitle,
                        sourceSystemImage: sourceSystemImage
                    )
                )
                if entries.count >= 6 { break }
            }

            return entries.count - startingCount
        }

        let continueSpotlightItems = spotlightItems(from: continueWatching.filter { embyActiveResumeSnapshot(for: $0) != nil })
        let continueFamily = mediaHomePreferredSpotlightFamily(from: continueSpotlightItems.map { $0.type })
        if append(
            continueSpotlightItems,
            sourceTitle: NSLocalizedString("Continue Watching", comment: ""),
            sourceSystemImage: "clock.fill"
        ) > 0 {
            if continueFamily == .series, entries.count < 6 {
                append(
                    spotlightItems(from: nextUp, matching: .series),
                    sourceTitle: NSLocalizedString("Next Up", comment: ""),
                    sourceSystemImage: "play.rectangle.fill"
                )
            }
            return entries
        }

        if append(
            spotlightItems(from: nextUp),
            sourceTitle: NSLocalizedString("Next Up", comment: ""),
            sourceSystemImage: "play.rectangle.fill"
        ) > 0 {
            return entries
        }

        if let library = fallbackSpotlightLibrary {
            append(
                spotlightItems(from: libraryItems[library.id] ?? [], matching: spotlightFamily(for: library)),
                sourceTitle: library.name,
                sourceSystemImage: library.libraryType.icon
            )
        }

        if entries.isEmpty {
            append(
                spotlightItems(from: favorites),
                sourceTitle: NSLocalizedString("Favorites", comment: ""),
                sourceSystemImage: "heart.fill"
            )
        }

        return entries
    }

    private func embyActiveResumeSnapshot(for item: EmbyItem) -> PlaybackProgressSnapshot? {
        let effectiveUserData = embyEffectiveUserData(
            for: item,
            serverId: server.id,
            remotePlaybackState: remotePlaybackState
        )
        guard let snapshot = PlaybackProgressSnapshot.fromPercent(
            effectiveUserData?.playedPercentage,
            played: effectiveUserData?.played ?? false
        ) else {
            return nil
        }
        guard snapshot.displayedProgress > 0, !snapshot.isFinished else { return nil }
        return snapshot
    }

    private func spotlightItems(
        from items: [EmbyItem],
        matching family: MediaHomeSpotlightFamily? = nil
    ) -> [EmbyItem] {
        let visibleItems = items.filter { embyCarouselBackdropImageURL(for: $0) != nil }
        guard !visibleItems.isEmpty else { return [] }

        guard let selectedFamily = family ?? mediaHomePreferredSpotlightFamily(from: visibleItems.map { $0.type }) else {
            return visibleItems
        }

        let filteredItems = visibleItems.filter {
            mediaHomeSpotlightFamily(forItemType: $0.type) == selectedFamily
        }
        return filteredItems.isEmpty ? visibleItems : filteredItems
    }

    private func spotlightFamily(for library: EmbyLibrary) -> MediaHomeSpotlightFamily {
        switch library.libraryType {
        case .movies:
            return .movie
        case .tvShows:
            return .series
        default:
            return .other
        }
    }

    private var homeCarouselItems: [MediaHomeCarouselItem] {
        homeCarouselEntries.map { entry in
            let item = entry.item
            let effectiveUserData = embyEffectiveUserData(
                for: item,
                serverId: server.id,
                remotePlaybackState: remotePlaybackState
            )
            let isPlayable = item.isPlayable

            return MediaHomeCarouselItem(
                id: item.id,
                title: item.displayTitle,
                subtitle: item.metadataLine ?? item.subtitle,
                metadataSegments: embyCarouselMetadataSegments(for: item),
                overview: embyCarouselOverview(for: item),
                sourceTitle: entry.sourceTitle,
                sourceSystemImage: entry.sourceSystemImage,
                imageURL: item.landscapeImageURL(server: server),
                backdropImageURL: embyCarouselBackdropImageURL(for: item),
                portraitImageURL: embyCarouselPortraitImageURL(for: item),
                logoURLs: [item.logoImageURL(server: server)].compactMap { $0 },
                actionTitle: isPlayable ? NSLocalizedString("Play", comment: "") : NSLocalizedString("View Details", comment: ""),
                actionSystemImage: isPlayable ? "play.fill" : "info.circle",
                playbackProgress: PlaybackProgressSnapshot.fromPercent(
                    effectiveUserData?.playedPercentage,
                    played: effectiveUserData?.played ?? false
                )
            )
        }
    }

    private func embyCarouselPortraitImageURL(for item: EmbyItem) -> URL? {
        switch item.type {
        case "Episode", "Season":
            return item.seriesPrimaryImageURL(server: server, maxWidth: 1000)
                ?? item.primaryImageURL(server: server, maxWidth: 1000)
        default:
            return item.primaryImageURL(server: server, maxWidth: 1000)
        }
    }

    private func embyCarouselBackdropImageURL(for item: EmbyItem) -> URL? {
        item.spotlightBackdropImageURL(server: server)
    }

    private var showsSearchButton: Bool {
        guard usesFullBleedHomeCarousel else { return true }
        let baseline = -navigationBarInset
        return titleAnchorOffset >= baseline - 24
    }

    private var supportsNativeSearchBar: Bool {
        if #available(iOS 15.0, *) {
            return true
        }
        return false
    }

    private var usesFullBleedHomeCarousel: Bool {
        !homeCarouselItems.isEmpty
    }

    private var isScrolled: Bool {
        guard usesFullBleedHomeCarousel else { return true }
        let baseline = -navigationBarInset
        return titleAnchorOffset < baseline - 30
    }

    private var useLightToolbar: Bool {
        #if os(iOS)
        if #unavailable(iOS 26.0), isSearchOverlayActive { return false }
        #endif
        return usesFullBleedHomeCarousel && !isScrolled
    }

    private var navigationBarInset: CGFloat {
        var topSafeArea: CGFloat = 0
        if let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
           let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
            topSafeArea = window.safeAreaInsets.top
        }
        let navBarHeight: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 50 : 44
        return topSafeArea + navBarHeight
    }

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Color.clear
                            .frame(height: 0)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: MediaLibraryHeaderOffsetPreferenceKey.self,
                                        value: proxy.frame(in: .named("embyLibraryScroll")).minY
                                    )
                                }
                            )

                        if !homeCarouselItems.isEmpty {
                            MediaHomeCarouselView(
                                items: homeCarouselItems,
                                onSelect: { selectedItem in
                                    guard let entry = homeCarouselEntries.first(where: { $0.id == selectedItem.id }) else {
                                        return
                                    }
                                    openDetails(for: entry.item)
                                },
                                onAction: { selectedItem in
                                    guard let entry = homeCarouselEntries.first(where: { $0.id == selectedItem.id }) else {
                                        return
                                    }
                                    openCarouselItem(entry.item)
                                }
                            )
                        }

                        VStack(alignment: .leading, spacing: 20) {
                            // Continue Watching Section (landscape thumbnails)
                            if !continueWatching.isEmpty {
                                EmbyLandscapeMediaSection(
                                    title: NSLocalizedString("Continue Watching", comment: ""),
                                    systemImage: "clock.fill",
                                    items: continueWatching,
                                    server: server,
                                    onPlay: playEmbyItem,
                                    onOpenDetails: openDetails,
                                    onExit: onExit
                                )
                            }

                            // Next Up Section (landscape thumbnails)
                            if !nextUp.isEmpty {
                                EmbyLandscapeMediaSection(
                                    title: NSLocalizedString("Next Up", comment: ""),
                                    systemImage: "play.rectangle.fill",
                                    items: nextUp,
                                    server: server,
                                    onPlay: playEmbyItem,
                                    onOpenDetails: openDetails,
                                    onExit: onExit
                                )
                            }

                            // Favorites Section
                            if !favorites.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    MediaSectionHeaderLabel(
                                        title: NSLocalizedString("Favorites", comment: ""),
                                        systemImage: "heart.fill"
                                    )
                                        .padding(.horizontal, 16)

                                    EmbyMediaSection(
                                        title: "", // Title already shown above
                                        items: favorites,
                                        server: server,
                                        showProgress: false,
                                        onExit: onExit,
                                        onPlay: playEmbyItem
                                    )
                                }
                            }

                            // My Media (Library Categories)
                            if !libraries.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    MediaSectionHeaderLabel(
                                        title: NSLocalizedString("My Media", comment: ""),
                                        systemImage: "square.grid.2x2.fill"
                                    )
                                        .padding(.horizontal, 16)

                                    LazyVGrid(columns: myMediaColumns, spacing: myMediaGridSpacing) {
                                        ForEach(libraries) { library in
                                            NavigationLink(destination: EmbyLibraryDetailView(server: server, library: library, onExit: onExit, onPlay: playEmbyItem)) {
                                                EmbyLibraryCard(
                                                    library: library,
                                                    server: server,
                                                    previewItems: libraryItems[library.id] ?? [],
                                                    itemCount: libraryCounts[library.id] ?? library.totalItemCount
                                                )
                                                .padding(2)
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                            .contentShape(Rectangle())
                                            .macCardHoverEffect(cornerRadius: 12)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, myMediaGridPadding)
                                    .padding(.vertical, 2)
                                    .onWidthChange { myMediaGridWidth = $0 }
                                }
                            }

                            // Latest items per library
                            ForEach(homeShelfLibraries) { library in
                                if let items = libraryItems[library.id], !items.isEmpty {
                                    EmbyMediaSection(
                                        title: library.name,
                                        items: items,
                                        server: server,
                                        showProgress: false,
                                        itemCount: libraryCounts[library.id] ?? library.totalItemCount,
                                        seeAllDestination: AnyView(EmbyLibraryDetailView(server: server, library: library, onExit: onExit, onPlay: playEmbyItem)),
                                        onExit: onExit,
                                        onPlay: playEmbyItem
                                    )
                                }
                            }
                        }
                        .mediaLibraryHorizontalSafeAreaPadding(isEnabled: usesFullBleedHomeCarousel)
                }
                .padding(.top, usesFullBleedHomeCarousel ? -navigationBarInset : navigationBarInset)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .coordinateSpace(name: "embyLibraryScroll")
            .onPreferenceChange(MediaLibraryHeaderOffsetPreferenceKey.self) { value in
                if initialTitleAnchorOffset == nil {
                    initialTitleAnchorOffset = value
                }
                titleAnchorOffset = value
            }
            .refreshableCompat {
                await loadData(quiet: true)
            }
            loadingOverlay
        }
        #if os(iOS)
        .ignoresSafeArea(edges: usesFullBleedHomeCarousel ? [.top, .horizontal] : [.top])
        #else
        .ignoresSafeArea(edges: usesFullBleedHomeCarousel ? [.top, .horizontal] : [])
        #endif
        .background(Color(.systemBackground))
        .background(
            Group {
                if isShowingSearch || !searchLaunchQuery.isEmpty {
                    NavigationLink(
                        destination: NavigationLazyView {
                            EmbySearchView(server: server, library: nil, initialQuery: searchLaunchQuery, onExit: onExit, onPlay: playEmbyItem)
                        },
                        isActive: $isShowingSearch,
                        label: { EmptyView() }
                    )
                }
                
                if let resolved = autoResolveItem {
                    NavigationLink(
                        destination: autoResolveDestination(for: resolved),
                        isActive: $isNavigatingToAutoResolve,
                        label: { EmptyView() }
                    )
                }
            }
        )
        .appErrorAlert(
            message: $errorMessage,
            title: NSLocalizedString("Couldn't load library", comment: ""),
            retryTitle: NSLocalizedString("Retry", comment: ""),
            retryAction: {
                Task { await loadData() }
            }
        )
        #if os(iOS)
        .modifier(inlineSearch)
        #endif
        .navigationBarTitle(Text(""), displayMode: .inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    ServerTypeIconMark(type: server.type, size: 18)
                    Text(server.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                .foregroundColor(useLightToolbar ? .white : Color(UIColor.label))
            }
        }
        .navBarTransparentCompat(isTransparent: useLightToolbar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: {
                        cleanupTasksAndTransientState()
                        onExit?()
                    }) {
                        AppToolbarIcon.serverExit(
                            legacyStyle: useLightToolbar ? .secondary : .primary
                        )
                    }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                #if os(iOS)
                searchToolbarControl
                #else
                Button(action: {
                    searchLaunchQuery = ""
                    nativeSearchText = ""
                    isShowingSearch = true
                }) {
                    AppToolbarIcon(
                        systemName: "magnifyingglass",
                        style: useLightToolbar ? .secondary : .primary
                    )
                }
                #endif

                if PlatformHelper.isRunningOnMac {
                    Button(action: {
                        Task { await loadData() }
                    }) {
                        AppToolbarIcon(
                            systemName: "arrow.clockwise",
                            style: useLightToolbar ? .secondary : .primary
                        )
                    }
                }
            }
        }
        .onChange(of: overlaySearchQuery) { newQuery in
            scheduleOverlaySearch(for: newQuery)
        }
            .fullScreenCover(item: $playerFile, onDismiss: {
                UIApplication.refreshInterfaceChrome()
                scheduleReloadData(quiet: true, delayNanoseconds: 300_000_000)
            }) { file in
                PlayerView(initialFile: file, playlist: $playerPlaylist)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remotePlaybackStateDidChange)) { notification in
                guard let payload = notification.object as? PlaybackStateRefreshPayload,
                      payload.serverId == server.id else {
                    return
                }
                scheduleReloadData(quiet: true, delayNanoseconds: 100_000_000)
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteFavoriteStateDidChange)) { notification in
                guard let payload = notification.object as? FavoriteStateRefreshPayload,
                      payload.serverId == server.id else {
                    return
                }
                Task { await refreshHomeFavorites() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .remoteItemDidDelete)) { notification in
                guard let payload = notification.object as? RemoteItemDeletePayload,
                      payload.serverId == server.id else { return }
                
                let id = payload.itemId
                continueWatching.removeAll(where: { $0.id == id })
                nextUp.removeAll(where: { $0.id == id })
                favorites.removeAll(where: { $0.id == id })
                for key in libraryItems.keys {
                    libraryItems[key]?.removeAll(where: { $0.id == id })
                }
            }
            .onAppear {
                if libraries.isEmpty {
                    scheduleReloadData(quiet: false)
                } else {
                    Task { await refreshHomeFavorites() }
                }
            }
            .onDisappear {
                cleanupTasksAndTransientState()
            }
            .edgeSwipeToDismiss(action: {
                cleanupTasksAndTransientState()
                onExit?()
            })
        }
    
    @State private var playerFile: VideoFile?
    @State private var playerPlaylist: [VideoFile]?

    private func openCarouselItem(_ item: EmbyItem) {
        if item.isPlayable {
            playEmbyItem(item)
        } else {
            openDetails(for: item)
        }
    }

    private func embyCarouselMetadataSegments(for item: EmbyItem) -> [String] {
        var segments: [String] = []

        if let type = embyCarouselTypeText(for: item.type) {
            segments.append(type)
        }
        if let year = item.productionYear {
            segments.append(String(year))
        }
        if let resolution = item.videoResolutionLabel {
            segments.append(resolution)
        }
        if let rating = item.officialRating, !rating.isEmpty {
            segments.append(rating)
        }
        if let runtime = mediaHomeRuntimeText(minutes: item.runtimeMinutes) {
            segments.append(runtime)
        }
        if let score = item.communityRating, score > 0 {
            segments.append(String(format: "★ %.1f", score))
        }
        if let countText = embyCarouselCountText(for: item) {
            segments.append(countText)
        }

        return Array(segments.prefix(5))
    }

    private func embyCarouselOverview(for item: EmbyItem) -> String? {
        if let overview = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overview.isEmpty {
            return overview
        }
        let genres = item.genres?.prefix(3).joined(separator: " • ") ?? ""
        return genres.isEmpty ? nil : genres
    }

    private func embyCarouselTypeText(for type: String) -> String? {
        switch type {
        case "Movie":
            return NSLocalizedString("Movie", comment: "")
        case "Series":
            return NSLocalizedString("Series", comment: "")
        case "Season":
            return NSLocalizedString("Season", comment: "")
        case "Episode":
            return NSLocalizedString("Episode", comment: "")
        case "Audio", "MusicVideo":
            return NSLocalizedString("Audio", comment: "")
        case "Playlist":
            return NSLocalizedString("Playlist", comment: "")
        case "BoxSet":
            return NSLocalizedString("Collection", comment: "")
        case "Folder":
            return NSLocalizedString("Folder", comment: "")
        default:
            return nil
        }
    }

    private func embyCarouselCountText(for item: EmbyItem) -> String? {
        switch item.type {
        case "Series":
            guard let count = item.childCount, count > 0 else { return nil }
            let unit = count == 1
                ? NSLocalizedString("Season", comment: "")
                : NSLocalizedString("Seasons", comment: "")
            return "\(count) \(unit)"
        case "Season":
            guard let count = item.childCount, count > 0 else { return nil }
            let unit = count == 1
                ? NSLocalizedString("Episode", comment: "")
                : NSLocalizedString("Episodes", comment: "")
            return "\(count) \(unit)"
        default:
            return nil
        }
    }
    
    private func playEmbyItem(_ item: EmbyItem) {
        guard let token = server.accessToken else { return }
        guard let streamUrl = embyPreferredStreamURL(for: item, server: server, token: token) else { return }
        
        let resumeDecision = embyResumeDecision(from: item.userData, runtimeTicks: item.runTimeTicks)
        let startPosition = resumeDecision.startPosition
        
        var videoFile = VideoFile(
            name: item.displayTitle,
            url: streamUrl,
            type: .video,
            size: 0,
            date: Date(),
            isRemote: true,
            duration: embyRuntimeSeconds(item.runTimeTicks),
            lastPlayedPosition: startPosition,
            lastAudioTrack: nil,
            lastSubtitleTrack: nil,
            jellyfinItemId: item.id,
            jellyfinServerId: server.id.uuidString,
            serverType: server.type,
            seriesId: item.seriesId,
            seasonId: item.seasonId
        )
        videoFile.shouldResetRemotePlayedStateOnPlaybackStart = resumeDecision.shouldResetPlayedStateOnStart
        
        // Inject server metadata for MediaInfo display
        applyEmbyPreferredSourceMetadata(from: item, to: &videoFile)
        
        // Play immediately with single-item playlist
        self.playerPlaylist = [videoFile]
        self.playerFile = videoFile
        
        // Background: fetch season episodes and update playlist
        if item.type == "Episode", let seriesId = item.seriesId, let seasonId = item.seasonId,
           let userId = server.userId {
            Task {
                do {
                    let episodes = try await EmbyService.shared.getEpisodes(
                        server: server, userId: userId, token: token,
                        seriesId: seriesId, seasonId: seasonId
                    )
                    let files = episodes.compactMap { ep -> VideoFile? in
                        guard let url = embyPreferredStreamURL(for: ep, server: server, token: token) else { return nil }
                        var title = ep.name
                        if let idx = ep.indexNumber {
                            title = "\(idx). \(ep.name)"
                        }
                        let resumeDecision = embyResumeDecision(from: ep.userData, runtimeTicks: ep.runTimeTicks)
                        var file = VideoFile(
                            name: title,
                            url: url,
                            type: .video,
                            size: 0,
                            date: Date(),
                            isRemote: true,
                            duration: ep.runTimeTicks.map { Double($0) / 10_000_000.0 },
                            lastPlayedPosition: resumeDecision.startPosition,
                            jellyfinItemId: ep.id,
                            jellyfinServerId: server.id.uuidString,
                            serverType: server.type,
                            seriesId: ep.seriesId,
                            seasonId: ep.seasonId
                        )
                        file.shouldResetRemotePlayedStateOnPlaybackStart = resumeDecision.shouldResetPlayedStateOnStart
                        applyEmbyPreferredSourceMetadata(from: ep, to: &file)
                        return file
                    }
                    if !files.isEmpty {
                        await MainActor.run {
                            self.playerPlaylist = files
                        }
                    }
                } catch {
                    print("[Emby] Background playlist fetch failed: \(error)")
                }
            }
        }
    }
    
    private func cleanupTasksAndTransientState() {
        loadDataTask?.cancel()
        loadDataTask = nil
        summaryTask?.cancel()
        summaryTask = nil
        overlaySearchTask?.cancel()
        overlaySearchTask = nil
        needsLogin = false
        isLoading = false
    }

    #if os(iOS)
    @ViewBuilder
    private var searchToolbarControl: some View {
        if #unavailable(iOS 26.0) {
            Button { isSearchOverlayActive = true } label: {
                AppToolbarIcon(systemName: "magnifyingglass")
            }
            .accessibilityLabel(NSLocalizedString("Search", comment: ""))
        }
    }

    private func submitInlineSearch(_ submitted: String) {
        SearchHistoryService.shared.addHistory(submitted, for: server.id)
        scheduleOverlaySearch(for: submitted, immediate: true)
    }

    private var inlineSearch: some ViewModifier {
        LibraryInlineSearchModifier(
            isPresented: $isSearchOverlayActive,
            query: $overlaySearchQuery,
            placeholder: NSLocalizedString("Search movies, TV shows...", comment: ""),
            serverId: server.id.uuidString,
            onSubmit: submitInlineSearch
        ) {
            embySearchOverlayResults
        }
    }
    #endif

    @ViewBuilder
    private var loadingOverlay: some View {
        if isLoading {
            VStack {
                ProgressView()
                    .scaleEffect(1.5)
                if needsLogin {
                    Text(NSLocalizedString("Logging in...", comment: ""))
                        .foregroundColor(.secondary)
                        .padding(.top, 8)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Expandable Search Overlay Logic
    
    @ViewBuilder
    private var embySearchOverlayResults: some View {
        if isOverlaySearching {
            VStack(spacing: 16) {
                Spacer(minLength: 40)
                ProgressView()
                    .scaleEffect(1.2)
                Text(NSLocalizedString("Searching...", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        } else if overlaySearchResults.isEmpty && !overlaySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(spacing: 12) {
                Spacer(minLength: 40)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                Text(NSLocalizedString("No results found", comment: ""))
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        } else {
            let topHits = Array(overlaySearchResults.prefix(10))
            VStack(alignment: .leading, spacing: 20) {
                if !topHits.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(NSLocalizedString("Top Suggestions", comment: ""))
                            .font(.headline)
                            .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(topHits) { item in
                                    NavigationLink(destination: NavigationLazyView {
                                        embyNavigationDestination(server: server, item: item, onExit: onExit, onPlay: playEmbyItem)
                                    }) {
                                        EmbyPosterCard(item: item, server: server, showProgress: false, onPlay: { playEmbyItem(item) })
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                    
                    Divider()
                        .padding(.horizontal, 16)
                }

                if !overlaySearchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(NSLocalizedString("All Results", comment: ""))
                            .font(.headline)
                            .padding(.horizontal, 16)

                        LazyVStack(spacing: 12) {
                            ForEach(overlaySearchResults) { item in
                                NavigationLink(destination: NavigationLazyView {
                                    embyNavigationDestination(server: server, item: item, onExit: onExit, onPlay: playEmbyItem)
                                }) {
                                    EmbyLibraryListRow(item: item, server: server, onPlay: { playEmbyItem(item) })
                                }
                                .buttonStyle(PlainButtonStyle())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
    }

    private func scheduleOverlaySearch(for rawQuery: String, immediate: Bool = false) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        overlaySearchTask?.cancel()

        guard !query.isEmpty else {
            overlaySearchResults = []
            isOverlaySearching = false
            return
        }

        let delay: UInt64 = immediate ? 0 : 300_000_000
        isOverlaySearching = true

        overlaySearchTask = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }

            do {
                guard let token = server.accessToken,
                      let userId = server.userId else {
                    await MainActor.run {
                        self.isOverlaySearching = false
                    }
                    return
                }

                let results = try await embyService.searchItems(
                    server: server,
                    userId: userId,
                    token: token,
                    query: query
                )

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.overlaySearchResults = results.stableUniqued()
                    self.isOverlaySearching = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isOverlaySearching = false
                }
            }
        }
    }

    private func scheduleReloadData(quiet: Bool = false, delayNanoseconds: UInt64 = 0) {
        loadDataTask?.cancel()
        loadDataTask = Task {
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else { return }
            await loadData(quiet: quiet)
        }
    }

    @MainActor
    private func syncLatestServerStateIfNeeded() {
        let hydrated = networkService.hydratedServer(from: server)
        if hydrated.accessToken != server.accessToken ||
            hydrated.userId != server.userId ||
            hydrated.username != server.username ||
            hydrated.passwordSecret != server.passwordSecret {
            self.server = hydrated
        }
    }

    private func loadData(quiet: Bool = false, retryOnUnauthorized: Bool = true) async {
        guard !Task.isCancelled else { return }

        await syncLatestServerStateIfNeeded()

        guard !server.address.isEmpty else {
            await MainActor.run {
                if !quiet {
                    errorMessage = NSLocalizedString("Invalid server address", comment: "")
                    isLoading = false
                }
                needsLogin = false
            }
            return
        }
        
        // If no token, try to login first
        if server.accessToken == nil || server.userId == nil {
            await performLogin(quiet: quiet)
            guard !Task.isCancelled else { return }
        }
        
        guard let token = server.accessToken, let userId = server.userId else {
            await MainActor.run {
                if !quiet {
                    errorMessage = NSLocalizedString("Login failed. Please check credentials.", comment: "")
                    isLoading = false
                }
                needsLogin = false
            }
            return
        }
        
        await MainActor.run {
            if !quiet { isLoading = true }
            errorMessage = nil
            needsLogin = false
        }
        
        do {
            async let resolvedTarget = resolveAutoNavigationTargetIfNeeded(userId: userId, token: token)

            // Load libraries
            let libs = try await embyService.getLibraries(server: server, userId: userId, token: token)
            guard !Task.isCancelled else { return }
            
            // Load continue watching
            let contWatching = try await embyService.getContinueWatching(server: server, userId: userId, token: token)
            guard !Task.isCancelled else { return }
            
            // Load next up
            let nextUpItems = try await embyService.getNextUp(server: server, userId: userId, token: token)
            guard !Task.isCancelled else { return }
            
            // Load favorites
            let favoriteItems = try await embyService.getFavorites(server: server, userId: userId, token: token)
            guard !Task.isCancelled else { return }
            
            // Load shelf items for each library
            var libItems: [String: [EmbyItem]] = [:]
            for library in libs {
                guard !Task.isCancelled else { return }
                let items = try await embyService.getHomeShelfItems(
                    server: server,
                    userId: userId,
                    token: token,
                    library: library
                )
                libItems[library.id] = items
            }

            let autoTarget = await resolvedTarget
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                libraries = libs
                continueWatching = contWatching
                nextUp = nextUpItems
                favorites = favoriteItems
                libraryItems = libItems
                if let autoTarget = autoTarget {
                    autoResolveItem = autoTarget.item
                    autoResolveSeasonId = autoTarget.seasonId
                    autoResolveEpisodeId = autoTarget.episodeId
                    isNavigatingToAutoResolve = true
                }
                isLoading = false
                needsLogin = false
            }

            summaryTask?.cancel()
            summaryTask = Task {
                await MediaServerSummaryService.shared.refreshSummary(for: server)
                guard !Task.isCancelled else { return }
                await withTaskGroup(of: (String, Int?).self) { group in
                    for lib in libs {
                        group.addTask {
                            guard !Task.isCancelled else { return (lib.id, nil) }
                            let count = await embyService.getLibraryItemCount(
                                server: server,
                                userId: userId,
                                token: token,
                                libraryId: lib.id,
                                libraryType: lib.libraryType
                            )
                            return (lib.id, count)
                        }
                    }
                    for await (libId, count) in group {
                        guard !Task.isCancelled else { return }
                        if let count = count {
                            await MainActor.run {
                                libraryCounts[libId] = count
                            }
                        }
                    }
                }
            }
        } catch EmbyError.unauthorized {
            guard !Task.isCancelled else { return }
            guard retryOnUnauthorized else {
                await MainActor.run {
                    if !quiet {
                        errorMessage = NSLocalizedString("Session expired. Please checking credentials.", comment: "")
                        isLoading = false
                    }
                    needsLogin = false
                }
                return
            }

            // Token invalid/expired, clear it and retry login
            await MainActor.run {
                var updatedServer = server
                updatedServer.accessToken = nil
                updatedServer.userId = nil
                server = updatedServer
                networkService.clearServerAuthTokens(for: server.id)
            }

            await performLogin(quiet: quiet)
            guard !Task.isCancelled else { return }
            
            if server.accessToken != nil {
                await loadData(quiet: quiet, retryOnUnauthorized: false)
            } else {
                await MainActor.run {
                    if !quiet && errorMessage == nil {
                        errorMessage = NSLocalizedString("Session expired. Please checking credentials.", comment: "")
                    }
                    isLoading = false
                    needsLogin = false
                }
            }
        } catch {
            if isCancellationError(error) || Task.isCancelled {
                await MainActor.run {
                    if !quiet {
                        isLoading = false
                    }
                    needsLogin = false
                }
                return
            }
            await MainActor.run {
                if !quiet {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
                needsLogin = false
            }
        }
    }

    private func resolveAutoNavigationTargetIfNeeded(userId: String, token: String) async -> AutoResolveTarget? {
        guard let targetId = targetItemIdToResolve, autoResolveItem == nil else {
            return nil
        }
        return await embyResolvedNavigationTarget(server: server, userId: userId, itemId: targetId, token: token)
    }

    private func refreshHomeFavorites() async {
        guard !Task.isCancelled else { return }
        await syncLatestServerStateIfNeeded()
        guard let token = server.accessToken,
              let userId = server.userId else {
            return
        }

        do {
            let favoriteItems = try await embyService.getFavorites(server: server, userId: userId, token: token)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                favorites = favoriteItems
            }
        } catch {
            print("[Emby] Failed to refresh home favorites: \(error)")
        }
    }
    
    private func performLogin(quiet: Bool = false) async {
        guard !Task.isCancelled else { return }
        guard let username = server.username, !username.isEmpty,
              let password = server.passwordSecret, !password.isEmpty else {
            await MainActor.run {
                if !quiet {
                    errorMessage = NSLocalizedString("No credentials. Please edit server and add username/password.", comment: "")
                    isLoading = false
                }
                needsLogin = false
            }
            return
        }
        
        await MainActor.run {
            if !quiet {
                isLoading = true
                needsLogin = true
            }
        }
        
        do {
            let result = try await embyService.login(server: server, username: username, password: password)
            guard !Task.isCancelled else {
                await MainActor.run {
                    needsLogin = false
                }
                return
            }
            
            print("[Emby] Login successful, token received")
            
            // Update server with token
            var updatedServer = server
            updatedServer.accessToken = result.accessToken
            updatedServer.userId = result.user.id
            
            await MainActor.run {
                server = updatedServer
                networkService.updateServer(updatedServer)
                needsLogin = false
            }
        } catch {
            guard !Task.isCancelled else {
                await MainActor.run {
                    needsLogin = false
                }
                return
            }
            print("[Emby] Login failed: \(error)")
            await MainActor.run {
                if !quiet {
                    errorMessage = NSLocalizedString("Login failed: ", comment: "") + error.localizedDescription
                    isLoading = false
                }
                needsLogin = false
            }
        }
    }

    @ViewBuilder
    private func autoResolveDestination(for item: EmbyItem) -> some View {
        if embyUsesListPage(item) {
            EmbyContainerListView(server: server, container: item, onExit: onExit, onPlay: playEmbyItem)
        } else {
            EmbyItemDetailView(
                server: server,
                item: item,
                onExit: onExit,
                initialSeasonId: autoResolveSeasonId,
                initialEpisodeId: autoResolveEpisodeId
            )
        }
    }

    private func openDetails(for item: EmbyItem) {
        if item.type != "Episode" && item.type != "Season" {
            autoResolveSeasonId = nil
            autoResolveEpisodeId = nil
            autoResolveItem = item
            isNavigatingToAutoResolve = true
            return
        }

        guard let token = server.accessToken, !token.isEmpty,
              let userId = server.userId, !userId.isEmpty else {
            autoResolveSeasonId = nil
            autoResolveEpisodeId = nil
            autoResolveItem = item
            isNavigatingToAutoResolve = true
            return
        }

        Task {
            let resolvedTarget = await embyResolvedNavigationTarget(server: server, userId: userId, itemId: item.id, token: token)
                ?? (item, nil, nil)
            await MainActor.run {
                autoResolveItem = resolvedTarget.item
                autoResolveSeasonId = resolvedTarget.seasonId
                autoResolveEpisodeId = resolvedTarget.episodeId
                isNavigatingToAutoResolve = true
            }
        }
    }
}

func embyUsesListPage(_ item: EmbyItem) -> Bool {
    item.type == "BoxSet" || item.type == "Playlist"
}

@ViewBuilder
func embyNavigationDestination(
    server: ServerConfig,
    item: EmbyItem,
    onExit: (() -> Void)? = nil,
    onPlay: ((EmbyItem) -> Void)? = nil
) -> some View {
    if embyUsesListPage(item) {
        EmbyContainerListView(server: server, container: item, onExit: onExit, onPlay: onPlay)
    } else {
        EmbyItemDetailView(server: server, item: item, onExit: onExit)
    }
}

// MARK: - Emby Media Section

struct EmbyMediaSection: View {
    let title: String
    let items: [EmbyItem]
    let server: ServerConfig
    let showProgress: Bool
    var itemCount: Int? = nil
    var seeAllDestination: AnyView? = nil
    var onExit: (() -> Void)? = nil
    var onPlay: ((EmbyItem) -> Void)? = nil

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsHeader: Bool {
        !trimmedTitle.isEmpty || seeAllDestination != nil
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if !trimmedTitle.isEmpty {
                        Text(trimmedTitle)
                            .font(.title2)
                            .fontWeight(.bold)
                    }

                    if let count = itemCount, count > 0 {
                        Text(MediaCountFormatter.formatCount(count))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Color(UIColor.tertiarySystemFill))
                            .clipShape(Capsule())
                    }

                    Spacer()

                    if let destination = seeAllDestination {
                        NavigationLink(destination: destination) {
                            Text(NSLocalizedString("See All", comment: ""))
                                .font(.subheadline)
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .padding(.horizontal)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(destination: embyNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                            EmbyPosterCard(item: item, server: server, showProgress: showProgress, onPlay: { onPlay?(item) })
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal)
            }
            .duoMediaShelfViewport()
        }
    }
}

// MARK: - Emby Poster Card

struct EmbyPosterCard: View {
    let item: EmbyItem
    let server: ServerConfig
    var showProgress: Bool
    var cardWidth: CGFloat = MediaCardMetrics.posterWidth
    var onPlay: (() -> Void)? = nil

    private var posterHeight: CGFloat { cardWidth * 1.5 }
    @ObservedObject private var offlineIndex = OfflineMediaIndexStore.shared
    @ObservedObject private var remotePlaybackState = RemotePlaybackStateStore.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                // Poster Image
                RemoteImage(url: item.primaryImageURL(server: server))
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(width: cardWidth, height: posterHeight)
                    .clipped()
                    .cornerRadius(8)
                
                // Gradient overlay
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(height: 60)
                .cornerRadius(8, corners: [.bottomLeft, .bottomRight])
                .allowsHitTesting(false)
                
                // Metadata Overlay
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let rating = item.communityRating, rating > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                Text(String(format: "%.1f", rating))
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(.yellow)
                        }
                        
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .allowsHitTesting(false)

                if let playbackProgressSnapshot = playbackProgressSnapshot {
                    PlaybackProgressBadge(
                        snapshot: playbackProgressSnapshot,
                        diameter: 16,
                        usesDarkBackground: true,
                        symbolName: "play.fill",
                        symbolSize: 8
                    )
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: cardWidth, height: posterHeight)
            
            // Content Text with fixed height to ensure uniform grid item sizing
            VStack(alignment: .leading, spacing: 2) {
                // Title
                Text(appLineBreakableTitle(item.displayTitle))
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .layoutPriority(1)

                // Subtitle
                DownloadedMetadataLine(
                    text: posterSubtitleText,
                    isDownloaded: isDownloaded,
                    font: .caption2,
                    iconSize: 10
                )

                Spacer(minLength: 0)
            }
            .frame(height: MediaCardMetrics.posterTextHeight, alignment: .topLeading)
        }
        .frame(width: cardWidth)
        .contentShape(Rectangle())
        .modifier(EmbyMediaContextMenuModifier(item: item, server: server, onPlay: onPlay))
    }
    
    private func childCountLabel(count: Int) -> String {
        switch item.type {
        case "Series":
            return count == 1 ? "1 \(NSLocalizedString("Season", comment: "Singular for season count"))" : "\(count) \(NSLocalizedString("Seasons", comment: "Plural for season count"))"
        case "Season":
            return count == 1 ? String(format: NSLocalizedString("%d Episode", comment: "Singular for episode count"), 1) : String(format: NSLocalizedString("%d Episodes", comment: "Plural for episode count"), count)
        default:
            return "\(count)"
        }
    }

    private var posterSubtitleText: String? {
        item.compactPosterMetadataLine
    }

    private var isDownloaded: Bool {
        offlineIndex.isDownloaded(serverId: server.id, remoteItemId: item.id)
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        let effectiveUserData = embyEffectiveUserData(
            for: item,
            serverId: server.id,
            remotePlaybackState: remotePlaybackState
        )
        return PlaybackProgressSnapshot.fromPercent(
            effectiveUserData?.playedPercentage,
            played: effectiveUserData?.played ?? false
        )
    }
}

// MARK: - Emby Thumb Card (16:9)

struct EmbyThumbCard: View {
    let item: EmbyItem
    let server: ServerConfig
    var showProgress: Bool = true
    var cardWidth: CGFloat? = nil
    var onPlay: (() -> Void)? = nil

    private var fixedWidth: CGFloat? { cardWidth }
    private var defaultCardHeight: CGFloat { (fixedWidth ?? MediaCardMetrics.landscapeWidth) * 9 / 16 }
    @ObservedObject private var offlineIndex = OfflineMediaIndexStore.shared
    @ObservedObject private var remotePlaybackState = RemotePlaybackStateStore.shared

    #if targetEnvironment(macCatalyst) || os(macOS)
    @State private var internalCardHovered = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnailContent

            VStack(alignment: .leading, spacing: 2) {
                Text(appLineBreakableTitle(item.displayTitle))
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .layoutPriority(1)

                DownloadedMetadataLine(
                    text: posterSubtitleText,
                    isDownloaded: isDownloaded,
                    font: .caption2,
                    iconSize: 10
                )

                Spacer(minLength: 0)
            }
            .frame(height: MediaCardMetrics.posterTextHeight, alignment: .topLeading)
        }
        .modifier(EmbyCardWidthModifier(width: fixedWidth))
        .contentShape(Rectangle())
        .modifier(EmbyMediaContextMenuModifier(item: item, server: server, onPlay: onPlay))
        #if targetEnvironment(macCatalyst) || os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                internalCardHovered = hovering
            }
        }
        #endif
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        ZStack(alignment: .bottomTrailing) {
            if let fixedWidth {
                RemoteImage(url: item.landscapeImageURL(server: server))
                    .aspectRatio(16/9, contentMode: .fill)
                    .frame(width: fixedWidth, height: defaultCardHeight)
                    .clipped()
                    .cornerRadius(8)
            } else {
                Color.clear
                    .aspectRatio(16/9, contentMode: .fit)
                    .overlay(
                        RemoteImage(url: item.landscapeImageURL(server: server))
                            .aspectRatio(16/9, contentMode: .fill)
                    )
                    .clipped()
                    .cornerRadius(8)
            }

            // Gradient overlay
            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(height: 48)
            .cornerRadius(8, corners: [.bottomLeft, .bottomRight])
            .allowsHitTesting(false)

            // Metadata Overlay
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let rating = item.communityRating, rating > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(.yellow)
                    }

                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
            .allowsHitTesting(false)

            if let playbackProgressSnapshot = playbackProgressSnapshot {
                PlaybackProgressBadge(
                    snapshot: playbackProgressSnapshot,
                    diameter: MediaCardMetrics.landscapePlayBadgeSize,
                    usesDarkBackground: true,
                    symbolName: "play.fill",
                    symbolSize: 14
                )
                .padding(.trailing, 8)
                .padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
            } else {
                #if targetEnvironment(macCatalyst) || os(macOS)
                MacPosterHoverPlayOverlay(
                    isCardHovered: internalCardHovered,
                    onPlay: onPlay,
                    buttonSize: MediaCardMetrics.landscapePlayBadgeSize,
                    cornerRadius: 8
                )
                .padding(.trailing, 8)
                .padding(.bottom, 8)
                #endif
            }
        }
        .modifier(EmbyThumbnailFrameModifier(width: fixedWidth, height: defaultCardHeight))
    }

    private func childCountLabel(count: Int) -> String {
        switch item.type {
        case "Series":
            return count == 1 ? "1 \(NSLocalizedString("Season", comment: "Singular for season count"))" : "\(count) \(NSLocalizedString("Seasons", comment: "Plural for season count"))"
        case "Season":
            return count == 1 ? String(format: NSLocalizedString("%d Episode", comment: "Singular for episode count"), 1) : String(format: NSLocalizedString("%d Episodes", comment: "Plural for episode count"), count)
        default:
            return "\(count)"
        }
    }

    private var posterSubtitleText: String? {
        item.compactPosterMetadataLine
    }

    private var isDownloaded: Bool {
        offlineIndex.isDownloaded(serverId: server.id, remoteItemId: item.id)
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        let effectiveUserData = embyEffectiveUserData(
            for: item,
            serverId: server.id,
            remotePlaybackState: remotePlaybackState
        )
        return PlaybackProgressSnapshot.fromPercent(
            effectiveUserData?.playedPercentage,
            played: effectiveUserData?.played ?? false
        )
    }
}

private struct EmbyThumbnailFrameModifier: ViewModifier {
    let width: CGFloat?
    let height: CGFloat

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, height: height)
        } else {
            content.frame(maxWidth: .infinity)
        }
    }
}

private struct EmbyCardWidthModifier: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width)
        } else {
            content.frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Emby Landscape Section

struct EmbyLandscapeMediaSection: View {
    let title: String
    let systemImage: String?
    let items: [EmbyItem]
    let server: ServerConfig
    let onPlay: (EmbyItem) -> Void
    let onOpenDetails: (EmbyItem) -> Void
    var onExit: (() -> Void)? = nil
    @ObservedObject private var offlineIndex = OfflineMediaIndexStore.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaSectionHeaderLabel(title: title, systemImage: systemImage)
                .padding(.horizontal)
            
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        sectionCard(for: item)
                    }
                }
                .padding(.horizontal)
            }
            .duoMediaShelfViewport()
        }
    }

    @ViewBuilder
    private func sectionCard(for item: EmbyItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.isPlayable {
                Button(action: {
                    onPlay(item)
                }) {
                    EmbyLandscapeMediaCard(item: item, server: server, showsText: false)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Button(action: {
                    onOpenDetails(item)
                }) {
                    EmbyLandscapeMediaCard(item: item, server: server, showsText: false)
                }
                .buttonStyle(PlainButtonStyle())
            }

            Button(action: {
                onOpenDetails(item)
            }) {
                EmbyLandscapeMediaCardText(
                    title: item.displayTitle,
                    subtitle: item.metadataLine,
                    isDownloaded: offlineIndex.isDownloaded(serverId: server.id, remoteItemId: item.id)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(width: MediaCardMetrics.landscapeWidth, alignment: .leading)
    }
}

// MARK: - Emby Landscape Card

struct EmbyLandscapeMediaCard: View {
    let item: EmbyItem
    let server: ServerConfig
    var showsText: Bool = true
    var onPlay: (() -> Void)? = nil

    private let cardWidth = MediaCardMetrics.landscapeWidth
    private let cardHeight = MediaCardMetrics.landscapeHeight
    @ObservedObject private var remotePlaybackState = RemotePlaybackStateStore.shared
    
    #if targetEnvironment(macCatalyst) || os(macOS)
    @State private var internalCardHovered = false
    #endif
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                // Backdrop/Primary Image with fallback (16:9)
                RemoteImage(url: item.landscapeImageURL(server: server)) // Removed RemoteImage
                    .aspectRatio(16/9, contentMode: .fill)
                    .frame(width: cardWidth, height: cardHeight)
                    .clipped()
                    .cornerRadius(8)
                
                if let playbackProgressSnapshot = playbackProgressSnapshot {
                    PlaybackProgressBadge(
                        snapshot: playbackProgressSnapshot,
                        diameter: MediaCardMetrics.landscapePlayBadgeSize,
                        usesDarkBackground: true,
                        symbolName: "play.fill",
                        symbolSize: 14
                    )
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
                } else {
                    #if targetEnvironment(macCatalyst) || os(macOS)
                    MacPosterHoverPlayOverlay(
                        isCardHovered: internalCardHovered,
                        onPlay: onPlay,
                        buttonSize: MediaCardMetrics.landscapePlayBadgeSize,
                        cornerRadius: 8
                    )
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
                    #else
                    Circle()
                        .fill(Color.black.opacity(0.6))
                        .frame(width: MediaCardMetrics.landscapePlayBadgeSize, height: MediaCardMetrics.landscapePlayBadgeSize)
                        .overlay(
                            Image(systemName: "play.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 14))
                        )
                        .padding(.trailing, 10)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                    #endif
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            
            if showsText {
                Text(item.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .foregroundColor(.primary)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: cardWidth)
        .contentShape(Rectangle())
        .modifier(EmbyMediaContextMenuModifier(item: item, server: server, onPlay: onPlay))
        #if targetEnvironment(macCatalyst) || os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                internalCardHovered = hovering
            }
        }
        #endif
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        let effectiveUserData = embyEffectiveUserData(
            for: item,
            serverId: server.id,
            remotePlaybackState: remotePlaybackState
        )
        return PlaybackProgressSnapshot.fromPercent(
            effectiveUserData?.playedPercentage,
            played: effectiveUserData?.played ?? false
        )
    }
}

private struct EmbyLandscapeMediaCardText: View {
    let title: String
    let subtitle: String?
    let isDownloaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(appLineBreakableTitle(title))
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .layoutPriority(1)

            DownloadedMetadataLine(
                text: subtitle,
                isDownloaded: isDownloaded,
                font: .caption2,
                iconSize: 10
            )

            Spacer(minLength: 0)
        }
        .frame(width: MediaCardMetrics.landscapeWidth, height: MediaCardMetrics.posterTextHeight, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

// MARK: - Emby Library Card

struct EmbyLibraryCard: View {
    let library: EmbyLibrary
    let server: ServerConfig
    let previewItems: [EmbyItem]
    var itemCount: Int? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var cardHeight: CGFloat {
        MediaCardMetrics.libraryShelfCardHeight(horizontalSizeClass: horizontalSizeClass)
    }

    private var previewImageURL: URL? {
        previewItems.lazy.compactMap { $0.landscapeImageURL(server: server) }.first
    }

    private var libraryImageURL: URL? {
        return library.primaryImageURL(server: server, maxWidth: 800)
    }

    private var fallbackGradient: LinearGradient {
        switch library.libraryType {
        case .movies:
            return LinearGradient(
                colors: [Color(red: 0.18, green: 0.24, blue: 0.44), Color(red: 0.09, green: 0.12, blue: 0.23)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .tvShows:
            return LinearGradient(
                colors: [Color(red: 0.20, green: 0.35, blue: 0.31), Color(red: 0.08, green: 0.18, blue: 0.17)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .music:
            return LinearGradient(
                colors: [Color(red: 0.33, green: 0.28, blue: 0.16), Color(red: 0.15, green: 0.12, blue: 0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .photos:
            return LinearGradient(
                colors: [Color(red: 0.37, green: 0.22, blue: 0.14), Color(red: 0.16, green: 0.10, blue: 0.07)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .collections:
            return LinearGradient(
                colors: [Color(red: 0.29, green: 0.26, blue: 0.42), Color(red: 0.13, green: 0.11, blue: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .playlists:
            return LinearGradient(
                colors: [Color(red: 0.18, green: 0.34, blue: 0.42), Color(red: 0.08, green: 0.16, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .mixed:
            return LinearGradient(
                colors: [Color(red: 0.23, green: 0.24, blue: 0.27), Color(red: 0.11, green: 0.11, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                Group {
                    if let previewImageURL {
                        RemoteImage(url: previewImageURL)
                            .scaledToFill()
                    } else if let libraryImageURL {
                        RemoteImage(url: libraryImageURL)
                            .scaledToFill()
                    } else {
                        fallbackGradient
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }

            LinearGradient(
                colors: colorScheme == .light
                    ? [Color.black.opacity(0.08), Color.black.opacity(0.45)]
                    : [Color.black.opacity(0.14), Color.black.opacity(0.8)],
                startPoint: .top,
                endPoint: .bottom
            )

            HStack(spacing: 10) {
                Image(systemName: library.libraryType.icon)
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(library.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if let count = itemCount ?? library.totalItemCount, count > 0 {
                        Text(MediaCountFormatter.format(count: count, libraryType: library.libraryType))
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                }
            }
            .foregroundColor(.white)
            .padding(12)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .frame(height: cardHeight)
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    colorScheme == .light
                        ? Color.black.opacity(0.08)
                        : Color.white.opacity(0.12),
                    lineWidth: 0.8
                )
        )
        .contentShape(Rectangle())
    }
}

private struct EmbySpecialLibraryCard: View {
    let library: EmbyLibrary
    let server: ServerConfig
    let previewItems: [EmbyItem]

    private var badgeTitle: String {
        switch library.libraryType {
        case .collections:
            return NSLocalizedString("Collections", comment: "")
        case .playlists:
            return NSLocalizedString("Playlists", comment: "")
        default:
            return library.name
        }
    }

    private var fallbackGradient: LinearGradient {
        switch library.libraryType {
        case .collections:
            return LinearGradient(
                colors: [Color(red: 0.28, green: 0.25, blue: 0.43), Color(red: 0.12, green: 0.10, blue: 0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .playlists:
            return LinearGradient(
                colors: [Color(red: 0.18, green: 0.33, blue: 0.42), Color(red: 0.08, green: 0.17, blue: 0.21)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [Color(red: 0.23, green: 0.24, blue: 0.27), Color(red: 0.11, green: 0.11, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    var body: some View {
        ZStack {
            fallbackGradient

            RoundedRectangle(cornerRadius: 18)
                .fill(Color.white.opacity(0.05))
                .padding(14)

            HStack(spacing: 18) {
                HStack(spacing: -28) {
                    if previewItems.isEmpty {
                        ForEach(0..<3, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color.white.opacity(0.14 - Double(index) * 0.03))
                                .frame(width: 62, height: 92)
                                .overlay(
                                    Image(systemName: library.libraryType == .playlists ? "music.note.list" : "square.stack")
                                        .font(.system(size: 18, weight: .semibold))
                                        .foregroundColor(.white.opacity(index == 0 ? 0.88 : 0.45))
                                )
                                .rotationEffect(.degrees(Double(index - 1) * 6))
                        }
                    } else {
                        ForEach(Array(previewItems.enumerated()), id: \.offset) { index, item in
                            RemoteImage(url: item.primaryImageURL(server: server, maxWidth: 240))
                                .aspectRatio(2 / 3, contentMode: .fill)
                                .frame(width: 62, height: 92)
                                .background(Color.white.opacity(0.08))
                                .cornerRadius(14)
                                .clipped()
                                .rotationEffect(.degrees(Double(index - 1) * 6))
                        }
                    }
                }
                .padding(.leading, 8)

                VStack(alignment: .leading, spacing: 8) {
                    Text(badgeTitle.uppercased())
                        .font(.caption2)
                        .fontWeight(.bold)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.white.opacity(0.14))
                        .cornerRadius(999)

                    Text(library.name)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .lineLimit(2)

                    Text(
                        library.libraryType == .playlists
                            ? NSLocalizedString("Open manual queues and playlist bundles.", comment: "")
                            : NSLocalizedString("Browse grouped sets with stacked poster previews.", comment: "")
                    )
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.76))
                    .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .frame(height: 140)
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
        )
        .contentShape(Rectangle())
    }
}

struct EmbyContainerListView: View {
    let server: ServerConfig
    let container: EmbyItem
    var onExit: (() -> Void)? = nil
    var onPlay: ((EmbyItem) -> Void)? = nil

    @State private var items: [EmbyItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var displayMode: LibraryDisplayMode = .poster
    
    @State private var currentStartIndex = 0
    @State private var hasMoreItems = true
    @State private var isPaginating = false
    private let pageSize = 100
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.presentationMode) private var presentationMode

    private var columns: [GridItem] {
        switch displayMode {
        case .poster:
            return MediaCardMetrics.libraryPosterColumns(horizontalSizeClass: horizontalSizeClass)
        case .thumb:
            return MediaCardMetrics.libraryThumbColumns(horizontalSizeClass: horizontalSizeClass)
        case .list:
            return []
        }
    }
    private var gridSpacing: CGFloat { MediaCardMetrics.libraryGridSpacing(horizontalSizeClass: horizontalSizeClass) }
    private var gridPadding: CGFloat { MediaCardMetrics.libraryGridPadding(horizontalSizeClass: horizontalSizeClass) }
    private var posterCardWidth: CGFloat { MediaCardMetrics.libraryPosterWidth(horizontalSizeClass: horizontalSizeClass) }
    private var thumbCardWidth: CGFloat { MediaCardMetrics.libraryThumbWidth(horizontalSizeClass: horizontalSizeClass) }

    var body: some View {
        ZStack {
            ScrollView {
                switch displayMode {
                case .poster:
                    MediaLibraryCardGrid(columns: columns, spacing: gridSpacing, legacyCardWidth: posterCardWidth) { columnWidth in
                        ForEach(items) { item in
                            NavigationLink(destination: embyNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                                EmbyPosterCard(item: item, server: server, showProgress: false, cardWidth: columnWidth, onPlay: { onPlay?(item) })
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        
                        if hasMoreItems && !items.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                                .onAppear {
                                    Task { await loadItems(isPagination: true) }
                                }
                        }
                    }
                    .padding(.horizontal, gridPadding)
                    .padding(.vertical, gridPadding)
                case .thumb:
                    LazyVGrid(columns: columns, spacing: gridSpacing) {
                        ForEach(items) { item in
                            NavigationLink(destination: embyNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                                EmbyThumbCard(item: item, server: server, showProgress: false, cardWidth: nil, onPlay: { onPlay?(item) })
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                        
                        if hasMoreItems && !items.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                                .onAppear {
                                    Task { await loadItems(isPagination: true) }
                                }
                        }
                    }
                    .padding(.horizontal, gridPadding)
                    .padding(.vertical, gridPadding)
                case .list:
                    LazyVStack(spacing: 12) {
                        ForEach(items) { item in
                            NavigationLink(destination: embyNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                                EmbyLibraryListRow(item: item, server: server, onPlay: { onPlay?(item) })
                            }
                            .buttonStyle(PlainButtonStyle())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        
                        if hasMoreItems && !items.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                                .onAppear {
                                    Task { await loadItems(isPagination: true) }
                                }
                        }
                    }
                    .padding()
                }

                if !isLoading && items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "tray")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Text(NSLocalizedString("No items in this container", comment: ""))
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                    .padding(.bottom, 24)
                }
            }

            if isLoading {
                ProgressView()
            }

        }
        .navigationTitle(container.name)
        .navigationBarTitleDisplayMode(.inline)
        .appErrorAlert(
            message: $errorMessage,
            title: NSLocalizedString("Couldn't load library", comment: ""),
            retryTitle: NSLocalizedString("Retry", comment: ""),
            retryAction: {
                Task { await loadItems() }
            }
        )
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    AppToolbarIcon(systemName: "chevron.left")
                }
                Button(action: { NavigationUtil.popToRootView() }) {
                    AppToolbarIcon(systemName: "house")
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Menu {
                    ForEach(LibraryDisplayMode.allCases) { mode in
                        Button(action: { setDisplayMode(mode) }) {
                            HStack {
                                Text(mode.localizedTitle)
                                if displayMode == mode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    AppToolbarIcon(systemName: displayMode.iconName)
                }

                if PlatformHelper.isRunningOnMac {
                    Button(action: {
                        Task { await loadItems() }
                    }) {
                        AppToolbarIcon(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .hideNavigationBarBackground()
        .customBackButton()
        .onAppear {
            loadSavedDisplayMode()
            if items.isEmpty {
                Task { await loadItems() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteItemDidDelete)) { notification in
            guard let payload = notification.object as? RemoteItemDeletePayload,
                  payload.serverId == server.id else { return }
            let id = payload.itemId
            items.removeAll(where: { $0.id == id })
        }
    }

    private func loadSavedDisplayMode() {
        displayMode = settings.libraryDisplayModeEnum(
            provider: "emby",
            serverId: server.id.uuidString,
            libraryId: "container-\(container.id)",
            defaultMode: .poster
        )
    }

    private func setDisplayMode(_ mode: LibraryDisplayMode) {
        displayMode = mode
        settings.saveLibraryDisplayMode(
            provider: "emby",
            serverId: server.id.uuidString,
            libraryId: "container-\(container.id)",
            mode: mode
        )
    }

    private func loadItems(isPagination: Bool = false) async {
        guard let token = server.accessToken, let userId = server.userId else { return }

        if isPagination {
            guard !isPaginating, hasMoreItems else { return }
            await MainActor.run { isPaginating = true }
        } else {
            await MainActor.run {
                isLoading = true
                errorMessage = nil
                currentStartIndex = 0
                hasMoreItems = true
            }
        }

        do {
            let response = try await EmbyService.shared.getItems(
                server: server,
                userId: userId,
                token: token,
                libraryId: container.id,
                sortBy: "SortName",
                sortOrder: "Ascending",
                startIndex: currentStartIndex,
                limit: pageSize,
                recursive: container.type == "BoxSet"
            )

            await MainActor.run {
                if isPagination {
                    items.append(contentsOf: response.items)
                } else {
                    items = response.items
                }
                hasMoreItems = response.items.count >= pageSize
                
                if isPagination {
                    currentStartIndex += pageSize
                    isPaginating = false
                } else {
                    currentStartIndex = pageSize
                    isLoading = false
                }
            }
        } catch {
            if isCancellationError(error) {
                await MainActor.run {
                    if isPagination {
                        isPaginating = false
                    } else {
                        isLoading = false
                    }
                }
                return
            }
            await MainActor.run {
                if isPagination {
                    isPaginating = false
                } else {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

struct EmbyMediaContextMenuModifier: ViewModifier {
    let item: EmbyItem
    let server: ServerConfig
    @AppStorage("allowMediaServerDeletion") private var allowMediaServerDeletion = false
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    @State private var isDeleted = false
    
    @State private var isFavorite: Bool
    @State private var isPlayed: Bool
    
    let onPlay: (() -> Void)?

    init(item: EmbyItem, server: ServerConfig, onPlay: (() -> Void)? = nil) {
        self.item = item
        self.server = server
        self.onPlay = onPlay
        self._isFavorite = State(initialValue: item.userData?.isFavorite ?? false)
        self._isPlayed = State(initialValue: item.userData?.played ?? false)
    }

    func body(content: Content) -> some View {
        content
            .overlay(
                Group {
                    if isDeleting {
                        ZStack {
                            Color.black.opacity(0.4)
                            ProgressView()
                        }
                        .cornerRadius(10)
                    }
                }
            )
            .contextMenu {
                    if let onPlay = onPlay, item.isPlayable {
                        Button(action: onPlay) {
                            Label(NSLocalizedString("Play", comment: ""), systemImage: "play.fill")
                        }
                    }


                    if item.type != "Episode" {
                        Button(action: { Task { await toggleFavorite() } }) {
                            Label(
                                isFavorite ? NSLocalizedString("Remove from Favorites", comment: "") : NSLocalizedString("Add to Favorites", comment: ""),
                                systemImage: isFavorite ? "heart.slash" : "heart"
                            )
                        }
                    }

                    if allowMediaServerDeletion && (item.type == "Movie" || item.type == "Episode" || item.type == "Series" || item.type == "Season") {
                        if #available(iOS 15.0, *) {
                            Button(role: .destructive, action: {
                                showingDeleteAlert = true
                            }) {
                                Label(NSLocalizedString("Delete from Server", comment: ""), systemImage: "trash")
                            }
                        } else {
                            Button(action: {
                                showingDeleteAlert = true
                            }) {
                                Label(NSLocalizedString("Delete from Server", comment: ""), systemImage: "trash")
                            }
                        }
                    }
                }
                .alert(isPresented: $showingDeleteAlert) {
                    Alert(
                        title: Text(NSLocalizedString("Delete from Server", comment: "")),
                        message: Text(String(format: NSLocalizedString("Are you sure you want to delete \"%@\" from the server? This cannot be undone.", comment: ""), item.name ?? "")),
                        primaryButton: .destructive(Text(NSLocalizedString("Delete", comment: ""))) {
                            Task { await deleteItem() }
                        },
                        secondaryButton: .cancel()
                    )
                }
    }

    private func togglePlayed() async {
        let newState = !isPlayed
        do {
            try await EmbyService.shared.togglePlayed(server: server, itemId: item.id, userId: server.userId ?? "", token: server.accessToken ?? "", isPlayed: newState)
            await MainActor.run { isPlayed = newState }
        } catch {
            print("Failed to toggle played state: \(error.localizedDescription)")
        }
    }

    private func toggleFavorite() async {
        let newState = !isFavorite
        do {
            try await EmbyService.shared.toggleFavorite(server: server, itemId: item.id, userId: server.userId ?? "", token: server.accessToken ?? "", isFavorite: newState)
            await MainActor.run { isFavorite = newState }
        } catch {
            print("Failed to toggle favorite state: \(error.localizedDescription)")
        }
    }

    private func deleteItem() async {
        isDeleting = true
        do {
            try await EmbyService.shared.deleteItem(server: server, itemId: item.id, token: server.accessToken ?? "")
            
            if let favorite = FavoriteService.shared.favorites.first(where: { $0.file.jellyfinItemId == item.id }) {
                FavoriteService.shared.remove(favorite)
            }
            if let historyFile = HistoryService.shared.remoteHistory.first(where: { $0.jellyfinItemId == item.id }) {
                HistoryService.shared.removeFromHistory(historyFile)
            }
            
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .remoteItemDidDelete,
                    object: RemoteItemDeletePayload(serverId: server.id, itemId: item.id)
                )
            }
        } catch {
            print("Failed to delete item from Emby server: \(error.localizedDescription)")
        }
        isDeleting = false
    }
}
