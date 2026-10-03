#if os(macOS)
import SwiftUI
import AppKit
import GenPlayerCore

public struct MacIPTVPlaylistView: View {
    public let server: ServerConfig
    public var onExit: (() -> Void)? = nil
    
    @ObservedObject private var iptvService = IPTVService.shared
    @ObservedObject private var epgService = EPGService.shared
    @State private var selectedGroup: String = "ALL"
    @State private var searchText: String = ""
    @State private var isLoading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var displayLimit: Int = 120
    @State private var epgTargetChannel: IPTVChannel? = nil
    @AppStorage("MacIPTVIsGridView") private var isGridView: Bool = true
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
    private let favoriteGroupKey = "FAVORITES"
    private let allGroupKey = "ALL"
    
    public init(server: ServerConfig, onExit: (() -> Void)? = nil) {
        self.server = server
        self.onExit = onExit
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
    
    private var displayedChannels: [IPTVChannel] {
        let baseList = baseChannelsForSelectedGroup
        let filtered: [IPTVChannel]
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            filtered = baseList
        } else {
            filtered = baseList.filter {
                $0.name.localizedCaseInsensitiveContains(query) || $0.group.localizedCaseInsensitiveContains(query)
            }
        }
        return filtered.sorted(by: sortField, order: sortOrder)
    }
    
    private var visibleChannels: [IPTVChannel] {
        Array(displayedChannels.prefix(displayLimit))
    }
    
