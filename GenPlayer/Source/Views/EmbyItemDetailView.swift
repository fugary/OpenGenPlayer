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

private struct EmbyDetailPosterCardText: View {
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

private struct EmbyDetailPersonCard: View {
    let server: ServerConfig
    let person: EmbyPerson

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

            EmbyDetailPosterCardText(
                title: person.name,
                subtitle: personCardSubtitle(role: person.role, type: person.type),
                width: MediaCardMetrics.peoplePosterWidth,
                height: MediaCardMetrics.peopleTextHeight,
                titleColor: .white.opacity(0.9),
                subtitleColor: .white.opacity(0.7)
            )
        }
        .frame(width: MediaCardMetrics.peoplePosterWidth)
        .contentShape(Rectangle())
    }
}

private struct EmbyDetailRelatedCard: View {
    let server: ServerConfig
    let item: EmbyItem
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

            EmbyDetailPosterCardText(
                title: item.displayTitle,
                subtitle: subtitleText,
                width: cardWidth,
                height: MediaCardMetrics.posterTextHeight,
                titleColor: .white.opacity(0.9),
                subtitleColor: .white.opacity(0.7)
            )
        }
        .frame(width: cardWidth)
        .contentShape(Rectangle())
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

struct EmbyItemDetailView: View {
    let server: ServerConfig
    let item: EmbyItem
    var onExit: (() -> Void)? = nil
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var initialSeasonId: String? = nil
    var initialEpisodeId: String? = nil
    
    @State private var showFullOverviewSheet = false
    @State private var seasons: [EmbyItem] = []
    @State private var episodes: [EmbyItem] = [] // For current season
    @State private var containerChildren: [EmbyItem] = []
    @State private var selectedSeasonId: String?
    @State private var hasUserSelectedSeason = false
    @State private var isLoadingChildren = false
    @State private var isLoading = false
    @State private var playerFile: VideoFile?
    @State private var playerPlaylist: [VideoFile]?
    @State private var pendingEpisodeId: String?
    @State private var resumeSeasonId: String?
    
    @State private var people: [EmbyPerson] = []
    @State private var similarItems: [EmbyItem] = []
    @State private var showPrePlaybackOptions = false
    @State private var isLoadingPrePlaybackOptions = false
    @State private var prePlaybackTargetItem: EmbyItem? = nil
    @State private var prePlaybackQualityOptions: [PrePlaybackTrackOption] = []
    @State private var prePlaybackAudioOptions: [PrePlaybackTrackOption] = []
    @State private var prePlaybackSubtitleOptions: [PrePlaybackTrackOption] = []
    @State private var prePlaybackExternalSubtitleCandidates: [ExternalSubtitleCandidate] = []
    @State private var selectedPrePlaybackQualityID: String? = AppSettings.shared.defaultRemotePlaybackQualityOption.id
    @State private var selectedPrePlaybackAudioID: String? = nil
    @State private var selectedPrePlaybackSubtitleID: String? = nil
    @State private var canShowPrePlaybackOptions = false
    @State private var isFavorite = false
    @State private var isPlayed = false
    @State private var isUpdatingPlayedState = false
    @AppStorage("allowMediaServerDeletion") private var allowMediaServerDeletion = false
    @State private var showingDeleteAlert = false
    @State private var itemToDelete: EmbyItem? = nil
    @State private var isDeleting = false
    @State private var errorMessage: String = ""
    @State private var showErrorAlert: Bool = false
    @State private var offlineState: DownloadAggregateState = .notDownloaded
    @State private var pendingDownloadItem: EmbyItem? = nil
    @State private var pendingSeasonDownloadItems: [EmbyItem] = []
    @State private var pendingSeasonDownloadTitle: String?
    @State private var isShowingDownloadConfirmAlert: Bool = false
    @State private var isShowingDownloadCenter = false
    @State private var downloadToastMessage: String? = nil
    @StateObject private var backdropReadability = AdaptiveBackdropReadabilityModel()
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var remotePlaybackState = RemotePlaybackStateStore.shared
    
    private let embyService = EmbyService.shared
    
    private var streamPlaybackURL: URL? {
        let mediaSource = item.mediaSources?.first
        let token = server.accessToken ?? ""
        return embyService.resolvePlaybackURL(server: server, itemId: item.id, token: token, mediaSource: mediaSource)
            ?? embyService.getStreamURL(server: server, itemId: item.id, token: token, mediaSourceId: mediaSource?.id)
    }

    private var backgroundImageUrl: URL? {
        item.spotlightBackdropImageURL(server: server)
    }

    private var effectiveItemUserData: EmbyUserData? {
        effectiveUserData(for: item)
    }

    private var effectiveIsPlayed: Bool {
        effectiveItemUserData?.played ?? isPlayed
    }

    private var downloadTargetItem: EmbyItem? {
        item.isPlayable ? item : nil
    }

    private var currentOfflineTargetIds: [String] {
        if item.isPlayable {
            return [item.id]
        }
        if item.type == "Series" {
            return episodes.filter(\.isPlayable).map(\.id)
        }
        return containerChildren.filter(\.isPlayable).map(\.id)
    }

    private var selectedSeasonEpisodes: [EmbyItem] {
        if item.type == "Series" {
            return episodes.filter(\.isPlayable)
        }
        return containerChildren.filter(\.isPlayable)
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
        initialSeasonId ?? resumeSeasonId
    }

