#if os(tvOS)
import SwiftUI
import GenPlayerCore

struct TVLibraryLeafDetailView: View {
    let server: ServerConfig
    let node: TVMediaLibraryNode
    private let playbackCoordinator = TVPlaybackCoordinator.shared

    private var playableFile: VideoFile? {
        tvPlayableLibraryFile(server: server, node: node)
    }

    var body: some View {
        TVPageScrollView(
            title: tvDisplayTitle(from: node.name, type: node.type),
            subtitle: nil,
            handlesExitCommand: true,
            showsTitle: false,
            topPadding: 0,
            showsHomeAction: true,
            showsDownloadsAction: true
        ) {
            TVFullBleedHeroRow(height: TVLibraryLeafCinematicHero.heroHeight) {
                TVLibraryLeafCinematicHero(
                    server: server,
                    node: node,
                    playableFile: playableFile,
                    downloadNodes: [node],
                    downloadGroupTitle: nil,
                    onPlay: { file in
                        playbackCoordinator.play(file: file)
                    }
                )
            }

            if !node.people.isEmpty {
                TVCastShelfSection(people: node.people, server: server)
            }

            TVSimilarItemsSection(server: server, node: node)

            Button(action: {}) {
                TVLibraryLeafInfoGrid(node: node, server: server)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(TVFocusableSectionButtonStyle())
            .tvDisableSystemFocusEffect()
        }
        .navigationTitle(Text(tvDisplayTitle(from: node.name, type: node.type)))
    }
}

// MARK: - Series Detail View (TV Shows)

struct TVSeriesDetailView: View {
    let server: ServerConfig
    let node: TVMediaLibraryNode
    let initialSeasonId: String?
    let initialEpisodeId: String?
    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var seasonFocusNamespace
    @FocusState private var focusedSeasonId: String?
    private let downloadCenter = DownloadCenterService.shared
    private let playbackCoordinator = TVPlaybackCoordinator.shared

    @State private var seasonNodes: [TVMediaLibraryNode] = []
    @State private var selectedSeasonId: String?
    @State private var episodeNodes: [TVMediaLibraryNode] = []
    @State private var isLoading = false
    @State private var isLoadingEpisodes = false
    @State private var episodeErrorMessage: String?
    @State private var seasonLoadTask: Task<Void, Never>?
    @State private var episodeLoadTask: Task<Void, Never>?

    init(
        server: ServerConfig,
        node: TVMediaLibraryNode,
        initialSeasonId: String? = nil,
        initialEpisodeId: String? = nil
    ) {
        self.server = server
        self.node = node
        self.initialSeasonId = initialSeasonId
        self.initialEpisodeId = initialEpisodeId
    }

    private var displayTitle: String {
        tvDisplayTitle(from: node.name, type: node.type)
    }

    private var selectedSeason: TVMediaLibraryNode? {
        seasonNodes.first(where: { $0.id == selectedSeasonId })
    }

    private var selectedSeasonTitle: String? {
        selectedSeason.map { tvDisplayTitle(from: $0.name, type: .folder) }
    }

    private var offlineSeasonScopeId: String? {
        selectedSeasonId ?? initialSeasonId
    }

    private var offlineEpisodePlaylist: [VideoFile] {
        tvDownloadedLibraryPlaybackFiles(
            server: server,
            seriesId: node.id,
            seasonId: offlineSeasonScopeId,
            downloadCenter: downloadCenter
        )
    }

    private var primaryEpisodeFile: VideoFile? {
        let episode = initialEpisodeId.flatMap { episodeId in
            episodeNodes.first(where: { $0.id == episodeId })
        } ?? episodeNodes.first
        if let file = episode.flatMap({ tvPlayableLibraryFile(server: server, node: $0) }) {
            return file
        }
        if let initialEpisodeId,
           let file = tvDownloadedLibraryPlaybackFiles(
            server: server,
            itemId: initialEpisodeId,
            downloadCenter: downloadCenter
           ).first {
            return file
        }
        return offlineEpisodePlaylist.first
    }

    private var playableEpisodePlaylist: [VideoFile] {
        let loadedPlaylist = episodeNodes.compactMap { tvPlayableLibraryFile(server: server, node: $0) }
        return loadedPlaylist.isEmpty ? offlineEpisodePlaylist : loadedPlaylist
    }

    private var currentEpisodePlaylist: [VideoFile]? {
        let playlist = playableEpisodePlaylist
        return playlist.isEmpty ? nil : playlist
    }

    private var initialContentScrollTargetID: String? {
        if initialEpisodeId != nil {
            return episodeNodes.isEmpty ? nil : "tv-series-target-episodes"
        }
        if initialSeasonId != nil {
            return seasonNodes.isEmpty ? nil : "tv-series-target-seasons"
        }
        return nil
    }

    var body: some View {
        TVPageScrollView(
            title: displayTitle,
            subtitle: nil,
            handlesExitCommand: true,
            showsTitle: false,
            topPadding: 0,
            scrollTargetID: initialContentScrollTargetID,
            showsHomeAction: true,
            showsDownloadsAction: true
        ) {
            TVFullBleedHeroRow(height: TVLibraryLeafCinematicHero.heroHeight) {
                TVLibraryLeafCinematicHero(
                    server: server,
                    node: node,
                    playableFile: primaryEpisodeFile,
                    downloadNodes: episodeNodes,
                    downloadGroupTitle: selectedSeasonTitle ?? displayTitle,
                    onPlay: { file in
                        playbackCoordinator.play(file: file, playlist: currentEpisodePlaylist)
                    }
                )
            }

            if isLoading && seasonNodes.isEmpty {
                TVInfoPanel(
                    title: platformShellString("Platform Shell TV Loading"),
                    message: displayTitle,
                    systemImageName: "hourglass"
                )
            }

            if !seasonNodes.isEmpty {
                TVSeriesSeasonPickerSection(
                    seasons: seasonNodes,
                    selectedSeasonId: selectedSeasonId,
                    shouldFocusSelectedSeason: initialSeasonId != nil && initialEpisodeId == nil,
                    focusNamespace: seasonFocusNamespace,
                    focusedSeasonId: $focusedSeasonId,
                    onFocusSeason: { _ in },
                    onSelectSeason: selectSeason,
                    onDownloadSeason: downloadSelectedSeason
                )
                .id("tv-series-target-seasons")
            }

            if isLoadingEpisodes {
                TVInfoPanel(
                    title: platformShellString("Platform Shell TV Detail Episodes"),
                    message: selectedSeasonTitle ?? displayTitle,
                    systemImageName: "hourglass"
                )
            } else if let episodeErrorMessage {
                TVInfoPanel(
                    title: platformShellString("Connection Failed"),
                    message: episodeErrorMessage,
                    systemImageName: "exclamationmark.triangle.fill",
                    tintColor: .red
                )
            } else if !episodeNodes.isEmpty {
                TVSeriesEpisodeShelfSection(
                    episodes: episodeNodes,
                    server: server,
                    selectedSeasonTitle: selectedSeasonTitle,
                    selectedEpisodeId: initialEpisodeId,
                    shouldFocusSelectedEpisode: initialEpisodeId != nil,
                    onMoveUpToSelectedSeason: focusSelectedSeason,
                    onPlayEpisode: playEpisode,
                    onPlayEpisodeFromBeginning: playEpisodeFromBeginning,
                    onTogglePlayed: { episode in Task { await togglePlayed(episode) } },
                    onDownloadSeason: {
                        if let selectedSeason = selectedSeason {
                            downloadSelectedSeason(selectedSeason)
                        }
                    }
                )
                .id("tv-series-target-episodes")
            } else if selectedSeasonId != nil && !isLoading {
                TVInfoPanel(
                    title: platformShellString("Platform Shell TV Detail Episodes"),
                    message: platformShellString("Platform Shell TV Detail No Items"),
                    systemImageName: "film"
                )
            }

            if !node.people.isEmpty {
                TVCastShelfSection(people: node.people, server: server)
            }

            TVSimilarItemsSection(server: server, node: node)

            Button(action: {}) {
                TVLibraryLeafInfoGrid(node: node, server: server)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(TVFocusableSectionButtonStyle())
            .tvDisableSystemFocusEffect()
        }
        .navigationTitle(Text(displayTitle))
        .onAppear { loadSeasons() }
        .onDisappear {
            seasonLoadTask?.cancel()
            episodeLoadTask?.cancel()
        }
    }

    private func loadSeasons() {
        guard seasonNodes.isEmpty, !isLoading else { return }
        isLoading = true
        seasonLoadTask?.cancel()

        seasonLoadTask = Task {
            do {
                let fetched = try await tvFetchMediaLibraryNodes(server: server, parentNode: node)
                if Task.isCancelled { return }
                await MainActor.run {
                    seasonNodes = fetched
                    isLoading = false
                    if selectedSeasonId == nil {
                        let targetSeason = initialSeasonId.flatMap { seasonId in
                            fetched.first(where: { $0.id == seasonId })
                        } ?? fetched.first
                        if let targetSeason {
                            selectedSeasonId = targetSeason.id
                            loadEpisodes(for: targetSeason)
                        }
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    seasonNodes = []
                    episodeNodes = []
                    isLoading = false
                }
            }
        }
    }

    private func selectSeason(_ season: TVMediaLibraryNode) {
        if selectedSeasonId == season.id {
            if episodeNodes.isEmpty && !isLoadingEpisodes {
                loadEpisodes(for: season)
            }
            return
        }
        episodeLoadTask?.cancel()
        selectedSeasonId = season.id
        episodeNodes = []
        episodeErrorMessage = nil
        loadEpisodes(for: season)
    }

    private func playEpisode(_ episode: TVMediaLibraryNode) {
        guard let file = tvPlayableLibraryFile(server: server, node: episode) else { return }
        playbackCoordinator.play(file: file, playlist: currentEpisodePlaylist)
    }

    private func focusSelectedSeason() {
        guard let selectedSeasonId = selectedSeasonId else { return }
        focusedSeasonId = selectedSeasonId
        for delay in [0.0, 0.08, 0.20] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                resetFocus(in: seasonFocusNamespace)
            }
        }
    }

