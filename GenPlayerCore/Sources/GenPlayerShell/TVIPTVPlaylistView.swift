#if os(tvOS)
import SwiftUI
import GenPlayerCore

public struct TVIPTVPlaylistView: View {
    public let server: ServerConfig
    public let onExit: () -> Void
    
    @ObservedObject private var iptvService = IPTVService.shared
    @ObservedObject private var epgService = EPGService.shared
    private let playbackCoordinator = TVPlaybackCoordinator.shared
    
    @State private var selectedGroup: String = "ALL"
    @State private var displayLimit: Int = 100
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var epgTargetChannel: IPTVChannel? = nil
    @AppStorage("tv_iptv_is_grid_layout") private var isGridLayout: Bool = true
    @AppStorage("iptv_sort_field") private var sortFieldRaw: String = IPTVSortField.default.rawValue
    @AppStorage("iptv_sort_order") private var sortOrderRaw: String = IPTVSortOrder.ascending.rawValue
    
    private var sortField: IPTVSortField {
        get { IPTVSortField(rawValue: sortFieldRaw) ?? .default }
        set { sortFieldRaw = newValue.rawValue }
    }
    
    private var sortOrder: IPTVSortOrder {
        get { IPTVSortOrder(rawValue: sortOrderRaw) ?? .ascending }
        set { sortOrderRaw = newValue.rawValue }
    }
    
    private let pageSize: Int = 100
    private let favoriteGroupKey = "FAVORITES"
    private let allGroupKey = "ALL"
    
    public init(server: ServerConfig, onExit: @escaping () -> Void) {
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
        baseChannelsForSelectedGroup.sorted(by: sortField, order: sortOrder)
    }
    
    private var visibleChannels: [IPTVChannel] {
        Array(displayedChannels.prefix(displayLimit))
    }
    
