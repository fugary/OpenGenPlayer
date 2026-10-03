import SwiftUI
import GenPlayerCore

public struct IPTVPlaylistView: View {
    public let server: ServerConfig
    public let onExit: (() -> Void)?
    public let targetChannelIdToResolve: String?
    @State private var hasResolvedInitialTarget: Bool = false
    @State private var highlightedChannelId: String? = nil
    
    @ObservedObject private var iptvService = IPTVService.shared
    @ObservedObject private var epgService = EPGService.shared
    @ObservedObject private var playbackService = VLCPlaybackService.shared
    
    @State private var selectedGroup: String = "ALL" // "ALL", "FAVORITES", or specific group name
    @State private var searchText: String = ""
    @State private var isShowingSearch: Bool = false
    @State private var displayedChannels: [IPTVChannel] = []
    @State private var searchResults: [IPTVChannel] = []
    @State private var searchDisplayLimit = 120
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var fullScreenFile: VideoFile?
    @State private var activeChannelPlaylist: [VideoFile]?
    @State private var epgTargetChannel: IPTVChannel?
    @State private var errorMessage: String?
    @State private var isLoading: Bool = false
    @State private var displayLimit: Int = 120
    @AppStorage("iOSIPTVIsGridLayout") private var isGridLayout: Bool = true
    @AppStorage("iptv_sort_field") private var sortFieldRaw: String = IPTVSortField.default.rawValue
    @AppStorage("iptv_sort_order") private var sortOrderRaw: String = IPTVSortOrder.ascending.rawValue
    
    private var sortField: IPTVSortField {
        get { IPTVSortField(rawValue: sortFieldRaw) ?? .default }
        nonmutating set { sortFieldRaw = newValue.rawValue }
    }
    
    private var sortOrder: IPTVSortOrder {
        get { IPTVSortOrder(rawValue: sortOrderRaw) ?? .ascending }
        nonmutating set { sortOrderRaw = newValue.rawValue }
    }

    
    private let pageSize: Int = 120
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    
    private var isCompactPortrait: Bool {
        #if targetEnvironment(macCatalyst)
        return false
        #else
        if UIDevice.current.userInterfaceIdiom == .phone {
            return verticalSizeClass != .compact
        }
        return horizontalSizeClass == .compact
        #endif
    }
    
    private let favoriteGroupKey = "FAVORITES"
    private let allGroupKey = "ALL"
    
    public init(
        server: ServerConfig,
        onExit: (() -> Void)? = nil,
        targetChannelIdToResolve: String? = nil
    ) {
        self.server = server
        self.onExit = onExit
        self.targetChannelIdToResolve = targetChannelIdToResolve
    }
    
    private var playlist: IPTVPlaylist? {
        iptvService.cachedPlaylist(for: server.id)
    }
    
    private var allChannels: [IPTVChannel] {
        playlist?.channels ?? []
    }
    
    private var favoriteChannels: [IPTVChannel] {
        playlist?.favoriteChannels ?? []
    }
    
    private var availableGroups: [String] {
        playlist?.groups ?? []
    }
    
    private var groupCounts: [String: Int] {
        playlist?.groupCounts ?? [:]
    }
    
    private var baseChannelsForSelectedGroup: [IPTVChannel] {
        guard let playlist = playlist else { return [] }
        if selectedGroup == favoriteGroupKey {
            return playlist.favoriteChannels
        } else if selectedGroup == allGroupKey {
            return playlist.channels
        } else {
            return playlist.channelsByGroup[selectedGroup] ?? []
        }
    }
    
    private var visibleChannels: [IPTVChannel] {
        Array(displayedChannels.prefix(displayLimit))
    }
    