    private func loadEpisodes(for season: TVMediaLibraryNode) {
        episodeLoadTask?.cancel()
        episodeErrorMessage = nil
        isLoadingEpisodes = true

        episodeLoadTask = Task {
            do {
                let fetched = try await tvFetchMediaLibraryNodes(server: server, parentNode: season)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard selectedSeasonId == season.id else { return }
                    episodeNodes = fetched.filter { !$0.isFolder || $0.rawItemType.lowercased() == "episode" }
                    isLoadingEpisodes = false
                    episodeErrorMessage = nil
                    episodeLoadTask = nil
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    guard selectedSeasonId == season.id else { return }
                    episodeNodes = []
                    isLoadingEpisodes = false
                    episodeErrorMessage = error.localizedDescription
                    episodeLoadTask = nil
                }
            }
        }
    }

    private func playEpisodeFromBeginning(_ episode: TVMediaLibraryNode) {
        guard var file = tvPlayableLibraryFile(server: server, node: episode) else { return }
        file.lastPlayedPosition = 0
        file.shouldResetRemotePlayedStateOnPlaybackStart = true
        playbackCoordinator.play(file: file, playlist: currentEpisodePlaylist)
    }

    private func togglePlayed(_ episode: TVMediaLibraryNode) async {
        let nextValue = !(episode.isPlayed ?? false)
        do {
            try await tvSetMediaLibraryPlayed(server: server, itemId: episode.id, isPlayed: nextValue)
            await MainActor.run {
                if let index = episodeNodes.firstIndex(where: { $0.id == episode.id }) {
                    episodeNodes[index].isPlayed = nextValue
                    if nextValue {
                        episodeNodes[index].playbackProgress = nil
                        episodeNodes[index].playbackPositionSeconds = nil
                    }
                }
            }
            PlaybackRefreshCenter.updateRemoteItem(
                serverId: server.id,
                itemId: episode.id,
                seriesId: episode.seriesId,
                seasonId: episode.seasonId,
                snapshot: RemotePlaybackStateSnapshot.manualPlayedState(
                    played: nextValue,
                    runtimeTicks: episode.runtimeTicks
                )
            )
        } catch {
            // Ignore
        }
    }

    private func downloadSelectedSeason(_ season: TVMediaLibraryNode) {
        let nodesToQueue = episodeNodes.filter {
            tvMediaLibraryCanQueueDownload(server: server, node: $0, downloadCenter: downloadCenter)
        }
        guard !nodesToQueue.isEmpty else { return }

        let groupTitle = tvDisplayTitle(from: season.name, type: .folder)
        let collectionId = season.id

        let job = DownloadJobDescriptor(
            kind: .seasonPack,
            sourceType: DownloadSourceType(serverType: server.type),
            title: groupTitle,
            groupTitle: groupTitle,
            collectionId: collectionId,
            seriesId: node.id,
            seasonId: season.id
        )

        let entries = nodesToQueue.enumerated().compactMap { index, downloadNode in
            tvMediaLibraryDownloadBatchItem(
                server: server,
                node: downloadNode,
                collectionId: collectionId,
                groupIndex: index
            )
        }

        _ = downloadCenter.enqueueMediaBatch(server: server, items: entries, job: job)
    }
}

// MARK: - Series Seasons / Episodes

private struct TVSeriesSeasonPickerSection: View {
    let seasons: [TVMediaLibraryNode]
    let selectedSeasonId: String?
    let shouldFocusSelectedSeason: Bool
    let focusNamespace: Namespace.ID
    @FocusState.Binding var focusedSeasonId: String?
    let onFocusSeason: (TVMediaLibraryNode) -> Void
    let onSelectSeason: (TVMediaLibraryNode) -> Void
    let onDownloadSeason: (TVMediaLibraryNode) -> Void

    @Environment(\.resetFocus) private var resetFocus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .center, spacing: 14) {
                        ForEach(seasons) { season in
                            Button(action: { onSelectSeason(season) }) {
                                TVSeasonPickerCard(
                                    season: season,
                                    isSelected: selectedSeasonId == season.id,
                                    onFocusChange: { focused in
                                        if focused {
                                            onFocusSeason(season)
                                        }
                                    }
                                )
                            }
                            .id(season.id)
                            .focused($focusedSeasonId, equals: season.id)
                            .prefersDefaultFocus(selectedSeasonId == season.id, in: focusNamespace)
                            .onAppear {
                                guard shouldFocusSelectedSeason && selectedSeasonId == season.id else { return }
                                requestSelectedSeasonFocus()
                            }
                            .contextMenu {
                                if selectedSeasonId == season.id {
                                    Button(action: { onDownloadSeason(season) }) {
                                        Label(platformShellString("Download Season"), systemImage: "arrow.down.circle")
                                    }
                                }
                            }
                            .buttonStyle(TVPlainButtonStyle())
                            .tvDisableSystemFocusEffect()
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                }
                .tvFocusSectionIfAvailable()
                .padding(.horizontal, -22)
                .onAppear {
                    scrollToSelectedSeason(using: proxy, animated: false)
                    requestSelectedSeasonFocus()
                    if focusedSeasonId == nil {
                        focusedSeasonId = selectedSeasonId
                    }
                }
                .onChange(of: selectedSeasonId ?? "") { newId in
                    scrollToSelectedSeason(using: proxy, animated: true)
                    requestSelectedSeasonFocus()
                    if !newId.isEmpty {
                        focusedSeasonId = newId
                    }
                }
            }
        }
        .focusScope(focusNamespace)
    }

    private func scrollToSelectedSeason(using proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedSeasonId else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.20)) {
                proxy.scrollTo(selectedSeasonId, anchor: .center)
            }
        } else {
            proxy.scrollTo(selectedSeasonId, anchor: .center)
        }
    }

    private func requestSelectedSeasonFocus() {
        guard shouldFocusSelectedSeason, selectedSeasonId != nil else { return }
        for delay in [0.0, 0.12, 0.35, 0.70] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                resetFocus(in: focusNamespace)
            }
        }
    }
}

private struct TVSeasonPickerCard: View {
    let season: TVMediaLibraryNode
    let isSelected: Bool
    let onFocusChange: (Bool) -> Void
    @Environment(\.isFocused) private var isFocused

    private var title: String {
        tvDisplayTitle(from: season.name, type: .folder)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title)
                .font(.system(size: 24, weight: .heavy))
                .foregroundColor(foregroundColor)
                .lineLimit(1)
                .minimumScaleFactor(0.70)
        }
        .frame(height: 58, alignment: .center)
        .frame(minWidth: 144, alignment: .center)
        .padding(.horizontal, 22)
        .contentShape(Capsule(style: .continuous))
        .background(
            Capsule(style: .continuous)
                .fill(backgroundFill)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(borderColor, lineWidth: isFocused || isSelected ? 2 : 1)
        )
        .scaleEffect(isFocused ? 1.035 : 1.0)
        .shadow(color: Color.black.opacity(isFocused ? 0.24 : 0.06), radius: isFocused ? 14 : 4, x: 0, y: isFocused ? 7 : 2)
        .onChange(of: isFocused, perform: onFocusChange)
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .animation(.easeOut(duration: 0.16), value: isSelected)
    }

    private var foregroundColor: Color {
        isFocused ? .black.opacity(0.90) : .white.opacity(isSelected ? 0.98 : 0.84)
    }

    private var backgroundFill: Color {
        if isFocused {
            return Color.white.opacity(0.94)
        }
        if isSelected {
            return Color.white.opacity(0.22)
        }
        return Color.clear
    }

    private var borderColor: Color {
        if isFocused {
            return Color.white.opacity(0.98)
        }
        if isSelected {
            return Color.white.opacity(0.36)
        }
        return Color.clear
    }
}

private struct TVSeasonDownloadButtonLabel: View {
    let state: DownloadAggregateState

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var title: String {
        switch state {
        case .downloaded:
            return platformShellString("Downloaded")
        case .queued, .downloading:
            return platformShellString("Downloading...")
        case .partiallyDownloaded(let completed, let total):
            return "\(platformShellString("Download Remaining")) (\(completed)/\(total))"
        case .failed:
            return platformShellString("Retry Download")
        default:
            return platformShellString("Download Season")
        }
    }

    private var iconName: String {
        switch state {
        case .downloaded:
            return "arrow.down.circle.fill"
        case .queued, .downloading, .partiallyDownloaded:
            return "arrow.down.circle"
        case .failed:
            return "arrow.clockwise.circle"
        default:
            return "arrow.down.circle"
        }
    }