    public var body: some View {
        TVPageScrollView(
            title: server.name,
            subtitle: "\(displayedChannels.count) \(platformShellString("Channels"))",
            handlesExitCommand: true,
            customExitCommand: {
                onExit()
                return true
            },
            titleAccessory: AnyView(
                HStack(spacing: 14) {
                    // 1st: Search
                    TVNavigationLink(destination: TVIPTVPlaylistSearchView(server: server)) {
                        TVTopChromeIconButton(
                            title: platformShellString("Search"),
                            systemImageName: "magnifyingglass",
                            diameter: 66
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()

                    // 2nd: Layout Toggle
                    Button(action: {
                        isGridLayout.toggle()
                    }) {
                        TVTopChromeIconButton(
                            title: platformShellString(isGridLayout ? "List View" : "Grid View"),
                            systemImageName: isGridLayout ? "list.bullet" : "square.grid.2x2",
                            diameter: 66
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()

                    // 3rd: Sort
                    TVNavigationLink(
                        destination: TVIPTVSortView(
                            sortFieldRaw: $sortFieldRaw,
                            sortOrderRaw: $sortOrderRaw
                        )
                    ) {
                        TVTopChromeIconButton(
                            title: platformShellString("Sort"),
                            systemImageName: "line.3.horizontal.decrease.circle",
                            diameter: 66
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()

                    // 4th: Refresh
                    Button(action: {
                        Task {
                            await loadPlaylist(force: true)
                        }
                    }) {
                        TVTopChromeIconButton(
                            title: platformShellString("Refresh"),
                            systemImageName: "arrow.clockwise",
                            diameter: 66
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                    .disabled(isLoading)

                    // 5th: Close
                    Button(action: onExit) {
                        TVTopChromeIconButton(
                            title: platformShellString("Close"),
                            systemImageName: "rectangle.portrait.and.arrow.right",
                            diameter: 66
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
                .tvFocusSectionIfAvailable()
            )
        ) {
            // Group Tabs Shelf
            if !allChannels.isEmpty {
                groupTabsShelf
                    .padding(.bottom, 24)
            }
            
            if isLoading {
                VStack(spacing: 20) {
                    ProgressView()
                        .scaleEffect(1.5)
                    Text(platformShellString("Loading playlist..."))
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(TVShellStyle.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
            } else if let error = errorMessage, allChannels.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 60))
                        .foregroundColor(.orange)
                    Text(platformShellString("Failed to Load Playlist"))
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(TVShellStyle.primary)
                    Text(error)
                        .font(.system(size: 22))
                        .foregroundColor(TVShellStyle.secondary)
                        .multilineTextAlignment(.center)
                    
                    Button(action: { Task { await loadPlaylist(force: true) } }) {
                        TVMaintenanceButtonLabel(
                            title: platformShellString("Retry"),
                            systemImageName: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else if allChannels.isEmpty {
                VStack(spacing: 24) {
                    Image(systemName: "play.tv")
                        .font(.system(size: 60))
                        .foregroundColor(TVShellStyle.secondary.opacity(0.4))
                    Text(platformShellString("No Channels Found"))
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(TVShellStyle.primary)
                    
                    Button(action: { Task { await loadPlaylist(force: true) } }) {
                        TVMaintenanceButtonLabel(
                            title: platformShellString("Refresh"),
                            systemImageName: "arrow.clockwise"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else if displayedChannels.isEmpty {
                VStack(spacing: 16) {
                    Text(platformShellString("No channels in this group"))
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(TVShellStyle.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            } else if isGridLayout {
                channelsGrid
            } else {
                channelsList
            }
        }
        .sheet(item: $epgTargetChannel) { target in
            TVIPTVProgramGuideSheet(
                channel: target,
                server: server,
                onPlay: { playChannel(target) },
                onDismiss: { epgTargetChannel = nil }
            )
        }
        .onAppear {
            if allChannels.isEmpty {
                Task {
                    await loadPlaylist(force: false)
                }
            }
        }
        .onChange(of: selectedGroup) { _ in
            displayLimit = pageSize
        }
    }
    
    // MARK: - Group Tabs Shelf
    
    private var groupTabsShelf: some View {
        HStack(spacing: 16) {
            TVCategoryTabButton(
                title: platformShellString("All"),
                count: allChannels.count,
                isSelected: selectedGroup == allGroupKey,
                iconName: nil
            ) {
                selectedGroup = allGroupKey
            }
            
            if !favoriteChannels.isEmpty {
                TVCategoryTabButton(
                    title: platformShellString("Favorites"),
                    count: favoriteChannels.count,
                    isSelected: selectedGroup == favoriteGroupKey,
                    iconName: "star.fill"
                ) {
                    selectedGroup = favoriteGroupKey
                }
            }
            
            if !availableGroups.isEmpty {
                Divider()
                    .frame(height: 36)
                    .padding(.horizontal, 2)
                
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(availableGroups, id: \.self) { group in
                            let count = groupCounts[group] ?? allChannels.filter { $0.matches(group: group) }.count
                            TVCategoryTabButton(
                                title: group,
                                count: count,
                                isSelected: selectedGroup == group,
                                iconName: nil
                            ) {
                                selectedGroup = group
                            }
                        }
                    }
                    .padding(.trailing, 8)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvFocusSectionIfAvailable()
    }
    
    // MARK: - Channels Grid (TVFocusableRowGrid with Virtual Windowing delivers instant render & 60fps focus)
    
    private var channelsGrid: some View {
        TVFocusableRowGrid(
            items: visibleChannels,
            columnsPerRow: 5,
            columnWidth: 320,
            rowMinHeight: 220,
            columnSpacing: 24,
            rowSpacing: 24
        ) { channel in
            TVLiveChannelCard(
                channel: channel,
                server: server,
                onPlay: { playChannel(channel) },
                onShowEPG: { epgTargetChannel = channel }
            )
            .onAppear {
                if channel.id == visibleChannels.last?.id, displayLimit < displayedChannels.count {
                    displayLimit = min(displayLimit + pageSize, displayedChannels.count)
                }
            }
        }
    }
    
    // MARK: - Channels List
    
    private var channelsList: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(visibleChannels) { channel in
                TVLiveChannelListRow(
                    channel: channel,
                    server: server,
                    onPlay: { playChannel(channel) },
                    onShowEPG: { epgTargetChannel = channel }
                )
                .onAppear {
                    if channel.id == visibleChannels.last?.id, displayLimit < displayedChannels.count {
                        displayLimit = min(displayLimit + pageSize, displayedChannels.count)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .tvFocusSectionIfAvailable()
    }
    
    private func loadPlaylist(force: Bool) async {
        await MainActor.run {
            isLoading = true
            errorMessage = nil
            displayLimit = 100
        }
        do {
            _ = try await iptvService.fetchPlaylist(for: server, forceRefresh: force)
            await MainActor.run {
                isLoading = false
            }
        } catch {
            await MainActor.run {
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }
    
    private func playChannel(_ channel: IPTVChannel) {
        let currentList = displayedChannels
        let playlistFiles = currentList.map { iptvService.makeVideoFile(for: $0, server: server) }
        let targetFile = iptvService.makeVideoFile(for: channel, server: server)
        
        playbackCoordinator.play(file: targetFile, playlist: playlistFiles)
    }
}

// MARK: - TV Channel Card Button Style

private struct TVLiveChannelCardButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isFocused ? TVShellStyle.elevatedSurface : TVShellStyle.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(isFocused ? Color.clear : TVShellStyle.glassStroke, lineWidth: 1)
            )
            .overlay(
                TVFocusedBlockOverlay(cornerRadius: 20, showsFocus: isFocused)
            )
            .scaleEffect(isFocused ? 1.06 : (configuration.isPressed ? 0.97 : 1.0))
            .shadow(
                color: isFocused ? Color.black.opacity(0.48) : Color.black.opacity(0.12),
                radius: isFocused ? 24 : 6,
                x: 0,
                y: isFocused ? 14 : 3
            )
            .animation(.easeOut(duration: 0.16), value: isFocused)
            .tvDisableSystemFocusEffect()
    }
}

// MARK: - TV Channel Card

private struct TVLiveChannelCard: View {
    let channel: IPTVChannel
    let server: ServerConfig
    let onPlay: () -> Void
    var onShowEPG: (() -> Void)? = nil
    
    @ObservedObject private var iptvService = IPTVService.shared
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
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    TVRemoteArtworkView(
                        url: snapshotURL ?? effectiveLogoURL,
                        server: server,
                        placeholderSystemImageName: "play.tv.fill",
                        placeholderCornerRadius: 16
                    )
                    .frame(height: 140)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    
                    if channel.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(Color(UIColor.systemYellow))
                            .padding(10)
                    }
                }
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(TVShellStyle.primary)
                        .lineLimit(1)
                    
                    if let prog = currentProgramme {
                        Text(prog.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(TVShellStyle.accentSoft)
                            .lineLimit(1)
                    } else {
                        Text(channel.group)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(TVShellStyle.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .padding(10)
        }
        .buttonStyle(TVLiveChannelCardButtonStyle())
        .contextMenu {
            Button(action: onPlay) {
                Label(platformShellString("Play"), systemImage: "play.fill")
            }

            if let onShowEPG = onShowEPG {
                Button(action: onShowEPG) {
                    Label(platformShellString("Program Guide"), systemImage: "list.bullet.rectangle")
                }
            }

            Button(action: {
                iptvService.toggleFavorite(channelId: channel.id, in: server)
            }) {
                Label(
                    channel.isFavorite ? platformShellString("Remove from Favorites") : platformShellString("Add to Favorites"),
                    systemImage: channel.isFavorite ? "star.slash" : "star"
                )
            }
        }
    }
}

// MARK: - TV Live Channel List Row

private struct TVLiveChannelListRow: View {
    let channel: IPTVChannel
    let server: ServerConfig
    let onPlay: () -> Void
    var onShowEPG: (() -> Void)? = nil
    
    @ObservedObject private var iptvService = IPTVService.shared
    @ObservedObject private var epgService = EPGService.shared
    @ObservedObject private var artworkService = IPTVArtworkService.shared
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    
    private var showsFocus: Bool {
        isFocused && isEnabled
    }
    
    private var primaryColor: Color {
        TVRowFocusStyle.primary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }
    
    private var secondaryColor: Color {
        TVRowFocusStyle.secondary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }
    
    private var rowFill: Color {
        if showsFocus {
            return TVRowFocusStyle.focusedFill(for: colorScheme)
        }
        return TVShellStyle.surface.opacity(0.72)
    }
    
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
            HStack(spacing: 20) {
                TVRemoteArtworkView(
                    url: snapshotURL ?? effectiveLogoURL,
                    server: server,
                    placeholderSystemImageName: "play.tv.fill",
                    placeholderCornerRadius: 10
                )
                .frame(width: 88, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .clipped()
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(channel.name)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(primaryColor)
                        .lineLimit(1)
                    
                    if let prog = currentProgramme {
                        HStack(spacing: 8) {
                            Text(prog.title)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(showsFocus ? primaryColor : TVShellStyle.accentSoft)
                                .lineLimit(1)
                            
                            Text(prog.formattedTimeSpan)
                                .font(.system(size: 16, design: .monospaced))
                                .foregroundColor(secondaryColor)
                        }
                    } else {
                        Text(channel.group.isEmpty ? " " : channel.group)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(secondaryColor)
                            .lineLimit(1)
                    }
                }
                
                Spacer()
                
                if channel.isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(showsFocus ? primaryColor : Color(UIColor.systemYellow))
                        .padding(.trailing, 8)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(rowFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(showsFocus ? Color.clear : Color.white.opacity(0.08), lineWidth: 1)
            )
            .overlay(
                TVFocusedBlockOverlay(cornerRadius: 16, showsFocus: showsFocus)
            )
            .scaleEffect(showsFocus ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.14), value: showsFocus)
            .contentShape(Rectangle())
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
        .contextMenu {
            Button(action: onPlay) {
                Label(platformShellString("Play"), systemImage: "play.fill")
            }
            
            if let onShowEPG = onShowEPG {
                Button(action: onShowEPG) {
                    Label(platformShellString("Program Guide"), systemImage: "list.bullet.rectangle")
                }
            }
            
            Button(action: {
                iptvService.toggleFavorite(channelId: channel.id, in: server)
            }) {
                Label(
                    channel.isFavorite ? platformShellString("Remove from Favorites") : platformShellString("Add to Favorites"),
                    systemImage: channel.isFavorite ? "star.slash" : "star"
                )
            }
        }
    }
}

// MARK: - TV IPTV Search View

struct TVIPTVPlaylistSearchView: View {
    let server: ServerConfig

    @ObservedObject private var iptvService = IPTVService.shared
    private let playbackCoordinator = TVPlaybackCoordinator.shared

    @State private var searchText: String = ""
    @State private var epgTargetChannel: IPTVChannel? = nil

    private var allChannels: [IPTVChannel] {
        iptvService.cachedPlaylist(for: server.id)?.channels ?? []
    }

    private var searchResults: [IPTVChannel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return [] }
        return allChannels.filter {
            $0.name.lowercased().contains(query) ||
            $0.group.lowercased().contains(query)
        }
    }

    var body: some View {
        TVPageScrollView(
            title: platformShellString("Search"),
            subtitle: server.name,
            handlesExitCommand: true
        ) {
            TVTextFieldPanel(
                title: platformShellString("Search Channels"),
                placeholder: platformShellString("Search Channels"),
                text: $searchText
            )

            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TVInfoPanel(
                    title: platformShellString("Search Channels"),
                    message: "\(allChannels.count) \(platformShellString("Channels"))",
                    systemImageName: "magnifyingglass"
                )
            } else if searchResults.isEmpty {
                TVInfoPanel(
                    title: platformShellString("No results found"),
                    message: searchText,
                    systemImageName: "doc.text.magnifyingglass"
                )
            } else {
                TVFocusableRowGrid(
                    items: searchResults,
                    columnsPerRow: 5,
                    columnWidth: 320,
                    rowMinHeight: 220,
                    columnSpacing: 24,
                    rowSpacing: 24
                ) { channel in
                    TVLiveChannelCard(
                        channel: channel,
                        server: server,
                        onPlay: {
                            let playlistFiles = searchResults.map { iptvService.makeVideoFile(for: $0, server: server) }
                            let targetFile = iptvService.makeVideoFile(for: channel, server: server)
                            playbackCoordinator.play(file: targetFile, playlist: playlistFiles)
                        },
                        onShowEPG: {
                            epgTargetChannel = channel
                        }
                    )
                }
            }
        }
        .sheet(item: $epgTargetChannel) { target in
            TVIPTVProgramGuideSheet(
                channel: target,
                server: server,
                onPlay: {
                    let targetFile = iptvService.makeVideoFile(for: target, server: server)
                    playbackCoordinator.play(file: targetFile)
                },
                onDismiss: { epgTargetChannel = nil }
            )
        }
    }
}

// MARK: - TV IPTV Sort View

struct TVIPTVSortView: View {
    @Binding var sortFieldRaw: String
    @Binding var sortOrderRaw: String
    
    private var sortField: IPTVSortField {
        get { IPTVSortField(rawValue: sortFieldRaw) ?? .default }
        nonmutating set { sortFieldRaw = newValue.rawValue }
    }
    
    private var sortOrder: IPTVSortOrder {
        get { IPTVSortOrder(rawValue: sortOrderRaw) ?? .ascending }
        nonmutating set { sortOrderRaw = newValue.rawValue }
    }

    var body: some View {
        TVSettingsChoicePage(title: platformShellString("Sort")) {
            VStack(alignment: .leading, spacing: 28) {
                sortFieldSection
                if sortField != .default {
                    sortOrderSection
                }
            }
        }
    }

    private var sortFieldSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVSettingsSectionHeader(title: platformShellString("Sort By"))

            ForEach(IPTVSortField.allCases) { option in
                Button(action: {
                    guard sortField != option else { return }
                    sortField = option
                    if option == .name {
                        sortOrder = .ascending
                    }
                }) {
                    TVSettingsChoiceRow(
                        title: platformShellString(option.title),
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

            ForEach(IPTVSortOrder.allCases) { option in
                Button(action: {
                    guard sortOrder != option else { return }
                    sortOrder = option
                }) {
                    TVSettingsChoiceRow(
                        title: platformShellString(option.title),
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
#endif