    private var gridColumns: [GridItem] {
        #if targetEnvironment(macCatalyst)
        return [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)]
        #else
        if UIDevice.current.userInterfaceIdiom == .pad || horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 14)]
        }
        let minWidth: CGFloat = verticalSizeClass == .compact ? 170 : 155
        return [GridItem(.adaptive(minimum: minWidth, maximum: 220), spacing: 12)]
        #endif
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Bar / Category Selector
            if !allChannels.isEmpty {
                groupSelectorView
                    .padding(.top, 4)
                    .padding(.bottom, 8)
                    .background(Color(UIColor.systemBackground))
            }
            
            // MARK: - Content Area
            ZStack {
                Color(UIColor.systemGroupedBackground).ignoresSafeArea()
                
                if isLoading && allChannels.isEmpty {
                    loadingView
                } else if let error = errorMessage, allChannels.isEmpty {
                    errorView(error)
                } else if allChannels.isEmpty {
                    emptyPlaylistView
                } else if displayedChannels.isEmpty {
                    noResultsView
                } else {
                    channelScrollView
                }
            }
            .modifier(inlineSearch)
        }
        .navigationBarTitle(server.name, displayMode: .inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarLeading) {
                if let onExit = onExit {
                    Button(action: onExit) {
                        AppToolbarIcon.serverExit(legacyStyle: .secondary)
                    }
                }
            }
            
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                searchToolbarControl
                
                Button(action: {
                    withAnimation { isGridLayout.toggle() }
                }) {
                    AppToolbarIcon(systemName: isGridLayout ? "list.bullet" : "square.grid.2x2")
                }
                
                Menu {
                    Section(header: Text(NSLocalizedString("Sort By", comment: ""))) {
                        ForEach(IPTVSortField.allCases) { field in
                            Button(action: {
                                sortField = field
                                if field == .name {
                                    sortOrder = .ascending
                                }
                            }) {
                                sortMenuRow(title: field.title, isSelected: sortField == field)
                            }
                        }
                    }

                    if sortField != .default {
                        Section(header: Text(NSLocalizedString("Order", comment: ""))) {
                            ForEach(IPTVSortOrder.allCases) { order in
                                Button(action: {
                                    sortOrder = order
                                }) {
                                    sortMenuRow(title: order.title, isSelected: sortOrder == order)
                                }
                            }
                        }
                    }

                    Section {
                        Button(action: {
                            Task {
                                try? await epgService.fetchEPG(for: server, forceRefresh: true)
                            }
                        }) {
                            Label(NSLocalizedString("Refresh EPG", comment: ""), systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                } label: {
                    AppToolbarIcon(systemName: "line.3.horizontal.decrease.circle")
                }

                if PlatformHelper.isRunningOnMac {
                    Button(action: {
                        Task { await refreshPlaylist(force: true) }
                    }) {
                        AppToolbarIcon(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        .edgeSwipeToDismiss(action: { onExit?() })
        .fullScreenCover(item: $fullScreenFile, onDismiss: {
            UIApplication.refreshInterfaceChrome()
        }) { file in
            PlayerView(initialFile: file, playlist: activeChannelPlaylist)
        }
        .sheet(item: $epgTargetChannel) { targetChannel in
            IPTVProgramGuideSheet(channel: targetChannel, server: server, onPlay: {
                play(targetChannel)
            })
        }
        .onChange(of: searchText) { _ in
            scheduleSearch()
        }
        .onChange(of: selectedGroup) { _ in
            displayLimit = pageSize
            refreshDisplayedChannels()
        }
        .onChange(of: playlist) { _ in refreshDisplayedChannels() }
        .onChange(of: sortFieldRaw) { _ in refreshDisplayedChannels() }
        .onChange(of: sortOrderRaw) { _ in refreshDisplayedChannels() }
        .onDisappear { searchTask?.cancel() }
        .onAppear {
            refreshDisplayedChannels()
            if allChannels.isEmpty {
                Task {
                    await refreshPlaylist(force: false)
                }
            }
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

    
    private var groupSelectorView: some View {
        HStack(spacing: isCompactPortrait ? 6 : 8) {
            // All Tab (Pinned)
            groupPill(
                title: NSLocalizedString("All", comment: ""),
                count: allChannels.count,
                isSelected: selectedGroup == allGroupKey,
                systemIcon: nil
            ) {
                selectedGroup = allGroupKey
            }
            .padding(.leading, isCompactPortrait ? 12 : 16)
            
            // Favorites Tab (Pinned)
            if !favoriteChannels.isEmpty {
                groupPill(
                    title: isCompactPortrait ? nil : NSLocalizedString("Favorites", comment: ""),
                    count: favoriteChannels.count,
                    isSelected: selectedGroup == favoriteGroupKey,
                    systemIcon: "star.fill",
                    accessibilityTitle: NSLocalizedString("Favorites", comment: "")
                ) {
                    selectedGroup = favoriteGroupKey
                }
            }
            
            if !availableGroups.isEmpty {
                Divider()
                    .frame(height: isCompactPortrait ? 16 : 18)
                    .padding(.horizontal, isCompactPortrait ? 1 : 2)
                
                // Custom Group Tabs (Scrollable)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: isCompactPortrait ? 6 : 8) {
                        ForEach(availableGroups, id: \.self) { group in
                            let count = groupCounts[group] ?? allChannels.filter { $0.matches(group: group) }.count
                            groupPill(
                                title: group,
                                count: count,
                                isSelected: selectedGroup == group,
                                systemIcon: nil
                            ) {
                                selectedGroup = group
                            }
                        }
                    }
                    .padding(.trailing, isCompactPortrait ? 12 : 16)
                }
            } else {
                Spacer()
            }
        }
    }
    
    private func groupPill(
        title: String?,
        count: Int,
        isSelected: Bool,
        systemIcon: String?,
        accessibilityTitle: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        let isIconOnly = (title == nil || title?.isEmpty == true)
        let badgeSize: CGFloat = isCompactPortrait ? 16 : 18
        let isSingleDigit = count < 10 && count >= 0

        return Button(action: action) {
            HStack(spacing: isCompactPortrait ? 4 : 6) {
                if let systemIcon = systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: isCompactPortrait ? 11 : 12, weight: .bold))
                        .foregroundColor(isSelected ? .white : Color(UIColor.systemYellow))
                }
                
                if let title = title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: isCompactPortrait ? 12 : 13, weight: isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? .white : Color(UIColor.label))
                }
                
                if isSingleDigit {
                    Text("\(count)")
                        .font(.system(size: isCompactPortrait ? 10 : 11, weight: .semibold))
                        .frame(width: badgeSize, height: badgeSize)
                        .background(isSelected ? Color.white.opacity(0.25) : Color(UIColor.secondarySystemFill))
                        .clipShape(Circle())
                        .foregroundColor(isSelected ? .white : Color(UIColor.secondaryLabel))
                } else {
                    Text("\(count)")
                        .font(.system(size: isCompactPortrait ? 10 : 11, weight: .semibold))
                        .padding(.horizontal, isCompactPortrait ? 4.5 : 5.5)
                        .frame(minHeight: badgeSize)
                        .background(isSelected ? Color.white.opacity(0.25) : Color(UIColor.secondarySystemFill))
                        .clipShape(Capsule())
                        .foregroundColor(isSelected ? .white : Color(UIColor.secondaryLabel))
                }
            }
            .padding(.horizontal, isCompactPortrait ? (isIconOnly ? 8 : 10) : 12)
            .padding(.vertical, isCompactPortrait ? 5 : 6)
            .background(isSelected ? Color.accentColor : Color(UIColor.secondarySystemGroupedBackground))
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.accentColor : Color(UIColor.separator).opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .accessibilityLabel(
            accessibilityTitle?.isEmpty == false ? "\(accessibilityTitle!), \(count)" : (title?.isEmpty == false ? "\(title!), \(count)" : "\(count)")
        )
    }
    
    // MARK: - Channel Views
    
    private var channelScrollView: some View {
        let currentVisible = visibleChannels
        
        return ScrollViewReader { scrollProxy in
            ScrollView {
                channelCollection(currentVisible, loadMore: loadMoreChannelsIfNeeded)
            }
            .onAppear {
                resolveTargetChannelIfNeeded(scrollProxy: scrollProxy)
            }
            .onChange(of: displayedChannels.count) { _ in
                resolveTargetChannelIfNeeded(scrollProxy: scrollProxy)
            }
        }
        .refreshableCompat {
            await refreshPlaylist(force: true)
        }
    }

    @ViewBuilder
    private func channelCollection(_ channels: [IPTVChannel], loadMore: @escaping () -> Void) -> some View {
        let lastID = channels.last?.id
        if isGridLayout {
            LazyVGrid(columns: gridColumns, spacing: 14) {
                ForEach(channels) { channel in
                    IPTVChannelGridCard(
                        channel: channel,
                        server: server,
                        onPlay: { play(channel) },
                        onToggleFavorite: { toggleFavorite(channel) },
                        onShowEPG: { epgTargetChannel = channel }
                    )
                    .id(channel.id)
                    .onAppear {
                        if channel.id == lastID {
                            loadMore()
                        }
                    }
                }
            }
            .padding(16)
        } else {
            LazyVStack(spacing: 8) {
                ForEach(channels) { channel in
                    IPTVChannelListRow(
                         channel: channel,
                         server: server,
                         onPlay: { play(channel) },
                         onToggleFavorite: { toggleFavorite(channel) },
                         onShowEPG: { epgTargetChannel = channel }
                     )
                     .id(channel.id)
                     .onAppear {
                         if channel.id == lastID {
                             loadMore()
                         }
                     }
                 }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var searchToolbarControl: some View {
        if #unavailable(iOS 26.0) {
            Button { isShowingSearch = true } label: {
                AppToolbarIcon(systemName: "magnifyingglass")
            }
            .accessibilityLabel(NSLocalizedString("Search", comment: ""))
        }
    }

    private func submitInlineSearch(_ query: String) {
        SearchHistoryService.shared.addHistory(query, for: server.id)
        scheduleSearch(immediate: true)
    }

    private var inlineSearch: some ViewModifier {
        LibraryInlineSearchModifier(
            isPresented: $isShowingSearch,
            query: $searchText,
            placeholder: NSLocalizedString("Search Channels", comment: ""),
            serverId: server.id.uuidString,
            onSubmit: submitInlineSearch
        ) {
            if isSearching {
                ProgressView().frame(maxWidth: .infinity).padding(40)
            } else if searchResults.isEmpty {
                noResultsView
            } else {
                channelCollection(Array(searchResults.prefix(searchDisplayLimit))) {
                    searchDisplayLimit = min(searchDisplayLimit + pageSize, searchResults.count)
                }
            }
        }
    }

    private func refreshDisplayedChannels() {
        displayedChannels = baseChannelsForSelectedGroup.sorted(by: sortField, order: sortOrder)
        if isShowingSearch { scheduleSearch(immediate: true) }
    }

    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchDisplayLimit = pageSize
        guard isShowingSearch, !query.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        isSearching = true
        // The sorted browsing snapshot is reused; typing never sorts the playlist again.
        let channels = displayedChannels
        searchTask = Task { @MainActor in
            if !immediate {
                do { try await Task.sleep(nanoseconds: 150_000_000) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            searchResults = channels.filter {
                $0.name.localizedCaseInsensitiveContains(query) ||
                $0.group.localizedCaseInsensitiveContains(query)
            }
            isSearching = false
        }
    }

    private func resolveTargetChannelIfNeeded(scrollProxy: ScrollViewProxy? = nil) {
        guard let targetId = targetChannelIdToResolve, !targetId.isEmpty, !hasResolvedInitialTarget else { return }
        guard let targetChannel = allChannels.first(where: { $0.id == targetId || $0.url.absoluteString == targetId }) else { return }
        
        hasResolvedInitialTarget = true
        highlightedChannelId = targetChannel.id
        
        if selectedGroup != allGroupKey && selectedGroup != targetChannel.group && selectedGroup != favoriteGroupKey {
            selectedGroup = allGroupKey
            refreshDisplayedChannels()
        }
        
        let currentDisplayed = displayedChannels
        if let index = currentDisplayed.firstIndex(where: { $0.id == targetChannel.id }) {
            if index >= displayLimit {
                displayLimit = max(displayLimit, index + pageSize)
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation {
                scrollProxy?.scrollTo(targetChannel.id, anchor: .center)
            }
        }
    }
    
    private func loadMoreChannelsIfNeeded() {
        guard displayLimit < displayedChannels.count else { return }
        displayLimit = min(displayLimit + pageSize, displayedChannels.count)
    }
    
    // MARK: - State Placeholders
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.3)
            Text(NSLocalizedString("Loading playlist...", comment: ""))
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundColor(.orange)
            
            Text(NSLocalizedString("Failed to Load Playlist", comment: ""))
                .font(.headline)
            
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            
            Button(action: {
                Task { await refreshPlaylist(force: true) }
            }) {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text(NSLocalizedString("Retry", comment: ""))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
    
    private var emptyPlaylistView: some View {
        VStack(spacing: 16) {
            Image(systemName: "tv.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text(NSLocalizedString("No Channels Found", comment: ""))
                .font(.headline)
                .foregroundColor(.secondary)
            
            Button(action: {
                Task { await refreshPlaylist(force: true) }
            }) {
                Text(NSLocalizedString("Refresh", comment: ""))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .cornerRadius(8)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
    
    private var noResultsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.5))
            
            Text(NSLocalizedString("No channels matching search", comment: ""))
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
    
    // MARK: - Actions
    
    private func refreshPlaylist(force: Bool) async {
        if allChannels.isEmpty {
            isLoading = true
        }
        errorMessage = nil
        do {
            try await iptvService.fetchPlaylist(for: server, forceRefresh: force)
        } catch {
            if allChannels.isEmpty {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }
    
    private func play(_ channel: IPTVChannel) {
        let currentList = isShowingSearch && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? searchResults : displayedChannels
        let playlistFiles = currentList.map { iptvService.makeVideoFile(for: $0, server: server) }
        let targetFile = iptvService.makeVideoFile(for: channel, server: server)
        
        activeChannelPlaylist = playlistFiles
        fullScreenFile = targetFile
    }
    
    private func toggleFavorite(_ channel: IPTVChannel) {
        iptvService.toggleFavorite(channelId: channel.id, in: server)
    }
}

// MARK: - iOS IPTV Channel Grid Card

private struct IPTVChannelGridCard: View {
    let channel: IPTVChannel
    let server: ServerConfig
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void
    let onShowEPG: () -> Void
    
    @ObservedObject private var epgService = EPGService.shared
    @ObservedObject private var artworkService = IPTVArtworkService.shared
    
    private var currentProgramme: EPGProgramme? {
        epgService.currentProgramme(for: channel, in: server.id)
    }
    
    private var snapshotURL: URL? {
        artworkService.snapshotURL(for: channel.id, in: server.id)
    }
    
    private var effectiveLogoURL: URL? {
        if let logo = channel.logoURL { return logo }
        return epgService.iconURL(for: channel, in: server.id)
    }
    
    var body: some View {
        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    ZStack {
                        if let snapshot = snapshotURL {
                            RemoteImage(
                                url: snapshot,
                                placeholderSystemImage: "play.tv.fill",
                                contentMode: .fill
                            )
                        } else if let logoURL = effectiveLogoURL {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(UIColor.tertiarySystemFill).opacity(0.65))
                                RemoteImage(
                                    url: logoURL,
                                    placeholderSystemImage: "play.tv.fill",
                                    contentMode: .fit
                                )
                                .padding(8)
                            }
                        } else {
                            ZStack {
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.12, green: 0.15, blue: 0.22),
                                        Color(red: 0.08, green: 0.09, blue: 0.14)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                
                                VStack(spacing: 5) {
                                    Image(systemName: "play.tv.fill")
                                        .font(.system(size: 22))
                                        .foregroundColor(.white.opacity(0.7))
                                    
                                    Text(channel.name)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundColor(.white.opacity(0.6))
                                        .lineLimit(1)
                                        .padding(.horizontal, 6)
                                }
                            }
                        }
                    }
                    .aspectRatio(16/9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    
                    Button(action: onToggleFavorite) {
                        Image(systemName: channel.isFavorite ? "star.fill" : "star")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(channel.isFavorite ? Color(UIColor.systemYellow) : .white)
                            .padding(5)
                            .background(Color.black.opacity(0.45))
                            .clipShape(Circle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .padding(5)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(channel.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Color(UIColor.label))
                        .lineLimit(1)
                    
                    if let prog = currentProgramme {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(prog.title)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color.accentColor)
                                .lineLimit(1)
                            
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color(UIColor.tertiarySystemFill))
                                        .frame(height: 2.5)
                                    Capsule()
                                        .fill(Color.accentColor)
                                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(prog.progress()))), height: 2.5)
                                }
                            }
                            .frame(height: 2.5)
                        }
                    } else {
                        Text(channel.group.isEmpty ? " " : channel.group)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(UIColor.secondaryLabel))
                            .lineLimit(1)
                    }
                }
                .frame(height: 38, alignment: .topLeading)
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
            .padding(8)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(14)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.06), lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.03), radius: 4, x: 0, y: 1.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button(action: onPlay) {
                Label(NSLocalizedString("Play", comment: ""), systemImage: "play.fill")
            }
            
            Button(action: onShowEPG) {
                Label(NSLocalizedString("Program Guide", comment: ""), systemImage: "list.bullet.rectangle")
            }
            
            Button(action: onToggleFavorite) {
                Label(
                    channel.isFavorite ? NSLocalizedString("Remove from Favorites", comment: "") : NSLocalizedString("Add to Favorites", comment: ""),
                    systemImage: channel.isFavorite ? "star.slash" : "star.fill"
                )
            }
            
            Divider()
            
            Button(action: {
                UIPasteboard.general.string = channel.url.absoluteString
            }) {
                Label(NSLocalizedString("Copy Stream URL", comment: ""), systemImage: "doc.on.doc")
            }
        }
    }
}