    private var tintColor: Color {
        switch state {
        case .downloaded:
            return Color(red: 0.42, green: 0.88, blue: 0.58)
        case .queued, .downloading, .partiallyDownloaded:
            return TVShellStyle.accentSoft
        case .failed:
            return Color(red: 1.0, green: 0.48, blue: 0.40)
        default:
            return .white
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: iconName)
                .font(.system(size: 25, weight: .bold))

            if isFocused || !isEnabled {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .transition(.opacity)
            }
        }
        .foregroundColor(isEnabled ? (isFocused ? .black : tintColor) : (tintColor != .white ? tintColor : TVShellStyle.secondary.opacity(0.45)))
        .padding(.horizontal, isFocused || !isEnabled ? 24 : 0)
        .frame(height: 70)
        .frame(minWidth: isFocused || !isEnabled ? nil : 88)
        .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(isFocused ? Color.white : Color.white.opacity(isEnabled ? 0.10 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(Color.white.opacity(isFocused ? 0.0 : 0.18), lineWidth: 1)
        )
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(
            color: isFocused ? Color.black.opacity(0.30) : Color.black.opacity(0.06),
            radius: isFocused ? 16 : 7,
            x: 0,
            y: isFocused ? 8 : 4
        )
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct TVSeasonDownloadButton: View {
    let server: ServerConfig
    let episodes: [TVMediaLibraryNode]
    let action: () -> Void

    private let downloadCenter = DownloadCenterService.shared
    @State private var state: DownloadAggregateState = .notDownloaded

    private func updateState() {
        let newState = tvMediaLibraryDownloadAggregateState(server: server, nodes: episodes, downloadCenter: downloadCenter)
        if state != newState {
            state = newState
        }
    }

    var body: some View {
        Button(action: action) {
            TVSeasonDownloadButtonLabel(state: state)
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
        .disabled(state == .downloaded)
        .onAppear {
            updateState()
        }
        .onReceive(downloadCenter.objectWillChange) { _ in
            updateState()
        }
    }
}

private struct TVSeriesEpisodeShelfSection: View {
    let episodes: [TVMediaLibraryNode]
    let server: ServerConfig
    let selectedSeasonTitle: String?
    let selectedEpisodeId: String?
    let shouldFocusSelectedEpisode: Bool
    let onMoveUpToSelectedSeason: () -> Void
    let onPlayEpisode: (TVMediaLibraryNode) -> Void
    let onPlayEpisodeFromBeginning: (TVMediaLibraryNode) -> Void
    let onTogglePlayed: (TVMediaLibraryNode) -> Void
    let onDownloadSeason: () -> Void

    @Environment(\.resetFocus) private var resetFocus
    @Namespace private var episodeFocusNamespace
    private let downloadCenter = DownloadCenterService.shared

    private func downloadEpisode(_ episode: TVMediaLibraryNode) {
        guard tvMediaLibraryCanQueueDownload(server: server, node: episode, downloadCenter: downloadCenter) else { return }

        let job = DownloadJobDescriptor(
            kind: .singleMedia,
            sourceType: DownloadSourceType(serverType: server.type),
            title: tvDisplayTitle(from: episode.name, type: episode.type),
            groupTitle: nil,
            collectionId: episode.id,
            seriesId: episode.seriesId,
            seasonId: episode.seasonId
        )

        guard let entry = tvMediaLibraryDownloadBatchItem(
            server: server,
            node: episode,
            collectionId: episode.id,
            groupIndex: 0
        ) else { return }

        _ = downloadCenter.enqueueMediaBatch(server: server, items: [entry], job: job)
    }

    private func cancelOrDeleteEpisodeDownload(_ episode: TVMediaLibraryNode) {
        let status = tvMediaLibraryDownloadStatus(server: server, node: episode, downloadCenter: downloadCenter)
        guard let status = status else { return }

        let task: DownloadTaskItem?
        switch server.type {
        case .plex:
            guard let remotePath = tvMediaLibraryDownloadRemotePath(server: server, node: episode) else { return }
            task = downloadCenter.tasks.first(where: { $0.serverId == server.id && $0.remotePath == remotePath })
        case .jellyfin, .emby:
            task = downloadCenter.tasks.first(where: { $0.serverId == server.id && $0.remoteItemId == episode.id })
        default:
            task = nil
        }

        guard let taskId = task?.id else { return }

        if status == .completed {
            downloadCenter.removeRecord(taskId, deleteLocalFile: true)
        } else {
            downloadCenter.cancel(taskId)
            downloadCenter.removeRecord(taskId, deleteLocalFile: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 24) {
                HStack(alignment: .center, spacing: 18) {
                    Text(platformShellString("Platform Shell TV Detail Episodes"))
                        .font(.title3.weight(.bold))
                        .foregroundColor(TVShellStyle.primary)

                    if !episodes.isEmpty {
                        TVSeasonDownloadButton(
                            server: server,
                            episodes: episodes,
                            action: onDownloadSeason
                        )
                        .onMoveCommand { direction in
                            if direction == .up {
                                onMoveUpToSelectedSeason()
                            }
                        }
                    }
                }

                Spacer()

                if let selectedSeasonTitle, !selectedSeasonTitle.isEmpty {
                    Text(selectedSeasonTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(TVShellStyle.secondary)
                        .lineLimit(1)
                }
            }
            .tvFocusSectionIfAvailable()

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 40) {
                        ForEach(episodes) { episode in
                            Button(action: { onPlayEpisode(episode) }) {
                                TVSeriesEpisodeCard(
                                    server: server,
                                    node: episode,
                                    isSelected: episode.id == selectedEpisodeId
                                )
                            }
                            .id(episode.id)
                            .prefersDefaultFocus(shouldFocusSelectedEpisode && episode.id == selectedEpisodeId, in: episodeFocusNamespace)
                            .onAppear {
                                guard shouldFocusSelectedEpisode && episode.id == selectedEpisodeId else { return }
                                requestSelectedEpisodeFocus()
                            }
                            .contextMenu {
                                Button(action: { onPlayEpisode(episode) }) {
                                    Label(platformShellString("Play"), systemImage: "play.fill")
                                }

                                if let progress = episode.playbackProgress, progress > 0 {
                                    Button(action: { onPlayEpisodeFromBeginning(episode) }) {
                                        Label(platformShellString("Platform Shell TV Detail Play From Beginning"), systemImage: "arrow.counterclockwise")
                                    }
                                }

                                Divider()

                                if let status = tvMediaLibraryDownloadStatus(server: server, node: episode, downloadCenter: downloadCenter) {
                                    if status == .completed {
                                        Button(action: { cancelOrDeleteEpisodeDownload(episode) }) {
                                            Label(platformShellString("Delete Download"), systemImage: "trash")
                                        }
                                    } else {
                                        Button(action: { cancelOrDeleteEpisodeDownload(episode) }) {
                                            Label(platformShellString("Cancel Download"), systemImage: "xmark.circle")
                                        }
                                    }
                                } else {
                                    Button(action: { downloadEpisode(episode) }) {
                                        Label(platformShellString("Download"), systemImage: "arrow.down.circle")
                                    }
                                }

                                Divider()

                                Button(action: { onTogglePlayed(episode) }) {
                                    let isPlayed = episode.isPlayed ?? false
                                    Label(
                                        platformShellString(isPlayed ? "Platform Shell TV Detail Mark Unwatched" : "Platform Shell TV Detail Mark Watched"),
                                        systemImage: isPlayed ? "checkmark.circle.fill" : "checkmark.circle"
                                    )
                                }
                            }
                            .buttonStyle(TVPlainButtonStyle())
                            .tvDisableSystemFocusEffect()
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 28)
                }
                .tvFocusSectionIfAvailable()
                .padding(.horizontal, -22)
                .onAppear {
                    scrollToSelectedEpisode(using: proxy, animated: false)
                    requestSelectedEpisodeFocus()
                }
                .onChange(of: selectedEpisodeId ?? "") { _ in
                    scrollToSelectedEpisode(using: proxy, animated: true)
                    requestSelectedEpisodeFocus()
                }
                .onChange(of: episodes.map(\.id).joined(separator: "|")) { _ in
                    scrollToSelectedEpisode(using: proxy, animated: true)
                    requestSelectedEpisodeFocus()
                }
            }
        }
        .focusScope(episodeFocusNamespace)
    }

    private func scrollToSelectedEpisode(using proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedEpisodeId,
              episodes.contains(where: { $0.id == selectedEpisodeId }) else {
            return
        }
        if animated {
            withAnimation(.easeOut(duration: 0.20)) {
                proxy.scrollTo(selectedEpisodeId, anchor: .center)
            }
        } else {
            proxy.scrollTo(selectedEpisodeId, anchor: .center)
        }
    }

    private func requestSelectedEpisodeFocus() {
        guard shouldFocusSelectedEpisode,
              let selectedEpisodeId,
              episodes.contains(where: { $0.id == selectedEpisodeId }) else {
            return
        }

        for delay in [0.0, 0.12, 0.35, 0.70] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                resetFocus(in: episodeFocusNamespace)
            }
        }
    }
}

private struct TVEpisodeDownloadBadge: View {
    let status: DownloadTaskStatus

    var body: some View {
        ZStack {
            Circle()
                .fill(backgroundColor.opacity(0.85))
                .frame(width: 36, height: 36)
                .shadow(radius: 4)

            Image(systemName: iconName)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(foregroundColor)
        }
    }

    private var backgroundColor: Color {
        switch status {
        case .completed:
            return Color(red: 0.1, green: 0.6, blue: 0.1)
        case .downloading, .queued, .paused:
            return TVShellStyle.accentSoft
        case .failed:
            return Color(red: 0.8, green: 0.2, blue: 0.2)
        default:
            return .black
        }
    }

