import SwiftUI
import GenPlayerShell

private func isCancellationError(_ error: Error) -> Bool {
    if error is CancellationError {
        return true
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
}

private func jellyfinResumeDecision(
    from userData: JellyfinUserData?,
    runtimeTicks: Int64?,
    playedOverride: Bool? = nil
) -> RemotePlaybackResumeDecision {
    userData?.resumeDecision(runtimeTicks: runtimeTicks, playedOverride: playedOverride) ?? .none
}

private func jellyfinPlaybackPositionSeconds(
    from userData: JellyfinUserData?,
    runtimeTicks: Int64?,
    playedOverride: Bool? = nil
) -> TimeInterval? {
    jellyfinResumeDecision(
        from: userData,
        runtimeTicks: runtimeTicks,
        playedOverride: playedOverride
    ).startPosition
}

private func jellyfinEffectiveUserData(
    for item: JellyfinItem,
    serverId: UUID,
    remotePlaybackState: RemotePlaybackStateStore
) -> JellyfinUserData? {
    JellyfinUserData.merged(
        item.userData,
        playbackState: remotePlaybackState.snapshot(serverId: serverId, itemId: item.id)
    )
}

private func jellyfinPreferredPlaybackSource(for item: JellyfinItem) -> JellyfinMediaSource? {
    let sources = item.mediaSources ?? []
    return JellyfinService.shared.preferredPlaybackSource(from: sources) ?? item.mediaSources?.first
}

private func jellyfinPreferredStreamURL(
    for item: JellyfinItem,
    server: ServerConfig,
    token: String,
    playbackQuality: RemotePlaybackQualityOption = .auto
) -> URL? {
    let preferredSource = jellyfinPreferredPlaybackSource(for: item)
    return JellyfinService.shared.resolvePlaybackURL(
        server: server,
        itemId: item.id,
        token: token,
        mediaSource: preferredSource,
        playbackQuality: playbackQuality
    )
}

private func applyJellyfinPreferredSourceMetadata(from item: JellyfinItem, to file: inout VideoFile) {
    guard let source = jellyfinPreferredPlaybackSource(for: item) else { return }
    file.serverMediaStreams = source.mediaStreams?.map { $0.toDictionary() }
    file.serverContainer = source.container
    file.serverSize = source.size
    file.serverBitrate = source.bitrate
    file.serverPath = source.path
}

private struct JellyfinPreparedPlayback {
    let streamURL: URL
    let mediaStreams: [[String: Any]]
    let container: String?
    let size: Int64?
    let bitrate: Int?
    let path: String?
    let playbackMethod: RemotePlaybackMethod
    let qualityOptions: [RemotePlaybackQualityOption]
    let externalSubtitleCandidates: [ExternalSubtitleCandidate]
}

private func jellyfinPreparedPlayback(
    for item: JellyfinItem,
    server: ServerConfig,
    token: String,
    userId: String?,
    playbackQuality: RemotePlaybackQualityOption = .auto
) async -> JellyfinPreparedPlayback? {
    func snapshot(from mediaSources: [JellyfinMediaSource]) -> JellyfinPreparedPlayback? {
        let preferredSource = JellyfinService.shared.preferredPlaybackSource(from: mediaSources) ?? mediaSources.first
        guard let streamURL = JellyfinService.shared.resolvePlaybackURL(
            server: server,
            itemId: item.id,
            token: token,
            mediaSource: preferredSource,
            playbackQuality: playbackQuality
        ) else {
            return nil
        }

        return JellyfinPreparedPlayback(
            streamURL: streamURL,
            mediaStreams: preferredSource?.mediaStreams?.map { $0.toDictionary() } ?? [],
            container: preferredSource?.container,
            size: preferredSource?.size,
            bitrate: preferredSource?.bitrate,
            path: preferredSource?.path,
            playbackMethod: JellyfinService.shared.playbackMethod(
                for: preferredSource,
                resolvedURL: streamURL,
                playbackQuality: playbackQuality
            ),
            qualityOptions: JellyfinService.shared.qualityOptions(from: mediaSources),
            externalSubtitleCandidates: JellyfinService.shared.externalSubtitleCandidates(
                server: server,
                itemId: item.id,
                mediaSources: mediaSources,
                token: token
            )
        )
    }

    let fallback = snapshot(from: item.mediaSources ?? [])
    guard let userId, !userId.isEmpty else { return fallback }

    do {
        let playbackInfo = try await JellyfinService.shared.getPlaybackInfo(
            server: server,
            itemId: item.id,
            userId: userId,
            token: token,
            playbackQuality: playbackQuality
        )
        return snapshot(from: playbackInfo.mediaSources) ?? fallback
    } catch {
        print("[Jellyfin] Playback preparation fallback for \(item.id): \(error)")
        return fallback
    }
}

private func applyJellyfinPreparedPlayback(_ preparedPlayback: JellyfinPreparedPlayback, to file: inout VideoFile) {
    file.serverMediaStreams = preparedPlayback.mediaStreams
    file.serverContainer = preparedPlayback.container
    file.serverSize = preparedPlayback.size
    file.serverBitrate = preparedPlayback.bitrate
    file.serverPath = preparedPlayback.path
    file.remotePlaybackMethod = preparedPlayback.playbackMethod
    file.externalSubtitleCandidates = preparedPlayback.externalSubtitleCandidates
    file.availablePlaybackQualityOptions = preparedPlayback.qualityOptions
}

private func mediaBitrateText(_ bitrate: Int?) -> String? {
    guard let bitrate = bitrate, bitrate > 0 else { return nil }
    if bitrate >= 1_000_000 {
        return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000.0)
    }
    return "\(max(1, bitrate / 1000)) kbps"
}

private func mediaFileSizeText(_ size: Int64?) -> String? {
    guard let size = size, size > 0 else { return nil }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: size)
}

private func jellyfinResolutionBadgeText(for item: JellyfinItem) -> String? {
    guard let width = jellyfinPreferredPlaybackSource(for: item)?.videoStream?.width else { return nil }
    if width >= 3800 { return "4K" }
    if width >= 1900 { return "1080P" }
    if width >= 1200 { return "720P" }
    return nil
}

private func jellyfinDetailMetadataSegments(for item: JellyfinItem) -> [String] {
    guard let source = jellyfinPreferredPlaybackSource(for: item) else { return [] }

    var segments: [String] = []
    if let resolution = jellyfinResolutionBadgeText(for: item) {
        segments.append(resolution)
    }
    segments += MediaTechnicalMetadata.parts(video: source.videoStream?.toDictionary() ?? [:])
    if let container = source.container?.split(separator: ",").first {
        let text = String(container).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !text.isEmpty {
            segments.append(text)
        }
    }
    if let bitrate = mediaBitrateText(source.bitrate) {
        segments.append(bitrate)
    }
    if let size = mediaFileSizeText(source.size) {
        segments.append(size)
    }
    return segments
}

private typealias JellyfinResolvedNavigationTarget = (item: JellyfinItem, seasonId: String?, episodeId: String?)

private func jellyfinResolvedNavigationTarget(
    server: ServerConfig,
    itemId: String,
    token: String
) async -> JellyfinResolvedNavigationTarget? {
    do {
        let item = try await JellyfinService.shared.getItemDetails(server: server, itemId: itemId, token: token)
        if item.type == "Episode", let seriesId = item.seriesId {
            let seriesItem = try await JellyfinService.shared.getItemDetails(server: server, itemId: seriesId, token: token)
            return (seriesItem, item.seasonId, item.id)
        }
        if item.type == "Season", let seriesId = item.seriesId {
            let seriesItem = try await JellyfinService.shared.getItemDetails(server: server, itemId: seriesId, token: token)
            return (seriesItem, item.id, nil)
        }
        return (item, nil, nil)
    } catch {
        print("Failed to resolve Jellyfin detail target: \(error)")
        return nil
    }
}

struct JellyfinLibraryView: View {
    @State var server: ServerConfig
    @ObservedObject var networkService: AppNetworkService
    var onExit: (() -> Void)? = nil
    
    @State private var libraries: [JellyfinLibrary] = []
    @State private var continueWatching: [JellyfinItem] = []
    @State private var nextUp: [JellyfinItem] = []
    @State private var libraryItems: [String: [JellyfinItem]] = [:] // libraryId -> items
    @State private var libraryCounts: [String: Int] = [:] // libraryId -> total count
    @State private var favorites: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var needsLogin = false
    @State private var isShowingSearch = false
    @State private var nativeSearchText = ""
    @State private var searchLaunchQuery = ""
    @State private var isSearchOverlayActive = false
    @State private var overlaySearchQuery = ""
    @State private var overlaySearchResults: [JellyfinItem] = []
    @State private var isOverlaySearching = false
    @State private var overlaySearchTask: Task<Void, Never>? = nil
    @State private var titleAnchorOffset: CGFloat = .zero
    @State private var initialTitleAnchorOffset: CGFloat?
    @State private var myMediaGridWidth: CGFloat = 0
    
    var targetItemIdToResolve: String? = nil
    @State private var autoResolveItem: JellyfinItem? = nil
    @State private var autoResolveSeasonId: String? = nil
    @State private var autoResolveEpisodeId: String? = nil
    @State private var isNavigatingToAutoResolve = false
    @State private var loadDataTask: Task<Void, Never>? = nil
    @State private var summaryTask: Task<Void, Never>? = nil
    private typealias AutoResolveTarget = JellyfinResolvedNavigationTarget
    
    @Environment(\.presentationMode) var presentationMode

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    
    private let jellyfinService = JellyfinService.shared
    @ObservedObject private var remotePlaybackState = RemotePlaybackStateStore.shared

    private struct HomeCarouselEntry: Identifiable {
        let item: JellyfinItem
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
    private var homeShelfLibraries: [JellyfinLibrary] {
        libraries.filter { $0.libraryType.showsHomeShelfSection }
    }

    @State private var carouselEntries: [JellyfinHomeCarousel.Entry] = []

    private var homeCarouselEntries: [HomeCarouselEntry] {
        carouselEntries.map { entry in
            HomeCarouselEntry(item: entry.item,
                sourceTitle: NSLocalizedString(entry.source.titleKey, comment: ""),
                sourceSystemImage: entry.source.systemImage)
        }
    }

