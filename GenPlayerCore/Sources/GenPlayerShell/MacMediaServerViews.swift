#if os(macOS)
import SwiftUI
import AVKit
import AppKit
import AuthenticationServices
import GenPlayerCore

struct MacServerHubView: View {
    let server: ServerConfig
    let onClose: () -> Void

    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var navManager = MacNavigationManager.shared
    @EnvironmentObject private var tabContext: MacTabContext

    @State private var stack: [MacMediaLibraryNode] = []
    @State private var nodes: [MacMediaLibraryNode] = []
    @State private var availableGenres: [String] = []
    @State private var availableYears: [String] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedLeaf: MacMediaLibraryNode?

    @State private var currentStartIndex = 0
    @State private var hasMoreItems = true
    @State private var isPaginating = false
    private let pageSize = 120

    @State private var jellyfinHeroEntries: [MacHomeCarouselEntry] = []
    @State private var resumeNodes: [MacMediaLibraryNode] = []
    @State private var latestNodes: [MacMediaLibraryNode] = []
    @State private var favoritesNodes: [MacMediaLibraryNode] = []
    @State private var libraryPreviewNodes: [String: [MacMediaLibraryNode]] = [:]
    @State private var searchText: String = ""
    /// Only updated after the debounce fires so that isLibraryHome / layout
    /// does not flip on every keystroke (prevents the home-page "jump").
    @State private var committedSearchText: String = ""
    @State private var carouselIndex = 0
    @State private var carouselTask: Task<Void, Never>?
    @State private var isCarouselHovered = false
    @State private var searchTask: Task<Void, Never>?
    
    @State private var selectedYear: String? = nil
    @State private var selectedGenre: String? = nil

    @AppStorage("MacJellyfinBrowserDisplayMode") private var displayModeRaw: String = LibraryDisplayMode.poster.rawValue
    @AppStorage("MacJellyfinBrowserIsGrid") private var isGridView = true
    @AppStorage("MacJellyfinSortOption") private var sortOptionRaw: String = "SortName"
    @AppStorage("MacJellyfinSortAscending") private var isSortAscending: Bool = true

    private var displayMode: LibraryDisplayMode {
        get {
            if let mode = LibraryDisplayMode(rawValue: displayModeRaw) {
                return mode
            }
            return isGridView ? .poster : .list
        }
        nonmutating set {
            displayModeRaw = newValue.rawValue
            isGridView = (newValue != .list)
        }
    }

    private var displayModeBinding: Binding<LibraryDisplayMode> {
        Binding(
            get: { self.displayMode },
            set: { self.displayMode = $0 }
        )
    }

    private var currentServer: ServerConfig {
        networkService.savedServers.first(where: { $0.id == server.id }) ?? server
    }

    private var title: String { currentServer.name }

    private var trimmedSearchText: String {
        committedSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isLibraryHome: Bool {
        stack.isEmpty && trimmedSearchText.isEmpty
    }

    private var currentLibraryName: String? {
        stack.last?.name
    }

    private var isListCategory: Bool {
        !stack.isEmpty
    }

    private func applySort(to nodes: [MacMediaLibraryNode]) -> [MacMediaLibraryNode] {
        guard isListCategory, trimmedSearchText.isEmpty else { return nodes }
        return macSortNodes(nodes, sortBy: sortOptionRaw, isAscending: isSortAscending)
    }

    private var libraryPreviewSections: [(library: MacMediaLibraryNode, items: [MacMediaLibraryNode])] {
        guard isLibraryHome else { return [] }
        return nodes.compactMap { library in
            let previewItems = libraryPreviewNodes[library.id] ?? []
            guard !previewItems.isEmpty else { return nil }
            return (library, previewItems)
        }
    }

    private var homeCarouselEntries: [MacHomeCarouselEntry] {
        guard isLibraryHome else { return [] }
        if currentServer.type == .jellyfin { return jellyfinHeroEntries }

        var entries: [MacHomeCarouselEntry] = []
        var seenIDs = Set<String>()

        func append(
            _ items: [MacMediaLibraryNode],
            sourceTitle: String,
            sourceSystemImageName: String
        ) {
            let candidates = MediaHomeCarouselSelection.unique(items, limit: items.count,
                identity: { MediaHomeCarouselSelection.identity(itemID: $0.id, seriesID: $0.seriesId, itemType: $0.collectionType ?? "") },
                lastPlayedAt: { $0.lastPlayedDate })
            for item in candidates {
                guard entries.count < 8 else { return }
                guard item.backdropURL != nil || item.posterURL != nil else { continue }
                guard seenIDs.insert(MediaHomeCarouselSelection.identity(itemID: item.id, seriesID: item.seriesId, itemType: item.collectionType ?? "")).inserted else { continue }
                entries.append(
                    MacHomeCarouselEntry(
                        node: item,
                        sourceTitle: sourceTitle,
                        sourceSystemImageName: sourceSystemImageName
                    )
                )
                if entries.count >= 8 { return }
            }
        }

        append(
            resumeNodes,
            sourceTitle: platformShellString("Continue Watching"),
            sourceSystemImageName: "clock.fill"
        )
        append(
            latestNodes,
            sourceTitle: platformShellString("Recently Added"),
            sourceSystemImageName: "sparkles.tv.fill"
        )
        append(
            favoritesNodes,
            sourceTitle: NSLocalizedString("Favorites", comment: ""),
            sourceSystemImageName: "heart.fill"
        )
        for section in libraryPreviewSections {
            append(
                section.items,
                sourceTitle: section.library.name,
                sourceSystemImageName: iconName(for: section.library)
            )
        }

        return entries
    }

    private let libraryColumns = [
        GridItem(.adaptive(minimum: MacMediaCardMetrics.landscapeWidth, maximum: MacMediaCardMetrics.landscapeWidth), spacing: 20, alignment: .top)
    ]

    private let portraitColumns = [
        GridItem(.adaptive(minimum: MacMediaCardMetrics.portraitWidth, maximum: MacMediaCardMetrics.portraitWidth), spacing: 20, alignment: .top)
    ]

    var body: some View {
        Group {
            if let leaf = selectedLeaf {
                // Show detail in-place — do NOT use NavigationLink push.
                // NavigationLink on macOS adds pushed views at window-VC level,
                // outside NSTabViewController's tab, so they remain visible when
                // switching tabs. Conditional rendering keeps everything inside
                // the NSHostingController's tab hierarchy.
                //
                // Wrap in a local NavigationStack so that nested NavigationLinks
                // inside MacMediaNodeDetailView (episodes, cast, similar) work
                // correctly and stay within the same tab.
                // We use a custom MacMediaDetailStackView to manage nested detail
                // pages (episodes, cast, similar) without NavigationLink to completely
                // bypass the macOS SwiftUI tab escape bug.
                MacMediaDetailStackView(
                    server: currentServer,
                    rootNode: leaf,
                    onBackToHub: { selectedLeaf = nil },
                    onHome: {
                        selectedLeaf = nil
                        stack.removeAll()
                        libraryPreviewNodes = [:]
                        restartCarousel()
                        loadNodes()
                    },
                    onExit: {
                        selectedLeaf = nil
                        onClose()
                    }
                )
            } else {
                // Hub content
                VStack(alignment: .leading, spacing: 0) {
                    ZStack {
                        Color(nsColor: .windowBackgroundColor).edgesIgnoringSafeArea(.all)

                        if let errorMessage {
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .padding()
                        } else if isLoading && nodes.isEmpty && resumeNodes.isEmpty && latestNodes.isEmpty {
                            ProgressView(platformShellString("Platform Shell TV Loading"))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if nodes.isEmpty && resumeNodes.isEmpty && latestNodes.isEmpty && isLibraryHome {
                            VStack(spacing: 12) {
                                Image(systemName: "square.grid.2x2")
                                    .font(.system(size: 48))
                                    .foregroundColor(.secondary.opacity(0.5))
                                Text(platformShellString("Platform Shell TV Folder Empty Title"))
                                    .font(.headline)
                                    .foregroundColor(.secondary)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            ScrollViewReader { proxy in
                                ScrollView {
                                    GeometryReader { geo in
                                        Color.clear.preference(key: MacScrollOffsetKey.self, value: geo.frame(in: .named("hubScroll")).minY)
                                    }
                                    .frame(height: 0)
                                    .id("TOP")

                                    VStack(alignment: .leading, spacing: 32) {
                                        if !trimmedSearchText.isEmpty {
                                            MacSectionHeader(
                                                title: platformShellString("Search Results"),
                                                systemImageName: "magnifyingglass"
                                            )
                                            .padding(.horizontal, 24)
                                            .padding(.top, 16)

                                            MacPortraitMediaGrid(nodes: nodes, columns: portraitColumns, onOpen: openNode, server: server, onPlay: playNode)
                                        } else {
                                            if isLibraryHome {
                                                if !homeCarouselEntries.isEmpty {
                                                    MacMediaHeroCarousel(
                                                        server: server,
                                                        entries: homeCarouselEntries,
                                                        selectedIndex: $carouselIndex,
                                                        onPrimaryAction: handleCarouselPrimaryAction,
                                                        onOpenDetails: openNode
                                                    )
                                                    .frame(height: 440)
                                                    .onHover { hovering in
                                                        isCarouselHovered = hovering
                                                        carouselTask?.cancel()
                                                        carouselTask = nil
                                                        if !hovering { startCarouselIfNeeded() }
                                                    }
                                                    .onAppear {
                                                        isCarouselHovered = false
                                                        startCarouselIfNeeded()
                                                    }
                                                    .onDisappear {
                                                        carouselTask?.cancel()
                                                        carouselTask = nil
                                                        isCarouselHovered = false
                                                    }
                                                }

                                                if !resumeNodes.isEmpty {
                                                    MacMediaShelfSection(
                                                        title: platformShellString("Continue Watching"),
                                                        systemImageName: "clock.fill",
                                                        items: resumeNodes,
                                                        artworkHeight: MacMediaCardMetrics.landscapeHeight
                                                    ) { node in
                                                        MacLandscapeMediaCard(node: node, action: { openNode(node) }, server: server, onPlay: { playNode(node) })
                                                    }
                                                }

                                                if !latestNodes.isEmpty {
                                                    MacMediaShelfSection(
                                                        title: platformShellString("Recently Added"),
                                                        systemImageName: "sparkles.tv.fill",
                                                        items: latestNodes,
                                                        artworkHeight: MacMediaCardMetrics.portraitHeight
                                                    ) { node in
                                                        MacPortraitMediaCard(node: node, action: { openNode(node) }, server: server, onPlay: { playNode(node) })
                                                    }
                                                }

                                                if !favoritesNodes.isEmpty {
                                                    MacMediaShelfSection(
                                                        title: NSLocalizedString("Favorites", comment: ""),
                                                        systemImageName: "heart.fill",
                                                        items: favoritesNodes,
                                                        artworkHeight: MacMediaCardMetrics.portraitHeight
                                                    ) { node in
                                                        MacPortraitMediaCard(node: node, action: { openNode(node) }, server: server, onPlay: { playNode(node) })
                                                    }
                                                }

                                                if !nodes.isEmpty {
                                                    MacSectionHeader(
                                                        title: platformShellString("My Media"),
                                                        systemImageName: "square.grid.2x2.fill"
                                                    )
                                                    .padding(.horizontal, 24)

                                                    LazyVGrid(columns: libraryColumns, alignment: .leading, spacing: 24) {
                                                        ForEach(nodes) { node in
                                                            MacLibraryCard(node: node, previewNodes: libraryPreviewNodes[node.id] ?? []) { openNode(node) }
                                                        }
                                                    }
                                                    .padding(.horizontal, 24)

                                                    ForEach(libraryPreviewSections, id: \.library.id) { section in
                                                        MacMediaShelfSection(
                                                            title: section.library.name,
                                                            systemImageName: iconName(for: section.library),
                                                            itemCount: section.library.itemCount,
                                                            onSeeAll: { openNode(section.library) },
                                                            items: section.items,
                                                            artworkHeight: MacMediaCardMetrics.portraitHeight
                                                        ) { node in
                                                            MacPortraitMediaCard(node: node, action: { openNode(node) }, server: currentServer, onPlay: { playNode(node) })
                                                        }
                                                    }
                                                }
                                            } else {
                                                if let currentLibraryName {
                                                    MacSectionHeader(
                                                        title: currentLibraryName,
                                                        systemImageName: "folder"
                                                    )
                                                    .padding(.horizontal, 24)
                                                    .padding(.top, 16)
                                                }

                                                if currentServer.type == .jellyfin || currentServer.type == .emby {
                                                    if !availableGenres.isEmpty || !availableYears.isEmpty {
                                                        MacLibraryFilterBar(
                                                            selectedYear: Binding(
                                                                get: { selectedYear },
                                                                set: { newValue in
                                                                    selectedYear = newValue
                                                                    loadNodes()
                                                                }
                                                            ),
                                                            selectedGenre: Binding(
                                                                get: { selectedGenre },
                                                                set: { newValue in
                                                                    selectedGenre = newValue
                                                                    loadNodes()
                                                                }
                                                            ),
                                                            availableYears: availableYears,
                                                            availableGenres: availableGenres
                                                        )
                                                    }
                                                }

                                                let sortedNodes = applySort(to: nodes)

                                                if sortedNodes.isEmpty {
                                                    if isLoading {
                                                        Spacer()
                                                            .frame(maxWidth: .infinity, minHeight: 300)
                                                    } else {
                                                        VStack(spacing: 12) {
                                                            let hasFilter = (selectedYear != nil || selectedGenre != nil)
                                                            Image(systemName: hasFilter ? "magnifyingglass" : "square.grid.2x2")
                                                                .font(.system(size: 48))
                                                                .foregroundColor(.secondary.opacity(0.5))
                                                            Text(hasFilter ? platformShellString("Platform Shell TV Filter Empty Title") : platformShellString("Platform Shell TV Folder Empty Title"))
                                                                .font(.headline)
                                                                .foregroundColor(.secondary)
                                                        }
                                                        .frame(maxWidth: .infinity, minHeight: 300)
                                                        .padding(.top, 40)
                                                    }
                                                } else {
                                                    switch displayMode {
                                                    case .poster:
                                                        MacPortraitMediaGrid(nodes: sortedNodes, columns: portraitColumns, onOpen: openNode, server: currentServer, onPlay: playNode)
                                                    case .thumb:
                                                        MacLandscapeMediaGrid(nodes: sortedNodes, columns: libraryColumns, onOpen: openNode, server: currentServer, onPlay: playNode)
                                                    case .list:
                                                        LazyVStack(spacing: 0) {
                                                            ForEach(sortedNodes) { node in
                                                                MacRemoteMediaListRow(
                                                                    node: node,
                                                                    onOpen: { openNode(node) },
                                                                    server: currentServer,
                                                                    onPlay: node.isFolder ? nil : { playNode(node) }
                                                                )
                                                            }
                                                        }
                                                        .padding(.horizontal, 24)
                                                    }
                                                }
                                                
                                                if hasMoreItems && !nodes.isEmpty && !isLoading && !isPaginating {
                                                    ProgressView()
                                                        .frame(maxWidth: .infinity, alignment: .center)
                                                        .padding(.vertical, 24)
                                                        .onAppear {
                                                            Task { loadNodes(isPagination: true) }
                                                        }
                                                }

                                                if !isLoading && !nodes.isEmpty && !hasMoreItems {
                                                    let count = stack.last?.itemCount ?? nodes.count
                                                    if count > 0 {
                                                        Text(MediaCountFormatter.formatTotal(count: count, libraryType: stack.last?.jellyfinLibraryType ?? .mixed))
                                                            .font(.footnote)
                                                            .foregroundColor(.secondary)
                                                            .frame(maxWidth: .infinity, alignment: .center)
                                                            .padding(.vertical, 20)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .padding(.bottom, 28)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .ignoresSafeArea(.all) // Fix macOS ScrollView top safe area gap inside ScrollViewReader
                                .padding(.bottom, 24)
                                .overlay {
                                    // Only show overlay spinner when there IS existing content underneath.
                                    // When nodes is empty, the main ZStack already shows a centered spinner.
                                    if isLoading && !nodes.isEmpty {
                                        ZStack {
                                            Color(nsColor: .windowBackgroundColor).opacity(0.4).edgesIgnoringSafeArea(.all)
                                            ProgressView()
                                        }
                                    }
                                }
                            }
                            .coordinateSpace(name: "hubScroll")
                        }
                    }
                }
                .macServerToolbar(
                    server: currentServer,
                    title: title,
                    canGoBack: !stack.isEmpty || !searchText.isEmpty,
                    isImmersive: isLibraryHome && !homeCarouselEntries.isEmpty,
                    searchText: $searchText,
                    onBack: {
                        if !searchText.isEmpty {
                            searchTask?.cancel()   // prevent stale debounce from re-triggering
                            searchText = ""
                            committedSearchText = ""
                            loadNodes()
                        } else {
                            _ = stack.popLast()
                            if stack.isEmpty {
                                selectedYear = nil
                                selectedGenre = nil
                                availableGenres = []
                                availableYears = []
                            }
                            nodes = []
                            loadNodes()
                        }
                    },
                    onHome: {
                        searchTask?.cancel()   // prevent stale debounce from re-triggering
                        searchText = ""
                        committedSearchText = ""
                        stack.removeAll()
                        selectedYear = nil
                        selectedGenre = nil
                        availableGenres = []
                        availableYears = []
                        nodes = []
                        resumeNodes = []
                        latestNodes = []
                        favoritesNodes = []
                        loadNodes()
                    },
                    onExit: onClose
                ) {
                    HStack(spacing: 6) {
                        if isListCategory {
                            MacDisplayModeMenuPopover(displayMode: displayModeBinding)
                            
                            MacSortMenuPopover(
                                sortOptionRaw: $sortOptionRaw,
                                isSortAscending: $isSortAscending
                            )
                        }

                        MacToolbarButton(
                            systemImage: "arrow.clockwise",
                            title: platformShellString("Refresh"),
                            action: {
                                if isLibraryHome {
                                    restartCarousel()
                                    resumeNodes = []
                                    latestNodes = []
                                    favoritesNodes = []
                                    libraryPreviewNodes = [:]
                                }
                                loadNodes()
                            }
                        )
                        .disabled(isLoading)
                    }
                }
            }
        }
        .onAppear {
            consumeTargetFileIfNeeded()
            // Reload if: (a) no content at all, or
            // (b) on home page but home shelves are empty — this happens when the
            //     user searched (which clears resumeNodes/latestNodes) and exited the
            //     server without pressing Back, then re-entered. The NSHostingController
            //     caches this view so onAppear still fires, but nodes is non-empty
            //     (search results) and the shelf data is lost.
            let homeShelvesStale = isLibraryHome
                && resumeNodes.isEmpty
                && latestNodes.isEmpty
                && favoritesNodes.isEmpty
                && !isLoading
            if nodes.isEmpty || homeShelvesStale { loadNodes() }
            startCarouselIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteFavoriteStateDidChange)) { notification in
            guard let payload = notification.object as? FavoriteStateRefreshPayload,
                  payload.serverId == server.id else { return }
            Task {
                let fNodes = try? await fetchMacFavoriteNodes(server: currentServer)
                await MainActor.run {
                    self.favoritesNodes = fNodes ?? []
                    self.restartCarousel()
                }
            }
        }
        .onDisappear {
            // Only cancel the carousel animation task; do NOT clear selectedLeaf or stack.
            // The NSHostingController caches this view, so when the user returns to this
            // server tab the browsing state (detail page, folder path) must be intact.
            carouselTask?.cancel()
            carouselTask = nil
            isCarouselHovered = false
        }
        .onChange(of: searchText) { newValue in
            searchTask?.cancel()
            // If the field is cleared (native x-button, Back, or Home), immediately
            // restore the committed state and reload home content.
            if newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                committedSearchText = ""
                // Always call loadNodes() here — this is the only way to restore
                // resumeNodes / latestNodes / favoritesNodes when the user clears the
                // search via the native text-field x-button (which doesn't go through
                // onBack / onHome). The extra call when clearing via Back/Home is
                // harmless (just a redundant but idempotent reload).
                loadNodes()
                return
            }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                if !Task.isCancelled {
                    await MainActor.run {
                        committedSearchText = newValue
                        loadNodes()
                    }
                }
            }
        }
        .onChange(of: navManager.targetFileToResolve) { _ in
            consumeTargetFileIfNeeded()
        }
        .onChange(of: sortOptionRaw) { _ in loadNodes() }
        .onChange(of: isSortAscending) { _ in loadNodes() }
        .onChange(of: tabContext.activeSelection) { newSelection in
            if newSelection == .server(server.id) {
                // View was already cached — consume any pending navigation target
                consumeTargetFileIfNeeded()
                // Resume carousel if it was paused when this tab was hidden
                startCarouselIfNeeded()
            } else if case .server(let otherId) = newSelection, otherId != server.id {
                // User navigated to a *different* server — reset this server's state
                // so it returns to its home when visited again.
                selectedLeaf = nil
                stack.removeAll()
            }
            // When switching to non-server tabs (history, favorites, settings, etc.)
            // do nothing: preserve the current detail/folder state so it is intact
            // when the user returns via the sidebar.
        }
    }

    private func consumeTargetFileIfNeeded() {
        guard let targetFile = MacNavigationManager.shared.targetFileToResolve else { return }
        // Only consume if this file belongs to our server
        var belongsHere = false
        if let serverId = targetFile.jellyfinServerId, server.id.uuidString == serverId {
            belongsHere = true
        } else if let host = targetFile.url.host, server.address.lowercased() == host.lowercased() {
            belongsHere = true
        }
        guard belongsHere else { return }
        MacNavigationManager.shared.targetFileToResolve = nil

        if let seriesId = targetFile.seriesId?.nilIfEmpty {
            MacNavigationManager.shared.targetSeasonId = targetFile.seasonId
            MacNavigationManager.shared.targetEpisodeId = targetFile.jellyfinItemId ?? targetFile.id
            let initialNode = MacMediaLibraryNode(
                id: targetFile.jellyfinItemId ?? targetFile.id,
                name: targetFile.name,
                type: targetFile.type,
                isFolder: targetFile.type == .folder,
                remotePath: targetFile.serverPath,
                posterURL: nil,
                backdropURL: nil,
                playbackURL: targetFile.url,
                playbackPositionTicks: targetFile.lastPlayedPosition.map { Int64($0 * 10_000_000) },
                runTimeTicks: targetFile.duration.map { Int64($0 * 10_000_000) },
                seriesId: seriesId,
                seriesName: nil,
                seasonId: targetFile.seasonId
            )
            openNode(initialNode)
        }

        Task {
            do {
                let latestServer = AppNetworkService.shared.savedServers.first(where: { $0.id == server.id }) ?? server
                let activeServer = AppNetworkService.shared.hydratedServer(from: latestServer)
                if let resolved = try await resolveMacMediaTarget(server: activeServer, targetFile: targetFile) {
                    await MainActor.run {
                        MacNavigationManager.shared.targetSeasonId = resolved.seasonId
                        MacNavigationManager.shared.targetEpisodeId = resolved.episodeId
                        selectedLeaf = resolved.node
                    }
                }
            } catch {
                print("Failed to resolve Mac media target for target file: \(error)")
            }
        }
    }

    private func openNode(_ node: MacMediaLibraryNode) {
        var targetNode = node

        if let seriesId = node.seriesId {
            MacNavigationManager.shared.targetSeasonId = node.seasonId
            MacNavigationManager.shared.targetEpisodeId = node.id
            
            let sName = node.seriesName ?? platformShellString("Series")
            let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let posterURL: URL?
            let backdropURL: URL?
            
            if server.type == .plex {
                posterURL = plexImageURL(baseURL: baseURL, key: seriesId, token: server.accessToken)
                backdropURL = plexImageURL(baseURL: baseURL, key: seriesId, token: server.accessToken)
            } else {
                posterURL = URL(string: "\(baseURL)/Items/\(seriesId)/Images/Primary?maxHeight=520&maxWidth=360&quality=90")
                backdropURL = URL(string: "\(baseURL)/Items/\(seriesId)/Images/Backdrop?maxWidth=1920&quality=90")
            }
            
            targetNode = MacMediaLibraryNode(
                id: seriesId,
                name: sName,
                type: .video,
                isFolder: true,
                remotePath: server.type == .plex ? (seriesId.hasPrefix("/") ? (seriesId.hasSuffix("/children") ? seriesId : "\(seriesId)/children") : "/library/metadata/\(seriesId)/children") : nil,
                posterURL: posterURL,
                backdropURL: backdropURL,
                playbackURL: nil,
                collectionType: server.type == .plex ? "show" : "Series"
            )
        } else if (node.collectionType?.lowercased() == "episode" || node.collectionType?.lowercased() == "season") {
            Task {
                let latestServer = AppNetworkService.shared.savedServers.first(where: { $0.id == server.id }) ?? server
                let activeServer = AppNetworkService.shared.hydratedServer(from: latestServer)
                if let fullNode = try? await fetchMacMediaItem(server: activeServer, nodeId: node.id) {
                    if let seriesId = fullNode.seriesId?.nilIfEmpty {
                        await MainActor.run {
                            MacNavigationManager.shared.targetSeasonId = (fullNode.collectionType?.lowercased() == "season") ? fullNode.id : fullNode.seasonId
                            MacNavigationManager.shared.targetEpisodeId = (fullNode.collectionType?.lowercased() == "episode") ? fullNode.id : nil
                            openNode(fullNode)
                        }
                    }
                }
            }
        }

        if targetNode.isFolder {
            if (server.type == .jellyfin || server.type == .emby || server.type == .plex) && !targetNode.isLibraryRoot {
                selectedLeaf = targetNode
            } else {
                stack.append(targetNode)
                searchText = ""
                committedSearchText = ""
                libraryPreviewNodes = [:]
                selectedYear = nil
                selectedGenre = nil
                availableGenres = []
                availableYears = []
                restartCarousel()
                nodes = []
                loadNodes()
            }
        } else {
            selectedLeaf = targetNode
        }
    }

    private func handleCarouselPrimaryAction(_ entry: MacHomeCarouselEntry) {
        if entry.node.isFolder {
            openNode(entry.node)
            return
        }

        playNode(entry.node)
    }

    private func playNode(_ node: MacMediaLibraryNode) {
        guard !node.isFolder else {
            openNode(node)
            return
        }
        let playlist = nodes.filter { !$0.isFolder }.map { videoFile(for: $0) }
        let targetFile = videoFile(for: node)
        let playableFile = downloadCenter.localPlaybackFile(for: targetFile) ?? targetFile
        MacPlayerWindowManager.shared.openPlayer(for: playableFile, playlist: playlist)
    }

    private func videoFile(for node: MacMediaLibraryNode) -> VideoFile {
        macMakeVideoFile(for: node, server: server)
    }

    private func iconName(for node: MacMediaLibraryNode) -> String {
        guard node.isFolder else { return node.type == .audio ? "music.note" : "film.fill" }
        switch node.collectionType?.lowercased() {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "photos": return "photo"
        case "homevideos": return "video"
        default: return "folder.fill"
        }
    }

    private func startCarouselIfNeeded() {
        guard homeCarouselEntries.count > 1, !isCarouselHovered, carouselTask == nil else { return }
        carouselTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 7_000_000_000)
                } catch {
                    return
                }

                await MainActor.run {
                    let count = homeCarouselEntries.count
                    guard !Task.isCancelled, !isCarouselHovered, count > 1 else { return }
                    withAnimation(.easeInOut(duration: 0.28)) {
                        carouselIndex = (carouselIndex + 1) % count
                    }
                }
            }
        }
    }

    private func restartCarousel() {
        carouselTask?.cancel()
        carouselTask = nil
        carouselIndex = 0
        startCarouselIfNeeded()
    }

    private func loadLibraryPreviewNodes(for libraries: [MacMediaLibraryNode], activeServer: ServerConfig) async -> [String: [MacMediaLibraryNode]] {
        await withTaskGroup(of: (String, [MacMediaLibraryNode]).self) { group in
            for library in libraries where library.isFolder {
                group.addTask {
                    do {
                        let previewNodes = try await fetchLibraryPreviewNodes(server: activeServer, library: library, limit: 12)
                        return (library.id, previewNodes)
                    } catch {
                        return (library.id, [])
                    }
                }
            }

            var previews: [String: [MacMediaLibraryNode]] = [:]
            for await result in group {
                previews[result.0] = result.1
            }
            return previews
        }
    }

    private func loadNodes(isPagination: Bool = false) {
        if isPagination {
            guard !isPaginating, hasMoreItems else { return }
            isPaginating = true
        } else {
            isLoading = true
            errorMessage = nil
            currentStartIndex = 0
            hasMoreItems = false
            nodes = []
        }
        let parent = stack.last
        let query = trimmedSearchText
        let baseServer = AppNetworkService.shared.hydratedServer(from: currentServer)
        
        if baseServer.type == .jellyfin || baseServer.type == .emby {
            if parent == nil {
                availableGenres = []
                availableYears = []
                selectedGenre = nil
                selectedYear = nil
            }
        }
        
        let sortBy = sortOptionRaw
        let sortOrder = isSortAscending ? "Ascending" : "Descending"
        
        Task {
            do {
                let activeServer = try await macPreparedMediaLibraryServer(server: baseServer)
                if !query.isEmpty && (activeServer.type == .jellyfin || activeServer.type == .emby) {
                    let searchResults = try await fetchJellyfinSearchNodes(server: activeServer, query: query, parentId: parent?.id)
                    if Task.isCancelled { return }
                    await MainActor.run {
                        self.nodes = searchResults
                        self.hasMoreItems = false
                        self.isPaginating = false
                        self.resumeNodes = []
                        self.latestNodes = []
                        self.favoritesNodes = []
                        self.libraryPreviewNodes = [:]
                        self.isLoading = false
                        self.restartCarousel()
                    }
                } else if parent == nil && query.isEmpty {
                    async let heroEntries = fetchMacJellyfinHeroEntries(server: activeServer)
                    async let rNodes = fetchMacResumeNodes(server: activeServer)
                    async let lNodes = fetchMacLatestNodes(server: activeServer)
                    async let fNodes = fetchMacFavoriteNodes(server: activeServer)
                    async let vNodes = fetchNodes(server: activeServer, parentNode: nil, sortBy: sortBy, sortOrder: sortOrder)

                    let fetchedHero = (try? await heroEntries) ?? []
                    let fetchedV = try await vNodes
                    let fetchedR = (try? await rNodes) ?? []
                    let fetchedL = (try? await lNodes) ?? []
                    let fetchedF = (try? await fNodes) ?? []
                    let previewNodes = await loadLibraryPreviewNodes(for: fetchedV, activeServer: activeServer)
                    Task {
                        await MediaServerSummaryService.shared.refreshSummary(for: activeServer)
                    }
                    if Task.isCancelled { return }
                    await MainActor.run {
                        self.jellyfinHeroEntries = fetchedHero
                        self.resumeNodes = fetchedR
                        self.latestNodes = fetchedL
                        self.favoritesNodes = fetchedF
                        self.nodes = fetchedV
                        self.hasMoreItems = false
                        self.libraryPreviewNodes = previewNodes
                        self.isLoading = false
                        self.restartCarousel()
                    }
                    Task {
                        for libNode in fetchedV {
                            if let realCount = await fetchRealMacLibraryItemCount(server: activeServer, node: libNode) {
                                await MainActor.run {
                                    if let idx = self.nodes.firstIndex(where: { $0.id == libNode.id }) {
                                        self.nodes[idx].itemCount = realCount
                                    }
                                }
                            }
                        }
                    }
                } else {
                    let fetched = try await fetchNodes(server: activeServer, parentNode: parent, startIndex: currentStartIndex, limit: pageSize, sortBy: sortBy, sortOrder: sortOrder, year: selectedYear, genre: selectedGenre)
                    
                    if activeServer.type == .jellyfin || activeServer.type == .emby, parent != nil {
                        // Concurrently fetch dynamic filters when we are inside a library
                        Task {
                            if let options = try? await fetchJellyfinLibraryFilterOptions(server: activeServer, parentId: parent?.id) {
                                if !Task.isCancelled {
                                    await MainActor.run {
                                        self.availableGenres = options.genres
                                        self.availableYears = options.years
                                    }
                                }
                            }
                        }
                    }
                    
                    if Task.isCancelled { return }
                    await MainActor.run {
                        if isPagination {
                            self.nodes.append(contentsOf: fetched)
                        } else {
                            self.nodes = fetched
                        }
                        self.hasMoreItems = fetched.count >= self.pageSize
                        
                        if isPagination {
                            self.currentStartIndex += self.pageSize
                            self.isPaginating = false
                        } else {
                            self.currentStartIndex = self.pageSize
                            self.resumeNodes = []
                            self.latestNodes = []
                            self.favoritesNodes = []
                            self.libraryPreviewNodes = [:]
                            self.isLoading = false
                            self.restartCarousel()
                        }
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    if isPagination {
                        self.isPaginating = false
                    } else {
                        self.nodes = []
                        self.resumeNodes = []
                        self.latestNodes = []
                        self.libraryPreviewNodes = [:]
                        self.errorMessage = error.localizedDescription
                        self.isLoading = false
                        self.restartCarousel()
                    }
                }
            }
        }
    }
}

struct MacHomeCarouselEntry: Identifiable {
    let node: MacMediaLibraryNode
    let sourceTitle: String
    let sourceSystemImageName: String

    var id: String { node.id }
}

private enum MacMediaCardMetrics {
    static let textHeight: CGFloat = 48
    static let portraitWidth: CGFloat = 158
    static let portraitHeight: CGFloat = 237
    static let landscapeWidth: CGFloat = 204
    static let landscapeHeight: CGFloat = 115
    static let heroThumbWidth: CGFloat = 76
    static let heroThumbHeight: CGFloat = 108
}

struct MacServerToolbarModifier<RightActions: View>: ViewModifier {
    let server: ServerConfig
    let title: String
    var centerTitle: String? = nil
    let canGoBack: Bool
    var hideSearchAndExit: Bool = false
    let isImmersive: Bool
    @Binding var searchText: String
    let onBack: () -> Void
    let onHome: () -> Void
    let onExit: () -> Void
    let rightActions: RightActions

    @State private var isSearchExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // Keep a SINGLE stable layout path (no if/else branching at the structural
        // level) so that headerOverlayView is never destroyed when isImmersive
        // toggles between true and false.
        //
        // Keep the native search field and its editor alive as results switch
        // between immersive and non-immersive content.
        VStack(spacing: 0) {
            // Placeholder gap:
            //   • 0     in immersive mode  — content fills to the top edge
            //   • N     in non-immersive   — content is pushed below the header
            Color.clear
                .frame(height: isImmersive ? 0 : MacBrowserToolbarMetrics.totalHeight)
            content
                // Keep safe-area-ignoring backgrounds below the reserved toolbar.
                .clipped()
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            // headerOverlayView is always present here; it is never torn down
            // when isImmersive changes, so search editing stays alive.
            headerOverlayView
                .frame(height: MacBrowserToolbarMetrics.rowHeight)
                .padding(.top, MacBrowserToolbarMetrics.topInset)
                .padding(.bottom, MacBrowserToolbarMetrics.bottomInset)
        }
        .onAppear {
            if !searchText.isEmpty {
                isSearchExpanded = true
            }
        }
        .onChange(of: searchText) { newText in
            if !newText.isEmpty && !isSearchExpanded {
                isSearchExpanded = true
            }
        }
        .onDisappear { isSearchExpanded = false }
        .toolbar {
            // All controls moved to headerOverlayView
        }
    }

    /// 全宽自定义 header：左侧返回/Home + 服务器信息，右侧操作按钮
    @ViewBuilder
    private var headerOverlayView: some View {
        HStack(alignment: .center, spacing: 0) {
            // ── 左侧：导航按钮 或 退出 ──
            if canGoBack || !hideSearchAndExit {
                HStack(spacing: 6) {
                    if canGoBack {
                        MacToolbarButton(
                            systemImage: "chevron.left",
                            title: platformShellString("Back"),
                            action: onBack
                        )

                        MacToolbarButton(
                            systemImage: "house",
                            title: platformShellString("Home"),
                            action: onHome
                        )
                    } else {
                        MacToolbarButton(
                            systemImage: "rectangle.portrait.and.arrow.right",
                            title: platformShellString("Close"),
                            action: onExit
                        )
                    }
                }
                .padding(4)
                .modifier(MacToolbarGlass())
                .padding(.leading, 24)
                .anchorPreference(key: MacToolbarControlBoundsKey.self, value: .bounds) { [.leading: $0] }
            }

            Spacer(minLength: 16)

            // ── 右侧：搜索 + 排序/视图切换等动作 ──
            HStack(spacing: 6) {
                if !hideSearchAndExit {
                    MacExpandableToolbarSearch(text: $searchText, isExpanded: $isSearchExpanded)
                }

                rightActions
            }
            .padding(4)
            .modifier(MacToolbarGlass())
            .padding(.trailing, 24)
            .anchorPreference(key: MacToolbarControlBoundsKey.self, value: .bounds) { [.trailing: $0] }
        }
        .frame(maxWidth: .infinity)
        .modifier(MacToolbarTitlePlacement(title: serverInfoView))
        .padding(.vertical, 4)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isSearchExpanded)
    }

    @ViewBuilder
    private var serverInfoView: some View {
        HStack(spacing: 8) {
            MacServerTypeIcon(type: server.type, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .foregroundColor(.primary)
                HStack(spacing: 4) {
                    Text(server.type.displayName)
                        .font(.system(size: 11, weight: .semibold))
                    Circle()
                        .fill(Color.secondary.opacity(0.42))
                        .frame(width: 2, height: 2)
                    Text(server.fullURL)
                        .font(.system(size: 11))
                        .truncationMode(.middle)
                        .lineLimit(1)
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct MacDisplayModeMenuPopover: View {
    @Binding var displayMode: LibraryDisplayMode
    @State private var isPresented = false

    var body: some View {
        MacToolbarButton(
            systemImage: displayMode.iconName,
            title: platformShellString("Display Mode"),
            action: { isPresented.toggle() }
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(platformShellString("Display Mode"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.top, 6)

                ForEach(LibraryDisplayMode.allCases) { mode in
                    Button(action: {
                        displayMode = mode
                        isPresented = false
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: mode.iconName)
                                .font(.system(size: 14))
                                .frame(width: 18)
                            Text(platformShellString(mode.localizedTitleKey))
                                .font(.subheadline)
                            Spacer(minLength: 12)
                            if displayMode == mode {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .frame(width: 160)
        }
    }
}

struct MacSortMenuPopover: View {
    @Binding var sortOptionRaw: String
    @Binding var isSortAscending: Bool
    var options: [(String, String)] = [("Name", "SortName"), ("Date Added", "DateCreated"), ("Release Date", "PremiereDate"), ("Release Year", "ProductionYear"), ("Rating", "CommunityRating"), ("Resolution", "Resolution"), ("Runtime", "Runtime")]
    var heading = "Sort By"
    @State private var isPresented = false

    var body: some View {
        MacToolbarButton(
            systemImage: "line.3.horizontal.decrease.circle",
            title: platformShellString("Sort"),
            action: { isPresented.toggle() }
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(platformShellString(heading))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                
                ForEach(options, id: \.1) { option in
                    sortButton(title: platformShellString(option.0), option: option.1)
                }

                Divider()
                
                Text(platformShellString("Order"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                
                orderButton(title: platformShellString("Ascending"), ascending: true)
                orderButton(title: platformShellString("Descending"), ascending: false)
            }
            .padding(8)
            .frame(width: 160)
        }
    }
    
    @ViewBuilder
    private func sortButton(title: String, option: String) -> some View {
        MacSortPopoverRow(title: title, isSelected: sortOptionRaw == option) {
            sortOptionRaw = option
            isPresented = false
        }
    }
    
    @ViewBuilder
    private func orderButton(title: String, ascending: Bool) -> some View {
        MacSortPopoverRow(title: title, isSelected: isSortAscending == ascending) {
            isSortAscending = ascending
            isPresented = false
        }
    }
}

private struct MacSortPopoverRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
        )
        .onHover { isHovered = $0 }
    }
}

private struct MacCarouselButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(isHovered ? .white : .white.opacity(0.8))
            .frame(width: 36, height: 36)
            .background(
                Circle()
                    .fill(isHovered
                          ? Color.black.opacity(0.6)
                          : Color.black.opacity(0.36))
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .onHover { isHovered = $0 }
            .macPointerHover()
    }
}

extension View {
    func macServerToolbar<RightActions: View>(
        server: ServerConfig,
        title: String,
        centerTitle: String? = nil,
        canGoBack: Bool,
        hideSearchAndExit: Bool = false,
        isImmersive: Bool = false,
        searchText: Binding<String>,
        onBack: @escaping () -> Void,
        onHome: @escaping () -> Void,
        onExit: @escaping () -> Void,
        @ViewBuilder rightActions: () -> RightActions
    ) -> some View {
        modifier(MacServerToolbarModifier(
            server: server,
            title: title,
            centerTitle: centerTitle,
            canGoBack: canGoBack,
            hideSearchAndExit: hideSearchAndExit,
            isImmersive: isImmersive,
            searchText: searchText,
            onBack: onBack,
            onHome: onHome,
            onExit: onExit,
            rightActions: rightActions()
        ))
    }
}

struct MacServerTypeIcon: View {
    let type: ServerConfig.ServerType
    let size: CGFloat

    var body: some View {
        Group {
            if let nsImage = NSImage(named: type.iconAssetName) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: type.systemIconName)
                    .font(.system(size: size * 0.88, weight: .semibold))
                    .foregroundColor(.accentColor)
                    .frame(width: size, height: size)
            }
        }
    }
}

private struct MacResumeButtonLabel: View {
    let progress: Double
    let playedSeconds: Int?
    let totalSeconds: Int?

    private var fraction: Double { min(max(progress, 0), 1) }

    private func timeText(_ seconds: Int) -> String {
        let value = max(seconds, 0)
        return value >= 3600
            ? String(format: "%d:%02d:%02d", value / 3600, (value % 3600) / 60, value % 60)
            : String(format: "%d:%02d", value / 60, value % 60)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white)
            GeometryReader { geometry in
                Capsule()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: geometry.size.width * fraction)
            }
            .allowsHitTesting(false)

            VStack(spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: "play.fill")
                    Text(platformShellString("Resume")).fontWeight(.bold)
                }
                .font(.headline)

                HStack(spacing: 6) {
                    if let playedSeconds, let totalSeconds, totalSeconds > 0 {
                        Text(timeText(playedSeconds))
                        Text("/")
                        Text(timeText(totalSeconds))
                        Text("·")
                    }
                    Text("\(Int((fraction * 100).rounded()))%")
                        .fontWeight(.semibold)
                }
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundColor(.black.opacity(0.72))
                .lineLimit(1)
            }
            .foregroundColor(.black)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
        }
        .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.6))
        .shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 1)
    }
}

struct MacMediaHeroCarousel: View {
    let server: ServerConfig
    let entries: [MacHomeCarouselEntry]
    @Binding var selectedIndex: Int
    let onPrimaryAction: (MacHomeCarouselEntry) -> Void
    let onOpenDetails: (MacMediaLibraryNode) -> Void
    @ObservedObject private var playbackState = RemotePlaybackStateStore.shared
    var primaryActionTitleOverride: String? = nil

    private var currentEntry: MacHomeCarouselEntry? {
        guard !entries.isEmpty else { return nil }
        return entries[min(max(selectedIndex, 0), entries.count - 1)]
    }

    var body: some View {
        Group {
            if let currentEntry {
                ZStack(alignment: .bottomLeading) {
                    MacRemoteArtworkImage(
                        url: currentEntry.node.backdropURL ?? currentEntry.node.posterURL,
                        placeholderSystemImageName: currentEntry.node.isFolder ? "folder.fill" : "film.fill"
                    )
                    .frame(maxWidth: .infinity, minHeight: 470, maxHeight: 470)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        onOpenDetails(currentEntry.node)
                    }

                    ZStack {
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.black.opacity(0.86),
                                Color.black.opacity(0.48),
                                Color.black.opacity(0.08)
                            ]),
                            startPoint: .leading,
                            endPoint: .trailing
                        )

                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.clear,
                                Color.black.opacity(0.78)
                            ]),
                            startPoint: .center,
                            endPoint: .bottom
                        )
                    }
                    .allowsHitTesting(false)

                    if !currentEntry.node.logoURLs.isEmpty {
                        VStack {
                            HStack {
                                Spacer()
                                MacRemoteLogoImage(urls: currentEntry.node.logoURLs, maxHeight: 75)
                                    .padding(.top, 32)
                                    .padding(.trailing, 96)
                                    .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 3)
                            }
                            Spacer()
                        }
                    }

                    VStack(alignment: .leading, spacing: 13) {
                        Label(currentEntry.sourceTitle, systemImage: currentEntry.sourceSystemImageName)
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.white.opacity(0.76))
                            .lineLimit(1)

                        Text(currentEntry.node.heroTitle)
                            .font(.system(size: 48, weight: .black))
                            .foregroundColor(.white)
                            .lineLimit(2)
                            .minimumScaleFactor(0.70)
                            .frame(maxWidth: 720, alignment: .leading)

                        if let episodeSubtitle = currentEntry.node.heroEpisodeSubtitle {
                            Text(episodeSubtitle)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(.white.opacity(0.88))
                                .lineLimit(2)
                                .frame(maxWidth: 720, alignment: .leading)
                        }

                        if let metadataLine = currentEntry.node.metadataLine, !metadataLine.isEmpty {
                            Text(metadataLine)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                        } else {
                            Text(currentEntry.node.isFolder ? serverSectionSubtitle(for: currentEntry.node) : platformShellString("Video Playback"))
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                        }

                        if let summary = currentEntry.node.summary?.nilIfEmpty {
                            Text(summary)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white.opacity(0.68))
                                .lineSpacing(3)
                                .lineLimit(2)
                                .frame(maxWidth: 640, alignment: .leading)
                        }

                        HStack(spacing: 12) {
                            primaryActionButton(for: currentEntry)
                        }
                    }
                    .padding(.leading, 44)
                    .padding(.bottom, 48)
                    .padding(.top, 60)

                    carouselControls
                        .padding(.trailing, 34)
                        .padding(.bottom, 28)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
                .frame(maxWidth: .infinity, minHeight: 470, maxHeight: 470)
            }
        }
    }

    private let thumbnailPageSize = 6

    private var thumbnailPageCount: Int {
        (entries.count + thumbnailPageSize - 1) / thumbnailPageSize
    }

    private var thumbnailPage: Int {
        min(max(selectedIndex, 0), max(entries.count - 1, 0)) / thumbnailPageSize
    }

    private var visibleThumbnailIndices: Range<Int> {
        let start = thumbnailPage * thumbnailPageSize
        return start..<min(start + thumbnailPageSize, entries.count)
    }

    private var carouselControls: some View {
        VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 12) {
                Button(action: { move(by: -1) }) {
                    Image(systemName: "chevron.left")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(MacCarouselButtonStyle())
                .disabled(entries.count <= 1)
                .opacity(entries.count <= 1 ? 0 : 1)

                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(visibleThumbnailIndices, id: \.self) { index in
                        let entry = entries[index]
                        Button(action: {
                            if selectedIndex == index {
                                onOpenDetails(entry.node)
                            } else {
                                selectedIndex = index
                            }
                        }) {
                            VStack(alignment: .leading, spacing: 6) {
                                MacRemoteArtworkImage(
                                    url: entry.node.posterURL ?? entry.node.backdropURL,
                                    placeholderSystemImageName: entry.node.isFolder ? "folder.fill" : "film.fill"
                                )
                                .frame(width: MacMediaCardMetrics.heroThumbWidth, height: MacMediaCardMetrics.heroThumbHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .stroke(index == selectedIndex ? Color.white : Color.white.opacity(0.16), lineWidth: index == selectedIndex ? 2 : 1)
                                )
                                .shadow(color: .black.opacity(index == selectedIndex ? 0.34 : 0.18), radius: 10, x: 0, y: 5)

                                Text(entry.node.heroTitle)
                                    .font(.caption.weight(index == selectedIndex ? .bold : .medium))
                                    .foregroundColor(index == selectedIndex ? .white : .white.opacity(0.68))
                                    .lineLimit(1)
                                    .frame(width: MacMediaCardMetrics.heroThumbWidth, alignment: .leading)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                .frame(width: CGFloat(min(thumbnailPageSize, entries.count)) * MacMediaCardMetrics.heroThumbWidth
                    + CGFloat(max(min(thumbnailPageSize, entries.count) - 1, 0)) * 10, alignment: .leading)

                Button(action: { move(by: 1) }) {
                    Image(systemName: "chevron.right")
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(MacCarouselButtonStyle())
                .disabled(entries.count <= 1)
                .opacity(entries.count <= 1 ? 0 : 1)
            }
            if thumbnailPageCount > 1 {
                Text("\(thumbnailPage + 1) / \(thumbnailPageCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundColor(.white.opacity(0.68))
            }
        }
    }

    private func move(by offset: Int) {
        guard entries.count > 1 else { return }
        let current = min(max(selectedIndex, 0), entries.count - 1)
        selectedIndex = (current + offset + entries.count) % entries.count
    }

    private func activeProgress(for node: MacMediaLibraryNode) -> PlaybackProgressSnapshot? {
        guard primaryActionTitleOverride == nil, !node.isFolder else { return nil }
        let local = playbackState.snapshot(serverId: server.id, itemId: node.id)
        let progress = RemotePlaybackResumeDecision.fromServerPlaybackState(
            playbackTicks: local?.playbackPositionTicks ?? node.playbackPositionTicks,
            runtimeTicks: node.runTimeTicks, playedPercentage: local?.playedPercentage,
            played: local?.played ?? node.isPlayed).progressSnapshot
        guard let progress, progress.displayedProgress > 0, !progress.isFinished else { return nil }
        return progress
    }

    @ViewBuilder
    private func primaryActionButton(for entry: MacHomeCarouselEntry) -> some View {
        if let progress = activeProgress(for: entry.node) {
            Button(action: { onPrimaryAction(entry) }) {
                let position = playbackState.snapshot(serverId: server.id, itemId: entry.node.id)?.playbackPositionTicks
                    ?? entry.node.playbackPositionTicks
                MacResumeButtonLabel(
                    progress: progress.displayedProgress,
                    playedSeconds: position.map { Int($0 / 10_000_000) },
                    totalSeconds: entry.node.runTimeTicks.map { Int($0 / 10_000_000) }
                )
                .frame(width: 240, height: 58)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        } else {
            Button(action: { onPrimaryAction(entry) }) {
                Label(primaryActionTitleOverride ?? primaryActionTitle(for: entry.node),
                      systemImage: primaryActionTitleOverride != nil ? "info.circle" : (entry.node.isFolder ? "rectangle.stack.fill" : "play.fill"))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private func primaryActionTitle(for node: MacMediaLibraryNode) -> String {
        node.isFolder ? platformShellString("Open") : platformShellString("Play")
    }

    private func serverSectionSubtitle(for node: MacMediaLibraryNode) -> String {
        node.collectionType?.isEmpty == false ? node.collectionType! : platformShellString("My Media")
    }
}

private struct MacFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
                .foregroundColor(isSelected ? .white : (isHovered ? .primary : .secondary))
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
        .macPointerHover()
    }
}

private struct MacSeeAllHoverEffect: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06))
            .cornerRadius(12)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
            .macPointerHover()
    }
}

private struct MacLibraryFilterBar: View {
    @Binding var selectedYear: String?
    @Binding var selectedGenre: String?
    let availableYears: [String]
    let availableGenres: [String]

    /// Show first two rows of chips; overflow goes into a dropdown.
    /// Each row is estimated at ~34pt height; we allow up to 2 visible rows.
    private let maxVisibleRows = 2
    private let chipHeight: CGFloat = 34
    private let chipSpacing: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !availableGenres.isEmpty {
                MacFilterSection(
                    label: platformShellString("Genre"),
                    allTitle: platformShellString("All"),
                    items: availableGenres,
                    selectedItem: selectedGenre,
                    displayName: { platformShellString($0) },
                    onSelect: { selectedGenre = $0 },
                    onSelectAll: { selectedGenre = nil }
                )
            }
            if !availableYears.isEmpty {
                MacFilterSection(
                    label: platformShellString("Year"),
                    allTitle: platformShellString("All"),
                    items: availableYears,
                    selectedItem: selectedYear,
                    displayName: { $0 },
                    onSelect: { selectedYear = $0 },
                    onSelectAll: { selectedYear = nil }
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FilterLayoutResult: Equatable {
    var row1: [String] = []
    var row2: [String] = []
    var overflow: [String] = []
    var totalHeight: CGFloat = 34
}

/// A single filter section that wraps chips into up to 2 rows.
/// If items exceed 2 rows, they are placed in a "More" dropdown.
private struct MacFilterSection: View {
    let label: String
    let allTitle: String
    let items: [String]
    let selectedItem: String?
    let displayName: (String) -> String
    let onSelect: (String) -> Void
    let onSelectAll: () -> Void

    @State private var containerWidth: CGFloat = 0

    private let chipSpacing: CGFloat = 8
    private let rowHeight: CGFloat = 34

    private func estimateWidth(for text: String) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return size.width + 26 // 24 padding + 2 safe margin
    }

    private func computeLayout(width: CGFloat) -> FilterLayoutResult {
        guard width > 50 else { return FilterLayoutResult() }
        
        let availableWidth = width - 50 - 12 // label width (50) + spacing
        var row1: [String] = []
        var row2: [String] = []
        var overflow: [String] = []
        
        var currentX: CGFloat = estimateWidth(for: allTitle) + chipSpacing
        var currentRow = 1
        
        for item in items {
            let itemWidth = estimateWidth(for: displayName(item))
            
            if currentRow == 1 {
                if currentX + itemWidth > availableWidth {
                    currentRow = 2
                    currentX = itemWidth + chipSpacing
                    row2.append(item)
                } else {
                    row1.append(item)
                    currentX += itemWidth + chipSpacing
                }
            } else if currentRow == 2 {
                let isLast = item == items.last
                let moreButtonWidth: CGFloat = 40
                let requiredSpace = itemWidth + (isLast ? 0 : (chipSpacing + moreButtonWidth))
                
                if currentX + requiredSpace > availableWidth {
                    currentRow = 3
                    overflow.append(item)
                } else {
                    row2.append(item)
                    currentX += itemWidth + chipSpacing
                }
            } else {
                overflow.append(item)
            }
        }
        
        let height: CGFloat = currentRow > 1 ? (rowHeight * 2 + chipSpacing) : rowHeight
        return FilterLayoutResult(row1: row1, row2: row2, overflow: overflow, totalHeight: height)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.vertical, 6)
                .frame(width: 50, alignment: .leading)
            
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: containerWidth > 0 ? computeLayout(width: containerWidth).totalHeight : rowHeight)
                .overlay(alignment: .topLeading) {
                    let layout = computeLayout(width: containerWidth)
                    
                    VStack(alignment: .leading, spacing: chipSpacing) {
                        HStack(spacing: chipSpacing) {
                            MacFilterChip(title: allTitle, isSelected: selectedItem == nil, action: onSelectAll)
                            ForEach(layout.row1, id: \.self) { item in
                                MacFilterChip(title: displayName(item), isSelected: selectedItem == item) { onSelect(item) }
                            }
                        }
                        if !layout.row2.isEmpty || !layout.overflow.isEmpty {
                            HStack(spacing: chipSpacing) {
                                ForEach(layout.row2, id: \.self) { item in
                                    MacFilterChip(title: displayName(item), isSelected: selectedItem == item) { onSelect(item) }
                                }
                                if !layout.overflow.isEmpty {
                                    Menu {
                                        ForEach(layout.overflow, id: \.self) { item in
                                            Button(displayName(item)) { onSelect(item) }
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis")
                                            .foregroundColor(.secondary)
                                            .frame(height: 24)
                                    }
                                    .menuStyle(.borderlessButton)
                                    .frame(width: 32)
                                    .padding(.top, 4)
                                }
                            }
                        }
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { containerWidth = geo.size.width }
                            .onChange(of: geo.size.width) { w in containerWidth = w }
                    }
                )
        }
    }
}

struct MacMediaShelfSection<Item: Identifiable, Card: View>: View {
    let title: String
    let systemImageName: String
    var itemCount: Int? = nil
    var onSeeAll: (() -> Void)?
    let items: [Item]
    /// Height of the card artwork, so the paging chevrons center on the artwork
    /// rather than on the whole row (artwork + title/metadata text).
    var artworkHeight: CGFloat? = nil
    let card: (Item) -> Card

    @State private var isHeaderHovered = false

    init(
        title: String,
        systemImageName: String,
        itemCount: Int? = nil,
        onSeeAll: (() -> Void)? = nil,
        items: [Item],
        artworkHeight: CGFloat? = nil,
        @ViewBuilder card: @escaping (Item) -> Card
    ) {
        self.title = title
        self.systemImageName = systemImageName
        self.itemCount = itemCount
        self.onSeeAll = onSeeAll
        self.items = items
        self.artworkHeight = artworkHeight
        self.card = card
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                if let onSeeAll {
                    Button(action: onSeeAll) {
                        MacSectionHeader(title: title, systemImageName: systemImageName, count: itemCount)
                            .foregroundColor(isHeaderHovered ? .accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.1)) {
                            isHeaderHovered = hovering
                        }
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                } else {
                    MacSectionHeader(title: title, systemImageName: systemImageName, count: itemCount)
                }

                Spacer()

                if let onSeeAll {
                    Button(action: onSeeAll) {
                        HStack(spacing: 4) {
                            Text(platformShellString("See All"))
                                .font(.system(size: 11, weight: .medium))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                    }
                    .buttonStyle(.plain)
                    .modifier(MacSeeAllHoverEffect())
                }
            }
            .padding(.horizontal, 24)

            MacHorizontalShelf(items: items, verticalPadding: 8, artworkHeight: artworkHeight, card: card)
        }
    }
}

private struct MacSectionHeader: View {
    let title: String
    let systemImageName: String
    var count: Int? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(title, systemImage: systemImageName)
                .font(.title2.weight(.semibold))
                .labelStyle(.titleAndIcon)
            if let count, count > 0 {
                Text(MediaCountFormatter.formatCount(count))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }
        }
    }
}

private struct MacPortraitMediaGrid: View {
    let nodes: [MacMediaLibraryNode]
    let columns: [GridItem]
    let onOpen: (MacMediaLibraryNode) -> Void
    var server: ServerConfig? = nil
    var onPlay: ((MacMediaLibraryNode) -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(nodes) { node in
                MacPortraitMediaCard(
                    node: node,
                    action: {
                        onOpen(node)
                    },
                    server: server,
                    onPlay: (node.isFolder || onPlay == nil) ? nil : { onPlay?(node) }
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }
}

private struct MacLandscapeMediaGrid: View {
    let nodes: [MacMediaLibraryNode]
    let columns: [GridItem]
    let onOpen: (MacMediaLibraryNode) -> Void
    var server: ServerConfig? = nil
    var onPlay: ((MacMediaLibraryNode) -> Void)? = nil

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(nodes) { node in
                MacLandscapeMediaCard(
                    node: node,
                    action: {
                        onOpen(node)
                    },
                    server: server,
                    onPlay: (node.isFolder || onPlay == nil) ? nil : { onPlay?(node) }
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
    }
}

private struct MacRemoteArtworkImage: View {
    let url: URL?
    let placeholderSystemImageName: String

    var body: some View {
        Group {
            if let url {
                MacCachedAsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        placeholder.overlay(ProgressView())
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.secondary.opacity(0.28),
                    Color.secondary.opacity(0.10)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: placeholderSystemImageName)
                .font(.system(size: 44, weight: .semibold))
                .foregroundColor(.secondary.opacity(0.78))
        }
    }
}

private struct MacRemoteLogoImage: View {
    let urls: [URL]
    var maxHeight: CGFloat = 75

    init(url: URL?, maxHeight: CGFloat = 75) {
        self.urls = url != nil ? [url!] : []
        self.maxHeight = maxHeight
    }

    init(urls: [URL], maxHeight: CGFloat = 75) {
        self.urls = urls
        self.maxHeight = maxHeight
    }

    var body: some View {
        Group {
            if !urls.isEmpty {
                MacCachedAsyncImage(urls: urls) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: maxHeight, alignment: .leading)
                    case .failure, .empty:
                        Color.clear
                            .frame(width: 1, height: maxHeight)
                    }
                }
            }
        }
    }
}

private struct MacLibraryCard: View {
    let node: MacMediaLibraryNode
    var previewNodes: [MacMediaLibraryNode] = []
    let action: () -> Void
    
    @State private var isHovered = false

    private var computedImageURL: URL? {
        if let url = previewNodes.compactMap({ $0.backdropURL }).first { return url }
        if let url = previewNodes.compactMap({ $0.posterURL }).first { return url }
        if let url = node.backdropURL { return url }
        if let url = node.posterURL { return url }
        return nil
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    if let imageURL = computedImageURL {
                        MacCachedAsyncImage(url: imageURL) { phase in
                            switch phase {
                            case .empty:
                                ZStack {
                                    fallbackGradient
                                    ProgressView()
                                }
                            case .success(let image):
                                image.resizable().scaledToFill()
                            case .failure:
                                fallbackIcon
                            }
                        }
                    } else {
                        fallbackIcon
                    }
                }
                .frame(width: MacMediaCardMetrics.landscapeWidth, height: MacMediaCardMetrics.landscapeHeight)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(isHovered ? 0.22 : 0.0), lineWidth: isHovered ? 2 : 0)
                )
                .scaleEffect(isHovered ? 1.04 : 1.0)
                .shadow(color: Color.black.opacity(isHovered ? 0.25 : 0.0), radius: isHovered ? 8 : 0, x: 0, y: 4)
                .zIndex(isHovered ? 1 : 0)

                VStack(alignment: .leading, spacing: 2) {
                    Text(macLineBreakableTitle(node.name))
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(isHovered ? .accentColor : .primary)
                        .lineLimit(1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .layoutPriority(1)

                    if let count = node.itemCount, count > 0 {
                        Text(MediaCountFormatter.format(count: count, libraryType: node.jellyfinLibraryType))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .macPointerHover()
    }

    private var fallbackIcon: some View {
        ZStack {
            fallbackGradient
            Image(systemName: iconName)
                .font(.system(size: 44))
                .foregroundColor(.white.opacity(0.9))
        }
    }

    private var fallbackGradient: LinearGradient {
        let type = node.collectionType?.lowercased() ?? ""
        switch type {
        case "movies":
            return LinearGradient(
                colors: [Color(red: 0.18, green: 0.25, blue: 0.46), Color(red: 0.08, green: 0.12, blue: 0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "tvshows", "shows":
            return LinearGradient(
                colors: [Color(red: 0.24, green: 0.34, blue: 0.63), Color(red: 0.13, green: 0.18, blue: 0.34)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "music":
            return LinearGradient(
                colors: [Color(red: 0.27, green: 0.38, blue: 0.30), Color(red: 0.12, green: 0.18, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "photos":
            return LinearGradient(
                colors: [Color(red: 0.44, green: 0.29, blue: 0.18), Color(red: 0.20, green: 0.13, blue: 0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "collections", "boxsets":
            return LinearGradient(
                colors: [Color(red: 0.32, green: 0.25, blue: 0.49), Color(red: 0.14, green: 0.10, blue: 0.24)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "playlists":
            return LinearGradient(
                colors: [Color(red: 0.18, green: 0.35, blue: 0.43), Color(red: 0.08, green: 0.16, blue: 0.20)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [Color(red: 0.24, green: 0.24, blue: 0.28), Color(red: 0.11, green: 0.11, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var iconName: String {
        if !node.isFolder { return "film.fill" }
        switch node.collectionType?.lowercased() {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "photos": return "photo"
        case "homevideos": return "video"
        default: return "folder.fill"
        }
    }
}

private struct MacLandscapeMediaCard: View {
    let node: MacMediaLibraryNode
    let action: (() -> Void)?
    var server: ServerConfig? = nil
    var onPlay: (() -> Void)? = nil
    var onDownload: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        let effectiveOnPlay = node.isFolder ? nil : onPlay
        ZStack(alignment: .topLeading) {
            if let action = action {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }

            if isHovered, let playAction = effectiveOnPlay {
                MacPosterHoverPlayOverlay(
                    isCardHovered: isHovered,
                    onPlay: playAction,
                    buttonSize: min(MacMediaCardMetrics.landscapeWidth * 0.3, 44),
                    cornerRadius: 10
                )
                .frame(width: MacMediaCardMetrics.landscapeWidth, height: MacMediaCardMetrics.landscapeHeight)
            }
        }
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .macPointerHover()
        .zIndex(isHovered ? 1 : 0)
        .modifier(MacMediaContextMenuModifier(node: node, server: server, onPlay: effectiveOnPlay, onDownload: onDownload))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            posterView
                .frame(width: MacMediaCardMetrics.landscapeWidth, height: MacMediaCardMetrics.landscapeHeight)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let progressTicks = node.playbackPositionTicks, let runTimeTicks = node.runTimeTicks, progressTicks > 0, runTimeTicks > 0 {
                        MacMediaPlaybackProgressBadge(
                            progress: Double(progressTicks) / Double(runTimeTicks),
                            systemImageName: "play.fill",
                            diameter: 18
                        )
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                    } else if node.isPlayed {
                        // nothing for fully played
                    } else if !node.isFolder {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let rating = node.communityRating, rating > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                                .font(.system(size: 10, weight: .bold))
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.65))
                        .clipShape(Capsule())
                        .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if node.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.system(size: 14))
                            .padding(8)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(isHovered ? 0.22 : 0.0), lineWidth: 1.5)
                )
                .shadow(color: Color.black.opacity(isHovered ? 0.25 : 0.0), radius: isHovered ? 8 : 0, x: 0, y: isHovered ? 4 : 0)

            VStack(alignment: .leading, spacing: 0) {
                Text(macLineBreakableTitle(node.name))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(isHovered ? .accentColor : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: MacMediaCardMetrics.landscapeWidth, alignment: .topLeading)
                    .layoutPriority(1)
                
                if let fullMeta = node.metadataLine, !fullMeta.isEmpty {
                    let displayMeta = fullMeta.components(separatedBy: " · ").prefix(3).joined(separator: " · ")
                    Text(displayMeta)
                        .font(.caption2)
                        .foregroundColor(isHovered ? .primary.opacity(0.8) : .secondary.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: MacMediaCardMetrics.landscapeWidth, alignment: .topLeading)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .frame(height: MacMediaCardMetrics.textHeight, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var posterView: some View {
        if let posterURL = node.posterURL {
            MacCachedAsyncImage(url: posterURL) { phase in
                switch phase {
                case .empty: ProgressView()
                case .success(let image): image.resizable().scaledToFill()
                case .failure: placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: node.isFolder ? "folder.fill" : "film.fill")
                .font(.title)
                .foregroundColor(.secondary)
        }
    }
}

#if os(macOS)
func showMacConfirmationAlert(
    title: String,
    message: String,
    confirmTitle: String = platformShellString("Delete"),
    isDestructive: Bool = true,
    onConfirm: @escaping () -> Void
) {
    DispatchQueue.main.async {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = isDestructive ? .critical : .informational
        let confirmBtn = alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: platformShellString("Cancel"))
        if isDestructive {
            confirmBtn.hasDestructiveAction = true
        }
        if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first(where: { $0.isVisible }) {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    onConfirm()
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                onConfirm()
            }
        }
    }
}
#endif

private struct MacMediaContextMenuModifier: ViewModifier {
    let node: MacMediaLibraryNode
    let server: ServerConfig?
    let onPlay: (() -> Void)?
    let onDownload: (() -> Void)?

    @AppStorage("allowMediaServerDeletion") private var allowMediaServerDeletion = false
    @State private var isDeleted = false
    @State private var isDeleting = false
    @State private var isFavorite: Bool
    @State private var isPlayed: Bool
    @State private var toastMessage: String? = nil

    private var isEpisodeNode: Bool {
        if node.collectionType?.caseInsensitiveCompare("Episode") == .orderedSame {
            return true
        }
        if node.seasonId != nil {
            return true
        }
        if node.seriesId != nil && node.type == .video {
            return true
        }
        return false
    }

    init(node: MacMediaLibraryNode, server: ServerConfig?, onPlay: (() -> Void)?, onDownload: (() -> Void)?) {
        self.node = node
        self.server = server
        self.onPlay = onPlay
        self.onDownload = onDownload
        self._isFavorite = State(initialValue: node.isFavorite)
        self._isPlayed = State(initialValue: node.isPlayed)
    }

    private var effectivePlayAction: (() -> Void)? {
        if let onPlay = onPlay {
            return onPlay
        }
        if !node.isFolder, let server = server {
            return {
                let file = macMakeVideoFile(for: node, server: server)
                let playableFile = DownloadCenterService.shared.localPlaybackFile(for: file) ?? file
                MacPlayerWindowManager.shared.openPlayer(for: playableFile, playlist: [playableFile])
            }
        }
        return nil
    }

    @MainActor
    private func performOpenInAnotherApp() {
        guard let server = server else { return }
        let targetFile = macMakeVideoFile(for: node, server: server)
        if let localFile = DownloadCenterService.shared.localPlaybackFile(for: targetFile),
           FileManager.default.fileExists(atPath: localFile.url.path) {
            MacSharingService.openInAnotherApp(url: localFile.url)
            return
        }
        if let playbackURL = node.playbackURL {
            MacSharingService.openInAnotherApp(url: playbackURL)
        } else if let remotePath = node.remotePath, let url = URL(string: remotePath), url.scheme != nil {
            MacSharingService.openInAnotherApp(url: url)
        }
    }

    @MainActor
    private func performShare() {
        guard let server = server else { return }
        let targetFile = macMakeVideoFile(for: node, server: server)
        if let localFile = DownloadCenterService.shared.localPlaybackFile(for: targetFile),
           FileManager.default.fileExists(atPath: localFile.url.path) {
            MacSharingService.share(items: [localFile.url])
            return
        }
        if let playbackURL = node.playbackURL {
            MacSharingService.share(items: [playbackURL])
        } else if let remotePath = node.remotePath, let url = URL(string: remotePath), url.scheme != nil {
            MacSharingService.share(items: [url])
        }
    }

    func body(content: Content) -> some View {
        if isDeleted {
            EmptyView()
        } else {
            content
                .overlay {
                    if isDeleting {
                        ZStack {
                            Color.black.opacity(0.4)
                            ProgressView()
                                .controlSize(.small)
                        }
                        .cornerRadius(10)
                    }
                }
                .contextMenu {
                    if let playAction = effectivePlayAction, !node.isFolder {
                        Button(platformShellString("Play")) { playAction() }
                    }
                    if let onDownload = onDownload, !node.isFolder {
                        Button(platformShellString("Download")) { onDownload() }
                    }
                    
                    if let server = server, !node.isFolder {
                        Divider()
                        
                        Button(platformShellString("Open in Another App")) {
                            performOpenInAnotherApp()
                        }

                        if let playbackURL = node.playbackURL {
                            Button(platformShellString("Copy Stream Link")) {
                                MacSharingService.copyToClipboard(playbackURL.absoluteString)
                            }
                        }
                        
                        Button(platformShellString("Share")) {
                            performShare()
                        }
                    }

                    if let server = server, (server.type == .jellyfin || server.type == .emby || server.type == .plex) {
                        Divider()
                        
                        if !isEpisodeNode {
                            Button(action: { Task { await toggleFavorite(server: server) } }) {
                                Text(isFavorite ? platformShellString("Remove from Favorites") : platformShellString("Add to Favorites"))
                            }
                        }

                        if node.type == .video || node.type == .audio {
                            Button(action: { Task { await togglePlayed(server: server) } }) {
                                Text(isPlayed ? platformShellString("Mark as Unplayed") : platformShellString("Mark as Played"))
                            }
                        }

                        if allowMediaServerDeletion && (node.type == .video || node.type == .audio || node.isFolder) {
                            Divider()
                            Button(role: .destructive) {
                                #if os(macOS)
                                showMacConfirmationAlert(
                                    title: platformShellString("Delete from Server"),
                                    message: String(format: platformShellString("Are you sure you want to delete \"%@\" from the server? This cannot be undone."), node.name),
                                    confirmTitle: platformShellString("Delete"),
                                    isDestructive: true
                                ) {
                                    Task { await deleteItem(server: server) }
                                }
                                #endif
                            } label: {
                                Text(platformShellString("Delete from Server"))
                            }
                        }
                    }
                }
                .floatingToast(message: $toastMessage)
        }
    }

    private func toggleFavorite(server: ServerConfig) async {
        guard let token = server.accessToken, !token.isEmpty else { return }
        let newFavoriteState = !isFavorite
        do {
            let rawBaseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            switch server.type {
            case .jellyfin, .emby:
                guard let userId = server.userId else { return }
                guard let rawURL = URL(string: "\(rawBaseURL)/Users/\(userId)/FavoriteItems/\(node.id)") else { return }
                let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
                var request = URLRequest(url: url)
                request.httpMethod = newFavoriteState ? "POST" : "DELETE"
                applyMediaLibraryHeaders(to: &request, server: server)
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResp = response as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
                    throw NSError(domain: "FavoriteError", code: httpResp.statusCode)
                }
            case .plex:
                break
            default:
                break
            }

            let file = macMakeVideoFile(for: node, server: server)
            let folderPath = "mac-server-\(server.id.uuidString)"
            let isCurrentlyFav = FavoriteService.shared.isFavorite(file: file, folderPath: folderPath)
            if newFavoriteState != isCurrentlyFav {
                FavoriteService.shared.toggleFavorite(file: file, folderPath: folderPath)
            }

            await MainActor.run {
                isFavorite = newFavoriteState
                toastMessage = platformShellString(newFavoriteState ? "Added to Favorites" : "Removed from Favorites")
            }
        } catch {
            print("Failed to toggle favorite: \(error)")
            await MainActor.run {
                toastMessage = platformShellString("Failed")
            }
        }
    }

    private func togglePlayed(server: ServerConfig) async {
        guard let token = server.accessToken, !token.isEmpty else { return }
        let nextPlayed = !isPlayed
        do {
            let rawBaseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            switch server.type {
            case .jellyfin, .emby:
                guard let userId = server.userId else { return }
                guard let rawURL = URL(string: "\(rawBaseURL)/Users/\(userId)/PlayedItems/\(node.id)") else { return }
                let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
                var request = URLRequest(url: url)
                request.httpMethod = nextPlayed ? "POST" : "DELETE"
                applyMediaLibraryHeaders(to: &request, server: server)
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResp = response as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
                    throw NSError(domain: "PlayedError", code: httpResp.statusCode)
                }
            case .plex:
                let path = nextPlayed ? "/:/scrobble" : "/:/unscrobble"
                guard let rawURL = URL(string: "\(rawBaseURL)\(path)?key=\(node.id)&identifier=com.plexapp.plugins.library") else { return }
                let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
                var request = URLRequest(url: url)
                request.httpMethod = "GET"
                applyMediaLibraryHeaders(to: &request, server: server)
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResp = response as? HTTPURLResponse, !(200...299).contains(httpResp.statusCode) {
                    throw NSError(domain: "PlexPlayedError", code: httpResp.statusCode)
                }
            default:
                break
            }

            await MainActor.run {
                isPlayed = nextPlayed
                toastMessage = platformShellString(nextPlayed ? "Marked as Played" : "Marked as Unplayed")
            }
        } catch {
            print("Failed to toggle played: \(error)")
            await MainActor.run {
                toastMessage = platformShellString("Failed")
            }
        }
    }

    private func deleteItem(server: ServerConfig) async {
        guard let token = server.accessToken, !token.isEmpty else { return }
        await MainActor.run { isDeleting = true }
        defer {
            Task { @MainActor in isDeleting = false }
        }

        do {
            let rawBaseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let endpoint: String
            switch server.type {
            case .plex:
                endpoint = "\(rawBaseURL)/library/metadata/\(node.id)"
            case .jellyfin, .emby:
                endpoint = "\(rawBaseURL)/Items/\(node.id)"
            default:
                return
            }

            guard let rawURL = URL(string: endpoint) else { return }
            let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            applyMediaLibraryHeaders(to: &request, server: server)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("Failed to delete item from server: status code \(statusCode)")
                await MainActor.run {
                    toastMessage = platformShellString("Failed to delete from server")
                }
                return
            }

            if let fav = FavoriteService.shared.favorites.first(where: { $0.file.jellyfinItemId == node.id }) {
                FavoriteService.shared.remove(fav)
            }
            if let h = HistoryService.shared.remoteHistory.first(where: { $0.jellyfinItemId == node.id }) {
                HistoryService.shared.removeFromHistory(h)
            }

            await MainActor.run {
                isDeleted = true
                toastMessage = platformShellString("Deleted")
                NotificationCenter.default.post(
                    name: .remoteItemDidDelete,
                    object: RemoteItemDeletePayload(serverId: server.id, itemId: node.id)
                )
            }
        } catch {
            print("Failed to delete item: \(error.localizedDescription)")
            await MainActor.run {
                toastMessage = platformShellString("Failed to delete from server")
            }
        }
    }
}

private struct MacPosterHoverPlayOverlay: View {
    let isCardHovered: Bool
    let onPlay: (() -> Void)?
    var buttonSize: CGFloat = 44
    var cornerRadius: CGFloat = 10

    @State private var isPlayButtonHovered = false

    var body: some View {
        if isCardHovered, let onPlay = onPlay {
            ZStack {
                Color.black.opacity(0.35)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .allowsHitTesting(false)

                Button(action: {
                    onPlay()
                }) {
                    ZStack {
                        Circle()
                            .fill(isPlayButtonHovered ? Color(red: 0.0, green: 0.64, blue: 0.86) : Color.black.opacity(0.65))
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(isPlayButtonHovered ? 0.7 : 0.35), lineWidth: 1.2)
                            )

                        Image(systemName: "play.fill")
                            .font(.system(size: buttonSize * 0.42, weight: .bold))
                            .foregroundColor(.white)
                            .offset(x: 1.5)
                    }
                    .frame(width: buttonSize, height: buttonSize)
                    .scaleEffect(isPlayButtonHovered ? 1.08 : 1.0)
                    .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 3)
                    .contentShape(Circle())
                }
                .buttonStyle(BorderlessButtonStyle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.12)) {
                        isPlayButtonHovered = hovering
                    }
                }
                .macPointerHover()
            }
            .transition(.opacity.animation(.easeInOut(duration: 0.15)))
        }
    }
}

private struct MacPortraitMediaCard: View {
    let node: MacMediaLibraryNode
    var width: CGFloat = MacMediaCardMetrics.portraitWidth
    var height: CGFloat = MacMediaCardMetrics.portraitHeight
    let action: (() -> Void)?
    var server: ServerConfig? = nil
    var onPlay: (() -> Void)? = nil
    var onDownload: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        let effectiveOnPlay = node.isFolder ? nil : onPlay
        ZStack(alignment: .topLeading) {
            if let action = action {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
            } else {
                content
            }

            if isHovered, let playAction = effectiveOnPlay {
                MacPosterHoverPlayOverlay(
                    isCardHovered: isHovered,
                    onPlay: playAction,
                    buttonSize: min(width * 0.32, 44),
                    cornerRadius: 10
                )
                .frame(width: width, height: height)
            }
        }
        .scaleEffect(isHovered ? 1.05 : 1.0)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .macPointerHover()
        .zIndex(isHovered ? 1 : 0)
        .modifier(MacMediaContextMenuModifier(node: node, server: server, onPlay: effectiveOnPlay, onDownload: onDownload))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            posterView
                .frame(width: width, height: height)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomTrailing) {
                    if let progressTicks = node.playbackPositionTicks, let runTimeTicks = node.runTimeTicks, progressTicks > 0, runTimeTicks > 0 {
                        MacMediaPlaybackProgressBadge(
                            progress: Double(progressTicks) / Double(runTimeTicks),
                            systemImageName: "play.fill",
                            diameter: 18
                        )
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                        .allowsHitTesting(false)
                    } else if node.isPlayed {
                        // nothing for fully played
                    } else if !node.isFolder {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                            .padding(8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let rating = node.communityRating, rating > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .foregroundColor(.yellow)
                                .font(.system(size: 10, weight: .bold))
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.65))
                        .clipShape(Capsule())
                        .padding(6)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if node.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.system(size: 14))
                            .padding(8)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary.opacity(isHovered ? 0.22 : 0.0), lineWidth: 1.5)
                )
                .shadow(color: Color.black.opacity(isHovered ? 0.25 : 0.0), radius: isHovered ? 8 : 0, x: 0, y: isHovered ? 4 : 0)

            VStack(alignment: .leading, spacing: 0) {
                Text(macLineBreakableTitle(node.name))
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(isHovered ? .accentColor : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(width: width, alignment: .topLeading)
                    .layoutPriority(1)
                
                if let fullMeta = node.metadataLine, !fullMeta.isEmpty {
                    let displayMeta = fullMeta.components(separatedBy: " · ").prefix(3).joined(separator: " · ")
                    Text(displayMeta)
                        .font(.caption2)
                        .foregroundColor(isHovered ? .primary.opacity(0.8) : .secondary.opacity(0.8))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(width: width, alignment: .topLeading)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .frame(height: MacMediaCardMetrics.textHeight, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var posterView: some View {
        if let posterURL = node.posterURL {
            MacCachedAsyncImage(url: posterURL) { phase in
                switch phase {
                case .empty: ProgressView()
                case .success(let image): image.resizable().scaledToFill()
                case .failure: placeholder
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Color.secondary.opacity(0.12)
            Image(systemName: node.isFolder ? "folder.fill" : "film.fill")
                .font(.title)
                .foregroundColor(.secondary)
        }
    }
}

struct MacMediaPerson: Identifiable {
    let id: String
    let name: String
    let role: String?
    let primaryImageURL: URL?
}


enum MacDetailTarget: Identifiable, Hashable {
    case node(MacMediaLibraryNode, playlist: [VideoFile]?)
    case person(MacMediaPerson)
    
    var id: String {
        switch self {
        case .node(let n, _): return "node_\(n.id)"
        case .person(let p): return "person_\(p.id)"
        }
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: MacDetailTarget, rhs: MacDetailTarget) -> Bool {
        lhs.id == rhs.id
    }
}

struct MacMediaDetailStackView: View {
    let server: ServerConfig
    let rootNode: MacMediaLibraryNode
    var onBackToHub: () -> Void
    var onHome: () -> Void
    var onExit: () -> Void
    
    @State private var stack: [MacDetailTarget] = []
    
    var body: some View {
        if let target = stack.last {
            detailView(for: target, isRoot: false)
        } else {
            detailView(for: .node(rootNode, playlist: nil), isRoot: true)
        }
    }
    
    @ViewBuilder
    private func detailView(for target: MacDetailTarget, isRoot: Bool) -> some View {
        switch target {
        case .node(let node, let playlist):
            MacMediaNodeDetailView(
                server: server,
                node: node,
                playlist: playlist,
                onBack: isRoot ? onBackToHub : { _ = stack.popLast() },
                onHome: onHome,
                onExit: onExit,
                onPushNode: { n, p in stack.append(.node(n, playlist: p)) },
                onPushPerson: { p in stack.append(.person(p)) }
            )
            .id(target.id)
        case .person(let person):
            MacMediaPersonDetailView(
                server: server,
                person: person,
                onBack: { _ = stack.popLast() },
                onHome: onHome,
                onExit: onExit,
                onPushNode: { n, p in stack.append(.node(n, playlist: p)) }
            )
            .id(target.id)
        }
    }
}

private struct MacMediaPersonDetailView: View {
    let server: ServerConfig
    let person: MacMediaPerson
    var onBack: (() -> Void)? = nil
    var onHome: (() -> Void)? = nil
    var onExit: (() -> Void)? = nil
    var onPushNode: ((MacMediaLibraryNode, [VideoFile]?) -> Void)? = nil
    
    @Environment(\.dismiss) private var dismiss
    @State private var items: [MacMediaLibraryNode] = []
    @State private var isLoading = false
    @State private var biography: String?
    @State private var birthDate: String?
    @State private var deathDate: String?
    @State private var placeOfBirth: String?
    
    @State private var sortOptionRaw: String = "SortName"
    @State private var isSortAscending: Bool = true
    
    private let columns = [
        GridItem(.adaptive(minimum: MacMediaCardMetrics.portraitWidth, maximum: MacMediaCardMetrics.portraitWidth), spacing: 20, alignment: .top)
    ]
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 24) {
                    MacRemoteArtworkImage(url: person.primaryImageURL, placeholderSystemImageName: "person.fill")
                        .frame(width: 140, height: 140)
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text(person.name)
                            .font(.system(size: 36, weight: .bold))
                            .foregroundColor(.primary)
                        if let role = person.role {
                            Text(role)
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                        
                        if birthDate != nil || placeOfBirth != nil || deathDate != nil {
                            VStack(alignment: .leading, spacing: 4) {
                                if let b = birthDate {
                                    Text("\(platformShellString("Born:")) \(b)")
                                }
                                if let p = placeOfBirth {
                                    Text("\(platformShellString("Birthplace:")) \(p)")
                                }
                                if let d = deathDate {
                                    Text("\(platformShellString("Died:")) \(d)")
                                }
                            }
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, 44)
                .padding(.top, 44)
                
                if let bio = biography, !bio.isEmpty {
                    Text(bio)
                        .font(.body)
                        .foregroundColor(.primary.opacity(0.85))
                        .padding(.horizontal, 44)
                        .padding(.top, 8)
                }
                
                if isLoading {
                    ProgressView()
                        .padding(.horizontal, 44)
                        .padding(.top, 24)
                } else if !items.isEmpty {
                    Text(platformShellString("Works"))
                        .font(.title2.weight(.semibold))
                        .padding(.horizontal, 44)
                        .padding(.top, 24)
                    
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
                        ForEach(items) { item in
                            MacPortraitMediaCard(
                                node: item,
                                action: {
                                    if let onPushNode {
                                        onPushNode(item, nil)
                                    }
                                },
                                server: server,
                                onPlay: item.isFolder ? nil : { macPlayNode(item, server: server) }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 16)
                    .padding(.bottom, 44)
                } else {
                    Text(platformShellString("No works found"))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 44)
                        .padding(.top, 24)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            isLoading = true
            
            // Fire detail fetch concurrently
            Task {
                do {
                    let latestServer = AppNetworkService.shared.savedServers.first(where: { $0.id == server.id }) ?? server
                    let activeServer = AppNetworkService.shared.hydratedServer(from: latestServer)
                    if let userId = try await resolvedMediaLibraryUserId(server: activeServer) {
                        let baseURL = activeServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        
                        // Fetch Details
                        var dComponents = URLComponents(string: "\(baseURL)/Users/\(userId)/Items/\(person.id)")
                        dComponents?.queryItems = [
                            URLQueryItem(name: "Fields", value: "Overview,PremiereDate,EndDate,ProductionLocations")
                        ]
                        if let rawDUrl = dComponents?.url {
                            let dUrl = RuntimeNetworkAddressResolver.runtimeURL(from: rawDUrl)
                            var dReq = URLRequest(url: dUrl)
                            applyMediaLibraryHeaders(to: &dReq, server: activeServer)
                            if let (dData, dResp) = try? await URLSession.shared.data(for: dReq),
                               let dHttp = dResp as? HTTPURLResponse, (200...299).contains(dHttp.statusCode),
                               let dJson = try? JSONSerialization.jsonObject(with: dData) as? [String: Any] {
                                
                                await MainActor.run {
                                    if let overview = dJson["Overview"] as? String { biography = overview.trimmingCharacters(in: .whitespacesAndNewlines) }
                                    if let pd = dJson["PremiereDate"] as? String { birthDate = String(pd.prefix(10)) }
                                    if let ed = dJson["EndDate"] as? String { deathDate = String(ed.prefix(10)) }
                                    if let locs = dJson["ProductionLocations"] as? [String], !locs.isEmpty { placeOfBirth = locs.joined(separator: ", ") }
                                }
                            }
                        }
                    }
                } catch {
                    print("Failed to fetch person details: \(error)")
                }
            }
            await loadWorks()
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .hideNavBack()
        .macServerToolbar(
            server: server,
            title: person.name,
            canGoBack: true,
            hideSearchAndExit: true,
            isImmersive: false,
            searchText: .constant(""),
            onBack: { if let onBack { onBack() } else { dismiss() } },
            onHome: { 
                onHome?() 
                if onBack == nil { dismiss() }
            },
            onExit: { onExit?() }
        ) {
            MacSortMenuPopover(sortOptionRaw: $sortOptionRaw, isSortAscending: $isSortAscending)
        }
        .onChange(of: sortOptionRaw) { _ in Task { await loadWorks() } }
        .onChange(of: isSortAscending) { _ in Task { await loadWorks() } }
    }
    
    @MainActor
    private func loadWorks() async {
        isLoading = true
        do {
            let latestServer = AppNetworkService.shared.savedServers.first(where: { $0.id == server.id }) ?? server
            let activeServer = AppNetworkService.shared.hydratedServer(from: latestServer)
            if let userId = try await resolvedMediaLibraryUserId(server: activeServer) {
                let baseURL = activeServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                
                // Fetch Works
                var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items")
                let sortOrder = isSortAscending ? "Ascending" : "Descending"
                components?.queryItems = [
                    URLQueryItem(name: "PersonIds", value: person.id),
                    URLQueryItem(name: "Recursive", value: "true"),
                    URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode"),
                    URLQueryItem(name: "Fields", value: macJellyfinItemFields),
                    URLQueryItem(name: "Limit", value: "60"),
                    URLQueryItem(name: "SortBy", value: sortOptionRaw),
                    URLQueryItem(name: "SortOrder", value: sortOrder)
                ]
                if let rawURL = components?.url {
                    let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
                    var request = URLRequest(url: url)
                    applyMediaLibraryHeaders(to: &request, server: activeServer)
                    let (data, response) = try await URLSession.shared.data(for: request)
                    if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
                       let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let elements = json["Items"] as? [[String: Any]] {
                        items = parseJellyfinItems(elements, baseURL: baseURL, server: activeServer)
                    }
                }
            }
        } catch {
            print("Failed to fetch works: \(error)")
        }
        isLoading = false
    }
}

private struct MacMediaNodeDetailView: View {
    let server: ServerConfig
    let node: MacMediaLibraryNode
    var playlist: [VideoFile]? = nil
    var onBack: (() -> Void)? = nil
    var onHome: (() -> Void)? = nil
    var onExit: (() -> Void)? = nil
    var onPushNode: ((MacMediaLibraryNode, [VideoFile]?) -> Void)? = nil
    var onPushPerson: ((MacMediaPerson) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared

    /// The node actually rendered by this view. Starts as the passed-in `node` and
    /// gets enriched asynchronously with full metadata (backdrop, poster, summary, etc.)
    /// so that even minimal nodes from history/favorites show complete data.
    @State private var displayNode: MacMediaLibraryNode

    init(
        server: ServerConfig,
        node: MacMediaLibraryNode,
        playlist: [VideoFile]? = nil,
        onBack: (() -> Void)? = nil,
        onHome: (() -> Void)? = nil,
        onExit: (() -> Void)? = nil,
        onPushNode: ((MacMediaLibraryNode, [VideoFile]?) -> Void)? = nil,
        onPushPerson: ((MacMediaPerson) -> Void)? = nil
    ) {
        self.server = server
        self.node = node
        self.playlist = playlist
        self.onBack = onBack
        self.onHome = onHome
        self.onExit = onExit
        self.onPushNode = onPushNode
        self.onPushPerson = onPushPerson
        self._displayNode = State(initialValue: node)
        self._isPlayed = State(initialValue: node.isPlayed)
    }

    @AppStorage("allowMediaServerDeletion") private var allowMediaServerDeletion = false
    @State private var showPlayer = false
    @State private var childNodes: [MacMediaLibraryNode] = []
    @State private var isLoadingChildren = false
    @State private var cast: [MacMediaPerson] = []
    @State private var similarNodes: [MacMediaLibraryNode] = []

    @State private var selectedSeasonNode: MacMediaLibraryNode?
    @State private var seasonEpisodes: [MacMediaLibraryNode] = []
    @State private var isLoadingEpisodes = false

    private enum MacDetailAlertType: Identifiable {
        case download
        case downloadSeason
        case delete
        var id: Int {
            switch self {
            case .download: return 1
            case .downloadSeason: return 2
            case .delete: return 3
            }
        }
    }

    @State private var activeAlert: MacDetailAlertType? = nil
    @State private var downloadTarget: MacMediaLibraryNode?
    @State private var pendingEpisodeId: String? = nil
    @State private var highlightedEpisodeId: String? = nil
    @State private var isDeleting = false
    @State private var isPlayed: Bool = false
    @State private var toastMessage: String? = nil

    private var selectedSeasonDownloadState: DownloadAggregateState {
        downloadCenter.aggregateState(serverId: server.id, remoteItemIds: seasonEpisodes.compactMap(\.id))
    }

    private var canQueueSelectedSeasonDownload: Bool {
        let episodesToQueue = seasonEpisodes.filter { episode in
            !downloadCenter.isDownloaded(serverId: server.id, remoteItemId: episode.id) &&
            !downloadCenter.activeJobs.contains(where: { job in
                job.serverId == server.id && job.tasks.contains(where: { $0.remoteItemId == episode.id })
            })
        }
        return !episodesToQueue.isEmpty
    }

    private var seasonDownloadIcon: String {
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

    private var seasonDownloadColor: Color {
        switch selectedSeasonDownloadState {
        case .downloaded:
            return .green
        case .partiallyDownloaded, .queued, .downloading:
            return .accentColor
        case .failed:
            return .red
        case .notDownloaded:
            return Color.white.opacity(0.85)
        }
    }

    private func downloadSeason() {
        let episodesToQueue = seasonEpisodes.filter { episode in
            !downloadCenter.isDownloaded(serverId: server.id, remoteItemId: episode.id) &&
            !downloadCenter.activeJobs.contains(where: { job in
                job.serverId == server.id && job.tasks.contains(where: { $0.remoteItemId == episode.id })
            })
        }
        guard !episodesToQueue.isEmpty else { return }

        let seasonTitle = "\(displayNode.name) - \(selectedSeasonNode?.name ?? "")"
        let job = DownloadJobDescriptor(
            kind: .seasonPack,
            sourceType: DownloadSourceType(serverType: server.type),
            title: seasonTitle,
            groupTitle: seasonTitle,
            collectionId: selectedSeasonNode?.id ?? displayNode.id,
            seriesId: displayNode.id,
            seasonId: selectedSeasonNode?.id
        )

        let entries = episodesToQueue.enumerated().map { index, episode in
            DownloadMediaBatchItem(
                remoteItemId: episode.id,
                remotePath: "/Videos/\(episode.id)/stream?Static=true&download=1",
                fileName: "\(episode.name).mp4",
                displayTitle: episode.name,
                totalBytes: nil,
                collectionId: selectedSeasonNode?.id ?? displayNode.id,
                seriesId: displayNode.id,
                seasonId: selectedSeasonNode?.id,
                groupIndex: index
            )
        }

        _ = downloadCenter.enqueueMediaBatch(server: server, items: entries, job: job)
    }

    private var isSeries: Bool {
        let t = displayNode.collectionType?.lowercased() ?? ""
        return t == "series" || t == "show" || t == "tvshows" || t == "tvshow" || (displayNode.isFolder && (childNodes.first?.collectionType?.lowercased() == "season" || childNodes.first?.name.lowercased().contains("season") == true))
    }

    private var playableNode: MacMediaLibraryNode? {
        if isSeries {
            return seasonEpisodes.first { $0.playbackPositionTicks ?? 0 > 0 } ?? seasonEpisodes.first
        }
        return displayNode.playbackURL != nil ? displayNode : nil
    }

    private var streamPlaybackURL: URL? {
        let node = playableNode ?? displayNode
        if let url = node.playbackURL {
            if server.type == .jellyfin || server.type == .emby {
                if let token = server.accessToken, !token.isEmpty, !url.absoluteString.contains("api_key=") {
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    var items = components?.queryItems ?? []
                    items.append(URLQueryItem(name: "api_key", value: token))
                    components?.queryItems = items
                    return components?.url ?? url
                }
            } else if server.type == .plex {
                if let token = server.accessToken, !token.isEmpty, !url.absoluteString.contains("X-Plex-Token=") {
                    var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                    var items = components?.queryItems ?? []
                    items.append(URLQueryItem(name: "X-Plex-Token", value: token))
                    components?.queryItems = items
                    return components?.url ?? url
                }
            }
            return url
        }
        return nil
    }

    private func videoFile(for targetNode: MacMediaLibraryNode) -> VideoFile {
        macMakeVideoFile(for: targetNode, server: server)
    }

    private var videoFile: VideoFile {
        videoFile(for: displayNode)
    }

    private var isFavorite: Bool {
        favoriteService.isFavorite(file: videoFile)
    }

    private func loadEpisodes(for season: MacMediaLibraryNode) async {
        isLoadingEpisodes = true
        do {
            let eps = try await fetchNodes(server: AppNetworkService.shared.hydratedServer(from: server), parentNode: season)
            seasonEpisodes = eps
        } catch {
            print("Failed to load episodes: \(error)")
        }
        isLoadingEpisodes = false
    }

    @State private var showScrollToTop = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    GeometryReader { geo in
                        Color.clear.preference(key: MacScrollOffsetKey.self, value: geo.frame(in: .named("detailScroll")).minY)
                    }
                    .frame(height: 0)
                    .id("TOP")

                    MacMediaDetailHero(
                        server: server,
                        node: displayNode,
                        playableNode: playableNode,
                        isFavorite: isFavorite,
                        isPlayed: isPlayed,
                        onPlay: {
                        let targetNode = playableNode ?? displayNode
                        let targetFile = videoFile(for: targetNode)
                        let playableFile = downloadCenter.localPlaybackFile(for: targetFile) ?? targetFile
                        MacPlayerWindowManager.shared.openPlayer(for: playableFile, playlist: isSeries ? seasonEpisodes.map { videoFile(for: $0) } : playlist)
                    },
                    onDownload: { startDownload(node: displayNode) },
                    onFavorite: {
                        favoriteService.toggleFavorite(file: videoFile)
                        toastMessage = platformShellString(isFavorite ? "Removed from Favorites" : "Added to Favorites")
                    },
                    onTogglePlayed: togglePlayed,
                    onDelete: {
                        activeAlert = .delete
                    }
                )

                // (Redundant bottom overview removed in favor of top hero overview)

                if displayNode.isFolder {
                    Divider().padding(.horizontal, 44)
                    
                    VStack(alignment: .leading, spacing: 20) {
                        if isLoadingChildren {
                            Text(platformShellString("Contents"))
                                .font(.title2.weight(.semibold))
                                .padding(.horizontal, 44)
                                .padding(.top, 24)
                            ProgressView()
                                .padding(.horizontal, 44)
                        } else if isSeries && !childNodes.isEmpty {
                            MacSectionHeader(title: platformShellString("Seasons"), systemImageName: "square.stack.fill")
                                .padding(.horizontal, 44)
                                .padding(.top, 24)
                            
                            if childNodes.count > 5 {
                                Menu {
                                    ForEach(childNodes) { season in
                                        Button(action: {
                                            selectedSeasonNode = season
                                            highlightedEpisodeId = nil
                                            Task { await loadEpisodes(for: season) }
                                        }) {
                                            HStack {
                                                Text(season.name)
                                                if selectedSeasonNode?.id == season.id {
                                                    Spacer()
                                                    Image(systemName: "checkmark")
                                                }
                                            }
                                        }
                                        .contextMenu {
                                            if allowMediaServerDeletion {
                                                Button(role: .destructive) {
                                                    #if os(macOS)
                                                    showMacConfirmationAlert(
                                                        title: platformShellString("Delete from Server"),
                                                        message: String(format: platformShellString("Are you sure you want to delete \"%@\" from the server? This cannot be undone."), season.name),
                                                        confirmTitle: platformShellString("Delete"),
                                                        isDestructive: true
                                                    ) {
                                                        Task { await deleteSeason(season) }
                                                    }
                                                    #endif
                                                } label: {
                                                    Text(platformShellString("Delete from Server"))
                                                }
                                            }
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 6) {
                                        Text(selectedSeasonNode?.name ?? platformShellString("Select Season"))
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundColor(.white)
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .background(Capsule().fill(Color.white.opacity(0.12)))
                                }
                                .buttonStyle(.plain)
                                .padding(.horizontal, 44)
                                .padding(.vertical, 12)
                            } else {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 12) {
                                        ForEach(childNodes) { season in
                                            Button(action: {
                                                selectedSeasonNode = season
                                                highlightedEpisodeId = nil
                                                Task { await loadEpisodes(for: season) }
                                            }) {
                                                Text(season.name)
                                                    .font(.system(size: 16, weight: selectedSeasonNode?.id == season.id ? .bold : .medium))
                                                    .foregroundColor(selectedSeasonNode?.id == season.id ? .white : .white.opacity(0.72))
                                                    .padding(.horizontal, 16)
                                                    .padding(.vertical, 8)
                                                    .background(
                                                        Capsule().fill(selectedSeasonNode?.id == season.id ? Color.white.opacity(0.12) : Color.clear)
                                                    )
                                            }
                                            .buttonStyle(.plain)
                                            .contextMenu {
                                                if allowMediaServerDeletion {
                                                    Button(role: .destructive) {
                                                        #if os(macOS)
                                                        showMacConfirmationAlert(
                                                            title: platformShellString("Delete from Server"),
                                                            message: String(format: platformShellString("Are you sure you want to delete \"%@\" from the server? This cannot be undone."), season.name),
                                                            confirmTitle: platformShellString("Delete"),
                                                            isDestructive: true
                                                        ) {
                                                            Task { await deleteSeason(season) }
                                                        }
                                                        #endif
                                                    } label: {
                                                        Text(platformShellString("Delete from Server"))
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 44)
                                    .padding(.vertical, 12)
                                }
                            }
                            
                            if isLoadingEpisodes && seasonEpisodes.isEmpty {
                                ProgressView().padding(.horizontal, 44).padding(.top, 10)
                            } else if seasonEpisodes.isEmpty {
                                VStack(spacing: 16) {
                                    ZStack {
                                        Circle()
                                            .fill(Color.white.opacity(0.06))
                                            .frame(width: 60, height: 60)
                                        Image(systemName: "film.stack")
                                            .font(.system(size: 26))
                                            .foregroundColor(.white.opacity(0.45))
                                    }
                                    
                                    VStack(spacing: 6) {
                                        Text(platformShellString("This season is empty"))
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundColor(.white)
                                        
                                        Text(platformShellString("No episodes found in this season"))
                                            .font(.system(size: 13))
                                            .foregroundColor(.white.opacity(0.55))
                                    }
                                    
                                    if allowMediaServerDeletion, let currentSeason = selectedSeasonNode {
                                        Button(action: {
                                            #if os(macOS)
                                            showMacConfirmationAlert(
                                                title: platformShellString("Delete from Server"),
                                                message: String(format: platformShellString("Are you sure you want to delete \"%@\" from the server? This cannot be undone."), currentSeason.name),
                                                confirmTitle: platformShellString("Delete"),
                                                isDestructive: true
                                            ) {
                                                Task { await deleteSeason(currentSeason) }
                                            }
                                            #endif
                                        }) {
                                            HStack(spacing: 8) {
                                                Image(systemName: "trash")
                                                    .font(.system(size: 13, weight: .semibold))
                                                Text(platformShellString("Delete Empty Season"))
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
                                        .buttonStyle(.plain)
                                        .padding(.top, 4)
                                    }
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 36)
                                .padding(.horizontal, 24)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(Color.white.opacity(0.03))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16)
                                                .stroke(Color.white.opacity(0.06), lineWidth: 1)
                                        )
                                )
                                .padding(.horizontal, 44)
                                .padding(.vertical, 16)
                            } else {
                                HStack(spacing: 12) {
                                    Text(selectedSeasonNode?.name ?? platformShellString("Episodes"))
                                        .font(.title2.weight(.semibold))
                                    
                                    Button(action: {
                                        if canQueueSelectedSeasonDownload {
                                            activeAlert = .downloadSeason
                                        }
                                    }) {
                                        Image(systemName: seasonDownloadIcon)
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundColor(seasonDownloadColor)
                                            .frame(width: 32, height: 32)
                                            .background(Color.white.opacity(0.1), in: Circle())
                                            .modifier(MacHoverEffect())
                                    }
                                    .buttonStyle(.plain)
                                    .macPointerHover()
                                    .disabled(!canQueueSelectedSeasonDownload)
                                    .help(platformShellString("Downloads"))
                                    
                                    Spacer()
                                }
                                .padding(.horizontal, 44)
                                .padding(.vertical, 10)

                                let childPlaylist = seasonEpisodes.map { videoFile(for: $0) }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: MacMediaCardMetrics.landscapeWidth, maximum: MacMediaCardMetrics.landscapeWidth), spacing: 20, alignment: .top)], alignment: .leading, spacing: 24) {
                                    ForEach(Array(seasonEpisodes.enumerated()), id: \.element.id) { index, episode in
                                        let epVideoFile = videoFile(for: episode)
                                        Button(action: {
                                            if let onPushNode {
                                                onPushNode(episode, childPlaylist)
                                            }
                                        }) {
                                            MacEpisodeCard(
                                                server: server,
                                                node: episode,
                                                indexNumber: episode.indexNumber ?? (index + 1),
                                                isPlayed: episode.isPlayed,
                                                isHighlighted: highlightedEpisodeId == episode.id,
                                                onPlay: {
                                                    let epFile = videoFile(for: episode)
                                                    let playableFile = downloadCenter.localPlaybackFile(for: epFile) ?? epFile
                                                    MacPlayerWindowManager.shared.openPlayer(for: playableFile, playlist: childPlaylist)
                                                },
                                                onDownload: {
                                                    startDownload(node: episode)
                                                }
                                            )
                                        }
                                        .buttonStyle(.plain)
                                        .id("episode-\(episode.id)")
                                    }
                                }
                                .opacity(isLoadingEpisodes ? 0.5 : 1.0)
                                .padding(.horizontal, 44)
                                .padding(.bottom, 44)
                            }
                        } else if !childNodes.isEmpty {
                            Text(platformShellString("Contents"))
                                .font(.title2.weight(.semibold))
                                .padding(.horizontal, 44)
                                .padding(.top, 24)

                            let isChildFolder = childNodes.first?.isFolder ?? true
                            let minWidth: CGFloat = isChildFolder ? 158 : MacMediaCardMetrics.landscapeWidth
                            let childPlaylist = isChildFolder ? nil : childNodes.filter { !$0.isFolder }.map { videoFile(for: $0) }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth, maximum: minWidth), spacing: 20, alignment: .top)], alignment: .leading, spacing: 24) {
                                ForEach(childNodes) { child in
                                    if isChildFolder {
                                        MacPortraitMediaCard(
                                            node: child,
                                            action: {
                                                if let onPushNode { onPushNode(child, childPlaylist) }
                                            },
                                            server: server,
                                            onPlay: child.isFolder ? nil : { macPlayNode(child, server: server, playlist: childPlaylist) }
                                        )
                                    } else {
                                        MacLandscapeMediaCard(
                                            node: child,
                                            action: {
                                                if let onPushNode { onPushNode(child, childPlaylist) }
                                            },
                                            server: server,
                                            onPlay: child.isFolder ? nil : { macPlayNode(child, server: server, playlist: childPlaylist) }
                                        )
                                    }
                                }
                            }
                            .padding(.horizontal, 44)
                            .padding(.bottom, 44)
                        } else {
                            Text(platformShellString("Platform Shell TV Folder Empty Title"))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 44)
                        }
                    }
                    }

                    if !cast.isEmpty {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(platformShellString("Cast & Crew"))
                                .font(.title2.weight(.semibold))
                                .padding(.horizontal, 44)
                                .padding(.top, node.isFolder ? 0 : 24)
                            
                            MacHorizontalShelf(items: cast, spacing: 24, horizontalPadding: 44, verticalPadding: 12, alignment: .center, artworkHeight: 110, artworkTopInset: 8) { person in
                                Button(action: {
                                    if let onPushPerson {
                                        onPushPerson(person)
                                    }
                                }) {
                                    VStack(spacing: 10) {
                                        MacRemoteArtworkImage(url: person.primaryImageURL, placeholderSystemImageName: "person.fill")
                                            .frame(width: 110, height: 110)
                                            .clipShape(Circle())
                                            .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
                                        VStack(spacing: 2) {
                                            Text(person.name)
                                                .font(.system(size: 14, weight: .semibold))
                                                .foregroundColor(.primary)
                                                .lineLimit(1)
                                            if let role = person.role {
                                                Text(role)
                                                    .font(.system(size: 12))
                                                    .foregroundColor(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }
                                        .frame(width: 120)
                                    }
                                    .padding(8)
                                    .contentShape(Rectangle())
                                    .macCardHoverEffectCore(cornerRadius: 12)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    
                    if !similarNodes.isEmpty {
                        VStack(alignment: .leading, spacing: 20) {
                            Text(platformShellString("More Like This"))
                                .font(.title2.weight(.semibold))
                                .padding(.horizontal, 44)
                                .padding(.top, 24)
                            
                            MacHorizontalShelf(items: similarNodes, spacing: 24, horizontalPadding: 44, verticalPadding: 24, alignment: .center, artworkHeight: MacMediaCardMetrics.portraitHeight) { similar in
                                MacPortraitMediaCard(
                                    node: similar,
                                    action: {
                                        if let onPushNode { onPushNode(similar, nil) }
                                    },
                                    server: server,
                                    onPlay: similar.isFolder ? nil : { macPlayNode(similar, server: server) }
                                )
                            }
                    }
                }

                let filePath = displayNode.remotePath?.nilIfEmpty
                let streamURL = streamPlaybackURL
                if filePath != nil || streamURL != nil {
                    VStack(alignment: .leading, spacing: 14) {
                        Divider().padding(.horizontal, 44)
                        
                        Text(platformShellString("Media Info"))
                            .font(.title2.weight(.semibold))
                            .padding(.horizontal, 44)
                            .padding(.top, 12)
                        
                        VStack(alignment: .leading, spacing: 16) {
                            // Server Source
                            HStack(alignment: .center, spacing: 12) {
                                Text(platformShellString("Server Info"))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 90, alignment: .leading)
                                
                                HStack(spacing: 6) {
                                    Image(systemName: "server.rack")
                                        .font(.caption)
                                        .foregroundColor(.accentColor)
                                    Text(server.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.primary)
                                }
                                
                                Spacer()
                            }
                            
                            // Technical Specs (Quality, Format, Bitrate, Size)
                            if let techLine = displayNode.technicalMetadataLine?.nilIfEmpty {
                                Divider()
                                HStack(alignment: .center, spacing: 12) {
                                    Text(platformShellString("Quality"))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .frame(width: 90, alignment: .leading)
                                    
                                    Text(techLine)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundColor(.primary.opacity(0.9))
                                    
                                    Spacer()
                                }
                            }
                            
                            // Physical File Path & Copy Button
                            if let path = filePath {
                                Divider()
                                HStack(alignment: .top, spacing: 12) {
                                    Text(platformShellString("File Path"))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .frame(width: 90, alignment: .leading)
                                    
                                    Text(path)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.primary.opacity(0.85))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    
                                    Spacer(minLength: 8)
                                    
                                    Button(action: {
                                        #if os(iOS)
                                        UIPasteboard.general.string = path
                                        #elseif os(macOS)
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(path, forType: .string)
                                        #endif
                                        toastMessage = platformShellString("Path Copied to Clipboard")
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "doc.on.doc")
                                            Text(platformShellString("Copy Path"))
                                        }
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.accentColor)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.accentColor.opacity(0.12))
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            // Stream URL & Copy Button
                            if let streamURL = streamURL {
                                Divider()
                                HStack(alignment: .top, spacing: 12) {
                                    Text(platformShellString("Stream URL"))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(.secondary)
                                        .frame(width: 90, alignment: .leading)
                                    
                                    Text(streamURL.absoluteString)
                                        .font(.system(size: 13, design: .monospaced))
                                        .foregroundColor(.primary.opacity(0.85))
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    
                                    Spacer(minLength: 8)
                                    
                                    Button(action: {
                                        #if os(iOS)
                                        UIPasteboard.general.string = streamURL.absoluteString
                                        #elseif os(macOS)
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(streamURL.absoluteString, forType: .string)
                                        #endif
                                        toastMessage = platformShellString("Stream URL Copied to Clipboard")
                                    }) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "link")
                                            Text(platformShellString("Copy Stream URL"))
                                        }
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundColor(.accentColor)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(Color.accentColor.opacity(0.12))
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(12)
                        .padding(.horizontal, 44)
                        .padding(.bottom, 40)
                    }
                }

            }

            .ignoresSafeArea(.all) // Fix macOS ScrollView top safe area gap inside ScrollViewReader
            .onChange(of: seasonEpisodes) { newEpisodes in
                if let epId = pendingEpisodeId, newEpisodes.contains(where: { $0.id == epId }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation {
                            proxy.scrollTo("episode-\(epId)", anchor: .center)
                        }
                        pendingEpisodeId = nil
                    }
                }
            }
        }
        .task(id: displayNode.id) {
            let latestServer = AppNetworkService.shared.savedServers.first(where: { $0.id == server.id }) ?? server
            let activeServer = AppNetworkService.shared.hydratedServer(from: latestServer)


            // Fetch full node metadata first (backdrop, poster, summary, etc.)
            // This is especially important when the view is opened from history/favorites
            // where the initial node has minimal data.
            async let metadataFetch: () = {
                if displayNode.backdropURL == nil || displayNode.summary == nil || displayNode.logoURL == nil {
                    do {
                        if let fullNode = try await fetchMacMediaItem(server: activeServer, nodeId: displayNode.id) {
                            await MainActor.run {
                                displayNode = fullNode
                            }
                        }
                    } catch URLError.fileDoesNotExist {
                        await MainActor.run {
                            toastMessage = platformShellString("Item not found on server")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                if let onBack {
                                    onBack()
                                } else {
                                    dismiss()
                                }
                            }
                        }
                    } catch {
                        // ignore other errors and stay on view with placeholder
                    }
                }
            }()

            async let childrenFetch: () = {
                if displayNode.isFolder && childNodes.isEmpty {
                    isLoadingChildren = true
                    do {
                        childNodes = try await fetchNodes(server: activeServer, parentNode: displayNode)
                        if isSeries {
                            let targetSeasonId = MacNavigationManager.shared.targetSeasonId
                            let targetEpisodeId = MacNavigationManager.shared.targetEpisodeId
                            
                            // Reset target properties
                            MacNavigationManager.shared.targetSeasonId = nil
                            MacNavigationManager.shared.targetEpisodeId = nil
                            
                            var resolvedSeasonNode = childNodes.first
                            if let seasonId = targetSeasonId, let matched = childNodes.first(where: { $0.id == seasonId }) {
                                resolvedSeasonNode = matched
                            }
                            
                            if let season = resolvedSeasonNode {
                                selectedSeasonNode = season
                                await loadEpisodes(for: season)
                                
                                if let epId = targetEpisodeId {
                                    await MainActor.run {
                                        self.pendingEpisodeId = epId
                                        self.highlightedEpisodeId = epId
                                    }
                                }
                            }
                        }
                    } catch {
                        print("Failed to fetch child nodes: \(error)")
                    }
                    isLoadingChildren = false
                }
            }()
            
            async let castFetch: () = {
                if cast.isEmpty {
                    do {
                        cast = try await fetchMacMediaPeople(server: activeServer, nodeId: displayNode.id)
                    } catch {
                        print("Failed to fetch cast: \(error)")
                    }
                }
            }()
            
            async let similarFetch: () = {
                if similarNodes.isEmpty && !displayNode.isFolder {
                    do {
                        similarNodes = try await fetchMacMediaSimilar(server: activeServer, nodeId: displayNode.id)
                    } catch {
                        print("Failed to fetch similar: \(error)")
                    }
                }
            }()
            
            await (metadataFetch, childrenFetch, castFetch, similarFetch)
        }
        .coordinateSpace(name: "detailScroll")
        .onPreferenceChange(MacScrollOffsetKey.self) { offset in
            showScrollToTop = offset < -300
        }
        .overlay(alignment: .bottomTrailing) {
            if showScrollToTop {
                Button(action: {
                    withAnimation { proxy.scrollTo("TOP", anchor: .top) }
                }) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.accentColor)
                        .clipShape(Circle())
                        .shadow(radius: 4)
                }
                .buttonStyle(.plain)
                .padding(32)
                .transition(.opacity)
            }
        }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle("")
        .hideNavBack()
        .macServerToolbar(
            server: server,
            title: server.name,
            canGoBack: true,
            hideSearchAndExit: true,
            isImmersive: true,
            searchText: .constant(""),
            onBack: {
                // Use explicit onBack callback when rendered in-place (not pushed via NavigationLink).
                // Fall back to dismiss() for nested NavigationLink-pushed instances (episodes, similar, etc.).
                if let onBack { onBack() } else { dismiss() }
            },
            onHome: {
                onHome?()
                // Only dismiss if this view was pushed via NavigationLink.
                // If it's the root detail view (has onBack), onHome?() already clears selectedLeaf.
                if onBack == nil { dismiss() }
            },
            onExit: { onExit?() }
        ) {
            EmptyView()
        }

        .floatingToast(message: $toastMessage)
        .onAppear {
            self.isPlayed = displayNode.isPlayed
        }
        .onReceive(NotificationCenter.default.publisher(for: .remoteItemDidDelete)) { notification in
            guard let payload = notification.object as? RemoteItemDeletePayload, payload.serverId == server.id else { return }
            if payload.itemId == displayNode.id {
                if let onBack {
                    onBack()
                } else {
                    dismiss()
                }
            } else {
                withAnimation {
                    seasonEpisodes.removeAll(where: { $0.id == payload.itemId })
                    childNodes.removeAll(where: { $0.id == payload.itemId })
                }
            }
        }
        .alert(item: $activeAlert) { type in
            switch type {
            case .download:
                return Alert(
                    title: Text(platformShellString("Download Video")),
                    message: Text(String(format: platformShellString("Are you sure you want to download \"%@\" for offline playback?"), downloadTarget?.name ?? "")),
                    primaryButton: .default(Text(platformShellString("Download"))) {
                        if let target = downloadTarget {
                            enqueueDownload(for: target)
                            toastMessage = platformShellString("Added to Downloads")
                            let userInfo: [AnyHashable: Any] = ["title": target.name]
                            NotificationCenter.default.post(name: NSNotification.Name("MacDownloadStarted"), object: nil, userInfo: userInfo)
                        }
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .downloadSeason:
                let seasonName = selectedSeasonNode?.name ?? platformShellString("Season")
                let count = seasonEpisodes.filter { ep in
                    !downloadCenter.isDownloaded(serverId: server.id, remoteItemId: ep.id) &&
                    !downloadCenter.activeJobs.contains(where: { job in
                        job.serverId == server.id && job.tasks.contains(where: { $0.remoteItemId == ep.id })
                    })
                }.count
                return Alert(
                    title: Text(platformShellString("Download Season")),
                    message: Text(String(format: platformShellString("Are you sure you want to download \"%@\" (%d episodes)?"), seasonName, count)),
                    primaryButton: .default(Text(platformShellString("Download"))) {
                        downloadSeason()
                        toastMessage = platformShellString("Added to Downloads")
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .delete:
                return Alert(
                    title: Text(platformShellString("Delete from Server")),
                    message: Text(String(format: platformShellString("Are you sure you want to delete \"%@\" from the server? This cannot be undone."), displayNode.name)),
                    primaryButton: .destructive(Text(platformShellString("Delete"))) {
                        Task { await deleteItem() }
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            }
        }
        .overlay {
            if isDeleting {
                ZStack {
                    Color.black.opacity(0.4)
                    ProgressView()
                        .controlSize(.regular)
                }
                .ignoresSafeArea()
            }
        }
    }

    private func deleteSeason(_ seasonNode: MacMediaLibraryNode) async {
        guard let token = server.accessToken, !token.isEmpty else { return }
        await MainActor.run { isDeleting = true }
        defer {
            Task { @MainActor in isDeleting = false }
        }

        do {
            let rawBaseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let endpoint: String
            switch server.type {
            case .plex:
                endpoint = "\(rawBaseURL)/library/metadata/\(seasonNode.id)"
            case .jellyfin, .emby:
                endpoint = "\(rawBaseURL)/Items/\(seasonNode.id)"
            default:
                return
            }

            guard let rawURL = URL(string: endpoint) else { return }
            let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            applyMediaLibraryHeaders(to: &request, server: server)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("Failed to delete season from server: status code \(statusCode)")
                await MainActor.run {
                    toastMessage = platformShellString("Failed to delete from server") + " (\(statusCode))"
                }
                return
            }

            if let fav = FavoriteService.shared.favorites.first(where: { $0.file.jellyfinItemId == seasonNode.id }) {
                FavoriteService.shared.remove(fav)
            }
            if let h = HistoryService.shared.remoteHistory.first(where: { $0.jellyfinItemId == seasonNode.id }) {
                HistoryService.shared.removeFromHistory(h)
            }

            await MainActor.run {
                NotificationCenter.default.post(
                    name: .remoteItemDidDelete,
                    object: RemoteItemDeletePayload(serverId: server.id, itemId: seasonNode.id)
                )
                toastMessage = platformShellString("Deleted")
                withAnimation {
                    childNodes.removeAll(where: { $0.id == seasonNode.id })
                    if selectedSeasonNode?.id == seasonNode.id {
                        if let next = childNodes.first {
                            selectedSeasonNode = next
                            Task { await loadEpisodes(for: next) }
                        } else {
                            selectedSeasonNode = nil
                            seasonEpisodes = []
                        }
                    }
                }
            }
        } catch {
            print("Failed to delete season: \(error.localizedDescription)")
            await MainActor.run {
                toastMessage = platformShellString("Failed to delete from server")
            }
        }
    }

    private func deleteItem() async {
        guard let token = server.accessToken, !token.isEmpty else { return }
        await MainActor.run { isDeleting = true }
        defer {
            Task { @MainActor in isDeleting = false }
        }

        do {
            let rawBaseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let endpoint: String
            switch server.type {
            case .plex:
                endpoint = "\(rawBaseURL)/library/metadata/\(displayNode.id)"
            case .jellyfin, .emby:
                endpoint = "\(rawBaseURL)/Items/\(displayNode.id)"
            default:
                return
            }

            guard let rawURL = URL(string: endpoint) else { return }
            let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            applyMediaLibraryHeaders(to: &request, server: server)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                print("Failed to delete item: status code \(statusCode)")
                await MainActor.run {
                    toastMessage = platformShellString("Failed to delete from server") + " (\(statusCode))"
                }
                return
            }

            if let fav = FavoriteService.shared.favorites.first(where: { $0.file.jellyfinItemId == displayNode.id }) {
                FavoriteService.shared.remove(fav)
            }
            if let h = HistoryService.shared.remoteHistory.first(where: { $0.jellyfinItemId == displayNode.id }) {
                HistoryService.shared.removeFromHistory(h)
            }

            await MainActor.run {
                NotificationCenter.default.post(
                    name: .remoteItemDidDelete,
                    object: RemoteItemDeletePayload(serverId: server.id, itemId: displayNode.id)
                )
                toastMessage = platformShellString("Deleted")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let onBack {
                        onBack()
                    } else {
                        dismiss()
                    }
                }
            }
        } catch {
            print("Failed to delete item: \(error)")
            await MainActor.run {
                toastMessage = platformShellString("Failed to delete from server")
            }
        }
    }

    private func startDownload(node: MacMediaLibraryNode, at point: CGPoint? = nil) {
        downloadTarget = node
        activeAlert = .download
    }

    private func togglePlayed() {
        guard let token = server.accessToken, let userId = server.userId else { return }
        let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let itemId = displayNode.id
        guard let url = URL(string: "\(baseURL)/Users/\(userId)/PlayedItems/\(itemId)") else { return }
        
        var request = URLRequest(url: url)
        request.httpMethod = isPlayed ? "DELETE" : "POST"
        request.setValue("MediaBrowser Token=\"\(token)\"", forHTTPHeaderField: server.type == .jellyfin ? "Authorization" : "X-Emby-Token")
        
        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResp = response as? HTTPURLResponse, (200...299).contains(httpResp.statusCode) {
                    await MainActor.run {
                        isPlayed.toggle()
                        toastMessage = platformShellString(isPlayed ? "Marked as Played" : "Marked as Unplayed")
                    }
                }
            } catch { print("Failed to toggle played: \(error)") }
        }
    }

    private func enqueueDownload(for targetNode: MacMediaLibraryNode) {
        if let itemId = targetNode.id.nilIfEmpty {
            _ = downloadCenter.enqueueMediaDownload(
                server: server,
                remoteItemId: itemId,
                fileName: "\(targetNode.name).mp4",
                totalBytes: nil,
                displayTitle: targetNode.name,
                seriesId: targetNode.seriesId,
                seasonId: nil
            )
        } else if let remotePath = targetNode.remotePath, !remotePath.isEmpty {
            downloadCenter.enqueueDownload(
                server: server,
                remotePath: remotePath,
                fileName: targetNode.name,
                totalBytes: nil,
                displayTitle: targetNode.name
            )
        }
    }
}

private struct MacTruncatableOverviewText: View {
    let summary: String
    @State private var isOverviewExpanded = false

    var body: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                isOverviewExpanded.toggle()
            }
        }) {
            Text(summary)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.white.opacity(0.78))
                .lineSpacing(4)
                .lineLimit(isOverviewExpanded ? nil : 2)
                .multilineTextAlignment(.leading)
        }
        .buttonStyle(PlainButtonStyle())
        .frame(maxWidth: 960, alignment: .leading)
    }
}

struct MacMediaDetailHero: View {
    let server: ServerConfig
    let node: MacMediaLibraryNode
    var playableNode: MacMediaLibraryNode? = nil
    let isFavorite: Bool
    let isPlayed: Bool
    let onPlay: () -> Void
    let onDownload: () -> Void
    let onFavorite: () -> Void
    let onTogglePlayed: () -> Void
    var onDelete: (() -> Void)? = nil
    var showsMediaServerActions = true
    var canPlay = true
    var showsStandaloneFavorite = false

    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @State private var isShowingPlaybackOptions = false

    private var activeJobId: UUID? {
        if let itemId = node.id.nilIfEmpty {
            return downloadCenter.activeJobs.first(where: { job in
                job.serverId == server.id && job.tasks.contains(where: { $0.remoteItemId == itemId })
            })?.id
        } else if let remotePath = node.remotePath {
            return downloadCenter.activeJobs.first(where: { job in
                job.serverId == server.id && job.tasks.contains(where: { $0.remotePath == remotePath })
            })?.id
        }
        return nil
    }

    private var isDownloaded: Bool {
        if let itemId = node.id.nilIfEmpty {
            return downloadCenter.isDownloaded(serverId: server.id, remoteItemId: itemId)
        } else if let remotePath = node.remotePath {
            return downloadCenter.isDownloaded(serverId: server.id, remotePath: remotePath)
        }
        return false
    }

    private var downloadIcon: String {
        if isDownloaded { return "arrow.down.circle.fill" }
        if activeJobId != nil { return "stop.circle" }
        return "arrow.down.circle"
    }
    
    private var downloadTint: Color {
        if isDownloaded { return .green }
        if activeJobId != nil { return .orange }
        return .white
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MacRemoteArtworkImage(
                url: node.backdropURL ?? node.posterURL,
                placeholderSystemImageName: node.isFolder ? "folder.fill" : "film.fill"
            )
            .frame(maxWidth: .infinity, minHeight: 430, maxHeight: 430)
            .clipped()

            ZStack {
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.black.opacity(0.86),
                        Color.black.opacity(0.50),
                        Color.black.opacity(0.16)
                    ]),
                    startPoint: .leading,
                    endPoint: .trailing
                )

                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.clear,
                        Color(nsColor: .windowBackgroundColor).opacity(0.94)
                    ]),
                    startPoint: .center,
                    endPoint: .bottom
                )
            }

                    if !node.logoURLs.isEmpty {
                        VStack {
                            HStack {
                                Spacer()
                                MacRemoteLogoImage(urls: node.logoURLs, maxHeight: 85)
                                    .padding(.top, 32)
                                    .padding(.trailing, 96)
                                    .shadow(color: .black.opacity(0.6), radius: 6, x: 0, y: 3)
                            }
                            Spacer()
                        }
                    }

            HStack(alignment: .top, spacing: 34) {
                MacRemoteArtworkImage(
                    url: node.posterURL ?? node.backdropURL,
                    placeholderSystemImageName: node.isFolder ? "folder.fill" : "film.fill"
                )
                .frame(width: 178, height: 267)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.42), radius: 24, x: 0, y: 14)

                VStack(alignment: .leading, spacing: 14) {


                    Text(node.name)
                        .font(.system(size: 46, weight: .black))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: 960, alignment: .leading)

                    if let metadataLine = node.metadataLine?.nilIfEmpty {
                        Text(metadataLine)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white.opacity(0.76))
                            .lineLimit(1)
                    }

                    if let technicalLine = node.technicalMetadataLine?.nilIfEmpty {
                        Text(technicalLine)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }

                    if let summary = node.summary?.nilIfEmpty {
                        MacTruncatableOverviewText(summary: summary)
                    }

                    HStack(spacing: 14) {
                        Button(action: onPlay) {
                            let targetNode = playableNode ?? node
                            let progress: Double? = {
                                guard let pos = targetNode.playbackPositionTicks, let total = targetNode.runTimeTicks, total > 0, pos > 0 else { return nil }
                                return min(1.0, Double(pos) / Double(total))
                            }()
                            
                            Group {
                                if let p = progress, let pos = targetNode.playbackPositionTicks, let total = targetNode.runTimeTicks {
                                    MacResumeButtonLabel(
                                        progress: p,
                                        playedSeconds: Int(pos / 10_000_000),
                                        totalSeconds: Int(total / 10_000_000)
                                    )
                                } else {
                                    HStack(spacing: 8) {
                                        Image(systemName: "play.fill")
                                        Text(platformShellString("Play"))
                                            .fontWeight(.bold)
                                    }
                                    .font(.headline)
                                    .foregroundColor(.black)
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 58)
                                    .background(Color.white)
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.6))
                                    .shadow(color: .black.opacity(0.06), radius: 1, x: 0, y: 1)
                                    .scaleEffect(1.0)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Capsule())
                        .padding(.horizontal, 8)
                        .frame(minWidth: 160, idealWidth: 180, maxWidth: 280)
                        .frame(height: 58)
                        .disabled(!canPlay || ((playableNode ?? node).playbackURL == nil && (playableNode ?? node).isFolder))

                        if showsMediaServerActions {
                        MacDetailActionIconButton(
                            systemImageName: "captions.bubble",
                            help: platformShellString("Audio & Subtitles"),
                            action: { isShowingPlaybackOptions = true }
                        )
                        .disabled((playableNode ?? node).isFolder)
                        .popover(isPresented: $isShowingPlaybackOptions, arrowEdge: .bottom) {
                            MacPrePlaybackOptionsPopover(
                                server: server,
                                node: playableNode ?? node,
                                isPresented: $isShowingPlaybackOptions,
                                onPlay: onPlay
                            )
                        }

                        MacDetailActionIconButton(
                            systemImageName: "arrow.counterclockwise",
                            help: platformShellString("Replay from Beginning"),
                            action: onPlay // Just triggers play again for now
                        )
                        .disabled((playableNode ?? node).isFolder)

                        MacDetailActionIconButton(
                            systemImageName: isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                            help: platformShellString(isPlayed ? "Mark as Unplayed" : "Mark as Played"),
                            tint: isPlayed ? .green : .white,
                            action: onTogglePlayed
                        )
                        .disabled((playableNode ?? node).isFolder)

                        if !node.isFolder {
                            MacDetailActionIconButton(
                                systemImageName: downloadIcon,
                                help: platformShellString("Downloads"),
                                tint: downloadTint,
                                action: nil,
                                actionWithPoint: { point in
                                    if isDownloaded {
                                        // Could prompt to delete, or ignore. iOS ignores or allows delete in downloaded list.
                                    } else if let jobId = activeJobId {
                                        downloadCenter.cancel(jobId: jobId)
                                    } else {
                                        let userInfo: [AnyHashable: Any] = ["screenPoint": point]
                                        NotificationCenter.default.post(name: NSNotification.Name("MacDownloadAction"), object: nil, userInfo: userInfo)
                                        onDownload()
                                    }
                                }
                            )
                        }

                        MacDetailActionIconButton(
                            systemImageName: isFavorite ? "star.fill" : "star",
                            help: platformShellString("Local Favorites"),
                            tint: isFavorite ? .yellow : .white,
                            action: onFavorite
                        )

                        if let onDelete = onDelete, UserDefaults.standard.bool(forKey: "allowMediaServerDeletion") && (server.type == .jellyfin || server.type == .emby || server.type == .plex) {
                            MacDetailActionIconButton(
                                systemImageName: "trash",
                                help: platformShellString("Delete from Server"),
                                tint: .red,
                                action: onDelete
                            )
                        }
                        }
                        if showsStandaloneFavorite {
                            MacDetailActionIconButton(
                                systemImageName: isFavorite ? "star.fill" : "star",
                                help: platformShellString("Local Favorites"),
                                tint: isFavorite ? .yellow : .white,
                                action: onFavorite
                            )
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 44)
            .padding(.top, 110)
            .padding(.bottom, 24)
        }
    }
}

private struct MacDetailActionIconButton: View {
    let systemImageName: String
    let help: String
    var tint: Color = .white
    var action: (() -> Void)? = nil
    var actionWithPoint: ((CGPoint) -> Void)? = nil

    var body: some View {
        Button(action: {
            action?()
            let screenPoint = NSEvent.mouseLocation
            actionWithPoint?(screenPoint)
        }) {
            Image(systemName: systemImageName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 52, height: 52)
                .background(.white.opacity(0.12), in: Circle())
                .modifier(MacHoverEffect())
        }
        .buttonStyle(.plain)
        .macPointerHover()
        .help(help)
    }
}

private struct MacDetailInfoRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.primary.opacity(0.82))
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 3)
    }
}

final class MacWebAuthContextProvider: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first ?? ASPresentationAnchor()
    }
}

struct MacServerEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var networkService = AppNetworkService.shared

    let existingServer: ServerConfig?
    let prefilledServer: ServerConfig?
    var onSave: ((ServerConfig) -> Void)? = nil

    @State private var type: ServerConfig.ServerType = .smb
    @State private var drafts: [ServerConfig.ServerType: ServerTypeDraft] = [:]
    @State private var vodSourceDrafts: [VODSourceConfig] = []

    @State private var verifiedUserId: String?
    @State private var status: String?
    @State private var testSucceeded = false
    @State private var testFailed = false
    @State private var showServerTypePopover = false
    @State private var isPasswordVisible = false

    // Plex
    @State private var isPlexAuthorizing = false
    @State private var plexPin: PlexLoginPin? = nil
    @State private var plexPollingTask: Task<Void, Never>? = nil
    @State private var verifiedAccessToken: String? = nil

    // 115
    @State private var pan115LoginMode: Int = 0
    @State private var showingPan115WebLogin: Bool = false
    @State private var pan115QRSession: Pan115Manager.QRCodeSessionInfo? = nil
    @State private var pan115QRStatusText: String = ""
    @State private var pan115PollingTask: Task<Void, Never>? = nil

    // OneDrive
    @State private var isOneDriveAuthorizing = false
    @State private var oneDriveAuthSession: ASWebAuthenticationSession? = nil
    @State private var oneDriveAuthContextProvider: MacWebAuthContextProvider? = nil

    // Google Drive
    @State private var isGoogleDriveAuthorizing = false
    @State private var googleDriveAuthSession: ASWebAuthenticationSession? = nil
    @State private var googleDriveAuthContextProvider: MacWebAuthContextProvider? = nil
    @Environment(\.openURL) var openURL

    init(existingServer: ServerConfig?, prefilledServer: ServerConfig? = nil, initialType: ServerConfig.ServerType = .smb, onSave: ((ServerConfig) -> Void)? = nil) {
        self.existingServer = existingServer
        self.prefilledServer = prefilledServer
        self.onSave = onSave

        let targetType: ServerConfig.ServerType
        var initialDrafts: [ServerConfig.ServerType: ServerTypeDraft] = [:]

        if let rawServer = existingServer ?? prefilledServer {
            let server = AppNetworkService.shared.hydratedServer(from: rawServer)
            targetType = server.type
            initialDrafts[server.type] = ServerTypeDraft.initial(for: server.type, existing: server)
        } else {
            targetType = initialType
            initialDrafts[initialType] = ServerTypeDraft.initial(for: initialType, existing: nil)
        }

        _vodSourceDrafts = State(initialValue: (existingServer ?? prefilledServer).map { $0.type == .vod ? $0.macVODSources : [] } ?? [])
        _type = State(initialValue: targetType)
        _drafts = State(initialValue: initialDrafts)
    }

    private var spec: ServerFormSpec {
        ServerFormSpec.spec(for: type)
    }

    private var currentDraft: Binding<ServerTypeDraft> {
        Binding(
            get: {
                if let draft = drafts[type] {
                    return draft
                }
                return ServerTypeDraft.initial(for: type, existing: existingServer)
            },
            set: { newValue in
                drafts[type] = newValue
            }
        )
    }

    private var canSave: Bool {
        currentDraft.wrappedValue.isValidForSave(spec: spec)
            && (type != .vod || MacVODSourcesEditor.valid(vodSourceDrafts))
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {

                    // Server Type Picker
                    VStack(alignment: .leading, spacing: 12) {
                        Text(platformShellString("Server Type"))
                            .font(.headline)

                        Button {
                            showServerTypePopover.toggle()
                        } label: {
                            HStack(spacing: 12) {
                                MacServerTypeIcon(type: type, size: 36)
                                
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(platformShellString("Server Type"))
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                    HStack(spacing: 6) {
                                        Text(type.displayName)
                                            .font(.body.weight(.semibold))
                                            .foregroundColor(.primary)
                                        if type.isBeta {
                                            Text("Beta")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.orange)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1.5)
                                                .background(Color.orange.opacity(0.12))
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                                
                                Spacer()
                                
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(12)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showServerTypePopover, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 0) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(platformShellString("Media Servers"))
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 16)
                                            .padding(.top, 4)

                                        ForEach(ServerConfig.ServerType.mediaTypes, id: \.rawValue) { serverType in
                                            editorServerTypeRow(for: serverType)
                                        }

                                        Divider()
                                            .padding(.vertical, 4)
                                            .padding(.horizontal, 12)

                                        Text(platformShellString("File Protocols"))
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 16)

                                        ForEach(ServerConfig.ServerType.protocolTypes, id: \.rawValue) { serverType in
                                            editorServerTypeRow(for: serverType)
                                        }

                                        Divider()
                                            .padding(.vertical, 4)
                                            .padding(.horizontal, 12)

                                        Text(platformShellString("Live TV"))
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 16)

                                        ForEach(ServerConfig.ServerType.liveTypes, id: \.rawValue) { serverType in
                                            editorServerTypeRow(for: serverType)
                                        }

                                        Divider()
                                            .padding(.vertical, 4)
                                            .padding(.horizontal, 12)

                                        Text(platformShellString("Cloud Drives"))
                                            .font(.caption.weight(.semibold))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 16)

                                        ForEach(ServerConfig.ServerType.cloudTypes, id: \.rawValue) { serverType in
                                            editorServerTypeRow(for: serverType)
                                        }
                                    }
                                    .padding(.vertical, 8)
                                }
                            }
                            .frame(width: 260, height: 400)
                        }
                    }

                    // Form fields
                    VStack(spacing: 16) {
                        MacFormField(title: platformShellString("Server Name")) {
                            TextField(platformShellString("Server Name"), text: currentDraft.name)
                                .textFieldStyle(.roundedBorder)
                        }

                        if spec.authStyle == .pan115 {
                            pan115View
                        } else if spec.authStyle == .onedrive {
                            oneDriveView
                        } else if spec.authStyle == .googledrive {
                            googleDriveView
                        } else if spec.authStyle == .iptv {
                            iptvView
                        } else if spec.authStyle == .vod {
                            vodView
                        } else {
                            standardConnectionView
                            credentialsView
                        }
                    }

                    if let status {
                        Text(status)
                            .foregroundColor(status.contains("失败") || status.contains("Failed") || status.contains("error") ? .red : .green)
                            .font(.callout)
                    }
                }
                .padding(20)
            }

            Divider()

            // Footer
            HStack {
                Button(platformShellString("Test Connection"), action: testConnection)
                    .buttonStyle(.bordered)
                Spacer()
                Button(platformShellString("Cancel")) { dismiss() }
                    .buttonStyle(.bordered)
                Button(platformShellString("Save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(20)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 500, height: 600)
        .sheet(isPresented: $showingPan115WebLogin) {
            Pan115WebLoginSheet { capturedCookie in
                showingPan115WebLogin = false
                self.currentDraft.password.wrappedValue = capturedCookie
                self.currentDraft.accessToken.wrappedValue = capturedCookie
                self.testSucceeded = true
                self.testFailed = false
                self.status = platformShellString("Authorization successful!")
            }
        }
        .onDisappear {
            pan115PollingTask?.cancel()
            plexPollingTask?.cancel()
            oneDriveAuthSession?.cancel()
        }
    }

    // MARK: - Subviews
    @ViewBuilder
    private var pan115View: some View {
        let isAuthorized = !currentDraft.accessToken.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                           !currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(spacing: 16) {
            Picker("", selection: $pan115LoginMode) {
                Text(platformShellString("QR Code Login")).tag(0)
                Text(platformShellString("Web Login")).tag(1)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
            .onChange(of: pan115LoginMode) { newMode in
                if newMode == 0 {
                    if pan115QRSession == nil && pan115PollingTask == nil {
                        loadPan115QRCode()
                    }
                } else {
                    pan115PollingTask?.cancel()
                }
            }

            if pan115LoginMode == 1 {
                VStack(spacing: 16) {
                    HStack(spacing: 14) {
                        MacServerTypeIcon(type: .pan115, size: 36)

                        VStack(alignment: .leading, spacing: 3) {
                            Text(platformShellString("115 Account Authorization"))
                                .font(.headline)
                            Text(platformShellString("Log in via official 115 web page with SMS, password, or WeChat. GenPlayer will automatically authorize and capture credentials."))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)

                    if isAuthorized {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(platformShellString("Connection Successful"))
                                    .font(.body.weight(.medium))
                                    .foregroundColor(.primary)
                                Text(platformShellString("115"))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(platformShellString("Re-authorize Device")) {
                                showingPan115WebLogin = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(14)
                        .background(Color.green.opacity(0.08))
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.green.opacity(0.2), lineWidth: 1)
                        )
                    } else {
                        Button(action: { showingPan115WebLogin = true }) {
                            HStack(spacing: 8) {
                                Image(systemName: "globe")
                                    .font(.headline)
                                Text(platformShellString("Sign in on 115.com"))
                                    .font(.body.weight(.semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 12) {
                    if let qr = pan115QRSession {
                        AsyncImage(url: qr.qrCodeURL) { phase in
                            switch phase {
                            case .empty:
                                ProgressView().frame(width: 180, height: 180)
                            case .success(let image):
                                image
                                    .resizable()
                                    .interpolation(.none)
                                    .scaledToFit()
                                    .frame(width: 180, height: 180)
                                    .cornerRadius(10)
                                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                            case .failure:
                                VStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle").foregroundColor(.orange)
                                    Text(platformShellString("Failed to load QR code")).font(.caption).foregroundColor(.secondary)
                                    Button(platformShellString("Retry")) { loadPan115QRCode(force: true) }.buttonStyle(.bordered)
                                }
                                .frame(width: 180, height: 180)
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)

                        Text(pan115QRStatusText.isEmpty ? platformShellString("Scan with 115 Mobile App") : pan115QRStatusText)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Button(action: { loadPan115QRCode(force: true) }) {
                            Label(platformShellString("Refresh QR Code"), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        ProgressView().frame(width: 180, height: 180)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .onAppear {
                                if pan115LoginMode == 0 && pan115QRSession == nil && pan115PollingTask == nil {
                                    loadPan115QRCode()
                                }
                            }
                    }
                }
                .padding(.vertical, 4)
            }

            cloudBetaDisclaimerView
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var oneDriveView: some View {
        let isAuthorized = !currentDraft.accessToken.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                           !currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(spacing: 16) {
            HStack(spacing: 14) {
                MacServerTypeIcon(type: .onedrive, size: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(platformShellString("Microsoft Account Authorization"))
                        .font(.headline)
                    Text(platformShellString("Sign in securely with your personal, work, or school Microsoft Account via official Microsoft authentication."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

            if isAuthorized {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(platformShellString("Connection Successful"))
                            .font(.body.weight(.medium))
                            .foregroundColor(.primary)
                        Text(platformShellString("Connect to OneDrive"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(platformShellString("Re-authorize Device")) {
                        startOneDriveSignIn()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(14)
                .background(Color.green.opacity(0.08))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.green.opacity(0.2), lineWidth: 1)
                )
            } else {
                Button(action: startOneDriveSignIn) {
                    HStack(spacing: 8) {
                        if isOneDriveAuthorizing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "lock.shield")
                                .font(.headline)
                        }
                        Text(isOneDriveAuthorizing ? platformShellString("Signing in...") : platformShellString("Sign in with Microsoft"))
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isOneDriveAuthorizing)
            }

            cloudBetaDisclaimerView
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var googleDriveView: some View {
        let isAuthorized = !currentDraft.accessToken.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                           !currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        VStack(spacing: 16) {
            HStack(spacing: 14) {
                MacServerTypeIcon(type: .googledrive, size: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(platformShellString("Google Account Authorization"))
                        .font(.headline)
                    Text(platformShellString("Sign in securely with your Google Account via official Google authentication."))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)

            if isAuthorized {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(platformShellString("Connection Successful"))
                            .font(.body.weight(.medium))
                            .foregroundColor(.primary)
                        Text(platformShellString("Connect to Google Drive"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button(platformShellString("Re-authorize Device")) {
                        startGoogleDriveSignIn()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(14)
                .background(Color.green.opacity(0.08))
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.green.opacity(0.2), lineWidth: 1)
                )
            } else {
                Button(action: startGoogleDriveSignIn) {
                    HStack(spacing: 8) {
                        if isGoogleDriveAuthorizing {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "lock.shield")
                                .font(.headline)
                        }
                        Text(isGoogleDriveAuthorizing ? platformShellString("Signing in...") : platformShellString("Sign in with Google"))
                            .font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isGoogleDriveAuthorizing)
            }

            cloudBetaDisclaimerView
        }
        .padding(.vertical, 8)
    }

    private var cloudBetaDisclaimerView: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.footnote)
                .foregroundColor(.orange)
                .padding(.top, 1)

            Text(platformShellString("Cloud Drive Beta Disclaimer"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(Color.orange.opacity(0.06))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.15), lineWidth: 1)
        )
    }


    @ViewBuilder
    private var iptvView: some View {
        MacFormField(title: platformShellString("Playlist URL or File Path")) {
            TextField("https://example.com/playlist.m3u", text: currentDraft.address)
                .textFieldStyle(.roundedBorder)
        }

        MacFormField(title: platformShellString("EPG URL (optional)")) {
            TextField("https://example.com/epg.xml.gz", text: currentDraft.customEPGURL)
                .textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder
    private var vodView: some View {
        MacVODSourcesEditor(sources: $vodSourceDrafts)
            .onAppear {
                if vodSourceDrafts.isEmpty {
                    vodSourceDrafts = [VODSourceConfig(name: currentDraft.wrappedValue.name, address: currentDraft.wrappedValue.address)]
                }
            }
            .onChange(of: vodSourceDrafts) { sources in
                currentDraft.wrappedValue.address = sources.first(where: \.isEnabled)?.address ?? ""
            }
    }

    @ViewBuilder
    private var standardConnectionView: some View {
        HStack(spacing: 16) {
            if spec.requiresAddressInput {
                MacFormField(title: platformShellString("Address")) {
                    TextField(spec.addressPlaceholder, text: currentDraft.address)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if spec.requiresPortInput {
                let defaultPortText = "\(spec.defaultPort(useSSL: currentDraft.useSSL.wrappedValue))"
                MacFormField(title: platformShellString("Port")) {
                    TextField(defaultPortText, text: currentDraft.portString)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                }
            }
        }

        if spec.allowsSSL {
            Toggle(platformShellString("HTTPS"), isOn: currentDraft.useSSL)
                .toggleStyle(.switch)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var credentialsView: some View {
        if spec.authStyle == .plex {
            HStack(alignment: .bottom, spacing: 16) {
                MacFormField(title: platformShellString("Access Token")) {
                    TextField(platformShellString("Access Token"), text: currentDraft.accessToken)
                        .textFieldStyle(.roundedBorder)
                }
                
                Button(action: startPlexLogin) {
                    if isPlexAuthorizing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(platformShellString("Sign in with Plex"))
                    }
                }
                .buttonStyle(.bordered)
                .disabled(currentDraft.address.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPlexAuthorizing)
            }
        } else {
            HStack(spacing: 16) {
                MacFormField(title: platformShellString("Username")) {
                    TextField(platformShellString("Username"), text: currentDraft.username)
                        .textFieldStyle(.roundedBorder)
                }

                MacFormField(title: platformShellString("Password")) {
                    ZStack(alignment: .trailing) {
                        if isPasswordVisible {
                            TextField(platformShellString("Password"), text: currentDraft.password)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            SecureField(platformShellString("Password"), text: currentDraft.password)
                                .textFieldStyle(.roundedBorder)
                        }
                        
                        Button(action: { isPasswordVisible.toggle() }) {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                                .padding(.trailing, 8)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if spec.showsWorkgroup {
                MacFormField(title: platformShellString("Workgroup (optional)")) {
                    TextField(platformShellString("Workgroup (optional)"), text: currentDraft.workgroup)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func editorServerTypeRow(for serverType: ServerConfig.ServerType) -> some View {
        Button {
            type = serverType
            showServerTypePopover = false
            pan115PollingTask?.cancel()
            plexPollingTask?.cancel()
            oneDriveAuthSession?.cancel()

            if drafts[serverType] == nil {
                drafts[serverType] = ServerTypeDraft.initial(for: serverType, existing: existingServer)
            }
            if serverType == .pan115 {
                if pan115LoginMode == 0 && currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    loadPan115QRCode()
                }
            }
        } label: {
            HStack(spacing: 12) {
                MacServerTypeIcon(type: serverType, size: 26)
                Text(serverType.displayName)
                    .strikethrough(serverType == .googledrive)
                    .font(.body)
                    .foregroundColor(.primary)
                if serverType.isBeta {
                    Text("Beta")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }
                Spacer()
                if type == serverType {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .font(.body.weight(.semibold))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(type == serverType ? Color.accentColor.opacity(0.1) : Color.clear)
    }

    private func loadPan115QRCode(force: Bool = false) {
        if !force && (pan115QRSession != nil || pan115PollingTask != nil) {
            return
        }
        pan115PollingTask?.cancel()
        pan115QRSession = nil
        pan115QRStatusText = platformShellString("Scan with 115 Mobile App")
        pan115PollingTask = Task {
            do {
                let session = try await Pan115Manager.shared.fetchQRCode()
                if Task.isCancelled { return }
                await MainActor.run {
                    self.pan115QRSession = session
                    self.pan115QRStatusText = platformShellString("Scan with 115 Mobile App")
                }
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                    let statusResult = await Pan115Manager.shared.pollQRCodeStatus(session: session)
                    if Task.isCancelled { return }
                    var shouldStop = false
                    await MainActor.run {
                        switch statusResult {
                        case .waiting:
                            self.pan115QRStatusText = platformShellString("Scan with 115 Mobile App")
                        case .scanned:
                            self.pan115QRStatusText = platformShellString("Scanned. Please confirm on phone.")
                        case .success(let cookie):
                            self.pan115QRStatusText = platformShellString("Authorization successful!")
                            if !cookie.isEmpty {
                                self.currentDraft.password.wrappedValue = cookie
                                self.currentDraft.accessToken.wrappedValue = cookie
                                self.testSucceeded = true
                                self.testFailed = false
                                self.status = platformShellString("Authorization successful!")
                            }
                            shouldStop = true
                        case .expired:
                            self.pan115QRStatusText = platformShellString("QR code expired. Click to reload.")
                            shouldStop = true
                        case .error(let err):
                            self.pan115QRStatusText = err
                            shouldStop = true
                        }
                    }
                    if shouldStop {
                        break
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.pan115QRStatusText = error.localizedDescription
                }
            }
        }
    }

    private func startPlexLogin() {
        guard type == .plex else { return }

        plexPollingTask?.cancel()
        isPlexAuthorizing = true
        plexPin = nil

        plexPollingTask = Task {
            do {
                let pin = try await PlexPinAuthorizationService.shared.createLoginPin()
                guard let loginURL = PlexPinAuthorizationService.shared.linkURL(for: pin) else {
                    throw NSError(
                        domain: "GenPlayer",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: platformShellString("Failed to build Plex login URL")]
                    )
                }

                await MainActor.run {
                    plexPin = pin
                    openURL(loginURL)
                }

                for _ in 0..<60 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                    let polled = try await PlexPinAuthorizationService.shared.pollLoginPin(id: pin.id, code: pin.code)
                    if let token = polled.authToken, !token.isEmpty {
                        await MainActor.run {
                            verifiedAccessToken = token
                            self.currentDraft.accessToken.wrappedValue = token
                            testSucceeded = false
                            testFailed = false
                            isPlexAuthorizing = false
                            plexPin = nil
                        }
                        return
                    }
                }

                await MainActor.run {
                    isPlexAuthorizing = false
                    plexPin = nil
                    status = platformShellString("Plex login timed out. Please try again.")
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isPlexAuthorizing = false
                    plexPin = nil
                    status = error.localizedDescription
                }
            }
        }
    }

    private func startOneDriveSignIn() {
        guard type == .onedrive else { return }
        isOneDriveAuthorizing = true
        let pkce = OneDriveManager.generatePKCE()

        guard let authURL = OneDriveManager.buildAuthorizationURL(challenge: pkce.challenge) else {
            isOneDriveAuthorizing = false
            status = platformShellString("Connection Failed")
            return
        }

        let contextProvider = MacWebAuthContextProvider()
        self.oneDriveAuthContextProvider = contextProvider

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "genplayer") { callbackURL, error in
            DispatchQueue.main.async {
                self.isOneDriveAuthorizing = false
            }

            if let error = error {
                if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                    return
                }
                DispatchQueue.main.async {
                    self.status = error.localizedDescription
                }
                return
            }

            guard let callbackURL = callbackURL,
                  let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                DispatchQueue.main.async {
                    self.status = platformShellString("Authorization code not returned.")
                }
                return
            }

            Task {
                do {
                    let tokenResponse = try await OneDriveManager.shared.exchangeCodeForTokens(code: code, verifier: pkce.verifier)
                    await MainActor.run {
                        var draft = self.currentDraft.wrappedValue
                        draft.accessToken = tokenResponse.accessToken
                        draft.password = tokenResponse.refreshToken ?? tokenResponse.accessToken
                        if draft.name.isEmpty || draft.name == "OneDrive" {
                            draft.name = tokenResponse.displayName.isEmpty ? "OneDrive" : "OneDrive - \(tokenResponse.displayName)"
                        }
                        self.currentDraft.wrappedValue = draft
                        self.verifiedAccessToken = tokenResponse.accessToken
                        self.testSucceeded = true
                        self.testFailed = false
                        self.status = platformShellString("Connection Successful")
                    }
                } catch {
                    await MainActor.run {
                        self.status = "\(platformShellString("Connection Failed")): \(error.localizedDescription)"
                    }
                }
            }
        }

        session.presentationContextProvider = contextProvider
        session.prefersEphemeralWebBrowserSession = false
        self.oneDriveAuthSession = session
        session.start()
    }

    private func startGoogleDriveSignIn() {
        guard type == .googledrive else { return }
        isGoogleDriveAuthorizing = true
        let pkce = GoogleDriveManager.generatePKCE()

        guard let authURL = GoogleDriveManager.buildAuthorizationURL(challenge: pkce.challenge) else {
            isGoogleDriveAuthorizing = false
            status = platformShellString("Connection Failed")
            return
        }

        let contextProvider = MacWebAuthContextProvider()
        self.googleDriveAuthContextProvider = contextProvider

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: GoogleDriveManager.callbackScheme) { callbackURL, error in
            DispatchQueue.main.async {
                self.isGoogleDriveAuthorizing = false
            }

            if let error = error {
                if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                    return
                }
                DispatchQueue.main.async {
                    self.status = error.localizedDescription
                }
                return
            }

            guard let callbackURL = callbackURL,
                  let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                DispatchQueue.main.async {
                    self.status = platformShellString("Authorization code not returned.")
                }
                return
            }

            Task {
                do {
                    let tokenResponse = try await GoogleDriveManager.shared.exchangeCodeForTokens(code: code, verifier: pkce.verifier)
                    await MainActor.run {
                        var draft = self.currentDraft.wrappedValue
                        draft.accessToken = tokenResponse.accessToken
                        if !tokenResponse.refreshToken.isEmpty {
                            draft.password = tokenResponse.refreshToken
                        }
                        if draft.name.isEmpty || draft.name == "Google Drive" {
                            draft.name = tokenResponse.displayName.isEmpty ? "Google Drive" : "Google Drive - \(tokenResponse.displayName)"
                        }
                        self.currentDraft.wrappedValue = draft
                        self.verifiedAccessToken = tokenResponse.accessToken
                        self.testSucceeded = true
                        self.testFailed = false
                        self.status = platformShellString("Connection Successful")
                    }
                } catch {
                    await MainActor.run {
                        self.status = "\(platformShellString("Connection Failed")): \(error.localizedDescription)"
                    }
                }
            }
        }

        session.presentationContextProvider = contextProvider
        session.prefersEphemeralWebBrowserSession = false
        self.googleDriveAuthSession = session
        session.start()
    }

    private func save() {
        let draft = currentDraft.wrappedValue
        var server = draft.buildServerConfig(type: type, id: existingServer?.id ?? UUID())
        if type == .vod {
            server.vodSources = vodSourceDrafts.map { source in
                var value = source
                value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
                value.address = value.address.trimmingCharacters(in: .whitespacesAndNewlines)
                return value
            }
            server.address = server.vodSources?.first(where: \.isEnabled)?.address ?? server.address
        }


        let hydratedExisting = existingServer.map { AppNetworkService.shared.hydratedServer(from: $0) }

        let connectionSettingsChanged: Bool
        if let hydratedExisting {
            connectionSettingsChanged =
                hydratedExisting.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != server.address.lowercased() ||
                hydratedExisting.port != server.port ||
                hydratedExisting.useSSL != server.useSSL ||
                hydratedExisting.type != type ||
                hydratedExisting.username?.trimmingCharacters(in: .whitespacesAndNewlines) != server.username ||
                hydratedExisting.passwordSecret != server.passwordSecret ||
                hydratedExisting.workgroup?.trimmingCharacters(in: .whitespacesAndNewlines) != server.workgroup
        } else {
            connectionSettingsChanged = true
        }

        var finalAccessToken: String? = nil
        var finalUserId: String? = nil

        // PIN authorization and server reachability are separate: keep the current Plex
        // credential even before a successful probe, including when replacing an old token.
        if type == .plex {
            finalAccessToken = server.accessToken
        } else if testSucceeded {
            finalAccessToken = verifiedAccessToken ?? draft.accessToken.nilIfEmpty
            finalUserId = verifiedUserId
        } else if !testFailed && !connectionSettingsChanged, let existing = hydratedExisting, existing.type == type {
            finalAccessToken = existing.accessToken
            finalUserId = existing.userId
        } else if !testFailed, let existing = hydratedExisting, existing.type == type, !draft.accessToken.isEmpty {
            finalAccessToken = draft.accessToken.nilIfEmpty ?? existing.accessToken
            finalUserId = verifiedUserId ?? existing.userId
        } else if type.isCloudDrive {
            finalAccessToken = draft.accessToken.nilIfEmpty
        }

        server.accessToken = finalAccessToken
        server.userId = finalUserId

        if let existingServer {
            server.id = existingServer.id
            if finalAccessToken == nil && connectionSettingsChanged && !type.isCloudDrive {
                networkService.clearServerAuthTokens(for: existingServer.id)
            }
            networkService.updateServer(server)
        } else {
            networkService.addServer(server)
        }
        onSave?(server)
        dismiss()
    }

    private func testConnection() {
        if type == .onedrive {
            let token = verifiedAccessToken ?? currentDraft.accessToken.wrappedValue.nilIfEmpty
            guard let token, !token.isEmpty else {
                status = platformShellString("Sign in with Microsoft")
                testSucceeded = false
                testFailed = true
                return
            }
            status = platformShellString("Platform Shell TV Loading")
            let probe = currentDraft.wrappedValue.buildServerConfig(type: .onedrive)
            Task {
                do {
                    _ = try await networkService.testConnection(probe)
                    await MainActor.run {
                        testSucceeded = true
                        testFailed = false
                        status = platformShellString("Connection Successful")
                    }
                } catch {
                    await MainActor.run {
                        testSucceeded = false
                        testFailed = true
                        status = "\(platformShellString("Connection Failed")): \(error.localizedDescription)"
                    }
                }
            }
            return
        }

        if type == .googledrive {
            let token = verifiedAccessToken ?? currentDraft.accessToken.wrappedValue.nilIfEmpty
            guard let token, !token.isEmpty else {
                status = platformShellString("Sign in with Google")
                testSucceeded = false
                testFailed = true
                return
            }
            status = platformShellString("Platform Shell TV Loading")
            var probe = currentDraft.wrappedValue.buildServerConfig(type: .googledrive)
            probe.accessToken = token
            if let pass = currentDraft.password.wrappedValue.nilIfEmpty {
                probe.passwordSecret = pass
            }
            Task {
                do {
                    _ = try await networkService.testConnection(probe)
                    await MainActor.run {
                        testSucceeded = true
                        testFailed = false
                        status = platformShellString("Connection Successful")
                    }
                } catch {
                    await MainActor.run {
                        testSucceeded = false
                        testFailed = true
                        status = "\(platformShellString("Connection Failed")): \(error.localizedDescription)"
                    }
                }
            }
            return
        }

        if type == .pan115 {
            let hasCookie = !currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasCookie {
                testSucceeded = true
                testFailed = false
                status = platformShellString("Connection Successful")
            } else {
                testSucceeded = false
                testFailed = true
                status = platformShellString("Please scan QR code or log in via Web first.")
            }
            return
        }

        if type == .iptv {
            let trimmed = currentDraft.address.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                status = platformShellString("Playlist URL or File Path cannot be empty")
                return
            }
            status = platformShellString("Platform Shell TV Loading")
            let probe = currentDraft.wrappedValue.buildServerConfig(type: .iptv)
            Task {
                do {
                    _ = try await IPTVService.shared.fetchPlaylist(for: probe, forceRefresh: true)
                    await MainActor.run {
                        testSucceeded = true
                        testFailed = false
                        status = platformShellString("Connection Successful")
                    }
                } catch {
                    await MainActor.run {
                        testSucceeded = false
                        testFailed = true
                        status = "\(platformShellString("Connection Failed")): \(error.localizedDescription)"
                    }
                }
            }
            return
        }

        let probe = currentDraft.wrappedValue.buildServerConfig(type: type)
        status = platformShellString("Platform Shell TV Loading")
        Task {
            do {
                let checked = try await macTestServerConnection(probe)
                await MainActor.run {
                    testSucceeded = true
                    testFailed = false
                    verifiedAccessToken = checked.accessToken
                    self.currentDraft.accessToken.wrappedValue = checked.accessToken ?? self.currentDraft.accessToken.wrappedValue
                    verifiedUserId = checked.userId ?? verifiedUserId
                    self.currentDraft.useSSL.wrappedValue = checked.useSSL
                    if let port = checked.port { self.currentDraft.portString.wrappedValue = String(port) }
                    status = platformShellString("Connection Successful")
                }
            } catch {
                await MainActor.run {
                    testSucceeded = false
                    testFailed = true
                    verifiedAccessToken = nil
                    verifiedUserId = nil
                    status = "\(platformShellString("Connection Failed")): \(error.localizedDescription)"
                }
            }
        }
    }
}

struct MacServerDiscoveryView: View {
    @ObservedObject private var discoveryService = PlatformServerDiscoveryService.shared
    @Environment(\.presentationMode) var presentationMode

    var onUseServer: (ServerConfig) -> Void

    var body: some View {
        VStack {
            HStack {
                Text(platformShellString("Discovered Servers"))
                    .font(.headline)
                Spacer()
                Button(action: { discoveryService.startDiscovery() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                Button(platformShellString("Close")) {
                    presentationMode.wrappedValue.dismiss()
                }
                .buttonStyle(.bordered)
            }
            .padding()
            
            if discoveryService.discoveredServers.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "network")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning local network for media servers...")
                            .font(.subheadline)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(discoveryService.discoveredServers) { discoveredServer in
                    let config = discoveryService.createServerConfig(from: discoveredServer)
                    HStack(spacing: 16) {
                        MacServerTypeIcon(type: config.type, size: 40)
                            .padding(8)
                            .background(Color.accentColor.opacity(0.1))
                            .cornerRadius(10)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(discoveredServer.name)
                                .font(.headline)
                            Text("\(discoveredServer.type.displayName) · \(discoveredServer.address):\(String(discoveredServer.port))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Button(action: {
                            onUseServer(config)
                            presentationMode.wrappedValue.dismiss()
                        }) {
                            Text(platformShellString("Add Server"))
                                .fontWeight(.medium)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                    .padding(.vertical, 8)
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 500, minHeight: 400)
        .background(Color(NSColor.controlBackgroundColor))
        .onAppear { discoveryService.startDiscovery() }
        .onDisappear { discoveryService.stopDiscovery() }
    }
}
struct MacMediaLibraryNode: Identifiable, Hashable {
    let id: String
    let name: String
    let type: VideoFile.FileType
    let isFolder: Bool
    let remotePath: String?
    let posterURL: URL?
    let backdropURL: URL?
    let playbackURL: URL?
    var logoURLs: [URL] = []
    var logoURL: URL? {
        get { logoURLs.first }
        set {
            if let newValue {
                if !logoURLs.contains(newValue) { logoURLs.insert(newValue, at: 0) }
            } else {
                logoURLs.removeAll()
            }
        }
    }
    var collectionType: String? = nil
    var summary: String? = nil
    var metadataLine: String? = nil
    var technicalMetadataLine: String? = nil
    var isLibraryRoot: Bool = false
    var playbackPositionTicks: Int64? = nil
    var runTimeTicks: Int64? = nil
    var lastPlayedDate: Date? = nil
    var dateCreated: Date? = nil
    var premiereDate: Date? = nil
    var seriesId: String? = nil
    var seriesName: String? = nil
    var seasonId: String? = nil
    var isFavorite: Bool = false
    var isPlayed: Bool = false
    var indexNumber: Int? = nil
    var parentIndexNumber: Int? = nil
    var communityRating: Double? = nil
    var itemCount: Int? = nil

    init(
        id: String,
        name: String,
        type: VideoFile.FileType,
        isFolder: Bool,
        remotePath: String? = nil,
        posterURL: URL? = nil,
        backdropURL: URL? = nil,
        playbackURL: URL? = nil,
        logoURLs: [URL] = [],
        collectionType: String? = nil,
        summary: String? = nil,
        metadataLine: String? = nil,
        technicalMetadataLine: String? = nil,
        isLibraryRoot: Bool = false,
        playbackPositionTicks: Int64? = nil,
        runTimeTicks: Int64? = nil,
        lastPlayedDate: Date? = nil,
        dateCreated: Date? = nil,
        premiereDate: Date? = nil,
        seriesId: String? = nil,
        seriesName: String? = nil,
        seasonId: String? = nil,
        isFavorite: Bool = false,
        isPlayed: Bool = false,
        indexNumber: Int? = nil,
        parentIndexNumber: Int? = nil,
        communityRating: Double? = nil,
        itemCount: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isFolder = isFolder
        self.remotePath = remotePath
        self.posterURL = posterURL
        self.backdropURL = backdropURL
        self.playbackURL = playbackURL
        self.logoURLs = logoURLs
        self.collectionType = collectionType
        self.summary = summary
        self.metadataLine = metadataLine
        self.technicalMetadataLine = technicalMetadataLine
        self.isLibraryRoot = isLibraryRoot
        self.playbackPositionTicks = playbackPositionTicks
        self.runTimeTicks = runTimeTicks
        self.lastPlayedDate = lastPlayedDate
        self.dateCreated = dateCreated
        self.premiereDate = premiereDate
        self.seriesId = seriesId
        self.seriesName = seriesName
        self.seasonId = seasonId
        self.isFavorite = isFavorite
        self.isPlayed = isPlayed
        self.indexNumber = indexNumber
        self.parentIndexNumber = parentIndexNumber
        self.communityRating = communityRating
        self.itemCount = itemCount
    }

    var heroTitle: String {
        guard collectionType?.lowercased() == "episode",
              let title = seriesName?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return name }
        return title
    }

    var heroEpisodeSubtitle: String? {
        guard collectionType?.lowercased() == "episode" else { return nil }
        var components: [String] = []
        let season = parentIndexNumber.map { String(format: "S%02d", $0) } ?? ""
        let episode = indexNumber.map { String(format: "E%02d", $0) } ?? ""
        if !(season + episode).isEmpty { components.append(season + episode) }
        if heroTitle != name { components.append(name) }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    var jellyfinLibraryType: JellyfinLibrary.LibraryType {
        switch collectionType?.lowercased() {
        case "movies", "movie": return .movies
        case "tvshows", "show": return .tvShows
        case "music", "artist": return .music
        case "homevideos", "photos", "photo": return .photos
        case "boxsets": return .collections
        case "playlists": return .playlists
        default: return .mixed
        }
    }
}

func fetchNodes(server: ServerConfig, parentNode: MacMediaLibraryNode?, startIndex: Int? = nil, limit: Int? = nil, sortBy: String? = nil, sortOrder: String? = nil, year: String? = nil, genre: String? = nil) async throws -> [MacMediaLibraryNode] {
    switch server.type {
    case .jellyfin, .emby:
        return try await fetchJellyfinLikeNodes(server: server, parentNode: parentNode, startIndex: startIndex, limit: limit, sortBy: sortBy, sortOrder: sortOrder, year: year, genre: genre)
    case .plex:
        return try await fetchPlexNodes(server: server, parentNode: parentNode, startIndex: startIndex, limit: limit)
    case .smb, .webdav, .alist, .ftp, .sftp, .nfs:
        let path = parentNode?.remotePath ?? "/"
        let files = try await AppNetworkService.shared.fetchContents(for: server, at: path)
        let nodes = files.map { file in
            let sizeStr = file.type == .folder ? nil : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
            return MacMediaLibraryNode(
                id: file.serverPath ?? file.url.path,
                name: file.name,
                type: file.type,
                isFolder: file.type == .folder,
                remotePath: file.serverPath ?? file.url.path,
                posterURL: nil,
                backdropURL: nil,
                playbackURL: file.isRemote ? file.url : nil,
                collectionType: nil,
                summary: sizeStr,
                metadataLine: sizeStr,
                technicalMetadataLine: nil
            )
        }
        if let limit = limit {
            return Array(nodes.prefix(limit))
        }
        return nodes
    default:
        return []
    }
}

private func fetchMacJellyfinHeroEntries(server: ServerConfig) async throws -> [MacHomeCarouselEntry] {
    guard server.type == .jellyfin,
          let userId = try await resolvedMediaLibraryUserId(server: server) else { return [] }
    let entries = try await JellyfinHomeCarousel.load(server: server, userId: userId, token: server.accessToken ?? "")
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return try entries.compactMap { entry in
        let data = try JSONEncoder().encode(entry.item)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let node = parseJellyfinItems([json], baseURL: baseURL, server: server,
                                            usesCarouselArtworkFallbacks: true).first else { return nil }
        return MacHomeCarouselEntry(node: node, sourceTitle: platformShellString(entry.source.titleKey),
                                   sourceSystemImageName: entry.source.systemImage)
    }
}

private func fetchMacResumeNodes(server: ServerConfig) async throws -> [MacMediaLibraryNode] {
    switch server.type {
    case .jellyfin, .emby:
        return try await fetchJellyfinResumeNodes(server: server)
    case .plex:
        return try await fetchPlexContinueWatchingNodes(server: server, limit: 20)
    default:
        return []
    }
}

private func fetchMacLatestNodes(server: ServerConfig) async throws -> [MacMediaLibraryNode] {
    switch server.type {
    case .jellyfin, .emby:
        return try await fetchJellyfinLatestNodes(server: server, limit: 16)
    case .plex:
        return try await fetchPlexRecentlyAddedNodes(server: server, limit: 16)
    default:
        return []
    }
}

private func fetchMacFavoriteNodes(server: ServerConfig) async throws -> [MacMediaLibraryNode] {
    switch server.type {
    case .jellyfin, .emby:
        return try await fetchJellyfinFavoriteNodes(server: server, limit: 24)
    default:
        return []
    }
}

func macSortNodes(
    _ nodes: [MacMediaLibraryNode],
    sortBy: String = "DateCreated",
    isAscending: Bool = false
) -> [MacMediaLibraryNode] {
    var seenIDs = Set<String>()
    let uniqueNodes = nodes.filter { seenIDs.insert($0.id).inserted }
    return uniqueNodes.sorted { (a: MacMediaLibraryNode, b: MacMediaLibraryNode) in
        switch sortBy {
        case "DateCreated":
            let dateA = a.dateCreated ?? Date.distantPast
            let dateB = b.dateCreated ?? Date.distantPast
            return isAscending ? dateA < dateB : dateA > dateB
        case "PremiereDate":
            let dateA = a.premiereDate ?? Date.distantPast
            let dateB = b.premiereDate ?? Date.distantPast
            return isAscending ? dateA < dateB : dateA > dateB
        case "ProductionYear":
            let yearA = a.premiereDate?.timeIntervalSince1970 ?? 0
            let yearB = b.premiereDate?.timeIntervalSince1970 ?? 0
            return isAscending ? yearA < yearB : yearA > yearB
        case "CommunityRating":
            let ratingA = a.communityRating ?? -1.0
            let ratingB = b.communityRating ?? -1.0
            return isAscending ? ratingA < ratingB : ratingA > ratingB
        case "Resolution":
            let resA = a.technicalMetadataLine ?? ""
            let resB = b.technicalMetadataLine ?? ""
            return isAscending ? resA < resB : resA > resB
        case "Runtime":
            let timeA = a.runTimeTicks ?? 0
            let timeB = b.runTimeTicks ?? 0
            return isAscending ? timeA < timeB : timeA > timeB
        case "SortName":
            fallthrough
        default:
            return isAscending ? a.name.localizedStandardCompare(b.name) == .orderedAscending : a.name.localizedStandardCompare(b.name) == .orderedDescending
        }
    }
}

private func fetchLibraryPreviewNodes(server: ServerConfig, library: MacMediaLibraryNode, limit: Int) async throws -> [MacMediaLibraryNode] {
    switch server.type {
    case .jellyfin, .emby:
        let fetchCount = max(limit * 3, 36)
        let nodes = try await fetchNodes(
            server: server,
            parentNode: library,
            startIndex: 0,
            limit: fetchCount,
            sortBy: "DateCreated",
            sortOrder: "Descending"
        )
        let sorted = macSortNodes(nodes, sortBy: "DateCreated", isAscending: false)
        return Array(sorted.prefix(limit))
    case .plex:
        let recent = try await fetchPlexLibraryRecentlyAddedNodes(server: server, libraryId: library.id, libraryType: library.collectionType, limit: limit)
        if !recent.isEmpty { return recent }
        let nodes = try await fetchNodes(server: server, parentNode: library, limit: limit)
        return Array(nodes.prefix(limit))
    default:
        let nodes = try await fetchNodes(server: server, parentNode: library, limit: limit)
        return Array(nodes.prefix(limit))
    }
}

private func fetchRealMacLibraryItemCount(server: ServerConfig, node: MacMediaLibraryNode) async -> Int? {
    let activeServer = AppNetworkService.shared.hydratedServer(from: server)
    if activeServer.type == .plex {
        let baseURL = activeServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: "\(baseURL)/library/sections/\(node.id)/all") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "0")
        ]
        guard let rawURL = components.url else { return nil }
        let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
        var request = URLRequest(url: url)
        applyMediaLibraryHeaders(to: &request, server: activeServer)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = json["MediaContainer"] as? [String: Any],
              let total = (container["totalSize"] as? Int) ?? (container["size"] as? Int) else {
            return nil
        }
        return total
    } else if activeServer.type == .jellyfin || activeServer.type == .emby {
        guard let userId = try? await resolvedMediaLibraryUserId(server: activeServer), !userId.isEmpty else { return nil }
        let baseURL = activeServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items") else { return nil }
        var includeItemTypes: String? = nil
        if let type = node.collectionType?.lowercased() {
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
            URLQueryItem(name: "Limit", value: "0")
        ]
        if let types = includeItemTypes, !types.isEmpty {
            queryItems.append(URLQueryItem(name: "IncludeItemTypes", value: types))
        }
        components.queryItems = queryItems
        guard let rawURL = components.url else { return nil }
        let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
        var request = URLRequest(url: url)
        applyMediaLibraryHeaders(to: &request, server: activeServer)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = (json["TotalRecordCount"] as? Int) ?? (json["TotalRecordCount"] as? Int64).map(Int.init) else {
            return nil
        }
        return total
    }
    return nil
}

private func fetchJellyfinLikeNodes(server: ServerConfig, parentNode: MacMediaLibraryNode?, startIndex: Int? = nil, limit: Int? = nil, sortBy: String? = nil, sortOrder: String? = nil, year: String? = nil, genre: String? = nil) async throws -> [MacMediaLibraryNode] {
    guard let userId = try await resolvedMediaLibraryUserId(server: server), !userId.isEmpty else {
        throw NSError(domain: "GenPlayerShell", code: 401, userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")])
    }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    var components: URLComponents?
    if let parentNode {
        components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items")
        
        var includeItemTypes = "Folder,CollectionFolder,Series,Season,Movie,Episode,MusicAlbum,Audio,MusicArtist,Photo"
        if let type = parentNode.collectionType?.lowercased() {
            switch type {
            case "movies", "movie": includeItemTypes = "Movie"
            case "tvshows", "series", "show": includeItemTypes = "Series"
            case "music", "audio": includeItemTypes = "MusicAlbum"
            case "boxsets", "collections": includeItemTypes = "BoxSet"
            case "playlists": includeItemTypes = "Playlist"
            default: break
            }
        }
        
        // When filtering by year or genre, we are searching for actual media items recursively.
        // Folders themselves do not have genres or years, so including them would cause an empty result.
        if (year != nil && !year!.isEmpty) || (genre != nil && !genre!.isEmpty) {
            if includeItemTypes.contains("Folder") {
                includeItemTypes = "Movie,Series,Episode,MusicAlbum,Audio"
            }
        }
        
        components?.queryItems = [
            URLQueryItem(name: "ParentId", value: parentNode.id),
            URLQueryItem(name: "Recursive", value: "false"),
            URLQueryItem(name: "IncludeItemTypes", value: includeItemTypes),
            URLQueryItem(name: "Fields", value: macJellyfinItemFields)
        ]
        if let sortBy = sortBy, !sortBy.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "SortBy", value: sortBy))
            if sortBy != "SortName" {
                // Jellyfin often needs recursive=true to sort correctly by things like rating or year within a library
                components?.queryItems?.removeAll(where: { $0.name == "Recursive" })
                components?.queryItems?.append(URLQueryItem(name: "Recursive", value: "true"))
            }
        }
        if let sortOrder = sortOrder, !sortOrder.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "SortOrder", value: sortOrder))
        }
        if let year = year, !year.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "Years", value: year))
            components?.queryItems?.removeAll(where: { $0.name == "Recursive" })
            components?.queryItems?.append(URLQueryItem(name: "Recursive", value: "true"))
        }
        if let genre = genre, !genre.isEmpty {
            components?.queryItems?.append(URLQueryItem(name: "Genres", value: genre))
            components?.queryItems?.removeAll(where: { $0.name == "Recursive" })
            components?.queryItems?.append(URLQueryItem(name: "Recursive", value: "true"))
        }
        if let limit {
            components?.queryItems?.append(URLQueryItem(name: "Limit", value: "\(limit)"))
        }
        if let startIndex = startIndex {
            components?.queryItems?.append(URLQueryItem(name: "StartIndex", value: "\(startIndex)"))
        }
    } else {
        components = URLComponents(string: "\(baseURL)/Users/\(userId)/Views")
        components?.queryItems = [URLQueryItem(name: "Fields", value: "Path,Type,CollectionType,Overview,ChildCount,RecursiveItemCount")]
    }
    guard let rawURL = components?.url else { throw URLError(.badURL) }
    let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)

    var request = URLRequest(url: url)
    applyMediaLibraryHeaders(to: &request, server: server)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard (200...299).contains(http.statusCode) else {
        let errorMsg = platformShellString("Platform Shell TV Library Server Error")
        let desc = errorMsg == "Platform Shell TV Library Server Error" ? "Server Error: \(http.statusCode)" : errorMsg.replacingOccurrences(of: "%d", with: "\(http.statusCode)")
        throw NSError(domain: "GenPlayerShell", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: desc])
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = json["Items"] as? [[String: Any]] else { return [] }

    let mappedNodes: [MacMediaLibraryNode] = items.compactMap { (item: [String: Any]) in
        guard let id = item["Id"] as? String,
              let name = item["Name"] as? String else { return nil }
        let rawItemType = item["Type"] as? String
        let mediaType = (item["MediaType"] as? String) ?? rawItemType ?? ""
        let itemType = (rawItemType ?? mediaType).lowercased()
        let isFolder = (item["IsFolder"] as? Bool) ?? jellyfinLikeFolderTypes.contains(itemType) || jellyfinLikeFolderTypes.contains(mediaType.lowercased())
        let collectionType = (item["CollectionType"] as? String) ?? rawItemType
        let userData = item["UserData"] as? [String: Any]
        
        let tokenQuery: String = {
            if let token = server.accessToken, !token.isEmpty {
                return "&api_key=\(token)"
            }
            return ""
        }()

        let imageTags = item["ImageTags"] as? [String: Any]
        let hasPrimary = imageTags?["Primary"] != nil || item["PrimaryImageTag"] != nil
        let hasBackdrop = (item["BackdropImageTags"] as? [String])?.isEmpty == false
        let hasParentBackdrop = (item["ParentBackdropImageTags"] as? [String])?.isEmpty == false
        let hasLogo = imageTags?["Logo"] != nil || (item["HasLogo"] as? Bool == true) || item["LogoImageTag"] != nil
        let hasArt = imageTags?["Art"] != nil || (item["HasArt"] as? Bool == true) || item["ArtImageTag"] != nil
        let seriesId = item["SeriesId"] as? String
        let parentLogoItemId = item["ParentLogoItemId"] as? String
        
        var logoCandidates: [URL] = []
        if hasLogo {
            if let u = URL(string: "\(baseURL)/Items/\(id)/Images/Logo?format=png&maxWidth=600&quality=90\(tokenQuery)") { logoCandidates.append(u) }
        }
        if hasArt {
            if let u = URL(string: "\(baseURL)/Items/\(id)/Images/Art?format=png&maxWidth=600&quality=90\(tokenQuery)") { logoCandidates.append(u) }
        }
        if let parentNodeURLs = parentNode?.logoURLs {
            for u in parentNodeURLs {
                if !logoCandidates.contains(u) { logoCandidates.append(u) }
            }
        }
        if let parentLogoId = parentLogoItemId, !parentLogoId.isEmpty {
            if let u = URL(string: "\(baseURL)/Items/\(parentLogoId)/Images/Logo?format=png&maxWidth=600&quality=90\(tokenQuery)"), !logoCandidates.contains(u) { logoCandidates.append(u) }
            if let u = URL(string: "\(baseURL)/Items/\(parentLogoId)/Images/Art?format=png&maxWidth=600&quality=90\(tokenQuery)"), !logoCandidates.contains(u) { logoCandidates.append(u) }
        }
        if let seriesId = seriesId, !seriesId.isEmpty {
            if let u = URL(string: "\(baseURL)/Items/\(seriesId)/Images/Logo?format=png&maxWidth=600&quality=90\(tokenQuery)"), !logoCandidates.contains(u) { logoCandidates.append(u) }
            if let u = URL(string: "\(baseURL)/Items/\(seriesId)/Images/Art?format=png&maxWidth=600&quality=90\(tokenQuery)"), !logoCandidates.contains(u) { logoCandidates.append(u) }
        }
        if itemType == "movie" || itemType == "series" || itemType == "episode" || itemType == "video" {
            if let u = URL(string: "\(baseURL)/Items/\(id)/Images/Logo?format=png&maxWidth=600&quality=90\(tokenQuery)"), !logoCandidates.contains(u) { logoCandidates.append(u) }
            if let u = URL(string: "\(baseURL)/Items/\(id)/Images/Art?format=png&maxWidth=600&quality=90\(tokenQuery)"), !logoCandidates.contains(u) { logoCandidates.append(u) }
        }
        
        let posterURL: URL?
        let backdropURL: URL?
        
        if hasPrimary {
            posterURL = URL(string: "\(baseURL)/Items/\(id)/Images/Primary?maxHeight=520&maxWidth=360&quality=90\(tokenQuery)")
        } else if let pPoster = parentNode?.posterURL {
            posterURL = pPoster
        } else if let seriesId = seriesId, !seriesId.isEmpty {
            posterURL = URL(string: "\(baseURL)/Items/\(seriesId)/Images/Primary?maxHeight=520&maxWidth=360&quality=90\(tokenQuery)")
        } else {
            posterURL = nil
        }
        
        if hasBackdrop {
            backdropURL = URL(string: "\(baseURL)/Items/\(id)/Images/Backdrop?maxWidth=1920&quality=90\(tokenQuery)")
        } else if let pBackdrop = parentNode?.backdropURL {
            backdropURL = pBackdrop
        } else if hasParentBackdrop, let parentBackdropId = item["ParentBackdropItemId"] as? String {
            backdropURL = URL(string: "\(baseURL)/Items/\(parentBackdropId)/Images/Backdrop?maxWidth=1920&quality=90\(tokenQuery)")
        } else {
            backdropURL = nil
        }
        
        let deviceIdQuery = server.type == .emby ? "&DeviceId=GenPlayerMac" : ""
        let playbackURL = isFolder ? nil : URL(string: "\(baseURL)/Videos/\(id)/stream?Static=true\(deviceIdQuery)\(tokenQuery)")
        let metadata = macJellyfinMetadataLines(from: item, fallbackType: collectionType)
        return MacMediaLibraryNode(
            id: id,
            name: name,
            type: fileType(from: mediaType),
            isFolder: isFolder,
            remotePath: item["Path"] as? String,
            posterURL: posterURL,
            backdropURL: backdropURL,
            playbackURL: playbackURL,
            logoURLs: logoCandidates,
            collectionType: collectionType,
            summary: item["Overview"] as? String,
            metadataLine: metadata.metadata,
            technicalMetadataLine: metadata.technical,
            isLibraryRoot: parentNode == nil,
            playbackPositionTicks: userData?["PlaybackPositionTicks"] as? Int64,
            runTimeTicks: item["RunTimeTicks"] as? Int64,
            lastPlayedDate: MediaHomeCarouselSelection.date(userData?["LastPlayedDate"] as? String),
            dateCreated: {
                if let d = item["DateCreated"] as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let parsed = formatter.date(from: d) { return parsed }
                    return ISO8601DateFormatter().date(from: d)
                }
                return nil
            }(),
            premiereDate: {
                if let d = item["PremiereDate"] as? String {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let parsed = formatter.date(from: d) { return parsed }
                    return ISO8601DateFormatter().date(from: d)
                }
                return nil
            }(),
            seriesId: item["SeriesId"] as? String,
            seriesName: item["SeriesName"] as? String,
            seasonId: item["SeasonId"] as? String,
            isFavorite: userData?["IsFavorite"] as? Bool ?? false,
            isPlayed: userData?["Played"] as? Bool ?? false,
            indexNumber: item["IndexNumber"] as? Int,
            parentIndexNumber: item["ParentIndexNumber"] as? Int,
            communityRating: macDoubleValue(item["CommunityRating"]),
            itemCount: (item["RecursiveItemCount"] as? Int) ?? (item["ChildCount"] as? Int)
        )
    }.sorted { l, r in
        // Folders first
        if l.isFolder != r.isFolder { return l.isFolder && !r.isFolder }
        // If both have numeric index (Season / Episode), sort numerically to avoid
        // lexicographic ordering (1, 10, 11, 2, 3 …)
        if let li = l.indexNumber, let ri = r.indexNumber { return li < ri }
        // Fall back to server-provided name order (no re-sorting for movies/series lists)
        return l.name.localizedCaseInsensitiveCompare(r.name) == .orderedAscending
    }

    let filteredNodes = parentNode == nil ? mappedNodes.filter {
        let type = $0.collectionType?.lowercased()
        return type != "boxsets" && type != "collections"
    } : mappedNodes

    guard let limit else { return filteredNodes }
    return Array(filteredNodes.prefix(limit))
}

private func fetchPlexNodes(server: ServerConfig, parentNode: MacMediaLibraryNode?, startIndex: Int? = nil, limit: Int? = nil) async throws -> [MacMediaLibraryNode] {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let path: String = {
        if let parentPath = parentNode?.remotePath, !parentPath.isEmpty {
            return parentPath
        }
        return "/library/sections"
    }()

    guard var components = URLComponents(string: baseURL + path) else { throw URLError(.badURL) }
    
    var queryItems = components.queryItems ?? []
    if let startIndex = startIndex {
        queryItems.append(URLQueryItem(name: "X-Plex-Container-Start", value: "\(startIndex)"))
    }
    if let limit = limit {
        queryItems.append(URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)"))
    }
    if !queryItems.isEmpty {
        components.queryItems = queryItems
    }
    
    guard let rawURL = components.url else { throw URLError(.badURL) }
    let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
    var request = URLRequest(url: url)
    applyMediaLibraryHeaders(to: &request, server: server)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let container = json["MediaContainer"] as? [String: Any] else { return [] }

    let directories = (container["Directory"] as? [[String: Any]]) ?? []
    let videos = (container["Metadata"] as? [[String: Any]]) ?? []

    let mappedNodes: [MacMediaLibraryNode] = (directories + videos).compactMap { (item: [String: Any]) in
        let key = (item["key"] as? String) ?? (item["ratingKey"] as? String) ?? ""
        let name = (item["title"] as? String) ?? (item["grandparentTitle"] as? String) ?? key
        guard !key.isEmpty, !name.isEmpty else { return nil }
        let type = (item["type"] as? String) ?? ""
        let isFolder = plexFolderTypes.contains(type.lowercased())

        let media = (item["Media"] as? [[String: Any]])?.first
        let part = (media?["Part"] as? [[String: Any]])?.first
        let fileKey = part?["key"] as? String

        let remotePath: String
        if path == "/library/sections" {
            remotePath = "/library/sections/\(key)/all"
        } else if isFolder {
            if key.hasPrefix("/") {
                remotePath = key.hasSuffix("/children") ? key : "\(key)/children"
            } else {
                remotePath = "/library/metadata/\(key)/children"
            }
        } else {
            remotePath = (part?["file"] as? String) ?? (key.hasPrefix("/") ? key : "/library/metadata/\(key)")
        }

        let posterKey = (item["thumb"] as? String) ?? (item["art"] as? String)
        let backdropKey = (item["art"] as? String) ?? (item["thumb"] as? String)
        let posterURL = posterKey.flatMap { plexImageURL(baseURL: baseURL, key: $0, token: server.accessToken) }
        let backdropURL = backdropKey.flatMap { plexImageURL(baseURL: baseURL, key: $0, token: server.accessToken) }

        let playbackURL = fileKey.flatMap { key -> URL? in
            guard var components = URLComponents(string: baseURL + key) else { return nil }
            if let token = server.accessToken, !token.isEmpty {
                var queryItems = components.queryItems ?? []
                if !queryItems.contains(where: { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame }) {
                    queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
                }
                components.queryItems = queryItems
            }
            return components.url
        }

        let metadata = macPlexMetadataLines(from: item, fallbackType: type)

        return MacMediaLibraryNode(
            id: key,
            name: name,
            type: fileType(from: type),
            isFolder: isFolder,
            remotePath: remotePath,
            posterURL: posterURL,
            backdropURL: backdropURL,
            playbackURL: playbackURL,
            collectionType: type,
            summary: item["summary"] as? String,
            metadataLine: metadata.metadata,
            technicalMetadataLine: metadata.technical,
            seriesId: (item["grandparentRatingKey"] as? String) ?? (item["grandparentKey"] as? String),
            seriesName: item["grandparentTitle"] as? String,
            seasonId: item["parentKey"] as? String,
            isFavorite: false,
            isPlayed: (item["viewCount"] as? Int ?? 0) > 0,
            indexNumber: item["index"] as? Int,
            parentIndexNumber: item["parentIndex"] as? Int,
            communityRating: macDoubleValue(item["rating"]),
            itemCount: (item["count"] as? Int) ?? (item["leafCount"] as? Int)
        )
    }.sorted { l, r in
        if l.isFolder != r.isFolder { return l.isFolder && !r.isFolder }
        return l.name.localizedCaseInsensitiveCompare(r.name) == .orderedAscending
    }

    // We don't need to manually prefix(limit) here because the server handles it via X-Plex-Container-Size
    return mappedNodes
}

// MARK: - Plex Continue Watching / Recently Added (Mac)

/// Fetches Plex "Continue Watching" hub items, mirrors iOS `PlexService.getContinueWatching`.
private func fetchPlexContinueWatchingNodes(server: ServerConfig, limit: Int = 20) async throws -> [MacMediaLibraryNode] {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: baseURL + "/hubs/home/continueWatching") else { return [] }
    components.queryItems = [URLQueryItem(name: "limit", value: "\(limit)")]
    if let token = server.accessToken, !token.isEmpty {
        components.queryItems?.append(URLQueryItem(name: "X-Plex-Token", value: token))
    }
    guard let rawURL = components.url else { return [] }
    let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)

    var request = URLRequest(url: url)
    applyMediaLibraryHeaders(to: &request, server: server)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let container = json["MediaContainer"] as? [String: Any] else { return [] }

    // Plex may return direct Metadata or Hub > Metadata
    var metadataItems: [[String: Any]] = []
    if let direct = container["Metadata"] as? [[String: Any]], !direct.isEmpty {
        metadataItems = Array(direct.prefix(limit))
    } else if let hubs = container["Hub"] as? [[String: Any]] {
        var seen = Set<String>()
        for hub in hubs {
            for item in hub["Metadata"] as? [[String: Any]] ?? [] {
                let key = (item["ratingKey"] as? String) ?? ""
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                metadataItems.append(item)
                if metadataItems.count >= limit { break }
            }
            if metadataItems.count >= limit { break }
        }
    }

    return metadataItems.compactMap { item in
        parsePlexItemToNode(item, baseURL: baseURL, server: server)
    }
}

/// Fetches Plex global recently added across all libraries, mirrors iOS `PlexService.getRecentlyAdded` at hub level.
private func fetchPlexRecentlyAddedNodes(server: ServerConfig, limit: Int = 16) async throws -> [MacMediaLibraryNode] {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    // First, get libraries to fetch recently added per library
    guard var sectionsComponents = URLComponents(string: baseURL + "/library/sections") else { return [] }
    if let token = server.accessToken, !token.isEmpty {
        sectionsComponents.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
    }
    guard let rawSectionsURL = sectionsComponents.url else { return [] }
    let sectionsURL = RuntimeNetworkAddressResolver.runtimeURL(from: rawSectionsURL)

    var sectionsRequest = URLRequest(url: sectionsURL)
    applyMediaLibraryHeaders(to: &sectionsRequest, server: server)

    let (sectionsData, sectionsResp) = try await URLSession.shared.data(for: sectionsRequest)
    guard let sectionsHttp = sectionsResp as? HTTPURLResponse, (200...299).contains(sectionsHttp.statusCode),
          let sectionsJSON = try JSONSerialization.jsonObject(with: sectionsData) as? [String: Any],
          let sectionsContainer = sectionsJSON["MediaContainer"] as? [String: Any],
          let directories = sectionsContainer["Directory"] as? [[String: Any]] else { return [] }

    // Fetch recently added per library and merge
    var allRecent: [MacMediaLibraryNode] = []
    var seenIds = Set<String>()
    let perLibraryLimit = max(limit / max(directories.count, 1), 4)

    for dir in directories {
        guard let libraryId = dir["key"] as? String else { continue }
        let libraryType = (dir["type"] as? String) ?? ""
        guard libraryType.lowercased() == "movie" || libraryType.lowercased() == "show" else { continue }

        let nodes = try await fetchPlexLibraryRecentlyAddedNodes(server: server, libraryId: libraryId, limit: perLibraryLimit)
        for node in nodes {
            if seenIds.insert(node.id).inserted {
                allRecent.append(node)
            }
        }
    }

    return Array(allRecent.prefix(limit))
}

/// Fetches Plex recently added items for a specific library, mirrors iOS `PlexService.getRecentlyAdded(libraryId:)`.
private func fetchPlexLibraryRecentlyAddedNodes(server: ServerConfig, libraryId: String, libraryType: String? = nil, limit: Int = 24) async throws -> [MacMediaLibraryNode] {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let isShow = libraryType?.lowercased() == "show"
    let endpoint = isShow ? "/library/sections/\(libraryId)/all" : "/library/sections/\(libraryId)/recentlyAdded"
    
    guard var components = URLComponents(string: baseURL + endpoint) else { return [] }
    var queryItems = [
        URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
        URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)")
    ]
    if isShow {
        queryItems.append(URLQueryItem(name: "sort", value: "addedAt:desc"))
    }
    components.queryItems = queryItems
    if let token = server.accessToken, !token.isEmpty {
        components.queryItems?.append(URLQueryItem(name: "X-Plex-Token", value: token))
    }
    guard let rawURL = components.url else { return [] }
    let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)

    var request = URLRequest(url: url)
    applyMediaLibraryHeaders(to: &request, server: server)

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let container = json["MediaContainer"] as? [String: Any] else { return [] }

    let metadata = (container["Metadata"] as? [[String: Any]]) ?? []
    return metadata.prefix(limit).compactMap { item in
        parsePlexItemToNode(item, baseURL: baseURL, server: server)
    }
}

/// Shared helper: parse a Plex API metadata dictionary into a MacMediaLibraryNode.
private func parsePlexItemToNode(_ item: [String: Any], baseURL: String, server: ServerConfig) -> MacMediaLibraryNode? {
    let key = (item["ratingKey"] as? String) ?? (item["key"] as? String) ?? ""
    let name = (item["title"] as? String) ?? (item["grandparentTitle"] as? String) ?? key
    guard !key.isEmpty, !name.isEmpty else { return nil }
    let type = (item["type"] as? String) ?? ""
    let isFolder = plexFolderTypes.contains(type.lowercased())

    let media = (item["Media"] as? [[String: Any]])?.first
    let part = (media?["Part"] as? [[String: Any]])?.first
    let fileKey = part?["key"] as? String

    let remotePath: String
    if isFolder {
        if let rawKey = item["key"] as? String, rawKey.hasPrefix("/") {
            remotePath = rawKey.hasSuffix("/children") ? rawKey : "\(rawKey)/children"
        } else {
            remotePath = "/library/metadata/\(key)/children"
        }
    } else {
        remotePath = (part?["file"] as? String) ?? (key.hasPrefix("/") ? key : "/library/metadata/\(key)")
    }

    let posterKey = (item["thumb"] as? String) ?? (item["art"] as? String)
    let backdropKey = (item["art"] as? String) ?? (item["thumb"] as? String)
    let posterURL = posterKey.flatMap { plexImageURL(baseURL: baseURL, key: $0, token: server.accessToken) }
    let backdropURL = backdropKey.flatMap { plexImageURL(baseURL: baseURL, key: $0, token: server.accessToken) }

    let playbackURL = fileKey.flatMap { key -> URL? in
        guard var components = URLComponents(string: baseURL + key) else { return nil }
        if let token = server.accessToken, !token.isEmpty {
            var queryItems = components.queryItems ?? []
            if !queryItems.contains(where: { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame }) {
                queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
            }
            components.queryItems = queryItems
        }
        return components.url
    }

    let viewOffset = item["viewOffset"] as? Int64
    let duration = item["duration"] as? Int64
    // Plex uses milliseconds; convert to ticks (1 tick = 10000 ns = 0.01 ms → multiply ms by 10000)
    let positionTicks = viewOffset.map { $0 * 10000 }
    let runTimeTicks = duration.map { $0 * 10000 }
    let metadata = macPlexMetadataLines(from: item, fallbackType: type)

    return MacMediaLibraryNode(
        id: key,
        name: name,
        type: fileType(from: type),
        isFolder: isFolder,
        remotePath: remotePath,
        posterURL: posterURL,
        backdropURL: backdropURL,
        playbackURL: playbackURL,
        collectionType: type,
        summary: item["summary"] as? String,
        metadataLine: metadata.metadata,
        technicalMetadataLine: metadata.technical,
        playbackPositionTicks: positionTicks,
        runTimeTicks: runTimeTicks,
        lastPlayedDate: (item["lastViewedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) },
        seriesId: item["grandparentKey"] as? String,
        seriesName: item["grandparentTitle"] as? String,
        seasonId: item["parentKey"] as? String,
        isFavorite: false,
        isPlayed: (item["viewCount"] as? Int ?? 0) > 0,
        indexNumber: item["index"] as? Int,
        parentIndexNumber: item["parentIndex"] as? Int,
        communityRating: macDoubleValue(item["rating"])
    )
}

private let jellyfinLikeFolderTypes: Set<String> = ["folder", "collectionfolder", "series", "season", "musicartist", "musicalbum", "boxset", "playlist"]
private let plexFolderTypes: Set<String> = ["show", "season", "artist", "album", "collection", "genre", "directory", "photoalbum"]
let macJellyfinItemFields = "Path,Type,MediaType,Overview,Genres,DateCreated,PremiereDate,ProductionYear,CommunityRating,RunTimeTicks,ChildCount,RecursiveItemCount,IndexNumber,ParentIndexNumber,SeriesId,SeriesName,SeasonId,SeasonName,ImageTags,BackdropImageTags,ParentBackdropItemId,ParentBackdropImageTags,ParentLogoItemId,ParentLogoImageTag,PrimaryImageTag,MediaSources"

private func fileType(from rawType: String) -> VideoFile.FileType {
    switch rawType.lowercased() {
    case "movie", "episode", "video", "clip": return .video
    case "song", "audio", "track": return .audio
    case "photo", "image": return .image
    case "subtitle": return .subtitle
    case "folder", "collectionfolder", "series", "season", "musicartist", "musicalbum", "artist", "album", "show": return .folder
    default: return .document
    }
}

func resolvedMediaLibraryUserId(server: ServerConfig) async throws -> String? {
    if let userId = server.userId, !userId.isEmpty { return userId }
    guard server.type == .jellyfin || server.type == .emby,
          let token = server.accessToken, !token.isEmpty else {
        return nil
    }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let rawURL = URL(string: "\(baseURL)/Users/Me") else { return nil }
    let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)

    var request = URLRequest(url: url)
    applyMediaLibraryHeaders(to: &request, server: server)
    request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
    request.setValue(token, forHTTPHeaderField: "X-MediaBrowser-Token")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return json["Id"] as? String
}

func applyMediaLibraryHeaders(to request: inout URLRequest, server: ServerConfig) {
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    if let token = server.accessToken, !token.isEmpty {
        switch server.type {
        case .jellyfin, .emby:
            request.setValue("MediaBrowser Client=\"GenPlayer-macOS\", Device=\"Mac\", DeviceId=\"GenPlayerMac\", Version=\"1.0\", Token=\"\(token)\"", forHTTPHeaderField: "Authorization")
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            request.setValue(token, forHTTPHeaderField: "X-MediaBrowser-Token")
        case .plex:
            request.setValue("GenPlayer", forHTTPHeaderField: "X-Plex-Product")
            request.setValue("macOS", forHTTPHeaderField: "X-Plex-Platform")
            request.setValue("GenPlayer-macOS", forHTTPHeaderField: "X-Plex-Device")
            request.setValue("GenPlayerMac", forHTTPHeaderField: "X-Plex-Client-Identifier")
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        default:
            break
        }
    }
}

private func macResolutionText(width: Int?, height: Int?) -> String? {
    guard let w = width, let h = height else { return nil }
    if w >= 3840 || h >= 2160 { return "4K" }
    if w >= 1920 || h >= 1080 { return "1080p" }
    if w >= 1280 || h >= 720 { return "720p" }
    return "SD"
}

private func macLineBreakableTitle(_ title: String) -> String {
    title
        .replacingOccurrences(of: ".", with: ".\u{200B}")
        .replacingOccurrences(of: "_", with: "_\u{200B}")
        .replacingOccurrences(of: "-", with: "-\u{200B}")
}

private func macApproximateFileSize(_ size: Int64) -> String {
    let gb = Double(size) / 1_073_741_824.0
    if gb >= 1.0 {
        return "\(Int(gb.rounded())) GB"
    }
    let mb = Double(size) / 1_048_576.0
    if mb >= 1.0 {
        return "\(Int(mb.rounded())) MB"
    }
    let kb = Double(size) / 1024.0
    return "\(Int(kb.rounded())) KB"
}

private func macJellyfinMetadataLines(from item: [String: Any], fallbackType: String? = nil) -> (metadata: String?, technical: String?) {
    var parts: [String] = []

    var videoWidth: Int? = item["Width"] as? Int
    var videoHeight: Int? = item["Height"] as? Int
    var fileSize: Int64? = macInt64Value(item["Size"])
    var container: String? = item["Container"] as? String
    var bitrate: Int? = item["Bitrate"] as? Int

    var selectedVideoStream = (item["MediaStreams"] as? [[String: Any]])?.first {
        ($0["Type"] as? String)?.caseInsensitiveCompare("Video") == .orderedSame
    }
    if let sources = item["MediaSources"] as? [[String: Any]], !sources.isEmpty {
        var bestPixels = 0
        for source in sources {
            let streams = source["MediaStreams"] as? [[String: Any]] ?? []
            let videoStream = streams.first { ($0["Type"] as? String)?.caseInsensitiveCompare("Video") == .orderedSame }
            let w = videoStream?["Width"] as? Int ?? item["Width"] as? Int
            let h = videoStream?["Height"] as? Int ?? item["Height"] as? Int
            let pixels = (w ?? 0) * (h ?? 0)
            if pixels >= bestPixels {
                bestPixels = pixels
                selectedVideoStream = videoStream
                videoWidth = w
                videoHeight = h
                fileSize = macInt64Value(source["Size"]) ?? macInt64Value(item["Size"])
                container = (source["Container"] as? String) ?? (item["Container"] as? String)
                bitrate = (source["Bitrate"] as? Int) ?? (item["Bitrate"] as? Int)
            }
        }
    }

    let itemType = ((item["Type"] as? String) ?? fallbackType ?? "").lowercased()
    if itemType == "episode" {
        if let index = item["IndexNumber"] as? Int {
            parts.append("\(platformShellString("Episode")) \(index)")
        } else {
            parts.append(platformShellString("Episode"))
        }
        if let ticks = macInt64Value(item["RunTimeTicks"]),
           let runtime = macRuntimeText(fromJellyfinTicks: ticks) {
            parts.append(runtime)
        }
        if let size = fileSize, size > 0 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            parts.append(sizeStr)
        }
    } else {
        if let year = item["ProductionYear"] as? Int {
            parts.append("\(year)")
        } else if let dateString = item["PremiereDate"] as? String, dateString.count >= 4 {
            parts.append(String(dateString.prefix(4)))
        }

        if itemType == "series" || itemType == "show" || itemType == "tvshows" {
            let childCount = (item["ChildCount"] as? Int) ?? (item["SeasonCount"] as? Int)
            let recursiveCount = item["RecursiveItemCount"] as? Int
            if let count = childCount, count > 0 {
                let singular = platformShellString("Platform Shell TV Detail Season")
                let isChinese = singular == "季"
                var countText: String
                if isChinese {
                    countText = "\(count) 季"
                    if let ep = recursiveCount, ep > 0 {
                        countText += " \(ep) 集"
                    }
                } else {
                    countText = "\(count)S"
                    if let ep = recursiveCount, ep > 0 {
                        countText += " \(ep)E"
                    }
                }
                parts.append(countText)
            } else if let genres = item["Genres"] as? [String], !genres.isEmpty {
                parts.append(genres.prefix(2).joined(separator: " / "))
            }
        } else if itemType == "season" {
            let epCount = (item["ChildCount"] as? Int) ?? (item["EpisodeCount"] as? Int)
            if let count = epCount, count > 0 {
                let epText: String
                let singular = platformShellString("Platform Shell TV Detail Episode")
                let plural = platformShellString("Platform Shell TV Detail Episodes")
                if singular == "集" {
                    epText = "\(count) 集"
                } else {
                    epText = count == 1 ? "\(count) \(singular)" : "\(count) \(plural)"
                }
                parts.append(epText)
            }
        } else {
            if let ticks = macInt64Value(item["RunTimeTicks"]),
               let runtime = macRuntimeText(fromJellyfinTicks: ticks) {
                parts.append(runtime)
            }

            if let size = fileSize, size > 0 {
                parts.append(macApproximateFileSize(size))
            }
            
            if let genres = item["Genres"] as? [String], !genres.isEmpty {
                parts.append(genres.prefix(2).joined(separator: " / "))
            }
        }
    }

    let metadataStr = parts.isEmpty ? nil : parts.joined(separator: " · ")

    var techParts: [String] = []

    if let w = videoWidth, let h = videoHeight, let res = macResolutionText(width: w, height: h) {
        techParts.append(res)
    }
    
    if let selectedVideoStream {
        techParts.append(contentsOf: MediaTechnicalMetadata.parts(video: selectedVideoStream))
    }

    if let containerStr = container?.split(separator: ",").first {
        let text = String(containerStr).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !text.isEmpty {
            techParts.append(text)
        }
    }

    if let b = bitrate, b > 0 {
        if b >= 1_000_000 {
            techParts.append(String(format: "%.1f Mbps", Double(b) / 1_000_000.0))
        } else {
            techParts.append("\(max(1, b / 1000)) kbps")
        }
    }

    if let size = fileSize, size > 0 {
        let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        techParts.append(sizeStr)
    }

    let technicalStr = techParts.isEmpty ? nil : techParts.joined(separator: " · ")

    return (metadataStr, technicalStr)
}

struct MacScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

struct MacEpisodeCard: View {
    let server: ServerConfig
    let node: MacMediaLibraryNode
    let indexNumber: Int?
    let isPlayed: Bool
    var isHighlighted: Bool = false
    var onPlay: () -> Void
    var onDownload: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                let imageURL: URL? = {
                    if node.posterURL?.absoluteString.contains("/Items/\(node.id)/Images/Primary") == true {
                        return node.posterURL
                    }
                    return node.backdropURL ?? node.posterURL
                }()
                
                MacCachedAsyncImage(url: imageURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFill()
                    } else {
                        Rectangle().fill(Color.secondary.opacity(0.12))
                    }
                }
                .frame(width: MacMediaCardMetrics.landscapeWidth, height: MacMediaCardMetrics.landscapeHeight)
                .clipShape(RoundedRectangle(cornerRadius: 10))

                Image(systemName: "play.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.white.opacity(isHovered ? 0.9 : 0.0))
                    .shadow(radius: 4)

                if isPlayed {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                                .background(Circle().fill(Color.white))
                                .font(.system(size: 16))
                                .padding(8)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onPlay() }
            .overlay(alignment: .bottomTrailing) {
                if let progressTicks = node.playbackPositionTicks, let runTimeTicks = node.runTimeTicks, progressTicks > 0, runTimeTicks > 0 {
                    MacMediaPlaybackProgressBadge(
                        progress: Double(progressTicks) / Double(runTimeTicks),
                        systemImageName: "play.fill",
                        diameter: 18
                    )
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .allowsHitTesting(false)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHighlighted ? Color.accentColor : Color.primary.opacity(isHovered ? 0.22 : 0.0), lineWidth: isHighlighted ? 2.5 : 1.5)
            )
            .shadow(color: Color.black.opacity(isHovered ? 0.25 : 0.0), radius: isHovered ? 8 : 0, x: 0, y: isHovered ? 4 : 0)
            
            VStack(alignment: .leading, spacing: 4) {
                // If it's an episode, we skip the indexNumber in the title because it's now in metadataLine.
                let titlePrefix = (node.collectionType?.caseInsensitiveCompare("Episode") != .orderedSame && indexNumber != nil) ? "\(indexNumber!). " : ""
                Text("\(titlePrefix)\(node.name)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isHovered ? .accentColor : .primary)
                    .lineLimit(1)
                
                if let metadata = node.metadataLine {
                    Text(metadata)
                        .font(.system(size: 12))
                        .foregroundColor(isHovered ? .primary.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
                
                if let technical = node.technicalMetadataLine {
                    Text(technical)
                        .font(.system(size: 12))
                        .foregroundColor(isHovered ? .primary.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
                
                Spacer(minLength: 0)
            }
            .frame(height: 56, alignment: .topLeading)
        }
        .frame(width: MacMediaCardMetrics.landscapeWidth)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .zIndex(isHovered ? 1 : 0)
        .modifier(MacMediaContextMenuModifier(node: node, server: server, onPlay: onPlay, onDownload: onDownload))
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onHover { h in withAnimation(.easeOut(duration: 0.15)) { isHovered = h } }
                .macPointerHover()
        )
    }
}

private func macPlexMetadataLines(from item: [String: Any], fallbackType: String? = nil) -> (metadata: String?, technical: String?) {
    var parts: [String] = []

    if let year = item["year"] as? Int {
        parts.append("\(year)")
    }

    if let duration = macInt64Value(item["duration"]),
       let runtime = macRuntimeText(fromMilliseconds: duration) {
        parts.append(runtime)
    }

    let mediaArray = item["Media"] as? [[String: Any]]
    let mediaFirst = mediaArray?.first
    let partArray = mediaFirst?["Part"] as? [[String: Any]]
    let partFirst = partArray?.first

    var fileSize: Int64? = macInt64Value(item["size"])
    if fileSize == nil {
        fileSize = macInt64Value(mediaFirst?["size"])
        if fileSize == nil {
            fileSize = macInt64Value(partFirst?["size"])
        }
    }
    if let size = fileSize, size > 0 {
        parts.append(macApproximateFileSize(size))
    }

    if let genres = item["Genre"] as? [[String: Any]] {
        let names = genres.compactMap { $0["tag"] as? String }
        if !names.isEmpty {
            parts.append(names.prefix(2).joined(separator: " / "))
        }
    }

    let metadataStr = parts.isEmpty ? nil : parts.joined(separator: " · ")

    var techParts: [String] = []

    let width = (mediaFirst?["width"] as? Int)
    let height = (mediaFirst?["height"] as? Int)
    if let w = width, let h = height, let res = macResolutionText(width: w, height: h) {
        techParts.append(res)
    } else if let res = mediaFirst?["videoResolution"] as? String, !res.isEmpty {
        let upper = res.uppercased()
        if upper == "4K" || upper == "1080" || upper == "720" || upper == "SD" {
            techParts.append(upper == "1080" || upper == "720" ? "\(upper)p" : upper)
        } else {
            techParts.append(upper)
        }
    }

    let videoStream = (partFirst?["Stream"] as? [[String: Any]])?.first {
        macInt64Value($0["streamType"]) == 1
    }
    if let videoStream {
        techParts.append(contentsOf: MediaTechnicalMetadata.parts(video: videoStream, plex: true, includeCodec: false))
    }

    if let vCodec = mediaFirst?["videoCodec"] as? String, !vCodec.isEmpty {
        techParts.append(vCodec.uppercased())
    }

    if let aCodec = mediaFirst?["audioCodec"] as? String, !aCodec.isEmpty {
        var audioDesc = aCodec.uppercased()
        if let channels = mediaFirst?["audioChannels"] as? Int {
            if channels == 8 { audioDesc += " 7.1" }
            else if channels == 6 { audioDesc += " 5.1" }
            else if channels == 2 { audioDesc += " 2.0" }
        }
        techParts.append(audioDesc)
    }

    if let container = (mediaFirst?["container"] as? String)?.uppercased(), !container.isEmpty {
        techParts.append(container)
    }

    if let bitrate = mediaFirst?["bitrate"] as? Int, bitrate > 0 {
        if bitrate >= 1000 {
            techParts.append(String(format: "%.1f Mbps", Double(bitrate) / 1000.0))
        } else {
            techParts.append("\(bitrate) kbps")
        }
    }

    if let size = fileSize, size > 0 {
        let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        techParts.append(sizeStr)
    }

    let technicalStr = techParts.isEmpty ? nil : techParts.joined(separator: " · ")
    return (metadataStr, technicalStr)
}

private func macPlexMetadataLine(from item: [String: Any], fallbackType: String? = nil) -> String? {
    macPlexMetadataLines(from: item, fallbackType: fallbackType).metadata
}

private func macRuntimeText(fromJellyfinTicks ticks: Int64) -> String? {
    guard ticks > 0 else { return nil }
    return macRuntimeText(fromMinutes: Int((Double(ticks) / 600_000_000.0).rounded()))
}

private func macRuntimeText(fromMilliseconds milliseconds: Int64) -> String? {
    guard milliseconds > 0 else { return nil }
    return macRuntimeText(fromMinutes: Int((Double(milliseconds) / 60_000.0).rounded()))
}

private func macRuntimeText(fromMinutes minutes: Int) -> String? {
    guard minutes > 0 else { return nil }
    if minutes < 60 {
        return "\(minutes)m"
    }
    return "\(minutes / 60)h \(minutes % 60)m"
}

func macMakeVideoFile(for node: MacMediaLibraryNode, server: ServerConfig) -> VideoFile {
    var rawURL = node.playbackURL ?? node.posterURL ?? URL(fileURLWithPath: node.remotePath ?? node.id)
    if rawURL.scheme?.hasPrefix("http") == true {
        if (server.type == .jellyfin || server.type == .emby),
           let token = server.accessToken, !token.isEmpty {
            if var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) {
                var queryItems = components.queryItems ?? []
                let hasApiKey = queryItems.contains(where: { $0.name.caseInsensitiveCompare("api_key") == .orderedSame })
                if !hasApiKey {
                    queryItems.append(URLQueryItem(name: "api_key", value: token))
                }
                if server.type == .emby && !queryItems.contains(where: { $0.name.caseInsensitiveCompare("DeviceId") == .orderedSame }) {
                    queryItems.append(URLQueryItem(name: "DeviceId", value: "GenPlayerMac"))
                }
                components.queryItems = queryItems
                if let updated = components.url {
                    rawURL = updated
                }
            }
        } else if server.type == .plex,
                  let token = server.accessToken, !token.isEmpty {
            if var components = URLComponents(url: rawURL, resolvingAgainstBaseURL: false) {
                var queryItems = components.queryItems ?? []
                let hasToken = queryItems.contains(where: { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame })
                if !hasToken {
                    queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
                    components.queryItems = queryItems
                    if let updated = components.url {
                        rawURL = updated
                    }
                }
            }
        }
    }
    var file = VideoFile(
        name: node.name,
        url: rawURL,
        type: node.type,
        size: 0,
        date: Date(),
        isRemote: true,
        duration: node.runTimeTicks.map { Double($0) / 10_000_000.0 },
        lastPlayedPosition: node.playbackPositionTicks.map { Double($0) / 10_000_000.0 },
        jellyfinItemId: node.id,
        jellyfinServerId: server.id.uuidString,
        serverType: server.type,
        seriesId: node.seriesId,
        seasonId: node.seasonId
    )
    file.serverPath = node.remotePath
    return file
}

@MainActor
private func macPlayNode(_ node: MacMediaLibraryNode, server: ServerConfig, playlist: [VideoFile]? = nil) {
    let targetFile = macMakeVideoFile(for: node, server: server)
    let playableFile = DownloadCenterService.shared.localPlaybackFile(for: targetFile) ?? targetFile
    MacPlayerWindowManager.shared.openPlayer(for: playableFile, playlist: playlist)
}

private func macDoubleValue(_ value: Any?) -> Double? {
    if let double = value as? Double { return double }
    if let float = value as? Float { return Double(float) }
    if let int = value as? Int { return Double(int) }
    if let number = value as? NSNumber { return number.doubleValue }
    if let string = value as? String { return Double(string) }
    return nil
}

private func macInt64Value(_ value: Any?) -> Int64? {
    if let int64 = value as? Int64 { return int64 }
    if let int = value as? Int { return Int64(int) }
    if let number = value as? NSNumber { return number.int64Value }
    if let string = value as? String { return Int64(string) }
    return nil
}

private func plexImageURL(baseURL: String, key: String, token: String?) -> URL? {
    guard var components = URLComponents(string: baseURL + key) else { return nil }
    if let token, !token.isEmpty {
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
        components.queryItems = queryItems
    }
    return components.url
}

extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ServerConfig.ServerType {
    static var macAllCases: [ServerConfig.ServerType] {
        [.smb, .webdav, .alist, .ftp, .sftp, .nfs, .jellyfin, .emby, .plex, .iptv, .vod]
    }

    var macIsMediaLibraryServer: Bool {
        switch self {
        case .jellyfin, .emby, .plex: return true
        default: return false
        }
    }

    var macDefaultPortString: String {
        switch self {
        case .smb: return "445"
        case .ftp: return "21"
        case .sftp: return "22"
        case .nfs: return "2049"
        case .webdav: return "5005"
        case .alist: return "5244"
        case .pan115, .onedrive, .googledrive: return "443"
        case .jellyfin, .emby: return "8096"
        case .plex: return "32400"
        case .iptv, .vod: return "80"
        }
    }

    var macShowsSSLToggle: Bool {
        switch self {
        case .webdav, .alist, .jellyfin, .emby, .plex: return true
        default: return false
        }
    }
}


struct MacHistoryGroup: Identifiable {
    let id: String
    let name: String
    var files: [VideoFile]
    var server: ServerConfig? = nil
}

struct MacPageHeaderView: View {
    let title: String
    var trailingView: AnyView? = nil
    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(.primary)
            Spacer()
            if let trailingView = trailingView {
                trailingView
            }
        }
        .padding(.bottom, 8)
    }
}

struct MacServerHeaderButton: View {
    let server: ServerConfig
    let onNavigate: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: onNavigate) {
            HStack(spacing: 8) {
                MacServerTypeIcon(type: server.type, size: 20)
                Text(server.name)
                    .font(.title2.weight(.semibold))
                    .foregroundColor(isHovered ? .accentColor : .primary)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .macPointerHover()
    }
}

struct MacLocalGroupHeaderButton: View {
    let icon: String
    let name: String
    var onNavigate: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        if let onNavigate = onNavigate {
            Button(action: onNavigate) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .foregroundColor(isHovered ? .accentColor : .secondary)
                    Text(name)
                        .font(.title2.weight(.semibold))
                        .foregroundColor(isHovered ? .accentColor : .primary)
                }
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .macPointerHover()
        } else {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(.secondary)
                Text(name)
                    .font(.title2.weight(.semibold))
            }
        }
    }
}

struct MacGroupClearCountButton: View {
    let count: Int
    let isConfirming: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if isConfirming {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 14, weight: .semibold))
                } else {
                    Text("\(count)")
                        .font(.system(size: 11).monospacedDigit())
                        .fontWeight(.medium)
                }
            }
            .foregroundColor(isConfirming ? .white : (isHovered ? .primary : .secondary))
            .padding(.horizontal, isConfirming ? 10 : 8)
            .frame(minWidth: 28)
            .frame(height: 24)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isConfirming ? (isHovered ? Color.red.opacity(0.85) : Color.red) : (isHovered ? Color.primary.opacity(0.12) : Color.primary.opacity(0.06)))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .macPointerHover()
    }
}

struct MacHistoryRootView: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @EnvironmentObject private var tabContext: MacTabContext
    @ObservedObject private var historyService = HistoryService.shared
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    
    var onNavigateToServer: ((UUID, VideoFile?) -> Void)? = nil
    var onNavigateToLocal: ((URL, VideoFile?) -> Void)? = nil
    
    private enum MacHistoryAlert: Identifiable {
        case clearAll
        case resourceNotFound(VideoFile, String)
        case connectionError(String)
        
        var id: String {
            switch self {
            case .clearAll: return "clearAll"
            case .resourceNotFound(let file, let msg): return "notFound-\(file.id)-\(msg)"
            case .connectionError(let msg): return "error-\(msg)"
            }
        }
    }
    
    @State private var groupToClearID: String? = nil
    @State private var activeAlert: MacHistoryAlert? = nil
    @State private var isShowingPrivacyUnlock: Bool = false
    @State private var pendingAction: (() -> Void)? = nil

    private var shouldHidePrivateItems: Bool {
        guard securityService.isPrivacySpaceEnabled else { return false }
        if !securityService.isPrivacySpaceUnlocked {
            return true
        }
        if securityService.excludePrivacyFromHistory {
            return !securityService.showPrivateHistory
        }
        return false
    }

    private var groupedHistory: [MacHistoryGroup] {
        var groups: [MacHistoryGroup] = []
        
        let localFiles = historyService.localHistory.filter { file in
            guard HistoryService.isHistoryEnabled(for: file) else { return false }
            if shouldHidePrivateItems && privacySpace.isFileMarkedPrivate(file) { return false }
            return true
        }.sorted(by: { $0.date > $1.date })
        
        if !localFiles.isEmpty {
            groups.append(MacHistoryGroup(id: "local", name: platformShellString("Local"), files: localFiles))
        }
        
        let remoteFiles = historyService.remoteHistory.filter { file in
            guard HistoryService.isHistoryEnabled(for: file) else { return false }
            if shouldHidePrivateItems && privacySpace.isFileMarkedPrivate(file) { return false }
            return true
        }.sorted(by: { $0.date > $1.date })
            
        var remoteServices: [UUID: [VideoFile]] = [:]
        var legacyRemoteGroups: [String: [VideoFile]] = [:]
        
        let orderedServers = networkService.servers
        
        for file in remoteFiles {
            let matchedServer = resolveServer(for: file)
            if let server = matchedServer {
                if remoteServices[server.id] == nil { remoteServices[server.id] = [] }
                remoteServices[server.id]?.append(file)
            } else {
                let key: String
                if let host = file.url.host {
                    let scheme = file.url.scheme?.lowercased() ?? ""
                    if scheme == "smb" { key = "SMB (\(host))" }
                    else if scheme.hasPrefix("http") { key = "WebDAV/Stream (\(host))" }
                    else { key = "\(scheme.uppercased()) (\(host))" }
                } else {
                    key = platformShellString("Remote")
                }
                if legacyRemoteGroups[key] == nil { legacyRemoteGroups[key] = [] }
                legacyRemoteGroups[key]?.append(file)
            }
        }
        
        for server in orderedServers {
            if let files = remoteServices[server.id] {
                groups.append(MacHistoryGroup(id: "server-\(server.id)", name: server.name, files: files.sorted(by: { $0.date > $1.date }), server: server))
            }
        }
        
        let sortedLegacyKeys = legacyRemoteGroups.keys.sorted()
        for key in sortedLegacyKeys {
            if let files = legacyRemoteGroups[key] {
                groups.append(MacHistoryGroup(id: key, name: key, files: files.sorted(by: { $0.date > $1.date })))
            }
        }
        
        return groups
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MacPageHeaderView(title: platformShellString("Play History"), trailingView: AnyView(
                    HStack(spacing: 8) {
                        if tabContext.activeSelection == .history && securityService.isPrivacySpaceEnabled && securityService.excludePrivacyFromHistory && securityService.isPrivacySpaceUnlocked {
                            MacToolbarButton(
                                systemImage: securityService.showPrivateHistory ? "eye" : "eye.slash",
                                title: platformShellString(securityService.showPrivateHistory ? "Hide Private History" : "Show Private History"),
                                symbolSize: 13,
                                symbolWeight: .regular,
                                action: togglePrivacySpaceEye
                            )
                            .padding(4)
                            .modifier(MacToolbarGlass())
                        }

                        if tabContext.activeSelection == .history && !groupedHistory.isEmpty {
                            MacToolbarButton(
                                systemImage: "trash",
                                title: platformShellString("Clear History"),
                                role: .destructive,
                                symbolSize: NSFont.systemFontSize,
                                symbolWeight: .regular
                            ) {
                                activeAlert = .clearAll
                            }
                            .padding(4)
                            .modifier(MacToolbarGlass())
                        }
                    }
                ))
                .padding(.horizontal, 24)
                .padding(.top, 4)
                if groupedHistory.isEmpty {
                    MacEmptyStateView(icon: "clock.arrow.circlepath", title: platformShellString("No History"))
                } else {
                    LazyVStack(spacing: 20) {
                        ForEach(groupedHistory) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    if let server = group.server {
                                        MacServerHeaderButton(server: server) {
                                            self.handleNavigate(to: server)
                                        }
                                    } else {
                                        MacLocalGroupHeaderButton(
                                            icon: group.id == "local" ? "internaldrive.fill" : "network",
                                            name: group.name
                                        )
                                    }
                                        
                                    Spacer()
                                    
                                    MacGroupClearCountButton(
                                        count: group.files.count,
                                        isConfirming: groupToClearID == group.id,
                                        action: {
                                            if groupToClearID == group.id {
                                                withAnimation {
                                                    historyService.clearHistory(for: group.files)
                                                    groupToClearID = nil
                                                }
                                            } else {
                                                withAnimation {
                                                    groupToClearID = group.id
                                                }
                                            }
                                        }
                                    )
                                }
                                .padding(.horizontal, 24)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if groupToClearID != nil {
                                        withAnimation { groupToClearID = nil }
                                    } else {
                                        if let server = group.server {
                                            self.handleNavigate(to: server)
                                        } else if group.id == "local" {
                                            if let firstFile = group.files.first {
                                                let folderURL = firstFile.type == .folder ? firstFile.url : firstFile.url.deletingLastPathComponent()
                                                onNavigateToLocal?(folderURL, nil)
                                            } else if let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                                                onNavigateToLocal?(docsURL, nil)
                                            }
                                        }
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        historyService.clearHistory(for: group.files)
                                    } label: {
                                        Text(platformShellString("Clear Group"))
                                    }
                                }
                                
                                MacHorizontalShelf(items: group.files, spacing: 16, horizontalPadding: 24, verticalPadding: 16, artworkHeight: MacMediaCardMetrics.landscapeHeight) { file in
                                    MacHistoryInteractionCard(
                                        file: file,
                                        onArtworkTap: { playHistory(file) },
                                        onTextTap: { openDetail(for: file) }
                                    )
                                    .contextMenu {
                                        if !file.isRemote {
                                            Button {
                                                let folderURL = file.type == .folder ? file.url : file.url.deletingLastPathComponent()
                                                if let onNavigateToLocal = onNavigateToLocal {
                                                    onNavigateToLocal(folderURL, file)
                                                } else {
                                                    MacSharingService.revealInFinder(url: file.url)
                                                }
                                            } label: {
                                                Label(platformShellString("Show in Folder"), systemImage: "folder")
                                            }

                                            Button {
                                                MacSharingService.revealInFinder(url: file.url)
                                            } label: {
                                                Label(platformShellString("Reveal in Finder"), systemImage: "arrow.up.forward.app")
                                            }
                                            Divider()
                                        }
                                        Button(role: .destructive) {
                                            historyService.removeFromHistory(file)
                                        } label: {
                                            Text(platformShellString("Delete"))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .onTapGesture {
            if groupToClearID != nil {
                withAnimation { groupToClearID = nil }
            }
        }
        .alert(item: $activeAlert) { alertType in
            switch alertType {
            case .clearAll:
                return Alert(
                    title: Text(platformShellString("Clear History")),
                    message: Text(platformShellString("Are you sure you want to clear all play history?")),
                    primaryButton: .destructive(Text(platformShellString("Clear All"))) {
                        let shouldExcludePrivate = securityService.isPrivacySpaceEnabled &&
                            (!securityService.isPrivacySpaceUnlocked || !securityService.showPrivateHistory)
                        historyService.clearHistory(excludingPrivate: shouldExcludePrivate)
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .resourceNotFound(let file, let message):
                return Alert(
                    title: Text(platformShellString("Unable to Play")),
                    message: Text(message),
                    primaryButton: .destructive(Text(platformShellString("Remove from History"))) {
                        historyService.removeFromHistory(file)
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .connectionError(let message):
                return Alert(
                    title: Text(platformShellString("Unable to Play")),
                    message: Text(message),
                    dismissButton: .default(Text(platformShellString("OK")))
                )
            }
        }
        .sheet(isPresented: $isShowingPrivacyUnlock) {
            MacPrivacySpaceUnlockView(isPresented: $isShowingPrivacyUnlock)
            .onDisappear {
                if securityService.isPrivacySpaceUnlocked {
                    pendingAction?()
                }
                pendingAction = nil
            }
        }
        .id("MacHistoryRootView_\(appLanguage)")
    }
    
    private func togglePrivacySpaceEye() {
        withAnimation {
            securityService.showPrivateHistory.toggle()
        }
    }

    private func handleNavigate(to server: ServerConfig) {
        if privacySpace.isServerMarkedPrivate(server) && !securityService.isPrivacySpaceUnlocked {
            pendingAction = { onNavigateToServer?(server.id, nil) }
            isShowingPrivacyUnlock = true
        } else {
            onNavigateToServer?(server.id, nil)
        }
    }

    private func playHistory(_ file: VideoFile) {
        let isFilePrivate = privacySpace.isFileMarkedPrivate(file)
        let isServerPrivate = resolveServer(for: file).map { privacySpace.isServerMarkedPrivate($0) } ?? false
        
        if (isFilePrivate || isServerPrivate) && !securityService.isPrivacySpaceUnlocked {
            pendingAction = { playHistory(file) }
            isShowingPrivacyUnlock = true
            return
        }
        guard file.type == .video || file.type == .audio else { return }
        let playableFile = downloadCenter.localPlaybackFile(for: file) ?? file

        if !playableFile.isRemote {
            if !FileManager.default.fileExists(atPath: playableFile.url.path) {
                activeAlert = .resourceNotFound(file, platformShellString("The local file does not exist or has been deleted."))
                return
            }
            MacPlayerWindowManager.shared.openPlayer(for: playableFile)
            return
        }

        if let server = playableFile.resolvedServer {
            Task { @MainActor in
                do {
                    let validated = try await PlaybackResourceValidator.validatePlayback(for: playableFile)
                    MacPlayerWindowManager.shared.openPlayer(for: validated)
                } catch let valError as PlaybackValidationError {
                    if valError.isResourceNotFound {
                        activeAlert = .resourceNotFound(file, platformShellString("The media resource has been deleted or does not exist on the server."))
                    } else {
                        activeAlert = .connectionError(valError.localizedDescription)
                    }
                } catch {
                    activeAlert = .connectionError(error.localizedDescription)
                }
            }
            return
        }

        MacPlayerWindowManager.shared.openPlayer(for: playableFile)
    }
    
    private func openDetail(for file: VideoFile) {
        let isFilePrivate = privacySpace.isFileMarkedPrivate(file)
        let isServerPrivate = resolveServer(for: file).map { privacySpace.isServerMarkedPrivate($0) } ?? false
        
        if (isFilePrivate || isServerPrivate) && !securityService.isPrivacySpaceUnlocked {
            pendingAction = { openDetail(for: file) }
            isShowingPrivacyUnlock = true
            return
        }
        if let server = resolveServer(for: file) {
            onNavigateToServer?(server.id, file)
        } else if !file.isRemote {
            let folderURL = file.type == .folder ? file.url : file.url.deletingLastPathComponent()
            if let onNavigateToLocal = onNavigateToLocal {
                onNavigateToLocal(folderURL, file)
            } else {
                MacSharingService.revealInFinder(url: file.url)
            }
        } else {
            playHistory(file)
        }
    }
    
    private func resolveServer(for file: VideoFile) -> ServerConfig? {
        if let id = file.jellyfinServerId, let server = AppNetworkService.shared.servers.first(where: { $0.id.uuidString == id }) {
            return server
        }
        if let host = file.url.host {
            return AppNetworkService.shared.servers.first { $0.address.lowercased() == host.lowercased() }
        }
        return nil
    }
    
    private func createNode(for file: VideoFile) -> MacMediaLibraryNode? {
        MacMediaLibraryNode(
            id: file.jellyfinItemId ?? file.id,
            name: file.name,
            type: file.type,
            isFolder: file.type == .folder,
            remotePath: nil,
            posterURL: nil,
            backdropURL: nil,
            playbackURL: file.url,
            playbackPositionTicks: file.lastPlayedPosition.map { Int64($0 * 10_000_000) },
            runTimeTicks: file.duration.map { Int64($0 * 10_000_000) },
            seriesId: file.seriesId,
            seriesName: nil,
            seasonId: file.seasonId
        )
    }
}

struct MacMediaNodeDetailViewWrapper: View {
    let server: ServerConfig
    let node: MacMediaLibraryNode
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        Group {
            if #available(macOS 13.0, *) {
                NavigationStack {
                    content
                }
            } else {
                NavigationView {
                    content
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
    }
    
    private var content: some View {
        MacMediaNodeDetailView(server: server, node: node)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(platformShellString("Close")) {
                        dismiss()
                    }
                }
            }
    }
}

struct MacMediaPlaybackProgressBadge: View {
    let progress: Double
    let systemImageName: String
    let diameter: CGFloat

    private var clampedProgress: Double {
        min(max(progress, 0), 1)
    }

    private var ringColor: Color {
        clampedProgress >= 0.98 ? Color(red: 0.34, green: 0.86, blue: 0.58) : .accentColor
    }

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0, to: clampedProgress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: max(2.2, diameter * 0.07), lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: diameter + 6, height: diameter + 6)

            Circle()
                .fill(Color.black.opacity(0.74))
                .frame(width: diameter, height: diameter)
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )

            Image(systemName: systemImageName)
                .font(.system(size: max(15, diameter * 0.40), weight: .bold))
                .foregroundColor(.white)
        }
        .frame(width: diameter + 6, height: diameter + 6)
        .shadow(color: Color.black.opacity(0.28), radius: 10, x: 0, y: 5)
    }
}

struct MacMediaIndicatorBadge: View {
    let file: VideoFile
    let playbackSnapshot: PlaybackProgressSnapshot?
    let diameter: CGFloat

    var body: some View {
        ZStack {
            if let snapshot = playbackSnapshot, snapshot.displayedProgress > 0 {
                MacMediaPlaybackProgressBadge(
                    progress: snapshot.displayedProgress,
                    systemImageName: file.macPlaybackBadgeSystemImage,
                    diameter: diameter
                )
            } else {
                Circle()
                    .fill(Color.black.opacity(0.74))
                    .frame(width: diameter, height: diameter)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )

                Image(systemName: file.macPlaybackBadgeSystemImage)
                    .font(.system(size: max(10, diameter * 0.40), weight: .bold))
                    .foregroundColor(.white)
            }
        }
        .frame(width: diameter + 6, height: diameter + 6)
        .shadow(color: Color.black.opacity(0.28), radius: 10, x: 0, y: 5)
    }
}

struct MacHistoryInteractionCard: View {
    let file: VideoFile
    let onArtworkTap: () -> Void
    let onTextTap: () -> Void

    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @State private var isTextHovered = false

    private var iconName: String {
        switch file.type {
        case .folder: return "folder.fill"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .image: return "photo"
        default: return "doc.fill"
        }
    }

    private var iconColor: Color {
        switch file.type {
        case .folder: return .blue
        case .video: return .purple
        case .audio: return .pink
        case .image: return .green
        case .document, .subtitle: return .orange
        default: return .secondary
        }
    }

    private var computedThumbnailURL: URL? {
        if let id = file.jellyfinServerId, let server = AppNetworkService.shared.servers.first(where: { $0.id.uuidString == id }) {
            let itemId = file.seriesId?.nilIfEmpty ?? file.jellyfinItemId
            if let itemId, !itemId.isEmpty {
                switch server.type {
                case .plex:
                    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return plexImageURL(baseURL: baseURL, key: "/library/metadata/\(itemId)/thumb", token: server.accessToken)
                case .jellyfin, .emby:
                    return URL(string: "\(server.fullURL)/Items/\(itemId)/Images/Primary")
                default:
                    return nil
                }
            }
        }
        return nil
    }

    private func resolveServer(for file: VideoFile) -> ServerConfig? {
        if let id = file.jellyfinServerId, let server = AppNetworkService.shared.servers.first(where: { $0.id.uuidString == id }) {
            return server
        }
        if let host = file.url.host {
            return AppNetworkService.shared.servers.first { $0.address.lowercased() == host.lowercased() }
        }
        return nil
    }

    private var formattedListDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: file.date).replacingOccurrences(of: ",", with: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onArtworkTap) {
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.gray.opacity(0.08))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                        )
                        .frame(width: MacMediaCardMetrics.landscapeWidth, height: MacMediaCardMetrics.landscapeHeight)

                    if let thumbURL = computedThumbnailURL {
                        MacRemoteArtworkImage(
                            url: thumbURL,
                            placeholderSystemImageName: iconName
                        )
                        .frame(width: 204, height: 115)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    } else {
                        MacRemoteFileImage(file: file, server: resolveServer(for: file))
                            .frame(width: 204, height: 115)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }

                    VStack {
                        HStack {
                            if securityService.isPrivacySpaceEnabled && privacySpace.isFileMarkedPrivate(file) {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(Color.black.opacity(0.6))
                                    .cornerRadius(4)
                                    .padding([.top, .leading], 6)
                            }
                            Spacer()
                            HStack(spacing: 2) {
                                if let server = resolveServer(for: file) {
                                    if let uiImage = NSImage(named: server.type.iconAssetName) {
                                        Image(nsImage: uiImage)
                                            .resizable()
                                            .frame(width: 10, height: 10)
                                    } else {
                                        Image(systemName: server.type.systemIconName)
                                            .font(.system(size: 8, weight: .bold))
                                    }
                                    Text(server.name)
                                        .font(.system(size: 9, weight: .bold))
                                } else if file.isRemote {
                                    Image(systemName: file.serverType?.systemIconName ?? "server.rack")
                                        .font(.system(size: 8, weight: .bold))
                                    Text(file.serverType?.displayName ?? platformShellString("Remote"))
                                        .font(.system(size: 9, weight: .bold))
                                } else {
                                    Image(systemName: "internaldrive.fill")
                                        .font(.system(size: 8, weight: .bold))
                                    Text(platformShellString("Local"))
                                        .font(.system(size: 9, weight: .bold))
                                }
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                            .padding([.top, .trailing], 6)
                        }
                        Spacer()
                    }

                    if let progressTicks = file.lastPlayedPosition, let runTimeTicks = file.duration, progressTicks > 0, runTimeTicks > 0 {
                        MacMediaPlaybackProgressBadge(
                            progress: Double(progressTicks) / Double(runTimeTicks),
                            systemImageName: file.type == .audio ? "music.note" : "play.fill",
                            diameter: 18
                        )
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .allowsHitTesting(false)
                    }

                    if securityService.isPrivacySpaceEnabled && privacySpace.isFileMarkedPrivate(file) {
                        Image(systemName: securityService.isPrivacySpaceUnlocked ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                            .padding([.top, .leading], 6)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .allowsHitTesting(false)
                    }
                }
            }
            .buttonStyle(.plain)
            .macCardHoverEffectCore(cornerRadius: 12)

            Button(action: onTextTap) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(macLineBreakableTitle(file.name))
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(isTextHovered ? .accentColor : .primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                    
                    if file.jellyfinItemId != nil || file.serverType == .jellyfin || file.serverType == .emby {
                        Text(formattedListDate)
                            .font(.caption2)
                            .foregroundColor(isTextHovered ? .primary.opacity(0.8) : .secondary)
                            .lineLimit(1)
                    } else if let folder = file.url.deletingLastPathComponent().pathComponents.last, folder != "/" {
                        Text(folder)
                            .font(.caption2)
                            .foregroundColor(isTextHovered ? .primary.opacity(0.8) : .secondary)
                            .lineLimit(1)
                    }
                    
                    Spacer(minLength: 0)
                }
                .frame(width: 204, height: 48, alignment: .topLeading)
            }
            .buttonStyle(.plain)
            .onHover { isTextHovered = $0 }
            .macPointerHover()
        }
        .frame(width: 204, alignment: .topLeading)
    }
}
struct MacFavoriteGroup: Identifiable {
    let id: String
    let name: String
    var files: [VideoFile]
    var server: ServerConfig? = nil
}

struct MacFavoritesRootView: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @EnvironmentObject private var tabContext: MacTabContext
    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    
    var onNavigateToServer: ((UUID, VideoFile?) -> Void)? = nil
    var onNavigateToLocal: ((URL, VideoFile?) -> Void)? = nil
    
    private enum MacFavoritesAlert: Identifiable {
        case clearAll
        case resourceNotFound(VideoFile, String)
        case connectionError(String)
        
        var id: String {
            switch self {
            case .clearAll: return "clearAll"
            case .resourceNotFound(let file, let msg): return "notFound-\(file.id)-\(msg)"
            case .connectionError(let msg): return "error-\(msg)"
            }
        }
    }

    @State private var groupToClearID: String? = nil
    @State private var activeAlert: MacFavoritesAlert? = nil
    @State private var isShowingPrivacyUnlock: Bool = false
    @State private var pendingAction: (() -> Void)? = nil

    private var shouldHidePrivateItems: Bool {
        securityService.isPrivacySpaceEnabled &&
        securityService.hideLockedItems &&
        !securityService.isPrivacySpaceUnlocked
    }

    private var groupedFavorites: [MacFavoriteGroup] {
        var groups: [MacFavoriteGroup] = []
        
        let localFiles = favoriteService.favorites
            .filter { !$0.file.isRemote }
            .filter { !shouldHidePrivateItems || !privacySpace.isFileMarkedPrivate($0.file) }
            .sorted(by: { $0.addedDate > $1.addedDate })
            .map { $0.file }
        
        if !localFiles.isEmpty {
            groups.append(MacFavoriteGroup(id: "local", name: platformShellString("Local"), files: localFiles))
        }
        
        let remoteFiles = favoriteService.favorites
            .filter { $0.file.isRemote }
            .filter { !shouldHidePrivateItems || !privacySpace.isFileMarkedPrivate($0.file) }
            .sorted(by: { $0.addedDate > $1.addedDate })
            .map { $0.file }
            
        var remoteServices: [UUID: [VideoFile]] = [:]
        var legacyRemoteGroups: [String: [VideoFile]] = [:]
        
        let orderedServers = networkService.servers
        
        for file in remoteFiles {
            let matchedServer = resolveServer(for: file)
            if let server = matchedServer {
                if remoteServices[server.id] == nil { remoteServices[server.id] = [] }
                remoteServices[server.id]?.append(file)
            } else if let host = file.url.host {
                if legacyRemoteGroups[host] == nil { legacyRemoteGroups[host] = [] }
                legacyRemoteGroups[host]?.append(file)
            }
        }
        
        for server in orderedServers {
            if let files = remoteServices[server.id], !files.isEmpty {
                groups.append(MacFavoriteGroup(id: server.id.uuidString, name: server.name, files: files, server: server))
            }
        }
        
        for (host, files) in legacyRemoteGroups {
            if !files.isEmpty {
                groups.append(MacFavoriteGroup(id: host, name: host, files: files))
            }
        }
        
        return groups
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                MacPageHeaderView(title: platformShellString("Favorites"), trailingView: AnyView(
                    Group {
                        if tabContext.activeSelection == .favorites && !groupedFavorites.isEmpty {
                            MacToolbarButton(
                                systemImage: "trash",
                                title: platformShellString("Clear Favorites"),
                                role: .destructive,
                                symbolSize: NSFont.systemFontSize,
                                symbolWeight: .regular
                            ) {
                                activeAlert = .clearAll
                            }
                            .padding(4)
                            .modifier(MacToolbarGlass())
                        }
                    }
                ))
                .padding(.horizontal, 24)
                .padding(.top, 4)
                if groupedFavorites.isEmpty {
                    MacEmptyStateView(icon: "star", title: platformShellString("No Favorites"))
                } else {
                    LazyVStack(spacing: 20) {
                        ForEach(groupedFavorites) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    if let server = group.server {
                                        MacServerHeaderButton(server: server) {
                                            self.handleNavigate(to: server)
                                        }
                                    } else {
                                        MacLocalGroupHeaderButton(
                                            icon: group.id == "local" ? "internaldrive.fill" : "network",
                                            name: group.name
                                        )
                                    }
                                        
                                    Spacer()
                                    
                                    MacGroupClearCountButton(
                                        count: group.files.count,
                                        isConfirming: groupToClearID == group.id,
                                        action: {
                                            if groupToClearID == group.id {
                                                withAnimation {
                                                    for file in group.files {
                                                        if let item = favoriteService.favorites.first(where: { $0.file.id == file.id }) {
                                                            favoriteService.remove(item)
                                                        }
                                                    }
                                                    groupToClearID = nil
                                                }
                                            } else {
                                                withAnimation {
                                                    groupToClearID = group.id
                                                }
                                            }
                                        }
                                    )
                                }
                                .padding(.horizontal, 24)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if groupToClearID != nil {
                                        withAnimation { groupToClearID = nil }
                                    } else {
                                        if let server = group.server {
                                            self.handleNavigate(to: server)
                                        } else if group.id == "local" {
                                            if let firstFile = group.files.first {
                                                let folderURL = firstFile.type == .folder ? firstFile.url : firstFile.url.deletingLastPathComponent()
                                                onNavigateToLocal?(folderURL, nil)
                                            } else if let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                                                onNavigateToLocal?(docsURL, nil)
                                            }
                                        }
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        for file in group.files {
                                            if let item = favoriteService.favorites.first(where: { $0.file.id == file.id }) {
                                                favoriteService.remove(item)
                                            }
                                        }
                                    } label: {
                                        Text(platformShellString("Clear Group"))
                                    }
                                }
                                
                                MacHorizontalShelf(items: group.files, spacing: 16, horizontalPadding: 24, verticalPadding: 16, artworkHeight: MacMediaCardMetrics.landscapeHeight) { file in
                                    MacHistoryInteractionCard(
                                        file: file,
                                        onArtworkTap: { playFavorite(file) },
                                        onTextTap: { openDetail(for: file) }
                                    )
                                    .contextMenu {
                                        if !file.isRemote {
                                            Button {
                                                let folderURL = file.type == .folder ? file.url : file.url.deletingLastPathComponent()
                                                if let onNavigateToLocal = onNavigateToLocal {
                                                    onNavigateToLocal(folderURL, file)
                                                } else {
                                                    MacSharingService.revealInFinder(url: file.url)
                                                }
                                            } label: {
                                                Label(platformShellString("Show in Folder"), systemImage: "folder")
                                            }

                                            Button {
                                                MacSharingService.revealInFinder(url: file.url)
                                            } label: {
                                                Label(platformShellString("Reveal in Finder"), systemImage: "arrow.up.forward.app")
                                            }
                                            Divider()
                                        }
                                        Button(role: .destructive) {
                                            if let item = favoriteService.favorites.first(where: { $0.file.id == file.id }) {
                                                favoriteService.remove(item)
                                            }
                                        } label: {
                                            Text(platformShellString("Remove Favorite"))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
        }
        .onTapGesture {
            if groupToClearID != nil {
                withAnimation { groupToClearID = nil }
            }
        }
        .alert(item: $activeAlert) { alertType in
            switch alertType {
            case .clearAll:
                return Alert(
                    title: Text(platformShellString("Clear Favorites")),
                    message: Text(platformShellString("Are you sure you want to remove all favorites?")),
                    primaryButton: .destructive(Text(platformShellString("Clear All"))) {
                        favoriteService.clearAll()
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .resourceNotFound(let file, let message):
                return Alert(
                    title: Text(platformShellString("Unable to Play")),
                    message: Text(message),
                    primaryButton: .destructive(Text(platformShellString("Remove from History"))) {
                        favoriteService.remove(file: file)
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .connectionError(let message):
                return Alert(
                    title: Text(platformShellString("Unable to Play")),
                    message: Text(message),
                    dismissButton: .default(Text(platformShellString("OK")))
                )
            }
        }
        .sheet(isPresented: $isShowingPrivacyUnlock) {
            MacPrivacySpaceUnlockView(isPresented: $isShowingPrivacyUnlock)
            .onDisappear {
                if securityService.isPrivacySpaceUnlocked {
                    pendingAction?()
                }
                pendingAction = nil
            }
        }
        .id("MacFavoritesRootView_\(appLanguage)")
    }
    
    private func handleNavigate(to server: ServerConfig) {
        if privacySpace.isServerMarkedPrivate(server) && !securityService.isPrivacySpaceUnlocked {
            pendingAction = { onNavigateToServer?(server.id, nil) }
            isShowingPrivacyUnlock = true
        } else {
            onNavigateToServer?(server.id, nil)
        }
    }

    private func playFavorite(_ file: VideoFile) {
        let isFilePrivate = privacySpace.isFileMarkedPrivate(file)
        let isServerPrivate = resolveServer(for: file).map { privacySpace.isServerMarkedPrivate($0) } ?? false
        
        if (isFilePrivate || isServerPrivate) && !securityService.isPrivacySpaceUnlocked {
            pendingAction = { playFavorite(file) }
            isShowingPrivacyUnlock = true
            return
        }
        if file.serverType == .vod {
            openDetail(for: file)
            return
        }
        guard file.type == .video || file.type == .audio else {
            openDetail(for: file)
            return
        }
        let playableFile = downloadCenter.localPlaybackFile(for: file) ?? file

        if !playableFile.isRemote {
            if !FileManager.default.fileExists(atPath: playableFile.url.path) {
                activeAlert = .resourceNotFound(file, platformShellString("The local file does not exist or has been deleted."))
                return
            }
            MacPlayerWindowManager.shared.openPlayer(for: playableFile)
            return
        }

        if let server = playableFile.resolvedServer {
            Task { @MainActor in
                do {
                    let validated = try await PlaybackResourceValidator.validatePlayback(for: playableFile)
                    MacPlayerWindowManager.shared.openPlayer(for: validated)
                } catch let valError as PlaybackValidationError {
                    if valError.isResourceNotFound {
                        activeAlert = .resourceNotFound(file, platformShellString("The media resource has been deleted or does not exist on the server."))
                    } else {
                        activeAlert = .connectionError(valError.localizedDescription)
                    }
                } catch {
                    activeAlert = .connectionError(error.localizedDescription)
                }
            }
            return
        }

        MacPlayerWindowManager.shared.openPlayer(for: playableFile)
    }

    private func openDetail(for file: VideoFile) {
        let isFilePrivate = privacySpace.isFileMarkedPrivate(file)
        let isServerPrivate = resolveServer(for: file).map { privacySpace.isServerMarkedPrivate($0) } ?? false
        
        if (isFilePrivate || isServerPrivate) && !securityService.isPrivacySpaceUnlocked {
            pendingAction = { openDetail(for: file) }
            isShowingPrivacyUnlock = true
            return
        }
        if let server = resolveServer(for: file) {
            onNavigateToServer?(server.id, file)
        } else if !file.isRemote {
            let folderURL = file.type == .folder ? file.url : file.url.deletingLastPathComponent()
            if let onNavigateToLocal = onNavigateToLocal {
                onNavigateToLocal(folderURL, file)
            } else {
                MacSharingService.revealInFinder(url: file.url)
            }
        }
    }

    private func resolveServer(for file: VideoFile) -> ServerConfig? {
        if let id = file.jellyfinServerId, let server = AppNetworkService.shared.servers.first(where: { $0.id.uuidString == id }) {
            return server
        }
        if let host = file.url.host {
            return AppNetworkService.shared.servers.first { $0.address.lowercased() == host.lowercased() }
        }
        return nil
    }
}

private struct MacEmptyStateView: View {
    let icon: String
    let title: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 64))
                .foregroundColor(.secondary.opacity(0.5))
            Text(title)
                .font(.title2.weight(.medium))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
    }
}


struct MacSettingsRootView: View {
    @EnvironmentObject private var tabContext: MacTabContext
    enum SettingsTab: String, CaseIterable, Identifiable {
        case general = "General"
        case playback = "Playback"
        case security = "Security"
        case appIcon = "App Icon"
        case advanced = "Advanced Settings"
        case storage = "Storage"
        case donation = "Support GenPlayer"
        case about = "About"
        
        var id: String { rawValue }
        
        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .playback: return "play.circle"
            case .security: return "lock.shield"
            case .appIcon: return "app.badge"
            case .advanced: return "slider.horizontal.3"
            case .storage: return "externaldrive"
            case .donation: return "heart.fill"
            case .about: return "info.circle"
            }
        }
    }

    @ObservedObject private var navManager = MacNavigationManager.shared
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var historyService = HistoryService.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var backupManager = MacServerBackupManager.shared
    @ObservedObject private var donationService = DonationService.shared

    @AppStorage("allowRemoteMutationOperations") private var allowRemoteMutationOperations = false
    @AppStorage("enableVideoHistory") private var enableVideoHistory = true
    @AppStorage("enableAudioHistory") private var enableAudioHistory = true

    @AppStorage("userTheme") private var userTheme: String = "System"
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @AppStorage("doubleTapSeekDuration") private var doubleTapSeekDuration: Double = 15.0
    @AppStorage("defaultPlaybackSpeed") private var defaultPlaybackSpeed: Double = 1.0
    @AppStorage("defaultAudioPlaybackSpeed") private var defaultAudioPlaybackSpeed: Double = 1.0
    @AppStorage("subtitleAutoSelectionMode") private var subtitleAutoSelectionModeRaw: String = "followAppLanguage"
    @AppStorage("enableSecondarySubtitlesBeta") private var enableSecondarySubtitlesBeta: Bool = false
    @AppStorage("enableMacPiPBeta") private var enableMacPiPBeta: Bool = true
    @AppStorage("subtitleDelaySeconds") private var subtitleDelaySeconds: Double = 0.0
    @AppStorage("audioDelaySeconds") private var audioDelaySeconds: Double = 0.0
    @AppStorage("macVideoPlaybackEngine") private var macVideoPlaybackEngine = "mpv"
    @AppStorage("defaultVideoDecoder") private var defaultVideoDecoderRaw: String = "hw"
    @AppStorage("enableRemoteFileCache") private var enableRemoteFileCache: Bool = true
    @AppStorage("enableICloudServerListSync") private var enableICloudServerListSync: Bool = false
    @AppStorage("onboardingForceReplay") private var onboardingForceReplay: Bool = false
    @AppStorage("allowMediaServerDeletion") private var allowMediaServerDeletion = false
    @AppStorage("extractRemoteAudioArtwork") private var extractRemoteAudioArtwork = false
    @AppStorage("macSnapshotSaveLocation") private var macSnapshotSaveLocation: String = "desktop"
    @AppStorage("macSnapshotCustomFolderPath") private var macSnapshotCustomFolderPath: String = ""

    @State private var selectedTab: SettingsTab? = .general
    @State private var showingLanguageRestartAlert = false

    private var visibleTabs: [SettingsTab] {
        SettingsTab.allCases.filter { tab in
            if tab == .donation {
                return donationService.isChinaStorefront
            }
            return true
        }
    }

    private var availablePlaybackRates: [Double] {
        macVideoPlaybackEngine == "mpv" ? MPVPlaybackSpeed.rates.map(Double.init) : [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0]
    }
    private var subtitleModes: [(String, String)] {
        [
            ("off", platformShellString("Off")),
            ("followAppLanguage", platformShellString("Follow App Language")),
            ("chinese", platformShellString("Chinese")),
            ("english", platformShellString("English"))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MacPageHeaderView(title: platformShellString("Settings"))
                .padding(.horizontal, 24)
                .padding(.top, 4)
                .padding(.bottom, 16)
            
            HStack(spacing: 0) {
                // Sidebar
                List(selection: $selectedTab) {
                    ForEach(visibleTabs) { tab in
                        HStack {
                            Label(platformShellString(tab.rawValue), systemImage: tab.icon)
                            Spacer()
                            if tab == .donation && donationService.isLifetimeSupporter {
                                Image(systemName: "crown.fill")
                                    .font(.caption2)
                                    .foregroundColor(.yellow)
                            }
                        }
                        .tag(tab)
                        .id("\(tab.rawValue)_\(appLanguage)")
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 240)
                .background(Color(NSColor.controlBackgroundColor))
            
            Divider()
            
            // Detail
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                        switch selectedTab ?? .general {
                        case .general:
                            settingsRow(title: "Theme") {
                                Picker("", selection: $userTheme) {
                                    let systemThemeStr = trueSystemThemeIsDark() ? platformShellString("Dark") : platformShellString("Light")
                                    Text("\(platformShellString("System")) · \(systemThemeStr)").tag("System")
                                    Text(platformShellString("Light")).tag("Light")
                                    Text(platformShellString("Dark")).tag("Dark")
                                }
                            }
                            Divider().opacity(0.5)
                            settingsRow(title: "Language") {
                                Picker("", selection: Binding(
                                    get: { appLanguage },
                                    set: { language in
                                        guard language != appLanguage else { return }
                                        appLanguage = language
                                        if language == "system" {
                                            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                                        } else {
                                            UserDefaults.standard.set([language], forKey: "AppleLanguages")
                                        }
                                        UserDefaults.standard.synchronize()
                                        showingLanguageRestartAlert = true
                                    }
                                )) {
                                    ForEach(["system", "en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es"], id: \.self) { language in
                                        Text(languageName(for: language)).tag(language)
                                    }
                                }
                            }
                            Divider().opacity(0.5)
                            settingsRow(title: "Replay Onboarding") {
                                Button(platformShellString("Replay")) {
                                    onboardingForceReplay = true
                                }
                            }
                            Divider().opacity(0.5)
                            settingsRow(title: "App Icon") {
                                Button(platformShellString("App Icon")) {
                                    selectedTab = .appIcon
                                }
                            }
                        case .security:
                            MacSecuritySettingsView()
                            
                        case .playback:
                            settingsToggle(title: "Video Playback History", isOn: $enableVideoHistory)
                            Divider().opacity(0.5)
                            settingsToggle(title: "Audio Playback History", isOn: $enableAudioHistory)
                            Divider().opacity(0.5)
                            settingsRow(title: "Seek Time") {
                                Picker("", selection: $doubleTapSeekDuration) {
                                    Text("5s").tag(5.0)
                                    Text("10s").tag(10.0)
                                    Text("15s").tag(15.0)
                                    Text("30s").tag(30.0)
                                }
                            }
                            Divider().opacity(0.5)
                            settingsRow(title: "Default Video Playback Speed") {
                                Picker("", selection: $defaultPlaybackSpeed) {
                                    ForEach(availablePlaybackRates, id: \.self) { rate in
                                        Text("\(String(format: "%g", rate))x").tag(rate)
                                    }
                                }
                            }
                            Divider().opacity(0.5)
                            settingsRow(title: "Default Audio Playback Speed") {
                                Picker("", selection: $defaultAudioPlaybackSpeed) {
                                    ForEach(availablePlaybackRates, id: \.self) { rate in
                                        Text("\(String(format: "%g", rate))x").tag(rate)
                                    }
                                }
                            }
                            Divider().opacity(0.5)
                            settingsRow(title: "Auto Subtitle Selection") {
                                Picker("", selection: $subtitleAutoSelectionModeRaw) {
                                    ForEach(subtitleModes, id: \.0) { mode in
                                        Text(mode.1).tag(mode.0)
                                    }
                                }
                            }
                            Divider().opacity(0.5)
                            settingsToggle(title: "Secondary Subtitles", isOn: $enableSecondarySubtitlesBeta)
                            Divider().opacity(0.5)
                            settingsToggle(title: "Picture in Picture", isOn: $enableMacPiPBeta)
                            Divider().opacity(0.5)
                            settingsToggle(title: "Multi-Window Playback", isOn: Binding(get: {
                                UserDefaults.standard.object(forKey: "enableMacMultiWindow") as? Bool ?? true
                            }, set: {
                                UserDefaults.standard.set($0, forKey: "enableMacMultiWindow")
                            }))
                            Divider().opacity(0.5)
                            settingsRow(title: "Default Subtitle Delay") {
                                Picker("", selection: $subtitleDelaySeconds) {
                                    delayOptions
                                }
                            }
                            Divider().opacity(0.5)
                            settingsRow(title: "Default Audio Delay") {
                                Picker("", selection: $audioDelaySeconds) {
                                    delayOptions
                                }
                            }
                            Divider().opacity(0.5)
                            settingsRow(title: "Screenshot Save Location", contentWidth: 200) {
                                Picker("", selection: Binding(
                                    get: {
                                        let current = macSnapshotSaveLocation
                                        if current == "custom" && !macSnapshotCustomFolderPath.isEmpty {
                                            return "custom"
                                        } else if current == "downloads" {
                                            return "downloads"
                                        } else {
                                            return "desktop"
                                        }
                                    },
                                    set: { newValue in
                                        if newValue == "chooseCustom" {
                                            selectCustomSnapshotFolder()
                                        } else if newValue == "desktop" {
                                            selectDesktopSnapshotFolder()
                                        } else if newValue == "downloads" {
                                            selectDownloadsSnapshotFolder()
                                        } else {
                                            macSnapshotSaveLocation = newValue
                                        }
                                    }
                                )) {
                                    Text(platformShellString("Desktop")).tag("desktop")
                                    Text(platformShellString("Downloads")).tag("downloads")
                                    Divider()
                                    if !macSnapshotCustomFolderPath.isEmpty {
                                        Text(customFolderDisplayName).tag("custom")
                                    }
                                    Text(platformShellString("Other Folder...")).tag("chooseCustom")
                                }
                            }

                        case .appIcon:
                            MacSettingsAppIconView(onNavigateToDonation: {
                                selectedTab = .donation
                            })
                            
                        case .advanced:
                            settingsRow(title: platformShellString("MPV.Engine")) {
                                Picker("", selection: $macVideoPlaybackEngine) {
                                    Text("VLC").tag("vlc")
                                    Text(platformShellString("MPV.Name")).tag("mpv")
                                }
                            }
                            Divider().opacity(0.5)
                            settingsRow(title: "Default Video Decoder") {
                                Picker("", selection: $defaultVideoDecoderRaw) {
                                    Text(platformShellString("Hardware (HW)")).tag("hw")
                                    Text(platformShellString("Software (SW)")).tag("sw")
                                }
                            }
                            Divider().opacity(0.5)
                            settingsToggle(title: "Sync Server List via iCloud", isOn: Binding(
                                get: { enableICloudServerListSync },
                                set: { enabled in
                                    enableICloudServerListSync = enabled
                                    networkService.setICloudServerListSyncEnabled(enabled)
                                }
                            ))
                            Divider().opacity(0.5)
                            settingsToggle(title: "Enable Remote File Cache", isOn: $enableRemoteFileCache)
                            Divider().opacity(0.5)
                            settingsToggle(title: "Extract Remote Audio Artwork", isOn: $extractRemoteAudioArtwork)
                            Divider().opacity(0.5)
                            settingsToggle(title: "Allow Remote File Modifications", isOn: $allowRemoteMutationOperations)
                            Divider().opacity(0.5)
                            settingsToggle(title: platformShellString("Allow Media Server Deletion"), isOn: $allowMediaServerDeletion)
                            Divider().opacity(0.5)
                            settingsRow(title: "Server Backup") {
                                HStack(spacing: 8) {
                                    Button(platformShellString("Import")) {
                                        MacServerBackupManager.shared.importServers()
                                    }
                                    Button(platformShellString("Export")) {
                                        MacServerBackupManager.shared.exportServers()
                                    }
                                }
                            }
                        case .storage:
                            MacStorageSettingsView()
                        case .donation:
                            MacSettingsDonationView(onChangeAppIcon: {
                                selectedTab = .appIcon
                            })
                        case .about:
                            MacSettingsAboutView(onNavigateToDonation: {
                                selectedTab = .donation
                            })
                        }
                    }
                    .padding(24)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 32)
                .padding(.top, 16)
                .padding(.bottom, 40)
                .frame(maxWidth: 800, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if let target = navManager.targetSettingsTab {
                if let tab = SettingsTab(rawValue: target) {
                    selectedTab = tab
                } else if target == "About" {
                    selectedTab = .about
                }
                DispatchQueue.main.async {
                    navManager.targetSettingsTab = nil
                }
            }
        }
        .onChange(of: navManager.targetSettingsTab) { newTab in
            if let newTab {
                if let tab = SettingsTab(rawValue: newTab) {
                    selectedTab = tab
                } else if newTab == "About" {
                    selectedTab = .about
                }
                DispatchQueue.main.async {
                    navManager.targetSettingsTab = nil
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .macNavigateToSettingsAbout)) { _ in
            selectedTab = .about
            DispatchQueue.main.async {
                navManager.targetSettingsTab = nil
            }
        }
        .alert(isPresented: $showingLanguageRestartAlert) {
            Alert(
                title: Text(platformShellString("Language Changed")),
                message: Text(platformShellString("Language Restart Prompt")),
                primaryButton: .default(Text(platformShellString("Restart Now")), action: {
                    #if os(macOS)
                    relaunchMacApp()
                    #endif
                }),
                secondaryButton: .cancel(Text(platformShellString("Later")))
            )
        }
        .alert(item: $backupManager.alertItem) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text(platformShellString("OK")))
            )
        }
        .id("MacSettingsRootView_\(appLanguage)")
    }
    
    private func settingsRow<Content: View>(title: String, contentWidth: CGFloat = 160, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(platformShellString(title))
            Spacer()
            content()
                .frame(width: contentWidth, alignment: .trailing)
                .labelsHidden()
        }
    }

    private var customFolderDisplayName: String {
        let url = URL(fileURLWithPath: macSnapshotCustomFolderPath)
        return "📁 " + url.lastPathComponent
    }

    private func selectCustomSnapshotFolder() {
        if MacVLCPlaybackService.MacSnapshotDestinationManager.shared.authorizeFolder(location: "custom") {
            macSnapshotCustomFolderPath = UserDefaults.standard.string(forKey: "macSnapshotCustomFolderPath") ?? ""
            macSnapshotSaveLocation = "custom"
        }
    }

    private func selectDesktopSnapshotFolder() {
        if MacVLCPlaybackService.MacSnapshotDestinationManager.shared.isLocationAuthorized("desktop") {
            macSnapshotSaveLocation = "desktop"
        } else if MacVLCPlaybackService.MacSnapshotDestinationManager.shared.authorizeFolder(location: "desktop") {
            macSnapshotSaveLocation = "desktop"
        }
    }

    private func selectDownloadsSnapshotFolder() {
        if MacVLCPlaybackService.MacSnapshotDestinationManager.shared.isLocationAuthorized("downloads") {
            macSnapshotSaveLocation = "downloads"
        } else if MacVLCPlaybackService.MacSnapshotDestinationManager.shared.authorizeFolder(location: "downloads") {
            macSnapshotSaveLocation = "downloads"
        }
    }
    
    private func settingsToggle(title: String, isOn: Binding<Bool>) -> some View {
        settingsRow(title: title) {
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
        }
    }
    
    private var delayOptions: some View {
        ForEach(Array(stride(from: -5.0, through: 5.01, by: 0.1)), id: \.self) { value in
            Text(String(format: "%.1f s", value)).tag(value)
        }
    }

    private func trueSystemThemeIsDark() -> Bool {
        #if os(macOS)
        if let style = UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")?["AppleInterfaceStyle"] as? String {
            return style.lowercased().contains("dark")
        }
        return false
        #else
        return colorScheme == .dark
        #endif
    }

    private func resolvedSystemLanguage() -> String {
        #if os(macOS)
        if let globalLangs = UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")?["AppleLanguages"] as? [String],
           let first = globalLangs.first {
            return normalizeLanguageCode(first)
        }
        #endif
        let preferred = Locale.preferredLanguages.first ?? "en"
        return normalizeLanguageCode(preferred)
    }

    private func normalizeLanguageCode(_ raw: String) -> String {
        let normalized = raw.replacingOccurrences(of: "_", with: "-").lowercased()
        if normalized.hasPrefix("zh") {
            if normalized.contains("hant") || normalized.contains("tw") || normalized.contains("hk") || normalized.contains("mo") {
                return "zh-Hant"
            }
            return "zh-Hans"
        }
        if normalized.hasPrefix("en") { return "en" }
        if normalized.hasPrefix("ja") { return "ja" }
        if normalized.hasPrefix("ko") { return "ko" }
        if normalized.hasPrefix("fr") { return "fr" }
        if normalized.hasPrefix("de") { return "de" }
        if normalized.hasPrefix("es") { return "es" }
        return "en"
    }

    private func languageName(for code: String) -> String {
        if code == "system" {
            let resolved = resolvedSystemLanguage()
            return "\(platformShellString("System")) · \(languageName(for: resolved))"
        }
        switch code {
        case "en": return "English"
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁體中文"
        case "ja": return "日本語"
        case "ko": return "한국어"
        case "fr": return "Français"
        case "de": return "Deutsch"
        case "es": return "Español"
        default: return code
        }
    }
}

public struct MacFeedbackDraft: Identifiable {
    public let id = UUID()
    public let recipient: String
    public let subject: String
    public let messageBody: String
    
    public init(recipient: String, subject: String, messageBody: String) {
        self.recipient = recipient
        self.subject = subject
        self.messageBody = messageBody
    }
}

@MainActor
public final class MacFeedbackManager: ObservableObject {
    public static let shared = MacFeedbackManager()
    
    public static let recipientEmail = "fufuguo86+genplayer@gmail.com"
    
    private init() {}
    
    public func makeDraft() -> MacFeedbackDraft {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        let osLabel = Self.osDescription
        let deviceLabel = Self.deviceDescription
        let themeLabel = Self.themeDescription
        let languageLabel = Self.languageDescription
        let systemLanguageLabel = Self.systemLanguageDescription
        let timestamp = ISO8601DateFormatter().string(from: Date())
        
        let body = """
        \(platformShellString("Feedback Body Intro"))

        \(platformShellString("Feedback Body What Happened"))
        \(platformShellString("Feedback Body Reproduce"))
        \(platformShellString("Feedback Body Expected"))

        ---
        \(platformShellString("Feedback Field App")): Gen Player \(appVersion) (\(buildNumber))
        \(platformShellString("Feedback Field OS")): \(osLabel)
        \(platformShellString("Feedback Field Device")): \(deviceLabel)
        \(platformShellString("Feedback Field Theme")): \(themeLabel)
        \(platformShellString("Feedback Field App Language")): \(languageLabel)
        \(platformShellString("Feedback Field System Language")): \(systemLanguageLabel)
        \(platformShellString("Feedback Field Time")): \(timestamp)
        """
        
        return MacFeedbackDraft(
            recipient: Self.recipientEmail,
            subject: platformShellString("Feedback Email Subject"),
            messageBody: body
        )
    }
    
    public func mailtoURL(for draft: MacFeedbackDraft) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = draft.recipient
        components.queryItems = [
            URLQueryItem(name: "subject", value: draft.subject),
            URLQueryItem(name: "body", value: draft.messageBody)
        ]
        return components.url
    }
    
    public func sendFeedback() {
        let draft = makeDraft()
        
        if let url = mailtoURL(for: draft), NSWorkspace.shared.open(url) {
            return
        }
        
        copyDraftToPasteboard(draft)
        showNoEmailAppAlert()
    }
    
    private func copyDraftToPasteboard(_ draft: MacFeedbackDraft) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let fullContent = "To: \(draft.recipient)\nSubject: \(draft.subject)\n\n\(draft.messageBody)"
        pasteboard.setString(fullContent, forType: .string)
    }
    
    private func showNoEmailAppAlert() {
        let alert = NSAlert()
        alert.messageText = platformShellString("No Email App Available")
        alert.informativeText = platformShellString("Feedback Fallback Message")
        alert.alertStyle = .informational
        alert.addButton(withTitle: platformShellString("OK"))
        alert.runModal()
    }
    
    private static var osDescription: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    
    private static var deviceDescription: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        if size > 0 {
            var model = [CChar](repeating: 0, count: size)
            sysctlbyname("hw.model", &model, &size, nil, 0)
            let modelString = String(cString: model).trimmingCharacters(in: .whitespacesAndNewlines)
            if !modelString.isEmpty {
                return "Mac (\(modelString))"
            }
        }
        return "Mac"
    }
    
    private static var themeDescription: String {
        let setting = UserDefaults.standard.string(forKey: "userTheme") ?? "System"
        switch setting {
        case "Light": return platformShellString("Light")
        case "Dark": return platformShellString("Dark")
        default: return platformShellString("System")
        }
    }
    
    private static var languageDescription: String {
        let lang = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        return languageName(for: lang)
    }
    
    private static func languageName(for code: String) -> String {
        switch code {
        case "system":
            let systemStr = platformShellString("System")
            let resolved = platformResolvedLanguage(for: "system")
            return "\(systemStr) (\(resolved))"
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁體中文"
        case "en": return "English"
        case "ja": return "日本語"
        case "ko": return "한국어"
        case "fr": return "Français"
        case "de": return "Deutsch"
        case "es": return "Español"
        default: return code
        }
    }
    
    private static var systemLanguageDescription: String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        return Locale.current.localizedString(forIdentifier: preferred) ?? preferred
    }
}

struct MacSettingsAboutView: View {
    var onNavigateToDonation: (() -> Void)? = nil
    @ObservedObject private var donationService = DonationService.shared
    @State private var showingOpenSourceLicenses = false
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    private let websiteURL = URL(string: "https://genplayer.fugary.com/")!
    private let releaseNotesURL = URL(string: "https://genplayer.fugary.com/changelog.html")!
    private let privacyPolicyURL = URL(string: "https://genplayer.fugary.com/privacy.html")!
    private let openSourceURL = URL(string: "https://genplayer.fugary.com/opensource.html")!

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 16) {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 60))
                    .foregroundColor(.blue)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(20)
                
                Text(platformShellString("Gen Player"))
                    .font(.title2)
                    .fontWeight(.bold)
                
                Text("\(platformShellString("Version")) \(appVersion) (\(buildNumber))")
                    .foregroundColor(.secondary)
                    .font(.footnote)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
            
            VStack(alignment: .leading, spacing: 10) {
                Text(platformShellString("Description"))
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Text(platformShellString("AppDescription"))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(platformShellString("Copyright"))
                    Spacer()
                    Text("© 2026 Gary Fu")
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 4)
                
                if donationService.isChinaStorefront {
                    aboutNavigationRow(
                        title: platformShellString("Support GenPlayer"),
                        icon: "heart.fill"
                    ) {
                        onNavigateToDonation?()
                    }
                }

                aboutLinkRow(
                    title: platformShellString("Website"),
                    icon: "globe",
                    destination: websiteURL
                )

                aboutLinkRow(
                    title: platformShellString("Privacy Policy"),
                    icon: "hand.raised.fill",
                    destination: privacyPolicyURL
                )

                aboutLinkRow(
                    title: platformShellString("Release Notes"),
                    icon: "doc.text",
                    destination: releaseNotesURL
                )
                
                aboutActionRow(
                    title: platformShellString("Send Feedback"),
                    icon: "envelope.fill",
                    action: {
                        MacFeedbackManager.shared.sendFeedback()
                    }
                )
                
                aboutActionRow(
                    title: platformShellString("Show in Finder"),
                    icon: "folder",
                    action: {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    }
                )
                
                aboutNavigationRow(
                    title: platformShellString("Open Source Licenses"),
                    icon: "doc.text.magnifyingglass"
                ) {
                    showingOpenSourceLicenses = true
                }
            }
            
            Spacer()
        }
        .sheet(isPresented: $showingOpenSourceLicenses) {
            MacOpenSourceLicensesView()
        }
    }

    private func aboutLinkRow(title: String, icon: String, destination: URL) -> some View {
        Button(action: {
            NSWorkspace.shared.open(destination)
        }) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.blue)
                }

                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: "arrow.up.right.square")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func aboutNavigationRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.blue)
                }

                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func aboutActionRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.blue.opacity(0.12))
                        .frame(width: 34, height: 34)
                    Image(systemName: icon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.blue)
                }

                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: "arrow.up.right.square")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color(NSColor.controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct MacOpenSourceLicensesView: View {
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(platformShellString("Open Source Licenses"))
                    .font(.headline)
                Spacer()
                Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title2)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(MacOpenSourceLibrary.catalog) { library in
                        MacOpenSourceLibraryRow(library: library)
                    }
                }
                .padding()
            }
        }
        .frame(width: 500, height: 450)
    }
}

struct MacOpenSourceLibrary: Identifiable {
    let name: String
    let licenseType: String
    let urlString: String
    let description: String

    var id: String { name }

    var url: URL? {
        URL(string: urlString)
    }

    static let catalog: [MacOpenSourceLibrary] = [
        MacOpenSourceLibrary(
            name: "MPVKit / libmpv / FFmpeg",
            licenseType: "LGPL-3.0",
            urlString: "https://github.com/mpvkit/MPVKit/blob/1.0.0/LICENSE",
            description: "MPV.LicenseDescription"
        ),
        MacOpenSourceLibrary(
            name: "VLCKitSPM / MobileVLCKit",
            licenseType: "LGPL-2.1",
            urlString: "https://github.com/fugary/vlckit-spm/blob/main/LICENSE",
            description: "Swift Package wrapper for the MobileVLCKit / VLC playback stack used for audio and video playback."
        ),
        MacOpenSourceLibrary(
            name: "AMSMB2 (+ libsmb2)",
            licenseType: "LGPL-2.1",
            urlString: "https://github.com/amosavian/AMSMB2/blob/master/LICENSE",
            description: "SMB2/3 client framework used for SMB server access. The upstream project notes App Store distribution should use dynamic linking."
        ),
        MacOpenSourceLibrary(
            name: "FilesProvider",
            licenseType: "MIT",
            urlString: "https://github.com/amosavian/FileProvider/blob/master/LICENSE",
            description: "Remote file provider library used by the FTP browsing and transfer flow."
        ),
        MacOpenSourceLibrary(
            name: "libssh2",
            licenseType: "BSD 3-Clause",
            urlString: "https://github.com/libssh2/libssh2/blob/master/COPYING",
            description: "SSH2/SFTP client library bound directly by the app for SFTP directory browsing and downloads."
        ),
        MacOpenSourceLibrary(
            name: "NFSKit",
            licenseType: "MIT",
            urlString: "https://github.com/alexiscn/NFSKit/blob/main/LICENSE",
            description: "Swift package used for NFS server browsing and file download support."
        ),
        MacOpenSourceLibrary(
            name: "fishhook",
            licenseType: "BSD 3-Clause",
            urlString: "https://github.com/facebook/fishhook/blob/main/LICENSE",
            description: "A library that enables dynamically rebinding symbols in Mach-O binaries running on iOS."
        ),
        MacOpenSourceLibrary(
            name: "Source Han Sans SC",
            licenseType: "OFL-1.1",
            urlString: "https://github.com/adobe-fonts/source-han-sans/blob/master/LICENSE.txt",
            description: "Bundled Chinese font used as the fallback subtitle/UI font replacement for specific system font cases."
        )
    ]
}

struct MacOpenSourceLibraryRow: View {
    let library: MacOpenSourceLibrary
    @State private var isHovered = false

    var body: some View {
        Button(action: {
            if let url = library.url {
                NSWorkspace.shared.open(url)
            }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(library.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    Spacer()
                    Text(library.licenseType)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(4)
                        .foregroundColor(.primary)
                }
                
                Text(platformShellString(library.description))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isHovered ? Color(NSColor.controlBackgroundColor) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isHovered ? Color.secondary.opacity(0.2) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}


private struct IdentifiedURL: Identifiable {
    let id = UUID()
    let url: URL
}

private struct IdentifiedVideoFile: Identifiable {
    let id = UUID()
    let file: VideoFile
}

private struct MacFormField<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
            content
        }
    }

}

func macAuthenticateMediaLibraryServer(
    server: ServerConfig,
    username: String,
    password: String
) async throws -> ServerConfig {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let rawURL = URL(string: "\(baseURL)/Users/AuthenticateByName") else {
        throw URLError(.badURL)
    }

    let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(
        "MediaBrowser Client=\"GenPlayer-macOS\", Device=\"Mac\", DeviceId=\"GenPlayerMac\", Version=\"1.0\"",
        forHTTPHeaderField: "Authorization"
    )
    request.setValue(
        "MediaBrowser Client=\"GenPlayer-macOS\", Device=\"Mac\", DeviceId=\"GenPlayerMac\", Version=\"1.0\"",
        forHTTPHeaderField: "X-Emby-Authorization"
    )

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
        let format = platformShellString("Server error: %d")
        let desc = format.contains("%d") ? String(format: format, http.statusCode) : "\(platformShellString("Platform Shell TV Library Server Error")): \(http.statusCode)"
        throw NSError(domain: "GenPlayerShell", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: desc])
    }

    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let accessToken = json["AccessToken"] as? String else {
        throw NSError(domain: "GenPlayerShell", code: -1, userInfo: [NSLocalizedDescriptionKey: platformShellString("Failed to parse server response")])
    }

    let userId = (json["User"] as? [String: Any])?["Id"] as? String

    var verifiedServer = server
    verifiedServer.accessToken = accessToken
    verifiedServer.userId = userId ?? server.userId

    return verifiedServer
}

func macPreparedMediaLibraryServer(
    server: ServerConfig,
    forceCredentialRefresh: Bool = false
) async throws -> ServerConfig {
    guard server.type == .jellyfin || server.type == .emby else {
        return server
    }

    let hydrated = AppNetworkService.shared.hydratedServer(from: server)

    if !forceCredentialRefresh, let token = hydrated.accessToken, !token.isEmpty {
        if let userId = hydrated.userId, !userId.isEmpty {
            var verifiedServer = hydrated
            verifiedServer.accessToken = token
            verifiedServer.userId = userId
            return verifiedServer
        }

        if let resolvedUserId = try await resolvedMediaLibraryUserId(server: hydrated), !resolvedUserId.isEmpty {
            var verifiedServer = hydrated
            verifiedServer.accessToken = token
            verifiedServer.userId = resolvedUserId
            await MainActor.run {
                if AppNetworkService.shared.servers.contains(where: { $0.id == verifiedServer.id }) {
                    AppNetworkService.shared.updateServer(verifiedServer)
                }
            }
            return verifiedServer
        }

        if hydrated.username == nil || hydrated.username?.isEmpty == true ||
            hydrated.passwordSecret == nil || hydrated.passwordSecret?.isEmpty == true {
            return hydrated
        }
    }

    guard let username = hydrated.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty,
          let password = hydrated.passwordSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty else {
        return hydrated
    }

    let verifiedServer = try await macAuthenticateMediaLibraryServer(
        server: hydrated,
        username: username,
        password: password
    )

    if verifiedServer.accessToken != hydrated.accessToken ||
        verifiedServer.userId != hydrated.userId ||
        verifiedServer.port != hydrated.port ||
        verifiedServer.useSSL != hydrated.useSSL {
        await MainActor.run {
            if AppNetworkService.shared.servers.contains(where: { $0.id == verifiedServer.id }) {
                AppNetworkService.shared.updateServer(verifiedServer)
            }
        }
    }

    return verifiedServer
}

func macTestServerConnection(_ server: ServerConfig) async throws -> ServerConfig {
    if server.type != .jellyfin && server.type != .emby {
        return try await AppNetworkService.shared.testConnection(server)
    }

    let hydrated = AppNetworkService.shared.hydratedServer(from: server)

    guard let username = hydrated.username?.trimmingCharacters(in: .whitespacesAndNewlines), !username.isEmpty,
          let password = hydrated.passwordSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !password.isEmpty else {
        throw NSError(
            domain: "GenPlayerShell",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Please provide username and password")]
        )
    }

    return try await macAuthenticateMediaLibraryServer(
        server: hydrated,
        username: username,
        password: password
    )
}

private func fetchJellyfinResumeNodes(server: ServerConfig) async throws -> [MacMediaLibraryNode] {
    guard let userId = try await resolvedMediaLibraryUserId(server: server), !userId.isEmpty else { return [] }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items/Resume")
    components?.queryItems = [
        URLQueryItem(name: "UserId", value: userId),
        URLQueryItem(name: "Limit", value: "12"),
        URLQueryItem(name: "Fields", value: macJellyfinItemFields),
        URLQueryItem(name: "MediaTypes", value: "Video")
    ]
    guard let rawURL = components?.url else { return [] }
    let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
    var request = URLRequest(url: url)
    applyMediaLibraryHeaders(to: &request, server: server)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard (200...299).contains(http.statusCode) else {
        let errorMsg = platformShellString("Platform Shell TV Library Server Error")
        let desc = errorMsg == "Platform Shell TV Library Server Error" ? "Server Error: \(http.statusCode)" : errorMsg.replacingOccurrences(of: "%d", with: "\(http.statusCode)")
        throw NSError(domain: "GenPlayerShell", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: desc])
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = json["Items"] as? [[String: Any]] else { return [] }
    return parseJellyfinItems(items, baseURL: baseURL, server: server)
}

private func fetchJellyfinFavoriteNodes(
    server: ServerConfig,
    limit: Int = 24
) async throws -> [MacMediaLibraryNode] {
    guard let userId = try await resolvedMediaLibraryUserId(server: server), !userId.isEmpty else { return [] }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items") else { return [] }
    
    components.queryItems = [
        URLQueryItem(name: "Recursive", value: "true"),
        URLQueryItem(name: "Filters", value: "IsFavorite"),
        URLQueryItem(name: "Fields", value: macJellyfinItemFields),
        URLQueryItem(name: "Limit", value: "\(limit)")
    ]
    guard let rawURL = components.url else { return [] }
    let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
    
    var request = URLRequest(url: url)
    applyMediaLibraryHeaders(to: &request, server: server)
    
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = json["Items"] as? [[String: Any]] else { return [] }
    
    return parseJellyfinItems(items, baseURL: baseURL, server: server)
}

private func fetchJellyfinLatestNodes(
    server: ServerConfig,
    parentIDs: [String]? = nil,
    limit: Int = 16
) async throws -> [MacMediaLibraryNode] {
    guard let userId = try await resolvedMediaLibraryUserId(server: server), !userId.isEmpty else { return [] }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

    let resolvedParentIDs: [String]
    if let parentIDs {
        resolvedParentIDs = parentIDs
    } else {
        var viewsComponents = URLComponents(string: "\(baseURL)/Users/\(userId)/Views")
        guard let rawViewsUrl = viewsComponents?.url else { return [] }
        let viewsUrl = RuntimeNetworkAddressResolver.runtimeURL(from: rawViewsUrl)
        var viewsReq = URLRequest(url: viewsUrl)
        applyMediaLibraryHeaders(to: &viewsReq, server: server)
        let (vData, _) = try await URLSession.shared.data(for: viewsReq)
        guard let vJson = try? JSONSerialization.jsonObject(with: vData) as? [String: Any],
              let vItems = vJson["Items"] as? [[String: Any]] else { return [] }
        resolvedParentIDs = vItems.compactMap { $0["Id"] as? String }
    }

    let parentIds = resolvedParentIDs.joined(separator: ",")
    guard !parentIds.isEmpty else { return [] }

    var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items/Latest")
    components?.queryItems = [
        URLQueryItem(name: "UserId", value: userId),
        URLQueryItem(name: "Limit", value: "\(limit)"),
        URLQueryItem(name: "Fields", value: macJellyfinItemFields),
        URLQueryItem(name: "ParentId", value: parentIds),
        URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode,Video")
    ]
    guard let rawURL = components?.url else { return [] }
    let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
    var request = URLRequest(url: url)
    applyMediaLibraryHeaders(to: &request, server: server)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard (200...299).contains(http.statusCode) else {
        let errorMsg = platformShellString("Platform Shell TV Library Server Error")
        let desc = errorMsg == "Platform Shell TV Library Server Error" ? "Server Error: \(http.statusCode)" : errorMsg.replacingOccurrences(of: "%d", with: "\(http.statusCode)")
        throw NSError(domain: "GenPlayerShell", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: desc])
    }

    let parsed: [[String: Any]]
    if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        parsed = json
    } else if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let items = json["Items"] as? [[String: Any]] {
        parsed = items
    } else {
        return []
    }
    return parseJellyfinItems(parsed, baseURL: baseURL, server: server)
}

private func fetchJellyfinSearchNodes(server: ServerConfig, query: String, parentId: String? = nil) async throws -> [MacMediaLibraryNode] {
    guard let userId = try await resolvedMediaLibraryUserId(server: server), !userId.isEmpty else { return [] }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    var components = URLComponents(string: "\(baseURL)/Users/\(userId)/Items")
    components?.queryItems = [
        URLQueryItem(name: "SearchTerm", value: query),
        URLQueryItem(name: "Limit", value: "50"),
        URLQueryItem(name: "Recursive", value: "true"),
        URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode,Series,Video,Folder"),
        URLQueryItem(name: "Fields", value: macJellyfinItemFields)
    ]
    if let parentId = parentId, !parentId.isEmpty {
        components?.queryItems?.append(URLQueryItem(name: "ParentId", value: parentId))
    }
    guard let rawURL = components?.url else { return [] }
    let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
    var request = URLRequest(url: url)
    applyMediaLibraryHeaders(to: &request, server: server)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
    guard (200...299).contains(http.statusCode) else {
        let errorMsg = platformShellString("Platform Shell TV Library Server Error")
        let desc = errorMsg == "Platform Shell TV Library Server Error" ? "Server Error: \(http.statusCode)" : errorMsg.replacingOccurrences(of: "%d", with: "\(http.statusCode)")
        throw NSError(domain: "GenPlayerShell", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: desc])
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = json["Items"] as? [[String: Any]] else { return [] }
    return parseJellyfinItems(items, baseURL: baseURL, server: server)
}

private func macJellyfinCarouselArtworkFallbacks(
    _ item: [String: Any], baseURL: String, tokenQuery: String
) -> (poster: URL?, backdrop: URL?) {
    func image(_ id: String?, _ type: String) -> URL? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return URL(string: "\(baseURL)/Items/\(id)/Images/\(type)?maxWidth=1920&quality=90\(tokenQuery)")
    }
    let itemType = (item["Type"] as? String)?.lowercased()
    let series = (itemType == "episode" || itemType == "season")
        ? image(item["SeriesId"] as? String, "Primary") : nil
    let parentThumb = item["ParentThumbImageTag"] != nil
        ? image(item["ParentThumbItemId"] as? String, "Thumb") : nil
    let ownThumb = (item["ImageTags"] as? [String: Any])?["Thumb"] != nil
        ? image(item["Id"] as? String, "Thumb") : nil
    return (poster: series ?? parentThumb ?? ownThumb,
            backdrop: parentThumb ?? ownThumb ?? series)
}

func parseJellyfinItems(_ items: [[String: Any]], baseURL: String, server: ServerConfig? = nil, token: String? = nil,
                       usesCarouselArtworkFallbacks: Bool = false) -> [MacMediaLibraryNode] {
    let resolvedToken: String? = {
        if let token, !token.isEmpty { return token }
        if let serverToken = server?.accessToken, !serverToken.isEmpty { return serverToken }
        let cleanBase = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return AppNetworkService.shared.savedServers.first(where: {
            $0.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == cleanBase
        })?.accessToken
    }()
    let tokenQuery = (resolvedToken?.isEmpty == false) ? "&api_key=\(resolvedToken!)" : ""

    return items.compactMap { item in
        guard let id = item["Id"] as? String,
              let name = item["Name"] as? String else { return nil }
        let rawItemType = item["Type"] as? String
        let mediaType = (item["MediaType"] as? String) ?? rawItemType ?? ""
        let itemType = (rawItemType ?? mediaType).lowercased()
        let isFolder = (item["IsFolder"] as? Bool) ?? jellyfinLikeFolderTypes.contains(itemType) || jellyfinLikeFolderTypes.contains(mediaType.lowercased())
        let collectionType = (item["CollectionType"] as? String) ?? rawItemType
        let userData = item["UserData"] as? [String: Any]
        
        let imageTags = item["ImageTags"] as? [String: Any]
        let backdropImageTags = item["BackdropImageTags"] as? [String]
        let parentBackdropItemId = item["ParentBackdropItemId"] as? String
        let parentBackdropImageTags = item["ParentBackdropImageTags"] as? [String]
        let parentLogoItemId = item["ParentLogoItemId"] as? String
        let seriesId = item["SeriesId"] as? String
        
        let hasPrimary = item["PrimaryImageTag"] != nil || imageTags?["Primary"] != nil
        let hasThumb = imageTags?["Thumb"] != nil
        let hasBackdrop = backdropImageTags?.isEmpty == false
        let hasLogo = imageTags?["Logo"] != nil || (item["HasLogo"] as? Bool == true) || item["LogoImageTag"] != nil
        let hasArt = imageTags?["Art"] != nil || (item["HasArt"] as? Bool == true) || item["ArtImageTag"] != nil
        
        var logoCandidates: [URL] = []
        if hasLogo {
            if let u = URL(string: "\(baseURL)/Items/\(id)/Images/Logo?format=png&maxWidth=600&quality=90\(tokenQuery)") { logoCandidates.append(u) }
        }
        if hasArt {
            if let u = URL(string: "\(baseURL)/Items/\(id)/Images/Art?format=png&maxWidth=600&quality=90\(tokenQuery)") { logoCandidates.append(u) }
        }
        if let parentLogoId = parentLogoItemId, !parentLogoId.isEmpty {
            if let u = URL(string: "\(baseURL)/Items/\(parentLogoId)/Images/Logo?format=png&maxWidth=600&quality=90\(tokenQuery)"), !logoCandidates.contains(u) { logoCandidates.append(u) }
            if let u = URL(string: "\(baseURL)/Items/\(parentLogoId)/Images/Art?format=png&maxWidth=600&quality=90\(tokenQuery)"), !logoCandidates.contains(u) { logoCandidates.append(u) }
        }
        if let seriesId = seriesId, !seriesId.isEmpty {
            if let u = URL(string: "\(baseURL)/Items/\(seriesId)/Images/Logo?format=png&maxWidth=600&quality=90\(tokenQuery)"), !logoCandidates.contains(u) { logoCandidates.append(u) }
            if let u = URL(string: "\(baseURL)/Items/\(seriesId)/Images/Art?format=png&maxWidth=600&quality=90\(tokenQuery)"), !logoCandidates.contains(u) { logoCandidates.append(u) }
        }
        if itemType == "movie" || itemType == "series" || itemType == "episode" || itemType == "video" {
            if let u = URL(string: "\(baseURL)/Items/\(id)/Images/Logo?format=png&maxWidth=600&quality=90\(tokenQuery)"), !logoCandidates.contains(u) { logoCandidates.append(u) }
            if let u = URL(string: "\(baseURL)/Items/\(id)/Images/Art?format=png&maxWidth=600&quality=90\(tokenQuery)"), !logoCandidates.contains(u) { logoCandidates.append(u) }
        }
        
        let posterURL: URL? = hasPrimary 
            ? URL(string: "\(baseURL)/Items/\(id)/Images/Primary?maxHeight=520&maxWidth=360&quality=90\(tokenQuery)") 
            : nil

        let backdropURL: URL?
        if hasBackdrop {
            backdropURL = URL(string: "\(baseURL)/Items/\(id)/Images/Backdrop?maxWidth=1920&quality=90\(tokenQuery)")
        } else if let parentId = parentBackdropItemId, parentBackdropImageTags?.isEmpty == false {
            backdropURL = URL(string: "\(baseURL)/Items/\(parentId)/Images/Backdrop?maxWidth=1920&quality=90\(tokenQuery)")
        } else if mediaType.lowercased() == "episode" && hasThumb {
            backdropURL = URL(string: "\(baseURL)/Items/\(id)/Images/Thumb?maxWidth=1920&quality=90\(tokenQuery)")
        } else if hasPrimary {
            backdropURL = URL(string: "\(baseURL)/Items/\(id)/Images/Primary?maxWidth=1920&quality=90\(tokenQuery)")
        } else {
            backdropURL = nil
        }
        
        let artworkFallbacks = usesCarouselArtworkFallbacks
            ? macJellyfinCarouselArtworkFallbacks(item, baseURL: baseURL, tokenQuery: tokenQuery) : nil
        let deviceIdQuery = (server?.type == .emby) ? "&DeviceId=GenPlayerMac" : ""
        let playbackURL = isFolder ? nil : URL(string: "\(baseURL)/Videos/\(id)/stream?Static=true\(deviceIdQuery)\(tokenQuery)")
        let metadata = macJellyfinMetadataLines(from: item, fallbackType: collectionType)
        return MacMediaLibraryNode(
            id: id,
            name: name,
            type: fileType(from: mediaType),
            isFolder: isFolder,
            remotePath: item["Path"] as? String,
            posterURL: posterURL ?? artworkFallbacks?.poster,
            backdropURL: backdropURL ?? artworkFallbacks?.backdrop,
            playbackURL: playbackURL,
            logoURLs: logoCandidates,
            collectionType: collectionType,
            summary: item["Overview"] as? String,
            metadataLine: metadata.metadata,
            technicalMetadataLine: metadata.technical,
            isLibraryRoot: false,
            playbackPositionTicks: userData?["PlaybackPositionTicks"] as? Int64,
            runTimeTicks: item["RunTimeTicks"] as? Int64,
            lastPlayedDate: MediaHomeCarouselSelection.date(userData?["LastPlayedDate"] as? String),
            seriesId: item["SeriesId"] as? String,
            seriesName: item["SeriesName"] as? String,
            seasonId: item["SeasonId"] as? String,
            isFavorite: userData?["IsFavorite"] as? Bool ?? false,
            isPlayed: userData?["Played"] as? Bool ?? false,
            indexNumber: item["IndexNumber"] as? Int,
            parentIndexNumber: item["ParentIndexNumber"] as? Int,
            communityRating: macDoubleValue(item["CommunityRating"]),
            itemCount: (item["RecursiveItemCount"] as? Int) ?? (item["ChildCount"] as? Int)
        )
    }
}

private func fetchMacMediaPeople(server: ServerConfig, nodeId: String) async throws -> [MacMediaPerson] {
    if server.type == .plex {
        let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanKey = nodeId.hasPrefix("/library/metadata/") ? String(nodeId.dropFirst("/library/metadata/".count)) : nodeId
        guard let url = URL(string: "\(baseURL)/library/metadata/\(cleanKey)") else { return [] }
        var request = URLRequest(url: url)
        applyMediaLibraryHeaders(to: &request, server: server)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = json["MediaContainer"] as? [String: Any] else { return [] }
        let items = ((container["Metadata"] as? [[String: Any]]) ?? (container["Directory"] as? [[String: Any]])) ?? []
        guard let item = items.first else { return [] }

        var merged: [MacMediaPerson] = []
        var seenNames = Set<String>()

        let roleEntries = (item["Role"] as? [[String: Any]]) ?? []
        for r in roleEntries {
            guard let name = r["tag"] as? String, !name.isEmpty else { continue }
            if seenNames.insert(name).inserted {
                let role = r["role"] as? String
                let thumb = r["thumb"] as? String
                let imageURL = thumb.flatMap { plexImageURL(baseURL: baseURL, key: $0, token: server.accessToken) }
                merged.append(MacMediaPerson(id: (r["id"] as? String) ?? name, name: name, role: role, primaryImageURL: imageURL))
            }
        }

        let directorEntries = (item["Director"] as? [[String: Any]]) ?? []
        for d in directorEntries {
            guard let name = d["tag"] as? String, !name.isEmpty else { continue }
            if seenNames.insert(name).inserted {
                let thumb = d["thumb"] as? String
                let imageURL = thumb.flatMap { plexImageURL(baseURL: baseURL, key: $0, token: server.accessToken) }
                merged.append(MacMediaPerson(id: (d["id"] as? String) ?? name, name: name, role: "Director", primaryImageURL: imageURL))
            }
        }

        return merged
    }
    guard server.type == .jellyfin || server.type == .emby else { return [] }
    guard let userId = try await resolvedMediaLibraryUserId(server: server), !userId.isEmpty else { return [] }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let urlString = "\(baseURL)/Users/\(userId)/Items/\(nodeId)?Fields=People"
    guard let url = URL(string: urlString) else { return [] }
    
    var request = URLRequest(url: url)
    applyMediaLibraryHeaders(to: &request, server: server)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return [] }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let people = json["People"] as? [[String: Any]] else { return [] }
    
    return people.compactMap { p in
        guard let name = p["Name"] as? String else { return nil }
        let id = (p["Id"] as? String) ?? name
        let role = (p["Role"] as? String) ?? (p["Type"] as? String)
        let hasImage = (p["PrimaryImageTag"] as? String) != nil
        let imageURL = hasImage ? URL(string: "\(baseURL)/Items/\(id)/Images/Primary?maxHeight=300&maxWidth=200&quality=90") : nil
        return MacMediaPerson(id: id, name: name, role: role, primaryImageURL: imageURL)
    }
}

private func fetchMacMediaSimilar(server: ServerConfig, nodeId: String) async throws -> [MacMediaLibraryNode] {
    if server.type == .plex {
        let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanKey = nodeId.hasPrefix("/library/metadata/") ? String(nodeId.dropFirst("/library/metadata/".count)) : nodeId
        guard let url = URL(string: "\(baseURL)/hubs/metadata/\(cleanKey)/related?X-Plex-Container-Start=0&X-Plex-Container-Size=12") else { return [] }
        var request = URLRequest(url: url)
        applyMediaLibraryHeaders(to: &request, server: server)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = json["MediaContainer"] as? [String: Any] else { return [] }
        let direct = (container["Metadata"] as? [[String: Any]]) ?? []
        var items: [[String: Any]] = direct
        if items.isEmpty, let hubs = container["Hub"] as? [[String: Any]] {
            for hub in hubs {
                if let hubItems = hub["Metadata"] as? [[String: Any]] {
                    items.append(contentsOf: hubItems)
                }
            }
        }
        return items.filter {
            let key = ($0["ratingKey"] as? String) ?? ($0["key"] as? String) ?? ""
            return key != cleanKey
        }.prefix(12).compactMap { item in
            parsePlexItemToNode(item, baseURL: baseURL, server: server)
        }
    }
    guard server.type == .jellyfin || server.type == .emby else { return [] }
    guard let userId = try await resolvedMediaLibraryUserId(server: server), !userId.isEmpty else { return [] }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let urlString = "\(baseURL)/Items/\(nodeId)/Similar?UserId=\(userId)&Limit=12&Fields=\(macJellyfinItemFields)"
    guard let url = URL(string: urlString) else { return [] }
    
    var request = URLRequest(url: url)
    applyMediaLibraryHeaders(to: &request, server: server)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return [] }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let items = json["Items"] as? [[String: Any]] else { return [] }
    return parseJellyfinItems(items, baseURL: baseURL, server: server)
}

func fetchMacMediaItem(server: ServerConfig, nodeId: String) async throws -> MacMediaLibraryNode? {
    if server.type == .plex {
        let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanKey = nodeId.hasPrefix("/library/metadata/") ? String(nodeId.dropFirst("/library/metadata/".count)) : nodeId
        guard let url = URL(string: "\(baseURL)/library/metadata/\(cleanKey)") else { return nil }
        var request = URLRequest(url: url)
        applyMediaLibraryHeaders(to: &request, server: server)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 404 { throw URLError(.fileDoesNotExist) }
        guard (200...299).contains(http.statusCode) else { return nil }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = json["MediaContainer"] as? [String: Any] else { return nil }
        let directories = (container["Directory"] as? [[String: Any]]) ?? []
        let videos = (container["Metadata"] as? [[String: Any]]) ?? []
        guard let item = (directories + videos).first else { return nil }
        let key = (item["key"] as? String) ?? (item["ratingKey"] as? String) ?? cleanKey
        let name = (item["title"] as? String) ?? (item["grandparentTitle"] as? String) ?? key
        let type = (item["type"] as? String) ?? ""
        let isFolder = plexFolderTypes.contains(type.lowercased())

        let media = (item["Media"] as? [[String: Any]])?.first
        let part = (media?["Part"] as? [[String: Any]])?.first
        let fileKey = part?["key"] as? String

        let remotePath: String
        if isFolder {
            if key.hasPrefix("/") {
                remotePath = key.hasSuffix("/children") ? key : "\(key)/children"
            } else {
                remotePath = "/library/metadata/\(key)/children"
            }
        } else {
            remotePath = (part?["file"] as? String) ?? (key.hasPrefix("/") ? key : "/library/metadata/\(key)")
        }

        let posterKey = (item["thumb"] as? String) ?? (item["art"] as? String)
        let backdropKey = (item["art"] as? String) ?? (item["thumb"] as? String)
        let posterURL = posterKey.flatMap { plexImageURL(baseURL: baseURL, key: $0, token: server.accessToken) }
        let backdropURL = backdropKey.flatMap { plexImageURL(baseURL: baseURL, key: $0, token: server.accessToken) }

        let playbackURL = fileKey.flatMap { key -> URL? in
            guard var components = URLComponents(string: baseURL + key) else { return nil }
            if let token = server.accessToken, !token.isEmpty {
                var queryItems = components.queryItems ?? []
                if !queryItems.contains(where: { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame }) {
                    queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
                }
                components.queryItems = queryItems
            }
            return components.url
        }

        let metadata = macPlexMetadataLines(from: item, fallbackType: type)

        return MacMediaLibraryNode(
            id: key,
            name: name,
            type: fileType(from: type),
            isFolder: isFolder,
            remotePath: remotePath,
            posterURL: posterURL,
            backdropURL: backdropURL,
            playbackURL: playbackURL,
            collectionType: type,
            summary: item["summary"] as? String,
            metadataLine: metadata.metadata,
            technicalMetadataLine: metadata.technical,
            seriesId: item["grandparentRatingKey"] as? String ?? item["grandparentKey"] as? String,
            seriesName: item["grandparentTitle"] as? String,
            seasonId: item["parentRatingKey"] as? String ?? item["parentKey"] as? String,
            isFavorite: false,
            isPlayed: (item["viewCount"] as? Int ?? 0) > 0,
            indexNumber: item["index"] as? Int,
            parentIndexNumber: item["parentIndex"] as? Int,
            communityRating: macDoubleValue(item["rating"]),
            itemCount: (item["count"] as? Int) ?? (item["leafCount"] as? Int)
        )
    }
    guard server.type == .jellyfin || server.type == .emby else { return nil }
    guard let userId = try await resolvedMediaLibraryUserId(server: server), !userId.isEmpty else { return nil }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let urlString = "\(baseURL)/Users/\(userId)/Items/\(nodeId)?Fields=\(macJellyfinItemFields)"
    guard let url = URL(string: urlString) else { return nil }
    
    var request = URLRequest(url: url)
    applyMediaLibraryHeaders(to: &request, server: server)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse else { return nil }
    if http.statusCode == 404 { throw URLError(.fileDoesNotExist) }
    guard (200...299).contains(http.statusCode) else { return nil }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return parseJellyfinItems([json], baseURL: baseURL, server: server).first
}

private typealias MacResolvedNavigationTarget = (node: MacMediaLibraryNode, seasonId: String?, episodeId: String?)

private func resolveMacMediaTarget(server: ServerConfig, targetFile: VideoFile) async throws -> MacResolvedNavigationTarget? {
    let activeServer = AppNetworkService.shared.hydratedServer(from: server)
    
    // If targetFile already has seriesId, try to fetch the Series node directly
    if let seriesId = targetFile.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines), !seriesId.isEmpty {
        let seasonId = targetFile.seasonId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let episodeId = targetFile.jellyfinItemId ?? targetFile.id
        if let seriesNode = try? await fetchMacMediaItem(server: activeServer, nodeId: seriesId) {
            return (seriesNode, seasonId, episodeId)
        }
    }
    
    // Otherwise, fetch metadata for the target itemId
    let targetId = targetFile.jellyfinItemId ?? targetFile.id
    guard let directNode = try await fetchMacMediaItem(server: activeServer, nodeId: targetId) else {
        return nil
    }
    
    let itemType = directNode.collectionType?.lowercased() ?? ""
    if itemType == "episode" || (directNode.type == .video && directNode.seriesId?.isEmpty == false && !directNode.isFolder) {
        if let seriesId = directNode.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines), !seriesId.isEmpty {
            let seasonId = directNode.seasonId ?? targetFile.seasonId
            let episodeId = directNode.id
            if let seriesNode = try? await fetchMacMediaItem(server: activeServer, nodeId: seriesId) {
                return (seriesNode, seasonId, episodeId)
            } else {
                let fallback = MacMediaLibraryNode(
                    id: seriesId,
                    name: directNode.seriesName ?? platformShellString("Series"),
                    type: .video,
                    isFolder: true,
                    remotePath: server.type == .plex ? (seriesId.hasPrefix("/") ? (seriesId.hasSuffix("/children") ? seriesId : "\(seriesId)/children") : "/library/metadata/\(seriesId)/children") : nil,
                    posterURL: nil,
                    backdropURL: nil,
                    playbackURL: nil,
                    collectionType: server.type == .plex ? "show" : "Series"
                )
                return (fallback, seasonId, episodeId)
            }
        }
    } else if itemType == "season" {
        if let seriesId = directNode.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines), !seriesId.isEmpty {
            let seasonId = directNode.id
            let episodeId: String? = nil
            if let seriesNode = try? await fetchMacMediaItem(server: activeServer, nodeId: seriesId) {
                return (seriesNode, seasonId, episodeId)
            } else {
                let fallback = MacMediaLibraryNode(
                    id: seriesId,
                    name: directNode.seriesName ?? platformShellString("Series"),
                    type: .video,
                    isFolder: true,
                    remotePath: server.type == .plex ? (seriesId.hasPrefix("/") ? (seriesId.hasSuffix("/children") ? seriesId : "\(seriesId)/children") : "/library/metadata/\(seriesId)/children") : nil,
                    posterURL: nil,
                    backdropURL: nil,
                    playbackURL: nil,
                    collectionType: server.type == .plex ? "show" : "Series"
                )
                return (fallback, seasonId, episodeId)
            }
        }
    } else if itemType == "series" || itemType == "show" || itemType == "tvshows" || itemType == "tvshow" {
        let seasonId = targetFile.seasonId
        let episodeId = (targetFile.jellyfinItemId != directNode.id) ? targetFile.jellyfinItemId : nil
        return (directNode, seasonId, episodeId)
    }
    
    return (directNode, nil, nil)
}

private struct MacSecuritySettingsView: View {
    @ObservedObject private var securityService = SecurityService.shared
    
    @State private var isShowingPinSetup = false
    @State private var pinSetupMode: MacPinSetupMode = .create
    @State private var isPrivacySpaceSetup = false
    @State private var isShowingPrivacyUnlock = false
    @State private var pendingPrivacySpaceDisable = false
    @State private var errorMessage: String?
    
    enum MacPinSetupMode {
        case create, change
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // App Lock
            Text(platformShellString("App Lock"))
                .font(.headline)
                .padding(.bottom, -8)
            
            settingsToggle(title: "Enable App Lock", isOn: Binding(
                get: { securityService.isSecurityEnabled },
                set: { enabled in
                    if enabled {
                        if securityService.hasPin {
                            securityService.toggleSecurity(true)
                        } else {
                            pinSetupMode = .create
                            isPrivacySpaceSetup = false
                            isShowingPinSetup = true
                        }
                    } else {
                        securityService.toggleSecurity(false)
                    }
                }
            ))
            
            if securityService.isSecurityEnabled {
                settingsToggle(title: securityService.biometricsSettingTitle, isOn: Binding(
                    get: { securityService.useBiometrics },
                    set: { enabled in
                        if enabled {
                            if !securityService.toggleBiometrics(true) {
                                errorMessage = securityService.biometricsUnavailableMessage()
                            }
                        } else {
                            _ = securityService.toggleBiometrics(false)
                        }
                    }
                ))
                
                Button(platformShellString("Change PIN")) {
                    pinSetupMode = .change
                    isPrivacySpaceSetup = false
                    isShowingPinSetup = true
                }
                .padding(.top, 4)
            }
            
            Divider().padding(.vertical, 8)
            
            // Privacy Space
            Text(platformShellString("Privacy Space"))
                .font(.headline)
            
            Text(platformShellString("Privacy Space protects access inside Gen Player. It does not replace your device passcode or system-level storage encryption."))
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.bottom, 4)
            
            settingsToggle(title: "Enable Privacy Space", isOn: Binding(
                get: { securityService.isPrivacySpaceEnabled },
                set: { enabled in
                    if enabled {
                        if securityService.hasPrivacyPassword {
                            securityService.togglePrivacySpace(true)
                        } else {
                            pinSetupMode = .create
                            isPrivacySpaceSetup = true
                            isShowingPinSetup = true
                        }
                        if !securityService.isPrivacySpaceUnlocked && securityService.hasPrivacyPassword {
                            pendingPrivacySpaceDisable = true
                            isShowingPrivacyUnlock = true
                        } else {
                            securityService.togglePrivacySpace(false)
                        }
                    }
                }
            ))
            
            if securityService.isPrivacySpaceEnabled {
                settingsToggle(title: securityService.biometricsSettingTitle, isOn: Binding(
                    get: { securityService.allowBiometricsForPrivacy },
                    set: { enabled in
                        if enabled {
                            if !securityService.togglePrivacyBiometrics(true) {
                                errorMessage = securityService.biometricsUnavailableMessage()
                            }
                        } else {
                            _ = securityService.togglePrivacyBiometrics(false)
                        }
                    }
                ))
                
                settingsToggle(title: "Hide Locked Items", isOn: Binding(
                    get: { securityService.hideLockedItems },
                    set: { securityService.setHideLockedItems($0) }
                ))
                
                settingsToggle(title: "Exclude Private Content from History", isOn: Binding(
                    get: { securityService.excludePrivacyFromHistory },
                    set: { securityService.setExcludePrivacyFromHistory($0) }
                ))
                
                Button(platformShellString("Change Privacy PIN")) {
                    pinSetupMode = .change
                    isPrivacySpaceSetup = true
                    isShowingPinSetup = true
                }
                .padding(.top, 4)
                
                Button(platformShellString(securityService.isPrivacySpaceUnlocked ? "Lock Privacy Space Now" : "Unlock Privacy Space")) {
                    if securityService.isPrivacySpaceUnlocked {
                        securityService.lockPrivacySpace()
                    } else {
                        isShowingPrivacyUnlock = true
                    }
                }
                .padding(.top, 4)
            }
        }
        .sheet(isPresented: $isShowingPinSetup) {
            MacPinSetupSheet(
                mode: pinSetupMode,
                isPrivacySpace: isPrivacySpaceSetup,
                onSave: { password in
                    if isPrivacySpaceSetup {
                        securityService.setPrivacyPassword(password)
                        securityService.togglePrivacySpace(true)
                    } else {
                        securityService.setPin(password)
                        securityService.toggleSecurity(true)
                    }
                    isShowingPinSetup = false
                },
                onCancel: {
                    isShowingPinSetup = false
                }
            )
        }
        .sheet(isPresented: $isShowingPrivacyUnlock, onDismiss: {
            if securityService.isPrivacySpaceUnlocked {
                if pendingPrivacySpaceDisable {
                    securityService.togglePrivacySpace(false)
                    pendingPrivacySpaceDisable = false
                }
            } else {
                pendingPrivacySpaceDisable = false
            }
        }) {
            MacPrivacySpaceUnlockView(isPresented: $isShowingPrivacyUnlock)
        }
        .alert(isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Alert(title: Text("Error"), message: Text(errorMessage ?? ""))
        }
    }
    
    private func settingsToggle(title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(platformShellString(title))
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .frame(width: 160, alignment: .trailing)
                .labelsHidden()
        }
    }
}

private struct MacPinSetupSheet: View {
    let mode: MacSecuritySettingsView.MacPinSetupMode
    let isPrivacySpace: Bool
    let onSave: (String) -> Void
    let onCancel: () -> Void
    
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMsg = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text(platformShellString(mode == .create ? "Create PIN" : "Change PIN"))
                .font(.headline)
            
            VStack(alignment: .leading, spacing: 12) {
                SecureField(platformShellString("Enter PIN"), text: $password)
                    .textFieldStyle(.roundedBorder)
                
                SecureField(platformShellString("Confirm PIN"), text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
            }
            
            if !errorMsg.isEmpty {
                Text(errorMsg)
                    .foregroundColor(.red)
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            
            HStack {
                Button(platformShellString("Cancel"), action: onCancel)
                Spacer()
                Button(platformShellString("Save")) {
                    if password.isEmpty {
                        errorMsg = "PIN cannot be empty"
                    } else if password != confirmPassword {
                        errorMsg = "PINs do not match"
                    } else {
                        onSave(password)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 320)
    }
}

private struct MacStorageSettingsView: View {
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @AppStorage("enableRemoteFileCache") private var enableRemoteFileCache: Bool = true
    @AppStorage("notifyWhenDownloadsFinish") private var notifyWhenDownloadsFinish: Bool = true
    @AppStorage("pauseDownloadsInLowPowerMode") private var pauseDownloadsInLowPowerMode: Bool = true

    @State private var imageCacheSize: String = "0 B"
    @State private var remoteFileCacheSize: String = "0 B"

    private var downloadedStorageSummary: DownloadCenterService.DownloadedStorageSummary {
        downloadCenter.downloadedStorageSummary()
    }

    private var remoteFileCacheDirectory: URL {
        let paths = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("GenPlayer/RemoteFileCache", isDirectory: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // 1. Device Storage Overview
            if let storageInfo = systemStorageInfo() {
                deviceStorageOverview(storageInfo: storageInfo)
                Divider().padding(.vertical, 6)
            }

            // 2. Downloads Section
            VStack(alignment: .leading, spacing: 12) {
                Text(platformShellString("Downloads"))
                    .font(.headline)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(platformShellString("Downloaded Content"))
                        Text(String(format: platformShellString("%d files"), downloadedStorageSummary.fileCount))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: downloadedStorageSummary.totalBytes, countStyle: .file))
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 12) {
                    Button(action: {
                        NotificationCenter.default.post(name: .macNavigateToDownloads, object: nil)
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.down.circle")
                            Text(platformShellString("Open Download Center"))
                        }
                    }

                    Spacer()

                    Button(action: {
                        promptClearDownloads()
                    }) {
                        Text(platformShellString("Clear Downloaded Content"))
                            .foregroundColor(.red)
                    }
                    .disabled(downloadedStorageSummary.recordCount == 0)
                }
                .padding(.top, 2)

                Text(platformShellString("Downloaded files and their Download Center records are removed together to keep storage state consistent."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider().padding(.vertical, 6)

            // 3. Download Behavior Section
            VStack(alignment: .leading, spacing: 12) {
                Text(platformShellString("Download Behavior"))
                    .font(.headline)

                HStack {
                    Text(platformShellString("Maximum Concurrent Downloads"))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { downloadCenter.maxConcurrentDownloads },
                        set: { downloadCenter.maxConcurrentDownloads = $0 }
                    )) {
                        ForEach(1...5, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .frame(width: 80, alignment: .trailing)
                    .labelsHidden()
                }

                Divider().opacity(0.5)

                HStack {
                    Text(platformShellString("Notify When Downloads Finish"))
                    Spacer()
                    Toggle("", isOn: $notifyWhenDownloadsFinish)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Divider().opacity(0.5)

                HStack {
                    Text(platformShellString("Pause Downloads in Low Power Mode"))
                    Spacer()
                    Toggle("", isOn: $pauseDownloadsInLowPowerMode)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Text(platformShellString("Wi-Fi and Low Power Mode rules pause downloads without deleting progress. Completion alerts are sent only when Gen Player is not active."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Divider().padding(.vertical, 6)

            // 4. Cache Section
            VStack(alignment: .leading, spacing: 12) {
                Text(platformShellString("Cache"))
                    .font(.headline)

                HStack {
                    Text(platformShellString("Cache Remote File Opens"))
                    Spacer()
                    Toggle("", isOn: $enableRemoteFileCache)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Divider().opacity(0.5)

                HStack {
                    Text(platformShellString("Image Cache"))
                    Spacer()
                    HStack(spacing: 12) {
                        Text(imageCacheSize)
                            .foregroundColor(.secondary)
                        Button(platformShellString("Clear")) {
                            promptClearImageCache()
                        }
                    }
                }

                Divider().opacity(0.5)

                HStack {
                    Text(platformShellString("Remote File Cache"))
                    Spacer()
                    HStack(spacing: 12) {
                        Text(remoteFileCacheSize)
                            .foregroundColor(.secondary)
                        Button(platformShellString("Clear")) {
                            promptClearRemoteFileCache()
                        }
                    }
                }

                Text(platformShellString("Image cache stores posters and artwork. Remote file cache stores reusable local copies for remote preview and Open in Another App. Neither affects your downloaded media."))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onAppear {
            refreshStorageUsage()
            downloadCenter.reconcileMissingLocalFiles()
        }
    }

    private func promptClearDownloads() {
        showMacAlertSheet(
            title: platformShellString("Clear Downloaded Content"),
            message: platformShellString("Are you sure you want to delete all downloaded files and records managed by Download Center?"),
            confirmTitle: platformShellString("Clear")
        ) {
            downloadCenter.clearDownloadedContent()
        }
    }

    private func promptClearImageCache() {
        showMacAlertSheet(
            title: platformShellString("Clear Image Cache"),
            message: platformShellString("Are you sure you want to clear the downloaded image cache? This will not affect your downloaded media."),
            confirmTitle: platformShellString("Clear")
        ) {
            MacImageCache.shared.clearCache {
                refreshStorageUsage()
            }
            refreshStorageUsage()
        }
    }

    private func promptClearRemoteFileCache() {
        showMacAlertSheet(
            title: platformShellString("Clear Remote File Cache"),
            message: platformShellString("Are you sure you want to clear the remote file cache? This will not affect your downloaded media."),
            confirmTitle: platformShellString("Clear")
        ) {
            clearRemoteFileCache()
        }
    }

    private func showMacAlertSheet(title: String, message: String, confirmTitle: String, onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        let confirmBtn = alert.addButton(withTitle: confirmTitle)
        confirmBtn.hasDestructiveAction = true
        alert.addButton(withTitle: platformShellString("Cancel"))
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    onConfirm()
                }
            }
        } else {
            if alert.runModal() == .alertFirstButtonReturn {
                onConfirm()
            }
        }
    }

    private func deviceStorageOverview(storageInfo: (free: Int64, total: Int64)) -> some View {
        let used = max(0, storageInfo.total - storageInfo.free)
        let usedRatio = storageInfo.total > 0 ? min(max(Double(used) / Double(storageInfo.total), 0), 1.0) : 0
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let freeStr = formatter.string(fromByteCount: storageInfo.free)
        let totalStr = formatter.string(fromByteCount: storageInfo.total)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "internaldrive.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.blue)

                Text(platformShellString("Device Storage"))
                    .font(.headline)

                Spacer()

                Text(String(format: platformShellString("Free Space: %@ / Total: %@"), freeStr, totalStr))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(height: 8)

                    Capsule()
                        .fill(usedRatio > 0.9 ? Color.red : Color.blue)
                        .frame(width: geo.size.width * CGFloat(usedRatio), height: 8)
                }
            }
            .frame(height: 8)
        }
    }

    private func refreshStorageUsage() {
        MacImageCache.shared.calculateSize { size in
            self.imageCacheSize = size
        }
        calculateRemoteFileCacheSize { size in
            self.remoteFileCacheSize = size
        }
    }

    private func calculateRemoteFileCacheSize(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let dir = self.remoteFileCacheDirectory
            var totalSize: Int64 = 0
            if let enumerator = FileManager.default.enumerator(
                at: dir,
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
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                completion(formatter.string(fromByteCount: totalSize))
            }
        }
    }

    private func clearRemoteFileCache() {
        DispatchQueue.global(qos: .userInitiated).async {
            let dir = self.remoteFileCacheDirectory
            do {
                if FileManager.default.fileExists(atPath: dir.path) {
                    try FileManager.default.removeItem(at: dir)
                }
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("Error clearing remote file cache: \(error)")
            }
            DispatchQueue.main.async {
                self.refreshStorageUsage()
            }
        }
    }

    private func systemStorageInfo() -> (free: Int64, total: Int64)? {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let freeSize = attributes[.systemFreeSize] as? NSNumber,
               let totalSize = attributes[.systemSize] as? NSNumber {
                return (free: freeSize.int64Value, total: totalSize.int64Value)
            }
        } catch {
            print("Error getting system storage info: \(error)")
        }
        return nil
    }
}

extension View {
    @ViewBuilder
    func hideNavBack() -> some View {
        if #available(macOS 13.0, *) {
            self.navigationBarBackButtonHidden(true)
        } else {
            self
        }
    }
}

struct MacRemoteMediaListRow: View {
    let node: MacMediaLibraryNode
    let onOpen: () -> Void
    var server: ServerConfig? = nil
    var onPlay: (() -> Void)? = nil
    var onDownload: (() -> Void)? = nil

    @State private var isThumbnailHovered = false

    var body: some View {
        let effectiveOnPlay = (node.isFolder || onPlay == nil) ? nil : onPlay
        ZStack(alignment: .leading) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    thumbnailContent
                        .frame(width: 72, height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text(node.name)
                            .font(.body)
                            .fontWeight(.medium)
                            .lineLimit(2)
                        if let meta = node.metadataLine {
                            Text(meta)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        if let tech = node.technicalMetadataLine {
                            Text(tech)
                                .font(.caption2)
                                .foregroundColor(.secondary.opacity(0.8))
                                .lineLimit(1)
                        }
                        if let summary = node.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                        if let pos = node.playbackPositionTicks, let total = node.runTimeTicks, total > 0 {
                            let progress = Double(pos) / Double(total)
                            if progress > 0 {
                                ProgressView(value: min(max(progress, 0.0), 1.0))
                                    .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                                    .frame(height: 3)
                                    .padding(.top, 2)
                            }
                        }
                    }
                    
                    Spacer()
                    
                    if let date = node.dateCreated {
                        Text(date, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Image(systemName: "chevron.right")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isThumbnailHovered, let playAction = effectiveOnPlay {
                MacPosterHoverPlayOverlay(
                    isCardHovered: isThumbnailHovered,
                    onPlay: playAction,
                    buttonSize: 32,
                    cornerRadius: 6
                )
                .frame(width: 72, height: 108)
                .padding(.leading, 12)
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isThumbnailHovered = hovering
            }
        }
        .modifier(MacMediaContextMenuModifier(node: node, server: server, onPlay: effectiveOnPlay, onDownload: onDownload))
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        ZStack {
            if let thumb = node.posterURL {
                MacCachedAsyncImage(url: thumb) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        ZStack {
                            Color.secondary.opacity(0.1)
                            Image(systemName: "photo").foregroundColor(.secondary)
                        }
                    }
                }
            } else {
                ZStack {
                    Color.secondary.opacity(0.1)
                    Image(systemName: node.isFolder ? "folder.fill" : "film.fill").foregroundColor(.secondary)
                }
            }
        }
    }
}


private struct MacCardHoverEffectCore: ViewModifier {
    let cornerRadius: CGFloat
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(isHovered ? 0.22 : 0.0), lineWidth: isHovered ? 2 : 0)
            )
            .scaleEffect(isHovered ? 1.04 : 1.0)
            .shadow(color: Color.black.opacity(isHovered ? 0.2 : 0.0), radius: isHovered ? 8 : 0, x: 0, y: 4)
            .onHover { h in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = h
                }
            }
            .macPointerHover()
    }
}

extension View {
    fileprivate func macCardHoverEffectCore(cornerRadius: CGFloat = 12) -> some View {
        self.modifier(MacCardHoverEffectCore(cornerRadius: cornerRadius))
    }
}

// MARK: - Pre-Playback Options Popover

private struct MacPrePlaybackStream: Identifiable, Hashable {
    let id: String
    let title: String
    let type: String
    let index: Int
    let isDefault: Bool
}

private struct MacPrePlaybackOptionsPopover: View {
    let server: ServerConfig
    let node: MacMediaLibraryNode
    @Binding var isPresented: Bool
    let onPlay: () -> Void
    
    @AppStorage("enableSecondarySubtitlesBeta") private var enableSecondarySubtitlesBeta: Bool = false
    
    @State private var isLoading = true
    @State private var audioStreams: [MacPrePlaybackStream] = []
    @State private var subtitleStreams: [MacPrePlaybackStream] = []
    @State private var errorMessage: String?
    
    @State private var selectedAudioQuery: String?
    @State private var selectedSubtitleQuery: String?
    @State private var subtitlesDisabled: Bool = false
    
    @State private var selectedSecondarySubtitleQuery: String?
    @State private var selectedSecondarySubtitleOrdinal: Int?
    
    private var scopeKey: String {
        if let seriesId = node.seriesId, !seriesId.isEmpty {
            return "series.\(seriesId)"
        }
        return "item.\(node.id)"
    }
    
    private var preferencePrefix: String {
        "trackQuery.\(server.type.rawValue).\(server.id.uuidString).\(scopeKey)"
    }
    
    private var secondarySubtitlePreferencePrefix: String {
        "secondarySubtitle.server.\(server.type.rawValue).\(server.id.uuidString).item.\(node.id)"
    }
    
    private func isAudioSelected(_ stream: MacPrePlaybackStream) -> Bool {
        if let selected = selectedAudioQuery {
            return selected == stream.title
        }
        return stream.isDefault
    }
    
    private func isSubtitleSelected(_ stream: MacPrePlaybackStream) -> Bool {
        if subtitlesDisabled {
            return false
        }
        if let selected = selectedSubtitleQuery {
            return selected == stream.title
        }
        return stream.isDefault
    }
    
    private var isOffSubtitleSelected: Bool {
        if subtitlesDisabled {
            return true
        }
        if selectedSubtitleQuery == nil {
            return !subtitleStreams.contains(where: { $0.isDefault })
        }
        return false
    }
    
    private func isSecondarySubtitleSelected(_ stream: MacPrePlaybackStream) -> Bool {
        if let selected = selectedSecondarySubtitleQuery {
            return selected == stream.title
        }
        return false
    }
    
    private var isOffSecondarySubtitleSelected: Bool {
        return selectedSecondarySubtitleQuery == nil
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView().controlSize(.small)
                    Spacer()
                }
                .padding()
            } else if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !audioStreams.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(platformShellString("Audio Tracks")).font(.headline)
                                ForEach(audioStreams) { stream in
                                    Button(action: {
                                        selectAudio(stream.title)
                                    }) {
                                        HStack {
                                            Image(systemName: isAudioSelected(stream) ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(isAudioSelected(stream) ? .accentColor : .secondary)
                                            Text(stream.title)
                                                .font(.system(size: 13))
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        if !subtitleStreams.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(platformShellString("Subtitles")).font(.headline)
                                
                                // Off option
                                Button(action: {
                                    disableSubtitles()
                                }) {
                                    HStack {
                                        Image(systemName: isOffSubtitleSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(isOffSubtitleSelected ? .accentColor : .secondary)
                                        Text(platformShellString("Off"))
                                            .font(.system(size: 13))
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                
                                ForEach(subtitleStreams) { stream in
                                    Button(action: {
                                        selectSubtitle(stream.title)
                                    }) {
                                        HStack {
                                            Image(systemName: isSubtitleSelected(stream) ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(isSubtitleSelected(stream) ? .accentColor : .secondary)
                                            Text(stream.title)
                                                .font(.system(size: 13))
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        
                        if enableSecondarySubtitlesBeta && !subtitleStreams.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(platformShellString("Secondary Subtitle")).font(.headline)
                                
                                // Off option
                                Button(action: {
                                    disableSecondarySubtitles()
                                }) {
                                    HStack {
                                        Image(systemName: isOffSecondarySubtitleSelected ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(isOffSecondarySubtitleSelected ? .accentColor : .secondary)
                                        Text(platformShellString("Off"))
                                            .font(.system(size: 13))
                                        Spacer()
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                
                                ForEach(subtitleStreams) { stream in
                                    Button(action: {
                                        selectSecondarySubtitle(stream)
                                    }) {
                                        HStack {
                                            Image(systemName: isSecondarySubtitleSelected(stream) ? "checkmark.circle.fill" : "circle")
                                                .foregroundColor(isSecondarySubtitleSelected(stream) ? .accentColor : .secondary)
                                            Text(stream.title)
                                                .font(.system(size: 13))
                                            Spacer()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
                
                Divider()
                
                HStack {
                    Spacer()
                    Button(action: {
                        isPresented = false
                        onPlay()
                    }) {
                        HStack {
                            Image(systemName: "play.fill")
                            Text(platformShellString("Play"))
                                .fontWeight(.semibold)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.accentColor)
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .frame(width: 320, height: 300)
        .onAppear {
            loadSavedPreferences()
        }
        .task {
            await loadPlaybackInfo()
        }
    }
    
    private func loadSavedPreferences() {
        let prefix = preferencePrefix
        selectedAudioQuery = UserDefaults.standard.string(forKey: "\(prefix).audioQuery")
        selectedSubtitleQuery = UserDefaults.standard.string(forKey: "\(prefix).subtitleQuery")
        subtitlesDisabled = UserDefaults.standard.bool(forKey: "\(prefix).subtitlesDisabled")
        
        let secPrefix = secondarySubtitlePreferencePrefix
        selectedSecondarySubtitleQuery = UserDefaults.standard.string(forKey: "\(secPrefix).secondarySubtitleQuery")
        if UserDefaults.standard.object(forKey: "\(secPrefix).secondarySubtitleOrdinal") != nil {
            selectedSecondarySubtitleOrdinal = UserDefaults.standard.integer(forKey: "\(secPrefix).secondarySubtitleOrdinal")
        } else {
            selectedSecondarySubtitleOrdinal = nil
        }
    }
    
    private func selectAudio(_ query: String) {
        let prefix = preferencePrefix
        if selectedAudioQuery == query {
            UserDefaults.standard.removeObject(forKey: "\(prefix).audioQuery")
            selectedAudioQuery = nil
        } else {
            UserDefaults.standard.set(query, forKey: "\(prefix).audioQuery")
            selectedAudioQuery = query
        }
    }
    
    private func selectSubtitle(_ query: String) {
        let prefix = preferencePrefix
        UserDefaults.standard.set(query, forKey: "\(prefix).subtitleQuery")
        UserDefaults.standard.set(false, forKey: "\(prefix).subtitlesDisabled")
        selectedSubtitleQuery = query
        subtitlesDisabled = false
    }
    
    private func disableSubtitles() {
        let prefix = preferencePrefix
        UserDefaults.standard.removeObject(forKey: "\(prefix).subtitleQuery")
        UserDefaults.standard.set(true, forKey: "\(prefix).subtitlesDisabled")
        selectedSubtitleQuery = nil
        subtitlesDisabled = true
    }
    
    private func selectSecondarySubtitle(_ stream: MacPrePlaybackStream) {
        let secPrefix = secondarySubtitlePreferencePrefix
        if selectedSecondarySubtitleQuery == stream.title {
            UserDefaults.standard.removeObject(forKey: "\(secPrefix).secondarySubtitleQuery")
            UserDefaults.standard.removeObject(forKey: "\(secPrefix).secondarySubtitleOrdinal")
            selectedSecondarySubtitleQuery = nil
            selectedSecondarySubtitleOrdinal = nil
        } else {
            UserDefaults.standard.set(stream.title, forKey: "\(secPrefix).secondarySubtitleQuery")
            UserDefaults.standard.set(stream.index, forKey: "\(secPrefix).secondarySubtitleOrdinal")
            selectedSecondarySubtitleQuery = stream.title
            selectedSecondarySubtitleOrdinal = stream.index
        }
    }
    
    private func disableSecondarySubtitles() {
        let secPrefix = secondarySubtitlePreferencePrefix
        UserDefaults.standard.removeObject(forKey: "\(secPrefix).secondarySubtitleQuery")
        UserDefaults.standard.removeObject(forKey: "\(secPrefix).secondarySubtitleOrdinal")
        selectedSecondarySubtitleQuery = nil
        selectedSecondarySubtitleOrdinal = nil
    }
    
    private func loadPlaybackInfo() async {
        print("[MacPrePlaybackOptionsPopover] Loading playback options for \(node.name) (id: \(node.id))")
        guard let itemId = node.id.nilIfEmpty else {
            await MainActor.run {
                self.errorMessage = platformShellString("Invalid media item.")
                self.isLoading = false
            }
            return
        }
        
        do {
            let hydrated = AppNetworkService.shared.hydratedServer(from: server)
            guard let userId = try await resolvedMediaLibraryUserId(server: hydrated), !userId.isEmpty else {
                throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "Missing credentials"])
            }
            let baseURL = hydrated.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let urlString = "\(baseURL)/Users/\(userId)/Items/\(itemId)?Fields=\(macJellyfinItemFields)"
            guard let rawURL = URL(string: urlString) else { throw URLError(.badURL) }
            let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
            
            var request = URLRequest(url: url)
            applyMediaLibraryHeaders(to: &request, server: hydrated)
            
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw NSError(domain: "", code: 0, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code): \(body.prefix(100))"])
            }
            
            let item = try JSONDecoder().decode(JellyfinItem.self, from: data)
            let bestSource = item.mediaSources?.first(where: { $0.mediaStreams?.isEmpty == false }) ?? item.mediaSources?.first
            let rawStreams = bestSource?.mediaStreams ?? []
            
            var audios = [MacPrePlaybackStream]()
            var subs = [MacPrePlaybackStream]()
            
            for stream in rawStreams {
                let typeLower = stream.type.lowercased()
                let isAudio = typeLower == "audio"
                let isSubtitle = typeLower == "subtitle"
                if !isAudio && !isSubtitle { continue }
                
                let index = stream.index ?? -1
                let title = stream.displayTitle ?? stream.title ?? stream.language ?? "\(isAudio ? "Audio" : "Subtitle") \(index >= 0 ? String(index) : "")"
                
                let model = MacPrePlaybackStream(
                    id: UUID().uuidString,
                    title: title,
                    type: stream.type,
                    index: index,
                    isDefault: stream.isDefault ?? false
                )
                if isAudio { audios.append(model) }
                else { subs.append(model) }
            }
            
            print("[MacPrePlaybackOptionsPopover] Loaded \(audios.count) audio(s), \(subs.count) subtitle(s) for \(item.name)")
            
            await MainActor.run {
                self.audioStreams = audios
                self.subtitleStreams = subs
                self.isLoading = false
            }
        } catch {
            print("[MacPrePlaybackOptionsPopover] Error loading playback options: \(error.localizedDescription)")
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
}



struct NavigationLazyView<Content: View>: View {
    private let build: () -> Content

    init(@ViewBuilder _ build: @escaping () -> Content) {
        self.build = build
    }

    var body: some View {
        build()
    }
}

extension View {
    func floatingToast(message: Binding<String?>) -> some View {
        self.modifier(MacFloatingToastModifier(message: message))
    }
}

struct MacFloatingToastModifier: ViewModifier {
    @Binding var message: String?
    func body(content: Content) -> some View {
        ZStack {
            content
            if let msg = message {
                VStack {
                    Spacer()
                    Text(msg)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(8)
                        .padding(.bottom, 20)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation { message = nil }
                            }
                        }
                }
                .zIndex(100)
            }
        }
        .animation(.easeInOut, value: message)
    }
}

private func fetchJellyfinLibraryFilterOptions(server: ServerConfig, parentId: String?) async throws -> (genres: [String], years: [String]) {
    let network = AppNetworkService.shared
    guard let userId = try await resolvedMediaLibraryUserId(server: server), !userId.isEmpty else { return ([], []) }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    
    async let genresReq: [String] = {
        var comp = URLComponents(string: "\(baseURL)/Genres")
        var items = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,MusicAlbum,Audio,Episode")
        ]
        if let parentId { items.append(URLQueryItem(name: "ParentId", value: parentId)) }
        comp?.queryItems = items
        
        guard let rawURL = comp?.url else { return [] }
        let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
        var request = URLRequest(url: url)
        applyMediaLibraryHeaders(to: &request, server: server)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resItems = json["Items"] as? [[String: Any]] else { return [] }
        return resItems.compactMap { $0["Name"] as? String }
    }()
    
    async let yearsReq: [String] = {
        var comp = URLComponents(string: "\(baseURL)/Years")
        var items = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,MusicAlbum,Audio,Episode")
        ]
        if let parentId { items.append(URLQueryItem(name: "ParentId", value: parentId)) }
        comp?.queryItems = items
        
        guard let rawURL = comp?.url else { return [] }
        let url = RuntimeNetworkAddressResolver.runtimeURL(from: rawURL)
        var request = URLRequest(url: url)
        applyMediaLibraryHeaders(to: &request, server: server)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resItems = json["Items"] as? [[String: Any]] else { return [] }
        return resItems.compactMap { $0["Name"] as? String }.sorted(by: >)
    }()
    
    let (g, y) = try await (genresReq, yearsReq)
    return (g, y)
}
#endif