    private var seasonDownloadCandidates: [EmbyItem] {
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

    private var episodeSectionTitle: String {
        item.type == "Series"
            ? NSLocalizedString("Season Episodes", comment: "")
            : NSLocalizedString("Episodes", comment: "")
    }

    private var episodeSectionIcon: String {
        item.type == "Series" || item.type == "Season" ? "film.fill" : "list.bullet"
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
                ? embyPlaybackPositionSeconds(
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
        return "__emby_item__/\(targetItemId)"
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
                                    embyMetadataRow
                                    
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
                                    embyActionButtons
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
                                    embyMetadataRow
                                    
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
                                embyActionButtons
                            }
                        }
                    }
                        
                        // Seasons & Episodes
                        if item.type == "Series" {
                            VStack(alignment: .leading, spacing: 16) {
                                // Season Picker
                                if isLoadingChildren && seasons.isEmpty {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, minHeight: 80)
                                } else if !seasons.isEmpty {
                                    MediaSectionHeaderLabel(
                                        title: NSLocalizedString("Seasons", comment: ""),
                                        systemImage: "square.stack.fill",
                                        foregroundColor: .white,
                                        font: .headline,
                                        weight: .bold
                                    )
                                    .padding(.horizontal)

                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 12) {
                                            ForEach(seasons) { season in
                                                Button(action: {
                                                    pendingEpisodeId = nil
                                                    hasUserSelectedSeason = true
                                                    selectedSeasonId = season.id
                                                    Task { await loadEpisodes(seasonId: season.id) }
                                                }) {
                                                    Text(season.name)
                                                        .font(.system(size: 16, weight: selectedSeasonId == season.id ? .bold : .medium))
                                                        .foregroundColor(selectedSeasonId == season.id ? .white : .white.opacity(0.72))
                                                        .padding(.horizontal, 16)
                                                        .padding(.vertical, 8)
                                                        .background(
                                                            Capsule()
                                                                .fill(selectedSeasonId == season.id ? Color.accentColor : Color.white.opacity(0.1))
                                                        )
                                                }
                                                .disabled(isLoadingChildren)
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
                                }

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
                                
                                // Episodes List
                                if isLoadingChildren {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, minHeight: 120)
                                } else if !episodes.isEmpty {
                                    LazyVStack(spacing: 16) {
                                        ForEach(episodes) { episode in
                                            HStack(spacing: 12) {
                                                Button(action: {
                                                    playItem(item: episode, playbackQualityID: immediatePlaybackQualityID)
                                                }) {
                                                    EmbyEpisodeRow(item: episode, server: server)
                                                }
                                                .buttonStyle(PlainButtonStyle())
                                                .id(episodeAnchorID(for: episode.id))

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
                                            .padding(.horizontal)
                                            .contextMenu {
                                                Button(action: {
                                                    playItem(item: episode, playbackQualityID: immediatePlaybackQualityID)
                                                }) {
                                                    Label(NSLocalizedString("Play", comment: ""), systemImage: "play.fill")
                                                }
                                                Button(action: {
                                                    Task { await toggleChildPlayed(episode) }
                                                }) {
                                                    let isChildPlayed = effectiveUserData(for: episode)?.played ?? false
                                                    Label(
                                                        isChildPlayed ? NSLocalizedString("Mark as Unplayed", comment: "") : NSLocalizedString("Mark as Played", comment: ""),
                                                        systemImage: isChildPlayed ? "xmark.circle" : "checkmark.circle"
                                                    )
                                                }
                                                if canQueueEpisodeDownload(episode) {
                                                    Button(action: {
                                                        requestEpisodeDownload(episode)
                                                    }) {
                                                        Label(NSLocalizedString("Download", comment: ""), systemImage: "arrow.down.circle")
                                                    }
                                                }
                                                if allowMediaServerDeletion {
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
                                } else {
                                    emptySeasonCard(onDelete: {
                                        if let currentSeason = seasons.first(where: { $0.id == selectedSeasonId }) {
                                            itemToDelete = currentSeason
                                            showingDeleteAlert = true
                                        }
                                    })
                                }
                            }
                        }

                        if item.isContainer && item.type != "Series" {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 12) {
                                    MediaSectionHeaderLabel(
                                        title: item.type == "Season" ? episodeSectionTitle : NSLocalizedString("Items", comment: ""),
                                        systemImage: item.type == "Season" ? episodeSectionIcon : "list.bullet",
                                        foregroundColor: .white,
                                        font: .headline,
                                        weight: .bold
                                    )

                                    Spacer(minLength: 0)

                                    if item.type == "Season" && canShowSeasonDownloadButton {
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

                                if isLoadingChildren {
                                    ProgressView()
                                        .frame(maxWidth: .infinity, minHeight: 120)
                                } else if !containerChildren.isEmpty {
                                    LazyVStack(spacing: item.type == "Season" ? 16 : 0) {
                                        ForEach(containerChildren) { child in
                                            if child.isPlayable {
                                                HStack(spacing: 12) {
                                                    Button(action: {
                                                        playItem(item: child, playbackQualityID: immediatePlaybackQualityID)
                                                    }) {
                                                        if item.type == "Season" {
                                                            EmbyEpisodeRow(item: child, server: server)
                                                        } else {
                                                            EmbyContainerChildRow(item: child, server: server, isPlayable: true)
                                                        }
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
                                                .contextMenu {
                                                    Button(action: {
                                                        playItem(item: child, playbackQualityID: immediatePlaybackQualityID)
                                                    }) {
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
                                                        Button(action: {
                                                            requestEpisodeDownload(child)
                                                        }) {
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
                                                NavigationLink(destination: embyNavigationDestination(server: server, item: child, onExit: onExit)) {
                                                    EmbyContainerChildRow(item: child, server: server, isPlayable: false)
                                                }
                                                .buttonStyle(PlainButtonStyle())
                                                .padding(.horizontal)
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
                                    .padding(.horizontal, item.type == "Season" ? 0 : 16)
                                    .background(item.type == "Season" ? Color.clear : Color.black.opacity(0.3))
                                    .cornerRadius(item.type == "Season" ? 0 : 12)
                                } else {
                                    if item.type == "Season" {
                                        emptySeasonCard(onDelete: {
                                            itemToDelete = item
                                            showingDeleteAlert = true
                                        })
                                    } else {
                                        Text(NSLocalizedString("No items found", comment: ""))
                                            .foregroundColor(.white.opacity(0.62))
                                            .frame(maxWidth: .infinity, minHeight: 60)
                                            .padding(.horizontal)
                                    }
                                }
                            }
                        }
                        
                        // Cast & Crew
                        if !people.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(NSLocalizedString("Cast & Crew", comment: ""))
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal)
                                
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(alignment: .top, spacing: 16) {
                                        ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                                            NavigationLink(destination: EmbyPersonDetailView(server: server, person: person, onExit: onExit)) {
                                                EmbyDetailPersonCard(server: server, person: person)
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                                .duoMediaShelfViewport()
                            }
                        }
                        
                        // Similar Items
                        if !similarItems.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                Text(NSLocalizedString("More Like This", comment: ""))
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .padding(.horizontal)
                                
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(alignment: .top, spacing: 16) {
                                        ForEach(similarItems) { item in
                                            NavigationLink(destination: NavigationLazyView { AnyView(embyNavigationDestination(server: server, item: item, onExit: onExit)) }) {
                                                EmbyDetailRelatedCard(server: server, item: item)
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                                .duoMediaShelfViewport()
                            }
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
                            .padding(.top, 16)
                        }


                        Spacer(minLength: 50)
                    }
                    .mediaDetailHorizontalSafeAreaPadding(
                        usesWideLayout: horizontalSizeClass == .regular || geometry.size.width > 600
                    )
                    .onAppear {
                        scrollToPendingEpisode(using: scrollProxy)
                    }
                    .onChange(of: episodes.map(\.id)) { _ in
                        scrollToPendingEpisode(using: scrollProxy)
                        if item.type != "Series" {
                            Task { await refreshPrePlaybackOptionAvailability() }
                        }
                    }
                }
            } // end ZStack
            .navigationBarTitleDisplayMode(.inline)
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
        .fullScreenCover(item: $playerFile, onDismiss: {
            UIApplication.refreshInterfaceChrome()
            Task {
                try? await Task.sleep(nanoseconds: 300_000_000)
                await refreshPlaybackContextFromServer()
            }
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
            isPresented: $isShowingDownloadConfirmAlert,
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
                isFavorite = effectiveItemUserData?.isFavorite ?? false
                isPlayed = effectiveItemUserData?.played ?? false
                pendingEpisodeId = initialEpisodeId
                if item.type == "Series" {
                    canShowPrePlaybackOptions = false
                    Task { await loadSeasons() }
                    if initialSeasonId == nil {
                        Task { await loadPreferredSeasonContext() }
                    }
                } else if item.isContainer {
                    Task { await loadContainerChildren() }
                    Task { await refreshPrePlaybackOptionAvailability() }
                } else {
                    Task { await refreshPrePlaybackOptionAvailability() }
                }
                Task { await loadMetadata() }
                refreshOfflineAvailability()
            }
            .onChange(of: backgroundImageUrl) { newValue in
                if newValue == nil {
                    backdropReadability.reset()
                }
            }
            .onChange(of: resumeSeasonId) { _ in
                applyPreferredSeriesSeasonIfNeeded()
            }
            .onChange(of: downloadCenter.tasks.count) { _ in
                refreshOfflineAvailability()
            }
            .onChange(of: episodes.map(\.id)) { _ in
                refreshOfflineAvailability()
            }
            .onChange(of: containerChildren.map(\.id)) { _ in
                refreshOfflineAvailability()
            }
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
    }

    @ViewBuilder
    private var embyMetadataRow: some View {
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
            if let source = item.mediaSources?.first, let container = source.container {
                Text(container.uppercased())
                    .font(.caption2)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .border(Color.white.opacity(0.5), width: 0.5)
            }
        }
        .font(.caption)
        .foregroundColor(.white.opacity(0.86))
        let technicalParts = MediaTechnicalMetadata.parts(video: item.mediaSources?.first?.videoStream?.toDictionary() ?? [:])
        if !technicalParts.isEmpty {
            Text(technicalParts.joined(separator: " · "))
                .font(.caption)
                .foregroundColor(.white.opacity(0.86))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var embyActionButtons: some View {
        VStack(alignment: horizontalSizeClass == .regular ? .leading : .center, spacing: 12) {
            if item.isPlayable || item.type == "Series" {
                PrimaryPlaybackCTAButton(
                    title: playButtonTitle,
                    progress: playButtonProgressInfo,
                    action: {
                        if item.type == "Series" {
                            if let firstEp = episodes.first {
                                playItem(item: firstEp, playbackQualityID: immediatePlaybackQualityID)
                            }
                        } else {
                            playItem(item: item, playbackQualityID: immediatePlaybackQualityID)
                        }
                    }
                )
                .mediaDetailPlaybackButtonFrame()

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
            target.name
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
        isShowingDownloadConfirmAlert = true
    }

    private func requestEpisodeDownload(_ episode: EmbyItem) {
        guard canQueueEpisodeDownload(episode) else {
            downloadToastMessage = NSLocalizedString("Already in Download Queue", comment: "")
            return
        }
        pendingSeasonDownloadItems = []
        pendingSeasonDownloadTitle = nil
        pendingDownloadItem = episode
        isShowingDownloadConfirmAlert = true
    }

    private func requestSelectedSeasonDownload() {
        guard canQueueSelectedSeasonDownload else {
            downloadToastMessage = NSLocalizedString("Season Already Queued", comment: "")
            return
        }
        pendingDownloadItem = nil
        pendingSeasonDownloadItems = seasonDownloadCandidates
        pendingSeasonDownloadTitle = currentSeasonTitle
        isShowingDownloadConfirmAlert = true
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

    private func canQueueEpisodeDownload(_ episode: EmbyItem) -> Bool {
        switch downloadCenter.taskStatus(serverId: server.id, remoteItemId: episode.id) {
        case .queued, .downloading, .paused, .completed:
            return false
        default:
            return true
        }
    }

    private func episodeDownloadIcon(for episode: EmbyItem) -> String {
        switch downloadCenter.taskStatus(serverId: server.id, remoteItemId: episode.id) {
        case .completed:
            return "arrow.down.circle.fill"
        case .queued, .downloading, .paused:
            return "arrow.down.circle.fill"
        default:
            return "arrow.down.circle"
        }
    }

    private func episodeDownloadColor(for episode: EmbyItem) -> Color {
        switch downloadCenter.taskStatus(serverId: server.id, remoteItemId: episode.id) {
        case .completed:
            return .green
        case .queued, .downloading, .paused:
            return Color(UIColor.systemBlue)
        default:
            return .white.opacity(0.9)
        }
    }

    private func downloadFileName(for item: EmbyItem) -> String {
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

    private func episodeAnchorID(for episodeId: String) -> String {
        "episode-\(episodeId)"
    }

    private func scrollToPendingEpisode(using proxy: ScrollViewProxy) {
        guard let targetEpisodeId = pendingEpisodeId else { return }
        guard episodes.contains(where: { $0.id == targetEpisodeId }) else { return }
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(episodeAnchorID(for: targetEpisodeId), anchor: .center)
            }
            pendingEpisodeId = nil
        }
    }


    
    private func makePreparedPlayableFile(
        item: EmbyItem,
        startFromBeginning: Bool = false,
        playbackQuality: RemotePlaybackQualityOption = .auto,
        audioQuery: String? = nil,
        subtitleQuery: String? = nil,
        preferredAudioOrdinal: Int? = nil,
        preferredSubtitleOrdinal: Int? = nil,
        externalSubtitleCandidates: [ExternalSubtitleCandidate] = [],
        disableSubtitles: Bool = false
    ) async -> VideoFile? {
        guard let token = server.accessToken, let userId = server.userId else { return nil }
        let effectiveData = effectiveUserData(for: item)
        let resumeDecision = embyResumeDecision(
            from: effectiveData,
            runtimeTicks: item.runTimeTicks,
            playedOverride: item.id == self.item.id ? isPlayed : nil
        )
        let startPosition: TimeInterval? = startFromBeginning ? 0 : resumeDecision.startPosition
        let startTimeTicks = embyPlaybackStartTimeTicks(startPosition)
        let playbackInfo: EmbyPlaybackInfo
        do {
            playbackInfo = try await embyService.getPlaybackInfo(
                server: server,
                itemId: item.id,
                userId: userId,
                token: token,
                playbackQuality: playbackQuality,
                startTimeTicks: startTimeTicks
            )
        } catch {
            print("[Emby] Failed to load playback info for quality selection: \(error)")
            return nil
        }

        let preferredSource = embyService.preferredPlaybackSource(from: playbackInfo.mediaSources) ?? playbackInfo.mediaSources.first
        guard let streamUrl = embyService.resolvePlaybackURL(
            server: server,
            itemId: item.id,
            token: token,
            mediaSource: preferredSource,
            playbackQuality: playbackQuality,
            startTimeTicks: startTimeTicks
        ) else { return nil }

        var displayName = item.name
        if item.type == "Episode", let series = item.seriesName, let season = item.parentIndexNumber, let episode = item.indexNumber {
            displayName = "\(series) - S\(season)E\(episode) - \(item.name)"
        }

        var videoFile = VideoFile(
            name: displayName,
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
        videoFile.shouldResetRemotePlayedStateOnPlaybackStart =
            startFromBeginning || resumeDecision.shouldResetPlayedStateOnStart
        videoFile.preferredAudioTrackQuery = audioQuery
        videoFile.preferredSubtitleTrackQuery = subtitleQuery
        videoFile.preferredAudioTrackOrdinal = preferredAudioOrdinal
        videoFile.preferredSubtitleTrackOrdinal = preferredSubtitleOrdinal
        videoFile.preferredPlaybackQualityID = playbackQuality.id
        videoFile.availablePlaybackQualityOptions = embyService.qualityOptions(from: playbackInfo.mediaSources)
        videoFile.disableSubtitlesOnStart = disableSubtitles
        videoFile.externalSubtitleCandidates = externalSubtitleCandidates.isEmpty
            ? embyService.externalSubtitleCandidates(
                server: server,
                itemId: item.id,
                mediaSources: playbackInfo.mediaSources,
                token: token,
                mediaSourceId: preferredSource?.id
            )
            : externalSubtitleCandidates

        if let source = preferredSource {
            videoFile.serverMediaStreams = source.mediaStreams?.map { $0.toDictionary() }
            videoFile.serverContainer = source.container
            videoFile.serverSize = source.size
            videoFile.serverBitrate = source.bitrate
            videoFile.serverPath = source.path
            videoFile.remotePlaybackMethod = embyService.playbackMethod(
                for: source,
                resolvedURL: streamUrl,
                playbackQuality: playbackQuality
            )
        }

        return videoFile
    }

    private func makePlayableFile(
        item: EmbyItem,
        token: String,
        startFromBeginning: Bool = false,
        playbackQuality: RemotePlaybackQualityOption = .auto
    ) -> VideoFile? {
        let preferredSource = embyService.preferredPlaybackSource(from: item.mediaSources ?? []) ?? item.mediaSources?.first
        let effectiveData = effectiveUserData(for: item)
        let resumeDecision = embyResumeDecision(
            from: effectiveData,
            runtimeTicks: item.runTimeTicks,
            playedOverride: item.id == self.item.id ? isPlayed : nil
        )
        let startPosition: TimeInterval? = startFromBeginning ? 0 : resumeDecision.startPosition
        
        guard let streamUrl = embyService.resolvePlaybackURL(
            server: server,
            itemId: item.id,
            token: token,
            mediaSource: preferredSource,
            playbackQuality: playbackQuality,
            startTimeTicks: embyPlaybackStartTimeTicks(startPosition)
        ) else { return nil }

        var displayName = item.name
        if item.type == "Episode", let series = item.seriesName, let season = item.parentIndexNumber, let episode = item.indexNumber {
            displayName = "\(series) - S\(String(format: "%02d", season))E\(String(format: "%02d", episode)) - \(item.name)"
        }

        var videoFile = VideoFile(
            name: displayName,
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
        videoFile.shouldResetRemotePlayedStateOnPlaybackStart =
            startFromBeginning || resumeDecision.shouldResetPlayedStateOnStart
        
        videoFile.preferredPlaybackQualityID = playbackQuality.id
        if let source = preferredSource {
            videoFile.serverMediaStreams = source.mediaStreams?.map { $0.toDictionary() }
            videoFile.serverContainer = source.container
            videoFile.serverSize = source.size
            videoFile.serverBitrate = source.bitrate
            videoFile.serverPath = source.path
            videoFile.remotePlaybackMethod = embyService.playbackMethod(
                for: source,
                resolvedURL: streamUrl,
                playbackQuality: playbackQuality
            )
        }
        
        return videoFile
    }

    private func playlistFiles(from items: [EmbyItem], token: String, playbackQuality: RemotePlaybackQualityOption = .auto, startFromBeginning: Bool = false) -> [VideoFile] {
        items.compactMap { child -> VideoFile? in
            guard child.isPlayable else { return nil }
            return makePlayableFile(item: child, token: token, startFromBeginning: startFromBeginning, playbackQuality: playbackQuality)
        }
    }

    private func playItem(
        item: EmbyItem,
        playbackQualityID: String? = nil,
        audioQuery: String? = nil,
        subtitleQuery: String? = nil,
        preferredAudioOrdinal: Int? = nil,
        preferredSubtitleOrdinal: Int? = nil,
        externalSubtitleCandidates: [ExternalSubtitleCandidate] = [],
        disableSubtitles: Bool = false,
        startFromBeginning: Bool = false
    ) {
        Task {
            let playbackQuality = AppSettings.shared.resolvedRemotePlaybackQualityOption(for: playbackQualityID)
            guard let videoFile = await makePreparedPlayableFile(
                item: item,
                startFromBeginning: startFromBeginning,
                playbackQuality: playbackQuality,
                audioQuery: audioQuery,
                subtitleQuery: subtitleQuery,
                preferredAudioOrdinal: preferredAudioOrdinal,
                preferredSubtitleOrdinal: preferredSubtitleOrdinal,
                externalSubtitleCandidates: externalSubtitleCandidates,
                disableSubtitles: disableSubtitles
            ) else { return }
            
            guard let token = server.accessToken else { return }

            let playlistSource = !episodes.isEmpty ? episodes : containerChildren.filter(\.isPlayable)
            var playlist: [VideoFile] = []
            if !playlistSource.isEmpty {
                playlist = playlistFiles(from: playlistSource, token: token, playbackQuality: playbackQuality, startFromBeginning: startFromBeginning)
            }

            await MainActor.run {
                self.playerFile = videoFile
                self.playerPlaylist = playlist.isEmpty ? [videoFile] : playlist
            }
        }
    }

    private func replayFromStart() {
        if item.type == "Series" {
            Task {
                if let firstEpisode = await firstEpisodeForSeriesReplay() {
                    playItem(item: firstEpisode, playbackQualityID: immediatePlaybackQualityID, startFromBeginning: true)
                }
            }
            return
        }

        playItem(item: item, playbackQualityID: immediatePlaybackQualityID, startFromBeginning: true)
    }

    private var immediatePlaybackQualityID: String {
        AppSettings.shared.resolvedRemotePlaybackQualityID(for: selectedPrePlaybackQualityID)
    }

    private var playButtonTitle: String {
        if item.type == "Series" {
            if let firstEpisode = episodes.first(where: {
                embyResumeDecision(
                    from: effectiveUserData(for: $0),
                    runtimeTicks: $0.runTimeTicks
                ).shouldContinuePlayback
            }) {
                let season = firstEpisode.parentIndexNumber ?? 1
                let episode = firstEpisode.indexNumber ?? 1
                return String(
                    format: NSLocalizedString("Continue Play S%d:E%d", comment: ""),
                    season,
                    episode
                )
            }
            return NSLocalizedString("Start Play", comment: "")
        }
        if embyResumeDecision(
            from: effectiveItemUserData,
            runtimeTicks: item.runTimeTicks,
            playedOverride: effectiveIsPlayed
        ).shouldContinuePlayback {
            return NSLocalizedString("Continue", comment: "")
        }
        return NSLocalizedString("Play", comment: "")
    }

    private var playButtonProgressInfo: PlaybackCTAProgress? {
        let targetItem: EmbyItem
        if item.type == "Series" {
            guard let resumedEpisode = episodes.first(where: {
                embyResumeDecision(
                    from: effectiveUserData(for: $0),
                    runtimeTicks: $0.runTimeTicks
                ).shouldContinuePlayback
            }) else {
                return nil
            }
            targetItem = resumedEpisode
        } else {
            targetItem = item
        }

        let decision = embyResumeDecision(
            from: effectiveUserData(for: targetItem),
            runtimeTicks: targetItem.runTimeTicks,
            playedOverride: targetItem.id == item.id ? effectiveIsPlayed : nil
        )
        guard decision.shouldContinuePlayback else { return nil }
        guard let ticks = effectiveUserData(for: targetItem)?.playbackPositionTicks, ticks > 0 else { return nil }
        let playedSeconds = Int(ticks / 10_000_000)
        guard playedSeconds > 0 else { return nil }

        guard let runtimeTicks = targetItem.runTimeTicks, runtimeTicks > 0 else { return nil }
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

    private func loadPreferredSeasonContext() async {
        guard item.type == "Series",
              initialSeasonId == nil,
              let token = server.accessToken,
              let userId = server.userId else {
            return
        }

        do {
            let resumeItems = try await embyService.getContinueWatching(
                server: server,
                userId: userId,
                token: token,
                limit: 100
            )
            if let resumeItem = resumeItems.first(where: { $0.seriesId == item.id && $0.seasonId != nil }) {
                await MainActor.run {
                    self.resumeSeasonId = resumeItem.seasonId
                }
                return
            }
        } catch {
            print("Failed to load Emby resume context: \(error)")
        }

        do {
            let seriesNextUpItems = try await embyService.getNextUp(
                server: server,
                userId: userId,
                token: token,
                limit: 1,
                seriesId: item.id
            )
            if let nextUpItem = seriesNextUpItems.first(where: { $0.seasonId != nil }) {
                await MainActor.run {
                    self.resumeSeasonId = nextUpItem.seasonId
                }
                return
            }
        } catch {
            print("Failed to load Emby series next up context: \(error)")
        }

        do {
            let nextUpItems = try await embyService.getNextUp(
                server: server,
                userId: userId,
                token: token,
                limit: 100
            )
            if let nextUpItem = nextUpItems.first(where: { $0.seriesId == item.id && $0.seasonId != nil }) {
                await MainActor.run {
                    self.resumeSeasonId = nextUpItem.seasonId
                }
            }
        } catch {
            print("Failed to load Emby next up context: \(error)")
        }
    }

    private func applyPreferredSeriesSeasonIfNeeded() {
        guard item.type == "Series",
              initialSeasonId == nil,
              !hasUserSelectedSeason,
              let preferredSeasonId = resumeSeasonId,
              seasons.contains(where: { $0.id == preferredSeasonId }),
              selectedSeasonId != preferredSeasonId else {
            return
        }

        selectedSeasonId = preferredSeasonId
        Task { await loadEpisodes(seasonId: preferredSeasonId) }
    }
    
    private func loadSeasons() async {
        guard let token = server.accessToken, let userId = server.userId else { return }

        await MainActor.run {
            isLoadingChildren = true
        }

        do {
            let items = try await embyService.getSeasons(server: server, userId: userId, token: token, seriesId: item.id)
            let preferredSeason = items.first(where: { $0.id == preferredSeriesSeasonId }) ?? items.first
            await MainActor.run {
                self.seasons = items
                self.pendingEpisodeId = initialEpisodeId
                self.selectedSeasonId = preferredSeason?.id
            }

            if let preferred = preferredSeason {
                await loadEpisodes(seasonId: preferred.id)
            } else {
                await MainActor.run {
                    isLoadingChildren = false
                }
            }
        } catch {
            await MainActor.run {
                isLoadingChildren = false
            }
            print("Failed to load seasons: \(error)")
        }
    }

    private func firstEpisodeForSeriesReplay() async -> EmbyItem? {
        let currentEpisodes = await MainActor.run { self.episodes }
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
            let firstSeasonEpisodes = try await embyService.getEpisodes(
                server: server,
                userId: userId,
                token: token,
                seriesId: item.id,
                seasonId: firstSeasonId
            )
            return firstSeasonEpisodes.first(where: { $0.type == "Episode" }) ?? firstSeasonEpisodes.first
        } catch {
            print("Failed to load first Emby season for replay: \(error)")
            return currentEpisodes.first(where: { $0.type == "Episode" }) ?? currentEpisodes.first
        }
    }

    private func loadContainerChildren() async {
        guard let token = server.accessToken, let userId = server.userId else { return }

        await MainActor.run {
            isLoadingChildren = true
        }

        do {
            let items = try await embyService.getDirectChildren(
                server: server,
                userId: userId,
                token: token,
                parentId: item.id,
                recursive: item.type == "BoxSet"
            )
            await MainActor.run {
                containerChildren = items
                isLoadingChildren = false
            }
        } catch {
            await MainActor.run {
                isLoadingChildren = false
            }
            print("Failed to load container children: \(error)")
        }
    }
    
    private func loadEpisodes(seasonId: String) async {
        guard let token = server.accessToken, let userId = server.userId else { return }
        
        await MainActor.run {
            isLoading = true
            isLoadingChildren = true
        }
        
        do {
            let items = try await embyService.getEpisodes(server: server, userId: userId, token: token, seriesId: item.id, seasonId: seasonId)
            await MainActor.run {
                self.episodes = items
                self.isLoading = false
                self.isLoadingChildren = false
            }
        } catch {
            await MainActor.run {
                self.isLoading = false
                self.isLoadingChildren = false
            }
            print("Failed to load episodes: \(error)")
        }
    }
    
    private func loadMetadata() async {
        guard let token = server.accessToken, let userId = server.userId else { return }
        
        do {
            let peopleList = try await embyService.getPeople(server: server, itemId: item.id, token: token)
            await MainActor.run {
                self.people = peopleList
            }
        } catch {
            print("Failed to load people: \(error)")
        }
        
        do {
            let similarList = try await embyService.getSimilarItems(server: server, itemId: item.id, userId: userId, token: token)
            await MainActor.run {
                self.similarItems = similarList
            }
        } catch {
            print("Failed to load similar items: \(error)")
        }
    }

    private func resolvePrePlaybackTargetItem() -> EmbyItem? {
        if item.isPlayable { return item }
        if item.type == "Series" {
            return episodes.first(where: { $0.type == "Episode" }) ?? episodes.first
        }
        return episodes.first(where: { $0.isPlayable }) ?? episodes.first
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
            let playbackInfo = try await embyService.getPlaybackInfo(
                server: server,
                itemId: target.id,
                userId: userId,
                token: token
            )

            let streams = preferredPrePlaybackStreams(from: playbackInfo.mediaSources)
            let qualityOptions = AppSettings.shared.visibleRemotePlaybackQualityOptions(
                from: embyService.qualityOptions(from: playbackInfo.mediaSources)
            )
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
            let playbackInfo = try await embyService.getPlaybackInfo(
                server: server,
                itemId: target.id,
                userId: userId,
                token: token
            )
            let externalSubtitleCandidates = embyService.externalSubtitleCandidates(
                server: server,
                itemId: target.id,
                mediaSources: playbackInfo.mediaSources,
                token: token
            )
            let qualityOptions = AppSettings.shared.visibleRemotePlaybackQualityOptions(
                from: embyService.qualityOptions(from: playbackInfo.mediaSources)
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
                let title = prePlaybackTrackDisplayName(stream: stream, fallbackPrefix: NSLocalizedString("Audio", comment: ""), fallbackIndex: index + 1)
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

    private func preferredPrePlaybackStreams(from mediaSources: [EmbyMediaSource]) -> [EmbyMediaStream] {
        embyService.preferredPlaybackStreams(from: mediaSources)
    }

    private func isAudioStreamType(_ rawType: String) -> Bool {
        let type = rawType.lowercased()
        return type == "audio" || type.contains("audio")
    }

    private func isSubtitleStreamType(_ rawType: String) -> Bool {
        let type = rawType.lowercased()
        return type == "subtitle" || type.contains("subtitle") || type.contains("caption")
    }

    private func prePlaybackTrackDisplayName(stream: EmbyMediaStream, fallbackPrefix: String, fallbackIndex: Int) -> String {
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
        playItem(
            item: target,
            playbackQualityID: selectedPlaybackQualityID,
            audioQuery: selectedAudio,
            subtitleQuery: selectedSubtitle,
            preferredAudioOrdinal: selectedAudioOrdinal,
            preferredSubtitleOrdinal: selectedSubtitleOrdinal,
            externalSubtitleCandidates: prePlaybackExternalSubtitleCandidates,
            disableSubtitles: disableSubtitles
        )
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

    private func preferenceScopeKey(for item: EmbyItem) -> String {
        if let seriesId = item.seriesId, !seriesId.isEmpty {
            return "series.\(seriesId)"
        }
        return "item.\(item.id)"
    }

    private func savedTrackQueryPreference(for item: EmbyItem) -> (audioQuery: String?, subtitleQuery: String?, subtitlesDisabled: Bool?) {
        AppSettings.shared.trackQueryPreference(
            provider: server.type.rawValue,
            serverId: server.id.uuidString,
            scopeKey: preferenceScopeKey(for: item)
        )
    }

    private func persistTrackQueryPreference(
        for item: EmbyItem,
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

    private func toggleFavorite() async {
        guard let token = server.accessToken, let userId = server.userId else { return }

        let newStatus = !isFavorite
        do {
            try await embyService.toggleFavorite(
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
            if isCancellationError(error) { return }
            await MainActor.run {
                errorMessage = error.localizedDescription
                showErrorAlert = true
            }
        }
    }

    private func togglePlayed() async {
        guard !isUpdatingPlayedState else { return }
        guard let token = server.accessToken, let userId = server.userId else { return }

        let newStatus = !effectiveIsPlayed
        await MainActor.run {
            isUpdatingPlayedState = true
        }

        do {
            try await embyService.togglePlayed(
                server: server,
                itemId: item.id,
                userId: userId,
                token: token,
                isPlayed: newStatus
            )
            await MainActor.run {
                isPlayed = newStatus
                isUpdatingPlayedState = false
                downloadToastMessage = NSLocalizedString(newStatus ? "Marked as Played" : "Marked as Unplayed", comment: "")
                PlaybackRefreshCenter.updateRemoteItem(
                    serverId: server.id,
                    itemId: item.id,
                    seriesId: item.seriesId,
                    seasonId: item.seasonId,
                    snapshot: RemotePlaybackStateSnapshot.manualPlayedState(
                        played: newStatus,
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

    private func toggleLocalFavorite() {
        guard let file = localFavoritePlayableFile,
              let identityPath = localFavoriteIdentityPath else {
            return
        }
        favoriteService.toggleFavorite(file: file, folderPath: identityPath)
        downloadToastMessage = NSLocalizedString(favoriteService.isFavorite(file: file) ? "Added to Favorites" : "Removed from Favorites", comment: "")
    }

    private func effectiveUserData(for targetItem: EmbyItem) -> EmbyUserData? {
        return embyEffectiveUserData(
            for: targetItem,
            serverId: server.id,
            remotePlaybackState: remotePlaybackState
        )
    }

    private func refreshPlaybackContextFromServer() async {
        if item.type == "Series" {
            await loadSeasons()
            return
        }

        if item.isContainer {
            await loadContainerChildren()
        }
    }

    private func handleRemotePlaybackRefresh(_ payload: PlaybackStateRefreshPayload) {
        guard payload.serverId == server.id else { return }

        let isRelevant =
            payload.itemId == item.id ||
            payload.seriesId == item.id ||
            payload.seasonId == item.id ||
            payload.seasonId == selectedSeasonId ||
            episodes.contains(where: { $0.id == payload.itemId }) ||
            containerChildren.contains(where: { $0.id == payload.itemId })

        guard isRelevant else { return }

        Task { await refreshPlaybackContextFromServer() }
    }

    private func toggleChildPlayed(_ child: EmbyItem) async {
        guard let token = server.accessToken, let userId = server.userId else { return }
        let currentPlayed = effectiveUserData(for: child)?.played ?? false
        let nextPlayed = !currentPlayed
        do {
            try await embyService.togglePlayed(
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
                await loadEpisodes(seasonId: seasonId)
            }
        } catch {
            print("Failed to toggle child played state: \(error.localizedDescription)")
        }
    }

    private func deleteItem(_ targetItem: EmbyItem) async {
        isDeleting = true
        do {
            try await embyService.deleteItem(server: server, itemId: targetItem.id, token: server.accessToken ?? "")

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
                            Task { await loadEpisodes(seasonId: nextSeason.id) }
                        } else {
                            selectedSeasonId = nil
                            episodes = []
                        }
                    }
                } else {
                    episodes.removeAll(where: { $0.id == targetItem.id })
                    containerChildren.removeAll(where: { $0.id == targetItem.id })
                }
            }
        } catch {
            if isCancellationError(error) { return }
            print("Failed to delete item from Emby server: \(error.localizedDescription)")
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
}

struct EmbyEpisodeRow: View {
    let item: EmbyItem
    let server: ServerConfig
    @ObservedObject private var remotePlaybackState = RemotePlaybackStateStore.shared
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                RemoteImage(url: item.primaryImageURL(server: server, maxWidth: 300))
                    .aspectRatio(16/9, contentMode: .fill)
                    .frame(width: 120, height: 68)
                    .clipped()
                    .cornerRadius(8)
                
                if let progress = effectiveUserData?.playedPercentage, progress > 0 {
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: 120 * CGFloat(progress / 100), height: 3)
                }
            }
            .frame(width: 120, height: 68)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(2)
                    .foregroundColor(.white)
                
                HStack(spacing: 8) {
                    if let episodeNumber = item.indexNumber {
                        Text(String(format: NSLocalizedString("Episode %d", comment: ""), episodeNumber))
                    }
                    if let runtime = item.runtimeMinutes {
                        Text("• \(runtime) \(NSLocalizedString("Minutes", comment: ""))")
                    }
                }
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.72))

                let detailSegments = embyDetailMetadataSegments(for: item)
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

    private var effectiveUserData: EmbyUserData? {
        return embyEffectiveUserData(
            for: item,
            serverId: server.id,
            remotePlaybackState: remotePlaybackState
        )
    }
}

private struct EmbyContainerChildRow: View {
    let item: EmbyItem
    let server: ServerConfig
    let isPlayable: Bool

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: item.primaryImageURL(server: server, maxWidth: 300))
                .aspectRatio(16/9, contentMode: .fill)
                .frame(width: 120, height: 68)
                .clipped()
                .cornerRadius(4)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.body)
                    .fontWeight(.medium)
                    .lineLimit(2)
                    .foregroundColor(.white)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(1)
                }

                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                        .lineLimit(2)
                }
            }

            Spacer()

            Image(systemName: isPlayable ? "play.circle" : "chevron.right")
                .font(.title2)
                .foregroundColor(isPlayable ? .accentColor : .white.opacity(0.6))
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