    private var foregroundColor: Color {
        .white
    }

    private var iconName: String {
        switch status {
        case .completed:
            return "arrow.down"
        case .downloading:
            return "arrow.down"
        case .queued:
            return "clock"
        case .paused:
            return "pause"
        case .failed:
            return "exclamationmark"
        default:
            return ""
        }
    }
}

private struct TVSeriesEpisodeCard: View {
    let server: ServerConfig
    let node: TVMediaLibraryNode
    var isSelected: Bool = false
    @Environment(\.isFocused) private var isFocused
    private let downloadCenter = DownloadCenterService.shared
    @State private var downloadStatus: DownloadTaskStatus? = nil

    private let cardWidth: CGFloat = 390
    private let artworkHeight: CGFloat = 219
    private let detailHeight: CGFloat = 132
    private let cornerRadius: CGFloat = 16

    private var title: String {
        tvDisplayTitle(from: node.name, type: node.type)
    }

    private var episodeNumberText: String? {
        guard let episode = node.indexNumber else { return nil }
        return "\(platformShellString("Platform Shell TV Detail Episode")) \(episode)"
    }

    private var summaryText: String? {
        guard let summary = node.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return nil
        }
        return summary
    }

    private var durationText: String? {
        tvDurationText(ticks: node.runtimeTicks)
    }

    private var metadataText: String {
        var tokens: [String] = []
        if let dateText = tvMediaLibraryDisplayDateText(for: node) {
            tokens.append(dateText)
        }
        if let rating = node.rating, !rating.isEmpty {
            tokens.append(rating)
        } else if let communityRating = node.communityRating, communityRating > 0 {
            tokens.append(String(format: "%.1f", communityRating))
        }
        return tokens.isEmpty
            ? (node.metadataLine ?? platformShellString("Platform Shell TV Detail Episode"))
            : tokens.joined(separator: " • ")
    }

    private func updateDownloadStatus() {
        let newStatus = tvMediaLibraryDownloadStatus(server: server, node: node, downloadCenter: downloadCenter)
        if downloadStatus != newStatus {
            downloadStatus = newStatus
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                TVRemoteArtworkView(
                    url: node.backdropURL ?? node.posterURL,
                    server: server,
                    placeholderSystemImageName: node.type.tvSystemImageName
                )
                .aspectRatio(16.0/9.0, contentMode: .fill)
                .frame(width: cardWidth, height: artworkHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.clear,
                        Color.black.opacity(0.64)
                    ]),
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                if let progress = node.playbackProgress, progress > 0 {
                    TVMediaPlaybackProgressBadge(
                        progress: progress,
                        systemImageName: "play.fill",
                        diameter: 42
                    )
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if let downloadStatus {
                    TVEpisodeDownloadBadge(status: downloadStatus)
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                if let durationText {
                    TVEpisodeDurationBadge(text: durationText)
                        .padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
            .frame(width: cardWidth, height: artworkHeight)
            .tvFocusedPosterArtwork(cornerRadius: cornerRadius)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(isSelected ? 0.42 : 0), lineWidth: isSelected ? 1.5 : 0)
            )
            .shadow(color: Color.black.opacity(isFocused ? 0.32 : 0.20), radius: isFocused ? 20 : 14, x: 0, y: isFocused ? 13 : 8)

            VStack(alignment: .leading, spacing: 5) {
                if let episodeNumberText {
                    Text(episodeNumberText)
                        .font(.system(size: 16, weight: .heavy))
                        .foregroundColor(detailSecondaryColor)
                        .lineLimit(1)
                }

                Text(title)
                    .font(.system(size: 19, weight: .heavy))
                    .foregroundColor(detailPrimaryColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let summaryText {
                    Text(summaryText)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(detailSecondaryColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Text(metadataText)
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundColor(detailSecondaryColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(width: cardWidth, height: detailHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(detailBackgroundFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(detailBorderColor, lineWidth: isFocused || isSelected ? 1 : 0)
            )
        }
        .frame(width: cardWidth, height: artworkHeight + 12 + detailHeight, alignment: .topLeading)
        .tvPosterShelfCard(width: cardWidth, minHeight: artworkHeight + 12 + detailHeight, focusedScale: 1.036)
        .onAppear {
            updateDownloadStatus()
        }
        .onReceive(downloadCenter.objectWillChange) { _ in
            updateDownloadStatus()
        }
    }

    private var detailPrimaryColor: Color {
        isFocused ? .white : .white.opacity(isSelected ? 0.96 : 0.86)
    }

    private var detailSecondaryColor: Color {
        isFocused ? .white.opacity(0.76) : .white.opacity(isSelected ? 0.68 : 0.48)
    }

    private var detailBackgroundFill: Color {
        if isFocused {
            return Color.white.opacity(0.115)
        }
        if isSelected {
            return Color.white.opacity(0.075)
        }
        return Color.clear
    }

    private var detailBorderColor: Color {
        if isFocused {
            return Color.white.opacity(0.18)
        }
        if isSelected {
            return Color.white.opacity(0.12)
        }
        return Color.clear
    }
}

private struct TVEpisodeDurationBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 18, weight: .heavy))
            .foregroundColor(.white.opacity(0.95))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.42))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 4)
    }
}

// MARK: - Cast Shelf

private struct TVCastShelfSection: View {
    let people: [TVMediaLibraryPerson]
    let server: ServerConfig

    private var displayPeople: [TVMediaLibraryPerson] {
        var seen = Set<String>()
        let prioritized = people.sorted { lhs, rhs in
            let lhsPriority = tvPersonDisplayPriority(lhs.type)
            let rhsPriority = tvPersonDisplayPriority(rhs.type)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        return Array(prioritized.filter { person in
            let key = person.id.isEmpty ? person.name : person.id
            return seen.insert(key).inserted
        }.prefix(24))
    }

    var body: some View {
        if !displayPeople.isEmpty {
            TVShelfSection(
                title: platformShellString("Platform Shell TV Detail Cast"),
                subtitle: nil
            ) {
                ForEach(displayPeople) { person in
                    NavigationLink(
                        destination: TVPersonDetailView(server: server, person: person)
                    ) {
                        TVCastPersonCard(person: person, server: server)
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
            }
        }
    }
}

private struct TVCastPersonCard: View {
    let person: TVMediaLibraryPerson
    let server: ServerConfig
    @Environment(\.isFocused) private var isFocused

    private let artworkSize: CGFloat = 150
    private let cornerRadius: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .frame(width: artworkSize, height: artworkSize)

                if let imageURL = person.imageURL {
                    TVRemoteArtworkView(
                        url: imageURL,
                        server: server,
                        placeholderSystemImageName: "person.fill"
                    )
                    .frame(width: artworkSize, height: artworkSize)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 44, weight: .medium))
                        .foregroundColor(.white.opacity(0.32))
                }
            }
            .frame(width: artworkSize, height: artworkSize)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .tvFocusedPosterArtwork(cornerRadius: cornerRadius)
            .shadow(color: Color.black.opacity(isFocused ? 0.36 : 0.14), radius: isFocused ? 16 : 5, y: isFocused ? 9 : 3)

            VStack(alignment: .leading, spacing: 3) {
                Text(person.name)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(isFocused ? .white : .white.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let role = person.role, !role.isEmpty {
                    Text(role)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(isFocused ? .white.opacity(0.70) : .white.opacity(0.46))
                        .lineLimit(1)
                } else {
                    Text(tvLocalizedPersonType(person.type))
                        .font(.caption2.weight(.medium))
                        .foregroundColor(isFocused ? .white.opacity(0.70) : .white.opacity(0.46))
                        .lineLimit(1)
                }
            }
            .frame(width: artworkSize, height: 48, alignment: .topLeading)
        }
        .frame(width: 166, height: 218, alignment: .topLeading)
        .scaleEffect(isFocused ? 1.035 : 1.0)
        .animation(.easeOut(duration: 0.16), value: isFocused)
    }
}

private func tvLocalizedPersonType(_ type: String) -> String {
    switch type.lowercased() {
    case "director": return platformShellString("Platform Shell TV Detail Director")
    case "writer": return platformShellString("Platform Shell TV Detail Writer")
    case "producer": return platformShellString("Platform Shell TV Detail Producer")
    default: return platformShellString("Platform Shell TV Detail Actor")
    }
}

private func tvPersonDisplayPriority(_ type: String) -> Int {
    switch type.lowercased() {
    case "actor": return 0
    case "director": return 1
    case "writer": return 2
    case "producer": return 3
    default: return 4
    }
}

// MARK: - Person Detail View

private struct TVPersonDetailView: View {
    let server: ServerConfig
    let person: TVMediaLibraryPerson

    @State private var filmographyNodes: [TVMediaLibraryNode] = []
    @State private var personDetails: TVMediaLibraryPersonDetails?
    @State private var isLoading = false
    @State private var isLoadingDetails = false
    @State private var detailsTask: Task<Void, Never>?
    @State private var filmographyTask: Task<Void, Never>?
    @State private var sortField: TVMediaLibrarySortField = .dateAdded
    @State private var sortOrder: TVMediaLibrarySortOrder = .descending

    private var sortPreferenceKey: String {
        "tvPersonSort.\(server.type.rawValue).\(server.id.uuidString).\(person.id)"
    }

    private var usesLocalSort: Bool {
        sortField == .releaseDate || sortField == .releaseYear
    }