    private var homeCarouselItems: [MediaHomeCarouselItem] {
        homeCarouselEntries.map { entry in
            let item = entry.item
            let effectiveUserData = jellyfinEffectiveUserData(
                for: item,
                serverId: server.id,
                remotePlaybackState: remotePlaybackState
            )
            let isPlayable = item.isPlayable

            return MediaHomeCarouselItem(
                id: item.id,
                title: item.displayTitle,
                subtitle: item.subtitle,
                metadataSegments: jellyfinCarouselMetadataSegments(for: item),
                overview: jellyfinCarouselOverview(for: item),
                sourceTitle: entry.sourceTitle,
                sourceSystemImage: entry.sourceSystemImage,
                imageURL: item.landscapeImageURL(server: server),
                backdropImageURL: jellyfinCarouselBackdropImageURL(for: item),
                portraitImageURL: jellyfinCarouselPortraitImageURL(for: item),
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

    private func jellyfinCarouselPortraitImageURL(for item: JellyfinItem) -> URL? {
        switch item.type {
        case "Episode", "Season":
            return item.seriesPrimaryImageURL(server: server, maxWidth: 1000)
                ?? item.primaryImageURL(server: server, maxWidth: 1000)
        default:
            return item.primaryImageURL(server: server, maxWidth: 1000)
        }
    }

    private func jellyfinCarouselBackdropImageURL(for item: JellyfinItem) -> URL? {
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
                                        value: proxy.frame(in: .named("jellyfinLibraryScroll")).minY
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
                                LandscapeMediaSection(
                                    title: NSLocalizedString("Continue Watching", comment: ""),
                                    systemImage: "clock.fill",
                                    items: continueWatching,
                                    server: server,
                                    onPlay: playJellyfinItem,
                                    onOpenDetails: openDetails,
                                    horizontalPadding: myMediaGridPadding,
                                    onExit: onExit
                                )
                            }

                            // Next Up Section (landscape thumbnails)
                            if !nextUp.isEmpty {
                                LandscapeMediaSection(
                                    title: NSLocalizedString("Next Up", comment: ""),
                                    systemImage: "play.rectangle.fill",
                                    items: nextUp,
                                    server: server,
                                    onPlay: playJellyfinItem,
                                    onOpenDetails: openDetails,
                                    horizontalPadding: myMediaGridPadding,
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
                                        .padding(.horizontal, myMediaGridPadding)

                                    MediaSection(
                                        title: "", // Title already shown above
                                        items: favorites,
                                        server: server,
                                        showProgress: false,
                                        horizontalPadding: myMediaGridPadding,
                                        onExit: onExit,
                                        onPlay: playJellyfinItem
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
                                        .padding(.horizontal, myMediaGridPadding)

                                    LazyVGrid(columns: myMediaColumns, spacing: myMediaGridSpacing) {
                                        ForEach(libraries) { library in
                                            NavigationLink(destination: JellyfinLibraryDetailView(server: server, library: library, onExit: onExit, onPlay: playJellyfinItem)) {
                                                LibraryCard(
                                                    library: library,
                                                    server: server,
                                                    previewItems: libraryItems[library.id] ?? [],
                                                    itemCount: libraryCounts[library.id] ?? library.totalItemCount
                                                )
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                            .contentShape(Rectangle())
                                            .macCardHoverEffect(cornerRadius: 12)
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, myMediaGridPadding)
                                    .onWidthChange { myMediaGridWidth = $0 }
                                }
                            }

                            // Latest items per library
                            ForEach(homeShelfLibraries) { library in
                                if let items = libraryItems[library.id], !items.isEmpty {
                                    MediaSection(
                                        title: library.name,
                                        items: items,
                                        server: server,
                                        showProgress: false,
                                        itemCount: libraryCounts[library.id] ?? library.totalItemCount,
                                        seeAllDestination: AnyView(JellyfinLibraryDetailView(server: server, library: library, onExit: onExit, onPlay: playJellyfinItem)),
                                        horizontalPadding: myMediaGridPadding,
                                        onExit: onExit,
                                        onPlay: playJellyfinItem
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
            .coordinateSpace(name: "jellyfinLibraryScroll")
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
                            JellyfinSearchView(server: server, library: nil, initialQuery: searchLaunchQuery, onExit: onExit, onPlay: playJellyfinItem)
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

    private func openCarouselItem(_ item: JellyfinItem) {
        if item.isPlayable {
            playJellyfinItem(item)
        } else {
            openDetails(for: item)
        }
    }

    private func jellyfinCarouselMetadataSegments(for item: JellyfinItem) -> [String] {
        var segments: [String] = []

        if let type = jellyfinCarouselTypeText(for: item.type) {
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
        if let countText = jellyfinCarouselCountText(for: item) {
            segments.append(countText)
        }

        return Array(segments.prefix(5))
    }

    private func jellyfinCarouselOverview(for item: JellyfinItem) -> String? {
        if let overview = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overview.isEmpty {
            return overview
        }
        let genres = item.genres?.prefix(3).joined(separator: " • ") ?? ""
        return genres.isEmpty ? nil : genres
    }

    private func jellyfinCarouselTypeText(for type: String) -> String? {
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

    private func jellyfinCarouselCountText(for item: JellyfinItem) -> String? {
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
    
    private func playJellyfinItem(_ item: JellyfinItem) {
        guard let token = server.accessToken else { return }

        Task {
            guard let preparedPlayback = await jellyfinPreparedPlayback(
                for: item,
                server: server,
                token: token,
                userId: server.userId
            ) else {
                return
            }

            let resumeDecision = jellyfinResumeDecision(from: item.userData, runtimeTicks: item.runTimeTicks)
            let startPosition = resumeDecision.startPosition

            var videoFile = VideoFile(
                name: item.displayTitle,
                url: preparedPlayback.streamURL,
                type: .video,
                size: 0,
                date: Date(),
                isRemote: true,
                duration: nil,
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
            applyJellyfinPreparedPlayback(preparedPlayback, to: &videoFile)

            await MainActor.run {
                self.playerPlaylist = [videoFile]
                self.playerFile = videoFile
            }

            if item.type == "Episode",
               let seriesId = item.seriesId,
               let seasonId = item.seasonId,
               let userId = server.userId {
                do {
                    let episodes = try await JellyfinService.shared.getEpisodes(
                        server: server,
                        userId: userId,
                        token: token,
                        seriesId: seriesId,
                        seasonId: seasonId
                    )
                    let files = episodes.compactMap { ep -> VideoFile? in
                        guard let url = jellyfinPreferredStreamURL(for: ep, server: server, token: token) else { return nil }
                        let resumeDecision = jellyfinResumeDecision(from: ep.userData, runtimeTicks: ep.runTimeTicks)
                        var file = VideoFile(
                            name: ep.displayTitle,
                            url: url,
                            type: .video,
                            size: 0,
                            date: Date(),
                            isRemote: true,
                            lastPlayedPosition: resumeDecision.startPosition,
                            jellyfinItemId: ep.id,
                            jellyfinServerId: server.id.uuidString,
                            serverType: server.type,
                            seriesId: ep.seriesId,
                            seasonId: ep.seasonId
                        )
                        file.shouldResetRemotePlayedStateOnPlaybackStart = resumeDecision.shouldResetPlayedStateOnStart
                        applyJellyfinPreferredSourceMetadata(from: ep, to: &file)
                        return file
                    }
                    if !files.isEmpty {
                        await MainActor.run {
                            self.playerPlaylist = files
                        }
                    }
                } catch {
                    print("[Jellyfin] Background playlist fetch failed: \(error)")
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
            jellyfinSearchOverlayResults
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
    private var jellyfinSearchOverlayResults: some View {
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
                Text(NSLocalizedString("No Results Found", comment: ""))
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
                        Text(NSLocalizedString("Top Hits", comment: ""))
                            .font(.headline)
                            .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(topHits) { item in
                                    NavigationLink(destination: NavigationLazyView {
                                        jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: playJellyfinItem)
                                    }) {
                                        MediaPosterCard(item: item, server: server, showProgress: false, onPlay: { playJellyfinItem(item) })
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
                                    jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: playJellyfinItem)
                                }) {
                                    JellyfinLibraryListRow(item: item, server: server, onPlay: { playJellyfinItem(item) })
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

                let results = try await jellyfinService.searchItems(
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
            async let resolvedTarget = resolveAutoNavigationTargetIfNeeded(token: token)
            async let heroEntries = JellyfinHomeCarousel.load(server: server, userId: userId, token: token)

            // Load libraries
            let libs = try await jellyfinService.getLibraries(server: server, userId: userId, token: token)
            guard !Task.isCancelled else { return }
            
            // Load continue watching
            let contWatching = try await jellyfinService.getContinueWatching(server: server, userId: userId, token: token)
            guard !Task.isCancelled else { return }
            
            // Load next up
            let nextUpItems = try await jellyfinService.getNextUp(server: server, userId: userId, token: token)
            guard !Task.isCancelled else { return }
            
            // Load favorites
            let favoriteItems = try await jellyfinService.getFavorites(server: server, userId: userId, token: token)
            guard !Task.isCancelled else { return }
            
            // Load shelf items for each library
            var libItems: [String: [JellyfinItem]] = [:]
            for library in libs {
                guard !Task.isCancelled else { return }
                let items = try await jellyfinService.getHomeShelfItems(
                    server: server,
                    userId: userId,
                    token: token,
                    library: library
                )
                libItems[library.id] = items
            }

            let fetchedHeroEntries = (try? await heroEntries) ?? []
            let autoTarget = await resolvedTarget
            guard !Task.isCancelled else { return }
            
            await MainActor.run {
                carouselEntries = fetchedHeroEntries
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
                            let count = await jellyfinService.getLibraryItemCount(
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
        } catch JellyfinError.unauthorized {
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

    private func resolveAutoNavigationTargetIfNeeded(token: String) async -> AutoResolveTarget? {
        guard let targetId = targetItemIdToResolve, autoResolveItem == nil else {
            return nil
        }
        return await jellyfinResolvedNavigationTarget(server: server, itemId: targetId, token: token)
    }

    private func refreshHomeFavorites() async {
        guard !Task.isCancelled else { return }
        await syncLatestServerStateIfNeeded()
        guard let token = server.accessToken,
              let userId = server.userId else {
            return
        }

        do {
            let favoriteItems = try await jellyfinService.getFavorites(server: server, userId: userId, token: token)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                favorites = favoriteItems
            }
        } catch {
            print("[Jellyfin] Failed to refresh home favorites: \(error)")
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
            let result = try await jellyfinService.login(server: server, username: username, password: password)
            guard !Task.isCancelled else {
                await MainActor.run {
                    needsLogin = false
                }
                return
            }
            
            print("[Jellyfin] Login successful, token received")
            
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
            print("[Jellyfin] Login failed: \(error)")
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
    private func autoResolveDestination(for item: JellyfinItem) -> some View {
        if jellyfinUsesListPage(item) {
            JellyfinContainerListView(server: server, container: item, onExit: onExit, onPlay: playJellyfinItem)
        } else {
            JellyfinItemDetailView(
                server: server,
                item: item,
                onExit: onExit,
                initialSeasonId: autoResolveSeasonId,
                initialEpisodeId: autoResolveEpisodeId
            )
        }
    }

    private func openDetails(for item: JellyfinItem) {
        if item.type != "Episode" && item.type != "Season" {
            autoResolveSeasonId = nil
            autoResolveEpisodeId = nil
            autoResolveItem = item
            isNavigatingToAutoResolve = true
            return
        }

        guard let token = server.accessToken, !token.isEmpty else {
            autoResolveSeasonId = nil
            autoResolveEpisodeId = nil
            autoResolveItem = item
            isNavigatingToAutoResolve = true
            return
        }

        Task {
            let resolvedTarget = await jellyfinResolvedNavigationTarget(server: server, itemId: item.id, token: token)
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

private func jellyfinUsesListPage(_ item: JellyfinItem) -> Bool {
    item.type == "BoxSet" || item.type == "Playlist"
}

@ViewBuilder
func jellyfinNavigationDestination(
    server: ServerConfig,
    item: JellyfinItem,
    onExit: (() -> Void)? = nil,
    onPlay: ((JellyfinItem) -> Void)? = nil
) -> some View {
    if jellyfinUsesListPage(item) {
        JellyfinContainerListView(server: server, container: item, onExit: onExit, onPlay: onPlay)
    } else {
        JellyfinItemDetailView(server: server, item: item, onExit: onExit)
    }
}

// MARK: - Media Section

struct MediaSection: View {
    let title: String
    let items: [JellyfinItem]
    let server: ServerConfig
    let showProgress: Bool
    var itemCount: Int? = nil
    var seeAllDestination: AnyView? = nil
    var horizontalPadding: CGFloat? = nil
    var onExit: (() -> Void)? = nil
    var onPlay: ((JellyfinItem) -> Void)? = nil

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsHeader: Bool {
        !trimmedTitle.isEmpty || seeAllDestination != nil
    }
    
    private var sectionHorizontalPadding: CGFloat {
        horizontalPadding ?? max(16, max(UIApplication.currentSafeAreaInsets().left, UIApplication.currentSafeAreaInsets().right))
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
                .padding(.horizontal, sectionHorizontalPadding)
            }
            
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(destination: jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                            MediaPosterCard(item: item, server: server, showProgress: showProgress, onPlay: { onPlay?(item) })
                        }
                        .buttonStyle(PlainButtonStyle())
                        .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, sectionHorizontalPadding)
            }
            .duoMediaShelfViewport()
        }
    }
}

// MARK: - Media Poster Card

struct MediaPosterCard: View {
    let item: JellyfinItem
    let server: ServerConfig
    var showProgress: Bool = true
    var cardWidth: CGFloat = MediaCardMetrics.posterWidth
    var onPlay: (() -> Void)? = nil

    private var posterHeight: CGFloat { cardWidth * 1.5 }
    @ObservedObject private var offlineIndex = OfflineMediaIndexStore.shared
    @ObservedObject private var remotePlaybackState = RemotePlaybackStateStore.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                // Poster Image with cover mode
                RemoteImage(url: item.primaryImageURL(server: server))
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(width: cardWidth, height: posterHeight)
                    .clipped()
                    .cornerRadius(8)
                
                // Gradient overlay for text readability
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(height: 60)
                .cornerRadius(8, corners: [.bottomLeft, .bottomRight])
                .allowsHitTesting(false)
                
                // Bottom overlay with metadata
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        // Rating Badge
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
        .frame(width: cardWidth)
        .contentShape(Rectangle())
        .modifier(JellyfinMediaContextMenuModifier(item: item, server: server, onPlay: onPlay))
    }

    private var isDownloaded: Bool {
        offlineIndex.isDownloaded(serverId: server.id, remoteItemId: item.id)
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        let effectiveUserData = jellyfinEffectiveUserData(
            for: item,
            serverId: server.id,
            remotePlaybackState: remotePlaybackState
        )
        return PlaybackProgressSnapshot.fromPercent(
            effectiveUserData?.playedPercentage,
            played: effectiveUserData?.played ?? false
        )
    }

    private var posterSubtitleText: String? {
        item.compactPosterMetadataLine
    }
    
    private func childCountLabel(count: Int) -> String {
        switch item.type {
        case "Series":
            return count == 1 ? "1 \(NSLocalizedString("Season", comment: ""))" : "\(count) \(NSLocalizedString("Seasons", comment: ""))"
        case "Season":
            return count == 1 ? String(format: NSLocalizedString("%d Episode", comment: ""), 1) : String(format: NSLocalizedString("%d Episodes", comment: ""), count)
        default:
            return "\(count)"
        }
    }
}

// MARK: - Media Thumb Card (16:9)

struct MediaThumbCard: View {
    let item: JellyfinItem
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
        .modifier(CardWidthModifier(width: fixedWidth))
        .contentShape(Rectangle())
        .modifier(JellyfinMediaContextMenuModifier(item: item, server: server, onPlay: onPlay))
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

                    Spacer()

                    if let childCount = item.childCount, childCount > 0 {
                        Text(childCountLabel(count: childCount))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.9))
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
        .modifier(ThumbnailFrameModifier(width: fixedWidth, height: defaultCardHeight))
    }

    private var isDownloaded: Bool {
        offlineIndex.isDownloaded(serverId: server.id, remoteItemId: item.id)
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        let effectiveUserData = jellyfinEffectiveUserData(
            for: item,
            serverId: server.id,
            remotePlaybackState: remotePlaybackState
        )
        return PlaybackProgressSnapshot.fromPercent(
            effectiveUserData?.playedPercentage,
            played: effectiveUserData?.played ?? false
        )
    }

    private var posterSubtitleText: String? {
        item.compactPosterMetadataLine
    }

    private func childCountLabel(count: Int) -> String {
        switch item.type {
        case "Series":
            return count == 1 ? "1 \(NSLocalizedString("Season", comment: ""))" : "\(count) \(NSLocalizedString("Seasons", comment: ""))"
        case "Season":
            return count == 1 ? String(format: NSLocalizedString("%d Episode", comment: ""), 1) : String(format: NSLocalizedString("%d Episodes", comment: ""), count)
        default:
            return "\(count)"
        }
    }
}

private struct ThumbnailFrameModifier: ViewModifier {
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

private struct CardWidthModifier: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width)
        } else {
            content.frame(maxWidth: .infinity)
        }
    }
}

private struct DetailPosterCardText: View {
    let title: String
    let subtitle: String?
    let width: CGFloat
    let height: CGFloat
    let titleColor: Color
    let subtitleColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(titleColor)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .frame(width: width, height: 32, alignment: .topLeading)

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundColor(subtitleColor)
                    .lineLimit(1)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

private struct JellyfinDetailPersonCard: View {
    let server: ServerConfig
    let person: JellyfinPerson

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if let _ = person.primaryImageTag {
                    RemoteImage(url: person.primaryImageURL(server: server, maxWidth: 200))
                        .aspectRatio(2/3, contentMode: .fill)
                } else {
                    ZStack {
                        Rectangle()
                            .fill(Color.gray.opacity(0.3))

                        Image(systemName: "person.fill")
                            .font(.largeTitle)
                            .foregroundColor(.gray)
                    }
                }
            }
            .frame(width: MediaCardMetrics.peoplePosterWidth, height: MediaCardMetrics.peoplePosterHeight)
            .cornerRadius(8)
            .clipped()
            .contentShape(Rectangle())

            DetailPosterCardText(
                title: person.name,
                subtitle: personCardSubtitle(role: person.role, type: person.type),
                width: MediaCardMetrics.peoplePosterWidth,
                height: MediaCardMetrics.peopleTextHeight,
                titleColor: .white,
                subtitleColor: .white.opacity(0.7)
            )
        }
        .frame(width: MediaCardMetrics.peoplePosterWidth)
        .contentShape(Rectangle())
    }
}

private struct JellyfinDetailRelatedCard: View {
    let server: ServerConfig
    let item: JellyfinItem
    var onPlay: (() -> Void)? = nil

    private let cardWidth = MediaCardMetrics.posterWidth
    private let posterHeight = MediaCardMetrics.posterHeight

    #if targetEnvironment(macCatalyst) || os(macOS)
    @State private var internalCardHovered = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: item.primaryImageURL(server: server, maxWidth: 300))
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(width: cardWidth, height: posterHeight)
                    .cornerRadius(8)
                    .clipped()

                #if targetEnvironment(macCatalyst) || os(macOS)
                MacPosterHoverPlayOverlay(
                    isCardHovered: internalCardHovered,
                    onPlay: onPlay,
                    buttonSize: 36,
                    cornerRadius: 8
                )
                #endif

                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(height: 60)
                .cornerRadius(8, corners: [.bottomLeft, .bottomRight])
                .allowsHitTesting(false)

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

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                .allowsHitTesting(false)
            }

            DetailPosterCardText(
                title: item.displayTitle,
                subtitle: subtitleText,
                width: cardWidth,
                height: MediaCardMetrics.posterTextHeight,
                titleColor: .white,
                subtitleColor: .white.opacity(0.7)
            )
        }
        .frame(width: cardWidth)
        .contentShape(Rectangle())
        .modifier(JellyfinMediaContextMenuModifier(item: item, server: server, onPlay: onPlay))
        #if targetEnvironment(macCatalyst) || os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                internalCardHovered = hovering
            }
        }
        #endif
    }

    private var subtitleText: String? {
        item.compactPosterMetadataLine
    }
}

// MARK: - Landscape Media Section (for Continue Watching / Next Up)

struct LandscapeMediaSection: View {
    let title: String
    let systemImage: String?
    let items: [JellyfinItem]
    let server: ServerConfig
    let onPlay: (JellyfinItem) -> Void
    let onOpenDetails: (JellyfinItem) -> Void
    var horizontalPadding: CGFloat? = nil
    var onExit: (() -> Void)? = nil
    @ObservedObject private var offlineIndex = OfflineMediaIndexStore.shared
    
    private var sectionHorizontalPadding: CGFloat {
        horizontalPadding ?? max(16, max(UIApplication.currentSafeAreaInsets().left, UIApplication.currentSafeAreaInsets().right))
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaSectionHeaderLabel(title: title, systemImage: systemImage)
                .padding(.horizontal, sectionHorizontalPadding)
            
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        sectionCard(for: item)
                    }
                }
                .padding(.horizontal, sectionHorizontalPadding)
            }
            .duoMediaShelfViewport()
        }
    }

    @ViewBuilder
    private func sectionCard(for item: JellyfinItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.isPlayable {
                Button(action: {
                    onPlay(item)
                }) {
                    LandscapeMediaCard(item: item, server: server, showsText: false)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Button(action: {
                    onOpenDetails(item)
                }) {
                    LandscapeMediaCard(item: item, server: server, showsText: false)
                }
                .buttonStyle(PlainButtonStyle())
            }

            Button(action: {
                onOpenDetails(item)
            }) {
                LandscapeMediaCardText(
                    title: item.displayTitle,
                    subtitle: item.subtitle,
                    isDownloaded: offlineIndex.isDownloaded(serverId: server.id, remoteItemId: item.id)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(width: MediaCardMetrics.landscapeWidth, alignment: .leading)
        #if targetEnvironment(macCatalyst) || os(macOS)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                internalCardHovered = hovering
            }
        }
        #endif
    }
}

// MARK: - Landscape Media Card (16:9 thumbnail with play button)

struct LandscapeMediaCard: View {
    let item: JellyfinItem
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
                RemoteImage(url: item.landscapeImageURL(server: server))
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
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        let effectiveUserData = jellyfinEffectiveUserData(
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

private struct LandscapeMediaCardText: View {
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

// MARK: - Search View

struct JellyfinSearchView: View {
    let server: ServerConfig
    let library: JellyfinLibrary?
    var onExit: (() -> Void)? = nil
    var onPlay: ((JellyfinItem) -> Void)? = nil
    let initialQuery: String
    @State private var searchQuery: String
    @State private var searchResults: [JellyfinItem] = []
    @State private var isLoading = false
    @Environment(\.presentationMode) private var presentationMode
    
    // Rich Suggestions State
    @State private var searchTask: Task<Void, Never>? = nil
    
    private let jellyfinService = JellyfinService.shared

    private var supportsNativeSearchBar: Bool {
        if #available(iOS 15.0, *) {
            return true
        }
        return false
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedSearchResults: [JellyfinItem] {
        searchResults.stableUniqued()
    }
    
    init(
        server: ServerConfig,
        library: JellyfinLibrary? = nil,
        initialQuery: String = "",
        onExit: (() -> Void)? = nil,
        onPlay: ((JellyfinItem) -> Void)? = nil
    ) {
        self.server = server
        self.library = library
        self.initialQuery = initialQuery
        self.onExit = onExit
        self.onPlay = onPlay
        self._searchQuery = State(initialValue: initialQuery)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if !supportsNativeSearchBar {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 15))

                    TextField(NSLocalizedString("Search movies, TV shows...", comment: ""), text: $searchQuery)
                        .font(.body)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = ""; searchResults = [] }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 15))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(UIColor.systemGray5))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            
            // Content
            if isLoading {
                Spacer()
                VStack(spacing: 16) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text(NSLocalizedString("Searching...", comment: ""))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if searchResults.isEmpty && !trimmedSearchQuery.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(NSLocalizedString("No results found", comment: ""))
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if !displayedSearchResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Top Suggestions (Rich Inline Suggestions)
                        let topHits = Array(displayedSearchResults.prefix(5))
                        if !topHits.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(NSLocalizedString("Top Suggestions", comment: ""))
                                    .font(.headline)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 8)
                                
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(alignment: .top, spacing: 12) {
                                        ForEach(topHits) { item in
                                            NavigationLink(destination: NavigationLazyView {
                                                jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)
                                            }) {
                                                MediaPosterCard(item: item, server: server, showProgress: false, onPlay: { onPlay?(item) })
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
                        
                        // All Results
                        Text(NSLocalizedString("All Results", comment: ""))
                            .font(.headline)
                            .padding(.horizontal, 16)
                        
                        LazyVStack(spacing: 12) {
                            ForEach(displayedSearchResults) { item in
                                NavigationLink(destination: NavigationLazyView {
                                    jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)
                                }) {
                                    JellyfinLibraryListRow(item: item, server: server, onPlay: { onPlay?(item) })
                                }
                                .buttonStyle(PlainButtonStyle())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 24)
                }
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary.opacity(0.2))
                    Text(NSLocalizedString("Type to search", comment: ""))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                Spacer()
            }
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle(NSLocalizedString("Search", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    AppToolbarIcon(systemName: "chevron.left")
                }
                Button(action: { NavigationUtil.popToRootView() }) {
                    AppToolbarIcon(systemName: "house")
                }
            }
        }
        .hideNavigationBarBackground()
        .customBackButton()
        .compatSearchable(
            text: $searchQuery,
            prompt: NSLocalizedString("Search movies, TV shows...", comment: "")
        )
        .onChange(of: searchQuery) { newValue in
            scheduleSearch(for: newValue)
        }
        .onChange(of: initialQuery) { newValue in
            if searchQuery != newValue {
                searchQuery = newValue
            } else if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && searchResults.isEmpty {
                scheduleSearch(for: newValue, immediate: true)
            }
        }
        .onAppear {
            if !trimmedSearchQuery.isEmpty && searchResults.isEmpty {
                scheduleSearch(for: searchQuery, immediate: true)
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteItemDidDelete)) { notification in
            guard let payload = notification.object as? RemoteItemDeletePayload,
                  payload.serverId == server.id else { return }
            let id = payload.itemId
            searchResults.removeAll(where: { $0.id == id })
        }
    }

    private func scheduleSearch(for rawQuery: String, immediate: Bool = false) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !query.isEmpty else {
            isLoading = false
            searchResults = []
            return
        }

        if searchResults.isEmpty || immediate {
            isLoading = true
        }

        searchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    private func performSearch(query: String) async {
        guard let token = server.accessToken, let userId = server.userId else {
            await MainActor.run {
                isLoading = false
                searchResults = []
            }
            return
        }

        await MainActor.run { isLoading = true }

        do {
            let results: [JellyfinItem]
            if let library {
                results = try await jellyfinService.getItems(
                    server: server,
                    userId: userId,
                    token: token,
                    libraryId: library.id,
                    searchTerm: query,
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    startIndex: 0,
                    limit: 50,
                    recursive: true
                ).items
            } else {
                results = try await jellyfinService.searchItems(server: server, userId: userId, token: token, query: query)
            }
            guard !Task.isCancelled else { return }
            let shouldApplyResults = await MainActor.run {
                searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
            }
            guard shouldApplyResults else { return }
            await MainActor.run {
                searchResults = results
                isLoading = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            let shouldApplyResults = await MainActor.run {
                searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
            }
            guard shouldApplyResults else { return }
            print("Search error: \(error)")
            await MainActor.run { isLoading = false }
        }
    }
}



extension String {
    var localizedJellyfinType: String? {
        switch self {
        case "Movie": return NSLocalizedString("Movie", comment: "")
        case "Series": return NSLocalizedString("Series", comment: "")
        case "Episode": return NSLocalizedString("Episode", comment: "")
        case "MusicAlbum": return NSLocalizedString("Album", comment: "")
        case "Audio": return NSLocalizedString("Audio", comment: "")
        default: return nil
        }
    }
}

// Helper for partial corner radius
extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

// MARK: - Library Card

struct LibraryCard: View {
    let library: JellyfinLibrary
    let server: ServerConfig
    let previewItems: [JellyfinItem]
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
                colors: [Color(red: 0.18, green: 0.25, blue: 0.46), Color(red: 0.08, green: 0.12, blue: 0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .tvShows:
            return LinearGradient(
                colors: [Color(red: 0.24, green: 0.34, blue: 0.63), Color(red: 0.13, green: 0.18, blue: 0.34)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .music:
            return LinearGradient(
                colors: [Color(red: 0.27, green: 0.38, blue: 0.30), Color(red: 0.12, green: 0.18, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .photos:
            return LinearGradient(
                colors: [Color(red: 0.44, green: 0.29, blue: 0.18), Color(red: 0.20, green: 0.13, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .collections:
            return LinearGradient(
                colors: [Color(red: 0.32, green: 0.25, blue: 0.49), Color(red: 0.14, green: 0.10, blue: 0.24)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .playlists:
            return LinearGradient(
                colors: [Color(red: 0.18, green: 0.35, blue: 0.43), Color(red: 0.08, green: 0.16, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .mixed:
            return LinearGradient(
                colors: [Color(red: 0.24, green: 0.24, blue: 0.28), Color(red: 0.11, green: 0.11, blue: 0.14)],
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
                    : [Color.black.opacity(0.14), Color.black.opacity(0.78)],
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

private struct JellyfinSpecialLibraryCard: View {
    let library: JellyfinLibrary
    let server: ServerConfig
    let previewItems: [JellyfinItem]

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
                colors: [Color(red: 0.30, green: 0.24, blue: 0.48), Color(red: 0.13, green: 0.11, blue: 0.23)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .playlists:
            return LinearGradient(
                colors: [Color(red: 0.19, green: 0.36, blue: 0.46), Color(red: 0.09, green: 0.18, blue: 0.22)],
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
                            ? NSLocalizedString("Queue up curated mixes and manual playlists.", comment: "")
                            : NSLocalizedString("Browse grouped sets with stacked poster previews.", comment: "")
                    )
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.76))
                    .lineLimit(2)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.headline.weight(.semibold))
                    .foregroundColor(.white.opacity(0.85))
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

// MARK: - Library Detail View

struct JellyfinLibraryDetailView: View {
    let server: ServerConfig
    let library: JellyfinLibrary
    var onExit: (() -> Void)? = nil
    var onPlay: ((JellyfinItem) -> Void)? = nil
    
    @State private var items: [JellyfinItem] = []
    @State private var isLoading = true
    @State private var totalCount = 0
    @State private var sortBy = "DateCreated"
    @State private var sortOrder = "Descending"
    @State private var displayMode: LibraryDisplayMode = .poster
    
    @State private var availableGenres: [String] = []
    @State private var availableYears: [String] = []
    @State private var selectedGenre: String? = nil
    @State private var selectedYear: String? = nil
    
    @State private var currentStartIndex = 0
    @State private var hasMoreItems = true
    @State private var isPaginating = false
    private let pageSize = 100
    @ObservedObject private var settings = AppSettings.shared
    @State private var isShowingSearch = false
    @State private var nativeSearchText = ""
    @State private var searchLaunchQuery = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.presentationMode) private var presentationMode

    private let jellyfinService = JellyfinService.shared
    #if os(iOS)
    @State private var isSearchOverlayActive = false
    @State private var overlaySearchQuery = ""
    @State private var overlaySearchResults: [JellyfinItem] = []
    @State private var isOverlaySearching = false
    @State private var overlaySearchTask: Task<Void, Never>? = nil
    #endif
    
    private let sortOptions = [
        ("SortName", NSLocalizedString("Name", comment: "")),
        ("DateCreated", NSLocalizedString("Date Added", comment: "")),
        ("PremiereDate", NSLocalizedString("Release Date", comment: "")),
        ("ProductionYear", NSLocalizedString("Release Year", comment: "")),
        ("CommunityRating", NSLocalizedString("Rating", comment: "")),
        ("Resolution", NSLocalizedString("Resolution", comment: "")),
        ("Runtime", NSLocalizedString("Runtime", comment: ""))
    ]
    
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
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if !availableGenres.isEmpty || !availableYears.isEmpty {
                    LibraryFilterBar(
                        availableGenres: availableGenres,
                        availableYears: availableYears,
                        selectedGenre: Binding(
                            get: { selectedGenre },
                            set: { newValue in
                                if selectedGenre != newValue {
                                    selectedGenre = newValue
                                    Task { await loadItems() }
                                }
                            }
                        ),
                        selectedYear: Binding(
                            get: { selectedYear },
                            set: { newValue in
                                if selectedYear != newValue {
                                    selectedYear = newValue
                                    Task { await loadItems() }
                                }
                            }
                        )
                    )
                    .background(Color(UIColor.systemBackground))
                    Divider()
                }
                
                ScrollView {
                    switch displayMode {
                    case .poster:
                        MediaLibraryCardGrid(columns: columns, spacing: gridSpacing, legacyCardWidth: posterCardWidth) { columnWidth in
                            ForEach(items) { item in
                                NavigationLink(destination: jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                                    MediaPosterCard(item: item, server: server, showProgress: false, cardWidth: columnWidth, onPlay: onPlay != nil ? { onPlay?(item) } : nil)
                                }
                                .buttonStyle(PlainButtonStyle())
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
                        .padding(.horizontal, gridPadding)
                        .padding(.vertical, gridPadding)
                    case .thumb:
                        LazyVGrid(columns: columns, spacing: gridSpacing) {
                            ForEach(items) { item in
                                NavigationLink(destination: jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                                    MediaThumbCard(item: item, server: server, showProgress: false, cardWidth: nil, onPlay: onPlay != nil ? { onPlay?(item) } : nil)
                                }
                                .buttonStyle(PlainButtonStyle())
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
                        .padding(.horizontal, gridPadding)
                        .padding(.vertical, gridPadding)
                    case .list:
                        LazyVStack(spacing: 12) {
                            ForEach(items) { item in
                                NavigationLink(destination: jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                                    JellyfinLibraryListRow(item: item, server: server, onPlay: onPlay != nil ? { onPlay?(item) } : nil)
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

                    if !isLoading && !items.isEmpty && totalCount > 0 {
                        Text(MediaCountFormatter.formatTotal(count: totalCount, libraryType: library.libraryType))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    }
                } // close ScrollView
            } // close VStack
            
            if isLoading {
                ProgressView()
                    .scaleEffect(1.2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        }
        .navigationTitle(library.name)
        .navigationBarTitleDisplayMode(.inline)
        .libraryChildNavigationBarCompat()
        #if os(iOS)
        .modifier(inlineSearch)
        .onChange(of: overlaySearchQuery) { newQuery in
            scheduleOverlaySearch(for: newQuery)
        }
        .onDisappear {
            overlaySearchTask?.cancel()
        }
        #endif
        .background(
            NavigationLink(
                destination: NavigationLazyView {
                    JellyfinSearchView(server: server, library: library, initialQuery: searchLaunchQuery, onExit: onExit, onPlay: onPlay)
                },
                isActive: $isShowingSearch,
                label: { EmptyView() }
            )
        )
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    AppToolbarIcon(systemName: "chevron.left")
                }
                Button(action: {
                    NavigationUtil.popToRootView()
                }) {
                    AppToolbarIcon(systemName: "house")
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                #if os(iOS)
                searchToolbarControl
                #else
                Button(action: {
                    isShowingSearch = true
                }) {
                    AppToolbarIcon(systemName: "magnifyingglass")
                }
                #endif

                Menu {
                    ForEach(LibraryDisplayMode.allCases) { mode in
                        Button(action: { setDisplayMode(mode) }) {
                            sortMenuRow(title: mode.localizedTitle, isSelected: displayMode == mode)
                        }
                    }
                } label: {
                    AppToolbarIcon(systemName: displayMode.iconName)
                }

                Menu {
                    Section(header: Text(NSLocalizedString("Sort By", comment: ""))) {
                        ForEach(sortOptions, id: \.0) { option in
                            Button(action: {
                                updateSortField(option.0)
                            }) {
                                sortMenuRow(title: option.1, isSelected: sortBy == option.0)
                            }
                        }
                    }

                    Section(header: Text(NSLocalizedString("Sort Order", comment: ""))) {
                        Button(action: {
                            updateSortOrder("Ascending")
                        }) {
                            sortMenuRow(
                                title: NSLocalizedString("Ascending", comment: ""),
                                isSelected: sortOrder == "Ascending"
                            )
                        }
                        Button(action: {
                            updateSortOrder("Descending")
                        }) {
                            sortMenuRow(
                                title: NSLocalizedString("Descending", comment: ""),
                                isSelected: sortOrder == "Descending"
                            )
                        }
                    }
                } label: {
                    AppToolbarIcon(systemName: "line.3.horizontal.decrease.circle")
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
            loadSavedSortPreference()
            loadSavedDisplayMode()
            Task { await loadFilterOptions() }
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
    
    @ViewBuilder
    private func sortMenuRow(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func updateSortField(_ newSortBy: String) {
        guard sortBy != newSortBy else { return }
        sortBy = newSortBy
        if newSortBy == "SortName" && sortOrder != "Ascending" {
            sortOrder = "Ascending"
        }
        if newSortBy != "SortName" && sortOrder != "Descending" {
            sortOrder = "Descending"
        }
        persistSortPreferenceAndReload()
    }

    private func updateSortOrder(_ newSortOrder: String) {
        guard sortOrder != newSortOrder else { return }
        sortOrder = newSortOrder
        persistSortPreferenceAndReload()
    }

    private func persistSortPreferenceAndReload() {
        settings.saveLibrarySortPreference(
            provider: "jellyfin",
            serverId: server.id.uuidString,
            libraryId: library.id,
            sortBy: sortBy,
            sortOrder: sortOrder
        )
        Task { await loadItems() }
    }

    private func loadSavedSortPreference() {
        let saved = settings.librarySortPreference(
            provider: "jellyfin",
            serverId: server.id.uuidString,
            libraryId: library.id,
            defaultSortBy: sortBy,
            defaultSortOrder: sortOrder
        )
        sortBy = saved.sortBy
        sortOrder = saved.sortOrder
    }

    private func loadSavedDisplayMode() {
        displayMode = settings.libraryDisplayModeEnum(
            provider: "jellyfin",
            serverId: server.id.uuidString,
            libraryId: library.id,
            defaultMode: .poster
        )
    }

    private func setDisplayMode(_ mode: LibraryDisplayMode) {
        displayMode = mode
        settings.saveLibraryDisplayMode(
            provider: "jellyfin",
            serverId: server.id.uuidString,
            libraryId: library.id,
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
                currentStartIndex = 0
                hasMoreItems = true
            }
        }
        
        do {
            let response = try await JellyfinService.shared.getItems(
                server: server,
                userId: userId,
                token: token,
                libraryId: library.id,
                includeTypes: library.libraryType.browseIncludeTypes,
                sortBy: serverSortBy,
                sortOrder: sortOrder,
                genres: selectedGenre,
                years: selectedYear,
                startIndex: currentStartIndex,
                limit: pageSize
            )
            await MainActor.run {
                if isPagination {
                    items.append(contentsOf: sortedItems(response.items))
                } else {
                    items = sortedItems(response.items)
                }
                totalCount = response.totalRecordCount ?? 0
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
            print("Error loading library items: \(error)")
            await MainActor.run {
                if isPagination { isPaginating = false }
                else { isLoading = false }
            }
        }
    }

    private func loadFilterOptions() async {
        guard let token = server.accessToken else { return }
        do {
            let (genres, years) = try await JellyfinService.shared.getLibraryFilterOptions(
                server: server,
                token: token,
                parentId: library.id
            )
            await MainActor.run {
                self.availableGenres = genres
                self.availableYears = years
            }
        } catch {
            print("Error loading Jellyfin filter options: \(error)")
        }
    }

    private var usesLocalSort: Bool {
        sortBy == "Resolution" || sortBy == "PremiereDate" || sortBy == "ProductionYear"
    }

    private var serverSortBy: String {
        sortBy == "Resolution" ? "SortName" : sortBy
    }

    private func sortedItems(_ loadedItems: [JellyfinItem]) -> [JellyfinItem] {
        switch sortBy {
        case "Resolution":
            return sortedItems(loadedItems) { item in
                let pixels = item.bestVideoPixelCount
                return pixels > 0 ? pixels : nil
            }
        case "PremiereDate":
            return sortedItems(loadedItems) { $0.premiereDateSortValue }
        case "ProductionYear":
            return sortedItems(loadedItems) { $0.productionYearSortValue }
        default:
            return loadedItems
        }
    }

    private func sortedItems(
        _ loadedItems: [JellyfinItem],
        value: (JellyfinItem) -> Int?
    ) -> [JellyfinItem] {
        let isAscending = sortOrder == "Ascending"
        return loadedItems.sorted { lhs, rhs in
            let lhsValue = value(lhs)
            let rhsValue = value(rhs)
            if let lhsValue, let rhsValue, lhsValue != rhsValue {
                return isAscending ? lhsValue < rhsValue : lhsValue > rhsValue
            }
            if lhsValue != nil && rhsValue == nil {
                return true
            }
            if lhsValue == nil && rhsValue != nil {
                return false
            }
            return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
        }
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
        let key = "\(server.id.uuidString)_\(library.id)"
        SearchHistoryService.shared.addHistory(submitted, for: key)
        scheduleOverlaySearch(for: submitted, immediate: true)
    }

    private var inlineSearch: some ViewModifier {
        LibraryInlineSearchModifier(
            isPresented: $isSearchOverlayActive,
            query: $overlaySearchQuery,
            placeholder: NSLocalizedString("Search in library...", comment: ""),
            serverId: "\(server.id.uuidString)_\(library.id)",
            onSubmit: submitInlineSearch
        ) {
            jellyfinSearchOverlayResults
        }
    }

    @ViewBuilder
    private var jellyfinSearchOverlayResults: some View {
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
                Text(NSLocalizedString("No Results Found", comment: ""))
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
                        Text(NSLocalizedString("Top Hits", comment: ""))
                            .font(.headline)
                            .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(topHits) { item in
                                    NavigationLink(destination: NavigationLazyView {
                                        jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)
                                    }) {
                                        MediaPosterCard(item: item, server: server, showProgress: false, onPlay: onPlay != nil ? { onPlay?(item) } : nil)
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
                                    jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)
                                }) {
                                    JellyfinLibraryListRow(item: item, server: server, onPlay: onPlay != nil ? { onPlay?(item) } : nil)
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

                let response = try await jellyfinService.getItems(
                    server: server,
                    userId: userId,
                    token: token,
                    libraryId: library.id,
                    searchTerm: query,
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    startIndex: 0,
                    limit: 50,
                    recursive: true
                )

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.overlaySearchResults = response.items.stableUniqued()
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
    #endif
}

private struct JellyfinContainerListView: View {
    let server: ServerConfig
    let container: JellyfinItem
    var onExit: (() -> Void)? = nil
    var onPlay: ((JellyfinItem) -> Void)? = nil

    @State private var items: [JellyfinItem] = []
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
                            NavigationLink(destination: jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                                MediaPosterCard(item: item, server: server, showProgress: false, cardWidth: columnWidth, onPlay: onPlay != nil ? { onPlay?(item) } : nil)
                            }
                            .buttonStyle(PlainButtonStyle())
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
                    .padding(.horizontal, gridPadding)
                    .padding(.vertical, gridPadding)
                case .thumb:
                    LazyVGrid(columns: columns, spacing: gridSpacing) {
                        ForEach(items) { item in
                            NavigationLink(destination: jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                                MediaThumbCard(item: item, server: server, showProgress: false, cardWidth: nil, onPlay: onPlay != nil ? { onPlay?(item) } : nil)
                            }
                            .buttonStyle(PlainButtonStyle())
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
                    .padding(.horizontal, gridPadding)
                    .padding(.vertical, gridPadding)
                case .list:
                    LazyVStack(spacing: 12) {
                        ForEach(items) { item in
                            NavigationLink(destination: jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                                JellyfinLibraryListRow(item: item, server: server, onPlay: onPlay != nil ? { onPlay?(item) } : nil)
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
        .libraryChildNavigationBarCompat()
        .appErrorAlert(
            message: $errorMessage,
            title: NSLocalizedString("Couldn't load library", comment: ""),
            retryTitle: NSLocalizedString("Retry", comment: ""),
            retryAction: {
                Task { await loadItems() }
            }
        )
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
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
            provider: "jellyfin",
            serverId: server.id.uuidString,
            libraryId: "container-\(container.id)",
            defaultMode: .poster
        )
    }

    private func setDisplayMode(_ mode: LibraryDisplayMode) {
        displayMode = mode
        settings.saveLibraryDisplayMode(
            provider: "jellyfin",
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
            let response: JellyfinItemsResponse
            switch container.type {
            case "Playlist":
                response = try await JellyfinService.shared.getPagedPlaylistItems(
                    server: server,
                    userId: userId,
                    token: token,
                    playlistId: container.id,
                    startIndex: currentStartIndex,
                    limit: pageSize
                )
            default:
                response = try await JellyfinService.shared.getItems(
                    server: server,
                    userId: userId,
                    token: token,
                    libraryId: container.id,
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    startIndex: currentStartIndex,
                    limit: pageSize,
                    recursive: false
                )
            }

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

struct JellyfinLibraryListRow: View {
    let item: JellyfinItem
    let server: ServerConfig
    @ObservedObject private var offlineIndex = OfflineMediaIndexStore.shared
    @ObservedObject private var remotePlaybackState = RemotePlaybackStateStore.shared
    var onPlay: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: item.primaryImageURL(server: server, maxWidth: 240))
                .aspectRatio(2/3, contentMode: .fill)
                .frame(width: 72, height: 108)
                .cornerRadius(8)
                .clipped()

            VStack(alignment: .leading, spacing: 7) {
                Text(item.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundColor(.primary)

                if let subtitle = displaySubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if hasMetadata {
                    HStack(spacing: 8) {
                        if isDownloaded {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.green)
                        }

                        if let year = item.productionYear {
                            Text(String(year))
                        }

                        if let runtime = runtimeText {
                            Text(runtime)
                        }

                        if let rating = item.communityRating, rating > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundColor(.yellow)
                                Text(String(format: "%.1f", rating))
                            }
                        }

                        if let resolution = resolutionText {
                            Text(resolution)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(3)
                        }

                        if let fileSize = fileSizeText {
                            Text(fileSize)
                        }

                        if let officialRating = item.officialRating, !officialRating.isEmpty {
                            Text(officialRating)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color.secondary.opacity(0.45), lineWidth: 0.6)
                                )
                        }

                        if let episodeCode = episodeCodeText {
                            Text(episodeCode)
                        }

                        if let countText = childCountText {
                            Text(countText)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }

                if let summary = summaryText {
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                if let progress = effectiveUserData?.playedPercentage, progress > 0 {
                    ProgressView(value: progress / 100.0)
                        .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                        .frame(maxWidth: 180)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
        .contentShape(Rectangle())
        .modifier(JellyfinMediaContextMenuModifier(item: item, server: server, onPlay: onPlay))
    }

    private var cleanedOverview: String? {
        guard let text = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private var summaryText: String? {
        if let overview = cleanedOverview {
            return overview
        }

        if let genres = item.genres, !genres.isEmpty {
            return genres.joined(separator: " / ")
        }

        return nil
    }

    private var displaySubtitle: String? {
        guard let subtitle = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty else {
            return nil
        }
        if let year = item.productionYear, subtitle == String(year) {
            return nil
        }
        return subtitle
    }

    private var isDownloaded: Bool {
        offlineIndex.isDownloaded(serverId: server.id, remoteItemId: item.id)
    }

    private var effectiveUserData: JellyfinUserData? {
        jellyfinEffectiveUserData(
            for: item,
            serverId: server.id,
            remotePlaybackState: remotePlaybackState
        )
    }

    private var hasMetadata: Bool {
        item.productionYear != nil ||
        runtimeText != nil ||
        ((item.communityRating ?? 0) > 0) ||
        resolutionText != nil ||
        fileSizeText != nil ||
        (item.officialRating?.isEmpty == false) ||
        episodeCodeText != nil ||
        childCountText != nil
    }

    private var runtimeText: String? {
        guard let ticks = item.runTimeTicks, ticks > 0 else { return nil }
        let totalMinutes = Int(ticks / 10_000_000 / 60)
        guard totalMinutes > 0 else { return nil }

        if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if minutes == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(minutes)m"
        }
        return "\(totalMinutes)m"
    }

    private var resolutionText: String? {
        item.videoResolutionLabel
    }

    private var fileSizeText: String? {
        guard let size = item.mediaSources?.first?.size, size > 0 else { return nil }
        return formatBytes(size)
    }

    private var episodeCodeText: String? {
        guard item.type == "Episode",
              let season = item.parentIndexNumber,
              let episode = item.indexNumber else {
            return nil
        }
        return "S\(String(format: "%02d", season))E\(String(format: "%02d", episode))"
    }

    private var childCountText: String? {
        if item.type == "Series" {
            if let seasons = item.childCount, seasons > 0 {
                return seasons == 1 ? "1 \(NSLocalizedString("Season", comment: ""))" : "\(seasons) \(NSLocalizedString("Seasons", comment: ""))"
            }
            if let episodes = item.recursiveItemCount, episodes > 0 {
                return episodes == 1 ? String(format: NSLocalizedString("%d Episode", comment: ""), 1) : String(format: NSLocalizedString("%d Episodes", comment: ""), episodes)
            }
        }
        if item.type == "Season", let episodes = item.childCount, episodes > 0 {
            return episodes == 1 ? String(format: NSLocalizedString("%d Episode", comment: ""), 1) : String(format: NSLocalizedString("%d Episodes", comment: ""), episodes)
        }
        if (item.type == "Playlist" || item.type == "BoxSet" || item.type == "Folder" || item.type == "MusicAlbum"),
           let count = item.childCount ?? item.recursiveItemCount,
           count > 0 {
            return count == 1 ? "1 \(NSLocalizedString("Item", comment: ""))" : "\(count) \(NSLocalizedString("Items", comment: ""))"
        }
        return nil
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Item Detail View

struct JellyfinItemDetailView: View {
    let server: ServerConfig
    let item: JellyfinItem
    var onExit: (() -> Void)? = nil
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var initialSeasonId: String? = nil
    var initialEpisodeId: String? = nil
    
    @State private var isFavorite = false
    @State private var showFullOverviewSheet = false
    @State private var childItems: [JellyfinItem] = []      // Current display items (Seasons or Episodes)
    @State private var seasons: [JellyfinItem] = []        // All seasons if this is a Series
    @State private var selectedSeasonId: String? = nil     // Current selected season ID
    @State private var hasUserSelectedSeason = false
    @State private var isLoadingChildren = false
    @State private var playlistItems: [VideoFile]? = nil
    @State private var isPreparingPlaylist = false
    
    // Additional Metadata
    @State private var people: [JellyfinPerson] = []
    @State private var similarItems: [JellyfinItem] = []
    
    // Playback state
    @State private var playingFile: VideoFile? = nil
    @State private var errorMessage: String = ""
    @State private var showErrorAlert: Bool = false
    @State private var showingDeleteAlert = false
    @State private var itemToDelete: JellyfinItem? = nil
    @State private var isDeleting = false
    @AppStorage("allowMediaServerDeletion") private var allowMediaServerDeletion = false
    @State private var nextUpItem: JellyfinItem? = nil
    @State private var pendingEpisodeId: String? = nil
    @State private var showPrePlaybackOptions = false
    @State private var isLoadingPrePlaybackOptions = false
    @State private var prePlaybackTargetItem: JellyfinItem? = nil
    @State private var prePlaybackQualityOptions: [PrePlaybackTrackOption] = []
    @State private var prePlaybackAudioOptions: [PrePlaybackTrackOption] = []
    @State private var prePlaybackSubtitleOptions: [PrePlaybackTrackOption] = []
    @State private var prePlaybackExternalSubtitleCandidates: [ExternalSubtitleCandidate] = []
    @State private var selectedPrePlaybackQualityID: String? = AppSettings.shared.defaultRemotePlaybackQualityOption.id
    @State private var selectedPrePlaybackAudioID: String? = nil
    @State private var selectedPrePlaybackSubtitleID: String? = nil
    @State private var canShowPrePlaybackOptions = false
    @State private var isPlayed = false
    @State private var isUpdatingPlayedState = false
    @State private var offlineState: DownloadAggregateState = .notDownloaded
    @State private var pendingDownloadItem: JellyfinItem? = nil
    @State private var pendingSeasonDownloadItems: [JellyfinItem] = []
    @State private var pendingSeasonDownloadTitle: String?
    @State private var isShowingDownloadConfirmSheet = false
    @State private var isShowingDownloadCenter = false
    @State private var downloadToastMessage: String? = nil
    @StateObject private var backdropReadability = AdaptiveBackdropReadabilityModel()
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var remotePlaybackState = RemotePlaybackStateStore.shared
    
    private var streamPlaybackURL: URL? {
        let mediaSource = item.mediaSources?.first
        let token = server.accessToken ?? ""
        return JellyfinService.shared.resolvePlaybackURL(server: server, itemId: item.id, token: token, mediaSource: mediaSource)
            ?? JellyfinService.shared.getStreamURL(server: server, itemId: item.id, token: token, mediaSourceId: mediaSource?.id)
    }

    private var backgroundImageUrl: URL? {
        item.spotlightBackdropImageURL(server: server)
    }

    private var effectiveItemUserData: JellyfinUserData? {
        effectiveUserData(for: item)
    }

    private var effectiveIsPlayed: Bool {
        effectiveItemUserData?.played ?? isPlayed
    }

    private var downloadTargetItem: JellyfinItem? {
        item.isPlayable ? item : nil
    }

    private var currentOfflineTargetIds: [String] {
        if item.isPlayable {
            return [item.id]
        }
        let playableChildren = childItems.filter(\.isPlayable).map(\.id)
        if !playableChildren.isEmpty {
            return playableChildren
        }
        return []
    }

    private var selectedSeasonEpisodes: [JellyfinItem] {
        childItems.filter(\.isPlayable)
    }

    private var selectedSeasonDownloadState: DownloadAggregateState {
        downloadCenter.aggregateState(serverId: server.id, remoteItemIds: selectedSeasonEpisodes.map(\.id))
    }

    private var currentSeasonTitle: String {
        if item.type == "Series",
           let selectedSeason = seasons.first(where: { $0.id == selectedSeasonId }) {
            return "\(item.name) - \(selectedSeason.name)"
        }
        if item.type == "Season", let seriesName = item.seriesName {
            return "\(seriesName) - \(item.name)"
        }
        return item.displayTitle
    }

    private var preferredSeriesSeasonId: String? {
        initialSeasonId ?? nextUpItem?.seasonId
    }

    private var seasonDownloadCandidates: [JellyfinItem] {
        selectedSeasonEpisodes.filter { episode in
            switch downloadCenter.taskStatus(serverId: server.id, remoteItemId: episode.id) {
            case .queued, .downloading, .paused, .completed:
                return false
            default:
                return true
            }
        }
    }

    private var canShowSeasonDownloadButton: Bool {
        (item.type == "Series" || item.type == "Season") && !selectedSeasonEpisodes.isEmpty
    }

    private var canQueueSelectedSeasonDownload: Bool {
        !seasonDownloadCandidates.isEmpty
    }

    private var downloadTaskStatus: DownloadTaskStatus? {
        guard let target = downloadTargetItem else { return nil }
        return downloadCenter.taskStatus(serverId: server.id, remoteItemId: target.id)
    }

    private var downloadButtonIcon: String {
        switch downloadTaskStatus {
        case .completed, .downloading, .queued, .paused:
            return "arrow.down.circle.fill"
        default:
            return "arrow.down.circle"
        }
    }

    private var downloadActionColor: Color {
        switch downloadTaskStatus {
        case .completed:
            return .green
        case .downloading, .queued, .paused:
            return Color(UIColor.systemBlue)
        default:
            return .white
        }
    }

    private var canQueueCurrentItemDownload: Bool {
        guard downloadTargetItem != nil else { return false }
        switch downloadTaskStatus {
        case .queued, .downloading, .paused, .completed:
            return false
        default:
            return true
        }
    }

    private var offlineBadgeIcon: String {
        switch offlineState {
        case .downloaded:
            return "arrow.down.circle.fill"
        case .partiallyDownloaded, .queued, .downloading:
            return "arrow.down.circle"
        case .failed:
            return "exclamationmark.arrow.trianglehead.clockwise"
        case .notDownloaded:
            return "arrow.down.circle"
        }
    }

    private var offlineBadgeTitle: String {
        switch offlineState {
        case .downloaded:
            return NSLocalizedString("Offline Available", comment: "")
        case .partiallyDownloaded:
            return NSLocalizedString("Partially Offline", comment: "")
        case .queued:
            return NSLocalizedString("Queued", comment: "")
        case .downloading:
            return NSLocalizedString("Downloading...", comment: "")
        case .failed:
            return NSLocalizedString("Offline Needs Attention", comment: "")
        case .notDownloaded:
            return NSLocalizedString("Not Downloaded", comment: "")
        }
    }

    private var offlineBadgeBackground: Color {
        switch offlineState {
        case .downloaded:
            return Color.green.opacity(0.22)
        case .partiallyDownloaded, .queued, .downloading:
            return Color(UIColor.systemBlue).opacity(0.22)
        case .failed:
            return Color.red.opacity(0.2)
        case .notDownloaded:
            return Color.white.opacity(0.14)
        }
    }

    private var selectedSeasonButtonTitle: String {
        switch selectedSeasonDownloadState {
        case .downloaded:
            return NSLocalizedString("Season Downloaded", comment: "")
        case .downloading(let completed, let total):
            return "\(NSLocalizedString("Downloading Season", comment: "")) \(completed)/\(total)"
        case .queued(let completed, let total):
            return "\(NSLocalizedString("Queued Season", comment: "")) \(completed)/\(total)"
        case .partiallyDownloaded(let completed, let total):
            return "\(NSLocalizedString("Download Remaining", comment: "")) \(completed)/\(total)"
        case .failed:
            return NSLocalizedString("Retry Season Download", comment: "")
        case .notDownloaded:
            return NSLocalizedString("Download Season", comment: "")
        }
    }

    private var seasonDownloadRowDetail: String? {
        switch selectedSeasonDownloadState {
        case .notDownloaded:
            return nil
        default:
            return selectedSeasonButtonTitle
        }
    }

    private var seasonDownloadRowLeadingIcon: String {
        switch selectedSeasonDownloadState {
        case .downloaded:
            return "arrow.down.circle.fill"
        case .partiallyDownloaded, .queued, .downloading:
            return "arrow.down.circle"
        case .failed:
            return "exclamationmark.arrow.trianglehead.clockwise"
        case .notDownloaded:
            return "arrow.down.circle"
        }
    }

    private var seasonDownloadRowTrailingIcon: String {
        switch selectedSeasonDownloadState {
        case .downloaded:
            return "arrow.down.circle.fill"
        case .queued, .downloading:
            return "arrow.down.circle.fill"
        case .failed:
            return "exclamationmark.arrow.trianglehead.clockwise"
        case .partiallyDownloaded, .notDownloaded:
            return "arrow.down.circle"
        }
    }

    private var seasonDownloadRowTint: Color {
        switch selectedSeasonDownloadState {
        case .downloaded:
            return .green
        case .partiallyDownloaded, .queued, .downloading:
            return Color(UIColor.systemBlue)
        case .failed:
            return .red
        case .notDownloaded:
            return Color.accentColor
        }
    }

    private var seasonDownloadButtonColor: Color {
        switch selectedSeasonDownloadState {
        case .downloaded:
            return .green
        case .partiallyDownloaded, .queued, .downloading:
            return Color(UIColor.systemBlue)
        case .failed:
            return .red
        case .notDownloaded:
            return Color.white.opacity(0.9)
        }
    }

    private var localFavoritePlayableFile: VideoFile? {
        guard let targetItemId = localFavoriteTargetItemId,
              let identityURL = URL(string: "\(server.fullURL)/Items/\(targetItemId)") else {
            return nil
        }

        return VideoFile(
            name: localFavoriteDisplayName,
            url: identityURL,
            type: localFavoriteFileType,
            size: 0,
            date: Date(),
            isRemote: true,
            lastPlayedPosition: targetItemId == item.id
                ? jellyfinPlaybackPositionSeconds(
                    from: effectiveItemUserData,
                    runtimeTicks: item.runTimeTicks,
                    playedOverride: effectiveIsPlayed
                )
                : nil,
            jellyfinItemId: targetItemId,
            jellyfinServerId: server.id.uuidString,
            serverType: server.type,
            seriesId: localFavoriteSeriesId,
            seasonId: nil
        )
    }

    private var localFavoriteIdentityPath: String? {
        guard let targetItemId = localFavoriteTargetItemId else { return nil }
        return "__jellyfin_item__/\(targetItemId)"
    }

    private var isInLocalFavorites: Bool {
        guard let file = localFavoritePlayableFile,
              let identityPath = localFavoriteIdentityPath else {
            return false
        }
        return favoriteService.isFavorite(file: file, folderPath: identityPath)
    }

    private var localFavoriteTargetItemId: String? {
        switch item.type {
        case "Series":
            return item.id
        case "Episode", "Season":
            return item.seriesId
        default:
            return item.isPlayable ? item.id : nil
        }
    }

    private var localFavoriteDisplayName: String {
        switch item.type {
        case "Episode", "Season":
            return item.seriesName ?? item.displayTitle
        default:
            return item.displayTitle
        }
    }

    private var localFavoriteSeriesId: String? {
        switch item.type {
        case "Series":
            return item.id
        case "Episode", "Season":
            return item.seriesId
        default:
            return item.seriesId
        }
    }

    private var localFavoriteFileType: VideoFile.FileType {
        item.type == "Audio" ? .audio : .video
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                
                // Base background (Fullscreen Blurred Image)
                if let bgUrl = backgroundImageUrl {
                    RemoteImage(url: bgUrl, onImageLoaded: { image in
                            backdropReadability.update(from: image)
                        })
                        .scaleEffect(1.2, anchor: .top)
                        .aspectRatio(contentMode: .fill)
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                        .ignoresSafeArea()
                        .blur(radius: 40)
                        .overlay(Color.black.opacity(backdropReadability.style.baseOverlayOpacity))
                }
                
                // Clear Backdrop Image at top (Backdrop or Primary fallback)
                if let headerUrl = backgroundImageUrl {
                    VStack(spacing: 0) {
                        ZStack(alignment: .topTrailing) {
                            RemoteImage(url: headerUrl)
                                .scaleEffect(1.2, anchor: .top)
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width, height: geometry.size.height * 0.42, alignment: .top)
                                .clipped()
                                .overlay(
                                    LinearGradient(
                                        colors: [
                                            Color.black.opacity(backdropReadability.style.heroTopOpacity),
                                            Color.black.opacity(backdropReadability.style.heroUpperMidOpacity),
                                            Color.black.opacity(backdropReadability.style.heroLowerMidOpacity),
                                            Color.black.opacity(backdropReadability.style.heroBottomOpacity)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .mask(
                                    LinearGradient(
                                        colors: [.black, .black, .black, .clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            
                            // Top overlay ClearLogo (matching Jellyfin Web UI style)
                            if horizontalSizeClass == .regular || geometry.size.width > 600 {
                                if let logoUrl = item.logoImageURL(server: server) {
                                    let fallbackInset: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 54 : 47
                                    let logoTopInset = max(UIApplication.currentSafeAreaInsets().top, fallbackInset)
                                    RemoteLogoImage(url: logoUrl, maxHeight: 75)
                                        .padding(.top, logoTopInset + 20)
                                        .padding(.trailing, 96)
                                        .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 3)
                                }
                            }
                        }
                        Spacer()
                    }
                    .ignoresSafeArea()
                }
                
                ScrollViewReader { scrollProxy in
                    ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: horizontalSizeClass == .regular || geometry.size.width > 600 ? .leading : .center, spacing: 20) {
                        // Dynamic spacer for safe area - use global window inset as GeometryReader edge ignore may zero it out
                        let fallbackInset: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 54 : 47
                        let topInset = max(UIApplication.currentSafeAreaInsets().top, fallbackInset)
                        Spacer().frame(height: topInset + 44)
                        
                        if horizontalSizeClass == .regular || geometry.size.width > 600 {
                            // Wide / Mac / iPad Horizontal Hero Layout
                            HStack(alignment: .top, spacing: 24) {
                                // Poster Image
                                RemoteImage(url: item.primaryImageURL(server: server))
                                    .aspectRatio(2/3, contentMode: .fill)
                                    .frame(width: 160, height: 240)
                                    .cornerRadius(12)
                                    .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 5)
                                
                                // Metadata & Action Column
                                VStack(alignment: .leading, spacing: 10) {
                                    // Title
                                    Text(item.name)
                                        .font(.system(size: 26, weight: .bold))
                                        .foregroundColor(.white)
                                        .lineLimit(2)
                                    
                                    // Subtitle for episodes
                                    if item.type == "Episode", let seriesName = item.seriesName {
                                        Text(seriesName)
                                            .font(.system(size: 15))
                                            .foregroundColor(.white.opacity(0.72))
                                    }

                                    HStack(spacing: 6) {
                                        Image(systemName: offlineBadgeIcon)
                                            .font(.caption)
                                        Text(offlineBadgeTitle)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(offlineBadgeBackground)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)

                                    // Metadata Row
                                    jellyfinMetadataRow
                                    
                                    // Overview (Truncated to 3 lines, click to view full modal)
                                    if let overview = item.overview, !overview.isEmpty {
                                        Button(action: { showFullOverviewSheet = true }) {
                                            (Text(overview)
                                                .foregroundColor(.white.opacity(0.82))
                                             + Text("  " + NSLocalizedString("More", comment: "")).bold().foregroundColor(Color.accentColor))
                                                .font(.system(size: 14))
                                                .lineLimit(3)
                                                .multilineTextAlignment(.leading)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .padding(.vertical, 2)
                                    }

                                    // Info Box (Providers, Genres)
                                    if (item.providerIds != nil && !item.providerIds!.isEmpty) || 
                                       (item.genres != nil && !item.genres!.isEmpty) {
                                        MetadataInfoView(
                                            providerIds: item.providerIds,
                                            genres: item.genres,
                                            people: item.people,
                                            alignment: .leading
                                        )
                                    }
                                    
                                    // Play & Action Buttons
                                    jellyfinActionButtons
                                }
                            }
                            .padding(.horizontal, 24)
                        } else {
                            // Compact Vertical Layout (iPhone)
                            VStack(alignment: .center, spacing: 16) {
                                // Poster Image (Centered)
                                RemoteImage(url: item.primaryImageURL(server: server))
                                    .aspectRatio(2/3, contentMode: .fill)
                                    .frame(width: 140, height: 210)
                                    .cornerRadius(12)
                                    .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 5)
                                
                                // Metadata Section (Centered)
                                VStack(alignment: .center, spacing: 8) {
                                    if let logoUrl = item.logoImageURL(server: server) {
                                        RemoteLogoImage(url: logoUrl, maxHeight: 42)
                                            .shadow(color: Color.black.opacity(0.60), radius: 8, x: 0, y: 3)
                                            .padding(.bottom, 4)
                                    }

                                    Text(item.name)
                                        .font(.system(size: 24, weight: .bold))
                                        .foregroundColor(.white)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal)
                                    
                                    // Subtitle for episodes
                                    if item.type == "Episode", let seriesName = item.seriesName {
                                        Text(seriesName)
                                            .font(.system(size: 14))
                                            .foregroundColor(.white.opacity(0.72))
                                    }

                                    HStack(spacing: 6) {
                                        Image(systemName: offlineBadgeIcon)
                                            .font(.caption)
                                        Text(offlineBadgeTitle)
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(offlineBadgeBackground)
                                    .foregroundColor(.white)
                                    .cornerRadius(10)

                                    // Metadata Row
                                    jellyfinMetadataRow
                                    
                                    // Overview (Truncated to 3 lines, click to view full modal)
                                    if let overview = item.overview, !overview.isEmpty {
                                        Button(action: { showFullOverviewSheet = true }) {
                                            (Text(overview)
                                                .foregroundColor(.white.opacity(0.82))
                                             + Text("  " + NSLocalizedString("More", comment: "")).bold().foregroundColor(Color.accentColor))
                                                .font(.system(size: 13))
                                                .lineLimit(3)
                                                .multilineTextAlignment(.center)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .padding(.horizontal)
                                        .padding(.top, 4)
                                    }

                                    // Info Box (Providers, Genres)
                                    if (item.providerIds != nil && !item.providerIds!.isEmpty) || 
                                       (item.genres != nil && !item.genres!.isEmpty) {
                                        MetadataInfoView(
                                            providerIds: item.providerIds,
                                            genres: item.genres,
                                            people: item.people
                                        )
                                        .padding(.horizontal)
                                    }
                                }
                                
                                // Play & Action Buttons
                                jellyfinActionButtons
                            }
                        }
                    }
                    .padding(.bottom, 20)
                    .onAppear {
                        isFavorite = effectiveItemUserData?.isFavorite ?? false
                        isPlayed = effectiveItemUserData?.played ?? false
                        if item.type != "Series" {
                            canShowPrePlaybackOptions = false
                            Task { await refreshPrePlaybackOptionAvailability() }
                        } else {
                            canShowPrePlaybackOptions = false
                        }
                    }
                    
                // Content Section
                VStack(alignment: .leading, spacing: 24) {
                    
                    // MARK: - Next Up (Series only)
                    if item.type == "Series", let nextUp = nextUpItem {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(NSLocalizedString("Next Up", comment: ""))
                                .font(.headline)
                                .foregroundColor(.white)
                                .padding(.horizontal)
                            
                            Button(action: { playEpisode(nextUp, playbackQualityID: immediatePlaybackQualityID) }) {
                                VStack(alignment: .leading, spacing: 0) {
                                    ZStack(alignment: .bottomLeading) {
                                        RemoteImage(url: nextUp.primaryImageURL(server: server, maxWidth: 600))
                                            .aspectRatio(16/9, contentMode: .fill)
                                            .frame(height: 180)
                                            .clipped()
                                            .cornerRadius(8)
                                            .overlay(
                                                // Play icon overlay
                                                Image(systemName: "play.circle.fill")
                                                    .font(.system(size: 44))
                                                    .foregroundColor(.white.opacity(0.9))
                                                    .shadow(radius: 4)
                                            )
                                        
                                        // Progress bar
                                        if let progress = effectiveUserData(for: nextUp)?.playedPercentage, progress > 0 {
                                            GeometryReader { geo in
                                                VStack {
                                                    Spacer()
                                                    Rectangle()
                                                        .fill(Color.accentColor)
                                                        .frame(width: geo.size.width * CGFloat(progress / 100), height: 3)
                                                }
                                            }
                                            .cornerRadius(8)
                                        }
                                    }
                                    
                                    // Episode info
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(nextUp.displayTitle)
                                                .font(.system(size: 14, weight: .medium))
                                                .foregroundColor(.white)
                                                .lineLimit(1)
                                            HStack(spacing: 4) {
                                                if let s = nextUp.parentIndexNumber, let e = nextUp.indexNumber {
                                                    Text("S\(s):E\(e)")
                                                }
                                                if let runtime = nextUp.runTimeTicks.flatMap({ $0 / 600000000 }) {
                                                    Text("· \(runtime) \(NSLocalizedString("Minutes", comment: ""))")
                                                }
                                            }
                                            .font(.system(size: 12))
                                            .foregroundColor(.white.opacity(0.64))

                                            let detailSegments = jellyfinDetailMetadataSegments(for: nextUp)
                                            if !detailSegments.isEmpty {
                                                Text(detailSegments.joined(separator: " • "))
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.white.opacity(0.68))
                                                    .lineLimit(1)
                                                    .minimumScaleFactor(0.8)
                                            }
                                        }
                                        Spacer()
                                    }
                                    .padding(.vertical, 8)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .contextMenu {
                                Button(action: { playEpisode(nextUp, playbackQualityID: immediatePlaybackQualityID) }) {
                                    Label(NSLocalizedString("Play", comment: ""), systemImage: "play.fill")
                                }
                                Button(action: {
                                    Task { await toggleChildPlayed(nextUp) }
                                }) {
                                    let isChildPlayed = effectiveUserData(for: nextUp)?.played ?? false
                                    Label(
                                        isChildPlayed ? NSLocalizedString("Mark as Unplayed", comment: "") : NSLocalizedString("Mark as Played", comment: ""),
                                        systemImage: isChildPlayed ? "xmark.circle" : "checkmark.circle"
                                    )
                                }
                                if canQueueEpisodeDownload(nextUp) {
                                    Button(action: { requestEpisodeDownload(nextUp) }) {
                                        Label(NSLocalizedString("Download", comment: ""), systemImage: "arrow.down.circle")
                                    }
                                }
                                if allowMediaServerDeletion {
                                    if #available(iOS 15.0, *) {
                                        Button(role: .destructive, action: {
                                            itemToDelete = nextUp
                                            showingDeleteAlert = true
                                        }) {
                                            Label(NSLocalizedString("Delete from Server", comment: ""), systemImage: "trash")
                                        }
                                    } else {
                                        Button(action: {
                                            itemToDelete = nextUp
                                            showingDeleteAlert = true
                                        }) {
                                            Label(NSLocalizedString("Delete from Server", comment: ""), systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .frame(minWidth: 0, maxWidth: 560, alignment: .leading)
                            .padding(.horizontal)
                        }
                    }
                    
                    // Children Section (Seasons/Episodes/Playlist Items)
                    if item.isContainer || !seasons.isEmpty {
                        VStack(alignment: .leading, spacing: 20) {
                            // Season Selector for Series
                            if item.type == "Series" && !seasons.isEmpty {
                                MediaSectionHeaderLabel(
                                    title: NSLocalizedString("Seasons", comment: ""),
                                    systemImage: childrenSectionIcon,
                                    foregroundColor: .white,
                                    font: .headline,
                                    weight: .bold
                                )
                                .padding(.horizontal)

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 16) {
                                            ForEach(seasons) { season in
                                                Button(action: {
                                                    pendingEpisodeId = nil
                                                    hasUserSelectedSeason = true
                                                    selectedSeasonId = season.id
                                                    Task { await loadEpisodes(for: season.id) }
                                                }) {
                                                    Text(season.name)
                                                        .font(.system(size: 16, weight: selectedSeasonId == season.id ? .bold : .medium))
                                                    .foregroundColor(selectedSeasonId == season.id ? .white : .white.opacity(0.72))
                                                    .padding(.vertical, 8)
                                                    .padding(.horizontal, 16)
                                                    .background(
                                                        Capsule()
                                                            .fill(selectedSeasonId == season.id ? Color.accentColor : Color.white.opacity(0.1))
                                                    )
                                            }
                                            .contextMenu {
                                                if allowMediaServerDeletion {
                                                    if #available(iOS 15.0, *) {
                                                        Button(role: .destructive, action: {
                                                            itemToDelete = season
                                                            showingDeleteAlert = true
                                                        }) {
                                                            Label(NSLocalizedString("Delete from Server", comment: ""), systemImage: "trash")
                                                        }
                                                    } else {
                                                        Button(action: {
                                                            itemToDelete = season
                                                            showingDeleteAlert = true
                                                        }) {
                                                            Label(NSLocalizedString("Delete from Server", comment: ""), systemImage: "trash")
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                                .padding(.top, 8)
                            } else if item.type != "Season" {
                                MediaSectionHeaderLabel(
                                    title: childrenTitle,
                                    systemImage: childrenSectionIcon,
                                    foregroundColor: .white,
                                    font: .headline,
                                    weight: .bold
                                )
                                    .padding(.horizontal)
                            }

                            if item.type == "Series" || item.type == "Season" {
                                HStack(spacing: 12) {
                                    MediaSectionHeaderLabel(
                                        title: episodeSectionTitle,
                                        systemImage: episodeSectionIcon,
                                        foregroundColor: .white,
                                        font: .headline,
                                        weight: .bold
                                    )

                                    Spacer(minLength: 0)

                                    if canShowSeasonDownloadButton {
                                        Button(action: {
                                            requestSelectedSeasonDownload()
                                        }) {
                                            Image(systemName: seasonDownloadRowTrailingIcon)
                                                .font(.title2)
                                                .foregroundColor(seasonDownloadButtonColor)
                                                .frame(width: 36, height: 36)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                        .disabled(!canQueueSelectedSeasonDownload)
                                    }
                                }
                                .padding(.horizontal)
                            }
                            
                            if isLoadingChildren {
                                ProgressView()
                                    .frame(maxWidth: .infinity, minHeight: 120)
                            } else if childItems.isEmpty {
                                if item.type == "Series" || item.type == "Season" {
                                    emptySeasonCard(onDelete: {
                                        if item.type == "Series", let currentSeason = seasons.first(where: { $0.id == selectedSeasonId }) {
                                            itemToDelete = currentSeason
                                            showingDeleteAlert = true
                                        } else if item.type == "Season" {
                                            itemToDelete = item
                                            showingDeleteAlert = true
                                        }
                                    })
                                } else {
                                    Text(NSLocalizedString("No items found", comment: ""))
                                        .foregroundColor(.white.opacity(0.62))
                                        .frame(maxWidth: .infinity, minHeight: 60)
                                        .padding(.horizontal)
                                }
                            } else {
                                // Vertical list of episodes/items
                                LazyVStack(spacing: 16) {
                                    ForEach(childItems) { child in
                                        if child.isPlayable {
                                            HStack(spacing: 12) {
                                                Button(action: { playChildItem(child) }) {
                                                    HStack(spacing: 16) {
                                                        ZStack(alignment: .bottomLeading) {
                                                            RemoteImage(url: child.primaryImageURL(server: server, maxWidth: 300))
                                                                .aspectRatio(16/9, contentMode: .fill)
                                                                .frame(width: 120, height: 68)
                                                                .cornerRadius(8)
                                                                .clipped()

                                                            if let progress = effectiveUserData(for: child)?.playedPercentage, progress > 0 {
                                                                Rectangle()
                                                                    .fill(Color.accentColor)
                                                                    .frame(width: 120 * CGFloat(progress / 100), height: 3)
                                                            }
                                                        }

                                                        VStack(alignment: .leading, spacing: 4) {
                                                            Text(child.displayTitle)
                                                                .font(.system(size: 15, weight: .semibold))
                                                                .foregroundColor(.white)
                                                                .lineLimit(2)

                                                            HStack(spacing: 8) {
                                                                if let epNum = child.indexNumber {
                                                                    Text(String(format: NSLocalizedString("Episode %d", comment: ""), epNum))
                                                                }
                                                                if let runtime = child.runTimeTicks.flatMap({ $0 / 600000000 }) {
                                                                    Text("• \(runtime) \(NSLocalizedString("Minutes", comment: ""))")
                                                                }
                                                            }
                                                            .font(.system(size: 12))
                                                            .foregroundColor(.white.opacity(0.72))

                                                            let detailSegments = jellyfinDetailMetadataSegments(for: child)
                                                            if !detailSegments.isEmpty {
                                                                Text(detailSegments.joined(separator: " • "))
                                                                    .font(.system(size: 11))
                                                                    .foregroundColor(.white.opacity(0.62))
                                                                    .lineLimit(1)
                                                                    .minimumScaleFactor(0.8)
                                                            }
                                                        }

                                                        Spacer()

                                                        Image(systemName: "play.circle")
                                                            .font(.title2)
                                                            .foregroundColor(.white.opacity(0.9))
                                                    }
                                                    .contentShape(Rectangle())
                                                }
                                                .buttonStyle(PlainButtonStyle())

                                                Button(action: {
                                                    requestEpisodeDownload(child)
                                                }) {
                                                    Image(systemName: episodeDownloadIcon(for: child))
                                                        .font(.title2)
                                                        .foregroundColor(episodeDownloadColor(for: child))
                                                        .frame(width: 36, height: 36)
                                                }
                                                .buttonStyle(PlainButtonStyle())
                                                .disabled(!canQueueEpisodeDownload(child))

                                            }
                                            .padding(.horizontal)
                                            .id(episodeAnchorID(for: child.id))
                                            .contextMenu {
                                                Button(action: { playChildItem(child) }) {
                                                    Label(NSLocalizedString("Play", comment: ""), systemImage: "play.fill")
                                                }
                                                Button(action: {
                                                    Task { await toggleChildPlayed(child) }
                                                }) {
                                                    let isChildPlayed = effectiveUserData(for: child)?.played ?? false
                                                    Label(
                                                        isChildPlayed ? NSLocalizedString("Mark as Unplayed", comment: "") : NSLocalizedString("Mark as Played", comment: ""),
                                                        systemImage: isChildPlayed ? "xmark.circle" : "checkmark.circle"
                                                    )
                                                }
                                                if canQueueEpisodeDownload(child) {
                                                    Button(action: { requestEpisodeDownload(child) }) {
                                                        Label(NSLocalizedString("Download", comment: ""), systemImage: "arrow.down.circle")
                                                    }
                                                }
                                                if allowMediaServerDeletion {
                                                    if #available(iOS 15.0, *) {
                                                        Button(role: .destructive, action: {
                                                            itemToDelete = child
                                                            showingDeleteAlert = true
                                                        }) {
                                                            Label(NSLocalizedString("Delete from Server", comment: ""), systemImage: "trash")
                                                        }
                                                    } else {
                                                        Button(action: {
                                                            itemToDelete = child
                                                            showingDeleteAlert = true
                                                        }) {
                                                            Label(NSLocalizedString("Delete from Server", comment: ""), systemImage: "trash")
                                                        }
                                                    }
                                                }
                                            }
                                        } else {
                                            NavigationLink(destination: jellyfinNavigationDestination(server: server, item: child, onExit: onExit, onPlay: { playChildItem($0) })) {
                                                HStack(spacing: 16) {
                                                    RemoteImage(url: child.primaryImageURL(server: server, maxWidth: 200))
                                                        .aspectRatio(1, contentMode: .fill)
                                                        .frame(width: 80, height: 80)
                                                        .cornerRadius(8)
                                                        .clipped()
                                                    
                                                    VStack(alignment: .leading, spacing: 4) {
                                                        Text(child.displayTitle)
                                                            .font(.system(size: 16, weight: .medium))
                                                            .foregroundColor(.white)
                                                    }
                                                    Spacer()
                                                    Image(systemName: "chevron.right")
                                                        .foregroundColor(.white.opacity(0.62))
                                                }
                                                .padding(.horizontal)
                                            }
                                            .contextMenu {
                                                if allowMediaServerDeletion {
                                                    if #available(iOS 15.0, *) {
                                                        Button(role: .destructive, action: {
                                                            itemToDelete = child
                                                            showingDeleteAlert = true
                                                        }) {
                                                            Label(NSLocalizedString("Delete from Server", comment: ""), systemImage: "trash")
                                                        }
                                                    } else {
                                                        Button(action: {
                                                            itemToDelete = child
                                                            showingDeleteAlert = true
                                                        }) {
                                                            Label(NSLocalizedString("Delete from Server", comment: ""), systemImage: "trash")
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical)
                
                // MARK: - Cast & Crew
                if !people.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(NSLocalizedString("Cast & Crew", comment: ""))
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(people) { person in
                                    NavigationLink(destination: JellyfinPersonDetailView(server: server, person: person, onExit: onExit)) {
                                        JellyfinDetailPersonCard(server: server, person: person)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.horizontal)
                        }
                        .duoMediaShelfViewport()
                    }
                }
                
                // MARK: - Similar Items
                if !similarItems.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(NSLocalizedString("More Like This", comment: ""))
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.horizontal)
                        
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 16) {
                                ForEach(similarItems) { item in
                                    NavigationLink(destination: NavigationLazyView { AnyView(jellyfinNavigationDestination(server: server, item: item, onExit: onExit, onPlay: { playChildItem($0) })) }) {
                                        JellyfinDetailRelatedCard(server: server, item: item)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.horizontal)
                        }
                        .duoMediaShelfViewport()
                    }
                    .padding(.top, 20)
                }

                let filePath = item.mediaSources?.first?.path
                let streamURL = streamPlaybackURL
                if (filePath != nil && !filePath!.isEmpty) || streamURL != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(NSLocalizedString("Media Info", comment: ""))
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white.opacity(0.9))
                        
                        VStack(alignment: .leading, spacing: 12) {
                            // Server Info
                            HStack(alignment: .center, spacing: 8) {
                                Text(NSLocalizedString("Server Info", comment: ""))
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.6))
                                    .frame(width: 70, alignment: .leading)
                                
                                HStack(spacing: 4) {
                                    Image(systemName: "server.rack")
                                        .font(.caption2)
                                        .foregroundColor(Color.accentColor)
                                    Text(server.name)
                                        .font(.caption.weight(.medium))
                                        .foregroundColor(.white.opacity(0.9))
                                }
                                Spacer()
                            }
                            
                            if let path = filePath, !path.isEmpty {
                                Divider().background(Color.white.opacity(0.1))
                                
                                // File Path & Copy
                                HStack(alignment: .top, spacing: 8) {
                                    Text(NSLocalizedString("File Path", comment: ""))
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.6))
                                        .frame(width: 70, alignment: .leading)
                                    
                                    Text(path)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.8))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    
                                    Spacer(minLength: 4)
                                    
                                    Button(action: {
                                        #if os(iOS)
                                        UIPasteboard.general.string = path
                                        #elseif os(macOS)
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(path, forType: .string)
                                        #endif
                                        downloadToastMessage = NSLocalizedString("Path Copied to Clipboard", comment: "")
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "doc.on.doc")
                                            Text(NSLocalizedString("Copy Path", comment: ""))
                                        }
                                        .font(.caption)
                                        .foregroundColor(Color.accentColor)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.12))
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }

                            if let streamURL = streamURL {
                                Divider().background(Color.white.opacity(0.1))
                                
                                // Stream URL & Copy
                                HStack(alignment: .top, spacing: 8) {
                                    Text(NSLocalizedString("Stream URL", comment: ""))
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.6))
                                        .frame(width: 70, alignment: .leading)
                                    
                                    Text(streamURL.absoluteString)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.8))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    
                                    Spacer(minLength: 4)
                                    
                                    Button(action: {
                                        #if os(iOS)
                                        UIPasteboard.general.string = streamURL.absoluteString
                                        #elseif os(macOS)
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(streamURL.absoluteString, forType: .string)
                                        #endif
                                        downloadToastMessage = NSLocalizedString("Stream URL Copied to Clipboard", comment: "")
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "link")
                                            Text(NSLocalizedString("Copy Stream URL", comment: ""))
                                        }
                                        .font(.caption)
                                        .foregroundColor(Color.accentColor)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.white.opacity(0.12))
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.white.opacity(0.08))
                        .cornerRadius(10)
                    }
                    .padding(.horizontal)
                    .padding(.top, 20)
                }

                } // end outer VStack
                .mediaDetailHorizontalSafeAreaPadding(
                    usesWideLayout: horizontalSizeClass == .regular || geometry.size.width > 600
                )
                .padding(.bottom, 40)
                } // end ScrollView 1093
                .onAppear {
                    scrollToPendingEpisode(using: scrollProxy)
                }
                .onChange(of: childItems.map(\.id)) { _ in
                    scrollToPendingEpisode(using: scrollProxy)
                    if item.type != "Series" {
                        Task { await refreshPrePlaybackOptionAvailability() }
                    }
                }
                } // end ScrollViewReader
            } // end ZStack 1059
        } // end GeometryReader 1058
        .ignoresSafeArea(edges: [.top, .horizontal])
        .navigationBarTitle("", displayMode: .inline)
        .libraryChildNavigationBarCompat()
        .mediaLibraryNavigationToolbar {
            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                AppToolbarIcon(systemName: "chevron.left")
            }
        } home: {
            Button(action: { NavigationUtil.popToRootView() }) {
                AppToolbarIcon(systemName: "house")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                
                    Button(action: {
                        isShowingDownloadCenter = true
                    }) {
                        AppToolbarIcon(
                            systemName: "arrow.down.circle",
                            badgeCount: downloadCenter.activeJobs.count
                        )
                    }
                
            }
        }
        .hideNavigationBarBackground()
        .customBackButton()
        .fullScreenCover(item: $playingFile, onDismiss: {
            UIApplication.refreshInterfaceChrome()
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await refreshPlaybackContextFromServer()
            }
        }) { file in
            PlayerView(initialFile: file, playlist: $playlistItems)
        }
        .background(
            NavigationLink(
                destination: DownloadCenterView(),
                isActive: $isShowingDownloadCenter,
                label: { EmptyView() }
            )
        )
        .sheet(isPresented: $showPrePlaybackOptions) {
            PrePlaybackOptionsSheet(
                qualityOptions: prePlaybackQualityOptions,
                audioOptions: prePlaybackAudioOptions,
                subtitleOptions: prePlaybackSubtitleOptions,
                selectedQualityID: $selectedPrePlaybackQualityID,
                selectedAudioID: $selectedPrePlaybackAudioID,
                selectedSubtitleID: $selectedPrePlaybackSubtitleID,
                onConfirm: {
                    showPrePlaybackOptions = false
                    playWithPrePlaybackSelection()
                },
                onCancel: {
                    showPrePlaybackOptions = false
                }
            )
        }
        .alert(isPresented: $showErrorAlert) {
            Alert(
                title: Text(NSLocalizedString("Playback", comment: "")),
                message: Text(errorMessage),
                dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
            )
        }
        .appDownloadConfirmAlert(
            isPresented: $isShowingDownloadConfirmSheet,
            message: downloadConfirmMessage,
            onConfirm: {
                confirmPendingDownloadRequest()
            },
            onCancel: {
                pendingDownloadItem = nil
                pendingSeasonDownloadItems = []
                pendingSeasonDownloadTitle = nil
            }
        )
        .alert(isPresented: $showingDeleteAlert) {
            let target = itemToDelete ?? item
            return Alert(
                title: Text(NSLocalizedString("Delete from Server", comment: "")),
                message: Text(String(format: NSLocalizedString("Are you sure you want to delete \"%@\" from the server? This cannot be undone.", comment: ""), target.displayTitle)),
                primaryButton: .destructive(Text(NSLocalizedString("Delete", comment: ""))) {
                    Task { await deleteItem(target) }
                },
                secondaryButton: .cancel()
            )
        }
        .sheet(isPresented: $showFullOverviewSheet) {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if let overview = item.overview, !overview.isEmpty {
                            Text(overview)
                                .font(.body)
                                .lineSpacing(6)
                                .foregroundColor(.primary)
                        }
                    }
                    .padding(20)
                }
                .navigationTitle(NSLocalizedString("Overview", comment: ""))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: {
                            showFullOverviewSheet = false
                        }) {
                            AppToolbarIcon(systemName: "xmark", style: .secondary)
                        }
                        .accessibilityLabel(Text(NSLocalizedString("Close", comment: "")))
                    }
                }
            }
        }
        .floatingToast(message: $downloadToastMessage)
        .onReceive(NotificationCenter.default.publisher(for: .remotePlaybackStateDidChange)) { notification in
            guard let payload = notification.object as? PlaybackStateRefreshPayload else {
                return
            }
            handleRemotePlaybackRefresh(payload)
        }
        .onAppear {
            if backgroundImageUrl == nil {
                backdropReadability.reset()
            }
            if people.isEmpty, let existingPeople = item.people {
                people = existingPeople
            }
            pendingEpisodeId = initialEpisodeId
            if item.isContainer && (childItems.isEmpty || seasons.isEmpty) {
                Task { await loadChildren() }
            }
            Task { await loadMetadata() }
            if item.type == "Series" {
                Task { await loadNextUp() }
            }
            refreshOfflineAvailability()
        }
        .onChange(of: backgroundImageUrl) { newValue in
            if newValue == nil {
                backdropReadability.reset()
            }
        }
        .onChange(of: nextUpItem?.seasonId) { _ in
            applyPreferredSeriesSeasonIfNeeded()
        }
        .onChange(of: downloadCenter.tasks.count) { _ in
            refreshOfflineAvailability()
        }
        .onChange(of: childItems.map(\.id)) { _ in
            refreshOfflineAvailability()
        }
    }

    @ViewBuilder
    private var jellyfinMetadataRow: some View {
        HStack(spacing: 8) {
            if let year = item.productionYear {
                Text(String(year))
            }
            
            if let runtime = item.runtimeMinutes {
                Text(formatRuntime(runtime))
            }
            
            if let rating = item.communityRating {
                HStack(spacing: 2) {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                    Text(String(format: "%.1f", rating))
                }
            }
            
            if item.type == "Series" {
                if let count = item.childCount {
                    Text("\(count) \(NSLocalizedString("Seasons", comment: ""))")
                }
                if let epCount = item.recursiveItemCount {
                    Text("\(epCount) \(NSLocalizedString("Episodes", comment: ""))")
                }
            }
            
            // Resolution badge
            if let source = item.mediaSources?.first, let width = source.videoStream?.width {
                if width >= 3800 {
                    Text("4K")
                        .font(.caption2).fontWeight(.bold)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(3)
                } else if width >= 1900 {
                    Text("1080P")
                        .font(.caption2)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(3)
                }
            }
            
            if let source = item.mediaSources?.first, let size = source.size {
                Text(formatBytes(size))
            }
            
            if let officialRating = item.officialRating {
                Text(officialRating)
                    .font(.caption2)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .border(Color.white.opacity(0.5), width: 0.5)
            }
        }
        .font(.system(size: 13))
        .foregroundColor(.white.opacity(0.82))
        let technicalParts = MediaTechnicalMetadata.parts(video: item.mediaSources?.first?.videoStream?.toDictionary() ?? [:])
        if !technicalParts.isEmpty {
            Text(technicalParts.joined(separator: " · "))
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var jellyfinActionButtons: some View {
        VStack(alignment: horizontalSizeClass == .regular ? .leading : .center, spacing: 12) {
            if item.isPlayable || item.type == "Series" {
                PrimaryPlaybackCTAButton(
                    title: playButtonTitle,
                    progress: playButtonProgressInfo,
                    isLoading: isPreparingPlaylist,
                    action: {
                        if item.type == "Series" {
                            if let nextUp = nextUpItem {
                                playEpisode(nextUp, playbackQualityID: immediatePlaybackQualityID)
                            } else if let firstEp = childItems.first(where: { $0.type == "Episode" }) {
                                playEpisode(firstEp, playbackQualityID: immediatePlaybackQualityID)
                            } else if !childItems.isEmpty {
                                playEpisode(childItems[0], playbackQualityID: immediatePlaybackQualityID)
                            }
                        } else {
                            playItem(playbackQualityID: immediatePlaybackQualityID)
                        }
                    }
                )
                .mediaDetailPlaybackButtonFrame()
                .disabled(isPreparingPlaylist)
            }
            
            MediaDetailActionGrid(alignment: horizontalSizeClass == .regular ? .leading : .center) {
                if canShowPrePlaybackOptions {
                    Button(action: {
                        Task { await presentPrePlaybackOptions() }
                    }) {
                        Group {
                            if isLoadingPrePlaybackOptions {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            } else {
                                Image(systemName: "captions.bubble")
                            }
                        }
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ScaleIconButtonStyle())
                    .disabled(isLoadingPrePlaybackOptions)
                }
                
                Button(action: { replayFromStart() }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleIconButtonStyle())
                
                Button(action: { Task { await togglePlayed() } }) {
                    Image(systemName: effectiveIsPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundColor(effectiveIsPlayed ? .green : .white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleIconButtonStyle())
                .disabled(isUpdatingPlayedState)

                if downloadTargetItem != nil {
                    Button(action: {
                        requestCurrentItemDownload()
                    }) {
                        Image(systemName: downloadButtonIcon)
                            .font(.system(size: 20))
                            .foregroundColor(downloadActionColor)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ScaleIconButtonStyle())
                }
                
                Button(action: { Task { await toggleFavorite() } }) {
                    Image(systemName: isFavorite ? "heart.fill" : "heart")
                        .font(.system(size: 20))
                        .foregroundColor(isFavorite ? .red : .white)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleIconButtonStyle())

                if localFavoritePlayableFile != nil {
                    Button(action: { toggleLocalFavorite() }) {
                        Image(systemName: isInLocalFavorites ? "star.fill" : "star")
                            .font(.system(size: 20))
                            .foregroundColor(isInLocalFavorites ? .yellow : .white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ScaleIconButtonStyle())
                }

                if allowMediaServerDeletion && (item.type == "Movie" || item.type == "Episode" || item.type == "Series" || item.type == "Season") {
                    if #available(iOS 15.0, *) {
                        Button(role: .destructive, action: {
                            itemToDelete = item
                            showingDeleteAlert = true
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 20))
                                .foregroundColor(.red)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(ScaleIconButtonStyle())
                        .disabled(isDeleting)
                    } else {
                        Button(action: {
                            itemToDelete = item
                            showingDeleteAlert = true
                        }) {
                            Image(systemName: "trash")
                                .font(.system(size: 20))
                                .foregroundColor(.red)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(ScaleIconButtonStyle())
                        .disabled(isDeleting)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: horizontalSizeClass == .regular ? .leading : .center)
            .foregroundColor(.white)
        }
    }

    private func refreshOfflineAvailability() {
        offlineState = downloadCenter.aggregateState(serverId: server.id, remoteItemIds: currentOfflineTargetIds)
    }

    private var downloadConfirmMessage: String {
        if !pendingSeasonDownloadItems.isEmpty {
            let title = pendingSeasonDownloadTitle ?? currentSeasonTitle
            return String(
                format: NSLocalizedString("Add %d items from \"%@\" to the download queue now?", comment: ""),
                pendingSeasonDownloadItems.count,
                title
            )
        }
        guard let target = pendingDownloadItem else {
            return NSLocalizedString("Do you want to add this media item to the download queue?", comment: "")
        }
        return String(
            format: NSLocalizedString("Add \"%@\" to the download queue now?", comment: ""),
            target.displayTitle
        )
    }

    private func requestCurrentItemDownload() {
        guard let target = downloadTargetItem else { return }
        if !canQueueCurrentItemDownload {
            downloadToastMessage = NSLocalizedString("Already in Download Queue", comment: "")
            return
        }
        pendingSeasonDownloadItems = []
        pendingSeasonDownloadTitle = nil
        pendingDownloadItem = target
        isShowingDownloadConfirmSheet = true
    }

    private func requestEpisodeDownload(_ episode: JellyfinItem) {
        guard canQueueEpisodeDownload(episode) else {
            downloadToastMessage = NSLocalizedString("Already in Download Queue", comment: "")
            return
        }
        pendingSeasonDownloadItems = []
        pendingSeasonDownloadTitle = nil
        pendingDownloadItem = episode
        isShowingDownloadConfirmSheet = true
    }

    private func toggleChildPlayed(_ child: JellyfinItem) async {
        guard let token = server.accessToken, let userId = server.userId else { return }
        let currentPlayed = effectiveUserData(for: child)?.played ?? false
        let nextPlayed = !currentPlayed
        do {
            try await JellyfinService.shared.togglePlayed(
                server: server,
                itemId: child.id,
                userId: userId,
                token: token,
                isPlayed: nextPlayed
            )
            await MainActor.run {
                if child.id == item.id {
                    isPlayed = nextPlayed
                }
                downloadToastMessage = NSLocalizedString(nextPlayed ? "Marked as Played" : "Marked as Unplayed", comment: "")
                PlaybackRefreshCenter.updateRemoteItem(
                    serverId: server.id,
                    itemId: child.id,
                    seriesId: child.seriesId ?? item.id,
                    seasonId: child.seasonId ?? selectedSeasonId,
                    snapshot: RemotePlaybackStateSnapshot.manualPlayedState(
                        played: nextPlayed,
                        runtimeTicks: child.runTimeTicks
                    )
                )
            }
            if let seasonId = selectedSeasonId {
                await loadEpisodes(for: seasonId)
            }
        } catch {
            print("Failed to toggle child played state: \(error.localizedDescription)")
        }
    }

    private func deleteItem(_ targetItem: JellyfinItem) async {
        isDeleting = true
        do {
            try await JellyfinService.shared.deleteItem(server: server, itemId: targetItem.id, token: server.accessToken ?? "")
            
            if let favorite = FavoriteService.shared.favorites.first(where: { $0.file.jellyfinItemId == targetItem.id }) {
                FavoriteService.shared.remove(favorite)
            }
            if let historyFile = HistoryService.shared.remoteHistory.first(where: { $0.jellyfinItemId == targetItem.id }) {
                HistoryService.shared.removeFromHistory(historyFile)
            }
            
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .remoteItemDidDelete,
                    object: RemoteItemDeletePayload(serverId: server.id, itemId: targetItem.id)
                )
                
                if targetItem.id == item.id {
                    presentationMode.wrappedValue.dismiss()
                } else if targetItem.type == "Season" {
                    seasons.removeAll(where: { $0.id == targetItem.id })
                    if selectedSeasonId == targetItem.id {
                        if let nextSeason = seasons.first {
                            selectedSeasonId = nextSeason.id
                            Task { await loadEpisodes(for: nextSeason.id) }
                        } else {
                            selectedSeasonId = nil
                            childItems = []
                        }
                    }
                } else {
                    childItems.removeAll(where: { $0.id == targetItem.id })
                    if nextUpItem?.id == targetItem.id {
                        nextUpItem = nil
                    }
                }
            }
        } catch {
            if isCancellationError(error) { return }
            print("Failed to delete item from Jellyfin server: \(error.localizedDescription)")
            await MainActor.run {
                self.downloadToastMessage = NSLocalizedString("Failed to delete from server", comment: "")
            }
        }
        isDeleting = false
    }

    @ViewBuilder
    private func emptySeasonCard(onDelete: (() -> Void)?) -> some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 56, height: 56)
                Image(systemName: "film.stack")
                    .font(.system(size: 24))
                    .foregroundColor(.white.opacity(0.45))
            }
            
            VStack(spacing: 6) {
                Text(NSLocalizedString("This season is empty", comment: ""))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                
                Text(NSLocalizedString("No episodes found in this season", comment: ""))
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            
            if allowMediaServerDeletion, let onDelete = onDelete {
                Button(action: onDelete) {
                    HStack(spacing: 8) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                        Text(NSLocalizedString("Delete Empty Season", comment: ""))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundColor(Color.red.opacity(0.9))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .stroke(Color.red.opacity(0.28), lineWidth: 1)
                            )
                    )
                }
                .buttonStyle(PlainButtonStyle())
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .padding(.horizontal, 20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
        .padding(.horizontal)
        .padding(.vertical, 12)
    }

    private func requestSelectedSeasonDownload() {
        guard canQueueSelectedSeasonDownload else {
            downloadToastMessage = NSLocalizedString("Season Already Queued", comment: "")
            return
        }
        pendingDownloadItem = nil
        pendingSeasonDownloadItems = seasonDownloadCandidates
        pendingSeasonDownloadTitle = currentSeasonTitle
        isShowingDownloadConfirmSheet = true
    }

    private func confirmPendingDownloadRequest() {
        if !pendingSeasonDownloadItems.isEmpty {
            confirmSelectedSeasonDownload()
        } else {
            confirmCurrentItemDownload()
        }
    }

    private func confirmCurrentItemDownload() {
        guard let target = pendingDownloadItem else { return }
        pendingDownloadItem = nil
        let enqueued = downloadCenter.enqueueMediaDownload(
            server: server,
            remoteItemId: target.id,
            fileName: downloadFileName(for: target),
            totalBytes: target.mediaSources?.first?.size,
            displayTitle: target.displayTitle,
            groupTitle: nil,
            collectionId: target.id,
            seriesId: target.seriesId,
            seasonId: target.seasonId
        )
        if enqueued {
            downloadToastMessage = NSLocalizedString("Added to Download Queue", comment: "")
        } else {
            downloadToastMessage = NSLocalizedString("Already in Download Queue", comment: "")
        }
    }

    private func confirmSelectedSeasonDownload() {
        let episodesToQueue = pendingSeasonDownloadItems
        let seasonTitle = pendingSeasonDownloadTitle ?? currentSeasonTitle
        pendingSeasonDownloadItems = []
        pendingSeasonDownloadTitle = nil

        guard !episodesToQueue.isEmpty else {
            downloadToastMessage = NSLocalizedString("Season Already Queued", comment: "")
            return
        }

        let job = DownloadJobDescriptor(
            kind: .seasonPack,
            sourceType: DownloadSourceType(serverType: server.type),
            title: seasonTitle,
            groupTitle: seasonTitle,
            collectionId: selectedSeasonId ?? item.id,
            seriesId: item.type == "Series" ? item.id : item.seriesId,
            seasonId: selectedSeasonId ?? (item.type == "Season" ? item.id : item.seasonId)
        )

        let entries = episodesToQueue.enumerated().map { index, episode in
            DownloadMediaBatchItem(
                remoteItemId: episode.id,
                remotePath: "/Videos/\(episode.id)/stream?Static=true&download=1",
                fileName: downloadFileName(for: episode),
                displayTitle: episode.displayTitle,
                totalBytes: episode.mediaSources?.first?.size,
                collectionId: selectedSeasonId ?? item.id,
                seriesId: episode.seriesId ?? item.seriesId ?? item.id,
                seasonId: episode.seasonId ?? selectedSeasonId ?? item.seasonId,
                groupIndex: index
            )
        }

        let enqueuedCount = downloadCenter.enqueueMediaBatch(server: server, items: entries, job: job)
        if enqueuedCount > 0 {
            downloadToastMessage = String(
                format: NSLocalizedString("Added %d items to Download Queue", comment: ""),
                enqueuedCount
            )
        } else {
            downloadToastMessage = NSLocalizedString("Season Already Queued", comment: "")
        }
    }

    private func canQueueEpisodeDownload(_ episode: JellyfinItem) -> Bool {
        switch downloadCenter.taskStatus(serverId: server.id, remoteItemId: episode.id) {
        case .queued, .downloading, .paused, .completed:
            return false
        default:
            return true
        }
    }

    private func episodeDownloadIcon(for episode: JellyfinItem) -> String {
        switch downloadCenter.taskStatus(serverId: server.id, remoteItemId: episode.id) {
        case .completed:
            return "arrow.down.circle.fill"
        case .queued, .downloading, .paused:
            return "arrow.down.circle.fill"
        default:
            return "arrow.down.circle"
        }
    }

    private func episodeDownloadColor(for episode: JellyfinItem) -> Color {
        switch downloadCenter.taskStatus(serverId: server.id, remoteItemId: episode.id) {
        case .completed:
            return .green
        case .queued, .downloading, .paused:
            return Color(UIColor.systemBlue)
        default:
            return .white.opacity(0.9)
        }
    }

    private func downloadFileName(for item: JellyfinItem) -> String {
        var displayName = item.name
        if item.type == "Episode",
           let series = item.seriesName,
           let season = item.parentIndexNumber,
           let episode = item.indexNumber {
            displayName = "\(series) - S\(String(format: "%02d", season))E\(String(format: "%02d", episode)) - \(item.name)"
        }

        displayName = displayName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")

        if let rawContainer = item.mediaSources?.first?.container?.split(separator: ",").first {
            let container = String(rawContainer).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !container.isEmpty, !displayName.lowercased().hasSuffix(".\(container)") {
                displayName += ".\(container)"
            }
        }

        return displayName
    }

    private var childrenTitle: String {
        switch item.type {
        case "Series": return NSLocalizedString("Seasons", comment: "")
        case "Season": return NSLocalizedString("Episodes", comment: "")
        case "Playlist": return NSLocalizedString("Items", comment: "")
        default: return NSLocalizedString("Items", comment: "")
        }
    }

    private var episodeSectionTitle: String {
        switch item.type {
        case "Series":
            return NSLocalizedString("Season Episodes", comment: "")
        case "Season":
            return NSLocalizedString("Episodes", comment: "")
        default:
            return childrenTitle
        }
    }

    private var childrenSectionIcon: String {
        switch item.type {
        case "Series":
            return "square.stack.fill"
        case "Season":
            return "film.fill"
        default:
            return "list.bullet"
        }
    }

    private var episodeSectionIcon: String {
        item.type == "Series" || item.type == "Season" ? "film.fill" : "list.bullet"
    }

    private func episodeAnchorID(for episodeId: String) -> String {
        "episode-\(episodeId)"
    }

    private func scrollToPendingEpisode(using proxy: ScrollViewProxy) {
        guard let targetEpisodeId = pendingEpisodeId else { return }
        guard childItems.contains(where: { $0.id == targetEpisodeId }) else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(episodeAnchorID(for: targetEpisodeId), anchor: .center)
            }
            pendingEpisodeId = nil
        }
    }

    private func loadChildren() async {
        guard let token = server.accessToken, let userId = server.userId else { return }
        
        await MainActor.run { isLoadingChildren = true }
        
        do {
            let items: [JellyfinItem]
            switch item.type {
            case "Series":
                let seasonsList = try await JellyfinService.shared.getSeasons(server: server, userId: userId, token: token, seriesId: item.id)
                let preferredSeasonId = seasonsList.first(where: { $0.id == preferredSeriesSeasonId })?.id ?? seasonsList.first?.id
                await MainActor.run {
                    self.seasons = seasonsList
                    self.selectedSeasonId = preferredSeasonId
                    self.pendingEpisodeId = initialEpisodeId
                }
                if let seasonId = preferredSeasonId {
                    items = try await JellyfinService.shared.getEpisodes(server: server, userId: userId, token: token, seriesId: item.id, seasonId: seasonId)
                } else {
                    items = []
                }
            case "Season":
                items = try await JellyfinService.shared.getEpisodes(server: server, userId: userId, token: token, seriesId: item.seriesId ?? "", seasonId: item.id)
            case "Playlist":
                items = try await JellyfinService.shared.getPlaylistItems(server: server, userId: userId, token: token, playlistId: item.id)
            case "BoxSet", "Folder", "MusicAlbum":
                items = try await JellyfinService.shared.getDirectChildren(server: server, userId: userId, token: token, parentId: item.id, recursive: false)
            default:
                items = []
            }
            
            await MainActor.run {
                childItems = items
                isLoadingChildren = false
            }
        } catch {
            print("[Jellyfin] Error loading children for \(item.type): \(error)")
            await MainActor.run { isLoadingChildren = false }
        }
    }
    
    private func loadEpisodes(for seasonId: String) async {
        guard let token = server.accessToken, let userId = server.userId else { return }
        await MainActor.run { isLoadingChildren = true }
        do {
            let items = try await JellyfinService.shared.getEpisodes(server: server, userId: userId, token: token, seriesId: item.id, seasonId: seasonId)
            await MainActor.run {
                self.childItems = items
                self.isLoadingChildren = false
            }
        } catch {
            print("[Jellyfin] Error loading episodes: \(error)")
            await MainActor.run { isLoadingChildren = false }
        }
    }

    private func applyPreferredSeriesSeasonIfNeeded() {
        guard item.type == "Series",
              initialSeasonId == nil,
              !hasUserSelectedSeason,
              let preferredSeasonId = nextUpItem?.seasonId,
              seasons.contains(where: { $0.id == preferredSeasonId }),
              selectedSeasonId != preferredSeasonId else {
            return
        }

        selectedSeasonId = preferredSeasonId
        Task { await loadEpisodes(for: preferredSeasonId) }
    }

    private func makePlayableFile(
        from playableItem: JellyfinItem,
        token: String,
        startFromBeginning: Bool = false,
        playbackQuality: RemotePlaybackQualityOption = .auto
    ) -> VideoFile? {
        let effectiveData = effectiveUserData(for: playableItem)
        let resumeDecision = jellyfinResumeDecision(
            from: effectiveData,
            runtimeTicks: playableItem.runTimeTicks,
            playedOverride: playableItem.id == item.id ? isPlayed : nil
        )
        guard let streamURL = jellyfinPreferredStreamURL(
            for: playableItem,
            server: server,
            token: token,
            playbackQuality: playbackQuality
        ) else {
            return nil
        }

        var file = VideoFile(
            name: playableItem.displayTitle,
            url: streamURL,
            type: playableItem.type == "Audio" ? .audio : .video,
            size: 0,
            date: Date(),
            isRemote: true,
            lastPlayedPosition: startFromBeginning ? 0 : resumeDecision.startPosition,
            jellyfinItemId: playableItem.id,
            jellyfinServerId: server.id.uuidString,
            serverType: server.type,
            seriesId: playableItem.seriesId,
            seasonId: playableItem.seasonId
        )
        file.shouldResetRemotePlayedStateOnPlaybackStart =
            startFromBeginning || resumeDecision.shouldResetPlayedStateOnStart

        applyJellyfinPreferredSourceMetadata(from: playableItem, to: &file)
        file.preferredPlaybackQualityID = playbackQuality.id

        return file
    }

    private func playlistFiles(
        from items: [JellyfinItem],
        token: String,
        playbackQuality: RemotePlaybackQualityOption = .auto
    ) -> [VideoFile] {
        items.compactMap { child -> VideoFile? in
            guard child.isPlayable else { return nil }
            return makePlayableFile(from: child, token: token, playbackQuality: playbackQuality)
        }
    }

    private func makePreparedPlayableFile(
        from playableItem: JellyfinItem,
        startFromBeginning: Bool = false,
        playbackQuality: RemotePlaybackQualityOption = .auto,
        audioQuery: String? = nil,
        subtitleQuery: String? = nil,
        preferredAudioOrdinal: Int? = nil,
        preferredSubtitleOrdinal: Int? = nil,
        externalSubtitleCandidates: [ExternalSubtitleCandidate] = [],
        disableSubtitles: Bool = false
    ) async -> VideoFile? {
        guard let token = server.accessToken else { return nil }
        guard let preparedPlayback = await jellyfinPreparedPlayback(
            for: playableItem,
            server: server,
            token: token,
            userId: server.userId,
            playbackQuality: playbackQuality
        ) else {
            return nil
        }
        let effectiveData = effectiveUserData(for: playableItem)
        let resumeDecision = jellyfinResumeDecision(
            from: effectiveData,
            runtimeTicks: playableItem.runTimeTicks,
            playedOverride: playableItem.id == item.id ? isPlayed : nil
        )

        var file = VideoFile(
            name: playableItem.displayTitle,
            url: preparedPlayback.streamURL,
            type: playableItem.type == "Audio" ? .audio : .video,
            size: 0,
            date: Date(),
            isRemote: true,
            lastPlayedPosition: startFromBeginning ? 0 : resumeDecision.startPosition,
            jellyfinItemId: playableItem.id,
            jellyfinServerId: server.id.uuidString,
            serverType: server.type,
            seriesId: playableItem.seriesId,
            seasonId: playableItem.seasonId
        )
        file.shouldResetRemotePlayedStateOnPlaybackStart =
            startFromBeginning || resumeDecision.shouldResetPlayedStateOnStart

        applyPrePlaybackSelection(
            to: &file,
            audioQuery: audioQuery,
            subtitleQuery: subtitleQuery,
            preferredAudioOrdinal: preferredAudioOrdinal,
            preferredSubtitleOrdinal: preferredSubtitleOrdinal,
            disableSubtitles: disableSubtitles
        )
        applyJellyfinPreparedPlayback(preparedPlayback, to: &file)
        file.preferredPlaybackQualityID = playbackQuality.id
        if !externalSubtitleCandidates.isEmpty {
            file.externalSubtitleCandidates = externalSubtitleCandidates
        }

        return file
    }
    
    private func loadMetadata() async {
        guard let token = server.accessToken, let userId = server.userId else { return }
        
        // Load People
        do {
            let peopleList = try await JellyfinService.shared.getPeople(server: server, itemId: item.id, token: token)
            await MainActor.run {
                self.people = peopleList
            }
        } catch {
            print("[Jellyfin] Error loading people: \(error)")
        }
        
        // Load Similar Items
        do {
            let similarList = try await JellyfinService.shared.getSimilarItems(server: server, itemId: item.id, userId: userId, token: token)
            await MainActor.run {
                self.similarItems = similarList
            }
        } catch {
            print("[Jellyfin] Error loading similar items: \(error)")
        }
    }
    
    private func loadNextUp() async {
        guard let token = server.accessToken, let userId = server.userId else { return }
        guard item.type == "Series" else { return }
        
        do {
            let nextUpItems = try await JellyfinService.shared.getNextUp(server: server, userId: userId, token: token, seriesId: item.id)
            await MainActor.run {
                self.nextUpItem = nextUpItems.first
            }
        } catch {
            print("[Jellyfin] Error loading next up: \(error)")
        }
    }
    
    private func playItem(
        playbackQualityID: String? = nil,
        audioQuery: String? = nil,
        subtitleQuery: String? = nil,
        preferredAudioOrdinal: Int? = nil,
        preferredSubtitleOrdinal: Int? = nil,
        externalSubtitleCandidates: [ExternalSubtitleCandidate] = [],
        disableSubtitles: Bool = false
    ) {
        Task {
            let playbackQuality = AppSettings.shared.resolvedRemotePlaybackQualityOption(for: playbackQualityID)
            guard let videoFile = await makePreparedPlayableFile(
                from: item,
                playbackQuality: playbackQuality,
                audioQuery: audioQuery,
                subtitleQuery: subtitleQuery,
                preferredAudioOrdinal: preferredAudioOrdinal,
                preferredSubtitleOrdinal: preferredSubtitleOrdinal,
                externalSubtitleCandidates: externalSubtitleCandidates,
                disableSubtitles: disableSubtitles
            ) else {
                return
            }

            if item.type == "Episode" {
                let needsPlaylistPreparation = await MainActor.run { self.playlistItems == nil }
                if needsPlaylistPreparation {
                    print("[Jellyfin] playItem: Preparing playlist for episode...")
                    await preparePlaylist(playbackQualityID: playbackQuality.id)
                }
                await MainActor.run {
                    print("[Jellyfin] playItem: Playlist prepared. Launching player.")
                    self.playingFile = videoFile
                }
            } else if item.type == "Series" || item.type == "Season" {
                print("[Jellyfin] playItem: Container type '\(item.type)', preparing playlist...")
                await preparePlaylist(playbackQualityID: playbackQuality.id)
                await MainActor.run {
                    if var first = self.playlistItems?.first {
                        self.applyPrePlaybackSelection(
                            to: &first,
                            audioQuery: audioQuery,
                            subtitleQuery: subtitleQuery,
                            preferredAudioOrdinal: preferredAudioOrdinal,
                            preferredSubtitleOrdinal: preferredSubtitleOrdinal,
                            disableSubtitles: disableSubtitles
                        )
                        first.preferredPlaybackQualityID = playbackQuality.id
                        first.externalSubtitleCandidates = externalSubtitleCandidates.isEmpty
                            ? videoFile.externalSubtitleCandidates
                            : externalSubtitleCandidates
                        if var playlistItems = self.playlistItems, !playlistItems.isEmpty {
                            playlistItems[0] = first
                            self.playlistItems = playlistItems
                        }
                        print("[Jellyfin] playItem: Playing first item of playlist: \(first.name)")
                        self.playingFile = first
                    } else {
                        print("[Jellyfin] playItem: No episodes found in playlist to play.")
                        self.errorMessage = "No playable episodes found."
                        self.showErrorAlert = true
                    }
                }
            } else {
                await MainActor.run {
                    print("[Jellyfin] playItem: Single file playback. Wrapping in playlist.")
                    self.playlistItems = [videoFile]
                    print("[Jellyfin] playItem: Setting playingFile")
                    self.playingFile = videoFile
                }
            }
        }
    }

    private func preparePlaylist(playbackQualityID: String? = nil) async {
        guard let token = server.accessToken, let userId = server.userId else { return }
        guard let seriesId = item.seriesId, let seasonId = item.seasonId else { return }
        let playbackQuality = AppSettings.shared.resolvedRemotePlaybackQualityOption(for: playbackQualityID)
        
        await MainActor.run { isPreparingPlaylist = true }
        
        do {
            let episodes = try await JellyfinService.shared.getEpisodes(
                server: server, 
                userId: userId, 
                token: token, 
                seriesId: seriesId, 
                seasonId: seasonId
            )
            
            var files: [VideoFile] = []
            for ep in episodes {
                guard let file = await makePreparedPlayableFile(from: ep, playbackQuality: playbackQuality) else {
                    continue
                }
                files.append(file)
            }
            
            await MainActor.run {
                playlistItems = files
                isPreparingPlaylist = false
            }
        } catch {
            print("[Jellyfin] Error preparing playlist: \(error)")
            await MainActor.run { isPreparingPlaylist = false }
        }
    }
    
    private var playButtonTitle: String {
        if item.type == "Series" {
            if let nextUp = nextUpItem {
                let season = nextUp.parentIndexNumber ?? 1
                let episode = nextUp.indexNumber ?? 1
                return String(
                    format: NSLocalizedString("Continue Play S%d:E%d", comment: ""),
                    season,
                    episode
                )
            }
            return NSLocalizedString("Start Play", comment: "")
        }
        if jellyfinResumeDecision(
            from: effectiveItemUserData,
            runtimeTicks: item.runTimeTicks,
            playedOverride: effectiveIsPlayed
        ).shouldContinuePlayback {
            return NSLocalizedString("Continue", comment: "")
        }
        return NSLocalizedString("Play", comment: "")
    }

    private var playButtonProgressInfo: PlaybackCTAProgress? {
        let targetItem: JellyfinItem
        let decision: RemotePlaybackResumeDecision

        if item.type == "Series", let nextUp = nextUpItem {
            targetItem = nextUp
            decision = jellyfinResumeDecision(
                from: effectiveUserData(for: nextUp),
                runtimeTicks: nextUp.runTimeTicks
            )
        } else {
            targetItem = item
            decision = jellyfinResumeDecision(
                from: effectiveItemUserData,
                runtimeTicks: item.runTimeTicks,
                playedOverride: effectiveIsPlayed
            )
        }

        guard decision.shouldContinuePlayback else { return nil }
        let playbackTicks = effectiveUserData(for: targetItem)?.playbackPositionTicks
        guard let playbackTicks, playbackTicks > 0 else { return nil }
        let playedSeconds = Int(playbackTicks / 10_000_000)
        guard playedSeconds > 0 else { return nil }

        let runtimeTicks = targetItem.runTimeTicks
        guard let runtimeTicks, runtimeTicks > 0 else { return nil }
        let totalSeconds = Int(runtimeTicks / 10_000_000)
        guard totalSeconds > 0 else { return nil }

        let calculatedFraction = min(max(Double(playedSeconds) / Double(totalSeconds), 0), 1)
        let rawPercent = effectiveUserData(for: targetItem)?.playedPercentage.map { Int($0.rounded()) }
        let safePercent = min(max(rawPercent ?? Int((calculatedFraction * 100).rounded()), 0), 100)

        return PlaybackCTAProgress(
            playedText: formatClock(playedSeconds),
            totalText: formatClock(totalSeconds),
            percentText: "\(safePercent)%",
            fraction: Double(safePercent) / 100.0
        )
    }

    private func formatClock(_ totalSeconds: Int) -> String {
        let seconds = max(0, totalSeconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remaining = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remaining)
        }
        return String(format: "%02d:%02d", minutes, remaining)
    }
    
    /// Replay from the very beginning
    private func replayFromStart() {
        Task {
            let playbackQuality = AppSettings.shared.resolvedRemotePlaybackQualityOption(for: immediatePlaybackQualityID)
            if item.type == "Series" {
                let firstEpisode = await firstEpisodeForSeriesReplay()
                guard let firstEpisode,
                      let file = await makePreparedPlayableFile(from: firstEpisode, startFromBeginning: true, playbackQuality: playbackQuality) else {
                    return
                }
                await MainActor.run {
                    self.playlistItems = [file]
                    self.playingFile = file
                }
            } else {
                guard let file = await makePreparedPlayableFile(from: item, startFromBeginning: true, playbackQuality: playbackQuality) else { return }
                await MainActor.run {
                    self.playlistItems = [file]
                    self.playingFile = file
                }
            }
        }
    }

    private var immediatePlaybackQualityID: String {
        AppSettings.shared.resolvedRemotePlaybackQualityID(for: selectedPrePlaybackQualityID)
    }

    private func firstEpisodeForSeriesReplay() async -> JellyfinItem? {
        let currentEpisodes = await MainActor.run { self.childItems }
        let currentSelectedSeasonId = await MainActor.run { self.selectedSeasonId }
        let firstSeasonId = await MainActor.run { self.seasons.first?.id }

        if firstSeasonId == nil || firstSeasonId == currentSelectedSeasonId {
            return currentEpisodes.first(where: { $0.type == "Episode" }) ?? currentEpisodes.first
        }

        guard let token = server.accessToken,
              let userId = server.userId,
              let firstSeasonId else {
            return currentEpisodes.first(where: { $0.type == "Episode" }) ?? currentEpisodes.first
        }

        do {
            let firstSeasonEpisodes = try await JellyfinService.shared.getEpisodes(
                server: server,
                userId: userId,
                token: token,
                seriesId: item.id,
                seasonId: firstSeasonId
            )
            return firstSeasonEpisodes.first(where: { $0.type == "Episode" }) ?? firstSeasonEpisodes.first
        } catch {
            print("[Jellyfin] Error loading first season for replay: \(error)")
            return currentEpisodes.first(where: { $0.type == "Episode" }) ?? currentEpisodes.first
        }
    }

    private func playChildItem(
        _ child: JellyfinItem,
        playbackQualityID: String? = nil,
        audioQuery: String? = nil,
        subtitleQuery: String? = nil,
        preferredAudioOrdinal: Int? = nil,
        preferredSubtitleOrdinal: Int? = nil,
        externalSubtitleCandidates: [ExternalSubtitleCandidate] = [],
        disableSubtitles: Bool = false
    ) {
        guard child.isPlayable else { return }
        if child.type == "Episode" {
            playEpisode(
                child,
                playbackQualityID: playbackQualityID,
                audioQuery: audioQuery,
                subtitleQuery: subtitleQuery,
                preferredAudioOrdinal: preferredAudioOrdinal,
                preferredSubtitleOrdinal: preferredSubtitleOrdinal,
                externalSubtitleCandidates: externalSubtitleCandidates,
                disableSubtitles: disableSubtitles
            )
            return
        }

        Task {
            let playbackQuality = AppSettings.shared.resolvedRemotePlaybackQualityOption(for: playbackQualityID)
            guard let selectedFile = await makePreparedPlayableFile(
                from: child,
                playbackQuality: playbackQuality,
                audioQuery: audioQuery,
                subtitleQuery: subtitleQuery,
                preferredAudioOrdinal: preferredAudioOrdinal,
                preferredSubtitleOrdinal: preferredSubtitleOrdinal,
                externalSubtitleCandidates: externalSubtitleCandidates,
                disableSubtitles: disableSubtitles
            ),
            let token = server.accessToken else {
                return
            }

            let childItemsSnapshot = await MainActor.run { self.childItems }
            let files = playlistFiles(from: childItemsSnapshot, token: token, playbackQuality: playbackQuality)
            await MainActor.run {
                self.playlistItems = files.isEmpty ? [selectedFile] : files
                self.playingFile = selectedFile
            }
        }
    }
    
    private func playEpisode(
        _ episode: JellyfinItem,
        playbackQualityID: String? = nil,
        audioQuery: String? = nil,
        subtitleQuery: String? = nil,
        preferredAudioOrdinal: Int? = nil,
        preferredSubtitleOrdinal: Int? = nil,
        externalSubtitleCandidates: [ExternalSubtitleCandidate] = [],
        disableSubtitles: Bool = false
    ) {
        print("[Jellyfin] playEpisode called for: \(episode.name)")
        Task {
            let playbackQuality = AppSettings.shared.resolvedRemotePlaybackQualityOption(for: playbackQualityID)
            guard let selectedFile = await makePreparedPlayableFile(
                from: episode,
                playbackQuality: playbackQuality,
                audioQuery: audioQuery,
                subtitleQuery: subtitleQuery,
                preferredAudioOrdinal: preferredAudioOrdinal,
                preferredSubtitleOrdinal: preferredSubtitleOrdinal,
                externalSubtitleCandidates: externalSubtitleCandidates,
                disableSubtitles: disableSubtitles
            ),
            let token = server.accessToken else {
                print("[Jellyfin] playEpisode: Missing token or prepared playback")
                return
            }

            let childItemsSnapshot = await MainActor.run { self.childItems }
            let playlist = childItemsSnapshot.isEmpty
                ? [selectedFile]
                : {
                    let files = childItemsSnapshot.compactMap { child in
                        makePlayableFile(from: child, token: token, playbackQuality: playbackQuality)
                    }
                    return files.isEmpty ? [selectedFile] : files
                }()

            await MainActor.run {
                self.playlistItems = playlist
                print("[Jellyfin] playEpisode: Launching PlayerView with \(playlist.count) items")
                self.playingFile = selectedFile
            }
        }
    }
    

    
    private func toggleFavorite() async {
        guard let token = server.accessToken, let userId = server.userId else { return }
        
        let newStatus = !isFavorite
        do {
            try await JellyfinService.shared.toggleFavorite(
                server: server,
                itemId: item.id,
                userId: userId,
                token: token,
                isFavorite: newStatus
            )
            await MainActor.run {
                isFavorite = newStatus
                downloadToastMessage = NSLocalizedString(newStatus ? "Added to Favorites" : "Removed from Favorites", comment: "")
                FavoriteRefreshCenter.updateRemoteItem(
                    serverId: server.id,
                    itemId: item.id,
                    seriesId: item.seriesId,
                    isFavorite: newStatus
                )
            }
        } catch {
            print("[Jellyfin] Error toggling favorite: \(error)")
        }
    }

    private func toggleLocalFavorite() {
        guard let file = localFavoritePlayableFile,
              let identityPath = localFavoriteIdentityPath else {
            return
        }
        favoriteService.toggleFavorite(file: file, folderPath: identityPath)
        downloadToastMessage = NSLocalizedString(favoriteService.isFavorite(file: file) ? "Added to Favorites" : "Removed from Favorites", comment: "")
    }

    private func togglePlayed() async {
        guard !isUpdatingPlayedState else { return }
        guard let token = server.accessToken, let userId = server.userId else { return }

        let nextPlayed = !effectiveIsPlayed
        await MainActor.run {
            isUpdatingPlayedState = true
        }

        do {
            try await JellyfinService.shared.togglePlayed(
                server: server,
                itemId: item.id,
                userId: userId,
                token: token,
                isPlayed: nextPlayed
            )
            await MainActor.run {
                isPlayed = nextPlayed
                isUpdatingPlayedState = false
                downloadToastMessage = NSLocalizedString(nextPlayed ? "Marked as Played" : "Marked as Unplayed", comment: "")
                PlaybackRefreshCenter.updateRemoteItem(
                    serverId: server.id,
                    itemId: item.id,
                    seriesId: item.seriesId,
                    seasonId: item.seasonId,
                    snapshot: RemotePlaybackStateSnapshot.manualPlayedState(
                        played: nextPlayed,
                        runtimeTicks: item.runTimeTicks
                    )
                )
            }
        } catch {
            if isCancellationError(error) {
                await MainActor.run {
                    isUpdatingPlayedState = false
                }
                return
            }
            await MainActor.run {
                isUpdatingPlayedState = false
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    private func applyPrePlaybackSelection(
        to file: inout VideoFile,
        audioQuery: String?,
        subtitleQuery: String?,
        preferredAudioOrdinal: Int?,
        preferredSubtitleOrdinal: Int?,
        disableSubtitles: Bool
    ) {
        file.preferredAudioTrackQuery = audioQuery
        file.preferredSubtitleTrackQuery = subtitleQuery
        file.preferredAudioTrackOrdinal = preferredAudioOrdinal
        file.preferredSubtitleTrackOrdinal = preferredSubtitleOrdinal
        file.disableSubtitlesOnStart = disableSubtitles
    }

    private func resolvePrePlaybackTargetItem() -> JellyfinItem? {
        if item.isPlayable { return item }
        if item.type == "Series" {
            return nextUpItem ?? childItems.first(where: { $0.type == "Episode" }) ?? childItems.first
        }
        if item.type == "Season" {
            return childItems.first(where: { $0.type == "Episode" }) ?? childItems.first
        }
        return childItems.first(where: { $0.isPlayable })
    }

    private func effectiveUserData(for targetItem: JellyfinItem) -> JellyfinUserData? {
        jellyfinEffectiveUserData(
            for: targetItem,
            serverId: server.id,
            remotePlaybackState: remotePlaybackState
        )
    }

    private func refreshPlaybackContextFromServer() async {
        if item.type == "Series" {
            await loadNextUp()
        }

        guard item.isContainer else { return }

        if item.type == "Series",
           let selectedSeasonId,
           let token = server.accessToken,
           let userId = server.userId {
            do {
                let episodes = try await JellyfinService.shared.getEpisodes(
                    server: server,
                    userId: userId,
                    token: token,
                    seriesId: item.id,
                    seasonId: selectedSeasonId
                )
                await MainActor.run {
                    self.childItems = episodes
                }
            } catch {
                print("[Jellyfin] Error refreshing episodes after playback: \(error)")
            }
            return
        }

        await loadChildren()
    }

    private func handleRemotePlaybackRefresh(_ payload: PlaybackStateRefreshPayload) {
        guard payload.serverId == server.id else { return }

        let isRelevant =
            payload.itemId == item.id ||
            payload.seriesId == item.id ||
            payload.seasonId == item.id ||
            payload.seasonId == selectedSeasonId ||
            nextUpItem?.id == payload.itemId ||
            childItems.contains(where: { $0.id == payload.itemId })

        guard isRelevant else { return }

        Task { await refreshPlaybackContextFromServer() }
    }

    private func refreshPrePlaybackOptionAvailability() async {
        guard item.type != "Series" else {
            await MainActor.run { canShowPrePlaybackOptions = false }
            return
        }
        guard let target = resolvePrePlaybackTargetItem(),
              let token = server.accessToken,
              let userId = server.userId else {
            await MainActor.run { canShowPrePlaybackOptions = false }
            return
        }

        do {
            let playbackInfo = try await JellyfinService.shared.getPlaybackInfo(
                server: server,
                itemId: target.id,
                userId: userId,
                token: token
            )
            let streams = preferredPrePlaybackStreams(from: playbackInfo.mediaSources)
            let qualityOptions = AppSettings.shared.visibleRemotePlaybackQualityOptions(
                from: JellyfinService.shared.qualityOptions(from: playbackInfo.mediaSources)
            )
            guard !streams.isEmpty else {
                return
            }
            let audioCount = streams.filter { isAudioStreamType($0.type) }.count
            let subtitleCount = streams.filter { isSubtitleStreamType($0.type) }.count
            await MainActor.run {
                canShowPrePlaybackOptions = !qualityOptions.isEmpty || subtitleCount > 0 || audioCount > 1
            }
        } catch {
            await MainActor.run { canShowPrePlaybackOptions = false }
        }
    }

    private func presentPrePlaybackOptions() async {
        guard !isLoadingPrePlaybackOptions else { return }
        guard let target = resolvePrePlaybackTargetItem() else {
            await MainActor.run {
                errorMessage = NSLocalizedString("No playable item available.", comment: "")
                showErrorAlert = true
            }
            return
        }
        guard let token = server.accessToken, let userId = server.userId else {
            await MainActor.run {
                errorMessage = NSLocalizedString("Missing login information.", comment: "")
                showErrorAlert = true
            }
            return
        }

        await MainActor.run {
            isLoadingPrePlaybackOptions = true
        }

        do {
            let playbackInfo = try await JellyfinService.shared.getPlaybackInfo(
                server: server,
                itemId: target.id,
                userId: userId,
                token: token
            )
            let externalSubtitleCandidates = JellyfinService.shared.externalSubtitleCandidates(
                server: server,
                itemId: target.id,
                mediaSources: playbackInfo.mediaSources,
                token: token
            )
            let qualityOptions = AppSettings.shared.visibleRemotePlaybackQualityOptions(
                from: JellyfinService.shared.qualityOptions(from: playbackInfo.mediaSources)
            )

            let streams = preferredPrePlaybackStreams(from: playbackInfo.mediaSources)
            let audioStreams = streams.enumerated().filter { isAudioStreamType($0.element.type) }
            let subtitleStreams = streams.enumerated().filter { isSubtitleStreamType($0.element.type) }
            guard !qualityOptions.isEmpty || audioStreams.count > 1 || !subtitleStreams.isEmpty else {
                await MainActor.run {
                    isLoadingPrePlaybackOptions = false
                    errorMessage = NSLocalizedString("No selectable playback options for this item.", comment: "")
                    showErrorAlert = true
                }
                return
            }

            let qualityTrackOptions = qualityOptions.map { option in
                PrePlaybackTrackOption(
                    id: option.id,
                    title: option.title,
                    subtitle: option.subtitle,
                    query: option.id
                )
            }

            let audioOptions = audioStreams.map { (index, stream) in
                PrePlaybackTrackOption(
                    id: "audio-\(index)",
                    title: prePlaybackTrackDisplayName(stream: stream, fallbackPrefix: NSLocalizedString("Audio", comment: ""), fallbackIndex: index + 1),
                    query: prePlaybackTrackDisplayName(stream: stream, fallbackPrefix: NSLocalizedString("Audio", comment: ""), fallbackIndex: index + 1)
                )
            }

            var subtitleOptions: [PrePlaybackTrackOption] = [
                PrePlaybackTrackOption(
                    id: PrePlaybackTrackOption.subtitleOffID,
                    title: NSLocalizedString("Off", comment: ""),
                    query: nil
                )
            ]
            subtitleOptions.append(contentsOf: subtitleStreams.map { (index, stream) in
                let title = prePlaybackTrackDisplayName(stream: stream, fallbackPrefix: NSLocalizedString("Subtitle", comment: ""), fallbackIndex: index + 1)
                return PrePlaybackTrackOption(id: "subtitle-\(index)", title: title, query: title)
            })

            let savedPreference = savedTrackQueryPreference(for: target)
            let defaultAudioIndex = audioStreams.first(where: { $0.element.isDefault == true })?.offset
            let defaultSubtitleIndex = subtitleStreams.first(where: { $0.element.isDefault == true })?.offset
            let resolvedAudioID = savedPreference.audioQuery.flatMap { selectedTrackOptionID(matching: $0, in: audioOptions) }
                ?? defaultAudioIndex.map { "audio-\($0)" }
                ?? audioOptions.first?.id
            let resolvedSubtitleID: String
            if savedPreference.subtitlesDisabled == true {
                resolvedSubtitleID = PrePlaybackTrackOption.subtitleOffID
            } else {
                resolvedSubtitleID = savedPreference.subtitleQuery.flatMap { selectedTrackOptionID(matching: $0, in: subtitleOptions) }
                    ?? defaultSubtitleIndex.map { "subtitle-\($0)" }
                    ?? PrePlaybackTrackOption.subtitleOffID
            }

            await MainActor.run {
                prePlaybackTargetItem = target
                prePlaybackQualityOptions = qualityTrackOptions
                prePlaybackAudioOptions = audioOptions
                prePlaybackSubtitleOptions = subtitleOptions
                prePlaybackExternalSubtitleCandidates = externalSubtitleCandidates
                selectedPrePlaybackQualityID = AppSettings.shared.defaultRemotePlaybackQualityOption.id
                selectedPrePlaybackAudioID = resolvedAudioID
                selectedPrePlaybackSubtitleID = resolvedSubtitleID
                isLoadingPrePlaybackOptions = false
                showPrePlaybackOptions = true
            }
        } catch {
            if isCancellationError(error) {
                await MainActor.run {
                    isLoadingPrePlaybackOptions = false
                }
                return
            }
            await MainActor.run {
                isLoadingPrePlaybackOptions = false
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    private func preferredPrePlaybackStreams(from mediaSources: [JellyfinMediaSource]) -> [JellyfinMediaStream] {
        JellyfinService.shared.preferredPlaybackStreams(from: mediaSources)
    }

    private func isAudioStreamType(_ rawType: String) -> Bool {
        let type = rawType.lowercased()
        return type == "audio" || type.contains("audio")
    }

    private func isSubtitleStreamType(_ rawType: String) -> Bool {
        let type = rawType.lowercased()
        return type == "subtitle" || type.contains("subtitle") || type.contains("caption")
    }

    private func prePlaybackTrackDisplayName(stream: JellyfinMediaStream, fallbackPrefix: String, fallbackIndex: Int) -> String {
        if let title = stream.displayTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        var parts: [String] = []
        if let language = stream.language, !language.isEmpty {
            parts.append(language.uppercased())
        }
        if let codec = stream.codec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        if let channels = stream.channels, channels > 0 {
            parts.append("\(channels)ch")
        }
        if parts.isEmpty {
            return "\(fallbackPrefix) \(fallbackIndex)"
        }
        return parts.joined(separator: " · ")
    }

    private func playWithPrePlaybackSelection() {
        guard let target = prePlaybackTargetItem else { return }

        let selectedPlaybackQualityID = AppSettings.shared.resolvedRemotePlaybackQualityID(for: selectedPrePlaybackQualityID)
        let selectedAudio = prePlaybackAudioOptions.first(where: { $0.id == selectedPrePlaybackAudioID })?.query
        let selectedSubtitleID = selectedPrePlaybackSubtitleID ?? PrePlaybackTrackOption.subtitleOffID
        let disableSubtitles = selectedSubtitleID == PrePlaybackTrackOption.subtitleOffID
        let selectedSubtitle = prePlaybackSubtitleOptions.first(where: { $0.id == selectedSubtitleID })?.query
        let selectedAudioOrdinal = trackOrdinal(from: selectedPrePlaybackAudioID, prefix: "audio-")
        let selectedSubtitleOrdinal = disableSubtitles ? nil : trackOrdinal(from: selectedSubtitleID, prefix: "subtitle-")
        persistTrackQueryPreference(
            for: target,
            audioQuery: selectedAudio,
            subtitleQuery: selectedSubtitle,
            subtitlesDisabled: disableSubtitles
        )

        if target.type == "Episode" {
            playEpisode(
                target,
                playbackQualityID: selectedPlaybackQualityID,
                audioQuery: selectedAudio,
                subtitleQuery: selectedSubtitle,
                preferredAudioOrdinal: selectedAudioOrdinal,
                preferredSubtitleOrdinal: selectedSubtitleOrdinal,
                externalSubtitleCandidates: prePlaybackExternalSubtitleCandidates,
                disableSubtitles: disableSubtitles
            )
            return
        }

        if target.id == item.id {
            playItem(
                playbackQualityID: selectedPlaybackQualityID,
                audioQuery: selectedAudio,
                subtitleQuery: selectedSubtitle,
                preferredAudioOrdinal: selectedAudioOrdinal,
                preferredSubtitleOrdinal: selectedSubtitleOrdinal,
                externalSubtitleCandidates: prePlaybackExternalSubtitleCandidates,
                disableSubtitles: disableSubtitles
            )
            return
        }

        if target.isPlayable {
            playEpisode(
                target,
                playbackQualityID: selectedPlaybackQualityID,
                audioQuery: selectedAudio,
                subtitleQuery: selectedSubtitle,
                preferredAudioOrdinal: selectedAudioOrdinal,
                preferredSubtitleOrdinal: selectedSubtitleOrdinal,
                externalSubtitleCandidates: prePlaybackExternalSubtitleCandidates,
                disableSubtitles: disableSubtitles
            )
            return
        }

        errorMessage = NSLocalizedString("No playable item available.", comment: "")
        showErrorAlert = true
    }

    private func trackOrdinal(from rawID: String?, prefix: String) -> Int? {
        guard let rawID = rawID, rawID.hasPrefix(prefix) else { return nil }
        return Int(rawID.dropFirst(prefix.count))
    }

    private func selectedTrackOptionID(matching query: String, in options: [PrePlaybackTrackOption]) -> String? {
        let normalizedQuery = normalizedTrackQuery(query)
        guard !normalizedQuery.isEmpty else { return nil }
        return options.first(where: { option in
            guard let candidate = option.query else { return false }
            let normalizedCandidate = normalizedTrackQuery(candidate)
            return !normalizedCandidate.isEmpty
                && (normalizedCandidate.contains(normalizedQuery) || normalizedQuery.contains(normalizedCandidate))
        })?.id
    }

    private func normalizedTrackQuery(_ value: String) -> String {
        let lowered = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let allowed = CharacterSet.alphanumerics
        return String(lowered.unicodeScalars.filter { allowed.contains($0) })
    }

    private func preferenceScopeKey(for item: JellyfinItem) -> String {
        if let seriesId = item.seriesId, !seriesId.isEmpty {
            return "series.\(seriesId)"
        }
        return "item.\(item.id)"
    }

    private func savedTrackQueryPreference(for item: JellyfinItem) -> (audioQuery: String?, subtitleQuery: String?, subtitlesDisabled: Bool?) {
        AppSettings.shared.trackQueryPreference(
            provider: server.type.rawValue,
            serverId: server.id.uuidString,
            scopeKey: preferenceScopeKey(for: item)
        )
    }

    private func persistTrackQueryPreference(
        for item: JellyfinItem,
        audioQuery: String?,
        subtitleQuery: String?,
        subtitlesDisabled: Bool
    ) {
        AppSettings.shared.saveTrackQueryPreference(
            provider: server.type.rawValue,
            serverId: server.id.uuidString,
            scopeKey: preferenceScopeKey(for: item),
            audioQuery: audioQuery,
            subtitleQuery: subtitlesDisabled ? nil : subtitleQuery,
            subtitlesDisabled: subtitlesDisabled
        )
    }
}

struct JellyfinMediaContextMenuModifier: ViewModifier {
    let item: JellyfinItem
    let server: ServerConfig
    @AppStorage("allowMediaServerDeletion") private var allowMediaServerDeletion = false
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    @State private var isDeleted = false
    
    @State private var isFavorite: Bool
    @State private var isPlayed: Bool
    
    let onPlay: (() -> Void)?

    init(item: JellyfinItem, server: ServerConfig, onPlay: (() -> Void)? = nil) {
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
            try await JellyfinService.shared.togglePlayed(server: server, itemId: item.id, userId: server.userId ?? "", token: server.accessToken ?? "", isPlayed: newState)
            await MainActor.run { isPlayed = newState }
        } catch {
            print("Failed to toggle played state: \(error.localizedDescription)")
        }
    }

    private func toggleFavorite() async {
        let newState = !isFavorite
        do {
            try await JellyfinService.shared.toggleFavorite(server: server, itemId: item.id, userId: server.userId ?? "", token: server.accessToken ?? "", isFavorite: newState)
            await MainActor.run { isFavorite = newState }
        } catch {
            print("Failed to toggle favorite state: \(error.localizedDescription)")
        }
    }

    private func deleteItem() async {
        isDeleting = true
        do {
            try await JellyfinService.shared.deleteItem(server: server, itemId: item.id, token: server.accessToken ?? "")
            
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
            print("Failed to delete item from Jellyfin server: \(error.localizedDescription)")
        }
        isDeleting = false
    }
}
