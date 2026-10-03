import SwiftUI
import GenPlayerShell

private func plexMediaBitrateText(_ bitrate: Int?) -> String? {
    guard let bitrate = bitrate, bitrate > 0 else { return nil }
    if bitrate >= 1_000_000 {
        return String(format: "%.1f Mbps", Double(bitrate) / 1_000_000.0)
    }
    return "\(max(1, bitrate / 1000)) kbps"
}

private func plexMediaFileSizeText(_ size: Int64?) -> String? {
    guard let size = size, size > 0 else { return nil }
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useKB, .useMB, .useGB]
    formatter.includesUnit = true
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: size)
}

private func plexResolutionBadgeText(for item: PlexItem) -> String? {
    let streamText = item.mediaStreams.first(where: { !$0.isAudio && !$0.isSubtitle })?.displayTitle?.lowercased()
        ?? item.mediaStreams.first(where: { !$0.isAudio && !$0.isSubtitle })?.title?.lowercased()
        ?? item.summary?.lowercased()

    guard let streamText else { return nil }
    if streamText.contains("4k") || streamText.contains("2160") { return "4K" }
    if streamText.contains("1080") { return "1080P" }
    if streamText.contains("720") { return "720P" }
    return nil
}

private func plexDetailMetadataSegments(for item: PlexItem) -> [String] {
    var segments: [String] = []
    if let resolution = plexResolutionBadgeText(for: item) {
        segments.append(resolution)
    }
    segments += MediaTechnicalMetadata.parts(video: item.mediaStreams.first(where: { $0.streamType == 1 })?.technicalMetadata ?? [:])
    if let container = item.mediaContainer?.trimmingCharacters(in: .whitespacesAndNewlines), !container.isEmpty {
        segments.append(container.uppercased())
    }
    if let bitrate = plexMediaBitrateText(item.mediaBitrate) {
        segments.append(bitrate)
    }
    if let size = plexMediaFileSizeText(item.mediaSize) {
        segments.append(size)
    }
    return segments
}

private typealias PlexResolvedNavigationTarget = (item: PlexItem, seasonId: String?, episodeId: String?)

private extension Notification.Name {
    static let plexWatchlistDidChange = Notification.Name("GenPlayer.PlexWatchlistDidChange")
}

private struct PlexWatchlistChangePayload {
    let serverId: UUID
}

private func plexResolvedNavigationTarget(
    server: ServerConfig,
    itemId: String
) async -> PlexResolvedNavigationTarget? {
    do {
        guard let item = try await PlexService.shared.getMetadataItem(server: server, itemId: itemId) else {
            return nil
        }

        switch item.type.lowercased() {
        case "episode":
            if let showId = item.grandparentRatingKey,
               let showItem = try await PlexService.shared.getMetadataItem(server: server, itemId: showId) {
                return (showItem, item.parentRatingKey, item.id)
            }
            if let seasonId = item.parentRatingKey,
               let seasonItem = try await PlexService.shared.getMetadataItem(server: server, itemId: seasonId),
               let showId = seasonItem.parentRatingKey,
               let showItem = try await PlexService.shared.getMetadataItem(server: server, itemId: showId) {
                return (showItem, seasonId, item.id)
            }
        case "season":
            if let showId = item.parentRatingKey,
               let showItem = try await PlexService.shared.getMetadataItem(server: server, itemId: showId) {
                return (showItem, item.id, nil)
            }
        default:
            break
        }

        return (item, nil, nil)
    } catch {
        print("Failed to resolve Plex detail target: \(error)")
        return nil
    }
}

struct PlexLibraryView: View {
    @State var server: ServerConfig
    @ObservedObject var networkService: AppNetworkService
    var onExit: (() -> Void)? = nil
    var targetItemIdToResolve: String? = nil
    
    @State private var libraries: [PlexLibrary] = []
    @State private var continueWatching: [PlexItem] = []
    @State private var watchlistItems: [PlexItem] = []
    @State private var libraryItems: [String: [PlexItem]] = [:]
    @State private var libraryCounts: [String: Int] = [:]
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var prefersUnauthenticatedLocalAccess = false
    @State private var isShowingSearch = false
    @State private var nativeSearchText = ""
    @State private var searchLaunchQuery = ""
    @State private var isSearchOverlayActive = false
    @State private var overlaySearchQuery = ""
    @State private var overlaySearchResults: [String: [PlexItem]] = [:]
    @State private var isOverlaySearching = false
    @State private var overlaySearchTask: Task<Void, Never>? = nil
    @State private var titleAnchorOffset: CGFloat = .zero
    @State private var initialTitleAnchorOffset: CGFloat?
    @State private var myMediaGridWidth: CGFloat = 0
    
    @State private var playerFile: VideoFile?
    @State private var playerPlaylist: [VideoFile]?
    @State private var autoResolveItem: PlexItem? = nil
    @State private var autoResolveSeasonId: String? = nil
    @State private var autoResolveEpisodeId: String? = nil
    @State private var isNavigatingToAutoResolve = false
    private typealias AutoResolveTarget = PlexResolvedNavigationTarget

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    
    private let plexService = PlexService.shared

    private struct HomeCarouselEntry: Identifiable {
        let item: PlexItem
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

    private var hasVisibleContent: Bool {
        !libraries.isEmpty ||
        !continueWatching.isEmpty ||
        !watchlistItems.isEmpty ||
        libraryItems.values.contains(where: { !$0.isEmpty })
    }

    private var requestServer: ServerConfig {
        prefersUnauthenticatedLocalAccess ? unauthenticatedServer(from: server) : server
    }

    private var homeCarouselEntries: [HomeCarouselEntry] {
        var entries: [HomeCarouselEntry] = []
        var seenIds = Set<String>()
        let carouselServer = requestServer

        func append(
            _ items: [PlexItem],
            sourceTitle: String,
            sourceSystemImage: String?
        ) {
            let candidates = MediaHomeCarouselSelection.unique(items, limit: items.count,
                identity: { MediaHomeCarouselSelection.identity(itemID: $0.id, seriesID: $0.type.lowercased() == "season" ? $0.parentRatingKey : $0.grandparentRatingKey, itemType: $0.type) },
                lastPlayedAt: { $0.lastViewedAt })
            for item in candidates {
                guard entries.count < 6 else { break }
                guard item.backdropImageURL(server: carouselServer) != nil else { continue }
                guard seenIds.insert(MediaHomeCarouselSelection.identity(itemID: item.id, seriesID: (item.type.lowercased() == "season" ? item.parentRatingKey : item.grandparentRatingKey), itemType: item.type)).inserted else { continue }
                entries.append(
                    HomeCarouselEntry(
                        item: item,
                        sourceTitle: sourceTitle,
                        sourceSystemImage: sourceSystemImage
                    )
                )
                if entries.count >= 6 { return }
            }
        }

        append(
            continueWatching.filter { plexActiveResumeSnapshot(for: $0) != nil },
            sourceTitle: NSLocalizedString("Continue Watching", comment: ""),
            sourceSystemImage: "clock.fill"
        )

        for library in libraries where entries.count < 6 {
            append(
                libraryItems[library.id] ?? [],
                sourceTitle: library.title,
                sourceSystemImage: library.iconName
            )
        }

        if entries.isEmpty {
            append(
                watchlistItems,
                sourceTitle: NSLocalizedString("Favorites", comment: ""),
                sourceSystemImage: "heart.fill"
            )
        }

        return entries
    }

    private func plexActiveResumeSnapshot(for item: PlexItem) -> PlaybackProgressSnapshot? {
        guard let snapshot = PlaybackProgressSnapshot.fromFraction(
            item.playbackProgress,
            played: item.isPlayed
        ) else {
            return nil
        }
        guard snapshot.displayedProgress > 0, !snapshot.isFinished else { return nil }
        return snapshot
    }

    private var homeCarouselItems: [MediaHomeCarouselItem] {
        let carouselServer = requestServer

        return homeCarouselEntries.map { entry in
            let item = entry.item
            let isPlayable = item.isPlayable

            return MediaHomeCarouselItem(
                id: item.id,
                title: item.displayTitle,
                subtitle: item.metadataLine,
                metadataSegments: plexCarouselMetadataSegments(for: item),
                overview: plexCarouselOverview(for: item),
                sourceTitle: entry.sourceTitle,
                sourceSystemImage: entry.sourceSystemImage,
                imageURL: item.backdropImageURL(server: carouselServer),
                backdropImageURL: item.backdropImageURL(server: carouselServer),
                portraitImageURL: item.posterImageURL(server: carouselServer),
                logoURLs: nil,
                actionTitle: isPlayable ? NSLocalizedString("Play", comment: "") : NSLocalizedString("View Details", comment: ""),
                actionSystemImage: isPlayable ? "play.fill" : "info.circle",
                playbackProgress: PlaybackProgressSnapshot.fromFraction(
                    item.playbackProgress,
                    played: item.isPlayed
                )
            )
        }
    }

    private var showsInlineNavigationTitle: Bool {
        guard let initialTitleAnchorOffset else { return true }
        return titleAnchorOffset >= initialTitleAnchorOffset - 24
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

    private var plexHomeToolbarColor: Color? {
        #if os(iOS)
        return useLightToolbar ? .white : nil
        #else
        return nil
        #endif
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
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                        Color.clear
                            .frame(height: 0)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(
                                        key: MediaLibraryHeaderOffsetPreferenceKey.self,
                                        value: proxy.frame(in: .named("plexLibraryScroll")).minY
                                    )
                                }
                            )

                        if !homeCarouselItems.isEmpty {
                            MediaHomeCarouselView(
                                items: homeCarouselItems,
                                onSelect: { selectedItem in
                                    guard let entry = homeCarouselEntries.first(where: { $0.id == selectedItem.id }) else { return }
                                    openDetails(for: entry.item)
                                },
                                onAction: { selectedItem in
                                    guard let entry = homeCarouselEntries.first(where: { $0.id == selectedItem.id }) else { return }
                                    openCarouselItem(entry.item)
                                }
                            )
                        }