    private var filmographyFetchLimit: Int {
        usesLocalSort ? 100 : 50
    }

    var body: some View {
        TVPageScrollView(
            title: person.name,
            subtitle: nil,
            handlesExitCommand: true,
            showsTitle: false,
            topChromeAccessory: AnyView(sortAccessoryButton),
            showsHomeAction: true
        ) {
            // ── Person header ──
            HStack(alignment: .top, spacing: 32) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: 200, height: 200)

                    if let imageURL = person.imageURL {
                        TVRemoteArtworkView(
                            url: imageURL,
                            server: server,
                            placeholderSystemImageName: "person.fill"
                        )
                        .frame(width: 200, height: 200)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: 72, weight: .medium))
                            .foregroundColor(.white.opacity(0.32))
                    }
                }
                .shadow(color: Color.black.opacity(0.30), radius: 20, y: 10)

                VStack(alignment: .leading, spacing: 8) {
                    Text(person.name)
                        .font(.system(size: 42, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    Text(tvLocalizedPersonType(person.type))
                        .font(.title3.weight(.medium))
                        .foregroundColor(.white.opacity(0.56))

                    if let role = person.role, !role.isEmpty {
                        Text(role)
                            .font(.headline.weight(.medium))
                            .foregroundColor(.white.opacity(0.46))
                            .lineLimit(2)
                    }

                    if let details = personDetails, !details.detailRows.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(details.detailRows.enumerated()), id: \.offset) { entry in
                                let row = entry.element
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(platformShellString(row.key))
                                        .font(.caption.weight(.semibold))
                                        .foregroundColor(.white.opacity(0.44))
                                    Text(row.value)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundColor(.white.opacity(0.78))
                                        .lineLimit(2)
                                }
                            }
                        }
                        .padding(.top, 8)
                    }
                }
                .padding(.top, 16)
            }
            .padding(.bottom, 8)

            if let biography = personDetails?.biography {
                VStack(alignment: .leading, spacing: 12) {
                    Text(platformShellString("Platform Shell TV Detail Biography"))
                        .font(.title3.weight(.bold))
                        .foregroundColor(TVShellStyle.primary)

                    Text(biography)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(.white.opacity(0.76))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 1180, alignment: .leading)
            } else if isLoadingDetails {
                TVInfoPanel(
                    title: platformShellString("Platform Shell TV Detail Biography"),
                    message: person.name,
                    systemImageName: "hourglass"
                )
            }

            // ── Filmography ──
            if isLoading && filmographyNodes.isEmpty {
                TVInfoPanel(
                    title: platformShellString("Platform Shell TV Loading"),
                    message: person.name,
                    systemImageName: "hourglass"
                )
            }

            if !filmographyNodes.isEmpty {
                TVShelfSection(
                    title: platformShellString("Platform Shell TV Detail Filmography"),
                    subtitle: nil
                ) {
                    ForEach(filmographyNodes) { node in
                        NavigationLink(
                            destination: tvMediaLibraryDestination(server: server, node: node)
                        ) {
                            TVMediaLibraryPosterCard(server: server, node: node)
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                    }
                }
            } else if !isLoading {
                TVEmptyStateCard(
                    title: person.name,
                    message: platformShellString("Platform Shell TV Detail No Items"),
                    systemImageName: "film"
                )
                .tvGridCard()
            }
        }
        .navigationTitle(Text(person.name))
        .onAppear {
            loadSavedSortPreference()
            loadDetails()
            loadFilmography()
        }
        .onDisappear {
            detailsTask?.cancel()
            detailsTask = nil
            filmographyTask?.cancel()
            filmographyTask = nil
        }
    }

    // MARK: - Sort Button

    @ViewBuilder
    private var sortAccessoryButton: some View {
        TVNavigationLink(
            destination: TVMediaLibrarySortView(
                sortField: $sortField,
                sortOrder: $sortOrder,
                onPreferenceChanged: {
                    saveSortPreference()
                    reloadFilmography()
                }
            )
        ) {
            TVTopChromeIconButton(
                title: platformShellString("Sort"),
                systemImageName: "line.3.horizontal.decrease.circle"
            )
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
    }

    // MARK: - Sort Persistence

    private func loadSavedSortPreference() {
        let defaults = UserDefaults.standard
        if let rawField = defaults.string(forKey: "\(sortPreferenceKey).by"),
           let field = TVMediaLibrarySortField(rawValue: rawField) {
            sortField = field
        }
        if let rawOrder = defaults.string(forKey: "\(sortPreferenceKey).order"),
           let order = TVMediaLibrarySortOrder(rawValue: rawOrder) {
            sortOrder = order
        }
    }

    private func saveSortPreference() {
        let defaults = UserDefaults.standard
        defaults.set(sortField.rawValue, forKey: "\(sortPreferenceKey).by")
        defaults.set(sortOrder.rawValue, forKey: "\(sortPreferenceKey).order")
    }

    // MARK: - Data Loading

    private func loadDetails() {
        guard personDetails == nil, !isLoadingDetails else { return }
        isLoadingDetails = true
        detailsTask?.cancel()

        detailsTask = Task {
            do {
                let fetched = try await tvFetchPersonDetails(server: server, personId: person.id)
                if Task.isCancelled { return }
                await MainActor.run {
                    personDetails = fetched
                    isLoadingDetails = false
                    detailsTask = nil
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    personDetails = nil
                    isLoadingDetails = false
                    detailsTask = nil
                }
            }
        }
    }

    private func loadFilmography() {
        guard filmographyNodes.isEmpty, !isLoading else { return }
        startFilmographyTask()
    }

    private func reloadFilmography() {
        filmographyNodes = []
        startFilmographyTask()
    }

    private func startFilmographyTask() {
        isLoading = true
        filmographyTask?.cancel()

        filmographyTask = Task {
            do {
                let fetched = try await tvFetchPersonItems(
                    server: server,
                    personId: person.id,
                    sortBy: sortField.rawValue,
                    sortOrder: sortOrder.rawValue,
                    limit: filmographyFetchLimit
                )
                if Task.isCancelled { return }
                let sorted = localSortedNodes(fetched)
                await MainActor.run {
                    filmographyNodes = sorted
                    isLoading = false
                    filmographyTask = nil
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    filmographyNodes = []
                    isLoading = false
                    filmographyTask = nil
                }
            }
        }
    }

    // MARK: - Local Sort

    private func localSortedNodes(_ nodes: [TVMediaLibraryNode]) -> [TVMediaLibraryNode] {
        switch sortField {
        case .releaseDate:
            return sortedByInt(nodes) { tvPersonNodePremiereDateSortValue($0) }
        case .releaseYear:
            return sortedByInt(nodes) { $0.year }
        default:
            return nodes
        }
    }

    private func sortedByInt(
        _ nodes: [TVMediaLibraryNode],
        value: (TVMediaLibraryNode) -> Int?
    ) -> [TVMediaLibraryNode] {
        let isAscending = sortOrder == .ascending
        return nodes.sorted { lhs, rhs in
            let lhsValue = value(lhs)
            let rhsValue = value(rhs)
            if let l = lhsValue, let r = rhsValue, l != r {
                return isAscending ? l < r : l > r
            }
            if lhsValue != nil && rhsValue == nil { return true }
            if lhsValue == nil && rhsValue != nil { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

// MARK: - Person Sort Helpers

/// Extracts a sortable Int from a node's premiereDate string (e.g. "2023-07-15T00:00:00Z" → 20230715).
private func tvPersonNodePremiereDateSortValue(_ node: TVMediaLibraryNode) -> Int? {
    guard let raw = node.premiereDate else { return nil }
    let digits = raw.prefix(10).replacingOccurrences(of: "-", with: "")
    return Int(digits)
}

// MARK: - Similar Items Section

private struct TVSimilarItemsSection: View {
    let server: ServerConfig
    let node: TVMediaLibraryNode

    @State private var similarNodes: [TVMediaLibraryNode] = []
    @State private var didAttemptLoad = false
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading || !didAttemptLoad {
                TVInfoPanel(
                    title: platformShellString("Platform Shell TV Detail Similar"),
                    message: platformShellString("Platform Shell TV Loading"),
                    systemImageName: "hourglass"
                )
            } else if !similarNodes.isEmpty {
                TVShelfSection(
                    title: platformShellString("Platform Shell TV Detail Similar"),
                    subtitle: nil
                ) {
                    ForEach(similarNodes) { simNode in
                        NavigationLink(
                            destination: tvMediaLibraryDestination(server: server, node: simNode)
                        ) {
                            TVMediaLibraryPosterCard(server: server, node: simNode)
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                    }
                }
            } else if didAttemptLoad {
                TVInfoPanel(
                    title: platformShellString("Platform Shell TV Detail Similar"),
                    message: platformShellString("Platform Shell TV Detail No Items"),
                    systemImageName: "sparkles.tv"
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { loadSimilarIfNeeded() }
        .onDisappear { cancelLoadForRetryIfNeeded() }
    }

    private func loadSimilarIfNeeded() {
        guard !didAttemptLoad else { return }
        didAttemptLoad = true
        isLoading = true
        loadTask?.cancel()

        loadTask = Task {
            do {
                let fetched = try await tvFetchSimilarItems(server: server, node: node, limit: 12)
                if Task.isCancelled { return }
                await MainActor.run {
                    similarNodes = fetched
                    isLoading = false
                    loadTask = nil
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    similarNodes = []
                    isLoading = false
                    loadTask = nil
                }
            }
        }
    }

    private func cancelLoadForRetryIfNeeded() {
        loadTask?.cancel()
        loadTask = nil
        guard isLoading && similarNodes.isEmpty else { return }
        isLoading = false
        didAttemptLoad = false
    }
}

private struct TVLibraryLeafCinematicHero: View {
    let server: ServerConfig
    let node: TVMediaLibraryNode
    let playableFile: VideoFile?
    let downloadNodes: [TVMediaLibraryNode]
    let downloadGroupTitle: String?
    let onPlay: (VideoFile) -> Void

    static let heroHeight: CGFloat = 690
    private static let topBleed: CGFloat = 96
    private static let contentHorizontalPadding: CGFloat = TVPageContentMetrics.heroHorizontalPadding
    private let contentMaxWidth: CGFloat = 880

    private var title: String {
        tvDisplayTitle(from: node.name, type: node.type)
    }

    private var secondaryMetadataItems: [String] {
        var items: [String] = []
        if let dateText = tvMediaLibraryDisplayDateText(for: node) {
            items.append(dateText)
        }
        if let resolutionText = tvMediaLibraryResolutionText(for: node) {
            items.append(resolutionText)
        }
        if let childCountText {
            items.append(childCountText)
        }
        if items.isEmpty, let metadataLine = node.metadataLine, !metadataLine.isEmpty {
            items.append(metadataLine)
        }
        return items
    }

    private var childCountText: String? {
        guard let childCount = node.childCount, childCount > 0 else { return nil }
        if node.isSeries {
            let key = childCount == 1 ? "Platform Shell TV Detail Season" : "Platform Shell TV Detail Seasons"
            return "\(childCount) \(platformShellString(key))"
        }
        if node.isSeason {
            let key = childCount == 1 ? "Platform Shell TV Detail Episode" : "Platform Shell TV Detail Episodes"
            return "\(childCount) \(platformShellString(key))"
        }
        return nil
    }

    private var trimmedSummary: String? {
        guard let summary = node.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !summary.isEmpty else {
            return nil
        }
        return summary
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ZStack(alignment: .bottomTrailing) {
                TVRemoteArtworkView(
                    url: node.backdropURL ?? node.posterURL,
                    server: server,
                    placeholderSystemImageName: node.type.tvSystemImageName,
                    placeholderCornerRadius: 0
                )
                .frame(maxWidth: .infinity)
                .frame(height: Self.heroHeight + Self.topBleed)
                .clipped()
                
                if let logoUrl = node.logoURL {
                    TVRemoteLogoImage(url: logoUrl, maxHeight: 140)
                        .padding(.bottom, 74)
                        .padding(.trailing, 80)
                        .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 4)
                }
            }

            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.78),
                    Color.black.opacity(0.54),
                    Color.black.opacity(0.22),
                    Color.black.opacity(0.04)
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: Self.heroHeight + Self.topBleed)

            LinearGradient(
                gradient: Gradient(colors: [
                    Color.clear,
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.84)
                ]),
                startPoint: UnitPoint(x: 0.50, y: 0.24),
                endPoint: .bottom
            )
            .frame(height: Self.heroHeight + Self.topBleed)

            HStack(alignment: .bottom, spacing: 40) {
                if let posterURL = node.posterURL {
                    TVRemoteArtworkView(
                        url: posterURL,
                        server: server,
                        placeholderSystemImageName: node.type.tvSystemImageName,
                        placeholderCornerRadius: 16
                    )
                    .frame(width: 340, height: 510)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Color.black.opacity(0.6), radius: 12, x: 0, y: 6)
                }
                
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 64, weight: .heavy))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.50)
                        .frame(maxWidth: contentMaxWidth, alignment: .leading)
                        .shadow(color: Color.black.opacity(0.48), radius: 14, x: 0, y: 6)
    
                    TVHeroMetadataInlineRow(
                        genres: node.genres,
                        rating: node.rating,
                        communityRating: node.communityRating,
                        secondaryItems: secondaryMetadataItems
                    )
                    .padding(.top, 2)
    
                    if let trimmedSummary {
                        Text(trimmedSummary)
                            .font(.system(size: 25, weight: .semibold))
                            .foregroundColor(.white.opacity(0.86))
                            .lineSpacing(5)
                            .lineLimit(5)
                            .frame(maxWidth: contentMaxWidth, alignment: .leading)
                            .shadow(color: Color.black.opacity(0.50), radius: 10, x: 0, y: 4)
                            .padding(.top, 8)
                    }
    
                    TVMediaLibraryHeroActions(
                        server: server,
                        node: node,
                        playableFile: playableFile,
                        downloadNodes: downloadNodes,
                        downloadGroupTitle: downloadGroupTitle,
                        onPlay: onPlay
                    )
                    .padding(.top, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, Self.contentHorizontalPadding)
            .padding(.trailing, TVPageContentMetrics.horizontalPadding)
            .padding(.top, 108)
            .padding(.bottom, 74)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.heroHeight, alignment: .bottom)
    }
}