    public var body: some View {
        VStack(spacing: 0) {
            // Group Filter Section (Styled identical to Jellyfin/Emby category filter in MacMediaServerViews)
            if !allChannels.isEmpty && searchText.isEmpty {
                MacIPTVFilterSection(
                    label: platformShellString("Group"),
                    allTitle: platformShellString("All"),
                    allCount: allChannels.count,
                    favoriteTitle: favoriteChannels.isEmpty ? nil : platformShellString("Favorites"),
                    favoriteCount: favoriteChannels.count,
                    groups: availableGroups,
                    groupCounts: groupCounts,
                    selectedGroup: selectedGroup,
                    allGroupKey: allGroupKey,
                    favoriteGroupKey: favoriteGroupKey,
                    onSelectGroup: { group in
                        selectedGroup = group
                        displayLimit = pageSize
                    }
                )
                Divider()
            }
            
            // Content Area
            ZStack {
                Color(NSColor.windowBackgroundColor)
                    .ignoresSafeArea()
                
                if isLoading {
                    loadingView
                } else if let errorMessage = errorMessage, allChannels.isEmpty {
                    errorView(errorMessage)
                } else if allChannels.isEmpty {
                    emptyChannelsView
                } else if displayedChannels.isEmpty {
                    emptyFilterView
                } else {
                    channelsContentView
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        .macServerToolbar(
            server: server,
            title: server.name,
            canGoBack: false,
            searchText: $searchText,
            onBack: {},
            onHome: {},
            onExit: {
                onExit?()
            }
        ) {
            HStack(spacing: 6) {
                MacToolbarButton(
                    systemImage: isGridView ? "square.grid.2x2" : "list.bullet",
                    title: platformShellString(isGridView ? "Grid View" : "List View"),
                    action: { isGridView.toggle() }
                )

                MacIPTVSortPopover(
                    sortFieldRaw: $sortFieldRaw,
                    sortOrderRaw: $sortOrderRaw
                )

                MacToolbarButton(
                    systemImage: "arrow.clockwise",
                    title: platformShellString("Refresh"),
                    action: { loadPlaylist(force: true) }
                )
                .disabled(isLoading)
            }
        }
        .sheet(item: $epgTargetChannel) { target in
            MacIPTVProgramGuideSheet(
                channel: target,
                server: server,
                onPlay: { playChannel(target) },
                onDismiss: { epgTargetChannel = nil }
            )
        }
        .onChange(of: searchText) { _ in
            displayLimit = pageSize
        }
        .onAppear {
            displayLimit = pageSize
            if allChannels.isEmpty {
                loadPlaylist(force: false)
            }
        }
    }
    
    // MARK: - Channels Content View
    
    private var channelsContentView: some View {
        let currentVisible = visibleChannels
        let lastID = currentVisible.last?.id
        
        return ScrollView {
            if isGridView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 18)], spacing: 18) {
                    ForEach(currentVisible) { channel in
                        MacIPTVChannelCard(channel: channel, server: server) {
                            playChannel(channel)
                        } onToggleFavorite: {
                            toggleFavorite(for: channel)
                        } onShowEPG: {
                            epgTargetChannel = channel
                        }
                        .onAppear {
                            if channel.id == lastID {
                                loadMoreChannelsIfNeeded()
                            }
                        }
                    }
                }
                .padding(24)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(currentVisible) { channel in
                        MacIPTVChannelRow(channel: channel, server: server) {
                            playChannel(channel)
                        } onToggleFavorite: {
                            toggleFavorite(for: channel)
                        } onShowEPG: {
                            epgTargetChannel = channel
                        }
                        .onAppear {
                            if channel.id == lastID {
                                loadMoreChannelsIfNeeded()
                            }
                        }
                    }
                }
                .padding(24)
            }
        }
    }
    
    private func loadMoreChannelsIfNeeded() {
        let total = displayedChannels.count
        guard displayLimit < total else { return }
        displayLimit = min(displayLimit + pageSize, total)
    }
    
    // MARK: - State Views
    
    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text(platformShellString("Loading playlist..."))
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
    
    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text(platformShellString("Failed to Load Playlist"))
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            
            Button(platformShellString("Retry")) {
                loadPlaylist(force: true)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
    
    private var emptyChannelsView: some View {
        VStack(spacing: 16) {
            Image(systemName: "play.tv")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.4))
            Text(platformShellString("No Channels Found"))
                .font(.headline)
                .foregroundColor(.secondary)
            Button(platformShellString("Refresh")) {
                loadPlaylist(force: true)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
    
    private var emptyFilterView: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundColor(.secondary.opacity(0.4))
            Text(platformShellString("No channels matching search"))
                .font(.headline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
    
    // MARK: - Actions
    
    private func loadPlaylist(force: Bool) {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                _ = try await iptvService.fetchPlaylist(for: server, forceRefresh: force)
                await MainActor.run {
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
    
    private func playChannel(_ channel: IPTVChannel) {
        let file = iptvService.makeVideoFile(for: channel, server: server)
        let allFiles = displayedChannels.map { iptvService.makeVideoFile(for: $0, server: server) }
        MacPlayerWindowManager.shared.openPlayer(for: file, playlist: allFiles, thumbnailURL: channel.logoURL)
    }
    
    private func toggleFavorite(for channel: IPTVChannel) {
        iptvService.toggleFavorite(channelId: channel.id, in: server)
    }
}

// MARK: - Multi-Row Filter Section (Matches Jellyfin/Emby MacFilterSection layout)

private struct MacIPTVFilterLayoutResult: Equatable {
    var row1: [String] = []
    var row2: [String] = []
    var overflow: [String] = []
    var totalHeight: CGFloat = 34
}

private struct MacIPTVFilterSection: View {
    let label: String
    let allTitle: String
    let allCount: Int
    let favoriteTitle: String?
    let favoriteCount: Int
    let groups: [String]
    let groupCounts: [String: Int]
    let selectedGroup: String
    let allGroupKey: String
    let favoriteGroupKey: String
    let onSelectGroup: (String) -> Void
    
    @State private var containerWidth: CGFloat = 0
    
    private let chipSpacing: CGFloat = 8
    private let rowHeight: CGFloat = 34
    
    private func estimateWidth(for text: String, count: Int? = nil, hasIcon: Bool = false) -> CGFloat {
        var baseWidth: CGFloat = CGFloat(text.count) * 8.0 + 26
        if hasIcon { baseWidth += 14 }
        if let count = count {
            baseWidth += CGFloat(String(count).count) * 6.5 + 16
        }
        return baseWidth
    }
    
    private func computeLayout(width: CGFloat) -> MacIPTVFilterLayoutResult {
        guard width > 50 else { return MacIPTVFilterLayoutResult() }
        
        let availableWidth = width - 50 - 12 // label width (50) + spacing
        var row1: [String] = []
        var row2: [String] = []
        var overflow: [String] = []
        
        var currentX: CGFloat = estimateWidth(for: allTitle, count: allCount) + chipSpacing
        if let fav = favoriteTitle {
            currentX += estimateWidth(for: fav, count: favoriteCount, hasIcon: true) + chipSpacing
        }
        
        var currentRow = 1
        
        for group in groups {
            let itemWidth = estimateWidth(for: group, count: groupCounts[group])
            
            if currentRow == 1 {
                if currentX + itemWidth > availableWidth {
                    currentRow = 2
                    currentX = itemWidth + chipSpacing
                    row2.append(group)
                } else {
                    row1.append(group)
                    currentX += itemWidth + chipSpacing
                }
            } else if currentRow == 2 {
                let isLast = group == groups.last
                let moreButtonWidth: CGFloat = 50
                let requiredSpace = itemWidth + (isLast ? 0 : (chipSpacing + moreButtonWidth))
                
                if currentX + requiredSpace > availableWidth {
                    currentRow = 3
                    overflow.append(group)
                } else {
                    row2.append(group)
                    currentX += itemWidth + chipSpacing
                }
            } else {
                overflow.append(group)
            }
        }
        
        let height: CGFloat = currentRow > 1 ? (rowHeight * 2 + chipSpacing) : rowHeight
        return MacIPTVFilterLayoutResult(row1: row1, row2: row2, overflow: overflow, totalHeight: height)
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
                            IPTVFilterChipButton(
                                title: allTitle,
                                count: allCount,
                                isSelected: selectedGroup == allGroupKey
                            ) {
                                onSelectGroup(allGroupKey)
                            }
                            
                            if let fav = favoriteTitle {
                                IPTVFilterChipButton(
                                    title: fav,
                                    count: favoriteCount,
                                    systemIcon: "star.fill",
                                    isSelected: selectedGroup == favoriteGroupKey
                                ) {
                                    onSelectGroup(favoriteGroupKey)
                                }
                            }
                            
                            ForEach(layout.row1, id: \.self) { group in
                                IPTVFilterChipButton(
                                    title: group,
                                    count: groupCounts[group],
                                    isSelected: selectedGroup == group
                                ) {
                                    onSelectGroup(group)
                                }
                            }
                        }
                        
                        if !layout.row2.isEmpty || !layout.overflow.isEmpty {
                            HStack(spacing: chipSpacing) {
                                ForEach(layout.row2, id: \.self) { group in
                                    IPTVFilterChipButton(
                                        title: group,
                                        count: groupCounts[group],
                                        isSelected: selectedGroup == group
                                    ) {
                                        onSelectGroup(group)
                                    }
                                }
                                
                                if !layout.overflow.isEmpty {
                                    let isOverflowSelected = layout.overflow.contains(selectedGroup)
                                    Menu {
                                        ForEach(layout.overflow, id: \.self) { group in
                                            let count = groupCounts[group]
                                            Button(action: { onSelectGroup(group) }) {
                                                HStack {
                                                    Text(count != nil ? "\(group) (\(count!))" : group)
                                                    if selectedGroup == group {
                                                        Image(systemName: "checkmark")
                                                    }
                                                }
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            if isOverflowSelected {
                                                Text(selectedGroup)
                                                    .font(.subheadline.weight(.semibold))
                                                    .foregroundColor(.white)
                                                if let count = groupCounts[selectedGroup] {
                                                    Text("\(count)")
                                                        .font(.system(size: 11, weight: .medium))
                                                        .foregroundColor(.white.opacity(0.85))
                                                }
                                            } else {
                                                Image(systemName: "ellipsis")
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        .padding(.horizontal, isOverflowSelected ? 12 : 8)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule()
                                                .fill(isOverflowSelected ? Color.accentColor : Color.primary.opacity(0.06))
                                        )
                                    }
                                    .menuStyle(.borderlessButton)
                                    .fixedSize()
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
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - IPTV Filter Chip

private struct IPTVFilterChipButton: View {
    let title: String
    var count: Int? = nil
    var systemIcon: String? = nil
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemIcon = systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 11))
                        .foregroundColor(isSelected ? .white : .yellow)
                }
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundColor(isSelected ? .white : (isHovered ? .primary : .primary.opacity(0.85)))
                
                if let count = count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isSelected ? .white.opacity(0.9) : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(
                            Capsule()
                                .fill(isSelected ? Color.white.opacity(0.22) : Color.primary.opacity(0.08))
                        )
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Mac IPTV Channel Grid Card (with Hover Play Button & Context Menu)

private struct MacIPTVChannelCard: View {
    let channel: IPTVChannel
    let server: ServerConfig
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void
    let onShowEPG: () -> Void
    
    @ObservedObject private var epgService = EPGService.shared
    @ObservedObject private var artworkService = IPTVArtworkService.shared
    @State private var isHovered = false
    @State private var isPlayButtonHovered = false
    
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
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .center) {
                // Logo or Video Snapshot Container
                ZStack {
                    if let snapshot = snapshotURL {
                        MacCachedAsyncImage(url: snapshot) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            default:
                                fallbackLogoOrEmblemView
                            }
                        }
                    } else {
                        fallbackLogoOrEmblemView
                    }
                }
                .frame(height: 94)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                
                // Hover Play Button Overlay (Matches Jellyfin/Emby cards)
                if isHovered {
                    ZStack {
                        Color.black.opacity(0.35)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .allowsHitTesting(false)
                        
                        Button(action: onPlay) {
                            ZStack {
                                Circle()
                                    .fill(isPlayButtonHovered ? Color.accentColor : Color.black.opacity(0.65))
                                    .overlay(
                                        Circle()
                                            .stroke(Color.white.opacity(isPlayButtonHovered ? 0.8 : 0.4), lineWidth: 1.2)
                                    )
                                
                                Image(systemName: "play.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(.white)
                                    .offset(x: 1.5)
                            }
                            .frame(width: 40, height: 40)
                            .scaleEffect(isPlayButtonHovered ? 1.08 : 1.0)
                            .shadow(color: Color.black.opacity(0.4), radius: 6, x: 0, y: 3)
                            .contentShape(Circle())
                        }
                        .buttonStyle(BorderlessButtonStyle())
                        .onHover { isPlayButtonHovered = $0 }
                    }
                    .transition(.opacity.animation(.easeInOut(duration: 0.15)))
                }
                
                // Favorite Button in Top-Trailing corner
                VStack {
                    HStack {
                        Spacer()
                        Button(action: onToggleFavorite) {
                            Image(systemName: channel.isFavorite ? "star.fill" : "star")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundColor(channel.isFavorite ? .yellow : .white)
                                .padding(5)
                                .background(Color.black.opacity(0.5))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(6)
                    }
                    Spacer()
                }
            }
            
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                if let prog = currentProgramme {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(prog.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color.accentColor)
                            .lineLimit(1)
                        
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.secondary.opacity(0.2))
                                    .frame(height: 2.5)
                                Capsule()
                                    .fill(Color.accentColor)
                                    .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(prog.progress()))), height: 2.5)
                            }
                        }
                        .frame(height: 2.5)
                    }
                } else {
                    Text(channel.group)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(height: 36, alignment: .topLeading)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(NSColor.controlBackgroundColor).opacity(isHovered ? 0.95 : 0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isHovered ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: isHovered ? 1.5 : 1)
        )
        .shadow(color: Color.black.opacity(isHovered ? 0.12 : 0.04), radius: isHovered ? 8 : 4, x: 0, y: isHovered ? 4 : 2)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            onPlay()
        }
        .onTapGesture(count: 1) {
            onPlay()
        }
        .contextMenu {
            Button(action: onPlay) {
                Label(platformShellString("Play"), systemImage: "play.fill")
            }
            
            Button(action: onShowEPG) {
                Label(platformShellString("Program Guide"), systemImage: "list.bullet.rectangle")
            }
            
            Button(action: onToggleFavorite) {
                Label(
                    platformShellString(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites"),
                    systemImage: channel.isFavorite ? "star.slash" : "star.fill"
                )
            }
            
            Divider()
            
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(channel.url.absoluteString, forType: .string)
            }) {
                Label(platformShellString("Copy Stream URL"), systemImage: "doc.on.doc")
            }
        }
    }
    
    @ViewBuilder
    private var fallbackLogoOrEmblemView: some View {
        if let logoURL = effectiveLogoURL {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(NSColor.textBackgroundColor).opacity(0.55))
                
                MacCachedAsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(8)
                    case .empty, .failure:
                        emblemPlaceholderView
                    @unknown default:
                        emblemPlaceholderView
                    }
                }
            }
        } else {
            emblemPlaceholderView
        }
    }
    
    @ViewBuilder
    private var emblemPlaceholderView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.12, green: 0.15, blue: 0.22),
                    Color(red: 0.08, green: 0.09, blue: 0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 44, height: 32)
                    
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                Text(channel.name)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
                    .padding(.horizontal, 8)
            }
        }
    }
}