                        VStack(alignment: .leading, spacing: 20) {
                            if !continueWatching.isEmpty {
                                PlexLandscapeMediaSection(
                                    title: NSLocalizedString("Continue Watching", comment: ""),
                                    systemImage: "clock.fill",
                                    items: continueWatching,
                                    server: requestServer,
                                    horizontalPadding: myMediaGridPadding,
                                    onPlay: play,
                                    destination: { item in
                                        PlexItemDetailView(
                                            server: requestServer,
                                            item: item,
                                            onExit: nil,
                                            onPlay: play
                                        )
                                    }
                                )
                            }

                            if !watchlistItems.isEmpty {
                                PlexHorizontalSection(
                                    title: NSLocalizedString("Favorites", comment: ""),
                                    systemImage: "heart.fill",
                                    items: watchlistItems,
                                    server: requestServer,
                                    horizontalPadding: myMediaGridPadding,
                                    destination: { item in
                                        PlexItemResolverView(
                                            server: requestServer,
                                            item: item,
                                            onExit: nil,
                                            onPlay: play
                                        )
                                    }
                                )
                            }

                            if !libraries.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    MediaSectionHeaderLabel(
                                        title: NSLocalizedString("My Media", comment: ""),
                                        systemImage: "square.grid.2x2.fill"
                                    )
                                        .padding(.horizontal, myMediaGridPadding)

                                    LazyVGrid(columns: myMediaColumns, spacing: myMediaGridSpacing) {
                                        ForEach(libraries) { library in
                                            NavigationLink(
                                                destination: PlexLibraryDetailView(
                                                    server: requestServer,
                                                    library: library,
                                                    onExit: nil,
                                                    onPlay: play
                                                )
                                            ) {
                                                PlexLibraryCard(
                                                    library: library,
                                                    server: requestServer,
                                                    previewItem: libraryItems[library.id]?.first,
                                                    itemCount: libraryCounts[library.id] ?? library.itemCount
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

                            ForEach(libraries) { library in
                                if let items = libraryItems[library.id], !items.isEmpty {
                                    PlexHorizontalSection(
                                        title: library.title,
                                        items: items,
                                        server: requestServer,
                                        itemCount: libraryCounts[library.id] ?? library.itemCount,
                                        viewAllDestination: AnyView(
                                            PlexLibraryDetailView(
                                                server: requestServer,
                                                library: library,
                                                onExit: nil,
                                                onPlay: play
                                            )
                                        ),
                                        destination: { item in
                                            PlexItemDetailView(
                                                server: requestServer,
                                                item: item,
                                                onExit: nil,
                                                onPlay: play
                                            )
                                        }
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
            .coordinateSpace(name: "plexLibraryScroll")
            .onPreferenceChange(MediaLibraryHeaderOffsetPreferenceKey.self) { value in
                if initialTitleAnchorOffset == nil {
                    initialTitleAnchorOffset = value
                }
                titleAnchorOffset = value
            }
            .refreshableCompat {
                await loadData(quiet: true)
            }
            #if os(iOS)
            .ignoresSafeArea(edges: usesFullBleedHomeCarousel ? [.top, .horizontal] : [])
            #else
            .ignoresSafeArea(edges: usesFullBleedHomeCarousel ? [.top, .horizontal] : [])
            #endif
            
            if isLoading {
                ProgressView()
                    .scaleEffect(1.4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            
            if !isLoading && errorMessage == nil && !hasVisibleContent {
                VStack(spacing: 12) {
                    Image(systemName: "play.square.stack.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary.opacity(0.7))
                    Text(NSLocalizedString("No Plex libraries found", comment: ""))
                        .font(.headline)
                    Text(NSLocalizedString("Plex returned no libraries or playable items for this account. Verify the server address, selected account, and library access.", comment: ""))
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    PlexConnectionDetails(server: server)
                    Button(NSLocalizedString("Retry", comment: "")) {
                        Task { await loadData() }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .padding(24)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(16)
                .shadow(radius: 8)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        }
        #if os(iOS)
        .ignoresSafeArea(edges: usesFullBleedHomeCarousel ? [.top, .horizontal] : [.top])
        #else
        .ignoresSafeArea(edges: usesFullBleedHomeCarousel ? [.top, .horizontal] : [])
        #endif
        .appErrorAlert(
            message: $errorMessage,
            title: NSLocalizedString("Couldn't load library", comment: ""),
            retryTitle: NSLocalizedString("Retry", comment: ""),
            retryAction: {
                Task { await loadData() }
            }
        )
        .background(
            Group {
                if isShowingSearch || !searchLaunchQuery.isEmpty {
                    NavigationLink(
                        destination: NavigationLazyView {
                            PlexHomeSearchView(
                                server: requestServer,
                                libraries: libraries,
                                onPlay: play,
                                initialQuery: searchLaunchQuery
                            )
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
                #if os(iOS)
                .foregroundColor(useLightToolbar ? .white : Color(UIColor.label))
                #endif
            }
        }
        #if os(iOS)
        .navBarTransparentCompat(isTransparent: useLightToolbar)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(action: { onExit?() }) {
                    AppToolbarIcon.serverExit(
                        legacyForegroundColor: plexHomeToolbarColor
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
                    AppToolbarIcon(systemName: "magnifyingglass")
                }
                #endif

                if PlatformHelper.isRunningOnMac {
                    Button(action: {
                        Task { await loadData() }
                    }) {
                        AppToolbarIcon(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .onChange(of: overlaySearchQuery) { newQuery in
            scheduleOverlaySearch(for: newQuery)
        }
        .fullScreenCover(item: $playerFile, onDismiss: {
            UIApplication.refreshInterfaceChrome()
            Task { await loadData(quiet: true) }
        }) { file in
            PlayerView(initialFile: file, playlist: $playerPlaylist)
        }
        .onReceive(NotificationCenter.default.publisher(for: .remotePlaybackStateDidChange)) { notification in
            guard let payload = notification.object as? PlaybackStateRefreshPayload,
                  payload.serverId == server.id else {
                return
            }
            Task { await loadData(quiet: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .plexWatchlistDidChange)) { notification in
            guard let payload = notification.object as? PlexWatchlistChangePayload,
                  payload.serverId == server.id else {
                return
            }
            Task { await refreshHomeWatchlist(using: requestServer) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteItemDidDelete)) { notification in
            guard let payload = notification.object as? RemoteItemDeletePayload,
                  payload.serverId == server.id else { return }
            
            let id = payload.itemId
            continueWatching.removeAll(where: { $0.id == id })
            watchlistItems.removeAll(where: { $0.id == id })
            for key in libraryItems.keys {
                libraryItems[key]?.removeAll(where: { $0.id == id })
            }
        }
        .onAppear {
            if libraries.isEmpty {
                Task { await loadData() }
            } else {
                Task { await refreshHomeWatchlist(using: requestServer) }
            }
        }
        .onDisappear {
            cleanupTasksAndTransientState()
        }
        .edgeSwipeToDismiss(action: {
            cleanupTasksAndTransientState()
            if let onExit = onExit {
                onExit()
            } else {
                presentationMode.wrappedValue.dismiss()
            }
        })
    }

    private func cleanupTasksAndTransientState() {
        overlaySearchTask?.cancel()
        overlaySearchTask = nil
    }

    #if os(iOS)
    @ViewBuilder
    private var searchToolbarControl: some View {
        if #unavailable(iOS 26.0) {
            Button { isSearchOverlayActive = true } label: {
                AppToolbarIcon(systemName: "magnifyingglass", legacyForegroundColor: plexHomeToolbarColor)
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
            plexSearchOverlayResults
        }
    }
    #endif

    // MARK: - Expandable Search Overlay Logic

    @ViewBuilder
    private var plexSearchOverlayResults: some View {
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
        } else if !overlaySearchResults.values.contains(where: { !$0.isEmpty }) && !overlaySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(spacing: 12) {
                Spacer(minLength: 40)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                Text(NSLocalizedString("No matching Plex items", comment: ""))
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 20) {
                ForEach(libraries) { library in
                    if let items = overlaySearchResults[library.id], !items.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(library.title)
                                .font(.headline)
                                .padding(.horizontal, 16)

                            LazyVStack(spacing: 12) {
                                ForEach(items) { item in
                                    NavigationLink(
                                        destination: PlexItemDetailView(
                                            server: requestServer,
                                            item: item,
                                            onExit: nil,
                                            onPlay: play
                                        )
                                    ) {
                                        PlexLibraryListRow(item: item, server: requestServer)
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
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
    }

    private func scheduleOverlaySearch(for rawQuery: String, immediate: Bool = false) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        overlaySearchTask?.cancel()

        guard !query.isEmpty else {
            overlaySearchResults = [:]
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
                let resolved = try await plexService.searchLibraries(
                    server: requestServer,
                    libraries: libraries,
                    query: query,
                    limitPerLibrary: 24
                )

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.overlaySearchResults = resolved
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
    
    @MainActor
    private func loadData(quiet: Bool = false) async {
        if !quiet {
            isLoading = true
        }
        errorMessage = nil
        
        // Plex token is optional; if user placed token in password field, persist it.
        if (server.accessToken ?? "").isEmpty, let raw = server.passwordSecret, !raw.isEmpty {
            server.accessToken = raw
            networkService.updateServer(server)
        }

        do {
            let currentRequestServer = requestServer

            if let targetId = targetItemIdToResolve, autoResolveItem == nil {
                let resolvedTarget = await resolveAutoNavigationTargetIfNeeded(itemId: targetId)
                if let resolvedTarget {
                    autoResolveItem = resolvedTarget.item
                    autoResolveSeasonId = resolvedTarget.seasonId
                    autoResolveEpisodeId = resolvedTarget.episodeId
                    isNavigatingToAutoResolve = true
                }
            }

            let result = try await fetchHomeData(using: currentRequestServer)
            apply(result)

            if !prefersUnauthenticatedLocalAccess,
               shouldAttemptUnauthenticatedLocalFallback(with: result, server: server) {
                let fallbackServer = unauthenticatedServer(from: server)
                if let targetId = targetItemIdToResolve, autoResolveItem == nil {
                    let resolvedTarget = await plexResolvedNavigationTarget(server: fallbackServer, itemId: targetId)
                    if let resolvedTarget {
                        autoResolveItem = resolvedTarget.item
                        autoResolveSeasonId = resolvedTarget.seasonId
                        autoResolveEpisodeId = resolvedTarget.episodeId
                        isNavigatingToAutoResolve = true
                    }
                }
                let fallbackResult = try await fetchHomeData(using: fallbackServer)
                if hasVisibleContent(in: fallbackResult) {
                    prefersUnauthenticatedLocalAccess = true
                    apply(fallbackResult)
                }
            }
        } catch {
            if shouldAttemptPlexAutoRepair(after: error) {
                do {
                    let repairedServer = try await networkService.testConnection(server)
                    let didResolveEndpoint = repairedServer.fullURL != server.fullURL
                        || repairedServer.useSSL != server.useSSL
                        || repairedServer.port != server.port

                    if didResolveEndpoint {
                        server = repairedServer
                        networkService.updateServer(repairedServer)
                        let repairedResult = try await fetchHomeData(using: requestServer)
                        apply(repairedResult)

                        if !prefersUnauthenticatedLocalAccess,
                           shouldAttemptUnauthenticatedLocalFallback(with: repairedResult, server: repairedServer) {
                            let fallbackServer = unauthenticatedServer(from: repairedServer)
                            let fallbackResult = try await fetchHomeData(using: fallbackServer)
                            if hasVisibleContent(in: fallbackResult) {
                                prefersUnauthenticatedLocalAccess = true
                                apply(fallbackResult)
                            }
                        }
                        return
                    }
                } catch {
                    // Keep the original load error if endpoint repair is not helpful.
                }
            }

            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func fetchHomeData(using currentServer: ServerConfig) async throws -> PlexHomeData {
        // Keep the home fetch sequential. This path has previously tripped
        // Swift concurrency fatal errors when Plex home refreshes re-enter.
        let fetchedLibraries = try await plexService.getLibraries(server: currentServer)
        Task {
            await MediaServerSummaryService.shared.refreshSummary(for: currentServer)
        }
        let continueItems = try await plexService.getContinueWatching(server: currentServer, limit: 20)
        let watchlistItems = await loadHomeWatchlistItemsOrEmpty(using: currentServer)

        var latestMap: [String: [PlexItem]] = [:]
        for library in fetchedLibraries {
            if library.type.lowercased() == "show" || library.type.lowercased() == "movie" {
                let items = try await plexService.getLibraryItems(
                    server: currentServer,
                    library: library,
                    sortBy: PlexLibrarySortOption.dateAdded.rawValue,
                    sortOrder: "Descending",
                    searchQuery: "",
                    limit: 24
                )
                if items.isEmpty {
                    let fallbackItems = try await plexService.getRecentlyAdded(server: currentServer, libraryId: library.id, limit: 24)
                    latestMap[library.id] = filteredHomeItems(fallbackItems, for: library)
                } else {
                    latestMap[library.id] = items
                }
            } else {
                let items = try await plexService.getRecentlyAdded(server: currentServer, libraryId: library.id, limit: 24)
                latestMap[library.id] = filteredHomeItems(items, for: library)
            }
        }

        return PlexHomeData(
            libraries: fetchedLibraries,
            continueWatching: continueItems.filter(\.isPlayable),
            watchlistItems: watchlistItems,
            libraryItems: latestMap
        )
    }

    private func apply(_ data: PlexHomeData) {
        libraries = data.libraries
        var counts: [String: Int] = [:]
        for lib in data.libraries {
            if let c = lib.itemCount {
                counts[lib.id] = c
            }
        }
        libraryCounts = counts
        continueWatching = data.continueWatching
        watchlistItems = data.watchlistItems
        libraryItems = data.libraryItems
        isLoading = false
    }

    private func hasVisibleContent(in data: PlexHomeData) -> Bool {
        !data.libraries.isEmpty ||
        !data.continueWatching.isEmpty ||
        !data.watchlistItems.isEmpty ||
        data.libraryItems.values.contains(where: { !$0.isEmpty })
    }

    private func resolveAutoNavigationTargetIfNeeded(itemId: String) async -> AutoResolveTarget? {
        await plexResolvedNavigationTarget(server: requestServer, itemId: itemId)
    }

    private func autoResolveDestination(for item: PlexItem) -> some View {
        PlexItemDetailView(
            server: requestServer,
            item: item,
            onExit: nil,
            onPlay: play,
            initialSeasonId: autoResolveSeasonId,
            initialEpisodeId: autoResolveEpisodeId
        )
    }

    private func filteredHomeItems(_ items: [PlexItem], for library: PlexLibrary) -> [PlexItem] {
        switch library.type.lowercased() {
        case "movie":
            return items.filter { $0.type.lowercased() == "movie" || $0.type.lowercased() == "video" || $0.isPlayable }
        case "show":
            return items.filter { $0.type.lowercased() == "show" }
        default:
            return items.filter { $0.isPlayable || $0.isContainer }
        }
    }

    private func loadHomeWatchlistItems(using currentServer: ServerConfig) async throws -> [PlexItem] {
        try await plexService.getWatchlist(
            server: currentServer,
            sort: "watchlistedAt:desc",
            limit: 18
        )
    }

    private func loadHomeWatchlistItemsOrEmpty(using currentServer: ServerConfig) async -> [PlexItem] {
        (try? await loadHomeWatchlistItems(using: currentServer)) ?? []
    }

    private func refreshHomeWatchlist(using currentServer: ServerConfig) async {
        guard let updatedWatchlist = try? await loadHomeWatchlistItems(using: currentServer) else {
            return
        }
        await MainActor.run {
            watchlistItems = updatedWatchlist
        }
    }

    private func shouldAttemptUnauthenticatedLocalFallback(with data: PlexHomeData, server: ServerConfig) -> Bool {
        guard !hasVisibleContent(in: data) else { return false }
        guard isLikelyLocalPlexHost(server) else { return false }

        let tokenCandidates = [
            server.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
            server.passwordSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        return tokenCandidates.contains(where: { ($0?.isEmpty == false) })
    }

    private func unauthenticatedServer(from server: ServerConfig) -> ServerConfig {
        var stripped = server
        stripped.accessToken = nil
        stripped.passwordSecret = nil
        return stripped
    }

    private func isLikelyLocalPlexHost(_ server: ServerConfig) -> Bool {
        guard let components = URLComponents(string: server.fullURL),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            return false
        }

        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") {
            return true
        }

        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }

        if octets[0] == 10 || octets[0] == 127 {
            return true
        }
        if octets[0] == 192 && octets[1] == 168 {
            return true
        }
        if octets[0] == 172 && (16...31).contains(octets[1]) {
            return true
        }

        return false
    }

    private func shouldAttemptPlexAutoRepair(after error: Error) -> Bool {
        let transportCodes = [
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorTimedOut,
            NSURLErrorNetworkConnectionLost
        ]

        // Plex Media Server redirects HTTP → HTTPS with self-signed certs.
        // If the initial request hits a TLS error, the auto-repair probe
        // (which trusts self-signed certs) can find the correct endpoint.
        let tlsCodes = [
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorSecureConnectionFailed
        ]

        func containsRepairableFailure(_ error: NSError) -> Bool {
            if error.domain == NSURLErrorDomain && (transportCodes.contains(error.code) || tlsCodes.contains(error.code)) {
                return true
            }
            let posixTransportCodes: [Int32] = [ECONNREFUSED, ETIMEDOUT, EHOSTUNREACH, ENETUNREACH]
            if error.domain == NSPOSIXErrorDomain && posixTransportCodes.contains(Int32(error.code)) {
                return true
            }
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                return containsRepairableFailure(underlying)
            }
            return false
        }

        return containsRepairableFailure(error as NSError)
    }

    private func openCarouselItem(_ item: PlexItem) {
        if item.isPlayable {
            play(item)
        } else {
            openDetails(for: item)
        }
    }

    private func plexCarouselMetadataSegments(for item: PlexItem) -> [String] {
        var segments: [String] = []

        if let type = plexCarouselTypeText(for: item.type) {
            segments.append(type)
        }
        if let year = item.year {
            segments.append(String(year))
        }
        if let rating = item.contentRating, !rating.isEmpty {
            segments.append(rating)
        }
        if let duration = item.durationSeconds {
            segments.append(PlexUIHelpers.runtimeText(seconds: duration))
        }
        if let score = item.rating, score > 0 {
            segments.append(String(format: "★ %.1f", score))
        }
        if let countText = plexCarouselCountText(for: item) {
            segments.append(countText)
        }

        return Array(segments.prefix(5))
    }

    private func plexCarouselOverview(for item: PlexItem) -> String? {
        if let summary = item.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            return summary
        }
        let genres = item.genres.prefix(3).joined(separator: " • ")
        return genres.isEmpty ? nil : genres
    }

    private func plexCarouselTypeText(for type: String) -> String? {
        switch type.lowercased() {
        case "movie":
            return NSLocalizedString("Movie", comment: "")
        case "show":
            return NSLocalizedString("Series", comment: "")
        case "season":
            return NSLocalizedString("Season", comment: "")
        case "episode":
            return NSLocalizedString("Episode", comment: "")
        case "playlist":
            return NSLocalizedString("Playlist", comment: "")
        case "collection":
            return NSLocalizedString("Collection", comment: "")
        default:
            return nil
        }
    }

    private func plexCarouselCountText(for item: PlexItem) -> String? {
        switch item.type.lowercased() {
        case "show":
            if let childCount = item.childCount, childCount > 0 {
                let unit = childCount == 1
                    ? NSLocalizedString("Season", comment: "")
                    : NSLocalizedString("Seasons", comment: "")
                return "\(childCount) \(unit)"
            }
            if let leafCount = item.leafCount, leafCount > 0 {
                let unit = leafCount == 1
                    ? NSLocalizedString("Episode", comment: "")
                    : NSLocalizedString("Episodes", comment: "")
                return "\(leafCount) \(unit)"
            }
        case "season":
            guard let leafCount = item.leafCount, leafCount > 0 else { return nil }
            let unit = leafCount == 1
                ? NSLocalizedString("Episode", comment: "")
                : NSLocalizedString("Episodes", comment: "")
            return "\(leafCount) \(unit)"
        default:
            break
        }
        return nil
    }

    private func openDetails(for item: PlexItem) {
        switch item.type.lowercased() {
        case "episode", "season":
            Task {
                let resolvedTarget = await plexResolvedNavigationTarget(server: requestServer, itemId: item.id)
                    ?? (item, nil, nil)
                await MainActor.run {
                    autoResolveItem = resolvedTarget.item
                    autoResolveSeasonId = resolvedTarget.seasonId
                    autoResolveEpisodeId = resolvedTarget.episodeId
                    isNavigatingToAutoResolve = true
                }
            }
        default:
            autoResolveSeasonId = nil
            autoResolveEpisodeId = nil
            autoResolveItem = item
            isNavigatingToAutoResolve = true
        }
    }

    private func play(_ item: PlexItem) {
        guard item.isPlayable else { return }
        
        Task {
            do {
                let resolvedItem = try await plexService.resolveMetadataItem(server: requestServer, item: item) ?? item
                guard let file = plexService.buildPlayableVideoFile(server: requestServer, item: resolvedItem) else {
                    throw NSError(
                        domain: "PlexLibrary",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Unsupported file type", comment: "")]
                    )
                }

                playerPlaylist = [file]
                playerFile = file
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct PlexHomeSearchView: View {
    @Environment(\.presentationMode) private var presentationMode
    let server: ServerConfig
    let libraries: [PlexLibrary]
    var onPlay: (PlexItem) -> Void
    let initialQuery: String

    @State private var searchText = ""
    @State private var results: [String: [PlexItem]] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchReloadTask: Task<Void, Never>?

    private let plexService = PlexService.shared

    private var supportsNativeSearch: Bool {
        if #available(iOS 15.0, *) {
            return true
        }
        return false
    }

    private var hasResults: Bool {
        results.values.contains(where: { !$0.isEmpty })
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    init(
        server: ServerConfig,
        libraries: [PlexLibrary],
        onPlay: @escaping (PlexItem) -> Void,
        initialQuery: String = ""
    ) {
        self.server = server
        self.libraries = libraries
        self.onPlay = onPlay
        self.initialQuery = initialQuery
        self._searchText = State(initialValue: initialQuery)
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !supportsNativeSearch {
                        HStack(spacing: 10) {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField(NSLocalizedString("Search in library...", comment: ""), text: $searchText)
                                .disableAutocorrection(true)
                                .autocapitalization(.none)
                            if !searchText.isEmpty {
                                Button(action: clearSearch) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(12)
                        .padding(.horizontal)
                    }

                    if trimmedSearchText.isEmpty {
                        Text(NSLocalizedString("Start typing to search your Plex libraries.", comment: ""))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    } else if hasResults {
                        ForEach(libraries) { library in
                            if let items = results[library.id], !items.isEmpty {
                                Text(library.title)
                                    .font(.headline)
                                    .padding(.horizontal)

                                LazyVStack(spacing: 12) {
                                    ForEach(items) { item in
                                        NavigationLink(
                                            destination: PlexItemDetailView(
                                                server: server,
                                                item: item,
                                                onExit: nil,
                                                onPlay: onPlay
                                            )
                                        ) {
                                            PlexLibraryListRow(item: item, server: server)
                                        }
                                        .buttonStyle(PlainButtonStyle())
                                    }
                                }
                                .padding(.horizontal)
                            }
                        }
                    } else if !isLoading {
                        Text(NSLocalizedString("No matching Plex items", comment: ""))
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    }
                }
                .padding(.top, 8)
                .padding(.bottom, 20)
            }

            if isLoading {
                ProgressView()
            }

        }
        .navigationTitle(NSLocalizedString("Search", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .customBackButton()
        .mediaLibraryNavigationToolbar {
            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                AppToolbarIcon(systemName: "chevron.left")
            }
        } home: {
            Button(action: { NavigationUtil.popToRootView() }) {
                AppToolbarIcon(systemName: "house")
            }
        }
        .appErrorAlert(
            message: $errorMessage,
            title: NSLocalizedString("Search unavailable", comment: "")
        )
        .compatSearchable(
            text: $searchText,
            prompt: NSLocalizedString("Search in library...", comment: "")
        )
        .onDisappear {
            searchReloadTask?.cancel()
        }
        .onChange(of: searchText) { _ in
            scheduleSearchReload()
        }
        .onChange(of: initialQuery) { newValue in
            if searchText != newValue {
                searchText = newValue
            } else if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasResults {
                scheduleSearchReload(immediate: true)
            }
        }
        .onAppear {
            if !trimmedSearchText.isEmpty && !hasResults {
                scheduleSearchReload(immediate: true)
            }
        }
    }

    private func clearSearch() {
        searchText = ""
        results = [:]
    }

    private func scheduleSearchReload(immediate: Bool = false) {
        searchReloadTask?.cancel()
        let query = trimmedSearchText
        guard !query.isEmpty else {
            isLoading = false
            results = [:]
            return
        }
        searchReloadTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled else { return }
            await loadResults(query: query)
        }
    }

    private func loadResults(query: String) async {
        guard !query.isEmpty else {
            await MainActor.run {
                results = [:]
                isLoading = false
            }
            return
        }

        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }

        do {
            let resolved = try await plexService.searchLibraries(
                server: server,
                libraries: libraries,
                query: query,
                limitPerLibrary: 24
            )

            guard !Task.isCancelled else { return }
            let shouldApplyResults = await MainActor.run {
                searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query
            }
            guard shouldApplyResults else { return }
            await MainActor.run {
                results = resolved
                isLoading = false
            }
        } catch {
            if isCancellation(error) {
                await MainActor.run {
                    isLoading = false
                }
                return
            }
            let shouldApplyResults = await MainActor.run {
                searchText.trimmingCharacters(in: .whitespacesAndNewlines) == query
            }
            guard shouldApplyResults else { return }
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

private struct PlexHomeData {
    let libraries: [PlexLibrary]
    let continueWatching: [PlexItem]
    let watchlistItems: [PlexItem]
    let libraryItems: [String: [PlexItem]]
}

private struct PlexConnectionDetails: View {
    let server: ServerConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(NSLocalizedString("Server Name", comment: ""))
                    .foregroundColor(.secondary)
                Spacer()
                Text(server.name)
                    .multilineTextAlignment(.trailing)
            }

            HStack(alignment: .top, spacing: 8) {
                Text(NSLocalizedString("Connection Address", comment: ""))
                    .foregroundColor(.secondary)
                Spacer()
                Text(server.fullURL)
                    .multilineTextAlignment(.trailing)
            }
        }
        .font(.caption)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(UIColor.tertiarySystemBackground))
        .cornerRadius(10)
        .padding(.horizontal)
    }
}

private struct PlexLandscapeMediaSection<Destination: View>: View {
    let title: String
    let systemImage: String?
    let items: [PlexItem]
    let server: ServerConfig
    let onPlay: (PlexItem) -> Void
    let destination: (PlexItem) -> Destination
    @ObservedObject private var offlineIndex = OfflineMediaIndexStore.shared

    init(
        title: String,
        systemImage: String? = nil,
        items: [PlexItem],
        server: ServerConfig,
        horizontalPadding: CGFloat? = nil,
        onPlay: @escaping (PlexItem) -> Void,
        destination: @escaping (PlexItem) -> Destination
    ) {
        self.title = title
        self.systemImage = systemImage
        self.items = items
        self.server = server
        self.horizontalPadding = horizontalPadding
        self.onPlay = onPlay
        self.destination = destination
    }

    var horizontalPadding: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MediaSectionHeaderLabel(title: title, systemImage: systemImage)
                .padding(.horizontal, horizontalPadding ?? 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(items) { item in
                        sectionCard(for: item)
                    }
                }
                .padding(.horizontal, horizontalPadding ?? 16)
            }
            .duoMediaShelfViewport()
        }
    }

    @ViewBuilder
    private func sectionCard(for item: PlexItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if item.isPlayable {
                Button(action: {
                    onPlay(item)
                }) {
                    PlexLandscapeMediaCard(item: item, server: server, showsText: false)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                NavigationLink(destination: destination(item)) {
                    PlexLandscapeMediaCard(item: item, server: server, showsText: false)
                }
                .buttonStyle(PlainButtonStyle())
            }

            NavigationLink(destination: destination(item)) {
                PlexLandscapeMediaCardText(
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

private struct PlexHorizontalSection<Destination: View>: View {
    let title: String
    let systemImage: String?
    let items: [PlexItem]
    let server: ServerConfig
    var itemCount: Int? = nil
    let viewAllDestination: AnyView?
    let destination: (PlexItem) -> Destination

    init(
        title: String,
        systemImage: String? = nil,
        items: [PlexItem],
        server: ServerConfig,
        itemCount: Int? = nil,
        viewAllDestination: AnyView? = nil,
        horizontalPadding: CGFloat? = nil,
        destination: @escaping (PlexItem) -> Destination
    ) {
        self.title = title
        self.systemImage = systemImage
        self.items = items
        self.server = server
        self.itemCount = itemCount
        self.viewAllDestination = viewAllDestination
        self.horizontalPadding = horizontalPadding
        self.destination = destination
    }
    
    var horizontalPadding: CGFloat? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MediaSectionHeaderLabel(
                    title: title,
                    systemImage: systemImage,
                    font: .title3,
                    weight: .bold
                )

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

                if let viewAllDestination {
                    NavigationLink(destination: viewAllDestination) {
                        Text(NSLocalizedString("View All", comment: ""))
                            .font(.subheadline)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .padding(.horizontal, horizontalPadding ?? 16)
            
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in
                        NavigationLink(destination: destination(item)) {
                            PlexPosterCard(item: item, server: server)
                        }
                        .buttonStyle(PlainButtonStyle())
                    }
                }
                .padding(.horizontal, horizontalPadding ?? 16)
            }
            .duoMediaShelfViewport()
        }
    }
}

private struct PlexLandscapeMediaCard: View {
    let item: PlexItem
    let server: ServerConfig
    var showsText: Bool = true

    private let cardWidth = MediaCardMetrics.landscapeWidth
    private let cardHeight = MediaCardMetrics.landscapeHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: item.backdropImageURL(server: server))
                    .aspectRatio(16 / 9, contentMode: .fill)
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
                    Circle()
                        .fill(Color.black.opacity(0.6))
                        .frame(
                            width: MediaCardMetrics.landscapePlayBadgeSize,
                            height: MediaCardMetrics.landscapePlayBadgeSize
                        )
                        .overlay(
                            Image(systemName: "play.fill")
                                .foregroundColor(.white)
                                .font(.system(size: 14))
                        )
                        .padding(.trailing, 10)
                        .padding(.bottom, 10)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: cardWidth, height: cardHeight)

            if showsText {
                Text(appLineBreakableTitle(item.displayTitle))
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .layoutPriority(1)

                if let subtitle = item.metadataLine {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: cardWidth)
        .contentShape(Rectangle())
        .modifier(PlexMediaContextMenuModifier(item: item, server: server))
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        PlaybackProgressSnapshot.fromFraction(
            item.playbackProgress,
            played: item.isPlayed
        )
    }
}

private struct PlexLandscapeMediaCardText: View {
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

private struct PlexPosterCard: View {
    let item: PlexItem
    let server: ServerConfig
    var cardWidth: CGFloat = MediaCardMetrics.posterWidth
    @ObservedObject private var offlineIndex = OfflineMediaIndexStore.shared

    private var posterHeight: CGFloat { cardWidth * 1.5 }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: item.posterImageURL(server: server))
                    .aspectRatio(2 / 3, contentMode: .fill)
                    .frame(width: cardWidth, height: posterHeight)
                    .clipped()
                    .cornerRadius(8)

                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(height: 60)
                .cornerRadius(8, corners: [.bottomLeft, .bottomRight])
                .allowsHitTesting(false)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let rating = item.rating, rating > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 8))
                                Text(String(format: "%.1f", rating))
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(.yellow)
                        }

                        Spacer()

                        if let childCountLabel {
                            Text(childCountLabel)
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
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .layoutPriority(1)

                DownloadedMetadataLine(
                    text: item.metadataLine,
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
        .modifier(PlexMediaContextMenuModifier(item: item, server: server))
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        PlaybackProgressSnapshot.fromFraction(
            item.playbackProgress,
            played: item.isPlayed
        )
    }

    private var isDownloaded: Bool {
        offlineIndex.isDownloaded(serverId: server.id, remoteItemId: item.id)
    }

    private var childCountLabel: String? {
        switch item.type.lowercased() {
        case "show":
            guard let count = item.childCount, count > 0 else { return nil }
            return count == 1 ? "1 \(NSLocalizedString("Season", comment: "Singular for season count"))" : "\(count) \(NSLocalizedString("Seasons", comment: "Plural for season count"))"
        case "season":
            let count = item.leafCount ?? item.childCount ?? 0
            guard count > 0 else { return nil }
            return count == 1 ? String(format: NSLocalizedString("%d Episode", comment: "Singular for episode count"), 1) : String(format: NSLocalizedString("%d Episodes", comment: "Plural for episode count"), count)
        default:
            return nil
        }
    }
}

// MARK: - Plex Thumb Card (16:9)

private struct PlexThumbCard: View {
    let item: PlexItem
    let server: ServerConfig
    var cardWidth: CGFloat? = nil
    var onPlay: (() -> Void)? = nil

    private var fixedWidth: CGFloat? { cardWidth }
    private var defaultCardHeight: CGFloat { (fixedWidth ?? MediaCardMetrics.landscapeWidth) * 9 / 16 }
    @ObservedObject private var offlineIndex = OfflineMediaIndexStore.shared

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
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .layoutPriority(1)

                DownloadedMetadataLine(
                    text: item.metadataLine,
                    isDownloaded: isDownloaded,
                    font: .caption2,
                    iconSize: 10
                )

                Spacer(minLength: 0)
            }
            .frame(height: MediaCardMetrics.posterTextHeight, alignment: .topLeading)
        }
        .modifier(PlexCardWidthModifier(width: fixedWidth))
        .contentShape(Rectangle())
        .modifier(PlexMediaContextMenuModifier(item: item, server: server, onPlay: onPlay))
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
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(width: fixedWidth, height: defaultCardHeight)
                    .clipped()
                    .cornerRadius(8)
            } else {
                Color.clear
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .overlay(
                        RemoteImage(url: item.landscapeImageURL(server: server))
                            .aspectRatio(16 / 9, contentMode: .fill)
                    )
                    .clipped()
                    .cornerRadius(8)
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.6)],
                startPoint: .center,
                endPoint: .bottom
            )
            .frame(height: 48)
            .cornerRadius(8, corners: [.bottomLeft, .bottomRight])
            .allowsHitTesting(false)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let rating = item.rating, rating > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8))
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 9, weight: .medium))
                        }
                        .foregroundColor(.yellow)
                    }

                    Spacer()

                    if let childCountLabel {
                        Text(childCountLabel)
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
        .modifier(PlexThumbnailFrameModifier(width: fixedWidth, height: defaultCardHeight))
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        PlaybackProgressSnapshot.fromFraction(
            item.playbackProgress,
            played: item.isPlayed
        )
    }

    private var isDownloaded: Bool {
        offlineIndex.isDownloaded(serverId: server.id, remoteItemId: item.id)
    }

    private var childCountLabel: String? {
        switch item.type.lowercased() {
        case "show":
            guard let count = item.childCount, count > 0 else { return nil }
            return count == 1 ? "1 \(NSLocalizedString("Season", comment: "Singular for season count"))" : "\(count) \(NSLocalizedString("Seasons", comment: "Plural for season count"))"
        case "season":
            let count = item.leafCount ?? item.childCount ?? 0
            guard count > 0 else { return nil }
            return count == 1 ? String(format: NSLocalizedString("%d Episode", comment: "Singular for episode count"), 1) : String(format: NSLocalizedString("%d Episodes", comment: "Plural for episode count"), count)
        default:
            return nil
        }
    }
}

private struct PlexThumbnailFrameModifier: ViewModifier {
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

private struct PlexCardWidthModifier: ViewModifier {
    let width: CGFloat?

    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width)
        } else {
            content.frame(maxWidth: .infinity)
        }
    }
}

private struct PlexLibraryCard: View {
    let library: PlexLibrary
    let server: ServerConfig
    let previewItem: PlexItem?
    var itemCount: Int? = nil
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var cardHeight: CGFloat {
        MediaCardMetrics.libraryShelfCardHeight(horizontalSizeClass: horizontalSizeClass)
    }

    private var backgroundImageURL: URL? {
        if let previewItem {
            return previewItem.backdropImageURL(server: server) ?? previewItem.posterImageURL(server: server)
        }
        return library.imageURL(server: server, imagePath: library.art ?? library.thumb)
    }

    private var fallbackGradient: LinearGradient {
        switch library.type.lowercased() {
        case "movie":
            return LinearGradient(
                colors: [Color(red: 0.19, green: 0.24, blue: 0.45), Color(red: 0.09, green: 0.11, blue: 0.24)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "show":
            return LinearGradient(
                colors: [Color(red: 0.20, green: 0.34, blue: 0.30), Color(red: 0.08, green: 0.18, blue: 0.17)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [Color(red: 0.24, green: 0.24, blue: 0.26), Color(red: 0.12, green: 0.12, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
    
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                Group {
                    if let backgroundImageURL {
                        RemoteImage(url: backgroundImageURL)
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
                    ? [Color.black.opacity(0.08), Color.black.opacity(0.46)]
                    : [Color.black.opacity(0.15), Color.black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            
            HStack(spacing: 8) {
                Image(systemName: library.iconName)
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(library.title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    if let count = itemCount ?? library.itemCount, count > 0 {
                        Text(MediaCountFormatter.format(count: count, libraryType: library.libraryType))
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.white.opacity(0.82))
                            .lineLimit(1)
                    }
                }
            }
            .foregroundColor(.white)
            .padding(10)
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
    }
}

enum PlexLibraryTab: String, CaseIterable, Identifiable {
    case items
    case collections
    var id: String { rawValue }
    var localizedTitle: String {
        switch self {
        case .items: return NSLocalizedString("Items", comment: "")
        case .collections: return NSLocalizedString("Collections", comment: "")
        }
    }
}

private struct PlexLibraryDetailView: View {
    let server: ServerConfig
    let library: PlexLibrary
    var onExit: (() -> Void)? = nil
    var onPlay: (PlexItem) -> Void

    @State private var items: [PlexItem] = []
    @State private var currentTab: PlexLibraryTab = .items
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    @State private var currentStartIndex = 0
    @State private var hasMoreItems = true
    @State private var isPaginating = false
    private let pageSize = 120
    @State private var sortBy = PlexLibrarySortOption.dateAdded.rawValue
    @State private var sortOrder = "Descending"
    @State private var displayMode: LibraryDisplayMode = .poster
    @State private var genreChoices: [PlexLibraryFilterChoice] = []
    @State private var yearChoices: [PlexLibraryFilterChoice] = []
    @State private var selectedGenre: String?
    @State private var selectedYear: String?
    @State private var didLoadFilters = false
    @State private var activeRequestID = UUID()
    @State private var isVisible = false
    @State private var needsReload = false
    @State private var nativeSearchText = ""
    @State private var isShowingManualSearch = false
    @State private var searchReloadTask: Task<Void, Never>?
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.presentationMode) private var presentationMode

    private let plexService = PlexService.shared
    #if os(iOS)
    @State private var isSearchOverlayActive = false
    @State private var overlaySearchQuery = ""
    @State private var overlaySearchResults: [PlexItem] = []
    @State private var isOverlaySearching = false
    @State private var overlaySearchTask: Task<Void, Never>? = nil
    #endif

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
                libraryFilters
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if isShowingManualSearch && !supportsNativeSearch {
                            HStack(spacing: 10) {
                                Image(systemName: "magnifyingglass")
                                    .foregroundColor(.secondary)
                                TextField(NSLocalizedString("Search in library...", comment: ""), text: $nativeSearchText)
                                    .disableAutocorrection(true)
                                    .autocapitalization(.none)
                                if !nativeSearchText.isEmpty {
                                    Button(action: clearSearch) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color(UIColor.secondarySystemBackground))
                            .cornerRadius(12)
                            .padding(.horizontal)
                        }

                        if !isLoading {
                            HStack(spacing: 8) {
                                Text(String(format: NSLocalizedString("%d Items", comment: ""), items.count))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                if !nativeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text("•")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(NSLocalizedString("Filtered", comment: ""))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal)
                        }

                        switch displayMode {
                        case .poster:
                            MediaLibraryCardGrid(columns: columns, spacing: gridSpacing, legacyCardWidth: posterCardWidth) { columnWidth in
                                ForEach(items) { item in
                                    NavigationLink(
                                        destination: destinationView(for: item)
                                    ) {
                                        PlexPosterCard(item: item, server: server, cardWidth: columnWidth)
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
                                    NavigationLink(
                                        destination: destinationView(for: item)
                                    ) {
                                        PlexThumbCard(item: item, server: server, cardWidth: nil)
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
                                    NavigationLink(
                                        destination: destinationView(for: item)
                                    ) {
                                        PlexLibraryListRow(item: item, server: server)
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

                        if currentTab == .items && !isLoading && !items.isEmpty {
                            let total = library.itemCount ?? items.count
                            if total > 0 {
                                Text(MediaCountFormatter.formatTotal(count: total, libraryType: library.libraryType))
                                    .font(.footnote)
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 20)
                            }
                        }

                        if !isLoading && items.isEmpty {
                            VStack(spacing: 8) {
                                Image(systemName: nativeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "tray" : "magnifyingglass")
                                    .font(.system(size: 28))
                                    .foregroundColor(.secondary)
                                Text(
                                    nativeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? NSLocalizedString("No items in this library", comment: "")
                                    : NSLocalizedString("No matching Plex items", comment: "")
                                )
                                .font(.headline)
                                Text(NSLocalizedString("Try a different keyword or sort order.", comment: ""))
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 24)
                            .padding(.bottom, 24)
                        }
                    }
                    .padding(.vertical)
                }
                .allowsHitTesting(!isLoading)
                .refreshableCompat {
                    await loadItems()
                }
            }

            if isLoading {
                ProgressView()
                    .scaleEffect(1.2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

        }
        .navigationTitle(currentTab == .items ? library.title : currentTab.localizedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .libraryChildNavigationBarCompat()
        #if os(iOS)
        .modifier(inlineSearch)
        .onChange(of: overlaySearchQuery) { newQuery in
            scheduleOverlaySearch(for: newQuery)
        }
        .onDisappear {
            overlaySearchTask?.cancel()
            searchReloadTask?.cancel()
        }
        #endif
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
                Button(action: toggleManualSearch) {
                    AppToolbarIcon(systemName: "magnifyingglass")
                }
                #endif

                Menu {
                    Section {
                        ForEach(LibraryDisplayMode.allCases) { mode in
                            Button(action: { setDisplayMode(mode) }) {
                                sortMenuRow(title: mode.localizedTitle, isSelected: displayMode == mode)
                            }
                        }
                    }
                    Section(header: Text(NSLocalizedString("Browse", comment: ""))) {
                        Button(action: { currentTab = .items }) {
                            sortMenuRow(title: library.title, isSelected: currentTab == .items)
                        }
                        Button(action: { currentTab = .collections }) {
                            sortMenuRow(title: PlexLibraryTab.collections.localizedTitle, isSelected: currentTab == .collections)
                        }
                    }
                } label: {
                    AppToolbarIcon(systemName: displayMode.iconName)
                }

                Menu {
                    Section(header: Text(NSLocalizedString("Sort By", comment: ""))) {
                        ForEach(PlexLibrarySortOption.allCases, id: \.rawValue) { option in
                            Button(action: {
                                updateSortField(option.rawValue)
                            }) {
                                sortMenuRow(title: option.localizedTitle, isSelected: sortBy == option.rawValue)
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
            isVisible = true
            if !didLoadFilters { Task { await loadFilterOptions() } }
            loadSavedSortPreference()
            loadSavedDisplayMode()
            if items.isEmpty || needsReload {
                Task { await loadItems() }
            }
        }
        .onDisappear {
            isVisible = false
            activeRequestID = UUID()
            isLoading = false
            isPaginating = false
            searchReloadTask?.cancel()
        }
        .onChange(of: nativeSearchText) { _ in
            scheduleSearchReload()
        }
        .onChange(of: currentTab) { _ in
            Task { await loadItems() }
        }
    }

    private var selectedGenreValue: String? {
        genreChoices.first(where: { $0.title == selectedGenre })?.value
    }

    private var selectedYearValue: String? {
        yearChoices.first(where: { $0.title == selectedYear })?.value
    }

    @ViewBuilder
    private var libraryFilters: some View {
        if currentTab == .items && (!genreChoices.isEmpty || !yearChoices.isEmpty) {
            LibraryFilterBar(
                availableGenres: genreChoices.map(\.title),
                availableYears: yearChoices.map(\.title),
                selectedGenre: Binding(get: { selectedGenre }, set: { value in
                    guard value != selectedGenre else { return }
                    selectedGenre = value
                    Task { await loadItems() }
                }),
                selectedYear: Binding(get: { selectedYear }, set: { value in
                    guard value != selectedYear else { return }
                    selectedYear = value
                    Task { await loadItems() }
                })
            )
            .background(Color(UIColor.systemBackground))
            Divider()
        }
    }

    @MainActor
    private func loadFilterOptions() async {
        async let genres = try? plexService.getLibraryFilterChoices(server: server, library: library, field: .genre)
        async let years = try? plexService.getLibraryFilterChoices(server: server, library: library, field: .year)
        let (loadedGenres, loadedYears) = await (genres, years)
        genreChoices = loadedGenres ?? []
        yearChoices = loadedYears ?? []
        didLoadFilters = loadedGenres != nil && loadedYears != nil
    }

    private var supportsNativeSearch: Bool {
        if #available(iOS 15.0, *) {
            return true
        }
        return false
    }

    @ViewBuilder
    private func destinationView(for item: PlexItem) -> some View {
        if item.type == "collection" {
            PlexCollectionDetailView(server: server, collection: item, onExit: onExit, onPlay: onPlay)
        } else {
            PlexItemDetailView(server: server, item: item, onExit: nil, onPlay: onPlay)
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
        if newSortBy == "title" && sortOrder != "Ascending" {
            sortOrder = "Ascending"
        }
        if newSortBy != "title" && sortOrder != "Descending" {
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
            provider: "plex",
            serverId: server.id.uuidString,
            libraryId: library.id,
            sortBy: sortBy,
            sortOrder: sortOrder
        )
        Task { await loadItems() }
    }

    private func loadSavedSortPreference() {
        let saved = settings.librarySortPreference(
            provider: "plex",
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
            provider: "plex",
            serverId: server.id.uuidString,
            libraryId: library.id,
            defaultMode: .poster
        )
    }

    private func setDisplayMode(_ mode: LibraryDisplayMode) {
        displayMode = mode
        settings.saveLibraryDisplayMode(
            provider: "plex",
            serverId: server.id.uuidString,
            libraryId: library.id,
            mode: mode
        )
    }

    private func toggleManualSearch() {
        isShowingManualSearch.toggle()
        if !isShowingManualSearch {
            clearSearch()
        }
    }

    private func clearSearch() {
        nativeSearchText = ""
        Task { await loadItems() }
    }

    private func scheduleSearchReload() {
        searchReloadTask?.cancel()
        searchReloadTask = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await loadItems()
        }
    }

    @MainActor
    private func loadItems(isPagination: Bool = false) async {
        guard isVisible else { return }
        if isPagination {
            guard !isLoading, !isPaginating, hasMoreItems else { return }
            isPaginating = true
        } else {
            isLoading = true
            isPaginating = false
            errorMessage = nil
            needsReload = true
            currentStartIndex = 0
            hasMoreItems = true
        }
        let requestID = UUID()
        activeRequestID = requestID
        let requestedTab = currentTab
        let requestedStart = currentStartIndex
        let requestedQuery = nativeSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let genre = requestedTab == .items ? selectedGenreValue : nil
        let year = requestedTab == .items ? selectedYearValue : nil
        let requestedSortBy = sortBy
        let requestedSortOrder = sortOrder

        do {
            let responseItems: [PlexItem]
            let pageCount: Int
            switch requestedTab {
            case .items:
                responseItems = try await plexService.getLibraryItems(
                    server: server, library: library,
                    sortBy: requestedSortBy, sortOrder: requestedSortOrder,
                    searchQuery: requestedQuery, genre: genre, year: year,
                    startIndex: requestedStart, limit: pageSize
                )
                // The existing unfiltered search endpoint returns one bounded
                // result set, not offset-based pages.
                pageCount = !requestedQuery.isEmpty && genre == nil && year == nil ? 0 : responseItems.count
            case .collections:
                let collections = try await plexService.getLibraryCollections(
                    server: server, libraryId: library.id,
                    startIndex: requestedStart, limit: pageSize
                )
                pageCount = collections.count
                responseItems = requestedQuery.isEmpty ? collections : collections.filter {
                    $0.title.localizedCaseInsensitiveContains(requestedQuery)
                }
            }
            guard isVisible, activeRequestID == requestID else { return }
            if Task.isCancelled {
                isLoading = false
                isPaginating = false
                return
            }
            needsReload = false
            items = (isPagination ? items + responseItems : responseItems).stableUniqued()
            hasMoreItems = pageCount >= pageSize
            currentStartIndex = requestedStart + pageSize
            isLoading = false
            isPaginating = false
        } catch {
            guard isVisible, activeRequestID == requestID else { return }
            isLoading = false
            isPaginating = false
            if !isCancellation(error) { errorMessage = error.localizedDescription }
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
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
            plexSearchOverlayResults
        }
    }

    @ViewBuilder
    private var plexSearchOverlayResults: some View {
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
                                        destinationView(for: item)
                                    }) {
                                        PlexPosterCard(item: item, server: server, cardWidth: posterCardWidth)
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
                                    destinationView(for: item)
                                }) {
                                    PlexLibraryListRow(item: item, server: server)
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
                let results: [PlexItem]
                if currentTab == .items, selectedGenreValue != nil || selectedYearValue != nil {
                    results = try await plexService.getLibraryItems(
                        server: server, library: library, sortBy: sortBy, sortOrder: sortOrder,
                        searchQuery: query, genre: selectedGenreValue, year: selectedYearValue, limit: 50
                    )
                } else {
                    let grouped = try await plexService.searchLibraries(
                        server: server, libraries: [library], query: query, limitPerLibrary: 50
                    )
                    results = grouped[library.id] ?? []
                }
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
    #endif
}

private struct PlexLibraryListRow: View {
    let item: PlexItem
    let server: ServerConfig

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: item.posterImageURL(server: server))
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

                if let subtitle = item.metadataLine {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    if let rating = item.rating, rating > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", rating))
                        }
                    }

                    if let runtime = item.durationSeconds {
                        Text(PlexUIHelpers.runtimeText(seconds: runtime))
                    }

                    if let size = item.mediaSize {
                        Text(PlexUIHelpers.formatBytes(size))
                    }

                    if let contentRating = item.contentRating, !contentRating.isEmpty {
                        Text(contentRating)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(Color.secondary.opacity(0.45), lineWidth: 0.6)
                            )
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)

                if let progress = item.playbackProgress, progress > 0 {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(value: progress)
                            .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                        Text(
                            String(
                                format: NSLocalizedString("%d%% watched", comment: ""),
                                Int(progress * 100)
                            )
                        )
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            if item.isContainer {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(PlexMediaContextMenuModifier(item: item, server: server))
    }
}

private struct PlexCollectionDetailView: View {
    let server: ServerConfig
    let collection: PlexItem
    var onExit: (() -> Void)? = nil
    var onPlay: (PlexItem) -> Void
    
    @State private var items: [PlexItem] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    
    @State private var currentStartIndex = 0
    @State private var hasMoreItems = true
    @State private var isPaginating = false
    private let pageSize = 120
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject private var settings = AppSettings.shared
    
    private var columns: [GridItem] { MediaCardMetrics.libraryPosterColumns(horizontalSizeClass: horizontalSizeClass) }
    private var gridSpacing: CGFloat { MediaCardMetrics.libraryGridSpacing(horizontalSizeClass: horizontalSizeClass) }
    private var gridPadding: CGFloat { MediaCardMetrics.libraryGridPadding(horizontalSizeClass: horizontalSizeClass) }
    private var posterCardWidth: CGFloat { MediaCardMetrics.libraryPosterWidth(horizontalSizeClass: horizontalSizeClass) }

    var body: some View {
        ZStack {
            ScrollView {
                MediaLibraryCardGrid(columns: columns, spacing: gridSpacing, legacyCardWidth: posterCardWidth) { columnWidth in
                    ForEach(items) { item in
                        NavigationLink(destination: PlexItemDetailView(server: server, item: item, onExit: nil, onPlay: onPlay)) {
                            PlexPosterCard(item: item, server: server, cardWidth: columnWidth)
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
            }
            .refreshableCompat {
                await loadItems()
            }
            if isLoading { ProgressView() }
        }
        .navigationTitle(collection.title)
        .navigationBarTitleDisplayMode(.inline)
        .libraryChildNavigationBarCompat()
        .customBackButton()
        .mediaLibraryNavigationToolbar {
            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                AppToolbarIcon(systemName: "chevron.left")
            }
        } home: {
            Button(action: { NavigationUtil.popToRootView() }) {
                AppToolbarIcon(systemName: "house")
            }
        }
        .appErrorAlert(
            message: $errorMessage,
            title: NSLocalizedString("Couldn't load collection", comment: ""),
            retryTitle: NSLocalizedString("Retry", comment: ""),
            retryAction: { Task { await loadItems() } }
        )
        .onAppear {
            if items.isEmpty { Task { await loadItems() } }
        }
    }
    
    private func loadItems(isPagination: Bool = false) async {
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
            let loaded = try await PlexService.shared.getCollectionItems(
                server: server,
                collectionId: collection.id,
                startIndex: currentStartIndex,
                limit: pageSize
            )
            await MainActor.run {
                if isPagination {
                    items.append(contentsOf: loaded)
                } else {
                    items = loaded
                }
                
                hasMoreItems = loaded.count >= pageSize
                
                if isPagination {
                    currentStartIndex += pageSize
                    isPaginating = false
                } else {
                    currentStartIndex = pageSize
                    isLoading = false
                }
            }
        } catch {
            if isCancellation(error) {
                await MainActor.run {
                    if isPagination { isPaginating = false }
                    else { isLoading = false }
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
    
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

struct PlexItemDetailView: View {
    let server: ServerConfig
    let item: PlexItem
    var onExit: (() -> Void)? = nil
    var onPlay: (PlexItem) -> Void
    var initialSeasonId: String? = nil
    var initialEpisodeId: String? = nil
    @Environment(\.presentationMode) private var presentationMode
    @ObservedObject private var settings = AppSettings.shared

    @State private var showingDeleteAlert = false
    @State private var itemToDelete: PlexItem? = nil
    @State private var isDeleting = false

    @State private var resolvedItem: PlexItem
    @State private var seasons: [PlexItem] = []
    @State private var episodes: [PlexItem] = []
    @State private var relatedItems: [PlexItem] = []
    @State private var selectedSeasonId: String?
    @State private var pendingEpisodeId: String?
    @State private var isLoading = false
    @State private var isLoadingEpisodes = false
    @State private var errorMessage: String?
    @State private var playerFile: VideoFile?
    @State private var playerPlaylist: [VideoFile]?
    @State private var isPlayed = false
    @State private var isUpdatingPlayedState = false
    @State private var isFavorite = false
    @State private var isWatchlisted = false
    @State private var isUpdatingWatchlist = false
    @State private var watchlistTargetGUID: String? = nil
    @State private var showPrePlaybackOptions = false
    @State private var isLoadingPrePlaybackOptions = false
    @State private var prePlaybackTargetItem: PlexItem? = nil
    @State private var prePlaybackQualityOptions: [PrePlaybackTrackOption] = []
    @State private var prePlaybackAudioOptions: [PrePlaybackTrackOption] = []
    @State private var prePlaybackSubtitleOptions: [PrePlaybackTrackOption] = []
    @State private var selectedPrePlaybackQualityID: String? = AppSettings.shared.defaultRemotePlaybackQualityOption.id
    @State private var selectedPrePlaybackAudioID: String? = nil
    @State private var selectedPrePlaybackSubtitleID: String? = nil
    @State private var canShowPrePlaybackOptions = false
    @State private var offlineState: DownloadAggregateState = .notDownloaded
    @State private var pendingDownloadItem: PlexItem?
    @State private var pendingSeasonDownloadItems: [PlexItem] = []
    @State private var pendingSeasonDownloadTitle: String?
    @State private var isShowingDownloadConfirmSheet = false
    @State private var isShowingDownloadCenter = false
    @State private var downloadToastMessage: String? = nil
    @StateObject private var backdropReadability = AdaptiveBackdropReadabilityModel()
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var favoriteService = FavoriteService.shared

    private let plexService = PlexService.shared

    private var streamPlaybackURL: URL? {
        guard resolvedItem.isPlayable else { return nil }
        return plexService.resolvePlaybackURL(server: server, item: resolvedItem, playbackQuality: .auto)
            ?? plexService.getStreamURL(server: server, item: resolvedItem)
    }

    init(
        server: ServerConfig,
        item: PlexItem,
        onExit: (() -> Void)? = nil,
        onPlay: @escaping (PlexItem) -> Void,
        initialSeasonId: String? = nil,
        initialEpisodeId: String? = nil
    ) {
        self.server = server
        self.item = item
        self.onExit = onExit
        self.onPlay = onPlay
        self.initialSeasonId = initialSeasonId
        self.initialEpisodeId = initialEpisodeId
        _resolvedItem = State(initialValue: item)
        _pendingEpisodeId = State(initialValue: initialEpisodeId)
    }

    private var detailToolbarColor: Color? {
        #if os(iOS)
        if #available(iOS 16.0, *) { return .white }
        #endif
        return nil
    }

    private var playbackTargetItem: PlexItem? {
        if resolvedItem.isPlayable {
            return resolvedItem
        }
        return episodes.first(where: { $0.isPlayable }) ?? episodes.first
    }

    private var backgroundImageUrl: URL? {
        resolvedItem.backdropImageURL(server: server)
    }

    @ViewBuilder
    private var backdropBaseLayer: some View {
        if let bgUrl = backgroundImageUrl {
            RemoteImage(url: bgUrl, onImageLoaded: { image in
                    backdropReadability.update(from: image)
                })
                .scaleEffect(1.15, anchor: .top)
                .aspectRatio(contentMode: .fill)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea()
                .blur(radius: 38)
                .overlay(Color.black.opacity(backdropReadability.style.baseOverlayOpacity))
        } else {
            Color.black
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func backdropHeaderLayer(in geometry: GeometryProxy) -> some View {
        if let headerUrl = backgroundImageUrl {
            VStack(spacing: 0) {
                RemoteImage(url: headerUrl)
                    .scaleEffect(1.12, anchor: .top)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height * 0.4, alignment: .top)
                    .clipped()
                    .overlay(headerBackdropGradient)
                    .mask(
                        LinearGradient(
                            colors: [.black, .black, .black, .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                Spacer()
            }
            .ignoresSafeArea()
        }
    }

    private var headerBackdropGradient: LinearGradient {
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
    }

    private var downloadTargetItem: PlexItem? {
        resolvedItem.isPlayable ? resolvedItem : nil
    }

    private var currentOfflineRemotePaths: [String] {
        if let path = downloadPath {
            return [path]
        }
        return episodes.compactMap { plexService.getDownloadPath(item: $0) }
    }

    private var selectedSeasonEpisodes: [PlexItem] {
        episodes.filter(\.isPlayable)
    }

    private var selectedSeasonDownloadState: DownloadAggregateState {
        downloadCenter.aggregateStateForRemotePaths(
            serverId: server.id,
            remotePaths: selectedSeasonEpisodes.compactMap { plexService.getDownloadPath(item: $0) }
        )
    }

    private var currentSeasonTitle: String {
        if resolvedItem.type.lowercased() == "show",
           let selectedSeason = seasons.first(where: { $0.id == selectedSeasonId }) {
            return "\(resolvedItem.displayTitle) - \(selectedSeason.title)"
        }
        return resolvedItem.displayTitle
    }

    private var seasonDownloadCandidates: [PlexItem] {
        selectedSeasonEpisodes.filter { episode in
            canQueueEpisodeDownload(episode)
        }
    }

    private var canShowSeasonDownloadButton: Bool {
        (resolvedItem.type.lowercased() == "show" || resolvedItem.type.lowercased() == "season") && !selectedSeasonEpisodes.isEmpty
    }

    private var canQueueSelectedSeasonDownload: Bool {
        !seasonDownloadCandidates.isEmpty
    }

    private var downloadPath: String? {
        guard let target = downloadTargetItem else { return nil }
        return plexService.getDownloadPath(item: target)
    }

    private var downloadTaskStatus: DownloadTaskStatus? {
        guard let path = downloadPath else { return nil }
        return downloadCenter.taskStatus(serverId: server.id, remotePath: path)
    }

    private var canQueueCurrentItemDownload: Bool {
        guard downloadPath != nil else { return false }
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

    private var downloadButtonIcon: String {
        switch downloadTaskStatus {
        case .completed, .downloading, .queued, .paused:
            return "arrow.down.circle.fill"
        default:
            return "arrow.down.circle"
        }
    }

    private var downloadButtonColor: Color {
        switch downloadTaskStatus {
        case .completed:
            return .green
        case .downloading, .queued, .paused:
            return Color(UIColor.systemBlue)
        default:
            return .white
        }
    }

    private var favoriteIdentityPath: String? {
        guard let favoriteItemId else { return nil }
        return "__plex_item__/\(favoriteItemId)"
    }

    private var favoritePlayableFile: VideoFile? {
        if resolvedItem.type.lowercased() == "show" {
            let identityURL = resolvedItem.posterImageURL(server: server)
                ?? URL(string: "\(server.fullURL)/library/metadata/\(resolvedItem.id)")
            guard let identityURL else { return nil }
            return VideoFile(
                name: resolvedItem.displayTitle,
                url: identityURL,
                type: .video,
                size: 0,
                date: Date(),
                isRemote: true,
                jellyfinItemId: resolvedItem.id,
                jellyfinServerId: server.id.uuidString,
                serverType: .plex
            )
        }

        guard let target = downloadTargetItem else { return nil }
        return plexService.buildPlayableVideoFile(server: server, item: target)
    }

    private var favoriteItemId: String? {
        if resolvedItem.type.lowercased() == "show" {
            return resolvedItem.id
        }
        return favoritePlayableFile?.jellyfinItemId
    }

    private var watchlistTargetMetadataId: String? {
        switch resolvedItem.type.lowercased() {
        case "movie", "show":
            return resolvedItem.id
        case "season":
            return resolvedItem.parentRatingKey
        case "episode":
            return resolvedItem.grandparentRatingKey ?? resolvedItem.parentRatingKey
        default:
            return nil
        }
    }

    private var canShowWatchlistButton: Bool {
        watchlistTargetMetadataId != nil
    }

    private func playbackResumeDecision(for target: PlexItem) -> RemotePlaybackResumeDecision {
        RemotePlaybackResumeDecision.fromPlaybackPosition(
            positionSeconds: target.playbackPositionSeconds,
            progressFraction: target.playbackProgress,
            played: target.id == resolvedItem.id ? isPlayed : target.isPlayed
        )
    }

    private var playButtonTitle: String {
        guard let target = playbackTargetItem else {
            return NSLocalizedString("Play", comment: "")
        }
        let decision = playbackResumeDecision(for: target)
        if decision.shouldContinuePlayback {
            return NSLocalizedString("Continue Play", comment: "")
        }
        return NSLocalizedString("Start Play", comment: "")
    }

    private var playButtonProgressInfo: PlaybackCTAProgress? {
        guard let target = playbackTargetItem else { return nil }
        let decision = playbackResumeDecision(for: target)
        guard decision.shouldContinuePlayback else { return nil }

        let playedSeconds = Int(target.playbackPositionSeconds)
        guard playedSeconds > 0 else { return nil }

        guard let totalDuration = target.durationSeconds, totalDuration > 0 else { return nil }
        let totalSeconds = Int(totalDuration)
        guard totalSeconds > 0 else { return nil }

        let calculatedFraction = min(max(Double(playedSeconds) / Double(totalSeconds), 0), 1)
        let safePercent = min(max(Int((calculatedFraction * 100).rounded()), 0), 100)

        return PlaybackCTAProgress(
            playedText: formatClock(playedSeconds),
            totalText: formatClock(totalSeconds),
            percentText: "\(safePercent)%",
            fraction: Double(safePercent) / 100.0
        )
    }

    private var immediatePlaybackQualityID: String {
        AppSettings.shared.resolvedRemotePlaybackQualityID(for: selectedPrePlaybackQualityID)
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

    private var detailTopInset: CGFloat {
        let fallbackInset: CGFloat = UIDevice.current.userInterfaceIdiom == .pad ? 24 : 47
        return max(UIApplication.currentSafeAreaInsets().top, fallbackInset)
    }

    @ViewBuilder
    private var detailHeaderSection: some View {
        RemoteImage(url: resolvedItem.posterImageURL(server: server))
            .aspectRatio(2 / 3, contentMode: .fill)
            .frame(width: 170, height: 255)
            .cornerRadius(14)
            .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 6)

        VStack(alignment: .center, spacing: 10) {
            Text(resolvedItem.displayTitle)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let subtitle = resolvedItem.secondaryTitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.72))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            offlineAvailabilityBadge
            detailMetadataSection
            detailInfoBoxSection
            detailPlaybackSection
        }
    }

    private var offlineAvailabilityBadge: some View {
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
    }

    @ViewBuilder
    private var detailMetadataSection: some View {
        if hasDetailMetadata {
            HStack(spacing: 8) {
                if let year = resolvedItem.year {
                    Text(String(year))
                }

                if let duration = resolvedItem.durationSeconds {
                    Text(PlexUIHelpers.runtimeText(seconds: duration))
                }

                if let rating = resolvedItem.rating, rating > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                        Text(String(format: "%.1f", rating))
                    }
                }

                if resolvedItem.type.lowercased() == "show", let leafCount = resolvedItem.leafCount {
                    Text(String(format: NSLocalizedString("%d Episodes", comment: ""), leafCount))
                }

                if let resolution = resolutionBadgeText {
                    Text(resolution)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.white.opacity(0.2))
                        .cornerRadius(3)
                }

                if let size = resolvedItem.mediaSize {
                    Text(PlexUIHelpers.formatBytes(size))
                }

                if let contentRating = resolvedItem.contentRating, !contentRating.isEmpty {
                    Text(contentRating)
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .border(Color.white.opacity(0.5), width: 0.5)
                }

                if let container = resolvedItem.mediaContainer, !container.isEmpty {
                    Text(container.uppercased())
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .border(Color.white.opacity(0.5), width: 0.5)
                }
            }
            .font(.system(size: 13))
            .foregroundColor(.white.opacity(0.84))
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 20)
        }
        let technicalParts = MediaTechnicalMetadata.parts(video: resolvedItem.mediaStreams.first(where: { $0.streamType == 1 })?.technicalMetadata ?? [:])
        if !technicalParts.isEmpty {
            Text(technicalParts.joined(separator: " · "))
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
        }
    }

    @ViewBuilder
    private var detailInfoBoxSection: some View {
        if hasInfoBoxContent {
            MetadataInfoView(
                providerIds: resolvedItem.providerIds.isEmpty ? nil : resolvedItem.providerIds,
                genres: resolvedItem.genres.isEmpty ? nil : resolvedItem.genres,
                people: resolvedItem.people.isEmpty ? nil : resolvedItem.people
            )
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private var detailPlaybackSection: some View {
        if playbackTargetItem != nil {
            PrimaryPlaybackCTAButton(
                title: playButtonTitle,
                progress: playButtonProgressInfo,
                action: {
                    playPrimaryItem()
                }
            )
            .mediaDetailPlaybackButtonFrame()

            MediaDetailActionGrid(alignment: .center) {
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
                    .disabled(isLoadingPrePlaybackOptions)
                    .buttonStyle(ScaleIconButtonStyle())
                }

                Button(action: { replayFromStart() }) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 20))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ScaleIconButtonStyle())

                if resolvedItem.isPlayable {
                    Button(action: { Task { await togglePlayed() } }) {
                        Image(systemName: isPlayed ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 20))
                            .foregroundColor(isPlayed ? .green : .white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(isUpdatingPlayedState)
                    .buttonStyle(ScaleIconButtonStyle())
                }

                if downloadPath != nil {
                    Button(action: {
                        requestCurrentItemDownload()
                    }) {
                        Image(systemName: downloadButtonIcon)
                            .font(.system(size: 20))
                            .foregroundColor(downloadButtonColor)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ScaleIconButtonStyle())
                }

                if canShowWatchlistButton {
                    Button(action: { Task { await toggleWatchlist() } }) {
                        Image(systemName: isWatchlisted ? "heart.fill" : "heart")
                            .font(.system(size: 20))
                            .foregroundColor(isWatchlisted ? .red : .white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .disabled(isUpdatingWatchlist)
                    .buttonStyle(ScaleIconButtonStyle())
                }

                if favoritePlayableFile != nil {
                    Button(action: { toggleFavorite() }) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 20))
                            .foregroundColor(isFavorite ? .yellow : .white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ScaleIconButtonStyle())
                }

                if settings.allowMediaServerDeletion {
                    Button(action: {
                        itemToDelete = resolvedItem
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
            .foregroundColor(.white.opacity(0.9))
        }
    }

    @ViewBuilder
    private var detailSummarySection: some View {
        if let summary = resolvedItem.summary, !summary.isEmpty {
            Text(summary)
                .font(.body)
                .foregroundColor(.white.opacity(0.86))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private var seasonsSection: some View {
        if resolvedItem.type.lowercased() == "show", !seasons.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                MediaSectionHeaderLabel(
                    title: NSLocalizedString("Seasons", comment: ""),
                    systemImage: "square.stack.fill",
                    foregroundColor: .white,
                    font: .title3,
                    weight: .bold
                )
                .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(seasons) { season in
                            Button(action: {
                                selectedSeasonId = season.id
                                Task { await loadEpisodes(for: season.id) }
                            }) {
                                Text(season.title)
                                    .font(.system(size: 16, weight: selectedSeasonId == season.id ? .bold : .medium))
                                    .foregroundColor(selectedSeasonId == season.id ? .white : .white.opacity(0.72))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(
                                        Capsule()
                                            .fill(selectedSeasonId == season.id ? Color.accentColor : Color.white.opacity(0.1))
                                    )
                            }
                            .buttonStyle(PlainButtonStyle())
                            .contextMenu {
                                if settings.allowMediaServerDeletion {
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
            }
        }
    }

    @ViewBuilder
    private var episodesLoadingSection: some View {
        if isLoadingEpisodes {
            ProgressView()
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var episodesSection: some View {
        if !episodes.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    MediaSectionHeaderLabel(
                        title: resolvedItem.type.lowercased() == "season"
                            ? NSLocalizedString("Episodes", comment: "")
                            : NSLocalizedString("Season Episodes", comment: ""),
                        systemImage: "film.fill",
                        foregroundColor: .white,
                        font: .title3,
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

                ScrollViewReader { proxy in
                    LazyVStack(spacing: 16) {
                        ForEach(episodes) { episode in
                            HStack(spacing: 12) {
                                NavigationLink(
                                    destination: PlexItemDetailView(
                                        server: server,
                                        item: episode,
                                        onExit: nil,
                                        onPlay: onPlay
                                    )
                                ) {
                                    PlexEpisodeRow(item: episode, server: server)
                                }
                                .buttonStyle(PlainButtonStyle())

                                Button(action: {
                                    requestEpisodeDownload(episode)
                                }) {
                                    Image(systemName: episodeDownloadIcon(for: episode))
                                        .font(.title2)
                                        .foregroundColor(episodeDownloadColor(for: episode))
                                        .frame(width: 36, height: 36)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(!canQueueEpisodeDownload(episode))
                            }
                            .id(episode.id)
                            .contextMenu {
                                Button(action: {
                                    onPlay(episode)
                                }) {
                                    Label(NSLocalizedString("Play", comment: ""), systemImage: "play.fill")
                                }
                                Button(action: {
                                    Task { await toggleEpisodePlayed(episode) }
                                }) {
                                    Label(
                                        episode.isPlayed ? NSLocalizedString("Mark as Unplayed", comment: "") : NSLocalizedString("Mark as Played", comment: ""),
                                        systemImage: episode.isPlayed ? "xmark.circle" : "checkmark.circle"
                                    )
                                }
                                if canQueueEpisodeDownload(episode) {
                                    Button(action: {
                                        requestEpisodeDownload(episode)
                                    }) {
                                        Label(NSLocalizedString("Download", comment: ""), systemImage: "arrow.down.circle")
                                    }
                                }
                                if settings.allowMediaServerDeletion {
                                    if #available(iOS 15.0, *) {
                                        Button(role: .destructive, action: {
                                            itemToDelete = episode
                                            showingDeleteAlert = true
                                        }) {
                                            Label(NSLocalizedString("Delete from Server", comment: ""), systemImage: "trash")
                                        }
                                    } else {
                                        Button(action: {
                                            itemToDelete = episode
                                            showingDeleteAlert = true
                                        }) {
                                            Label(NSLocalizedString("Delete from Server", comment: ""), systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .onAppear {
                        scrollToPendingEpisode(using: proxy)
                    }
                    .onChange(of: episodes.map(\.id)) { _ in
                        scrollToPendingEpisode(using: proxy)
                    }
                }
                .padding(.horizontal)
            }
        } else if !isLoadingEpisodes && (resolvedItem.type.lowercased() == "show" || resolvedItem.type.lowercased() == "season") {
            emptySeasonCard(onDelete: {
                if let currentSeason = seasons.first(where: { $0.id == selectedSeasonId }) ?? (resolvedItem.type.lowercased() == "season" ? resolvedItem : nil) {
                    itemToDelete = currentSeason
                    showingDeleteAlert = true
                }
            })
        }
    }

    @ViewBuilder
    private var castSection: some View {
        if !resolvedItem.people.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("Cast & Crew", comment: ""))
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(Array(resolvedItem.people.prefix(24))) { person in
                            NavigationLink(
                                destination: PlexPersonDetailView(
                                    server: server,
                                    person: person,
                                    onPlay: onPlay
                                )
                            ) {
                                PlexPersonCard(person: person, server: server)
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

    @ViewBuilder
    private var relatedItemsSection: some View {
        if !relatedItems.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("More Like This", comment: ""))
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding(.horizontal)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(relatedItems) { related in
                            NavigationLink(
                                destination: PlexItemDetailView(
                                    server: server,
                                    item: related,
                                    onExit: nil,
                                    onPlay: onPlay
                                )
                            ) {
                                PlexRelatedPosterCard(item: related, server: server)
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
    }

    @ViewBuilder
    private var detailErrorSection: some View {
        if let errorMessage {
            Text(errorMessage)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private var mediaInfoSection: some View {
        let filePath = resolvedItem.mediaFilePath
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
            .padding(.top, 16)
        }
    }

    private func detailScrollView() -> some View {
        ScrollView {
            VStack(alignment: .center, spacing: 24) {
                Spacer().frame(height: detailTopInset + 10)
                detailHeaderSection
                detailSummarySection
                seasonsSection
                episodesLoadingSection
                episodesSection
                castSection
                relatedItemsSection
                mediaInfoSection
                detailErrorSection
            }
            .mediaDetailHorizontalSafeAreaPadding()
            .padding(.bottom, 32)
        }
        .refreshableCompat {
            await loadDetail()
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                backdropBaseLayer
                backdropHeaderLayer(in: geometry)
                detailScrollView()
            }
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .navigationTitle(resolvedItem.title)
        .navigationBarTitleDisplayMode(.inline)
        .libraryChildNavigationBarCompat()
        #if os(iOS)
        .hideNavigationBarBackground()
        .modifier(PlexDetailNavigationBarModifier())
        #endif
        .mediaLibraryNavigationToolbar {
            #if os(iOS)
            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                AppToolbarIcon(systemName: "chevron.left", legacyForegroundColor: .white)
            }
            #endif
        } home: {
            Button(action: { NavigationUtil.popToRootView() }) {
                AppToolbarIcon(systemName: "house", legacyForegroundColor: detailToolbarColor)
            }
        }
        .toolbar {
            #if os(iOS)
            ToolbarItem(placement: .principal) {
                Text(resolvedItem.title)
                    .font(.headline)
                    .foregroundColor(detailToolbarColor ?? Color(UIColor.label))
                    .lineLimit(1)
            }
            #endif
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                
                    Button(action: {
                        isShowingDownloadCenter = true
                    }) {
                        AppToolbarIcon(
                            systemName: "arrow.down.circle",
                            badgeCount: downloadCenter.activeJobs.count,
                            legacyForegroundColor: detailToolbarColor
                        )
                    }
                
            }
        }
        .fullScreenCover(item: $playerFile, onDismiss: {
            UIApplication.refreshInterfaceChrome()
            Task { await loadDetail() }
        }) { file in
            PlayerView(initialFile: file, playlist: $playerPlaylist)
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
        .floatingToast(message: $downloadToastMessage)
        .alert(isPresented: $showingDeleteAlert) {
            Alert(
                title: Text(NSLocalizedString("Delete from Server", comment: "")),
                message: Text(String(format: NSLocalizedString("Are you sure you want to delete \"%@\" from the server? This cannot be undone.", comment: ""), (itemToDelete ?? resolvedItem).displayTitle)),
                primaryButton: .destructive(Text(NSLocalizedString("Delete", comment: ""))) {
                    let target = itemToDelete ?? resolvedItem
                    Task { await deleteItem(target) }
                },
                secondaryButton: .cancel()
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .remotePlaybackStateDidChange)) { notification in
            guard let payload = notification.object as? PlaybackStateRefreshPayload else {
                return
            }
            handleRemotePlaybackRefresh(payload)
        }
        .onChange(of: downloadCenter.tasks.count) { _ in
            refreshOfflineAvailability()
        }
        .onChange(of: resolvedItem.id) { _ in
            isPlayed = resolvedItem.isPlayed
            refreshFavoriteState()
            Task { await refreshWatchlistState() }
            Task { await refreshPrePlaybackOptionAvailability() }
            refreshOfflineAvailability()
        }
        .onChange(of: episodes.map(\.id)) { _ in
            if resolvedItem.type.lowercased() != "show" {
                return
            }
            Task { await refreshPrePlaybackOptionAvailability() }
            refreshOfflineAvailability()
        }
        .onAppear {
            if backgroundImageUrl == nil {
                backdropReadability.reset()
            }
            isPlayed = resolvedItem.isPlayed
            refreshFavoriteState()
            pendingEpisodeId = initialEpisodeId
            Task { await refreshWatchlistState() }
            if resolvedItem.id == item.id && seasons.isEmpty && episodes.isEmpty && !isLoading {
                Task { await loadDetail() }
            }
            Task { await refreshPrePlaybackOptionAvailability() }
            refreshOfflineAvailability()
        }
        .onChange(of: backgroundImageUrl) { newValue in
            if newValue == nil {
                backdropReadability.reset()
            }
        }
    }

    private var hasDetailMetadata: Bool {
        resolvedItem.year != nil ||
        resolvedItem.durationSeconds != nil ||
        ((resolvedItem.rating ?? 0) > 0) ||
        (resolvedItem.type.lowercased() == "show" && resolvedItem.leafCount != nil) ||
        resolutionBadgeText != nil ||
        resolvedItem.mediaSize != nil ||
        (resolvedItem.contentRating?.isEmpty == false) ||
        (resolvedItem.mediaContainer?.isEmpty == false)
    }

    private var hasInfoBoxContent: Bool {
        !resolvedItem.providerIds.isEmpty || !resolvedItem.genres.isEmpty
    }

    private var resolutionBadgeText: String? {
        let lower = resolvedItem.mediaStreams.first(where: { $0.isAudio == false && $0.isSubtitle == false })?.displayTitle?.lowercased()
        if let lower, lower.contains("4k") {
            return "4K"
        }
        if let lower, lower.contains("1080") {
            return "1080P"
        }
        if let lower, lower.contains("720") {
            return "720P"
        }
        if let widthHint = resolvedItem.summary?.lowercased(), widthHint.contains("4k") {
            return "4K"
        }
        return nil
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
        return String(
            format: NSLocalizedString("Add \"%@\" to the download queue now?", comment: ""),
            pendingDownloadItem?.displayTitle ?? downloadTargetItem?.displayTitle ?? resolvedItem.displayTitle
        )
    }

    private func playPrimaryItem() {
        guard let target = playbackTargetItem else {
            errorMessage = NSLocalizedString("No playable item available.", comment: "")
            return
        }
        playItem(target, playbackQualityID: immediatePlaybackQualityID)
    }

    private func replayFromStart() {
        guard let target = playbackTargetItem else { return }
        playItem(target, playbackQualityID: immediatePlaybackQualityID, startFromBeginning: true)
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

    private func requestEpisodeDownload(_ episode: PlexItem) {
        guard canQueueEpisodeDownload(episode) else {
            downloadToastMessage = NSLocalizedString("Already in Download Queue", comment: "")
            return
        }
        pendingSeasonDownloadItems = []
        pendingSeasonDownloadTitle = nil
        pendingDownloadItem = episode
        isShowingDownloadConfirmSheet = true
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
        guard let target = pendingDownloadItem,
              let path = plexService.getDownloadPath(item: target) else { return }
        pendingDownloadItem = nil

        let job = DownloadJobDescriptor(
            kind: .singleMedia,
            sourceType: .plex,
            title: target.displayTitle,
            groupTitle: nil,
            collectionId: target.id
        )
        let item = DownloadMediaBatchItem(
            remoteItemId: target.id,
            remotePath: path,
            fileName: downloadFileName(for: target),
            displayTitle: target.displayTitle,
            totalBytes: target.mediaSize,
            collectionId: target.id,
            seriesId: resolvedItem.type.lowercased() == "show" ? resolvedItem.id : nil,
            seasonId: resolvedItem.type.lowercased() == "season" ? resolvedItem.id : nil,
            groupIndex: 0
        )
        let enqueuedCount = downloadCenter.enqueueMediaBatch(server: server, items: [item], job: job)
        if enqueuedCount > 0 {
            downloadToastMessage = NSLocalizedString("Added to Download Queue", comment: "")
        } else {
            downloadToastMessage = NSLocalizedString("Already in Download Queue", comment: "")
        }
    }

    private func confirmSelectedSeasonDownload() {
        let itemsToQueue = pendingSeasonDownloadItems
        let seasonTitle = pendingSeasonDownloadTitle ?? currentSeasonTitle
        pendingSeasonDownloadItems = []
        pendingSeasonDownloadTitle = nil

        let entries = itemsToQueue.enumerated().compactMap { index, episode -> DownloadMediaBatchItem? in
            guard let remotePath = plexService.getDownloadPath(item: episode) else { return nil }
            return DownloadMediaBatchItem(
                remoteItemId: episode.id,
                remotePath: remotePath,
                fileName: downloadFileName(for: episode),
                displayTitle: episode.displayTitle,
                totalBytes: episode.mediaSize,
                collectionId: selectedSeasonId ?? resolvedItem.id,
                seriesId: resolvedItem.type.lowercased() == "show" ? resolvedItem.id : nil,
                seasonId: selectedSeasonId ?? (resolvedItem.type.lowercased() == "season" ? resolvedItem.id : nil),
                groupIndex: index
            )
        }

        guard !entries.isEmpty else {
            downloadToastMessage = NSLocalizedString("Season Already Queued", comment: "")
            return
        }

        let job = DownloadJobDescriptor(
            kind: .seasonPack,
            sourceType: .plex,
            title: seasonTitle,
            groupTitle: seasonTitle,
            collectionId: selectedSeasonId ?? resolvedItem.id,
            seriesId: resolvedItem.type.lowercased() == "show" ? resolvedItem.id : nil,
            seasonId: selectedSeasonId ?? (resolvedItem.type.lowercased() == "season" ? resolvedItem.id : nil)
        )
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

    private func canQueueEpisodeDownload(_ episode: PlexItem) -> Bool {
        guard let remotePath = plexService.getDownloadPath(item: episode) else { return false }
        switch downloadCenter.taskStatus(serverId: server.id, remotePath: remotePath) {
        case .queued, .downloading, .paused, .completed:
            return false
        default:
            return true
        }
    }

    private func episodeDownloadIcon(for episode: PlexItem) -> String {
        guard let remotePath = plexService.getDownloadPath(item: episode) else {
            return "arrow.down.circle"
        }
        switch downloadCenter.taskStatus(serverId: server.id, remotePath: remotePath) {
        case .completed:
            return "arrow.down.circle.fill"
        case .queued, .downloading, .paused:
            return "arrow.down.circle.fill"
        default:
            return "arrow.down.circle"
        }
    }

    private func episodeDownloadColor(for episode: PlexItem) -> Color {
        guard let remotePath = plexService.getDownloadPath(item: episode) else {
            return .white.opacity(0.9)
        }
        switch downloadCenter.taskStatus(serverId: server.id, remotePath: remotePath) {
        case .completed:
            return .green
        case .queued, .downloading, .paused:
            return Color(UIColor.systemBlue)
        default:
            return .white.opacity(0.9)
        }
    }

    private func refreshOfflineAvailability() {
        offlineState = downloadCenter.aggregateStateForRemotePaths(serverId: server.id, remotePaths: currentOfflineRemotePaths)
    }

    private func downloadFileName(for item: PlexItem) -> String {
        var title = item.displayTitle
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")

        if let container = item.mediaContainer?.lowercased(),
           !container.isEmpty,
           !title.lowercased().hasSuffix(".\(container)") {
            title += ".\(container)"
        }
        return title
    }

    private func playItem(
        _ target: PlexItem,
        playbackQualityID: String? = nil,
        audioQuery: String? = nil,
        subtitleQuery: String? = nil,
        disableSubtitles: Bool = false,
        startFromBeginning: Bool = false
    ) {
        let resumeDecision = playbackResumeDecision(for: target)
        let startPosition: TimeInterval = startFromBeginning ? 0 : (resumeDecision.startPosition ?? 0)
        let playbackQuality = AppSettings.shared.resolvedRemotePlaybackQualityOption(for: playbackQualityID)
        guard var file = plexService.buildPlayableVideoFile(
            server: server,
            item: target,
            startPosition: startPosition,
            audioQuery: audioQuery,
            subtitleQuery: subtitleQuery,
            disableSubtitles: disableSubtitles,
            playbackQuality: playbackQuality
        ) else {
            errorMessage = NSLocalizedString("No playable item available.", comment: "")
            return
        }
        file.shouldResetRemotePlayedStateOnPlaybackStart =
            startFromBeginning || resumeDecision.shouldResetPlayedStateOnStart

        let queueSource = episodes.isEmpty ? [target] : episodes.filter { $0.isPlayable }
        let playlist: [VideoFile] = queueSource.compactMap { episode -> VideoFile? in
            let episodeDecision = playbackResumeDecision(for: episode)
            guard var file = plexService.buildPlayableVideoFile(
                server: server,
                item: episode,
                startPosition: startFromBeginning ? 0 : (episodeDecision.startPosition ?? 0),
                playbackQuality: playbackQuality
            ) else {
                return nil
            }
            file.shouldResetRemotePlayedStateOnPlaybackStart =
                startFromBeginning || episodeDecision.shouldResetPlayedStateOnStart
            return file
        }

        playerPlaylist = playlist.isEmpty ? [file] : playlist
        playerFile = file
    }

    private func refreshFavoriteState() {
        guard let file = favoritePlayableFile,
              let favoriteIdentityPath else {
            isFavorite = false
            return
        }
        isFavorite = favoriteService.isFavorite(file: file, folderPath: favoriteIdentityPath)
    }

    private func toggleFavorite() {
        guard let file = favoritePlayableFile else { return }
        favoriteService.toggleFavorite(file: file, folderPath: favoriteIdentityPath)
        downloadToastMessage = NSLocalizedString(favoriteService.isFavorite(file: file) ? "Added to Favorites" : "Removed from Favorites", comment: "")
        refreshFavoriteState()
    }

    private func resolveWatchlistTargetGUID(for targetId: String) async -> String? {
        if targetId == resolvedItem.id,
           let guid = resolvedItem.guid,
           !guid.isEmpty {
            return guid
        }

        do {
            let targetItem = try await plexService.getMetadataItem(server: server, itemId: targetId)
            let guid = targetItem?.guid?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (guid?.isEmpty == false) ? guid : nil
        } catch {
            return nil
        }
    }

    private func refreshWatchlistState() async {
        guard let targetId = watchlistTargetMetadataId else {
            await MainActor.run {
                watchlistTargetGUID = nil
                isWatchlisted = false
            }
            return
        }

        guard let guid = await resolveWatchlistTargetGUID(for: targetId) else {
            guard watchlistTargetMetadataId == targetId else { return }
            await MainActor.run {
                watchlistTargetGUID = nil
                isWatchlisted = false
            }
            return
        }

        do {
            let watchlisted = try await plexService.isWatchlisted(server: server, guid: guid)
            guard watchlistTargetMetadataId == targetId else { return }
            await MainActor.run {
                watchlistTargetGUID = guid
                isWatchlisted = watchlisted
            }
        } catch {
            guard watchlistTargetMetadataId == targetId else { return }
            await MainActor.run {
                watchlistTargetGUID = guid
                isWatchlisted = false
            }
        }
    }

    private func toggleWatchlist() async {
        guard !isUpdatingWatchlist else { return }

        guard let targetId = watchlistTargetMetadataId else {
            await MainActor.run {
                errorMessage = NSLocalizedString("This item does not support Plex watchlist.", comment: "")
            }
            return
        }

        let resolvedGUID: String?
        if let cachedGUID = watchlistTargetGUID {
            resolvedGUID = cachedGUID
        } else {
            resolvedGUID = await resolveWatchlistTargetGUID(for: targetId)
        }
        guard watchlistTargetMetadataId == targetId else { return }
        guard let guid = resolvedGUID else {
            await MainActor.run {
                errorMessage = NSLocalizedString("This item does not support Plex watchlist.", comment: "")
            }
            return
        }

        let previousValue = isWatchlisted
        let nextValue = !previousValue
        await MainActor.run {
            watchlistTargetGUID = guid
            isWatchlisted = nextValue
            isUpdatingWatchlist = true
        }

        do {
            try await plexService.setWatchlisted(server: server, guid: guid, isWatchlisted: nextValue)
            guard watchlistTargetMetadataId == targetId else { return }
            await MainActor.run {
                isUpdatingWatchlist = false
                downloadToastMessage = NSLocalizedString(nextValue ? "Added to Watchlist" : "Removed from Watchlist", comment: "")
            }
            NotificationCenter.default.post(
                name: .plexWatchlistDidChange,
                object: PlexWatchlistChangePayload(serverId: server.id)
            )
        } catch {
            guard watchlistTargetMetadataId == targetId else { return }
            await MainActor.run {
                isWatchlisted = previousValue
                isUpdatingWatchlist = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func togglePlayed() async {
        guard !isUpdatingPlayedState else { return }

        await MainActor.run {
            isUpdatingPlayedState = true
        }

        let nextPlayed = !isPlayed
        do {
            try await plexService.setPlayed(server: server, itemId: resolvedItem.id, isPlayed: nextPlayed)
            await MainActor.run {
                isPlayed = nextPlayed
                isUpdatingPlayedState = false
                downloadToastMessage = NSLocalizedString(nextPlayed ? "Marked as Played" : "Marked as Unplayed", comment: "")
                PlaybackRefreshCenter.updateRemoteItem(
                    serverId: server.id,
                    itemId: resolvedItem.id,
                    seriesId: playbackRefreshSeriesId(for: resolvedItem),
                    seasonId: playbackRefreshSeasonId(for: resolvedItem),
                    snapshot: RemotePlaybackStateSnapshot.manualPlayedState(
                        played: nextPlayed,
                        runtimeTicks: playbackRefreshRuntimeTicks(for: resolvedItem)
                    )
                )
            }
        } catch {
            await MainActor.run {
                isUpdatingPlayedState = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func playbackRefreshSeriesId(for target: PlexItem) -> String? {
        switch target.type.lowercased() {
        case "show":
            return target.id
        case "season":
            return target.parentRatingKey
        case "episode":
            return target.grandparentRatingKey
        default:
            return nil
        }
    }

    private func playbackRefreshSeasonId(for target: PlexItem) -> String? {
        switch target.type.lowercased() {
        case "season":
            return target.id
        case "episode":
            return target.parentRatingKey
        default:
            return nil
        }
    }

    private func playbackRefreshRuntimeTicks(for target: PlexItem) -> Int64? {
        guard let durationMillis = target.durationMillis else { return nil }
        return durationMillis * 10_000
    }

    private func fetchPlaybackMetadata(for target: PlexItem) async throws -> PlexItem {
        if target.id == resolvedItem.id, !resolvedItem.mediaStreams.isEmpty {
            return resolvedItem
        }
        return try await plexService.getMetadataItem(server: server, itemId: target.id) ?? target
    }

    private func refreshPrePlaybackOptionAvailability() async {
        guard let target = playbackTargetItem else {
            await MainActor.run { canShowPrePlaybackOptions = false }
            return
        }

        do {
            let metadata = try await fetchPlaybackMetadata(for: target)
            let audioCount = metadata.mediaStreams.filter { $0.isAudio }.count
            let subtitleCount = metadata.mediaStreams.filter { $0.isSubtitle }.count
            let qualityCount = plexService.qualityOptions(for: metadata).count
            await MainActor.run {
                canShowPrePlaybackOptions = qualityCount > 1 || subtitleCount > 0 || audioCount > 1
            }
        } catch {
            await MainActor.run { canShowPrePlaybackOptions = false }
        }
    }

    private func presentPrePlaybackOptions() async {
        guard !isLoadingPrePlaybackOptions else { return }
        guard let target = playbackTargetItem else {
            await MainActor.run {
                errorMessage = NSLocalizedString("No playable item available.", comment: "")
            }
            return
        }

        await MainActor.run {
            isLoadingPrePlaybackOptions = true
        }

        do {
            let metadata = try await fetchPlaybackMetadata(for: target)
            let audioStreams = metadata.mediaStreams.enumerated().filter { $0.element.isAudio }
            let subtitleStreams = metadata.mediaStreams.enumerated().filter { $0.element.isSubtitle }
            let qualityOptions = AppSettings.shared.visibleRemotePlaybackQualityOptions(
                from: plexService.qualityOptions(for: metadata)
            ).map { option in
                PrePlaybackTrackOption(
                    id: option.id,
                    title: option.title,
                    subtitle: option.subtitle,
                    query: option.id
                )
            }

            guard !qualityOptions.isEmpty || audioStreams.count > 1 || !subtitleStreams.isEmpty else {
                await MainActor.run {
                    isLoadingPrePlaybackOptions = false
                    errorMessage = NSLocalizedString("No selectable playback options for this item.", comment: "")
                }
                return
            }

            let audioOptions = audioStreams.map { (index, stream) in
                let title = prePlaybackTrackDisplayName(
                    stream: stream,
                    fallbackPrefix: NSLocalizedString("Audio", comment: ""),
                    fallbackIndex: index + 1
                )
                return PrePlaybackTrackOption(id: "audio-\(index)", title: title, query: title)
            }

            var subtitleOptions: [PrePlaybackTrackOption] = [
                PrePlaybackTrackOption(
                    id: PrePlaybackTrackOption.subtitleOffID,
                    title: NSLocalizedString("Off", comment: ""),
                    query: nil
                )
            ]
            subtitleOptions.append(contentsOf: subtitleStreams.map { (index, stream) in
                let title = prePlaybackTrackDisplayName(
                    stream: stream,
                    fallbackPrefix: NSLocalizedString("Subtitle", comment: ""),
                    fallbackIndex: index + 1
                )
                return PrePlaybackTrackOption(id: "subtitle-\(index)", title: title, query: title)
            })

            let defaultAudioIndex = audioStreams.first(where: { $0.element.selected || $0.element.defaultStream })?.offset
            let defaultSubtitleIndex = subtitleStreams.first(where: { $0.element.selected || $0.element.defaultStream })?.offset

            await MainActor.run {
                prePlaybackTargetItem = metadata
                prePlaybackQualityOptions = qualityOptions
                prePlaybackAudioOptions = audioOptions
                prePlaybackSubtitleOptions = subtitleOptions
                let resolvedQualityID = AppSettings.shared.resolvedRemotePlaybackQualityID(for: selectedPrePlaybackQualityID)
                selectedPrePlaybackQualityID = qualityOptions.contains(where: { $0.id == resolvedQualityID })
                    ? resolvedQualityID
                    : AppSettings.shared.defaultRemotePlaybackQualityOption.id
                selectedPrePlaybackAudioID = defaultAudioIndex.map { "audio-\($0)" } ?? audioOptions.first?.id
                selectedPrePlaybackSubtitleID = defaultSubtitleIndex.map { "subtitle-\($0)" } ?? PrePlaybackTrackOption.subtitleOffID
                isLoadingPrePlaybackOptions = false
                showPrePlaybackOptions = true
            }
        } catch {
            await MainActor.run {
                isLoadingPrePlaybackOptions = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func prePlaybackTrackDisplayName(
        stream: PlexMediaStream,
        fallbackPrefix: String,
        fallbackIndex: Int
    ) -> String {
        let title = stream.preferredQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        return "\(fallbackPrefix) \(fallbackIndex)"
    }

    private func playWithPrePlaybackSelection() {
        guard let target = prePlaybackTargetItem else { return }

        let selectedAudio = prePlaybackAudioOptions.first(where: { $0.id == selectedPrePlaybackAudioID })?.query
        let selectedSubtitleID = selectedPrePlaybackSubtitleID ?? PrePlaybackTrackOption.subtitleOffID
        let disableSubtitles = selectedSubtitleID == PrePlaybackTrackOption.subtitleOffID
        let selectedSubtitle = prePlaybackSubtitleOptions.first(where: { $0.id == selectedSubtitleID })?.query

        playItem(
            target,
            playbackQualityID: AppSettings.shared.resolvedRemotePlaybackQualityID(for: selectedPrePlaybackQualityID),
            audioQuery: selectedAudio,
            subtitleQuery: selectedSubtitle,
            disableSubtitles: disableSubtitles
        )
    }

    private func loadDetail() async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
        }

        do {
            let metadata = try await plexService.resolveMetadataItem(server: server, item: item) ?? item
            await MainActor.run {
                resolvedItem = metadata
                isPlayed = metadata.isPlayed
            }

            switch metadata.type.lowercased() {
            case "show":
                let loadedSeasons = try await plexService.getChildren(server: server, itemId: metadata.id)
                    .filter { $0.type.lowercased() == "season" }
                let preferredSeasonId = loadedSeasons.first(where: { $0.id == initialSeasonId })?.id
                    ?? loadedSeasons.first?.id
                await MainActor.run {
                    seasons = loadedSeasons
                    selectedSeasonId = preferredSeasonId
                }
                if let preferredSeasonId {
                    await loadEpisodes(for: preferredSeasonId)
                }
            case "season":
                await loadEpisodes(for: metadata.id)
            default:
                await MainActor.run {
                    seasons = []
                    episodes = []
                }
                break
            }

            let loadedRelated = (try? await plexService.getRelatedItems(server: server, itemId: metadata.id, limit: 18)) ?? []
            await MainActor.run {
                relatedItems = loadedRelated.filter { $0.isPlayable || $0.isContainer }
            }

            await MainActor.run {
                isLoading = false
                refreshFavoriteState()
            }
            await refreshWatchlistState()
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                relatedItems = []
                isLoading = false
            }
        }
    }

    private func handleRemotePlaybackRefresh(_ payload: PlaybackStateRefreshPayload) {
        guard payload.serverId == server.id else { return }

        let isRelevant =
            payload.itemId == item.id ||
            payload.itemId == resolvedItem.id ||
            payload.seriesId == item.id ||
            payload.seriesId == resolvedItem.id ||
            payload.seasonId == item.id ||
            payload.seasonId == resolvedItem.id ||
            payload.seasonId == selectedSeasonId ||
            episodes.contains(where: { $0.id == payload.itemId })

        guard isRelevant else { return }

        Task { await loadDetail() }
    }

    private func loadEpisodes(for seasonId: String) async {
        await MainActor.run {
            isLoadingEpisodes = true
        }

        do {
            let loadedEpisodes = try await plexService.getChildren(server: server, itemId: seasonId)
                .filter(\.isPlayable)
            await MainActor.run {
                episodes = loadedEpisodes
                isLoadingEpisodes = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoadingEpisodes = false
            }
        }
    }

    private func scrollToPendingEpisode(using proxy: ScrollViewProxy) {
        guard let pendingEpisodeId,
              episodes.contains(where: { $0.id == pendingEpisodeId }) else {
            return
        }

        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo(pendingEpisodeId, anchor: .top)
            }
            self.pendingEpisodeId = nil
        }
    }

    private func toggleEpisodePlayed(_ episode: PlexItem) async {
        let newState = !episode.isPlayed
        do {
            try await plexService.setPlayed(server: server, itemId: episode.id, isPlayed: newState)
            await MainActor.run {
                if episode.id == resolvedItem.id {
                    isPlayed = newState
                }
            }
            if let seasonId = selectedSeasonId {
                await loadEpisodes(for: seasonId)
            }
        } catch {
            print("Failed to toggle played state: \(error.localizedDescription)")
        }
    }

    private func deleteItem(_ targetItem: PlexItem) async {
        isDeleting = true
        do {
            try await plexService.deleteItem(server: server, ratingKey: targetItem.id)

            if let favorite = favoriteService.favorites.first(where: { $0.file.jellyfinItemId == targetItem.id }) {
                favoriteService.remove(favorite)
            }
            if let historyFile = HistoryService.shared.remoteHistory.first(where: { $0.jellyfinItemId == targetItem.id }) {
                HistoryService.shared.removeFromHistory(historyFile)
            }

            await MainActor.run {
                NotificationCenter.default.post(
                    name: .remoteItemDidDelete,
                    object: RemoteItemDeletePayload(serverId: server.id, itemId: targetItem.id)
                )

                if targetItem.id == resolvedItem.id {
                    presentationMode.wrappedValue.dismiss()
                } else if targetItem.type.lowercased() == "season" {
                    seasons.removeAll(where: { $0.id == targetItem.id })
                    if selectedSeasonId == targetItem.id {
                        if let nextSeason = seasons.first {
                            selectedSeasonId = nextSeason.id
                            Task { await loadEpisodes(for: nextSeason.id) }
                        } else {
                            selectedSeasonId = nil
                            episodes = []
                        }
                    }
                } else {
                    episodes.removeAll(where: { $0.id == targetItem.id })
                }
            }
        } catch {
            await MainActor.run {
                downloadToastMessage = NSLocalizedString("Failed to delete from server", comment: "")
            }
            print("Failed to delete item from Plex server: \(error.localizedDescription)")
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
            
            if settings.allowMediaServerDeletion, let onDelete = onDelete {
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
}

private struct PlexPersonDetailView: View {
    @Environment(\.presentationMode) private var presentationMode
    let server: ServerConfig
    let person: PlexPerson
    var onPlay: (PlexItem) -> Void

    @State private var items: [PlexItem] = []
    @State private var isLoadingItems = false
    @State private var errorMessage: String?
    
    @State private var currentStartIndex = 0
    @State private var hasMoreItems = true
    @State private var isPaginating = false
    private let pageSize = 60

    private let plexService = PlexService.shared

    @Environment(\.horizontalSizeClass) private var personHorizontalSizeClass

    private var usesWideLayout: Bool {
        personHorizontalSizeClass == .regular
    }

    private var titleFont: Font {
        usesWideLayout ? .title : .title2
    }

    private var subtitleFont: Font {
        usesWideLayout ? .title3 : .body
    }

    private var headerImageWidth: CGFloat {
        usesWideLayout ? 156 : 108
    }

    private var headerImageHeight: CGFloat {
        headerImageWidth * 1.5
    }

    private var posterCardWidth: CGFloat {
        usesWideLayout ? 148 : 112
    }

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: posterCardWidth,
                    maximum: usesWideLayout ? 176 : 132
                ),
                spacing: usesWideLayout ? 18 : 14,
                alignment: .top
            )
        ]
    }

    private var roleText: String? {
        let cleanedRole = person.role?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedType = person.type?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let cleanedRole, !cleanedRole.isEmpty else {
            return nil
        }
        if let cleanedType,
           !cleanedType.isEmpty,
           cleanedRole.compare(cleanedType, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return nil
        }
        return cleanedRole
    }

    private var typeText: String? {
        let cleanedType = person.type?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let cleanedType, !cleanedType.isEmpty else {
            return nil
        }
        return cleanedType
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection

                VStack(alignment: .leading, spacing: 14) {
                    Text(NSLocalizedString("Known For", comment: ""))
                        .font(.headline)
                        .foregroundColor(.primary)

                    if isLoadingItems {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 120)
                    } else if items.isEmpty {
                        Text(NSLocalizedString("No items found", comment: ""))
                            .foregroundColor(.secondary)
                    } else {
                        MediaLibraryCardGrid(columns: columns, spacing: usesWideLayout ? 18 : 14, legacyCardWidth: posterCardWidth) { columnWidth in
                            ForEach(items) { item in
                                NavigationLink(
                                    destination: PlexItemDetailView(
                                        server: server,
                                        item: item,
                                        onExit: nil,
                                        onPlay: onPlay
                                    )
                                ) {
                                    PlexPosterCard(item: item, server: server, cardWidth: columnWidth)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        
                        if hasMoreItems && !items.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                                .onAppear {
                                    Task { await loadKnownForItems(isPagination: true) }
                                }
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, usesWideLayout ? 24 : 16)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .background(Color(UIColor.systemBackground).ignoresSafeArea())
        .navigationTitle(person.name)
        .navigationBarTitleDisplayMode(.inline)
        .libraryChildNavigationBarCompat()
        .customBackButton()
        .mediaLibraryNavigationToolbar {
            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                AppToolbarIcon(systemName: "chevron.left")
            }
        } home: {
            Button(action: { NavigationUtil.popToRootView() }) {
                AppToolbarIcon(systemName: "house")
            }
        }
        .onAppear {
            if items.isEmpty, !isLoadingItems {
                Task { await loadKnownForItems() }
            }
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                if let imageURL = person.primaryImageURL(server: server) {
                    RemoteImage(url: imageURL)
                        .aspectRatio(2 / 3, contentMode: .fill)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(UIColor.tertiarySystemFill))

                        Image(systemName: "person.fill")
                            .font(.system(size: usesWideLayout ? 44 : 36))
                            .foregroundColor(Color(UIColor.secondaryLabel))
                    }
                }
            }
            .frame(width: headerImageWidth, height: headerImageHeight)
            .cornerRadius(16)
            .clipped()

            VStack(alignment: .leading, spacing: 10) {
                Text(person.name)
                    .font(titleFont)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)

                if let roleText {
                    Text(roleText)
                        .font(subtitleFont)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let typeText {
                    Text(typeText)
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12))
                        .cornerRadius(999)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    private func loadKnownForItems(isPagination: Bool = false) async {
        if isPagination {
            guard !isPaginating, hasMoreItems else { return }
            await MainActor.run { isPaginating = true }
        } else {
            await MainActor.run {
                isLoadingItems = true
                errorMessage = nil
                currentStartIndex = 0
                hasMoreItems = true
            }
        }

        do {
            let loadedItems = try await plexService.getPersonMedia(
                server: server,
                personId: person.id,
                startIndex: currentStartIndex,
                limit: pageSize
            )
            
            var seen = Set<String>()
            let filteredItems = loadedItems.filter { item in
                guard item.isPlayable || item.isContainer else {
                    return false
                }
                return seen.insert(item.id).inserted
            }

            await MainActor.run {
                if isPagination {
                    items.append(contentsOf: filteredItems)
                } else {
                    items = filteredItems
                }
                
                hasMoreItems = loadedItems.count >= pageSize
                
                if isPagination {
                    currentStartIndex += pageSize
                    isPaginating = false
                } else {
                    currentStartIndex = pageSize
                    isLoadingItems = false
                }
            }
        } catch {
            if isCancellation(error) {
                await MainActor.run {
                    if isPagination { isPaginating = false }
                    else { isLoadingItems = false }
                }
                return
            }
            await MainActor.run {
                if isPagination {
                    isPaginating = false
                } else {
                    errorMessage = error.localizedDescription
                    isLoadingItems = false
                }
            }
        }
    }
    
    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

private struct PlexEpisodeRow: View {
    let item: PlexItem
    let server: ServerConfig

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: item.imageURL(server: server, imagePath: item.thumb ?? item.posterPath))
                .aspectRatio(16/9, contentMode: .fill)
                .frame(width: 120, height: 68)
                .cornerRadius(8)
                .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let episodeNumber = item.index {
                        Text(String(format: NSLocalizedString("Episode %d", comment: ""), episodeNumber))
                    }
                    if let runtime = item.durationSeconds {
                        Text(PlexUIHelpers.runtimeText(seconds: runtime))
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.72))

                let detailSegments = plexDetailMetadataSegments(for: item)
                if !detailSegments.isEmpty {
                    Text(detailSegments.joined(separator: " • "))
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.62))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "play.circle")
                .font(.title2)
                .foregroundColor(.white.opacity(0.9))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

private struct PlexPersonCard: View {
    let person: PlexPerson
    let server: ServerConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let thumbURL = person.primaryImageURL(server: server) {
                RemoteImage(url: thumbURL)
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(width: 100, height: 150)
                    .cornerRadius(8)
                    .clipped()
            } else {
                ZStack {
                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 100, height: 150)
                        .cornerRadius(8)
                    Image(systemName: "person.fill")
                        .font(.system(size: 30))
                        .foregroundColor(.white.opacity(0.5))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .frame(width: 100, height: 32, alignment: .topLeading)

                if let subtitle = personCardSubtitle(role: person.role, type: person.type), !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(width: 100, height: MediaCardMetrics.peopleTextHeight, alignment: .topLeading)
        }
        .frame(width: 100)
    }
}

private struct PlexRelatedPosterCard: View {
    let item: PlexItem
    let server: ServerConfig

    private let cardWidth: CGFloat = 120
    private var posterHeight: CGFloat { cardWidth * 1.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: item.posterImageURL(server: server))
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(width: cardWidth, height: posterHeight)
                    .cornerRadius(8)
                    .clipped()

                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(height: 60)
                .cornerRadius(8, corners: [.bottomLeft, .bottomRight])
                .allowsHitTesting(false)

                HStack(spacing: 4) {
                    if let rating = item.rating, rating > 0 {
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

            Text(item.displayTitle)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.white)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: cardWidth)
    }
}

private enum PlexUIHelpers {
    static func runtimeText(seconds: TimeInterval) -> String {
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return String(format: NSLocalizedString("%dh %dm", comment: ""), hours, minutes)
        }
        return String(format: NSLocalizedString("%dm", comment: ""), minutes)
    }

    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct PlexMediaContextMenuModifier: ViewModifier {
    let item: PlexItem
    let server: ServerConfig
    @AppStorage("allowMediaServerDeletion") private var allowMediaServerDeletion = false
    @State private var showingDeleteAlert = false
    @State private var isDeleting = false
    @State private var isPlayed: Bool

    let onPlay: (() -> Void)?

    init(item: PlexItem, server: ServerConfig, onPlay: (() -> Void)? = nil) {
        self.item = item
        self.server = server
        self.onPlay = onPlay
        self._isPlayed = State(initialValue: item.isPlayed)
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

                Button(action: { Task { await togglePlayed() } }) {
                    Label(
                        isPlayed ? NSLocalizedString("Mark as Unplayed", comment: "") : NSLocalizedString("Mark as Played", comment: ""),
                        systemImage: isPlayed ? "xmark.circle" : "checkmark.circle"
                    )
                }

                if allowMediaServerDeletion {
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
                    message: Text(String(format: NSLocalizedString("Are you sure you want to delete \"%@\" from the server? This cannot be undone.", comment: ""), item.displayTitle)),
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
            try await PlexService.shared.setPlayed(server: server, itemId: item.id, isPlayed: newState)
            await MainActor.run { isPlayed = newState }
        } catch {
            print("Failed to toggle played state: \(error.localizedDescription)")
        }
    }

    private func deleteItem() async {
        isDeleting = true
        do {
            try await PlexService.shared.deleteItem(server: server, ratingKey: item.id)

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
            print("Failed to delete item from Plex server: \(error.localizedDescription)")
        }
        isDeleting = false
    }
}

#if os(iOS)
/// Match the existing media-detail back-button pattern without changing sheet themes.
private struct PlexDetailNavigationBarModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        content.customBackButton()
    }
}
#endif