private struct TVHeroMetadataInlineRow: View {
    let genres: [String]
    let rating: String?
    let communityRating: Double?
    let secondaryItems: [String]

    private var genreText: String? {
        let visibleGenres = genres.prefix(4)
        guard !visibleGenres.isEmpty else { return nil }
        return visibleGenres.joined(separator: " · ")
    }

    private var hasPrimaryLine: Bool {
        genreText != nil || (rating?.isEmpty == false) || ((communityRating ?? 0) > 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if hasPrimaryLine {
                HStack(spacing: 14) {
                    if let genreText {
                        Text(genreText)
                            .font(.system(size: 23, weight: .bold))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                            .minimumScaleFactor(0.76)
                    }

                    if let communityRating, communityRating > 0 {
                        HStack(spacing: 6) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 20, weight: .black))
                                .foregroundColor(Color(red: 1.0, green: 0.26, blue: 0.32))

                            Text(String(format: "%.1f", communityRating))
                                .font(.system(size: 23, weight: .bold))
                                .foregroundColor(.white.opacity(0.92))
                        }
                        .lineLimit(1)
                    }

                    if let rating, !rating.isEmpty {
                        Text(rating)
                            .font(.system(size: 18, weight: .heavy))
                            .foregroundColor(.white.opacity(0.92))
                            .padding(.horizontal, 8)
                            .frame(height: 28)
                            .background(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(Color.white.opacity(0.58), lineWidth: 2)
                            )
                    }
                }
                .shadow(color: Color.black.opacity(0.44), radius: 8, x: 0, y: 3)
            }

            if !secondaryItems.isEmpty {
                Text(secondaryItems.joined(separator: "  •  "))
                    .font(.system(size: 25, weight: .bold))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
                    .shadow(color: Color.black.opacity(0.44), radius: 8, x: 0, y: 3)
            }
        }
    }
}

private enum TVMediaLibraryDownloadAlert: Identifiable {
    case confirm(message: String)
    case notice(title: String, message: String)

    var id: String {
        switch self {
        case .confirm(let message):
            return "confirm-\(message)"
        case .notice(let title, let message):
            return "notice-\(title)-\(message)"
        }
    }
}

private struct TVMediaLibraryHeroActions: View {
    let server: ServerConfig
    let node: TVMediaLibraryNode
    let playableFile: VideoFile?
    let downloadNodes: [TVMediaLibraryNode]
    let downloadGroupTitle: String?
    let onPlay: (VideoFile) -> Void

    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
    @State private var isRemoteFavorite: Bool
    @State private var isPlayed: Bool
    @State private var isUpdatingRemoteFavorite = false
    @State private var isUpdatingPlayed = false
    @State private var activeDownloadAlert: TVMediaLibraryDownloadAlert?

    init(
        server: ServerConfig,
        node: TVMediaLibraryNode,
        playableFile: VideoFile?,
        downloadNodes: [TVMediaLibraryNode],
        downloadGroupTitle: String?,
        onPlay: @escaping (VideoFile) -> Void
    ) {
        self.server = server
        self.node = node
        self.playableFile = playableFile
        self.downloadNodes = downloadNodes
        self.downloadGroupTitle = downloadGroupTitle
        self.onPlay = onPlay
        _isRemoteFavorite = State(initialValue: node.isFavorite ?? false)
        _isPlayed = State(initialValue: node.isPlayed ?? false)
    }

    private var hasResumeProgress: Bool {
        guard !(node.isPlayed ?? false) else { return false }
        if let progress = node.playbackProgress, progress > 0.01, progress < 0.95 {
            return true
        }
        return (node.playbackPositionSeconds ?? 0) > 5
    }

    private var primaryTitle: String {
        hasResumeProgress ? platformShellString("Continue") : platformShellString("Play")
    }

    private var primaryButtonProgress: Double? {
        guard hasResumeProgress,
              let progress = node.playbackProgress,
              progress > 0.01 else {
            return nil
        }
        return min(max(progress, 0), 1)
    }

    private var canToggleRemoteFavorite: Bool {
        switch server.type {
        case .jellyfin, .emby:
            return !node.id.isEmpty
        default:
            return false
        }
    }

    private var canToggleRemotePlayed: Bool {
        switch server.type {
        case .jellyfin, .emby, .plex:
            return !node.id.isEmpty
        default:
            return false
        }
    }

    private var localFavoriteTarget: TVLocalFavoriteTarget? {
        tvLocalFavoriteTarget(server: server, node: node)
    }