// MARK: - Mac IPTV Channel List Row (with Context Menu)

private struct MacIPTVChannelRow: View {
    let channel: IPTVChannel
    let server: ServerConfig
    let onPlay: () -> Void
    let onToggleFavorite: () -> Void
    let onShowEPG: () -> Void
    
    @ObservedObject private var epgService = EPGService.shared
    @ObservedObject private var artworkService = IPTVArtworkService.shared
    @State private var isHovered = false
    
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
        HStack(spacing: 12) {
            // Logo / Snapshot
            ZStack {
                if let snapshot = snapshotURL {
                    MacCachedAsyncImage(url: snapshot) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        default:
                            fallbackRowLogoView
                        }
                    }
                } else {
                    fallbackRowLogoView
                }
            }
            .frame(width: 52, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            
            VStack(alignment: .leading, spacing: 3) {
                Text(channel.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                
                if let prog = currentProgramme {
                    HStack(spacing: 6) {
                        Text(prog.title)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundColor(Color.accentColor)
                            .lineLimit(1)
                        
                        Text(prog.formattedTimeSpan)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text(channel.group)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            Button(action: onToggleFavorite) {
                Image(systemName: channel.isFavorite ? "star.fill" : "star")
                    .font(.system(size: 14))
                    .foregroundColor(channel.isFavorite ? .yellow : .secondary.opacity(0.5))
                    .padding(6)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture(count: 2) {
            onPlay()
        }
        .onTapGesture(count: 1) {
            onPlay()
        }
        .contextMenu {
            Button(action: onPlay) {
                Label(platformShellString("Play"), systemImage: "play.fill")
            }
            
            Button(action: onShowEPG) {
                Label(platformShellString("Program Guide"), systemImage: "list.bullet.rectangle")
            }
            
            Button(action: onToggleFavorite) {
                Label(
                    platformShellString(channel.isFavorite ? "Remove from Favorites" : "Add to Favorites"),
                    systemImage: channel.isFavorite ? "star.slash" : "star.fill"
                )
            }
            
            Divider()
            
            Button(action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(channel.url.absoluteString, forType: .string)
            }) {
                Label(platformShellString("Copy Stream URL"), systemImage: "doc.on.doc")
            }
        }
    }
    
    @ViewBuilder
    private var fallbackRowLogoView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(NSColor.textBackgroundColor).opacity(0.55))
            
            if let logoURL = effectiveLogoURL {
                MacCachedAsyncImage(url: logoURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .padding(4)
                    case .empty, .failure:
                        Image(systemName: "play.tv.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary.opacity(0.35))
                    @unknown default:
                        Image(systemName: "play.tv.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.secondary.opacity(0.35))
                    }
                }
            } else {
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary.opacity(0.35))
            }
        }
    }
}