// MARK: - iOS IPTV Channel List Row

private struct IPTVChannelListRow: View {
    let channel: IPTVChannel
    let server: ServerConfig
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void
    let onShowEPG: () -> Void
    
    @ObservedObject private var epgService = EPGService.shared
    @ObservedObject private var artworkService = IPTVArtworkService.shared
    
    private var currentProgramme: EPGProgramme? {
        epgService.currentProgramme(for: channel, in: server.id)
    }
    
    private var snapshotURL: URL? {
        artworkService.snapshotURL(for: channel.id, in: server.id)
    }
    
    private var effectiveLogoURL: URL? {
        if let logo = channel.logoURL { return logo }
        return epgService.iconURL(for: channel, in: server.id)
    }
    
    var body: some View {
        Button(action: onPlay) {
            HStack(spacing: 12) {
                ZStack {
                    if let snapshot = snapshotURL {
                        RemoteImage(
                            url: snapshot,
                            placeholderSystemImage: "play.tv.fill",
                            contentMode: .fill
                        )
                    } else if let logoURL = effectiveLogoURL {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(UIColor.tertiarySystemFill).opacity(0.65))
                            RemoteImage(
                                url: logoURL,
                                placeholderSystemImage: "play.tv.fill",
                                contentMode: .fit
                            )
                            .padding(4)
                        }
                    } else {
                        ZStack {
                            LinearGradient(
                                colors: [
                                    Color(red: 0.12, green: 0.15, blue: 0.22),
                                    Color(red: 0.08, green: 0.09, blue: 0.14)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            Image(systemName: "play.tv.fill")
                                .font(.system(size: 15))
                                .foregroundColor(.white.opacity(0.7))
                        }
                    }
                }
                .aspectRatio(16/9, contentMode: .fit)
                .frame(width: 58)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                
                VStack(alignment: .leading, spacing: 3) {
                    Text(channel.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(UIColor.label))
                        .lineLimit(1)
                    
                    if let prog = currentProgramme {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(prog.title)
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(Color(UIColor.label))
                                    .lineLimit(1)
                                
                                Text(prog.formattedTimeSpan)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(Color(UIColor.secondaryLabel))
                            }
                            
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color(UIColor.tertiarySystemFill))
                                        .frame(height: 2.5)
                                    Capsule()
                                        .fill(Color.accentColor)
                                        .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(prog.progress()))), height: 2.5)
                                }
                            }
                            .frame(height: 2.5)
                        }
                    } else {
                        Text(channel.group.isEmpty ? " " : channel.group)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(Color(UIColor.secondaryLabel))
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                Button(action: onToggleFavorite) {
                    Image(systemName: channel.isFavorite ? "star.fill" : "star")
                        .font(.system(size: 15))
                        .foregroundColor(channel.isFavorite ? Color(UIColor.systemYellow) : Color(UIColor.tertiaryLabel))
                        .padding(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.05), lineWidth: 0.6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .contextMenu {
            Button(action: onPlay) {
                Label(NSLocalizedString("Play", comment: ""), systemImage: "play.fill")
            }
            
            Button(action: onShowEPG) {
                Label(NSLocalizedString("Program Guide", comment: ""), systemImage: "list.bullet.rectangle")
            }
            
            Button(action: onToggleFavorite) {
                Label(
                    NSLocalizedString(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites", comment: ""),
                    systemImage: channel.isFavorite ? "star.slash" : "star.fill"
                )
            }
            
            Divider()
            
            Button(action: {
                UIPasteboard.general.string = channel.url.absoluteString
            }) {
                Label(NSLocalizedString("Copy Stream URL", comment: ""), systemImage: "doc.on.doc")
            }
        }
    }
}