    private var isLocalFavorite: Bool {
        guard let target = localFavoriteTarget else { return false }
        return favoriteService.isFavorite(file: target.file, folderPath: target.identityPath)
    }

    private var effectiveDownloadNodes: [TVMediaLibraryNode] {
        let candidates = downloadNodes.isEmpty ? [node] : downloadNodes
        return candidates.filter { tvMediaLibraryDownloadBatchItem(server: server, node: $0, collectionId: node.id, groupIndex: 0) != nil }
    }

    private var canShowDownloadAction: Bool {
        !effectiveDownloadNodes.isEmpty
    }

    private var canQueueDownloadAction: Bool {
        effectiveDownloadNodes.contains {
            tvMediaLibraryCanQueueDownload(server: server, node: $0, downloadCenter: downloadCenter)
        }
    }

    private var downloadState: DownloadAggregateState {
        tvMediaLibraryDownloadAggregateState(
            server: server,
            nodes: effectiveDownloadNodes,
            downloadCenter: downloadCenter
        )
    }

    private var downloadActionTitle: String {
        switch downloadState {
        case .downloaded:
            return platformShellString("Downloaded")
        case .queued, .downloading:
            return platformShellString("Downloading...")
        case .failed:
            return platformShellString("Retry Download")
        default:
            return effectiveDownloadNodes.count > 1
                ? platformShellString("Download Season")
                : platformShellString("Download")
        }
    }

    private var downloadActionIcon: String {
        switch downloadState {
        case .downloaded, .queued, .downloading:
            return "arrow.down.circle.fill"
        case .failed:
            return "arrow.clockwise.circle"
        default:
            return "arrow.down.circle"
        }
    }