// MARK: - Mac IPTV Sort Popover

private struct MacIPTVSortPopover: View {
    @Binding var sortFieldRaw: String
    @Binding var sortOrderRaw: String
    @State private var isPresented = false

    private var sortField: IPTVSortField {
        get { IPTVSortField(rawValue: sortFieldRaw) ?? .default }
        nonmutating set { sortFieldRaw = newValue.rawValue }
    }

    private var sortOrder: IPTVSortOrder {
        get { IPTVSortOrder(rawValue: sortOrderRaw) ?? .ascending }
        nonmutating set { sortOrderRaw = newValue.rawValue }
    }

    var body: some View {
        MacToolbarButton(
            systemImage: "line.3.horizontal.decrease.circle",
            title: platformShellString("Sort"),
            action: { isPresented.toggle() }
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(platformShellString("Sort By"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)

                ForEach(IPTVSortField.allCases) { field in
                    Button(action: {
                        sortField = field
                        if field == .name {
                            sortOrder = .ascending
                        }
                    }) {
                        HStack {
                            Text(platformShellString(field.title))
                            Spacer()
                            if sortField == field {
                                Image(systemName: "checkmark")
                                    .font(.caption.weight(.bold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }

                if sortField != .default {
                    Divider()

                    Text(platformShellString("Sort Order"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)

                    ForEach(IPTVSortOrder.allCases) { order in
                        Button(action: {
                            sortOrder = order
                        }) {
                            HStack {
                                Text(platformShellString(order.title))
                                Spacer()
                                if sortOrder == order {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.bold))
                                        .foregroundColor(.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
            }
            .padding(8)
            .frame(width: 160)
        }
    }
}
#endif