    private var downloadActionTint: Color {
        switch downloadState {
        case .downloaded:
            return Color(red: 0.42, green: 0.88, blue: 0.58)
        case .queued, .downloading:
            return TVShellStyle.accentSoft
        case .failed:
            return Color(red: 1.0, green: 0.48, blue: 0.40)
        default:
            return .white
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            if let playableFile {
                Button(action: { onPlay(playableFile) }) {
                    TVHeroActionButton(
                        title: primaryTitle,
                        systemImageName: node.type == .audio ? "music.note" : "play.fill",
                        isPrimary: true,
                        progress: primaryButtonProgress
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()

                Button(action: { playFromBeginning(playableFile) }) {
                    TVHeroIconActionButton(
                        title: platformShellString("Platform Shell TV Detail Play From Beginning"),
                        systemImageName: "arrow.counterclockwise"
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

            if canShowDownloadAction {
                Button(action: requestDownload) {
                    TVHeroIconActionButton(
                        title: downloadActionTitle,
                        systemImageName: downloadActionIcon,
                        tint: downloadActionTint
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .disabled(!canQueueDownloadAction)
                .tvDisableSystemFocusEffect()
            }

            if canToggleRemoteFavorite {
                Button(action: { Task { await toggleRemoteFavorite() } }) {
                    TVHeroIconActionButton(
                        title: platformShellString(isRemoteFavorite ? "Remove Favorite" : "Add Favorite"),
                        systemImageName: isRemoteFavorite ? "heart.fill" : "heart",
                        tint: isRemoteFavorite ? Color(red: 1.0, green: 0.28, blue: 0.36) : .white
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .disabled(isUpdatingRemoteFavorite)
                .tvDisableSystemFocusEffect()
            }

            if canToggleRemotePlayed {
                Button(action: { Task { await togglePlayed() } }) {
                    TVHeroIconActionButton(
                        title: platformShellString(isPlayed ? "Platform Shell TV Detail Mark Unwatched" : "Platform Shell TV Detail Mark Watched"),
                        systemImageName: isPlayed ? "checkmark.circle.fill" : "checkmark.circle",
                        tint: isPlayed ? Color(red: 0.42, green: 0.88, blue: 0.58) : .white
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .disabled(isUpdatingPlayed)
                .tvDisableSystemFocusEffect()
            }

            if let target = localFavoriteTarget {
                Button(action: {
                    favoriteService.toggleFavorite(file: target.file, folderPath: target.identityPath)
                }) {
                    TVHeroIconActionButton(
                        title: platformShellString(isLocalFavorite ? "Remove Favorite" : "Add Favorite"),
                        systemImageName: isLocalFavorite ? "star.fill" : "star",
                        tint: isLocalFavorite ? Color(red: 1.0, green: 0.82, blue: 0.25) : .white
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
        .contentShape(Rectangle())
        .tvFocusSectionIfAvailable()
        .alert(item: $activeDownloadAlert) { alert in
            switch alert {
            case .confirm(let message):
                return Alert(
                    title: Text(platformShellString("Add to Download Queue")),
                    message: Text(message),
                    primaryButton: .default(Text(platformShellString("Download"))) {
                        confirmDownload()
                    },
                    secondaryButton: .cancel()
                )
            case .notice(let title, let message):
                return Alert(
                    title: Text(title),
                    message: Text(message),
                    dismissButton: .default(Text(platformShellString("OK")))
                )
            }
        }
    }

    private func playFromBeginning(_ playableFile: VideoFile) {
        var restartFile = playableFile
        restartFile.lastPlayedPosition = 0
        restartFile.shouldResetRemotePlayedStateOnPlaybackStart = true
        onPlay(restartFile)
    }

    private func requestDownload() {
        guard canQueueDownloadAction else {
            activeDownloadAlert = .notice(
                title: platformShellString("Downloads"),
                message: platformShellString("Already in Download Queue")
            )
            return
        }

        let message: String
        if effectiveDownloadNodes.count > 1 {
            let title = downloadGroupTitle ?? tvDisplayTitle(from: node.name, type: node.type)
            message = String(
                format: platformShellString("Add %d items from \"%@\" to the download queue now?"),
                effectiveDownloadNodes.count,
                title
            )
        } else {
            let title = effectiveDownloadNodes.first.map { tvDisplayTitle(from: $0.name, type: $0.type) }
                ?? tvDisplayTitle(from: node.name, type: node.type)
            message = String(
                format: platformShellString("Add \"%@\" to the download queue now?"),
                title
            )
        }

        activeDownloadAlert = .confirm(message: message)
    }

    private func confirmDownload() {
        let nodesToQueue = effectiveDownloadNodes.filter {
            tvMediaLibraryCanQueueDownload(server: server, node: $0, downloadCenter: downloadCenter)
        }
        guard !nodesToQueue.isEmpty else {
            activeDownloadAlert = .notice(
                title: platformShellString("Downloads"),
                message: platformShellString("Already in Download Queue")
            )
            return
        }

        let groupTitle = nodesToQueue.count > 1
            ? (downloadGroupTitle ?? tvDisplayTitle(from: node.name, type: node.type))
            : nil
        let collectionId = nodesToQueue.count > 1
            ? (nodesToQueue[0].seasonId ?? node.id)
            : node.id
        let job = DownloadJobDescriptor(
            kind: nodesToQueue.count > 1 ? .seasonPack : .singleMedia,
            sourceType: DownloadSourceType(serverType: server.type),
            title: groupTitle ?? tvDisplayTitle(from: nodesToQueue[0].name, type: nodesToQueue[0].type),
            groupTitle: groupTitle,
            collectionId: collectionId,
            seriesId: node.isSeries ? node.id : nodesToQueue[0].seriesId,
            seasonId: nodesToQueue[0].seasonId
        )

        let entries = nodesToQueue.enumerated().compactMap { index, downloadNode in
            tvMediaLibraryDownloadBatchItem(
                server: server,
                node: downloadNode,
                collectionId: collectionId,
                groupIndex: index
            )
        }
        let enqueuedCount = downloadCenter.enqueueMediaBatch(server: server, items: entries, job: job)
        let message: String
        if enqueuedCount > 0 {
            message = enqueuedCount == 1
                ? platformShellString("Added to Download Queue")
                : String(format: platformShellString("Added %d items to Download Queue"), enqueuedCount)
        } else {
            message = platformShellString(nodesToQueue.count > 1 ? "Season Already Queued" : "Already in Download Queue")
        }
        activeDownloadAlert = .notice(title: platformShellString("Downloads"), message: message)
    }

    private func toggleRemoteFavorite() async {
        guard !isUpdatingRemoteFavorite else { return }
        await MainActor.run { isUpdatingRemoteFavorite = true }
        let nextValue = !isRemoteFavorite
        do {
            try await tvSetMediaLibraryFavorite(server: server, itemId: node.id, isFavorite: nextValue)
            await MainActor.run {
                isRemoteFavorite = nextValue
                isUpdatingRemoteFavorite = false
            }
            FavoriteRefreshCenter.updateRemoteItem(
                serverId: server.id,
                itemId: node.id,
                seriesId: node.seriesId,
                isFavorite: nextValue
            )
        } catch {
            await MainActor.run {
                isUpdatingRemoteFavorite = false
            }
        }
    }

    private func togglePlayed() async {
        guard !isUpdatingPlayed else { return }
        await MainActor.run { isUpdatingPlayed = true }
        let nextValue = !isPlayed
        do {
            try await tvSetMediaLibraryPlayed(server: server, itemId: node.id, isPlayed: nextValue)
            await MainActor.run {
                isPlayed = nextValue
                isUpdatingPlayed = false
            }
            PlaybackRefreshCenter.updateRemoteItem(
                serverId: server.id,
                itemId: node.id,
                seriesId: node.seriesId,
                seasonId: node.seasonId,
                snapshot: RemotePlaybackStateSnapshot.manualPlayedState(
                    played: nextValue,
                    runtimeTicks: node.runtimeTicks
                )
            )
        } catch {
            await MainActor.run {
                isUpdatingPlayed = false
            }
        }
    }
}

private func tvMediaLibraryDownloadBatchItem(
    server: ServerConfig,
    node: TVMediaLibraryNode,
    collectionId: String,
    groupIndex: Int
) -> DownloadMediaBatchItem? {
    guard let remotePath = tvMediaLibraryDownloadRemotePath(server: server, node: node) else {
        return nil
    }

    return DownloadMediaBatchItem(
        remoteItemId: node.id,
        remotePath: remotePath,
        fileName: tvMediaLibraryDownloadFileName(for: node),
        displayTitle: tvDisplayTitle(from: node.name, type: node.type),
        totalBytes: node.mediaSize,
        collectionId: collectionId,
        seriesId: node.seriesId,
        seasonId: node.seasonId,
        groupIndex: groupIndex
    )
}

private func tvMediaLibraryDownloadRemotePath(
    server: ServerConfig,
    node: TVMediaLibraryNode
) -> String? {
    guard node.type == .video || node.type == .audio else { return nil }

    switch server.type {
    case .jellyfin, .emby:
        return node.id.isEmpty ? nil : "/Videos/\(node.id)/stream?Static=true&download=1"
    case .plex:
        return tvTrimmedText(node.downloadRemotePath)
    default:
        return nil
    }
}

private func tvMediaLibraryDownloadFileName(for node: TVMediaLibraryNode) -> String {
    var displayName = tvDisplayTitle(from: node.name, type: node.type)
    if let series = tvTrimmedText(node.seriesName),
       let season = node.parentIndexNumber,
       let episode = node.indexNumber {
        displayName = "\(series) - S\(String(format: "%02d", season))E\(String(format: "%02d", episode)) - \(displayName)"
    }

    displayName = displayName
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "\\", with: "_")

    if let rawContainer = tvTrimmedText(node.mediaContainer)?.split(separator: ",").first {
        let container = String(rawContainer).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !container.isEmpty, !displayName.lowercased().hasSuffix(".\(container)") {
            displayName += ".\(container)"
        }
    }

    return displayName
}

@MainActor
private func tvMediaLibraryCanQueueDownload(
    server: ServerConfig,
    node: TVMediaLibraryNode,
    downloadCenter: DownloadCenterService
) -> Bool {
    guard tvMediaLibraryDownloadRemotePath(server: server, node: node) != nil else { return false }
    switch tvMediaLibraryDownloadStatus(server: server, node: node, downloadCenter: downloadCenter) {
    case .queued, .downloading, .paused, .completed:
        return false
    default:
        return true
    }
}

@MainActor
private func tvMediaLibraryDownloadStatus(
    server: ServerConfig,
    node: TVMediaLibraryNode,
    downloadCenter: DownloadCenterService
) -> DownloadTaskStatus? {
    switch server.type {
    case .plex:
        guard let remotePath = tvMediaLibraryDownloadRemotePath(server: server, node: node) else { return nil }
        return downloadCenter.taskStatus(serverId: server.id, remotePath: remotePath)
    case .jellyfin, .emby:
        return downloadCenter.taskStatus(serverId: server.id, remoteItemId: node.id)
    default:
        return nil
    }
}

@MainActor
private func tvMediaLibraryDownloadAggregateState(
    server: ServerConfig,
    nodes: [TVMediaLibraryNode],
    downloadCenter: DownloadCenterService
) -> DownloadAggregateState {
    switch server.type {
    case .plex:
        let remotePaths = nodes.compactMap { tvMediaLibraryDownloadRemotePath(server: server, node: $0) }
        return downloadCenter.aggregateStateForRemotePaths(serverId: server.id, remotePaths: remotePaths)
    case .jellyfin, .emby:
        return downloadCenter.aggregateState(serverId: server.id, remoteItemIds: nodes.map(\.id))
    default:
        return .notDownloaded
    }
}

private struct TVMetadataTag: View {
    let text: String
    var isRating: Bool = false
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption2.weight(.bold))
            }
            Text(text)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundColor(.white.opacity(0.80))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(isRating
                    ? Color.orange.opacity(0.28)
                    : Color.white.opacity(0.10)
                )
        )
    }
}

private struct TVGenreTagsRow: View {
    let genres: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(genres, id: \.self) { genre in
                    Text(genre)
                        .font(.callout.weight(.medium))
                        .foregroundColor(.white.opacity(0.80))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(Color.white.opacity(0.10), lineWidth: 1)
                        )
                }
            }
        }
    }
}

private struct TVLibraryLeafInfoGrid: View {
    let node: TVMediaLibraryNode
    let server: ServerConfig

    var body: some View {
        let items = buildInfoItems()
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(platformShellString("Platform Shell TV Detail Info"))
                    .font(.headline.weight(.bold))
                    .foregroundColor(.white.opacity(0.56))

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)],
                    alignment: .leading,
                    spacing: 14
                ) {
                    ForEach(items, id: \.label) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.label)
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.white.opacity(0.46))
                            Text(item.value)
                                .font(.callout.weight(.medium))
                                .foregroundColor(.white.opacity(0.82))
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private struct InfoItem {
        let label: String
        let value: String
    }

    private func buildInfoItems() -> [InfoItem] {
        var items: [InfoItem] = []
        if let year = node.year {
            items.append(InfoItem(
                label: platformShellString("Platform Shell TV Detail Year"),
                value: "\(year)"
            ))
        }
        if let runtimeText = tvDurationText(ticks: node.runtimeTicks) {
            items.append(InfoItem(
                label: platformShellString("Platform Shell TV Detail Runtime"),
                value: runtimeText
            ))
        }
        if let rating = node.rating, !rating.isEmpty {
            items.append(InfoItem(
                label: platformShellString("Platform Shell TV Detail Rating"),
                value: rating
            ))
        }
        if !node.genres.isEmpty {
            items.append(InfoItem(
                label: platformShellString("Platform Shell TV Detail Genres"),
                value: node.genres.prefix(4).joined(separator: ", ")
            ))
        }
        items.append(InfoItem(
            label: platformShellString("Platform Shell TV Detail Server"),
            value: server.name
        ))
        return items
    }
}

struct TVHeroActionButton: View {
    let title: String
    let systemImageName: String
    let isPrimary: Bool
    var progress: Double? = nil

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var fillColor: Color {
        if !isEnabled {
            return TVShellStyle.subtleFill.opacity(0.45)
        }
        if isFocused {
            return Color.white.opacity(0.94)
        }
        return isPrimary ? Color.white.opacity(0.18) : Color.white.opacity(0.10)
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return TVShellStyle.secondary.opacity(0.45)
        }
        if isFocused {
            return .black.opacity(0.90)
        }
        return .white
    }

    private var progressFillColor: Color {
        isFocused
            ? TVShellStyle.accentSoft.opacity(0.24)
            : TVShellStyle.accentSoft.opacity(isPrimary ? 0.42 : 0.26)
    }

    private var clampedProgress: CGFloat? {
        guard isEnabled, let progress, progress > 0.01 else { return nil }
        return CGFloat(min(max(progress, 0), 1))
    }

    private var progressText: String? {
        guard let clampedProgress else { return nil }
        return "\(Int((Double(clampedProgress) * 100).rounded()))%"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImageName)
                .font(.system(size: 24, weight: .bold))
            Text(title)
                .font(.system(size: 25, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let progressText {
                Text(progressText)
                    .font(.system(size: 21, weight: .heavy, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .foregroundColor(foregroundColor.opacity(0.82))
                    .padding(.leading, 4)
            }
        }
        .foregroundColor(foregroundColor)
        .frame(minWidth: isPrimary ? 320 : 170, minHeight: 70)
        .padding(.horizontal, 26)
        .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .background(
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(fillColor)

                if let clampedProgress {
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 19, style: .continuous)
                            .fill(progressFillColor)
                            .frame(width: proxy.size.width * clampedProgress)
                            .frame(maxHeight: .infinity)
                    }
                    .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(isFocused ? Color.clear : TVShellStyle.separator.opacity(0.6), lineWidth: 1)
        )
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .shadow(
            color: isFocused ? Color.black.opacity(0.30) : Color.black.opacity(isPrimary ? 0.18 : 0.08),
            radius: isFocused ? 16 : 8,
            x: 0,
            y: isFocused ? 8 : 4
        )
        .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

private struct TVHeroIconActionButton: View {
    let title: String
    let systemImageName: String
    var tint: Color = .white

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Image(systemName: systemImageName)
            .font(.system(size: 25, weight: .bold))
            .foregroundColor(isEnabled ? (isFocused ? .black : tint) : (tint != .white ? tint : TVShellStyle.secondary.opacity(0.45)))
            .frame(width: 88, height: 70)
            .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(isFocused ? Color.white : Color.white.opacity(isEnabled ? 0.10 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(Color.white.opacity(isFocused ? 0.0 : 0.18), lineWidth: 1)
            )
            .scaleEffect(isFocused ? 1.06 : 1.0)
            .shadow(
                color: isFocused ? Color.black.opacity(0.30) : Color.black.opacity(0.06),
                radius: isFocused ? 16 : 7,
                x: 0,
                y: isFocused ? 8 : 4
            )
            .accessibilityLabel(Text(title))
            .animation(.easeOut(duration: 0.18), value: isFocused)
    }
}

#endif
