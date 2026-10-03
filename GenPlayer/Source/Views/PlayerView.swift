import SwiftUI
import GenPlayerShell
#if os(iOS)
import UIKit
#endif
import UniformTypeIdentifiers

private struct RemoteSkipAvailability: Equatable {
    let previous: Bool
    let next: Bool
}

private extension Notification.Name {
    static let playerRemoteNextTrackRequested = Notification.Name("GenPlayer.PlayerView.RemoteNextTrackRequested")
    static let playerRemotePreviousTrackRequested = Notification.Name("GenPlayer.PlayerView.RemotePreviousTrackRequested")
}

private func playbackStartTimeTicks(from seconds: TimeInterval?) -> Int64? {
    guard let seconds, seconds > 0 else { return nil }
    return Int64(seconds * 10_000_000.0)
}

struct PlayerView: View {
    @ObservedObject private var playbackService = VLCPlaybackService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var epgService = EPGService.shared
    let initialFile: VideoFile
    @Binding var playlist: [VideoFile]?
    
    /// Convenience init: wraps a static playlist value in .constant() binding
    init(initialFile: VideoFile, playlist: [VideoFile]? = nil) {
        self.initialFile = initialFile
        self._playlist = .constant(playlist)
    }
    
    /// Binding init: for deferred playlist loading (Jellyfin/Emby)
    init(initialFile: VideoFile, playlist: Binding<[VideoFile]?>) {
        self.initialFile = initialFile
        self._playlist = playlist
    }
    
    @Environment(\.presentationMode) var presentationMode
    @Environment(\.scenePhase) var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    
    // State
    @State private var isPlaylistLoaded: Bool = false
    @State private var loadedPlaylist: [VideoFile]? = nil
    @State private var loadedInitialIndex: Int = 0
    @State private var currentMediaItem: MediaItem? // Stable reference for playback
    @State private var isResolvingInitialAListPlayback = false
    @State private var showPlaylist: Bool = false
    @State private var showVideoInfo: Bool = false
    @State private var showProgramGuideSheet: Bool = false
    @State private var isLocked: Bool = false
    @State private var isImportingSubtitle = false
    @State private var isDropTargetingSubtitle: Bool = false
    @State private var remoteSubtitleLoadTask: Task<Void, Never>? = nil
    @State private var playbackQualityOptions: [RemotePlaybackQualityOption] = []
    @State private var sessionPlaybackQualityID: String? = nil
    @State private var activeMenuScreen: PlayerFloatingMenuScreen? = nil
    @State private var floatingMenuPresentationID = UUID()
    @State private var menuTriggerFrames: [PlayerFloatingMenuScreen: CGRect] = [:]
    @State private var liveTextTargetImage: UIImage? = nil
    @State private var isShowingLiveTextViewer: Bool = false
    
    // Gesture State
    @State private var dragOffset: CGSize = .zero
    @State private var gestureContainerSize: CGSize = .zero
    @State private var ignoresDragUntilEnd = false
    @GestureState private var isTouchDragActive = false
    @GestureState private var isSubtitleDragActive = false
    @State private var ignoresSubtitleDragUntilEnd = false
    @State private var cancelsCurrentScrub = false
    @State private var initialBrightness: CGFloat = 0
    @State private var initialVolume: Float = 0
    @State private var initialSeekTime: Int = 0
    @State private var isDragging: Bool = false
    @State private var dragType: DragType = .none
    @State private var secondarySubtitleDragInitialRatio: CGFloat?
    @State private var isSecondarySubtitlePositionAdjustmentActive: Bool = false
    @State private var secondarySubtitleAdjustmentHideWorkItem: DispatchWorkItem?
    
    // Feedback State
    @State private var feedbackData: FeedbackData?
    @State private var feedbackHideWorkItem: DispatchWorkItem?
    @State private var overlayDismissWorkItem: DispatchWorkItem?
    
    @State private var remoteFolderSubtitleURLs: [URL]? = nil
    @State private var interactiveZoomFeedbackText: String? = nil
    @State private var interactiveZoomFeedbackHideWorkItem: DispatchWorkItem?
    @State private var interactiveZoomResetHintWorkItem: DispatchWorkItem?
    @State private var hasShownInteractiveZoomResetHint: Bool = false
    @State private var overlayHideTimer: Timer?
    @State private var lastInteractionTime: Date = Date()
    @State private var isMenuPresented: Bool = false
    @State private var hasHandledAutoRotateForCurrentItem: Bool = false
    @State private var autoRotateHandledItemID: UUID? = nil
    @State private var autoRotateTargetOrientation: UIInterfaceOrientation? = nil
    @State private var autoRotateAttemptCount: Int = 0
    @State private var isAutoRotateAttemptInFlight: Bool = false
    @State private var autoRotateRetryWorkItem: DispatchWorkItem? = nil
    @State private var lastAutoAdvancedEndedItemID: UUID? = nil
    @State private var isAutoAdvancingAfterEnd: Bool = false
    @State private var safeAreaInsets: UIEdgeInsets = .zero
    @State private var topControlSafeAreaInsets: UIEdgeInsets?
    @State private var bottomControlSafeAreaInsets: UIEdgeInsets?
    @State private var overlayLayoutRefreshToken: UUID = UUID()
    @State private var remoteSkipAvailability = RemoteSkipAvailability(previous: false, next: false)
    @State private var seekPreviewImage: UIImage? = nil
    @State private var seekPreviewTargetTime: Double? = nil
    @State private var seekPreviewInitialTime: Double? = nil
    @State private var seekPreviewSessionID: UUID? = nil
    @State private var seekPreviewCaptureWorkItem: DispatchWorkItem?
    @State private var seekPreviewRequestID: UUID? = nil
    @State private var seekPreviewPendingTargetTime: Double? = nil
    @State private var seekPreviewRequestInFlight: Bool = false
    @State private var seekPreviewLastRequestedTime: Double? = nil
    @State private var seekPreviewDisplayedImageTargetTime: Double? = nil
    @State private var lastSeekPreviewCaptureDate: Date = .distantPast
    @State private var scrubPreviewProgress: Float? = nil
    @State private var isLongPressQuickPlaybackActive: Bool = false
    @State private var isQuickPlaybackSpeedLocked: Bool = false
    @State private var longPressQuickPlaybackRestoreRate: Float? = nil
    @State private var originalPlaybackRateBeforeLock: Float? = nil
    @State private var activeQuickPlaybackRate: Float? = nil
    @State private var suppressTapActionsUntil: Date = .distantPast
    @State private var suppressVolumeFeedbackUntil: Date = .distantPast
    @State private var videoPlayMode: PlaybackSequenceMode = .sequential
    @State private var videoPlaybackHistory: [Int] = []
    @State private var skipAutoRotateForItemID: UUID? = nil
    
    struct FeedbackData: Equatable {
        let icon: String
        let text: String
    }
    
    enum DragType {
        case none, volume, brightness, seek, secondarySubtitlePosition, speedLock
    }

    private enum PlaylistNavigationOrigin {
        case userInitiated
        case autoAdvance
        case historyBack
        case replay
    }

    private var isShowingSeekPreview: Bool {
        guard !isLocked, seekPreviewTargetTime != nil else { return false }
        return dragType == .seek || playbackService.isScrubbing
    }

    private var seekPreviewShowsLoadingIndicator: Bool {
        guard isShowingSeekPreview else { return false }
        guard seekPreviewImage == nil else { return false }
        return seekPreviewRequestInFlight ||
            seekPreviewPendingTargetTime != nil ||
            seekPreviewCaptureWorkItem != nil
    }

    private var playerBottomBarProgressBinding: Binding<Float> {
        Binding(
            get: { scrubPreviewProgress ?? playbackService.progress },
            set: { newValue in
                guard !cancelsCurrentScrub else { return }
                scrubPreviewProgress = min(max(0.0, newValue), 1.0)
            }
        )
    }

    private var displayedScrubCurrentTimeText: String {
        guard let previewProgress = scrubPreviewProgress, playbackService.maxDuration > 0 else {
            return playbackService.currentTime
        }
        return playbackService.formatTime(Int(Double(previewProgress) * playbackService.maxDuration))
    }

    private var pressAndHoldQuickPlaybackTargetRate: Float? {
        let configuredRate = Float(AppSettings.shared.pressAndHoldPlaybackSpeed)
        guard configuredRate > 1.0 else { return nil }
        return configuredRate
    }

    private var quickPlaybackLongPressDuration: Double { 0.35 }

    private var quickPlaybackLongPressMaxDistance: CGFloat { 60 }

    private var canHandleTapGestureAction: Bool {
        Date() >= suppressTapActionsUntil &&
            !isLongPressQuickPlaybackActive &&
            !playbackService.isInteractiveVideoGestureActive
    }

    private var isRemoteSeekPreview: Bool {
        playbackService.state.currentItem?.isRemote == true || currentMediaItem?.isRemote == true
    }

    private var remoteSeekPreviewFrameInterval: Double? {
        guard isRemoteSeekPreview else { return nil }
        guard let interval = playbackService.remoteSeekPreviewFrameIntervalSeconds,
              interval > 0.25 else {
            return nil
        }
        return interval
    }

    private var activePlaybackFile: VideoFile {
        playbackService.state.currentItem?.videoFile ?? currentMediaItem?.videoFile ?? initialFile
    }

    private var showsDownloadedIconBeforeTitle: Bool {
        let file = activePlaybackFile
        guard hasMediaServerLibraryContext(file) else { return false }
        // Offline downloaded library items: URL is local (isRemote=false) but they ARE the downloaded file
        if shouldTreatAsDownloadedLibraryItem(file) { return true }
        // Remote files: check download center
        guard file.isRemote else { return false }
        return downloadCenter.isDownloaded(file: file)
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            HiddenVolumeView()
                .frame(width: 0, height: 0)
            
            // 1. Video Layer (Now independent of GeometryReader, so it NEVER zooms)
            videoLayer
            
            // 2. Subtitle Layer
            SubtitleOverlayLayer()
            
            // 3. Buffering / Loading Indicator (centered, glass pill overlay)
            if (playbackService.isBuffering || !playbackService.isPlaying) && playbackService.state.status != .paused && playbackService.state.status != .error && playbackService.state.status != .idle {
                if playbackService.loadingPhase == .waitingForChoice {
                    PlaybackLoadingOverlay(
                        phase: playbackService.loadingPhase,
                        onContinueWaiting: playbackService.continueWaitingForPlayback,
                        onRetry: retryPlaybackAfterFailure,
                        onClose: closePlayerAfterFailure
                    )
                    .zIndex(150)
                } else {
                    BufferingIndicator(messageKey: playbackService.loadingPhase == .slow
                        ? "Loading is taking longer than usual…" : "Loading...")
                }
            }

            PlayerFloatingMenuOverlay(
                playbackService: playbackService,
                activeScreen: $activeMenuScreen,
                triggerFrames: menuTriggerFrames,
                onImportSubtitle: { isImportingSubtitle = true },
                onInfo: {
                    dismissFloatingMenu()
                    showVideoInfo.toggle()
                },
                playbackQualityOptions: playbackQualityOptions,
                selectedPlaybackQualityID: sessionPlaybackQualityID,
                onSelectPlaybackQuality: switchCurrentPlaybackQuality,
                onAction: showFeedback,
                onDismiss: dismissFloatingMenu
            )
            .zIndex(120)
            
            // Subtitle Drop Overlay
            if isDropTargetingSubtitle {
                SubtitleDropOverlay()
                    .zIndex(200)
                    .allowsHitTesting(false)
            }

            // Controls Layer (respects safe area via GeometryReader)
            GeometryReader { geometry in
                controlsOverlayLayer(geometry: geometry)
                    .onAppear { playbackService.updateSecondarySubtitleLayout(for: geometry.size) }
                    .onChange(of: geometry.size) { size in
                        playbackService.updateSecondarySubtitleLayout(for: size)
                        cancelGesturesForLayoutChange()
                    }
            }
            .ignoresSafeArea()
        }
        .background(PlaybackFailureAlertPresenter(
            failure: playbackService.activePlaybackFailure,
            onRetry: retryPlaybackAfterFailure,
            onClose: closePlayerAfterFailure,
            onUseVLC: playbackService.canRecoverMPVWithVLC ? { playbackService.recoverMPVWithVLC() } : nil
        ))
        .navigationBarHidden(true)
        .preferredColorScheme(.dark)
        .persistentSystemOverlaysCompat(hidden: !playbackService.showControlOverlay)
        .onPreferenceChange(PlayerMenuTriggerPreferenceKey.self) { frames in
            menuTriggerFrames = frames
        }
        .background(IOSSubtitleIntelligenceHost(model: playbackService.subtitleIntelligence))
        .sheet(isPresented: Binding(get: { playbackService.subtitleIntelligence.showingSettings },
                                    set: { playbackService.subtitleIntelligence.showingSettings = $0 })) {
            IOSSubtitleIntelligenceSettings(model: playbackService.subtitleIntelligence).equatable()
        }
        .sheet(isPresented: $playbackService.showSubtitleBrowser) {
            IOSPlayerSubtitleBrowser(playbackService: playbackService)
        }
        .sheet(isPresented: $showVideoInfo) {
            VideoInfoView(playbackService: playbackService)
        }
        .sheet(isPresented: $showPlaylist) {
            if let playlist = loadedPlaylist {
                PlaylistView(
                    playbackService: playbackService,
                    showPlaylist: $showPlaylist,
                    playlist: playlist,
                    onSelect: { index in
                        playItem(at: index)
                    }
                )
            }
        }
        .sheet(isPresented: $showProgramGuideSheet) {
            programGuideSheetView
        }
        .fileImporter(
            isPresented: $isImportingSubtitle,
            allowedContentTypes: subtitleImportTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let firstURL = urls.first {
                    importExternalSubtitle(from: firstURL)
                }
            case .failure(let error):
                showFeedback(icon: "exclamationmark.triangle", text: error.localizedDescription)
            }
        }
        .onReceive(playbackService.$state) { state in
            syncRemoteSkipAvailability()

            if state.status != .ended {
                if isAutoAdvancingAfterEnd,
                   state.status == .playing || state.status == .buffering || state.status == .paused || state.status == .idle {
                    isAutoAdvancingAfterEnd = false
                }
                return
            }

            guard !isAutoAdvancingAfterEnd else { return }
            guard let endedItemID = state.currentItem?.id else { return }
            guard lastAutoAdvancedEndedItemID != endedItemID else { return }

            // Guard against instant-skip loops:
            // Only auto-play if we actually played some content (e.g. > 5s or > 50%)
            // Or if the video is very short naturally.
            let isValidPlayback = state.duration < 10 || state.currentTime > 5 || state.progress > 0.5

            if isValidPlayback, nextPlaylistIndex() != nil {
                lastAutoAdvancedEndedItemID = endedItemID
                // Dispatch to next run loop to avoid state update cycles
                DispatchQueue.main.async {
                    playNext(autoTriggered: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerRemoteNextTrackRequested)) { _ in
            playNext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerRemotePreviousTrackRequested)) { _ in
            playPrevious()
        }
        .onReceive(playbackService.$outputVolume.dropFirst()) { newVolume in
            // Ignore hardware volume triggers if the user is actively swiping the screen to change volume
            guard !isDragging, Date() >= suppressVolumeFeedbackUntil else { return }
            
            let val = max(0.0, min(1.0, newVolume))
            let icon: String
            if val == 0 { icon = "speaker.slash.fill" }
            else if val < 0.3 { icon = "speaker.wave.1.fill" }
            else if val < 0.6 { icon = "speaker.wave.2.fill" }
            else { icon = "speaker.wave.3.fill" }
            
            showFeedback(icon: icon, text: "\(Int(val * 100))%")
        }
        .onAppear {
            suppressVolumeFeedbackUntil = Date().addingTimeInterval(0.8)
            if !isPlaylistLoaded { loadPlaylistFromDirectory() }
            configureRemoteCommandsForVideoPlayback()
            playbackService.refreshTracks()
            hasHandledAutoRotateForCurrentItem = false
            if currentMediaItem == nil {
                if let restoredItem = playbackService.restoredPictureInPictureMediaItem(for: initialFile) {
                    currentMediaItem = restoredItem
                    skipAutoRotateForItemID = restoredItem.id
                    if let resumePos = restoredItem.startPosition, resumePos > 0 {
                        currentMediaItem?.videoFile?.lastPlayedPosition = resumePos
                    }
                    print("[PiP] reusing current media item during restore for \(initialFile.name)")
                } else {
                    let initialPlaybackFile = refreshedInitialPlaybackFile(initialFile)
                    if !initialPlaybackFile.isRemote {
                        if !FileManager.default.fileExists(atPath: initialPlaybackFile.url.path) {
                            skipAutoRotateForItemID = nil
                            let itemUUID = UUID(uuidString: initialPlaybackFile.id) ?? UUID()
                            playbackService.activePlaybackFailure = VLCPlaybackService.PlaybackFailure(
                                itemID: itemUUID,
                                message: NSLocalizedString("The local file does not exist or has been deleted.", comment: "")
                            )
                            playbackService.state.status = .error
                            return
                        }
                    }
                    skipAutoRotateForItemID = nil
                    var item = MediaItem(
                        url: initialPlaybackFile.url,
                        title: initialPlaybackFile.name,
                        isRemote: initialPlaybackFile.isRemote,
                        jellyfinItemId: initialPlaybackFile.jellyfinItemId,
                        jellyfinServerId: initialPlaybackFile.jellyfinServerId,
                        serverType: initialPlaybackFile.serverType,
                        seriesId: initialPlaybackFile.seriesId,
                        seasonId: initialPlaybackFile.seasonId,
                        startPosition: initialPlaybackFile.shouldResetRemotePlayedStateOnPlaybackStart ? 0 : initialPlaybackFile.lastPlayedPosition
                    )
                    item.serverMediaStreams = initialPlaybackFile.serverMediaStreams
                    item.serverContainer = initialPlaybackFile.serverContainer
                    item.serverSize = initialPlaybackFile.serverSize
                    item.serverBitrate = initialPlaybackFile.serverBitrate
                    item.serverPath = initialPlaybackFile.serverPath
                    item.remotePlaybackMethod = initialPlaybackFile.remotePlaybackMethod
                    item.shouldResetRemotePlayedStateOnPlaybackStart = initialPlaybackFile.shouldResetRemotePlayedStateOnPlaybackStart
                    item.mediaSourceId = mediaSourceID(from: initialPlaybackFile.url)
                    item.playSessionId = playSessionID(from: initialPlaybackFile.url)
                    item.videoFile = initialPlaybackFile
                    item.externalSubtitleCandidates = initialPlaybackFile.externalSubtitleCandidates
                    item.preferredAudioTrackQuery = initialPlaybackFile.preferredAudioTrackQuery
                    item.preferredSubtitleTrackQuery = initialPlaybackFile.preferredSubtitleTrackQuery
                    item.preferredAudioTrackOrdinal = initialPlaybackFile.preferredAudioTrackOrdinal
                    item.preferredSubtitleTrackOrdinal = initialPlaybackFile.preferredSubtitleTrackOrdinal
                    item.preferredPlaybackQualityID = initialPlaybackFile.preferredPlaybackQualityID
                    item.availablePlaybackQualityOptions = initialPlaybackFile.availablePlaybackQualityOptions
                    if initialPlaybackFile.disableSubtitlesOnStart {
                        item.savedSubtitleTrackIndex = -1
                    }
                    item.externalSubtitleURL = prepareExternalSubtitles(for: initialPlaybackFile)
                    currentMediaItem = item
                    if var playlist = loadedPlaylist,
                       let index = playlist.firstIndex(where: { playlistItemsMatch($0, initialFile) }) {
                        playlist[index] = anchoredCurrentFile(current: initialPlaybackFile, fallback: playlist[index])
                        loadedPlaylist = playlist
                    }
                }
                let startupFile = currentMediaItem?.videoFile ?? initialFile
                if shouldResolveRemotePlaybackForCurrentSession(startupFile) {
                    sessionPlaybackQualityID = AppSettings.shared.resolvedRemotePlaybackQualityID(for: startupFile.preferredPlaybackQualityID)
                    playbackQualityOptions = AppSettings.shared.visibleRemotePlaybackQualityOptions(from: startupFile.availablePlaybackQualityOptions)
                } else {
                    sessionPlaybackQualityID = nil
                    playbackQualityOptions = []
                }
                loadRemoteExternalSubtitlesIfNeeded(for: startupFile)
                hydrateDownloadedLibraryMetadataIfNeeded(for: startupFile)
                Task { await refreshPlaybackQualityOptions(for: startupFile) }
            }
            syncRemoteSkipAvailability(force: true)
            if let currentItemID = currentMediaItem?.id,
               skipAutoRotateForItemID == currentItemID {
                hasHandledAutoRotateForCurrentItem = true
                print("[PiP] skipping auto-rotate for restored PlayerView \(initialFile.name)")
            } else {
                applyAutoRotatePreferenceIfNeeded()
            }
            playbackService.fitMacWindowToVideoAspectRatioIfNeeded()
        }
        .onChange(of: playbackService.state.videoResolution) { _ in
            playbackService.fitMacWindowToVideoAspectRatioIfNeeded()
        }
        .onDisappear {
            remoteSubtitleLoadTask?.cancel()
            secondarySubtitleAdjustmentHideWorkItem?.cancel()
            cancelPendingAutoRotateRetry()
            isAutoRotateAttemptInFlight = false
            isMenuPresented = false
            playbackService.isMenuPresented = false
            endLongPressQuickPlaybackIfNeeded()
            restoreOrientation()
            dismissFeedback()
            playbackService.isScrubbing = false
            clearSeekPreview()
            clearRemoteCommandsForVideoPlayback()
            if !playbackService.isVideoPiPActive &&
                !playbackService.isAudioFloatingVisible &&
                !playbackService.shouldSuppressStopForPlayerViewDisappearDuringRestore() {
                playbackService.stop()
            }
            UIApplication.refreshInterfaceChrome()
        }
        .onChange(of: playbackService.shouldDismissPresentedPlayerAfterPiPStart) { shouldDismiss in
            guard shouldDismiss else { return }
            playbackService.consumePresentedPlayerPiPDismissRequest()
            presentationMode.wrappedValue.dismiss()
        }
        .onChange(of: playlist) { newPlaylist in
            // Support deferred playlist loading: parent can update playlist after PlayerView is shown
            guard let newPlaylist = newPlaylist, newPlaylist.count > 1 else { return }
            let supportedExtensions = VideoFile.FileType.allSupportedExtensions
            let playlistFiles = newPlaylist.filter {
                $0.isRemote || supportedExtensions.contains($0.url.pathExtension.lowercased())
            }.map(offlinePreferredPlaybackFile)
            guard !playlistFiles.isEmpty else { return }
            print("[PlayerView] Playlist updated externally: \(playlistFiles.count) items")
            loadedPlaylist = playlistFiles
            // Re-find current item index
            if let current = currentMediaItem {
                loadedInitialIndex = playlistFiles.firstIndex(where: { playlistItemMatches($0, mediaItem: current) }) ?? 0
            }
            syncRemoteSkipAvailability(force: true)
        }
        .onChange(of: loadedPlaylist?.count ?? 0) { _ in
            videoPlaybackHistory.removeAll()
            normalizeVideoPlayModeIfNeeded()
            syncRemoteSkipAvailability(force: true)
        }
        .onReceive(playbackService.$state) { _ in
            applyAutoRotatePreferenceIfNeeded()
        }
        .onDrop(of: subtitleDropTypes, isTargeted: $isDropTargetingSubtitle) { providers in
            handleDroppedSubtitleProviders(providers)
            return true
        }

    }
    

    
    // MARK: - Sub-Views

    @ViewBuilder
    private var programGuideSheetView: some View {
        if let currentItem = playbackService.state.currentItem,
           let serverIdStr = currentItem.jellyfinServerId,
           let serverId = UUID(uuidString: serverIdStr),
           let server = AppNetworkService.shared.servers.first(where: { $0.id == serverId }) {
            let channel = IPTVChannel(
                id: currentItem.jellyfinItemId ?? "",
                name: currentItem.title,
                url: currentItem.url
            )
            IPTVProgramGuideSheet(
                channel: channel,
                server: server,
                onPlay: {
                    showProgramGuideSheet = false
                }
            )
        }
    }

    @ViewBuilder
    private var videoLayer: some View {
        if isPlaylistLoaded, let _ = loadedPlaylist {
            if let item = currentMediaItem {
                VLCPlayerView(
                    playbackService: playbackService,
                    item: item,
                    onReady: {
                        handlePlayerReady(for: item)
                    }
                )
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }
        } else {
            BufferingIndicator()
        }
    }

    private func handlePlayerReady(for item: MediaItem) {
        if playbackService.shouldReuseCurrentPlaybackSession(for: initialFile) {
            print("[PiP] restored PlayerView reattached to existing playback session for \(initialFile.name)")
            return
        }

        // Reappearing after a background pause or a sheet does not request a new
        // playback session. Keep its pause/failure/preparation state until play.
        guard playbackService.state.currentItem?.id != item.id else { return }

        if let videoFile = item.videoFile,
           videoFile.isRemote,
           (videoFile.serverType?.requiresDynamicPlaybackURL == true),
           videoFile.url.isFileURL {
            guard !isResolvingInitialAListPlayback,
                  playbackService.activePlaybackFailure?.itemID != item.id else {
                return
            }

            isResolvingInitialAListPlayback = true
            Task {
                do {
                    let playbackFile = try await AppNetworkService.shared.resolvedPlaybackFile(videoFile)
                    await MainActor.run {
                        isResolvingInitialAListPlayback = false
                        guard currentMediaItem?.id == item.id else { return }
                        playResolvedVideoFile(playbackFile, startFromBeginning: false)
                    }
                } catch {
                    await MainActor.run {
                        isResolvingInitialAListPlayback = false
                        let failure = VLCPlaybackService.PlaybackFailure(
                            itemID: item.id,
                            message: error.localizedDescription
                        )
                        playbackService.activePlaybackFailure = failure
                    }
                }
            }
            return
        }

        playbackService.play(item: item)
    }

    @ViewBuilder
    private func controlsOverlayLayer(geometry: GeometryProxy) -> some View {
        let isLandscape = geometry.size.width > geometry.size.height
        let usesRegularLayout = horizontalSizeClass == .regular
        let usesCustomStatusBar = usesRegularLayout || verticalSizeClass == .compact
        let overlayHorizontalPadding = playerOverlayHorizontalPadding(usesRegularLayout: usesRegularLayout, isLandscape: isLandscape)
        let overlayHorizontalInsets = playerOverlayHorizontalInsets(basePadding: overlayHorizontalPadding)
        let topControlHorizontalInsets = playerOverlayHorizontalInsets(
            basePadding: overlayHorizontalPadding,
            safeArea: topControlSafeAreaInsets
        )
        let bottomHorizontalInsets = playerOverlayHorizontalInsets(
            basePadding: overlayHorizontalPadding,
            safeArea: bottomControlSafeAreaInsets
        )
        let showsExtendedTransportControls = AdaptiveMediaLayout.showsExtendedTransportControls(
            availableWidth: geometry.size.width - bottomHorizontalInsets.leading - bottomHorizontalInsets.trailing,
            regularWidth: usesRegularLayout
        )
        let overlayTopBarCompensation = playerTopBarHorizontalCompensation(usesRegularLayout: usesRegularLayout)
        let overlayBottomControlSpacing = playerBottomControlSpacing(usesRegularLayout: usesRegularLayout, isLandscape: isLandscape)
        let overlayTopPadding = playerOverlayTopPadding(usesCustomStatusBar: usesCustomStatusBar)
        let overlayBottomPadding = playerOverlayBottomPadding(isLandscape: isLandscape)
        let overlayVideoRect = calculateVideoRect(containerSize: geometry.size, videoSize: playbackService.videoNaturalSize)
        let feedbackMinimumTopPadding = isLandscape
            ? (overlayTopPadding + 32)
            : (overlayTopPadding + (usesCustomStatusBar ? 88 : 72))
        let feedbackOverlayTopPadding = playerFeedbackOverlayTopPadding(
            containerSize: geometry.size,
            videoRect: overlayVideoRect,
            minimumTopPadding: feedbackMinimumTopPadding,
            overlayHeight: 60,
            isLandscape: isLandscape
        )
        let seekPreviewOverlayTopPadding = playerFeedbackOverlayTopPadding(
            containerSize: geometry.size,
            videoRect: overlayVideoRect,
            minimumTopPadding: feedbackMinimumTopPadding,
            overlayHeight: 196,
            isLandscape: isLandscape
        )
        let _ = overlayLayoutRefreshToken
        
        ZStack {
            WindowLayoutReader { metrics in
                safeAreaInsets = metrics.safeAreaInsets
            }
            .allowsHitTesting(false)

            // 4. Gesture Layer (Invisible but active)
            if !isShowingLiveTextViewer {
                if !isLocked {
                    GestureLayer()
                        .zIndex(10)
                } else {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation { playbackService.showControlOverlay.toggle() }
                        }
                }

                if !isLocked {
                    SecondarySubtitleAdjustmentHitLayer(containerSize: geometry.size)
                        .zIndex(25)
                }
            }
            
            // 5. Controls Overlay
            if playbackService.showControlOverlay && !isShowingLiveTextViewer {
                ZStack {
                    // Top Bar Area
                    topBarArea(
                        usesCustomStatusBar: usesCustomStatusBar,
                        overlayTopPadding: overlayTopPadding,
                        overlayHorizontalInsets: overlayHorizontalInsets,
                        topControlHorizontalInsets: topControlHorizontalInsets,
                        overlayTopBarCompensation: overlayTopBarCompensation,
                        usesRegularLayout: usesRegularLayout
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                    
                    // Side Controls
                    SideControlsView(
                        playbackService: playbackService, 
                        isLocked: $isLocked,
                        leadingPadding: playerSideControlPadding(isLandscape: isLandscape, edge: .leading),
                        trailingPadding: playerSideControlPadding(isLandscape: isLandscape, edge: .trailing),
                        onAction: showFeedback,
                        onMenuWillOpen: handleMenuWillOpen,
                        onMenuDismiss: dismissFloatingMenu,
                        onOpenAspectRatioMenu: { presentFloatingMenu(.aspectRatio) },
                        onRotateCompleted: handleRotationCompleted
                    )
                    .transition(.opacity)
                    
                    // Bottom Bar
                    bottomBarArea(
                        isLandscape: isLandscape,
                        usesRegularLayout: usesRegularLayout,
                        overlayBottomPadding: overlayBottomPadding,
                        overlayHorizontalInsets: bottomHorizontalInsets,
                        showsExtendedTransportControls: showsExtendedTransportControls,
                        overlayBottomControlSpacing: overlayBottomControlSpacing
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        lastInteractionTime = Date()
                    }
                )
                .zIndex(50)
            }
            
            // 7. Quick Playback Prompt
            quickPlaybackPromptView(overlayBottomPadding: overlayBottomPadding)
            
            // 6. Feedback Overlay
            feedbackOverlayView(
                feedbackOverlayTopPadding: feedbackOverlayTopPadding,
                seekPreviewOverlayTopPadding: seekPreviewOverlayTopPadding
            )

            // 8. Live Text Viewer Overlay
            if isShowingLiveTextViewer, let liveTextImage = liveTextTargetImage {
                PlayerLiveTextViewer(image: liveTextImage, onDismiss: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isShowingLiveTextViewer = false
                        liveTextTargetImage = nil
                    }
                })
                .transition(.opacity)
                .zIndex(200)
            }
        }
        .onReceive(playbackService.$showControlOverlay) { show in
            overlayHideTimer?.invalidate()
            if show {
                refreshSafeAreaInsetsFromWindow()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    refreshSafeAreaInsetsFromWindow()
                }
                scheduleOverlayHide()
            } else {
                activeMenuScreen = nil
                isMenuPresented = false
                playbackService.isMenuPresented = false
            }
        }
        .onChange(of: isLocked) { locked in
            if locked {
                // Instantly trigger the hide timer from the lock event
                playbackService.showControlOverlay = true
            }
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase != .active {
                endLongPressQuickPlaybackIfNeeded()
                dismissFeedback()
                dismissInteractiveZoomFeedback()
                isDragging = false
                dragType = .none
                dragOffset = .zero
                secondarySubtitleDragInitialRatio = nil
                playbackService.isScrubbing = false
                playbackService.clearAllInteractiveVideoGestureActivity()
                clearSeekPreview()
                dismissFloatingMenu()
                isShowingLiveTextViewer = false
                liveTextTargetImage = nil
                overlayHideTimer?.invalidate()
            } else {
                playbackService.clearAllInteractiveVideoGestureActivity()
                suppressTapActionsUntil = .distantPast
                if playbackService.state.status == .paused {
                    playbackService.showControlOverlay = true
                }
                scheduleOverlayHide()
            }
        }
        .onChange(of: playbackService.isInteractiveVideoGestureActive) { isActive in
            guard isActive else { return }
            endLongPressQuickPlaybackIfNeeded()
            if isDragging {
                isDragging = false
                dragType = .none
                dragOffset = .zero
                playbackService.isScrubbing = false
                clearSeekPreview()
            }
        }
        .statusBarHidden(usesCustomStatusBar || !playbackService.showControlOverlay)
    }

    @ViewBuilder
    private func feedbackOverlayView(
        feedbackOverlayTopPadding: CGFloat,
        seekPreviewOverlayTopPadding: CGFloat
    ) -> some View {
        if let interactiveZoomFeedbackText {
            VStack {
                UnifiedFeedbackView(icon: "plus.magnifyingglass", text: interactiveZoomFeedbackText)
                    .padding(.top, feedbackOverlayTopPadding)
                Spacer()
            }
            .transition(.opacity)
            .zIndex(100)
        } else if let data = feedbackData {
            VStack {
                UnifiedFeedbackView(icon: data.icon, text: data.text)
                    .contentShape(Capsule())
                    .onTapGesture {
                        dismissFeedback()
                    }
                    .padding(.top, feedbackOverlayTopPadding)
                Spacer()
            }
            .transition(.opacity)
            .zIndex(100)
        } else if isShowingSeekPreview, let targetTime = seekPreviewTargetTime {
            let diff = targetTime - (seekPreviewInitialTime ?? targetTime)
            let (icon, text) = seekFeedbackInfo(diff: diff, showsFineScrubbing: dragType == .seek)
            VStack {
                SeekPreviewOverlay(
                    image: seekPreviewImage,
                    showsLoadingIndicator: seekPreviewShowsLoadingIndicator,
                    targetTimeText: playbackService.formatTime(Int(targetTime)),
                    deltaIcon: icon,
                    deltaText: text
                )
                .padding(.top, seekPreviewOverlayTopPadding)
                Spacer()
            }
            .transition(.opacity)
            .zIndex(100)
        } else if isDragging && !isLocked && dragType != .secondarySubtitlePosition {
            let diff = (dragType == .seek && playbackService.maxDuration > 0) ? (indicatorValue() * playbackService.maxDuration - Double(initialSeekTime)) : 0
            let (icon, text) = gestureFeedbackInfo(diff: diff)
            VStack {
                UnifiedFeedbackView(icon: icon, text: text)
                    .padding(.top, feedbackOverlayTopPadding)
                Spacer()
            }
            .transition(.opacity)
            .zIndex(100)
        }
    }

    private var currentPlayingServer: ServerConfig? {
        guard let currentItem = playbackService.state.currentItem else { return nil }
        if let serverIdStr = currentItem.jellyfinServerId,
           let serverId = UUID(uuidString: serverIdStr),
           let server = AppNetworkService.shared.servers.first(where: { $0.id == serverId }) {
            return server
        }
        return AppNetworkService.shared.servers.first(where: { $0.type == currentItem.serverType })
    }

    @ViewBuilder
    private func topBarArea(
        usesCustomStatusBar: Bool,
        overlayTopPadding: CGFloat,
        overlayHorizontalInsets: EdgeInsets,
        topControlHorizontalInsets: EdgeInsets,
        overlayTopBarCompensation: CGFloat,
        usesRegularLayout: Bool
    ) -> some View {
        let hasAvailableEPG = playbackService.state.currentItem.map {
            EPGService.shared.hasAvailableEPG(for: $0, in: currentPlayingServer)
        } == true

        VStack(spacing: 0) {
            VStack(spacing: usesCustomStatusBar ? 8 : 0) {
                if usesCustomStatusBar {
                    CustomStatusBar()
                        .padding(overlayHorizontalInsets)
                        .zIndex(2)
                }

                PlayerTopBar(
                    playbackService: playbackService,
                    isLocked: $isLocked,
                    showPlaylist: $showPlaylist,
                    hasPlaylist: hasMultiplePlaylistItems,
                    isLiveStream: playbackService.state.currentItem?.isLiveStream ?? false,
                    showsDownloadedIconBeforeTitle: showsDownloadedIconBeforeTitle,
                    horizontalPadding: 0,
                    verticalPadding: 0,
                    trailingControlSpacing: 14,
                    horizontalCompensation: overlayTopBarCompensation,
                    onDismiss: {
                        if !playbackService.isVideoPiPActive && !playbackService.isAudioFloatingVisible {
                            playbackService.stop()
                        }
                        presentationMode.wrappedValue.dismiss()
                    },
                    onShowProgramGuide: hasAvailableEPG ? {
                        showProgramGuideSheet = true
                    } : nil,
                    onAction: showFeedback,
                    onLiveTextRequested: handleLiveTextExtraction,
                    onShowInfo: {
                        dismissFloatingMenu()
                        showVideoInfo = true
                    }
                )
                .padding(topControlHorizontalInsets)
                // Measure the full-width button row independently of the status row.
                .onPlayerControlSafeAreaChange { insets in
                    guard topControlSafeAreaInsets != insets else { return }
                    topControlSafeAreaInsets = insets
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, overlayTopPadding)
            .padding(.bottom, usesRegularLayout ? 8 : 6)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [Color.black.opacity(0.8), Color.clear]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()
                .opacity(isLocked ? 0 : 1)
            )
            Spacer()
        }
    }

    @ViewBuilder
    private func bottomBarArea(
        isLandscape: Bool,
        usesRegularLayout: Bool,
        overlayBottomPadding: CGFloat,
        overlayHorizontalInsets: EdgeInsets,
        showsExtendedTransportControls: Bool,
        overlayBottomControlSpacing: CGFloat?
    ) -> some View {
        VStack {
            Spacer()
            PlayerBottomBar(
                playbackService: playbackService,
                isLocked: $isLocked,
                progressValue: playerBottomBarProgressBinding,
                isLandscape: isLandscape,
                topPadding: usesRegularLayout ? 14 : 12,
                bottomPadding: overlayBottomPadding,
                contentPadding: overlayHorizontalInsets,
                maxContentWidth: nil,
                currentTimeText: displayedScrubCurrentTimeText,
                onAction: showFeedback,
                showsExtendedTransportControls: showsExtendedTransportControls,
                canPlayPrevious: canPlayPrevious,
                canPlayNext: canPlayNext,
                canReplayCurrentItem: canReplayCurrentItem,
                playbackSequenceMode: videoPlayMode,
                canChangePlaybackSequence: hasMultiplePlaylistItems,
                onReplay: replayCurrentItemFromBeginning,
                onPrevious: playPrevious,
                onNext: { playNext() },
                onSeekBackward: seekBackwardByConfiguredStep,
                onSeekForward: seekForwardByConfiguredStep,
                onCyclePlaybackSequenceMode: cycleVideoPlayMode,
                onInfo: {
                    dismissFloatingMenu()
                    showVideoInfo.toggle()
                },
                onImportSubtitle: { isImportingSubtitle = true },
                playbackQualityOptions: playbackQualityOptions,
                selectedPlaybackQualityID: sessionPlaybackQualityID,
                onSelectPlaybackQuality: switchCurrentPlaybackQuality,
                onScrubBegan: {
                    cancelsCurrentScrub = false
                    beginSeekPreviewSession(initialTime: playbackService.state.currentTime)
                },
                onScrubPreviewChanged: { targetTime in
                    guard !cancelsCurrentScrub else { return }
                    updateSeekPreview(targetTime: targetTime)
                },
                onScrubEnded: {
                    defer { cancelsCurrentScrub = false }
                    guard !cancelsCurrentScrub else { return }
                    commitSeekPreviewIfNeeded()
                },
                onTapSeek: { targetTime in
                    seekWithoutPreview(to: targetTime)
                },
                onMenuWillOpen: handleMenuWillOpen,
                onMenuDismiss: dismissFloatingMenu,
                onOpenAudioMenu: { presentFloatingMenu(.audioTracks) },
                onOpenSubtitleMenu: { presentFloatingMenu(.subtitleTracks) },
                onOpenSpeedMenu: { presentFloatingMenu(.playbackSpeed) },
                onOpenMoreMenu: { presentFloatingMenu(.more) },
                sideControlSpacing: overlayBottomControlSpacing
            )
            .onPlayerControlSafeAreaChange { insets in
                guard bottomControlSafeAreaInsets != insets else { return }
                // A changed slider width invalidates a drag's old coordinates.
                let previousInsets = bottomControlSafeAreaInsets ?? currentPlayerSafeAreaInsets
                let nextInsets = insets ?? currentPlayerSafeAreaInsets
                if playbackService.isScrubbing &&
                    (previousInsets.left != nextInsets.left || previousInsets.right != nextInsets.right) {
                    cancelsCurrentScrub = true
                    playbackService.isScrubbing = false
                    clearSeekPreview()
                }
                bottomControlSafeAreaInsets = insets
            }
        }
    }

    @ViewBuilder
    private func quickPlaybackPromptView(overlayBottomPadding: CGFloat) -> some View {
        if isLongPressQuickPlaybackActive || isQuickPlaybackSpeedLocked {
            let rateToDisplay = activeQuickPlaybackRate ?? (pressAndHoldQuickPlaybackTargetRate ?? 2.0)
            let rateStr = formattedPlaybackRateText(rateToDisplay)
            let promptText: String = isQuickPlaybackSpeedLocked
                ? String(format: NSLocalizedString("Speed locked at %@", comment: ""), rateStr)
                : String(format: NSLocalizedString("Playing at %@ • Slide down to lock", comment: ""), rateStr)
            
            VStack {
                Spacer()
                Text(promptText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.75))
                    .clipShape(Capsule())
                    .padding(.bottom, playbackService.showControlOverlay ? (overlayBottomPadding + 140) : (overlayBottomPadding + 40))
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: isLongPressQuickPlaybackActive || isQuickPlaybackSpeedLocked)
            .zIndex(150)
        }
    }

    @ViewBuilder
    private func SubtitleDropOverlay() -> some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "captions.bubble.fill")
                    .font(.system(size: 52, weight: .light))
                    .foregroundColor(.white)
                Text(NSLocalizedString("Drop Subtitle File", comment: "Player subtitle drag-and-drop overlay title"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.white)
                Text(NSLocalizedString("SRT, ASS, SSA, VTT, SUB", comment: "Player subtitle drag-and-drop supported formats hint"))
                    .font(.system(size: 14, weight: .regular))
                    .foregroundColor(.white.opacity(0.7))
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.white.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.4), lineWidth: 2)
                    )
            )
        }
    }

    private func SubtitleOverlayLayer() -> some View {
        GeometryReader { geometry in
            let containerSize = geometry.size
            let videoSize = playbackService.videoNaturalSize
            let videoRect = calculateVideoRect(containerSize: containerSize, videoSize: videoSize)
            let bottomPadding: CGFloat = 20
            let subtitleMaxWidth = max(0, videoRect.width - 32)
            let orientation = secondarySubtitleLayoutOrientation(for: containerSize)
            let baseFontSize = secondarySubtitleBaseFontSize(for: videoRect, orientation: orientation)
            let fontSize = baseFontSize * CGFloat(settings.secondarySubtitleSizeScale.rawValue)
            
            if !playbackService.displayedPrimarySubtitleParts.isEmpty {
                ZStack {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        subtitlePartsView(
                            playbackService.displayedPrimarySubtitleParts,
                            maxWidth: subtitleMaxWidth,
                            fontSize: fontSize
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, bottomPadding)
                    }
                }
                .frame(width: videoRect.width, height: videoRect.height)
                .position(x: videoRect.midX, y: videoRect.midY)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func SecondarySubtitleAdjustmentHitLayer(containerSize: CGSize) -> some View {
        if canShowSecondarySubtitleAdjustmentControls {
            let videoRect = calculateVideoRect(containerSize: containerSize, videoSize: playbackService.videoNaturalSize)
            if videoRect.width > 0, videoRect.height > 0 {
                let subtitleOrientation = secondarySubtitleLayoutOrientation(for: containerSize)
                let centerY = videoRect.minY + secondarySubtitleVerticalPosition(
                    in: videoRect.height,
                    orientation: subtitleOrientation
                )
                let subtitleMaxWidth = max(0, videoRect.width - 32)
                let baseFontSize = secondarySubtitleBaseFontSize(for: videoRect, orientation: subtitleOrientation)
                let fontSize = baseFontSize * CGFloat(settings.secondarySubtitleSizeScale.rawValue)

                let isSecondarySubtitleLoading = settings.enableSecondarySubtitlesBeta &&
                    playbackService.secondarySubtitleStatus == .loading
                let secondarySubtitleParts = settings.enableSecondarySubtitlesBeta
                    ? playbackService.currentSecondarySubtitleParts
                    : []

                let parts = isSecondarySubtitleLoading ? [secondarySubtitleLoadingPart()] : secondarySubtitleParts
                // ASS glyphs are already rendered by libass. Keep the original
                // stable drag surface, including gaps, without painting a text copy.
                let nativeASS = playbackService.isNativeASSSecondarySubtitle
                let nativeRect = nativeASSAdjustmentRect(in: containerSize)
                if nativeASS || isSecondarySubtitlePositionAdjustmentActive || parts.isEmpty {
                    // Keep the gesture on the same parent when a cue starts or ends mid-drag.
                    ZStack {
                        if nativeASS {
                            Color.clear
                            if isSecondarySubtitlePositionAdjustmentActive {
                                secondarySubtitleAdjustmentBackground()
                                if !playbackService.nativeASSHasContent {
                                    Label(NSLocalizedString("Secondary Subtitle", comment: ""), systemImage: "arrow.up.and.down")
                                        .font(.callout).foregroundColor(.white.opacity(0.7))
                                }
                            }
                        } else if !parts.isEmpty {
                            secondarySubtitleOverlayView(parts, maxWidth: subtitleMaxWidth, fontSize: fontSize)
                        } else {
                            secondarySubtitleAdjustmentFrame(maxWidth: subtitleMaxWidth)
                                .opacity(isSecondarySubtitlePositionAdjustmentActive ? 1 : 0)
                        }
                    }
                    .frame(width: nativeASS ? nativeRect.width : nil, height: nativeASS ? nativeRect.height : nil)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .updating($isSubtitleDragActive) { _, active, _ in active = true }
                            .onChanged { value in
                                handleSecondarySubtitleAdjustmentGestureChanged(value, in: containerSize)
                            }
                            .onEnded { value in
                                handleSecondarySubtitleAdjustmentGestureEnded(value, in: containerSize)
                            }
                    )
                    .onChange(of: isSubtitleDragActive) { active in
                        if !active { ignoresSubtitleDragUntilEnd = false }
                    }
                    .position(x: nativeASS ? nativeRect.midX : videoRect.midX, y: nativeASS ? nativeRect.midY : centerY)
                } else if isSecondarySubtitleLoading || !secondarySubtitleParts.isEmpty {
                    secondarySubtitleOverlayView(
                        isSecondarySubtitleLoading ? [secondarySubtitleLoadingPart()] : secondarySubtitleParts,
                        maxWidth: subtitleMaxWidth,
                        fontSize: fontSize
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        activateSecondarySubtitleAdjustment(autoHide: true)
                    }
                    .position(x: videoRect.midX, y: centerY)
                }
            }
        }
    }

    private func nativeASSAdjustmentRect(in size: CGSize) -> CGRect {
        let viewport = playbackService.nativeASSUsesVideoViewport
            ? calculateVideoRect(containerSize: size, videoSize: playbackService.videoNaturalSize)
            : CGRect(origin: .zero, size: size)
        let videoRect = calculateVideoRect(containerSize: size, videoSize: playbackService.videoNaturalSize)
        let fallbackY = videoRect.minY + secondarySubtitleVerticalPosition(in: videoRect.height,
            orientation: secondarySubtitleLayoutOrientation(for: size))
        var rect = MPVSecondarySubtitleRendering.adjustmentRect(bounds: playbackService.nativeASSBounds,
            viewport: viewport, fallbackCenterY: fallbackY)
        if isSecondarySubtitlePositionAdjustmentActive || !playbackService.nativeASSHasContent {
            // Preserve the existing full-row adjustment/empty-cue target. Native
            // bounds determine its vertical placement and height, not its width.
            rect.size.width = secondarySubtitleAdjustmentBoxWidth(maxWidth: max(0, videoRect.width - 32))
            rect.origin.x = videoRect.midX - rect.width / 2
        }
        return rect
    }

    private var canShowSecondarySubtitleAdjustmentControls: Bool {
        settings.enableSecondarySubtitlesBeta &&
            !playbackService.isNativeBitmapSecondarySubtitle &&
            !isMenuPresented &&
            activeMenuScreen == nil &&
            (playbackService.currentSecondarySubtitleTrackID != -1 ||
                !playbackService.currentSecondarySubtitleParts.isEmpty ||
                playbackService.secondarySubtitleStatus == .loading)
    }

    private func secondarySubtitleAdjustmentFrame(maxWidth: CGFloat) -> some View {
        secondarySubtitleAdjustmentBackground()
            .frame(width: secondarySubtitleAdjustmentBoxWidth(maxWidth: maxWidth), height: 76)
            .overlay(
                Label(NSLocalizedString("Secondary Subtitle", comment: ""), systemImage: "arrow.up.and.down")
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.7))
            )
    }

    private func secondarySubtitleAdjustmentBackground() -> some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.black.opacity(0.28))
            .shadow(color: Color.black.opacity(0.22), radius: 4, x: 0, y: 1)
    }

    private func secondarySubtitleAdjustmentBoxWidth(maxWidth: CGFloat) -> CGFloat {
        max(220, maxWidth)
    }

    @ViewBuilder
    private func secondarySubtitleOverlayView(_ parts: [SubtitlePart], maxWidth: CGFloat, fontSize: CGFloat) -> some View {
        if isSecondarySubtitlePositionAdjustmentActive {
            let boxWidth = secondarySubtitleAdjustmentBoxWidth(maxWidth: maxWidth)
            let horizontalPadding: CGFloat = 36
            let verticalPadding: CGFloat = 14
            let contentMaxWidth = max(0, boxWidth - horizontalPadding * 2)

            VStack(spacing: 0) {
                subtitlePartsView(parts, maxWidth: contentMaxWidth, fontSize: fontSize)
                    .frame(width: contentMaxWidth)
            }
            .padding(.vertical, verticalPadding)
            .frame(width: boxWidth)
            .background(secondarySubtitleAdjustmentBackground())
        } else {
            subtitlePartsView(parts, maxWidth: maxWidth, fontSize: fontSize)
        }
    }

    private func secondarySubtitleLoadingPart() -> SubtitlePart {
        SubtitlePart(
            start: 0,
            end: .greatestFiniteMagnitude,
            text: NSAttributedString(string: NSLocalizedString("Loading...", comment: "Secondary subtitle loading status"))
        )
    }

    private func secondarySubtitleBaseFontSize(
        for videoRect: CGRect,
        orientation: AppSettings.SecondarySubtitleLayoutOrientation
    ) -> CGFloat {
        guard videoRect.width > 0, videoRect.height > 0 else { return 22 }

        switch orientation {
        case .portrait:
            return min(max(videoRect.width * 0.036, 13), 16)
        case .landscape:
            return min(max(videoRect.height * 0.056, 18), 34)
        }
    }

    private func secondarySubtitleVerticalPosition(
        in videoHeight: CGFloat,
        orientation: AppSettings.SecondarySubtitleLayoutOrientation
    ) -> CGFloat {
        guard videoHeight > 0 else { return 0 }

        var centerY: CGFloat
        if let customRatio = playbackService.secondarySubtitleVerticalPositionRatio(for: orientation) {
            centerY = videoHeight * CGFloat(customRatio)
        } else {
            centerY = defaultSecondarySubtitleVerticalPosition(in: videoHeight)
        }

        return min(max(centerY, 32), max(32, videoHeight - 32))
    }

    private func defaultSecondarySubtitleVerticalPosition(in videoHeight: CGFloat) -> CGFloat {
        if playbackService.isNativeASSSecondarySubtitle {
            switch playbackService.secondarySubtitlePlacement {
            case .nearBottom: return videoHeight - 48
            case .middle: return videoHeight * 0.6
            case .top: return videoHeight * 0.2
            }
        }
        let reservedPrimarySubtitleHeight: CGFloat = 72
        let bottomBase: CGFloat = 20
        return videoHeight - max(bottomBase + reservedPrimarySubtitleHeight, 92)
    }

    private func secondarySubtitleLayoutOrientation(
        for containerSize: CGSize
    ) -> AppSettings.SecondarySubtitleLayoutOrientation {
        AppSettings.SecondarySubtitleLayoutOrientation.resolved(for: containerSize)
    }

    @ViewBuilder
    private func subtitlePartsView(_ parts: [SubtitlePart], maxWidth: CGFloat, fontSize: CGFloat) -> some View {
        if !parts.isEmpty {
            VStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    subtitlePartView(part, maxWidth: maxWidth, fontSize: fontSize)
                }
            }
            .frame(maxWidth: maxWidth)
        }
    }

    @ViewBuilder
    private func subtitlePartView(_ part: SubtitlePart, maxWidth: CGFloat, fontSize: CGFloat) -> some View {
        if let image = part.image {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: maxWidth)
        } else if let attrText = part.text {
            let textString = attrText.string.trimmingCharacters(in: .whitespacesAndNewlines)
            // Filter debug drawing commands.
            let isDrawingCommand = textString.hasPrefix("m ") ||
                (textString.contains(" m ") && textString.range(of: #"[0-9\-\s]+$"#, options: .regularExpression) != nil)

            if !textString.isEmpty && !isDrawingCommand {
                if let original = attrText.attribute(NSAttributedString.Key("GenPlayerSubtitleOriginal"), at: 0, effectiveRange: nil) as? String,
                   let translated = attrText.attribute(NSAttributedString.Key("GenPlayerSubtitleTranslation"), at: 0, effectiveRange: nil) as? String {
                    let originalFirst = attrText.attribute(NSAttributedString.Key("GenPlayerSubtitleOriginalFirst"), at: 0, effectiveRange: nil) as? Bool ?? true
                    VStack(spacing: 3) {
                        if originalFirst {
                            SubtitleTextView(attributedText: NSAttributedString(string: original), fontSize: fontSize * 0.82)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        SubtitleTextView(attributedText: NSAttributedString(string: translated), fontSize: fontSize)
                            .fixedSize(horizontal: false, vertical: true)
                        if !originalFirst {
                            SubtitleTextView(attributedText: NSAttributedString(string: original), fontSize: fontSize * 0.82)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    SubtitleTextView(attributedText: attrText, fontSize: fontSize)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    
    private func BufferingIndicator(messageKey: String = "Loading...") -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                .scaleEffect(0.9)
            
            Text(NSLocalizedString(messageKey, comment: ""))
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 3)
        .allowsHitTesting(false)
    }
    
    private func quickPlaybackLongPressArea<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .onLongPressGesture(
                minimumDuration: quickPlaybackLongPressDuration,
                maximumDistance: quickPlaybackLongPressMaxDistance,
                pressing: { pressing in
                    if !pressing {
                        endLongPressQuickPlaybackIfNeeded()
                    }
                }
            ) {
                activateLongPressQuickPlayback()
            }
    }

    private func handlePlayerSingleTap(defaultAction: () -> Void) {
        guard canHandleTapGestureAction else { return }

        if isSecondarySubtitlePositionAdjustmentActive {
            hideSecondarySubtitleAdjustment()
            return
        }

        defaultAction()
    }

    private func GestureLayer() -> some View {
         GeometryReader { geo in
            HStack(spacing: 0) {
                // Left Zone (30%) - Rewind
                quickPlaybackLongPressArea {
                    Color.black.opacity(0.001)
                        .frame(width: geo.size.width * 0.3)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            guard canHandleTapGestureAction else { return }
                            seekBackwardByConfiguredStep()
                        }
                        .onTapGesture(count: 1) {
                            handlePlayerSingleTap {
                                withAnimation { playbackService.showControlOverlay.toggle() }
                            }
                        }
                }
                
                // Center Zone (40%) - Play/Pause
                quickPlaybackLongPressArea {
                    Color.black.opacity(0.001)
                        .frame(width: geo.size.width * 0.4)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            guard canHandleTapGestureAction else { return }
                            playbackService.togglePlayPause()
                        }
                        .onTapGesture(count: 1) {
                            handlePlayerSingleTap {
                                withAnimation { playbackService.showControlOverlay.toggle() }
                            }
                        }
                }
                
                // Right Zone (30%) - Fast Forward
                quickPlaybackLongPressArea {
                    Color.black.opacity(0.001)
                        .frame(width: geo.size.width * 0.3)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) {
                            guard canHandleTapGestureAction else { return }
                            seekForwardByConfiguredStep()
                        }
                        .onTapGesture(count: 1) {
                            handlePlayerSingleTap {
                                withAnimation { playbackService.showControlOverlay.toggle() }
                            }
                        }
                }
            }
            .background(
                PlayerMultiTouchGestureBridge(
                    playbackService: playbackService,
                    onZoomChanged: handleInteractiveZoomScaleChanged,
                    onZoomEnded: handleInteractiveZoomScaleEnded,
                    onReset: handleInteractiveZoomReset
                )
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 30, coordinateSpace: .local)
                    .updating($isTouchDragActive) { _, active, _ in active = true }
                    .onChanged { value in handleDrag(value, in: geo.size) }
                    .onEnded { _ in handleDragEnded() }
            )
            .onChange(of: isTouchDragActive) { active in
                if !active { ignoresDragUntilEnd = false }
            }
        }
        .ignoresSafeArea()
    }
    
    // MARK: - Logic Helpers

    private func configureRemoteCommandsForVideoPlayback() {
        playbackService.onRequestNextTrack = {
            guard playbackService.canSkipToNextTrack else { return false }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .playerRemoteNextTrackRequested, object: nil)
            }
            return true
        }

        playbackService.onRequestPreviousTrack = {
            guard playbackService.canSkipToPreviousTrack else { return false }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .playerRemotePreviousTrackRequested, object: nil)
            }
            return true
        }

        playbackService.onRequestSeekToTime = { time in
            performRemoteRestartSeekIfNeeded(to: time)
        }
    }

    private func clearRemoteCommandsForVideoPlayback() {
        playbackService.onRequestNextTrack = nil
        playbackService.onRequestPreviousTrack = nil
        playbackService.onRequestSeekToTime = nil
        remoteSkipAvailability = RemoteSkipAvailability(previous: false, next: false)
        playbackService.updateRemoteSkipAvailability(canPrevious: false, canNext: false)
    }

    private func syncRemoteSkipAvailability(force: Bool = false) {
        let latest = RemoteSkipAvailability(previous: canPlayPrevious, next: canPlayNext)
        guard force || latest != remoteSkipAvailability else { return }
        remoteSkipAvailability = latest
        playbackService.updateRemoteSkipAvailability(canPrevious: latest.previous, canNext: latest.next)
    }

    private var subtitleImportTypes: [UTType] {
        var identifiers = Set<String>()
        var types: [UTType] = []

        func append(_ type: UTType) {
            if identifiers.insert(type.identifier).inserted {
                types.append(type)
            }
        }

        append(.plainText)
        append(.utf8PlainText)

        for ext in VideoFile.FileType.subtitleExtensions {
            if let type = UTType(filenameExtension: ext) {
                append(type)
            }
        }

        return types
    }

    /// UTType identifiers accepted by the drag-and-drop handler.
    private var subtitleDropTypes: [UTType] {
        var types: [UTType] = [.fileURL, .url]
        for ext in VideoFile.FileType.subtitleExtensions {
            if let type = UTType(filenameExtension: ext) {
                types.append(type)
            }
        }
        return types
    }

    /// Handles providers dropped onto the player and imports the first recognised subtitle file.
    private func handleDroppedSubtitleProviders(_ providers: [NSItemProvider]) {
        let subtitleExts = Set(VideoFile.FileType.subtitleExtensions)

        func tryImport(url: URL) {
            let ext = url.pathExtension.lowercased()
            guard subtitleExts.contains(ext) else {
                showFeedback(icon: "exclamationmark.triangle",
                             text: NSLocalizedString("Unsupported subtitle format", comment: ""))
                return
            }
            importExternalSubtitle(from: url)
        }

        // Attempt to load a file-system URL from the first valid provider
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    DispatchQueue.main.async {
                        var resolved: URL?
                        if let url = item as? URL {
                            resolved = url
                        } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                            resolved = url
                        }
                        if let url = resolved {
                            tryImport(url: url)
                        }
                    }
                }
                return
            }

            // Fallback: try loading as a plain URL
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                    DispatchQueue.main.async {
                        if let url = item as? URL {
                            tryImport(url: url)
                        }
                    }
                }
                return
            }
        }
    }


    private func importExternalSubtitle(from sourceURL: URL) {
        let hasScopedAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let localURL = try persistedSubtitleURL(from: sourceURL)
            playbackService.addExternalSubtitle(url: localURL)
            showFeedback(icon: "captions.bubble.fill", text: localURL.lastPathComponent)
        } catch {
            showFeedback(icon: "exclamationmark.triangle", text: error.localizedDescription)
        }
    }

    private func playerOverlayHorizontalPadding(usesRegularLayout: Bool, isLandscape: Bool) -> CGFloat {
        if usesRegularLayout {
            return isLandscape ? 20 : 18
        }

        return isLandscape ? 20 : 16
    }

    private func playerTopBarHorizontalCompensation(usesRegularLayout: Bool) -> CGFloat {
        return usesRegularLayout ? 8 : 12
    }

    private func playerBottomControlSpacing(usesRegularLayout: Bool, isLandscape: Bool) -> CGFloat? {
        guard isLandscape else { return nil }
        return usesRegularLayout ? 24 : 26
    }

    private func playerOverlayHorizontalInsets(basePadding: CGFloat, safeArea: UIEdgeInsets? = nil) -> EdgeInsets {
        let liveInsets = safeArea ?? currentPlayerSafeAreaInsets
        let leadingInset = liveInsets.left
        let trailingInset = liveInsets.right
        return EdgeInsets(
            top: 0,
            leading: basePadding + leadingInset,
            bottom: 0,
            trailing: basePadding + trailingInset
        )
    }

    private func playerOverlayTopPadding(usesCustomStatusBar: Bool) -> CGFloat {
        let topInset = currentPlayerSafeAreaInsets.top
        return usesCustomStatusBar ? max(8, topInset + 4) : topInset + 4
    }

    private func playerOverlayBottomPadding(isLandscape: Bool) -> CGFloat {
        let liveInsets = currentPlayerSafeAreaInsets
        let resolvedBottomInset = liveInsets.bottom
        return resolvedBottomInset + (isLandscape ? 8 : 10)
    }

    private enum HorizontalEdge {
        case leading
        case trailing
    }

    private func playerSideControlPadding(isLandscape: Bool, edge: HorizontalEdge) -> CGFloat {
        let basePadding: CGFloat = isLandscape ? 40 : 32
        let liveInsets = currentPlayerSafeAreaInsets
        let edgeInset: CGFloat

        switch edge {
        case .leading:
            edgeInset = liveInsets.left
        case .trailing:
            edgeInset = liveInsets.right
        }

        return basePadding + edgeInset
    }

    private func playerFeedbackOverlayTopPadding(
        containerSize: CGSize,
        videoRect: CGRect,
        minimumTopPadding: CGFloat,
        overlayHeight: CGFloat,
        isLandscape: Bool
    ) -> CGFloat {
        if isLandscape {
            return minimumTopPadding
        }

        let topGapAvailable = videoRect.minY - minimumTopPadding
        if topGapAvailable >= overlayHeight + 24 {
            return minimumTopPadding + ((topGapAvailable - overlayHeight) / 2)
        }

        let preferredRatio: CGFloat = 0.21
        let fallbackTopPadding = max(minimumTopPadding, containerSize.height * preferredRatio)
        let maximumTopPadding = max(minimumTopPadding, containerSize.height - overlayHeight - 160)
        return min(fallbackTopPadding, maximumTopPadding)
    }

    private var currentPlayerSafeAreaInsets: UIEdgeInsets {
        playbackService.playerView?.window?.safeAreaInsets ?? safeAreaInsets
    }

    private func refreshSafeAreaInsetsFromWindow() {
        let insets = currentPlayerSafeAreaInsets
        if safeAreaInsets != insets {
            safeAreaInsets = insets
        }
    }

    private func handleRotationCompleted() {
        refreshSafeAreaInsetsFromWindow()
        overlayLayoutRefreshToken = UUID()

        DispatchQueue.main.async {
            refreshSafeAreaInsetsFromWindow()
            overlayLayoutRefreshToken = UUID()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            refreshSafeAreaInsetsFromWindow()
            overlayLayoutRefreshToken = UUID()
        }
    }

    private func handleLiveTextExtraction() {
        guard LiveTextCapability.isSupported else { return }
        if playbackService.state.isPlaying {
            playbackService.pause()
        }
        playbackService.requestCurrentFrame { snapshot in
            guard let snapshot else { return }
            liveTextTargetImage = snapshot
            withAnimation(.easeInOut(duration: 0.2)) {
                isShowingLiveTextViewer = true
            }
        }
    }

    private func persistedSubtitleURL(from sourceURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let subtitleDir = fileManager.temporaryDirectory.appendingPathComponent("ImportedSubtitles", isDirectory: true)
        try fileManager.createDirectory(at: subtitleDir, withIntermediateDirectories: true)

        let fileExtension = sourceURL.pathExtension
        let rawBaseName = sourceURL.deletingPathExtension().lastPathComponent
        let baseName = sanitizedFilename(rawBaseName)
        let candidateName = fileExtension.isEmpty ? baseName : "\(baseName).\(fileExtension)"
        var destinationURL = subtitleDir.appendingPathComponent(candidateName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            let suffix = UUID().uuidString.prefix(8)
            let uniqueName = fileExtension.isEmpty ? "\(baseName)-\(suffix)" : "\(baseName)-\(suffix).\(fileExtension)"
            destinationURL = subtitleDir.appendingPathComponent(uniqueName)
        }

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func sanitizedFilename(_ fileName: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let components = fileName.components(separatedBy: invalid)
        let cleaned = components.joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "subtitle" : cleaned
    }
    
    private func loadPlaylistFromDirectory() {
        if let playlist = playlist {
            // Use provided playlist directly, just sort/filter if needed or use as is?
            // User likely wants them in the order provided by the API (IndexNumber).
            // But let's filter supported types just in case.
            // If it's a remote playlist, we trust the order from the API
            // If it contains local files, we might want to ensure they are valid
            var playlistFiles = playlist.filter { $0.type == .video }.map(offlinePreferredPlaybackFile)
            let initialPlaybackFile = offlinePreferredPlaybackFile(initialFile)
            if let matchedIndex = playlistFiles.firstIndex(where: { playlistItemsMatch($0, initialPlaybackFile) }) {
                playlistFiles[matchedIndex] = anchoredCurrentFile(current: initialPlaybackFile, fallback: playlistFiles[matchedIndex])
            }
            
            // NOTE: We do NOT re-sort provided playlists (like seasons) as they are already sorted by IndexNumber
            
            loadedPlaylist = playlistFiles.isEmpty ? [initialPlaybackFile] : playlistFiles
            loadedInitialIndex = loadedPlaylist?.firstIndex(where: { playlistItemsMatch($0, initialPlaybackFile) }) ?? 0
            isPlaylistLoaded = true
            syncRemoteSkipAvailability(force: true)
            return
        }

        let initialPlaybackFile = offlinePreferredPlaybackFile(initialFile)

        if tryLoadRemoteSeasonPlaylistIfNeeded() {
            return
        }

        if shouldTreatAsDownloadedLibraryItem(initialPlaybackFile) {
            loadedPlaylist = [initialPlaybackFile]
            loadedInitialIndex = 0
            isPlaylistLoaded = true
            syncRemoteSkipAvailability(force: true)
            return
        }

        if tryLoadRemoteFolderPlaylistIfNeeded() {
            return
        }

        let directoryURL = initialFile.url.deletingLastPathComponent()
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else {
            loadedPlaylist = [initialFile]
            loadedInitialIndex = 0
            isPlaylistLoaded = true
            syncRemoteSkipAvailability(force: true)
            return
        }
        
        let targetType: VideoFile.FileType = initialFile.type == .audio ? .audio : .video
        let playlistFiles = contents
            .compactMap { url -> VideoFile? in
                let resolvedType = VideoFile.FileType.determineType(from: url)
                guard resolvedType == targetType else { return nil }
                let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return VideoFile(
                    name: url.lastPathComponent,
                    url: url,
                    type: resolvedType,
                    size: Int64(resourceValues?.fileSize ?? 0),
                    date: resourceValues?.contentModificationDate ?? Date(),
                    isRemote: false
                )
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        
        print("[PlayerView] Loaded Playlist (\(playlistFiles.count) items):")
        playlistFiles.forEach { print(" - \($0.name)") }
        
        loadedPlaylist = playlistFiles.isEmpty ? [initialFile] : playlistFiles
        loadedInitialIndex = loadedPlaylist?.firstIndex(where: { playlistItemsMatch($0, initialFile) }) ?? 0
        isPlaylistLoaded = true
        syncRemoteSkipAvailability(force: true)
    }

    private func tryLoadRemoteSeasonPlaylistIfNeeded() -> Bool {
        guard hasMediaServerLibraryContext(initialFile),
              let rawServer = resolvedMediaServer(for: initialFile) else {
            return false
        }
        let server = AppNetworkService.shared.hydratedServer(from: rawServer)
        guard server.type == .jellyfin || server.type == .emby || server.type == .plex else {
            return false
        }

        let explicitSeasonId = initialFile.seasonId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let itemId = initialFile.jellyfinItemId?.trimmingCharacters(in: .whitespacesAndNewlines)

        guard (explicitSeasonId?.isEmpty == false) || (itemId?.isEmpty == false) else {
            return false
        }

        Task {
            var targetSeasonId = (explicitSeasonId?.isEmpty == false) ? explicitSeasonId : nil
            if targetSeasonId == nil, let itemId, !itemId.isEmpty {
                if server.type == .jellyfin, let token = server.accessToken {
                    if let item = try? await JellyfinService.shared.getItemDetails(server: server, itemId: itemId, token: token) {
                        targetSeasonId = item.seasonId
                    }
                } else if server.type == .emby, let token = server.accessToken, let userId = server.userId {
                    if let item = try? await EmbyService.shared.getItemDetails(server: server, userId: userId, itemId: itemId, token: token) {
                        targetSeasonId = item.seasonId
                    }
                } else if server.type == .plex {
                    if let item = try? await PlexService.shared.getMetadataItem(server: server, itemId: itemId) {
                        targetSeasonId = item.parentRatingKey ?? (item.type.lowercased() == "season" ? item.id : nil)
                    }
                }
            }

            guard let seasonId = targetSeasonId, !seasonId.isEmpty else {
                // 没有 seasonId 说明是电影或非剧集条目，回退为单项播放列表，避免 isPlaylistLoaded 永远不被设置
                await MainActor.run {
                    let playbackFile = offlinePreferredPlaybackFile(initialFile)
                    loadedPlaylist = [playbackFile]
                    loadedInitialIndex = 0
                    isPlaylistLoaded = true
                    syncRemoteSkipAvailability(force: true)
                    print("[PlayerView] Non-episode item (no seasonId), using single-item playlist")
                }
                return
            }

            let files: [VideoFile]
            switch server.type {
            case .jellyfin:
                if let token = server.accessToken, let userId = server.userId {
                    files = await jellyfinSeasonPlaylist(server: server, token: token, userId: userId, seasonId: seasonId)
                } else {
                    files = []
                }
            case .emby:
                if let token = server.accessToken, let userId = server.userId {
                    files = await embySeasonPlaylist(server: server, token: token, userId: userId, seasonId: seasonId)
                } else {
                    files = []
                }
            case .plex:
                if let items = try? await PlexService.shared.getChildren(server: server, itemId: seasonId) {
                    files = items.compactMap { PlexService.shared.buildPlayableVideoFile(server: server, item: $0) }
                } else {
                    files = []
                }
            default:
                files = []
            }

            await MainActor.run {
                var playlistFiles = files.map { DownloadCenterService.shared.localPlaybackFile(for: $0) ?? $0 }
                if let matchedIndex = playlistFiles.firstIndex(where: { playlistItemsMatch($0, initialFile) }) {
                    playlistFiles[matchedIndex] = anchoredCurrentFile(current: initialFile, fallback: playlistFiles[matchedIndex])
                } else if !playlistFiles.isEmpty {
                    playlistFiles.append(initialFile)
                }
                if playlistFiles.isEmpty {
                    playlistFiles = [initialFile]
                }
                loadedPlaylist = playlistFiles
                loadedInitialIndex = playlistFiles.firstIndex(where: { playlistItemsMatch($0, initialFile) }) ?? 0
                print("[PlayerView] Remote season playlist loaded: \(playlistFiles.count) items, initial index: \(loadedInitialIndex)")
                isPlaylistLoaded = true
                syncRemoteSkipAvailability(force: true)
            }
        }

        return true
    }

    private func tryLoadRemoteFolderPlaylistIfNeeded() -> Bool {
        guard initialFile.isRemote,
              let server = initialFile.resolvedServer,
              server.type.isFileServer else {
            return false
        }

        let hydratedServer = AppNetworkService.shared.hydratedServer(from: server)
        let parentPath = initialFile.remoteFolderPath

        Task {
            do {
                let files = try await AppNetworkService.shared.fetchContents(for: hydratedServer, at: parentPath)
                await MainActor.run {
                    self.remoteFolderSubtitleURLs = files
                        .filter { VideoFile.FileType.subtitleExtensions.contains($0.url.pathExtension.lowercased()) }
                        .map(\.url)
                    
                    let targetType: VideoFile.FileType = initialFile.type == .audio ? .audio : .video
                    var playlistFiles = files.filter { $0.type == targetType }
                    if let matchedIndex = playlistFiles.firstIndex(where: { playlistItemsMatch($0, initialFile) }) {
                        playlistFiles[matchedIndex] = anchoredCurrentFile(current: initialFile, fallback: playlistFiles[matchedIndex])
                    } else {
                        playlistFiles.append(initialFile)
                    }
                    playlistFiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

                    loadedPlaylist = playlistFiles.isEmpty ? [initialFile] : playlistFiles
                    loadedInitialIndex = loadedPlaylist?.firstIndex(where: { playlistItemsMatch($0, initialFile) }) ?? 0
                    print("[PlayerView] Remote folder playlist loaded (\(server.type.rawValue)): \(loadedPlaylist?.count ?? 0) items, initial index: \(loadedInitialIndex)")
                    isPlaylistLoaded = true
                    syncRemoteSkipAvailability(force: true)
                }
            } catch {
                await MainActor.run {
                    print("[PlayerView] Remote folder playlist load failed (\(server.type.rawValue)): \(error.localizedDescription)")
                    loadedPlaylist = [initialFile]
                    loadedInitialIndex = 0
                    isPlaylistLoaded = true
                    syncRemoteSkipAvailability(force: true)
                }
            }
        }

        return true
    }

    private func jellyfinSeasonPlaylist(server: ServerConfig, token: String, userId: String, seasonId: String) async -> [VideoFile] {
        do {
            let response = try await JellyfinService.shared.getItems(
                server: server,
                userId: userId,
                token: token,
                libraryId: seasonId,
                includeTypes: ["Episode"],
                sortBy: "IndexNumber"
            )
            let items = response.items.filter { $0.type == "Episode" }

            return items.compactMap { item in
                let preferredSource = JellyfinService.shared.preferredPlaybackSource(from: item.mediaSources ?? []) ?? item.mediaSources?.first
                guard let streamURL = JellyfinService.shared.resolvePlaybackURL(
                    server: server,
                    itemId: item.id,
                    token: token,
                    mediaSource: preferredSource
                ) else { return nil }

                var file = VideoFile(
                    name: item.displayTitle,
                    url: streamURL,
                    type: .video,
                    size: 0,
                    date: Date(),
                    isRemote: true,
                    duration: item.runTimeTicks.map { Double($0) / 10_000_000.0 },
                    lastPlayedPosition: item.userData?.resumeDecision(runtimeTicks: item.runTimeTicks).startPosition,
                    jellyfinItemId: item.id,
                    jellyfinServerId: server.id.uuidString,
                    serverType: server.type,
                    seriesId: item.seriesId,
                    seasonId: item.seasonId
                )
                file.shouldResetRemotePlayedStateOnPlaybackStart =
                    item.userData?.resumeDecision(runtimeTicks: item.runTimeTicks).shouldResetPlayedStateOnStart ?? false

                if let source = preferredSource {
                    file.serverMediaStreams = source.mediaStreams?.map { $0.toDictionary() }
                    file.serverContainer = source.container
                    file.serverSize = source.size
                    file.serverBitrate = source.bitrate
                    file.serverPath = source.path
                }
                return file
            }
        } catch {
            print("[PlayerView] Failed to load Jellyfin season playlist: \(error)")
            return []
        }
    }

    private func embySeasonPlaylist(server: ServerConfig, token: String, userId: String, seasonId: String) async -> [VideoFile] {
        do {
            let response = try await EmbyService.shared.getItems(
                server: server,
                userId: userId,
                token: token,
                libraryId: seasonId,
                includeTypes: ["Episode"],
                sortBy: "IndexNumber"
            )
            let items = response.items.filter { $0.type == "Episode" }

            return items.compactMap { item in
                let preferredSource = EmbyService.shared.preferredPlaybackSource(from: item.mediaSources ?? []) ?? item.mediaSources?.first
                let playSessionId = UUID().uuidString
                guard let streamURL = EmbyService.shared.resolvePlaybackURL(
                    server: server,
                    itemId: item.id,
                    token: token,
                    mediaSource: preferredSource,
                    playSessionId: playSessionId
                ) else { return nil }

                var title = item.name
                if let idx = item.indexNumber {
                    title = "\(idx). \(item.name)"
                }

                var file = VideoFile(
                    name: title,
                    url: streamURL,
                    type: .video,
                    size: 0,
                    date: Date(),
                    isRemote: true,
                    duration: item.runTimeTicks.map { Double($0) / 10_000_000.0 },
                    lastPlayedPosition: item.userData?.resumeDecision(runtimeTicks: item.runTimeTicks).startPosition,
                    jellyfinItemId: item.id,
                    jellyfinServerId: server.id.uuidString,
                    serverType: server.type,
                    seriesId: item.seriesId,
                    seasonId: item.seasonId
                )
                file.shouldResetRemotePlayedStateOnPlaybackStart =
                    item.userData?.resumeDecision(runtimeTicks: item.runTimeTicks).shouldResetPlayedStateOnStart ?? false

                if let source = preferredSource {
                    file.serverMediaStreams = source.mediaStreams?.map { $0.toDictionary() }
                    file.serverContainer = source.container
                    file.serverSize = source.size
                    file.serverBitrate = source.bitrate
                    file.serverPath = source.path
                }
                return file
            }
        } catch {
            print("[PlayerView] Failed to load Emby season playlist: \(error)")
            return []
        }
    }
    
    private func prepareExternalSubtitles(for video: VideoFile) -> URL? {
        let localCandidates = findExternalSubtitles(for: video).map { url in
            ExternalSubtitleCandidate(
                url: url,
                displayName: url.deletingPathExtension().lastPathComponent
            )
        }

        // Local files always prefer fresh sidecar scan; keep only currently valid restored candidates
        // to avoid stale history subtitles overriding/duplicating auto-loaded local subtitles.
        let restoredCandidates: [ExternalSubtitleCandidate]
        if video.url.isFileURL {
            restoredCandidates = video.externalSubtitleCandidates.filter { candidate in
                guard candidate.url.isFileURL else { return false }
                return FileManager.default.fileExists(atPath: candidate.url.standardizedFileURL.path)
            }
        } else {
            restoredCandidates = video.externalSubtitleCandidates
        }

        let subtitleCandidates = deduplicatedExternalSubtitleCandidates(localCandidates + restoredCandidates)
        playbackService.setExternalSubtitleCandidates(
            for: video.url,
            candidates: subtitleCandidates,
            autoSelectFirst: true
        )
        return playbackService.preferredExternalSubtitleURL(for: video.url)
    }

    private func mediaSourceID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        return components.queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame })?
            .value
    }

    private func playSessionID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        return components.queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("PlaySessionId") == .orderedSame })?
            .value
    }

    private func accessToken(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        return components.queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("api_key") == .orderedSame })?
            .value
    }

    private func offlinePreferredPlaybackFile(_ file: VideoFile) -> VideoFile {
        if let local = downloadCenter.localPlaybackFile(for: file) {
            return local
        }
        if file.url.isFileURL {
            if let hydrated = downloadCenter.hydratedPlaybackFile(for: file) {
                return hydrated
            }
        }
        return file
    }

    private func refreshedInitialPlaybackFile(_ file: VideoFile) -> VideoFile {
        let offlineFile = offlinePreferredPlaybackFile(file)
        if shouldTreatAsDownloadedLibraryItem(offlineFile) {
            return offlineFile
        }

        guard shouldResolveRemotePlaybackForCurrentSession(file),
              let server = file.resolvedServer,
              let itemId = file.jellyfinItemId else {
            return file
        }

        let playbackQuality = resolvedPlaybackQualityOption(for: effectivePlaybackQualityID(for: file))
        let mediaSourceId = mediaSourceID(from: file.url)
        let token = accessToken(from: file.url) ?? server.accessToken

        guard let token, !token.isEmpty else {
            return file
        }

        var refreshedFile = file
        switch server.type {
        case .jellyfin:
            guard let rebuiltURL = JellyfinService.shared.rebuildPlaybackURL(
                server: server,
                itemId: itemId,
                token: token,
                mediaSourceId: mediaSourceId,
                playbackQuality: playbackQuality
            ) else {
                return file
            }
            refreshedFile.url = rebuiltURL
        case .emby:
            let playSessionId = playSessionID(from: file.url) ?? UUID().uuidString
            guard let rebuiltURL = EmbyService.shared.rebuildPlaybackURL(
                server: server,
                itemId: itemId,
                token: token,
                mediaSourceId: mediaSourceId,
                playbackQuality: playbackQuality,
                mediaSourceContainer: file.serverContainer,
                playSessionId: playSessionId
            ) else {
                return file
            }
            refreshedFile.url = rebuiltURL
        default:
            break
        }

        return refreshedFile
    }

    private func loadRemoteExternalSubtitlesIfNeeded(for video: VideoFile) {
        remoteSubtitleLoadTask?.cancel()

        guard video.isRemote else { return }
        guard findExternalSubtitles(for: video).isEmpty else { return }
        guard let server = video.resolvedServer,
              let itemId = video.jellyfinItemId,
              let userId = server.userId,
              let token = accessToken(from: video.url) ?? server.accessToken else {
            return
        }

        guard server.type == .jellyfin || server.type == .emby else { return }

        let mediaURL = video.url
        let videoName = mediaURL.deletingPathExtension().lastPathComponent.lowercased()
        let preferredQuery = video.preferredSubtitleTrackQuery
        let preferredOrdinal = video.preferredSubtitleTrackOrdinal
        let shouldAutoSelect = !video.disableSubtitlesOnStart
        let playbackQuality = resolvedPlaybackQualityOption(for: video.preferredPlaybackQualityID ?? sessionPlaybackQualityID)

        remoteSubtitleLoadTask = Task {
            let candidates: [ExternalSubtitleCandidate]
            let serverStreams: [[String: Any]]
            let serverContainer: String?
            let serverSize: Int64?
            let serverBitrate: Int?
            let serverPath: String?
            let playSessionId: String?
            let mediaSourceId: String?
            let playbackMethod: RemotePlaybackMethod?

            do {
                switch server.type {
                case .jellyfin:
                    let playbackInfo = try await JellyfinService.shared.getPlaybackInfo(
                        server: server,
                        itemId: itemId,
                        userId: userId,
                        token: token,
                        playbackQuality: playbackQuality
                    )
                    let preferredSource = JellyfinService.shared.preferredPlaybackSource(
                        from: playbackInfo.mediaSources,
                        playbackQuality: playbackQuality
                    )
                    candidates = JellyfinService.shared.externalSubtitleCandidates(
                        server: server,
                        itemId: itemId,
                        mediaSources: playbackInfo.mediaSources,
                        token: token,
                        mediaSourceId: preferredSource?.id
                    )
                    serverStreams = JellyfinService.shared.preferredPlaybackStreams(
                        from: playbackInfo.mediaSources,
                        playbackQuality: playbackQuality
                    ).map { $0.toDictionary() }
                    serverContainer = preferredSource?.container
                    serverSize = preferredSource?.size
                    serverBitrate = preferredSource?.bitrate
                    serverPath = preferredSource?.path
                    playSessionId = playbackInfo.playSessionId
                    mediaSourceId = preferredSource?.id
                    playbackMethod = JellyfinService.shared.playbackMethod(
                        for: preferredSource,
                        resolvedURL: mediaURL,
                        playbackQuality: playbackQuality
                    )
                case .emby:
                    let currentPlaySessionId =
                        playSessionID(from: mediaURL) ??
                        currentMediaItem?.playSessionId ??
                        playbackService.state.currentItem?.playSessionId
                    let playbackInfo = try await EmbyService.shared.getPlaybackInfo(
                        server: server,
                        itemId: itemId,
                        userId: userId,
                        token: token,
                        playbackQuality: playbackQuality,
                        currentPlaySessionId: currentPlaySessionId
                    )
                    let preferredSource = EmbyService.shared.preferredPlaybackSource(
                        from: playbackInfo.mediaSources,
                        playbackQuality: playbackQuality
                    )
                    candidates = EmbyService.shared.externalSubtitleCandidates(
                        server: server,
                        itemId: itemId,
                        mediaSources: playbackInfo.mediaSources,
                        token: token,
                        mediaSourceId: preferredSource?.id
                    )
                    serverStreams = EmbyService.shared.preferredPlaybackStreams(
                        from: playbackInfo.mediaSources,
                        playbackQuality: playbackQuality
                    ).map { $0.toDictionary() }
                    serverContainer = preferredSource?.container
                    serverSize = preferredSource?.size
                    serverBitrate = preferredSource?.bitrate
                    serverPath = preferredSource?.path
                    playSessionId = playbackInfo.playSessionId
                    mediaSourceId = preferredSource?.id
                    playbackMethod = EmbyService.shared.playbackMethod(
                        for: preferredSource,
                        resolvedURL: mediaURL,
                        playbackQuality: playbackQuality
                    )
                default:
                    return
                }
            } catch {
                print("[PlayerView] Failed to load remote subtitles: \(error)")
                return
            }

            guard !Task.isCancelled else { return }

            var mergedCandidates: [ExternalSubtitleCandidate] = []
            var seenCandidateKeys = Set<String>()
            (candidates + video.externalSubtitleCandidates).forEach { candidate in
                let key = subtitleCandidateKey(for: candidate.url)
                guard seenCandidateKeys.insert(key).inserted else { return }
                mergedCandidates.append(candidate)
            }

            let orderedCandidates = orderedRemoteSubtitleCandidates(
                mergedCandidates,
                preferredQuery: preferredQuery,
                preferredOrdinal: preferredOrdinal,
                videoName: videoName
            )

            await MainActor.run {
                guard !Task.isCancelled else { return }
                guard currentMediaItem?.url == mediaURL || playbackService.state.currentItem?.url == mediaURL else {
                    return
                }

                applyRemotePlaybackMetadata(
                    streams: serverStreams,
                    container: serverContainer,
                    size: serverSize,
                    bitrate: serverBitrate,
                    path: serverPath,
                    playSessionId: playSessionId,
                    mediaSourceId: mediaSourceId,
                    playbackMethod: playbackMethod,
                    for: mediaURL
                )

                guard !orderedCandidates.isEmpty else {
                    playbackService.refreshTracks()
                    return
                }

                playbackService.setExternalSubtitleCandidates(
                    for: mediaURL,
                    candidates: orderedCandidates,
                    autoSelectFirst: false
                )

                if var item = currentMediaItem, item.url == mediaURL {
                    item.externalSubtitleCandidates = orderedCandidates
                    currentMediaItem = item
                }

                if var item = playbackService.state.currentItem, item.url == mediaURL {
                    item.externalSubtitleCandidates = orderedCandidates
                    playbackService.state.currentItem = item
                }

                guard shouldAutoSelect, let selectedURL = orderedCandidates.first?.url else { return }

                if var item = currentMediaItem, item.url == mediaURL {
                    item.externalSubtitleURL = selectedURL
                    item.externalSubtitleCandidates = orderedCandidates
                    currentMediaItem = item
                }

                if var item = playbackService.state.currentItem, item.url == mediaURL {
                    item.externalSubtitleURL = selectedURL
                    item.externalSubtitleCandidates = orderedCandidates
                    playbackService.state.currentItem = item
                    playbackService.restartCurrentItemForSelectedExternalSubtitle()
                }
            }
        }
    }

    private func applyRemotePlaybackMetadata(
        streams: [[String: Any]],
        container: String?,
        size: Int64?,
        bitrate: Int?,
        path: String?,
        playSessionId: String?,
        mediaSourceId: String?,
        playbackMethod: RemotePlaybackMethod?,
        for mediaURL: URL
    ) {
        guard currentMediaItem?.url == mediaURL || playbackService.state.currentItem?.url == mediaURL else {
            return
        }

        if var item = currentMediaItem, item.url == mediaURL {
            item.serverMediaStreams = streams
            item.serverContainer = container
            item.serverSize = size
            item.serverBitrate = bitrate
            item.serverPath = path
            item.playSessionId = playSessionId
            item.mediaSourceId = mediaSourceId
            item.remotePlaybackMethod = playbackMethod
            currentMediaItem = item
        }

        if var item = playbackService.state.currentItem, item.url == mediaURL {
            item.serverMediaStreams = streams
            item.serverContainer = container
            item.serverSize = size
            item.serverBitrate = bitrate
            item.serverPath = path
            item.playSessionId = playSessionId
            item.mediaSourceId = mediaSourceId
            item.remotePlaybackMethod = playbackMethod
            playbackService.state.currentItem = item
            playbackService.refreshSecondarySubtitleTracks()
        }
    }

    private func hasMediaServerLibraryContext(_ file: VideoFile) -> Bool {
        let serverType = file.serverType ?? file.resolvedServer?.type
        guard let serverType else { return false }
        guard serverType == .jellyfin || serverType == .emby || serverType == .plex else { return false }
        let serverId = (file.jellyfinServerId ?? file.resolvedServer?.id.uuidString)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let serverId, !serverId.isEmpty else {
            return false
        }
        return file.jellyfinItemId != nil || file.seriesId != nil || file.seasonId != nil
    }

    private func shouldTreatAsDownloadedLibraryItem(_ file: VideoFile) -> Bool {
        file.url.isFileURL && hasMediaServerLibraryContext(file)
    }

    private func resolvedMediaServer(for file: VideoFile) -> ServerConfig? {
        if let resolved = file.resolvedServer {
            return resolved
        }

        guard let serverIdString = file.jellyfinServerId,
              let serverId = UUID(uuidString: serverIdString) else {
            return nil
        }

        return AppNetworkService.shared.servers.first(where: { $0.id == serverId })
    }

    private func hydrateDownloadedLibraryMetadataIfNeeded(for file: VideoFile) {
        guard shouldTreatAsDownloadedLibraryItem(file),
              let itemId = file.jellyfinItemId,
              !itemId.isEmpty,
              let server = resolvedMediaServer(for: file) else {
            return
        }

        let existingStreams = currentMediaItem?.serverMediaStreams ?? playbackService.state.currentItem?.serverMediaStreams ?? file.serverMediaStreams
        if let existingStreams, !existingStreams.isEmpty {
            return
        }

        let mediaURL = file.url
        Task {
            let metadata: (
                streams: [[String: Any]],
                container: String?,
                size: Int64?,
                bitrate: Int?,
                path: String?,
                playbackMethod: RemotePlaybackMethod?,
                externalSubtitleCandidates: [ExternalSubtitleCandidate]
            )?

            do {
                switch server.type {
                case .jellyfin:
                    guard let token = server.accessToken, !token.isEmpty else { return }
                    let item = try await JellyfinService.shared.getItemDetails(server: server, itemId: itemId, token: token)
                    let mediaSources = item.mediaSources ?? []
                    let preferredSource = JellyfinService.shared.preferredPlaybackSource(from: mediaSources)
                    metadata = (
                        streams: JellyfinService.shared.preferredPlaybackStreams(from: mediaSources).map { $0.toDictionary() },
                        container: preferredSource?.container,
                        size: preferredSource?.size,
                        bitrate: preferredSource?.bitrate,
                        path: preferredSource?.path,
                        playbackMethod: JellyfinService.shared.playbackMethod(for: preferredSource, resolvedURL: nil, playbackQuality: .auto),
                        externalSubtitleCandidates: JellyfinService.shared.externalSubtitleCandidates(
                            server: server,
                            itemId: itemId,
                            mediaSources: mediaSources,
                            token: token,
                            mediaSourceId: preferredSource?.id
                        )
                    )
                case .emby:
                    guard let token = server.accessToken,
                          !token.isEmpty,
                          let userId = server.userId,
                          !userId.isEmpty else {
                        return
                    }
                    let item = try await EmbyService.shared.getItemDetails(server: server, userId: userId, itemId: itemId, token: token)
                    let mediaSources = item.mediaSources ?? []
                    let preferredSource = EmbyService.shared.preferredPlaybackSource(from: mediaSources)
                    metadata = (
                        streams: EmbyService.shared.preferredPlaybackStreams(from: mediaSources).map { $0.toDictionary() },
                        container: preferredSource?.container,
                        size: preferredSource?.size,
                        bitrate: preferredSource?.bitrate,
                        path: preferredSource?.path,
                        playbackMethod: EmbyService.shared.playbackMethod(for: preferredSource, resolvedURL: nil, playbackQuality: .auto),
                        externalSubtitleCandidates: EmbyService.shared.externalSubtitleCandidates(
                            server: server,
                            itemId: itemId,
                            mediaSources: mediaSources,
                            token: token,
                            mediaSourceId: preferredSource?.id
                        )
                    )
                case .plex:
                    guard let item = try await PlexService.shared.getMetadataItem(server: server, itemId: itemId),
                          let playable = PlexService.shared.buildPlayableVideoFile(server: server, item: item) else {
                        return
                    }
                    metadata = (
                        streams: playable.serverMediaStreams ?? [],
                        container: playable.serverContainer,
                        size: playable.serverSize,
                        bitrate: playable.serverBitrate,
                        path: playable.serverPath,
                        playbackMethod: playable.remotePlaybackMethod,
                        externalSubtitleCandidates: playable.externalSubtitleCandidates
                    )
                default:
                    return
                }
            } catch {
                print("[PlayerView] Failed to hydrate downloaded library metadata: \(error)")
                return
            }

            guard let metadata else { return }

            await MainActor.run {
                applyDownloadedLibraryMetadata(
                    streams: metadata.streams,
                    container: metadata.container,
                    size: metadata.size,
                    bitrate: metadata.bitrate,
                    path: metadata.path,
                    playbackMethod: metadata.playbackMethod,
                    externalSubtitleCandidates: metadata.externalSubtitleCandidates,
                    itemId: itemId,
                    mediaURL: mediaURL
                )
            }
        }
    }

    private func applyDownloadedLibraryMetadata(
        streams: [[String: Any]],
        container: String?,
        size: Int64?,
        bitrate: Int?,
        path: String?,
        playbackMethod: RemotePlaybackMethod?,
        externalSubtitleCandidates: [ExternalSubtitleCandidate],
        itemId: String,
        mediaURL: URL
    ) {
        func updateVideoFile(_ original: VideoFile?) -> VideoFile? {
            guard var file = original else { return nil }
            file.serverMediaStreams = streams
            file.serverContainer = container
            file.serverSize = size
            file.serverBitrate = bitrate
            file.serverPath = path
            file.remotePlaybackMethod = playbackMethod
            file.externalSubtitleCandidates = deduplicatedExternalSubtitleCandidates(
                file.externalSubtitleCandidates + externalSubtitleCandidates
            )
            return file
        }

        if var item = currentMediaItem,
           item.url == mediaURL || item.jellyfinItemId == itemId {
            item.serverMediaStreams = streams
            item.serverContainer = container
            item.serverSize = size
            item.serverBitrate = bitrate
            item.serverPath = path
            item.remotePlaybackMethod = playbackMethod
            item.externalSubtitleCandidates = deduplicatedExternalSubtitleCandidates(
                item.externalSubtitleCandidates + externalSubtitleCandidates
            )
            item.videoFile = updateVideoFile(item.videoFile)
            currentMediaItem = item
        }

        if var item = playbackService.state.currentItem,
           item.url == mediaURL || item.jellyfinItemId == itemId {
            item.serverMediaStreams = streams
            item.serverContainer = container
            item.serverSize = size
            item.serverBitrate = bitrate
            item.serverPath = path
            item.remotePlaybackMethod = playbackMethod
            item.externalSubtitleCandidates = deduplicatedExternalSubtitleCandidates(
                item.externalSubtitleCandidates + externalSubtitleCandidates
            )
            item.videoFile = updateVideoFile(item.videoFile)
            playbackService.state.currentItem = item
            if !externalSubtitleCandidates.isEmpty {
                playbackService.setExternalSubtitleCandidates(
                    for: mediaURL,
                    candidates: item.externalSubtitleCandidates,
                    autoSelectFirst: false
                )
            }
        }

        if var playlist = loadedPlaylist,
           let index = playlist.firstIndex(where: { $0.url == mediaURL || $0.jellyfinItemId == itemId }) {
            var playlistFile = playlist[index]
            playlistFile.serverMediaStreams = streams
            playlistFile.serverContainer = container
            playlistFile.serverSize = size
            playlistFile.serverBitrate = bitrate
            playlistFile.serverPath = path
            playlistFile.remotePlaybackMethod = playbackMethod
            playlistFile.externalSubtitleCandidates = deduplicatedExternalSubtitleCandidates(
                playlistFile.externalSubtitleCandidates + externalSubtitleCandidates
            )
            playlist[index] = playlistFile
            loadedPlaylist = playlist
        }
    }

    private func resolvedPlaybackQualityOption(for optionID: String?) -> RemotePlaybackQualityOption {
        AppSettings.shared.resolvedRemotePlaybackQualityOption(for: optionID)
    }

    private func resolvedPlaybackQualityID(for optionID: String?) -> String {
        AppSettings.shared.resolvedRemotePlaybackQualityID(for: optionID)
    }

    private func effectivePlaybackQualityID(for file: VideoFile) -> String? {
        resolvedPlaybackQualityID(for: sessionPlaybackQualityID ?? file.preferredPlaybackQualityID)
    }

    private func shouldResolveRemotePlaybackForCurrentSession(_ file: VideoFile) -> Bool {
        file.isRemote && (file.serverType == .jellyfin || file.serverType == .emby || file.serverType == .plex)
    }

    private func prepareRemotePlaybackFile(
        from file: VideoFile,
        startPosition: TimeInterval?,
        playbackQualityOverride: RemotePlaybackQualityOption? = nil
    ) async -> VideoFile? {
        if var localFile = downloadCenter.localPlaybackFile(for: file) {
            localFile.lastPlayedPosition = startPosition ?? file.lastPlayedPosition
            return localFile
        }

        guard shouldResolveRemotePlaybackForCurrentSession(file),
              let server = file.resolvedServer,
              let itemId = file.jellyfinItemId else {
            return file
        }

        let playbackQuality = playbackQualityOverride ?? resolvedPlaybackQualityOption(for: effectivePlaybackQualityID(for: file))
        let activeContextItem: MediaItem? = {
            if let currentMediaItem,
               currentMediaItem.jellyfinItemId == itemId,
               currentMediaItem.jellyfinServerId == server.id.uuidString {
                return currentMediaItem
            }
            if let currentItem = playbackService.state.currentItem,
               currentItem.jellyfinItemId == itemId,
               currentItem.jellyfinServerId == server.id.uuidString {
                return currentItem
            }
            return nil
        }()
        let startTimeTicks = playbackStartTimeTicks(from: startPosition)
        do {
            switch server.type {
            case .jellyfin:
                let token =
                    activeContextItem.map(\.url).flatMap(accessToken(from:)) ??
                    accessToken(from: file.url) ??
                    server.accessToken
                guard let token, !token.isEmpty else {
                    print("[PlayerView] Jellyfin switch failed: missing access token for itemId=\(itemId)")
                    return nil
                }

                let fallbackMediaSourceId =
                    activeContextItem?.mediaSourceId ??
                    mediaSourceID(from: file.url)

                func fallbackPreparedFile(reason: String) -> VideoFile? {
                    guard let rebuiltURL = JellyfinService.shared.rebuildPlaybackURL(
                        server: server,
                        itemId: itemId,
                        token: token,
                        mediaSourceId: fallbackMediaSourceId,
                        playbackQuality: playbackQuality
                    ) else {
                        print("[PlayerView] Jellyfin fallback rebuild failed for quality=\(playbackQuality.id) reason=\(reason)")
                        return nil
                    }

                    var preparedFile = file
                    preparedFile.url = rebuiltURL
                    preparedFile.lastPlayedPosition = startPosition
                    preparedFile.preferredPlaybackQualityID = playbackQuality.id
                    preparedFile.remotePlaybackMethod = playbackQuality.prefersConstrainedPlayback ? .transcode : .directPlay
                    return preparedFile
                }

                guard let userId = server.userId else {
                    return fallbackPreparedFile(reason: "missing_user_id")
                }

                do {
                    let playbackInfo = try await JellyfinService.shared.getPlaybackInfo(
                        server: server,
                        itemId: itemId,
                        userId: userId,
                        token: token,
                        playbackQuality: playbackQuality
                    )
                    let preferredSource = JellyfinService.shared.preferredPlaybackSource(
                        from: playbackInfo.mediaSources,
                        playbackQuality: playbackQuality
                    )
                    guard let resolvedURL = JellyfinService.shared.resolvePlaybackURL(
                        server: server,
                        itemId: itemId,
                        token: token,
                        mediaSource: preferredSource,
                        playbackQuality: playbackQuality
                    ) else {
                        return fallbackPreparedFile(reason: "resolve_playback_url_nil")
                    }

                    var preparedFile = file
                    preparedFile.url = resolvedURL
                    preparedFile.lastPlayedPosition = startPosition
                    preparedFile.preferredPlaybackQualityID = playbackQuality.id
                    preparedFile.availablePlaybackQualityOptions = JellyfinService.shared.qualityOptions(from: playbackInfo.mediaSources)
                    preparedFile.serverMediaStreams = preferredSource?.mediaStreams?.map { $0.toDictionary() }
                    preparedFile.serverContainer = preferredSource?.container
                    preparedFile.serverSize = preferredSource?.size
                    preparedFile.serverBitrate = preferredSource?.bitrate
                    preparedFile.serverPath = preferredSource?.path
                    preparedFile.remotePlaybackMethod = JellyfinService.shared.playbackMethod(
                        for: preferredSource,
                        resolvedURL: resolvedURL,
                        playbackQuality: playbackQuality
                    )
                    preparedFile.externalSubtitleCandidates = JellyfinService.shared.externalSubtitleCandidates(
                        server: server,
                        itemId: itemId,
                        mediaSources: playbackInfo.mediaSources,
                        token: token,
                        mediaSourceId: preferredSource?.id
                    )
                    return preparedFile
                } catch let error as JellyfinError {
                    if case .serverError(let code) = error, code == 404 {
                        print("[PlayerView] Jellyfin item not found (404) for itemId=\(itemId)")
                        return nil
                    }
                    print("[PlayerView] Jellyfin getPlaybackInfo failed for quality=\(playbackQuality.id): \(error)")
                    return fallbackPreparedFile(reason: "playback_info_error")
                } catch {
                    if (error as NSError).code == 404 {
                        return nil
                    }
                    print("[PlayerView] Jellyfin getPlaybackInfo failed for quality=\(playbackQuality.id): \(error)")
                    return fallbackPreparedFile(reason: "playback_info_error")
                }
            case .emby:
                let token =
                    activeContextItem.map(\.url).flatMap(accessToken(from:)) ??
                    accessToken(from: file.url) ??
                    server.accessToken
                guard let token, !token.isEmpty else {
                    print("[PlayerView] Emby switch failed: missing access token for itemId=\(itemId)")
                    return nil
                }

                let fallbackMediaSourceId =
                    activeContextItem?.mediaSourceId ??
                    mediaSourceID(from: file.url)

                let fallbackPlaySessionId =
                    activeContextItem?.playSessionId ??
                    playSessionID(from: file.url) ??
                    activeContextItem.map(\.url).flatMap(playSessionID(from:))

                func fallbackPreparedFile(reason: String) -> VideoFile? {
                    let finalPlaySessionId = fallbackPlaySessionId ?? UUID().uuidString
                    guard let rebuiltURL = EmbyService.shared.rebuildPlaybackURL(
                        server: server,
                        itemId: itemId,
                        token: token,
                        mediaSourceId: fallbackMediaSourceId,
                        playbackQuality: playbackQuality,
                        mediaSourceContainer: file.serverContainer ?? activeContextItem?.serverContainer,
                        playSessionId: finalPlaySessionId,
                        startTimeTicks: startTimeTicks
                    ) else {
                        print("[PlayerView] Emby fallback rebuild failed for quality=\(playbackQuality.id) reason=\(reason)")
                        return nil
                    }

                    var preparedFile = file
                    preparedFile.url = rebuiltURL
                    preparedFile.lastPlayedPosition = startPosition
                    preparedFile.preferredPlaybackQualityID = playbackQuality.id
                    preparedFile.remotePlaybackMethod = playbackQuality.prefersConstrainedPlayback ? .transcode : .directPlay
                    return preparedFile
                }

                guard let userId = server.userId else {
                    return fallbackPreparedFile(reason: "missing_user_id")
                }

                do {
                    let playbackInfo = try await EmbyService.shared.getPlaybackInfo(
                        server: server,
                        itemId: itemId,
                        userId: userId,
                        token: token,
                        playbackQuality: playbackQuality,
                        startTimeTicks: startTimeTicks,
                        currentPlaySessionId: fallbackPlaySessionId
                    )
                    let preferredSource = EmbyService.shared.preferredPlaybackSource(
                        from: playbackInfo.mediaSources,
                        playbackQuality: playbackQuality
                    )
                    let finalPlaySessionId = playbackInfo.playSessionId ?? fallbackPlaySessionId ?? UUID().uuidString
                    guard let resolvedURL = EmbyService.shared.resolvePlaybackURL(
                        server: server,
                        itemId: itemId,
                        token: token,
                        mediaSource: preferredSource,
                        playbackQuality: playbackQuality,
                        playSessionId: finalPlaySessionId,
                        startTimeTicks: startTimeTicks
                    ) else {
                        return fallbackPreparedFile(reason: "resolve_playback_url_nil")
                    }

                    var preparedFile = file
                    preparedFile.url = resolvedURL
                    preparedFile.lastPlayedPosition = startPosition
                    preparedFile.preferredPlaybackQualityID = playbackQuality.id
                    preparedFile.availablePlaybackQualityOptions = EmbyService.shared.qualityOptions(from: playbackInfo.mediaSources)
                    preparedFile.serverMediaStreams = preferredSource?.mediaStreams?.map { $0.toDictionary() }
                    preparedFile.serverContainer = preferredSource?.container
                    preparedFile.serverSize = preferredSource?.size
                    preparedFile.serverBitrate = preferredSource?.bitrate
                    preparedFile.serverPath = preferredSource?.path
                    preparedFile.remotePlaybackMethod = EmbyService.shared.playbackMethod(
                        for: preferredSource,
                        resolvedURL: resolvedURL,
                        playbackQuality: playbackQuality
                    )
                    preparedFile.externalSubtitleCandidates = EmbyService.shared.externalSubtitleCandidates(
                        server: server,
                        itemId: itemId,
                        mediaSources: playbackInfo.mediaSources,
                        token: token,
                        mediaSourceId: preferredSource?.id
                    )
                    return preparedFile
                } catch let error as EmbyError {
                    if case .serverError(let code) = error, code == 404 {
                        print("[PlayerView] Emby item not found (404) for itemId=\(itemId)")
                        return nil
                    }
                    print("[PlayerView] Emby getPlaybackInfo failed for quality=\(playbackQuality.id): \(error)")
                    return fallbackPreparedFile(reason: "playback_info_error")
                } catch {
                    if (error as NSError).code == 404 {
                        return nil
                    }
                    print("[PlayerView] Emby getPlaybackInfo failed for quality=\(playbackQuality.id): \(error)")
                    return fallbackPreparedFile(reason: "playback_info_error")
                }
            case .plex:
                guard let metadataItem = try await PlexService.shared.getMetadataItem(server: server, itemId: itemId) else {
                    return nil
                }
                guard let resolvedURL = PlexService.shared.resolvePlaybackURL(
                    server: server,
                    item: metadataItem,
                    playbackQuality: playbackQuality,
                    startPosition: startPosition
                ) else {
                    return nil
                }

                var preparedFile = file
                preparedFile.url = resolvedURL
                preparedFile.lastPlayedPosition = startPosition
                preparedFile.preferredPlaybackQualityID = playbackQuality.id
                preparedFile.availablePlaybackQualityOptions = PlexService.shared.qualityOptions(for: metadataItem)
                preparedFile.serverMediaStreams = metadataItem.mediaStreams.map { $0.toDictionary() }
                preparedFile.serverContainer = metadataItem.mediaContainer
                preparedFile.serverSize = metadataItem.mediaSize
                preparedFile.serverBitrate = metadataItem.mediaBitrate
                preparedFile.serverPath = metadataItem.mediaFilePath
                preparedFile.remotePlaybackMethod = PlexService.shared.playbackMethod(
                    for: playbackQuality,
                    resolvedURL: resolvedURL
                )
                if let decision = try await PlexService.shared.getPlaybackDecision(
                    server: server,
                    item: metadataItem,
                    playbackQuality: playbackQuality,
                    startPosition: startPosition
                ) {
                    if !decision.streams.isEmpty {
                        preparedFile.serverMediaStreams = decision.streams
                    }
                    preparedFile.serverContainer = decision.container ?? preparedFile.serverContainer
                    preparedFile.serverBitrate = decision.bitrate ?? preparedFile.serverBitrate
                    preparedFile.remotePlaybackMethod = decision.playbackMethod ?? preparedFile.remotePlaybackMethod
                }
                return preparedFile
            default:
                return file
            }
        } catch {
            print("[PlayerView] Failed to prepare remote playback file: \(error)")
            return nil
        }
    }

    private func refreshPlaybackQualityOptions(for file: VideoFile) async {
        guard shouldResolveRemotePlaybackForCurrentSession(file) else {
            await MainActor.run {
                playbackQualityOptions = []
                sessionPlaybackQualityID = nil
            }
            return
        }

        guard let server = file.resolvedServer,
              let itemId = file.jellyfinItemId else {
            await MainActor.run {
                playbackQualityOptions = AppSettings.shared.visibleRemotePlaybackQualityOptions(from: file.availablePlaybackQualityOptions)
                sessionPlaybackQualityID = AppSettings.shared.resolvedRemotePlaybackQualityID(
                    for: sessionPlaybackQualityID ?? file.preferredPlaybackQualityID
                )
            }
            return
        }

        do {
            let options: [RemotePlaybackQualityOption]
            switch server.type {
            case .jellyfin:
                guard let token = server.accessToken,
                      let userId = server.userId else {
                    throw NSError(domain: "PlayerView.RemotePlayback", code: -1)
                }
                let playbackInfo = try await JellyfinService.shared.getPlaybackInfo(
                    server: server,
                    itemId: itemId,
                    userId: userId,
                    token: token
                )
                options = JellyfinService.shared.qualityOptions(from: playbackInfo.mediaSources)
            case .emby:
                guard let token = server.accessToken,
                      let userId = server.userId else {
                    throw NSError(domain: "PlayerView.RemotePlayback", code: -1)
                }
                let playbackInfo = try await EmbyService.shared.getPlaybackInfo(
                    server: server,
                    itemId: itemId,
                    userId: userId,
                    token: token
                )
                options = EmbyService.shared.qualityOptions(from: playbackInfo.mediaSources)
            case .plex:
                let metadataItem = try await PlexService.shared.getMetadataItem(server: server, itemId: itemId)
                options = metadataItem.map(PlexService.shared.qualityOptions(for:)) ?? []
            default:
                options = []
            }

            await MainActor.run {
                let fallbackOptions = options.isEmpty ? file.availablePlaybackQualityOptions : options
                self.playbackQualityOptions = AppSettings.shared.visibleRemotePlaybackQualityOptions(from: fallbackOptions)
                self.sessionPlaybackQualityID = AppSettings.shared.resolvedRemotePlaybackQualityID(
                    for: self.sessionPlaybackQualityID ?? file.preferredPlaybackQualityID
                )
            }
        } catch {
            await MainActor.run {
                self.playbackQualityOptions = AppSettings.shared.visibleRemotePlaybackQualityOptions(from: file.availablePlaybackQualityOptions)
                self.sessionPlaybackQualityID = AppSettings.shared.resolvedRemotePlaybackQualityID(
                    for: self.sessionPlaybackQualityID ?? file.preferredPlaybackQualityID
                )
            }
        }
    }

    private func switchCurrentPlaybackQuality(to optionID: String) {
        guard AppSettings.shared.enablePlaybackQualitySwitchingBeta else { return }
        guard let currentItem = currentMediaItem,
              let playlist = loadedPlaylist,
              let currentIndex = playlist.firstIndex(where: { playlistItemMatches($0, mediaItem: currentItem) }) else {
            return
        }

        let resolvedOptionID = AppSettings.shared.resolvedRemotePlaybackQualityID(for: optionID)
        sessionPlaybackQualityID = resolvedOptionID
        if let file = loadedPlaylist?[currentIndex] {
            var updated = file
            updated.preferredPlaybackQualityID = resolvedOptionID
            loadedPlaylist?[currentIndex] = updated
        }

        Task {
            let currentTime = playbackService.state.currentTime
            guard let currentFile = loadedPlaylist?[currentIndex] else { return }
            let playbackFile = offlinePreferredPlaybackFile(currentFile)
            if playbackFile.isRemote && playbackFile.serverType == .jellyfin {
                _ = await playbackService.endCurrentServerPlaybackSessionForRestart(reason: "quality_switch")
            }
            guard let preparedFile = await prepareRemotePlaybackFile(
                    from: currentFile,
                    startPosition: currentTime,
                    playbackQualityOverride: resolvedPlaybackQualityOption(for: resolvedOptionID)
                  ) else {
                return
            }

            await MainActor.run {
                loadedPlaylist?[currentIndex] = preparedFile
                playResolvedVideoFile(preparedFile, startFromBeginning: false)
            }
        }
    }
    
    private func findExternalSubtitles(for video: VideoFile) -> [URL] {
        let subtitleExtensions = Set(VideoFile.FileType.subtitleExtensions)
        let videoName = video.url.deletingPathExtension().lastPathComponent.lowercased()

        var subtitleURLs: [URL] = []
        if let remoteFolderSubtitleURLs = remoteFolderSubtitleURLs {
            subtitleURLs = remoteFolderSubtitleURLs
        } else if let playlist {
            subtitleURLs = playlist
                .filter { file in
                    subtitleExtensions.contains(file.url.pathExtension.lowercased())
                }
                .map(\.url)
        }

        // Local fallback: scan sidecar subtitles from current video's folder.
        if subtitleURLs.isEmpty && video.url.isFileURL {
            let directoryURL = video.url.deletingLastPathComponent()
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            
            let scannedURLs = contents.filter { url in
                subtitleExtensions.contains(url.pathExtension.lowercased())
            }
            subtitleURLs.append(contentsOf: scannedURLs)
        }

        return rankedSubtitleURLs(subtitleURLs, for: videoName)
    }

    private func rankedSubtitleURLs(_ subtitleURLs: [URL], for videoName: String) -> [URL] {
        let scored = subtitleURLs.compactMap { url -> (url: URL, score: Int)? in
            let subtitleName = url.deletingPathExtension().lastPathComponent.lowercased()
            guard let score = subtitleMatchScore(videoName: videoName, subtitleName: subtitleName) else {
                return nil
            }
            return (url, score)
        }

        if !scored.isEmpty {
            return scored
                .sorted {
                    if $0.score == $1.score {
                        return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                    }
                    return $0.score > $1.score
                }
                .map(\.url)
        }

        // If no strong match (common in remote folders with arbitrary naming),
        // still expose all subtitle files so users can select manually.
        return subtitleURLs.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private func subtitleMatchScore(videoName: String, subtitleName: String) -> Int? {
        if subtitleName == videoName { return 100 }

        let separators = [".", "_", "-", " "]
        if separators.contains(where: { subtitleName.hasPrefix(videoName + $0) }) {
            return 95
        }

        if subtitleName.hasPrefix(videoName) { return 90 }
        if subtitleName.contains(videoName) { return 75 }

        if videoName.contains(subtitleName), subtitleName.count >= 4 {
            return 60
        }

        let prefixLength = subtitleName.commonPrefix(with: videoName).count
        if prefixLength >= 5 { return 50 }

        return nil
    }

    private func orderedRemoteSubtitleCandidates(
        _ candidates: [ExternalSubtitleCandidate],
        preferredQuery: String?,
        preferredOrdinal: Int?,
        videoName: String
    ) -> [ExternalSubtitleCandidate] {
        let rankedURLs = rankedSubtitleURLs(candidates.map(\.url), for: videoName)
        let rankMap = Dictionary(uniqueKeysWithValues: rankedURLs.enumerated().map { (index, url) in
            (subtitleCandidateKey(for: url), index)
        })
        let normalizedPreferredQuery = preferredQuery.map(normalizedSubtitleSearchText)
        let preferredKey: String?
        if let ordinal = preferredOrdinal, ordinal >= 0, ordinal < candidates.count {
            preferredKey = subtitleCandidateKey(for: candidates[ordinal].url)
        } else {
            preferredKey = nil
        }

        return candidates.sorted { lhs, rhs in
            let lhsPreferredOrdinal = preferredKey == subtitleCandidateKey(for: lhs.url)
            let rhsPreferredOrdinal = preferredKey == subtitleCandidateKey(for: rhs.url)
            if lhsPreferredOrdinal != rhsPreferredOrdinal {
                return lhsPreferredOrdinal && !rhsPreferredOrdinal
            }

            let lhsPreferred = normalizedPreferredQuery.map { remoteSubtitleCandidate(lhs, matches: $0) } ?? false
            let rhsPreferred = normalizedPreferredQuery.map { remoteSubtitleCandidate(rhs, matches: $0) } ?? false
            if lhsPreferred != rhsPreferred {
                return lhsPreferred && !rhsPreferred
            }

            let lhsRank = rankMap[subtitleCandidateKey(for: lhs.url)] ?? Int.max
            let rhsRank = rankMap[subtitleCandidateKey(for: rhs.url)] ?? Int.max
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
    }

    private func remoteSubtitleCandidate(_ candidate: ExternalSubtitleCandidate, matches normalizedQuery: String) -> Bool {
        guard !normalizedQuery.isEmpty else { return false }
        let displayName = normalizedSubtitleSearchText(candidate.displayName)
        let fileName = normalizedSubtitleSearchText(candidate.url.deletingPathExtension().lastPathComponent)
        return displayName.contains(normalizedQuery)
            || normalizedQuery.contains(displayName)
            || fileName.contains(normalizedQuery)
            || normalizedQuery.contains(fileName)
    }

    private func normalizedSubtitleSearchText(_ value: String) -> String {
        let lowered = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let allowed = CharacterSet.alphanumerics
        return String(lowered.unicodeScalars.filter { allowed.contains($0) })
    }

    private func subtitleCandidateKey(for url: URL) -> String {
        if url.isFileURL {
            return url.standardizedFileURL.path
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }

        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        if let queryItems = components.queryItems, !queryItems.isEmpty {
            let filtered = queryItems.filter { item in
                let name = item.name.lowercased()
                return name != "api_key" && name != "x-emby-token"
            }

            if filtered.isEmpty {
                components.queryItems = nil
            } else {
                components.queryItems = filtered.sorted { lhs, rhs in
                    let lhsName = lhs.name.lowercased()
                    let rhsName = rhs.name.lowercased()
                    if lhsName == rhsName {
                        return (lhs.value ?? "") < (rhs.value ?? "")
                    }
                    return lhsName < rhsName
                }
            }
        }

        return components.string ?? url.absoluteString
    }

    private func deduplicatedExternalSubtitleCandidates(_ candidates: [ExternalSubtitleCandidate]) -> [ExternalSubtitleCandidate] {
        var seen = Set<String>()
        var result: [ExternalSubtitleCandidate] = []
        for candidate in candidates {
            let key = subtitleCandidateKey(for: candidate.url)
            guard seen.insert(key).inserted else { continue }
            result.append(candidate)
        }
        return result
    }

    private func handleDrag(_ value: DragGesture.Value, in size: CGSize) {
        guard !ignoresDragUntilEnd, !playbackService.isInteractiveVideoGestureActive,
              size.width > 0, size.height > 0 else { return }
        let edgeMargin: CGFloat = 50.0
        if value.startLocation.y < edgeMargin || value.startLocation.y > size.height - edgeMargin { return }
        
        if !isDragging {
            isDragging = true
            dragType = .none
            dragOffset = .zero
            secondarySubtitleDragInitialRatio = nil
            gestureContainerSize = size
            initialBrightness = playbackService.brightness
            initialVolume = playbackService.outputVolume
            let total = playbackService.maxDuration 
            initialSeekTime = Int(Double(playbackService.progress) * total)
        }
        
        dragOffset = value.translation
        let screenHeight = max(gestureContainerSize.height, 1)
        
        if dragType == .none {
            if abs(dragOffset.width) > 10 || abs(dragOffset.height) > 10 {
                if isLongPressQuickPlaybackActive {
                    if !isQuickPlaybackSpeedLocked && dragOffset.height > 80 {
                        dragType = .speedLock
                        lockQuickPlaybackSpeed()
                    }
                    return
                }
                
                if canStartSecondarySubtitlePositionDrag(value, in: size),
                   abs(dragOffset.height) >= abs(dragOffset.width) {
                    clearSeekPreview()
                    dragType = .secondarySubtitlePosition
                    secondarySubtitleDragInitialRatio = currentSecondarySubtitleVerticalPositionRatio(in: size)
                } else if abs(dragOffset.width) > abs(dragOffset.height) {
                    dragType = .seek
                    playbackService.isScrubbing = true
                    beginSeekPreviewSession(initialTime: Double(initialSeekTime))
                } else {
                    clearSeekPreview()
                    if value.startLocation.x < size.width / 2 { dragType = .brightness }
                    else { dragType = .volume }
                }
            }
        }
        
        switch dragType {
        case .secondarySubtitlePosition:
            updateSecondarySubtitleVerticalPosition(value, in: size)
        case .brightness:
            let delta = -dragOffset.height / screenHeight
            playbackService.setBrightness(initialBrightness + delta)
        case .volume:
            let delta = Float(-dragOffset.height / screenHeight)
            playbackService.setVolume(initialVolume + delta)
        case .seek:
            let progress = Float(indicatorValue())
            scrubPreviewProgress = progress
            updateSeekPreview(targetTime: Double(progress) * playbackService.maxDuration)
        default: break
        }
    }

    private func handleSecondarySubtitleAdjustmentGestureChanged(_ value: DragGesture.Value, in size: CGSize) {
        guard !ignoresSubtitleDragUntilEnd, canShowSecondarySubtitleAdjustmentControls else { return }

        activateSecondarySubtitleAdjustment(autoHide: false)
        if !isDragging {
            isDragging = true
            dragType = .secondarySubtitlePosition
            dragOffset = .zero
            secondarySubtitleDragInitialRatio = currentSecondarySubtitleVerticalPositionRatio(in: size)
        }

        dragOffset = value.translation
        let distance = max(abs(value.translation.width), abs(value.translation.height))
        guard distance > 2 else { return }

        clearSeekPreview()
        updateSecondarySubtitleVerticalPosition(value, in: size)
    }

    private func handleSecondarySubtitleAdjustmentGestureEnded(_ value: DragGesture.Value, in size: CGSize) {
        defer { ignoresSubtitleDragUntilEnd = false }
        guard !ignoresSubtitleDragUntilEnd else { return }
        guard canShowSecondarySubtitleAdjustmentControls else {
            endSecondarySubtitlePositionDrag()
            return
        }

        let distance = max(abs(value.translation.width), abs(value.translation.height))
        if distance <= 2 {
            activateSecondarySubtitleAdjustment(autoHide: true)
        } else {
            updateSecondarySubtitleVerticalPosition(value, in: size)
            scheduleSecondarySubtitleAdjustmentHide(after: 2.0)
        }
        endSecondarySubtitlePositionDrag()
    }
    
    private func cancelGesturesForLayoutChange() {
        // A resize invalidates gesture coordinates, not the playback session.
        ignoresDragUntilEnd = ignoresDragUntilEnd || isTouchDragActive
        ignoresSubtitleDragUntilEnd = ignoresSubtitleDragUntilEnd || isSubtitleDragActive
        cancelsCurrentScrub = cancelsCurrentScrub || playbackService.isScrubbing
        endLongPressQuickPlaybackIfNeeded()
        endSecondarySubtitlePositionDrag()
        playbackService.isScrubbing = false
        clearSeekPreview()
        dismissFeedback()
        dismissFloatingMenu()
    }

    private func handleDragEnded() {
        defer { ignoresDragUntilEnd = false }
        guard !ignoresDragUntilEnd else { return }
        guard !playbackService.isInteractiveVideoGestureActive else { return }
        if dragType == .seek {
            commitSeekPreviewIfNeeded()
            playbackService.isScrubbing = false
        } else if dragType == .secondarySubtitlePosition {
            clearSeekPreview()
            scheduleSecondarySubtitleAdjustmentHide(after: 2.0)
        } else if dragType == .speedLock {
            // No action needed on drag end for speed lock
        } else {
            clearSeekPreview()
        }
        endSecondarySubtitlePositionDrag()
    }

    private func endSecondarySubtitlePositionDrag() {
        isDragging = false
        dragType = .none
        dragOffset = .zero
        secondarySubtitleDragInitialRatio = nil
    }

    private func activateSecondarySubtitleAdjustment(autoHide: Bool) {
        guard canShowSecondarySubtitleAdjustmentControls else { return }
        isSecondarySubtitlePositionAdjustmentActive = true
        secondarySubtitleAdjustmentHideWorkItem?.cancel()
        secondarySubtitleAdjustmentHideWorkItem = nil

        if autoHide {
            scheduleSecondarySubtitleAdjustmentHide(after: 3.0)
        }
    }

    private func scheduleSecondarySubtitleAdjustmentHide(after delay: TimeInterval) {
        secondarySubtitleAdjustmentHideWorkItem?.cancel()
        let workItem = DispatchWorkItem {
            hideSecondarySubtitleAdjustment()
        }
        secondarySubtitleAdjustmentHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func hideSecondarySubtitleAdjustment() {
        secondarySubtitleAdjustmentHideWorkItem?.cancel()
        secondarySubtitleAdjustmentHideWorkItem = nil
        withAnimation(.easeInOut(duration: 0.15)) {
            isSecondarySubtitlePositionAdjustmentActive = false
        }
    }

    private func canStartSecondarySubtitlePositionDrag(_ value: DragGesture.Value, in size: CGSize) -> Bool {
        guard canShowSecondarySubtitleAdjustmentControls,
              isSecondarySubtitlePositionAdjustmentActive else {
            return false
        }

        let videoRect = calculateVideoRect(containerSize: size, videoSize: playbackService.videoNaturalSize)
        guard videoRect.width > 0, videoRect.height > 0 else { return false }

        if playbackService.isNativeASSSecondarySubtitle {
            return nativeASSAdjustmentRect(in: size).insetBy(dx: -8, dy: -8).contains(value.startLocation)
        }
        let orientation = secondarySubtitleLayoutOrientation(for: size)
        let subtitleY = videoRect.minY + secondarySubtitleVerticalPosition(
            in: videoRect.height,
            orientation: orientation
        )
        let hitSlop = max(44, min(88, videoRect.height * 0.12))
        let horizontalPadding: CGFloat = 28
        return value.startLocation.x >= videoRect.minX - horizontalPadding &&
            value.startLocation.x <= videoRect.maxX + horizontalPadding &&
            abs(value.startLocation.y - subtitleY) <= hitSlop
    }

    private func currentSecondarySubtitleVerticalPositionRatio(in size: CGSize) -> CGFloat {
        let orientation = secondarySubtitleLayoutOrientation(for: size)
        if let customRatio = playbackService.secondarySubtitleVerticalPositionRatio(for: orientation) {
            return CGFloat(customRatio)
        }

        let videoRect = calculateVideoRect(containerSize: size, videoSize: playbackService.videoNaturalSize)
        guard videoRect.height > 0 else {
            return CGFloat(AppSettings.clampedSecondarySubtitlePositionRatio(0.56))
        }
        if playbackService.isNativeASSSecondarySubtitle, playbackService.nativeASSBounds != nil {
            return (nativeASSAdjustmentRect(in: size).midY - videoRect.minY) / videoRect.height
        }
        let currentY = secondarySubtitleVerticalPosition(
            in: videoRect.height,
            orientation: orientation
        )
        return currentY / videoRect.height
    }

    private func updateSecondarySubtitleVerticalPosition(_ value: DragGesture.Value, in size: CGSize) {
        let videoRect = calculateVideoRect(containerSize: size, videoSize: playbackService.videoNaturalSize)
        guard videoRect.height > 0 else { return }

        let initialRatio = secondarySubtitleDragInitialRatio ?? currentSecondarySubtitleVerticalPositionRatio(in: size)
        if secondarySubtitleDragInitialRatio == nil {
            secondarySubtitleDragInitialRatio = initialRatio
        }

        let ratio = initialRatio + value.translation.height / videoRect.height
        let clampedRatio = AppSettings.clampedSecondarySubtitlePositionRatio(Double(ratio))
        playbackService.setSecondarySubtitleVerticalPositionRatio(
            clampedRatio,
            for: secondarySubtitleLayoutOrientation(for: size)
        )
    }

    private func beginSeekPreviewSession(initialTime: Double) {
        let clampedInitialTime = max(0, min(initialTime, playbackService.maxDuration))
        seekPreviewInitialTime = clampedInitialTime
        let session = UUID()
        seekPreviewSessionID = session
        seekPreviewTargetTime = nil
        seekPreviewImage = playbackService.captureCurrentFramePreview()
        if playbackService.isUsingMPV {
            playbackService.requestCurrentFrame { image in
                guard seekPreviewSessionID == session, seekPreviewImage == nil,
                      abs((seekPreviewTargetTime ?? clampedInitialTime) - clampedInitialTime) <= seekPreviewMaximumDisplayedImageDrift else { return }
                seekPreviewImage = image
                seekPreviewDisplayedImageTargetTime = image == nil ? nil : clampedInitialTime
            }
        }
        seekPreviewDisplayedImageTargetTime = seekPreviewImage == nil ? nil : clampedInitialTime
        seekPreviewRequestID = nil
        seekPreviewPendingTargetTime = nil
        seekPreviewRequestInFlight = false
        seekPreviewLastRequestedTime = nil
        if playbackService.maxDuration > 0 {
            scrubPreviewProgress = Float(clampedInitialTime / playbackService.maxDuration)
        } else {
            scrubPreviewProgress = nil
        }
        seekPreviewCaptureWorkItem?.cancel()
        seekPreviewCaptureWorkItem = nil
        playbackService.cancelSeekPreviewImageRequest()
        lastSeekPreviewCaptureDate = .distantPast
    }

    private func updateSeekPreview(targetTime: Double) {
        guard playbackService.maxDuration > 0 else { return }
        let clampedTime = max(0, min(targetTime, playbackService.maxDuration))
        if seekPreviewInitialTime == nil {
            beginSeekPreviewSession(initialTime: playbackService.state.currentTime)
        }
        seekPreviewTargetTime = clampedTime
        if playbackService.maxDuration > 0 {
            scrubPreviewProgress = Float(clampedTime / playbackService.maxDuration)
        }
        scheduleSeekPreviewCapture()
    }

    private func commitSeekPreviewIfNeeded() {
        if let targetTime = seekPreviewTargetTime {
            seekWithoutPreview(to: targetTime)
        } else if let previewProgress = scrubPreviewProgress, playbackService.maxDuration > 0 {
            seekWithoutPreview(to: Double(previewProgress) * playbackService.maxDuration)
        }
        clearSeekPreview()
    }

    private func scheduleSeekPreviewCapture(force: Bool = false) {
        guard let targetTime = seekPreviewTargetTime else { return }

        seekPreviewCaptureWorkItem?.cancel()

        if seekPreviewRequestInFlight {
            seekPreviewPendingTargetTime = targetTime
            if shouldReplaceInFlightSeekPreviewRequest(with: targetTime) {
                seekPreviewCaptureWorkItem?.cancel()
                seekPreviewCaptureWorkItem = nil
                seekPreviewRequestInFlight = false
                playbackService.cancelSeekPreviewImageRequest()
                enqueueSeekPreviewCapture(after: 0)
            }
            return
        }

        let elapsed = Date().timeIntervalSince(lastSeekPreviewCaptureDate)
        let throttleDelay = max(0, seekPreviewRequestThrottleInterval - elapsed)
        let requiresUrgentRefresh: Bool = {
            guard let displayedTargetTime = seekPreviewDisplayedImageTargetTime else {
                return seekPreviewImage == nil
            }
            return seekPreviewImage == nil ||
                abs(targetTime - displayedTargetTime) > seekPreviewMaximumDisplayedImageDrift
        }()

        if !force, shouldRequestSeekPreview(for: targetTime), (requiresUrgentRefresh || throttleDelay <= 0) {
            enqueueSeekPreviewCapture(after: 0)
            return
        }

        let delay: TimeInterval
        if force {
            delay = 0
        } else if shouldRequestSeekPreview(for: targetTime) {
            delay = throttleDelay
        } else {
            delay = max(seekPreviewTrailingDebounceInterval, throttleDelay)
        }
        enqueueSeekPreviewCapture(after: delay)
    }

    private func enqueueSeekPreviewCapture(after delay: TimeInterval) {
        let requestID = UUID()
        seekPreviewRequestID = requestID
        let workItem = DispatchWorkItem {
            guard let currentTargetTime = seekPreviewTargetTime else {
                seekPreviewCaptureWorkItem = nil
                return
            }

            startSeekPreviewRequest(at: currentTargetTime, requestID: requestID)
            seekPreviewCaptureWorkItem = nil
        }

        seekPreviewCaptureWorkItem = workItem
        if delay <= 0 {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func startSeekPreviewRequest(at targetTime: Double, requestID: UUID) {
        seekPreviewRequestInFlight = true
        seekPreviewPendingTargetTime = nil
        seekPreviewLastRequestedTime = targetTime
        lastSeekPreviewCaptureDate = Date()

        playbackService.requestSeekPreviewImage(at: targetTime) { image in
            guard seekPreviewRequestID == requestID else { return }

            seekPreviewRequestInFlight = false
            let latestTargetTime = seekPreviewTargetTime ?? targetTime
            let returnedImageDisplayTime = normalizedSeekPreviewDisplayTime(for: targetTime)
            let returnedImageDistance = abs(latestTargetTime - returnedImageDisplayTime)
            let displayedImageDistance = displayedSeekPreviewImageDistance(to: latestTargetTime)
            let shouldDisplayReturnedImage =
                seekPreviewPendingTargetTime == nil &&
                returnedImageDistance <= seekPreviewMaximumDisplayedImageDrift
            let returnedImageImprovesDisplayedFrame =
                returnedImageDistance + 0.05 < displayedImageDistance

            if let image, shouldDisplayReturnedImage || returnedImageImprovesDisplayedFrame {
                seekPreviewImage = image
                seekPreviewDisplayedImageTargetTime = returnedImageDisplayTime
            }

            if seekPreviewPendingTargetTime != nil {
                scheduleSeekPreviewCapture(force: true)
            }
        }
    }

    private func shouldRequestSeekPreview(for targetTime: Double) -> Bool {
        if let targetBucket = seekPreviewFrameBucket(for: targetTime),
           let lastRequestedTime = seekPreviewLastRequestedTime,
           let lastRequestedBucket = seekPreviewFrameBucket(for: lastRequestedTime) {
            return targetBucket != lastRequestedBucket
        }

        guard let lastRequestedTime = seekPreviewLastRequestedTime else { return true }
        return abs(targetTime - lastRequestedTime) >= seekPreviewMinimumRequestDelta
    }

    private func seekPreviewFrameBucket(for targetTime: Double) -> Int? {
        guard let frameInterval = remoteSeekPreviewFrameInterval else { return nil }
        return Int(floor(max(targetTime, 0) / frameInterval))
    }

    private func normalizedSeekPreviewDisplayTime(for targetTime: Double) -> Double {
        guard let frameInterval = remoteSeekPreviewFrameInterval,
              let frameBucket = seekPreviewFrameBucket(for: targetTime) else {
            return targetTime
        }

        return (Double(frameBucket) * frameInterval) + (frameInterval * 0.5)
    }

    private func displayedSeekPreviewImageDistance(to targetTime: Double) -> Double {
        guard seekPreviewImage != nil,
              let displayedImageTargetTime = seekPreviewDisplayedImageTargetTime else {
            return .greatestFiniteMagnitude
        }

        return abs(targetTime - displayedImageTargetTime)
    }

    private func shouldReplaceInFlightSeekPreviewRequest(with targetTime: Double) -> Bool {
        guard isRemoteSeekPreview,
              seekPreviewImage == nil,
              let inFlightTargetTime = seekPreviewLastRequestedTime else {
            return false
        }

        let requestAge = Date().timeIntervalSince(lastSeekPreviewCaptureDate)
        guard requestAge >= 0.35 else {
            return false
        }

        return abs(targetTime - inFlightTargetTime) >= seekPreviewInFlightReplacementDelta
    }

    private var seekPreviewRequestThrottleInterval: TimeInterval {
        isRemoteSeekPreview ? 0.12 : 0.08
    }

    private var seekPreviewTrailingDebounceInterval: TimeInterval {
        isRemoteSeekPreview ? 0.09 : 0.06
    }

    private var seekPreviewMinimumRequestDelta: Double {
        if let frameInterval = remoteSeekPreviewFrameInterval {
            return max(0.35, min(2.0, frameInterval * 0.5))
        }
        if isRemoteSeekPreview {
            return max(0.75, min(2.0, playbackService.maxDuration / 2400.0))
        }
        return max(0.35, min(1.5, playbackService.maxDuration / 3600.0))
    }

    private var seekPreviewMaximumDisplayedImageDrift: Double {
        if let frameInterval = remoteSeekPreviewFrameInterval {
            return max(0.75, min(6.0, max(0.25, (frameInterval * 0.5) - 0.05)))
        }
        if isRemoteSeekPreview {
            return max(1.5, min(4.0, playbackService.maxDuration / 1800.0))
        }
        return max(0.45, min(1.0, playbackService.maxDuration / 5400.0))
    }

    private var seekPreviewInFlightReplacementDelta: Double {
        if isRemoteSeekPreview {
            return max(4.0, min(12.0, playbackService.maxDuration / 300.0))
        }
        return max(2.0, min(8.0, playbackService.maxDuration / 450.0))
    }

    private func clearSeekPreview() {
        seekPreviewSessionID = nil
        seekPreviewCaptureWorkItem?.cancel()
        seekPreviewCaptureWorkItem = nil
        seekPreviewRequestID = nil
        seekPreviewPendingTargetTime = nil
        seekPreviewRequestInFlight = false
        seekPreviewLastRequestedTime = nil
        seekPreviewDisplayedImageTargetTime = nil
        playbackService.cancelSeekPreviewImageRequest()
        seekPreviewTargetTime = nil
        seekPreviewInitialTime = nil
        seekPreviewImage = nil
        scrubPreviewProgress = nil
    }
    
    private func indicatorValue() -> Double {
        switch dragType {
        case .brightness: return Double(playbackService.brightness)
        case .volume: return Double(playbackService.volume)
        case .seek: 
            let width = max(gestureContainerSize.width, 1)
            let percentage = Double(dragOffset.width / width)
            let total = playbackService.maxDuration
            
            // 1. Calculate adaptive base speed based on total video length
            let baseSeekMax: Double
            if total <= 300 {
                // Short video (<= 5 mins): swipe covers 20% of the video
                baseSeekMax = total * 0.2
            } else if total <= 1800 {
                // Medium video (5-30 mins): scale linearly from 60s to 180s
                let ratio = (total - 300) / (1800 - 300)
                baseSeekMax = 60 + (ratio * (180 - 60))
            } else {
                // Long video (> 30 mins): 5 minutes per full swipe
                baseSeekMax = 300
            }
            
            // 2. Calculate vertical deviation for fine scrubbing
            let yOffset = abs(dragOffset.height)
            let speedMultiplier: Double
            
            if yOffset < 50 {
                speedMultiplier = 1.0     // Full speed
            } else if yOffset < 150 {
                speedMultiplier = 0.5     // Half speed
            } else if yOffset < 250 {
                speedMultiplier = 0.25    // Quarter speed
            } else {
                speedMultiplier = 0.1     // Fine control (10% speed)
            }
            
            let seekDelta = percentage * baseSeekMax * speedMultiplier
            
            let targetTime = Double(initialSeekTime) + seekDelta
            let clampedTime = max(0, min(targetTime, total))
            return total > 0 ? clampedTime / total : 0
        default: return 0
        }
    }
    
    private func calculateVideoRect(containerSize: CGSize, videoSize: CGSize) -> CGRect {
        return VLCPlaybackService.visibleVideoRect(
            containerSize: containerSize,
            naturalVideoSize: videoSize,
            aspectRatioOverride: playbackService.state.aspectRatio,
            displayMode: playbackService.state.videoDisplayMode
        )
    }

    private func restoreOrientation() {
        cancelPendingAutoRotateRetry()
        isAutoRotateAttemptInFlight = false

        guard UIDevice.current.userInterfaceIdiom != .pad else {
            AppDelegate.orientationLock = .all
            return
        }

        UIApplication.requestInterfaceOrientation(
            .portrait,
            lock: .portrait,
            allowForceFallback: false
        ) { _ in
            AppDelegate.orientationLock = .all
            UIApplication.refreshInterfaceChrome(delays: [0, 0.12])
        }
    }

    private func applyAutoRotatePreferenceIfNeeded() {
        if let currentItemID = playbackService.state.currentItem?.id {
            if skipAutoRotateForItemID == currentItemID {
                hasHandledAutoRotateForCurrentItem = true
                return
            }
            if skipAutoRotateForItemID != nil {
                skipAutoRotateForItemID = nil
            }
        }

        if playbackService.shouldDeferAutoRotateForRestoredPlayer(file: initialFile) {
            return
        }

        guard let currentItemID = playbackService.state.currentItem?.id else { return }
        if autoRotateHandledItemID != currentItemID {
            autoRotateHandledItemID = currentItemID
            hasHandledAutoRotateForCurrentItem = false
            autoRotateTargetOrientation = nil
            autoRotateAttemptCount = 0
            isAutoRotateAttemptInFlight = false
            cancelPendingAutoRotateRetry()
        }
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            hasHandledAutoRotateForCurrentItem = true
            return
        }
        if #available(iOS 27.1, *), AdaptiveMediaLayout.defersPhoneAutoRotation(
            regularWidth: horizontalSizeClass == .regular,
            regularHeight: verticalSizeClass == .regular
        ) {
            cancelPendingAutoRotateRetry()
            return
        }

        let mode = AppSettings.shared.videoAutoRotateMode
        guard mode != .off else {
            hasHandledAutoRotateForCurrentItem = true
            autoRotateTargetOrientation = nil
            return
        }

        let videoSize = playbackService.videoNaturalSize
        guard videoSize.width > 0, videoSize.height > 0 else { return }

        let desiredOrientation: UIInterfaceOrientation
        switch mode {
        case .off:
            return
        case .alwaysLandscape:
            desiredOrientation = .landscapeRight
        case .followVideoAspect:
            let aspectRatio = videoSize.width / videoSize.height
            desiredOrientation = aspectRatio >= 1.2 ? .landscapeRight : .portrait
        }

        if autoRotateTargetOrientation != desiredOrientation {
            autoRotateTargetOrientation = desiredOrientation
            hasHandledAutoRotateForCurrentItem = false
            autoRotateAttemptCount = 0
            isAutoRotateAttemptInFlight = false
            cancelPendingAutoRotateRetry()
        }

        guard !hasHandledAutoRotateForCurrentItem else { return }
        guard !isAutoRotateAttemptInFlight else { return }
        guard autoRotateRetryWorkItem == nil else { return }

        let currentOrientation = UIApplication.activeInterfaceOrientation()
        let isAlreadyAtDesiredOrientation = desiredOrientation.isLandscape
            ? currentOrientation.isLandscape
            : currentOrientation.isPortrait
        if isAlreadyAtDesiredOrientation {
            hasHandledAutoRotateForCurrentItem = true
            cancelPendingAutoRotateRetry()
            return
        }

        rotatePlayerIfNeeded(to: desiredOrientation)
    }

    private func rotatePlayerIfNeeded(to targetOrientation: UIInterfaceOrientation) {
        let currentOrientation = UIApplication.activeInterfaceOrientation()
        let isAlreadyAtDesiredOrientation = targetOrientation.isLandscape
            ? currentOrientation.isLandscape
            : currentOrientation.isPortrait
        guard !isAlreadyAtDesiredOrientation else {
            hasHandledAutoRotateForCurrentItem = true
            cancelPendingAutoRotateRetry()
            return
        }

        guard autoRotateAttemptCount < 3 else {
            hasHandledAutoRotateForCurrentItem = true
            cancelPendingAutoRotateRetry()
            return
        }

        isAutoRotateAttemptInFlight = true
        autoRotateAttemptCount += 1
        let targetMask: UIInterfaceOrientationMask = targetOrientation.isLandscape ? .landscapeRight : .portrait

        UIApplication.requestInterfaceOrientation(
            targetOrientation,
            lock: targetMask,
            allowForceFallback: false
        ) { didRotate in
            isAutoRotateAttemptInFlight = false
            AppDelegate.orientationLock = .all
            UIApplication.refreshInterfaceChrome(delays: [0, 0.12])

            if didRotate {
                hasHandledAutoRotateForCurrentItem = true
                cancelPendingAutoRotateRetry()
            } else {
                scheduleAutoRotateRetry()
            }
        }
    }

    private func cancelPendingAutoRotateRetry() {
        autoRotateRetryWorkItem?.cancel()
        autoRotateRetryWorkItem = nil
    }

    private func scheduleAutoRotateRetry() {
        guard !hasHandledAutoRotateForCurrentItem else { return }
        guard autoRotateAttemptCount < 3 else {
            hasHandledAutoRotateForCurrentItem = true
            cancelPendingAutoRotateRetry()
            return
        }

        cancelPendingAutoRotateRetry()

        let workItem = DispatchWorkItem {
            autoRotateRetryWorkItem = nil
            applyAutoRotatePreferenceIfNeeded()
        }
        autoRotateRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: workItem)
    }
    
    private func handleMenuWillOpen() {
        isMenuPresented = true
        playbackService.isMenuPresented = true
        lastInteractionTime = Date()
        if !playbackService.showControlOverlay {
            playbackService.showControlOverlay = true
        }
        scheduleOverlayHide()
    }

    private func presentFloatingMenu(_ screen: PlayerFloatingMenuScreen) {
        handleMenuWillOpen()
        activeMenuScreen = nil
        let presentationID = UUID()
        floatingMenuPresentationID = presentationID
        DispatchQueue.main.async {
            guard floatingMenuPresentationID == presentationID, scenePhase == .active, isMenuPresented else { return }
            activeMenuScreen = screen
        }
    }

    private func dismissFloatingMenu() {
        floatingMenuPresentationID = UUID()
        activeMenuScreen = nil
        isMenuPresented = false
        playbackService.isMenuPresented = false
        playbackService.flushDeferredTrackRefreshIfNeeded()
        scheduleOverlayHide()
    }

    private func dismissFeedback() {
        feedbackHideWorkItem?.cancel()
        feedbackHideWorkItem = nil
        withAnimation {
            feedbackData = nil
        }
    }

    private func dismissInteractiveZoomFeedback() {
        interactiveZoomFeedbackHideWorkItem?.cancel()
        interactiveZoomFeedbackHideWorkItem = nil
        interactiveZoomResetHintWorkItem?.cancel()
        interactiveZoomResetHintWorkItem = nil
        withAnimation {
            interactiveZoomFeedbackText = nil
        }
    }
    
    private func showFeedback(icon: String, text: String) {
        showFeedback(icon: icon, text: text, autoDismissAfter: 1.0)
    }

    private func showFeedback(icon: String, text: String, autoDismissAfter delay: TimeInterval? = 1.0) {
        feedbackHideWorkItem?.cancel()
        feedbackHideWorkItem = nil
        withAnimation { feedbackData = FeedbackData(icon: icon, text: text) }
        if let delay = delay {
            let workItem = DispatchWorkItem {
                dismissFeedback()
            }
            feedbackHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
        // Reset overlay hide timer on every user interaction
        scheduleOverlayHide()
    }

    private func showInteractiveZoomFeedback(scale: CGFloat, autoDismissAfter delay: TimeInterval? = nil) {
        interactiveZoomFeedbackHideWorkItem?.cancel()
        interactiveZoomFeedbackHideWorkItem = nil
        let clampedScale = VLCPlaybackService.clampedInteractiveVideoZoomScale(scale)
        let text = "\(Int((clampedScale * 100).rounded()))%"
        withAnimation {
            interactiveZoomFeedbackText = text
        }
        if let delay {
            let workItem = DispatchWorkItem {
                withAnimation {
                    interactiveZoomFeedbackText = nil
                }
            }
            interactiveZoomFeedbackHideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
        scheduleOverlayHide()
    }

    private func handleInteractiveZoomScaleChanged(_ scale: CGFloat) {
        interactiveZoomResetHintWorkItem?.cancel()
        interactiveZoomResetHintWorkItem = nil
        showInteractiveZoomFeedback(scale: scale, autoDismissAfter: nil)
    }

    private func handleInteractiveZoomScaleEnded(_ scale: CGFloat) {
        let clampedScale = VLCPlaybackService.clampedInteractiveVideoZoomScale(scale)
        showInteractiveZoomFeedback(scale: clampedScale, autoDismissAfter: 0.9)

        guard clampedScale > 1.02, !hasShownInteractiveZoomResetHint else { return }
        hasShownInteractiveZoomResetHint = true

        let workItem = DispatchWorkItem {
            showFeedback(
                icon: "hand.tap",
                text: NSLocalizedString("Double-tap with two fingers to reset", comment: ""),
                autoDismissAfter: 1.8
            )
        }
        interactiveZoomResetHintWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95, execute: workItem)
    }

    private func handleInteractiveZoomReset() {
        dismissInteractiveZoomFeedback()
        showFeedback(
            icon: "arrow.counterclockwise",
            text: NSLocalizedString("Reset Zoom", comment: "")
        )
    }

    private func lockQuickPlaybackSpeed() {
        guard let targetRate = activeQuickPlaybackRate else { return }
        isQuickPlaybackSpeedLocked = true
        
        playbackService.setPlaybackRate(targetRate)
        
        if targetRate != pressAndHoldQuickPlaybackTargetRate {
            originalPlaybackRateBeforeLock = nil
        }
    }

    private func activateLongPressQuickPlayback() {
        guard !isLongPressQuickPlaybackActive,
              !isLocked,
              !isDragging,
              !playbackService.isBuffering,
              let quickRate = pressAndHoldQuickPlaybackTargetRate else {
            return
        }

        let currentRate = max(playbackService.state.rate, 0.1)
        let targetRate: Float
        
        if currentRate >= quickRate - 0.01 {
            // Already at or above quick rate. Toggle back to original.
            targetRate = originalPlaybackRateBeforeLock ?? 1.0
        } else {
            // Normal quick rate
            originalPlaybackRateBeforeLock = currentRate
            targetRate = quickRate
        }
        
        guard targetRate != currentRate else { return }

        longPressQuickPlaybackRestoreRate = currentRate
        activeQuickPlaybackRate = targetRate
        isLongPressQuickPlaybackActive = true
        isQuickPlaybackSpeedLocked = false
        playbackService.setTemporaryPlaybackRate(targetRate)
    }

    private func endLongPressQuickPlaybackIfNeeded() {
        guard isLongPressQuickPlaybackActive else { return }

        isLongPressQuickPlaybackActive = false

        if isQuickPlaybackSpeedLocked {
            longPressQuickPlaybackRestoreRate = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                if !isLongPressQuickPlaybackActive {
                    withAnimation { isQuickPlaybackSpeedLocked = false }
                }
            }
            return
        }

        let restoreRate = max(longPressQuickPlaybackRestoreRate ?? 1.0, 0.1)
        longPressQuickPlaybackRestoreRate = nil
        suppressTapActionsUntil = Date().addingTimeInterval(0.25)
        playbackService.setTemporaryPlaybackRate(restoreRate)
        dismissFeedback()
    }
    
    private func scheduleOverlayHide() {
        overlayHideTimer?.invalidate()
        lastInteractionTime = Date()
        overlayHideTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(lastInteractionTime)
            if isMenuPresented || playbackService.isMenuPresented {
                lastInteractionTime = Date()
                return
            }
            if elapsed >= 5.0 {
                timer.invalidate()
                if playbackService.showControlOverlay && !playbackService.isScrubbing && !isDragging {
                    withAnimation { playbackService.showControlOverlay = false }
                }
            }
        }
    }
    
    private func gestureFeedbackInfo(diff: Double = 0) -> (String, String) {
        let screenHeight = max(gestureContainerSize.height, 1)
        
        switch dragType {
        case .brightness: 
            let delta = -dragOffset.height / screenHeight
            let val = max(0.0, min(1.0, initialBrightness + delta))
            return ("sun.max.fill", "\(Int(val * 100))%")
        case .volume:
             let delta = Float(-dragOffset.height / screenHeight)
             let val = max(0.0, min(1.0, initialVolume + delta))
             
             let icon: String
             if val == 0 { icon = "speaker.slash.fill" }
             else if val < 0.3 { icon = "speaker.wave.1.fill" }
             else if val < 0.6 { icon = "speaker.wave.2.fill" }
             else { icon = "speaker.wave.3.fill" }
             return (icon, "\(Int(val * 100))%")
        case .seek:
             return seekFeedbackInfo(diff: diff, showsFineScrubbing: true)
        default: return ("", "")
        }
    }

    private func seekFeedbackInfo(diff: Double, showsFineScrubbing: Bool) -> (String, String) {
        let roundedSeconds = Int(diff.rounded())
        let absSeconds = abs(roundedSeconds)
        let icon = roundedSeconds >= 0 ? "forward.fill" : "backward.fill"

        let baseText: String
        if absSeconds >= 60 {
            let minutes = absSeconds / 60
            let seconds = absSeconds % 60
            let sign = roundedSeconds == 0 ? "" : (roundedSeconds > 0 ? "+" : "-")
            baseText = "\(sign)\(minutes):\(String(format: "%02d", seconds))"
        } else {
            let sign = roundedSeconds == 0 ? "" : (roundedSeconds > 0 ? "+" : "-")
            baseText = "\(sign)\(absSeconds)s"
        }

        guard showsFineScrubbing else {
            return (icon, baseText)
        }

        let yOffset = abs(dragOffset.height)
        guard yOffset >= 50 else {
            return (icon, baseText)
        }

        let speed = yOffset < 150 ? "0.5x" : (yOffset < 250 ? "0.25x" : "0.1x")
        return (icon, "\(baseText) (\(NSLocalizedString("Fine", comment: "")) \(speed))")
    }

    private func formattedPlaybackRateText(_ rate: Float) -> String {
        "\(String(format: "%g", rate))x"
    }

    private func performRemoteRestartSeekIfNeeded(to targetTime: Double) -> Bool {
        let playlistIndex = currentPlaylistIndex
        guard let playlist = loadedPlaylist,
              playlistIndex >= 0,
              playlistIndex < playlist.count else {
            return false
        }

        let currentFile = playlist[playlistIndex]
        guard currentFile.isRemote,
              currentFile.serverType == ServerConfig.ServerType.emby,
              currentFile.remotePlaybackMethod == RemotePlaybackMethod.transcode else {
            return false
        }

        let resolvedDuration = currentFile.duration ?? playbackService.maxDuration
        let clampedTargetTime = resolvedDuration > 0
            ? max(0, min(targetTime, resolvedDuration))
            : max(0, targetTime)
        let wasPaused = playbackService.state.status == .paused

        Task {
            guard let preparedFile = await prepareRemotePlaybackFile(
                from: currentFile,
                startPosition: clampedTargetTime,
                playbackQualityOverride: resolvedPlaybackQualityOption(for: effectivePlaybackQualityID(for: currentFile))
            ) else {
                return
            }

            await MainActor.run {
                if playlistIndex < (self.loadedPlaylist?.count ?? 0) {
                    self.loadedPlaylist?[playlistIndex] = preparedFile
                }
                playResolvedVideoFile(preparedFile, startFromBeginning: false)
                Task { await refreshPlaybackQualityOptions(for: preparedFile) }
            }

            if wasPaused {
                await MainActor.run {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        if playbackService.state.status == .playing || playbackService.state.status == .buffering {
                            playbackService.togglePlayPause()
                        }
                    }
                }
            }
        }

        return true
    }

    private func seekWithoutPreview(to targetTime: Double) {
        playbackService.isScrubbing = false
        clearSeekPreview()
        if !performRemoteRestartSeekIfNeeded(to: targetTime) {
            playbackService.seek(to: targetTime)
        }
    }
    
    private func seekBackwardByConfiguredStep() {
        let duration = AppSettings.shared.doubleTapSeekDuration
        playbackService.isScrubbing = false
        clearSeekPreview()
        playbackService.seek(by: -duration)
        showFeedback(icon: "gobackward.\(Int(duration))", text: "")
    }

    private func seekForwardByConfiguredStep() {
        let duration = AppSettings.shared.doubleTapSeekDuration
        playbackService.isScrubbing = false
        clearSeekPreview()
        playbackService.seek(by: duration)
        showFeedback(icon: "goforward.\(Int(duration))", text: "")
    }

    private func cycleVideoPlayMode() {
        guard hasMultiplePlaylistItems else { return }

        let allModes = PlaybackSequenceMode.allCases
        let currentIndex = allModes.firstIndex(of: videoPlayMode) ?? 0
        let nextIndex = (currentIndex + 1) % allModes.count
        videoPlayMode = allModes[nextIndex]
        videoPlaybackHistory.removeAll()
        syncRemoteSkipAvailability(force: true)
        showFeedback(icon: videoPlayMode.icon, text: videoPlayMode.title)
    }

    private func replayCurrentItemFromBeginning() {
        guard canReplayCurrentItem else { return }

        isAutoAdvancingAfterEnd = false
        if currentPlaylistIndex >= 0 {
            playItem(at: currentPlaylistIndex, navigationOrigin: .replay, startFromBeginning: true)
        } else {
            if var replayItem = currentMediaItem {
                replayItem.startPosition = 0
                replayItem.savedAudioTrackIndex = playbackService.isUsingMPV || playbackService.state.currentAudioTrackID == -1
                    ? nil
                    : playbackService.state.currentAudioTrackID
                replayItem.savedSubtitleTrackIndex = playbackService.isUsingMPV ? nil : playbackService.state.currentSubtitleTrackID
                currentMediaItem = replayItem
            }
            _ = playbackService.restartCurrentItemFromBeginning()
            syncRemoteSkipAvailability(force: true)
        }

        showFeedback(icon: "arrow.counterclockwise", text: NSLocalizedString("Replay from Start", comment: ""))
    }

    // MARK: - Playlist Logic

    private var hasMultiplePlaylistItems: Bool {
        guard let playlist = loadedPlaylist else { return false }
        return playlist.count > 1
    }

    private var canReplayCurrentItem: Bool {
        currentMediaItem != nil
    }
    
    private var currentPlaylistIndex: Int {
        guard let playlist = loadedPlaylist, let item = currentMediaItem else { return -1 }
        return playlist.firstIndex(where: { playlistItemMatches($0, mediaItem: item) }) ?? -1
    }
    
    private var canPlayPrevious: Bool {
        if videoPlayMode == .shuffle, !videoPlaybackHistory.isEmpty {
            return true
        }
        return currentPlaylistIndex > 0
    }
    
    private var canPlayNext: Bool {
        nextPlaylistIndex() != nil
    }
    
    private func playPrevious() {
        guard loadedPlaylist != nil else { return }
        isAutoAdvancingAfterEnd = false

        if videoPlayMode == .shuffle, let previousIndex = popPlaybackHistoryIndex() {
            playItem(at: previousIndex, navigationOrigin: .historyBack)
            return
        }

        guard currentPlaylistIndex > 0 else { return }
        playItem(at: currentPlaylistIndex - 1, navigationOrigin: .userInitiated)
    }
    
    private func playNext(autoTriggered: Bool = false) {
        guard loadedPlaylist != nil, let nextIndex = nextPlaylistIndex() else { return }
        if autoTriggered {
            isAutoAdvancingAfterEnd = true
        } else {
            isAutoAdvancingAfterEnd = false
        }
        let shouldRestartFromBeginning = nextIndex == currentPlaylistIndex
        print("[PlayerView] playNext: Current Index \(currentPlaylistIndex) -> Next \(nextIndex)")
        playItem(
            at: nextIndex,
            navigationOrigin: autoTriggered ? .autoAdvance : .userInitiated,
            startFromBeginning: shouldRestartFromBeginning
        )
    }
    
    private func playItem(
        at index: Int,
        navigationOrigin: PlaylistNavigationOrigin = .userInitiated,
        startFromBeginning: Bool = false
    ) {
        guard let playlist = loadedPlaylist, index >= 0, index < playlist.count else { return }
        recordPlaybackHistoryIfNeeded(for: navigationOrigin, targetIndex: index)

        let videoFile = playlist[index]
        let attemptID = playbackService.playbackAttemptID
        if videoFile.isRemote,
           (videoFile.serverType?.requiresDynamicPlaybackURL == true),
           videoFile.url.isFileURL {
            Task {
                do {
                    let preparedFile = try await AppNetworkService.shared.resolvedPlaybackFile(videoFile)
                    await MainActor.run {
                        guard playbackService.playbackAttemptID == attemptID else { return }
                        if index < (self.loadedPlaylist?.count ?? 0) {
                            self.loadedPlaylist?[index] = preparedFile
                        }
                        playResolvedVideoFile(preparedFile, startFromBeginning: startFromBeginning)
                    }
                } catch {
                    await MainActor.run {
                        guard playbackService.playbackAttemptID == attemptID else { return }
                        playbackService.activePlaybackFailure = VLCPlaybackService.PlaybackFailure(
                            itemID: currentMediaItem?.id ?? UUID(),
                            message: error.localizedDescription
                        )
                    }
                }
            }
            return
        }

        if shouldResolveRemotePlaybackForCurrentSession(videoFile) {
            Task {
                let startPosition = (startFromBeginning || videoFile.shouldResetRemotePlayedStateOnPlaybackStart) ? 0 : videoFile.lastPlayedPosition
                guard let preparedFile = await prepareRemotePlaybackFile(
                    from: videoFile,
                    startPosition: startPosition
                ) else {
                    await MainActor.run {
                        guard playbackService.playbackAttemptID == attemptID else { return }
                        playbackService.activePlaybackFailure = VLCPlaybackService.PlaybackFailure(
                            itemID: currentMediaItem?.id ?? UUID(),
                            message: NSLocalizedString("Playback failed. Please check the server and network connection, then try again.", comment: "")
                        )
                    }
                    return
                }

                await MainActor.run {
                    guard playbackService.playbackAttemptID == attemptID else { return }
                    if index < (self.loadedPlaylist?.count ?? 0) {
                        self.loadedPlaylist?[index] = preparedFile
                    }
                    playResolvedVideoFile(preparedFile, startFromBeginning: startFromBeginning)
                    Task { await refreshPlaybackQualityOptions(for: preparedFile) }
                }
            }
            return
        }

        playResolvedVideoFile(videoFile, startFromBeginning: startFromBeginning)
    }

    private func playResolvedVideoFile(_ videoFile: VideoFile, startFromBeginning: Bool) {
        let url = videoFile.url
        let title = videoFile.name // Use name from VideoFile
        let preservesCurrentSelections = !playbackService.isUsingMPV && (currentMediaItem.map { playlistItemMatches(videoFile, mediaItem: $0) } ?? false)
        let savedAudioTrackIndex = preservesCurrentSelections
            ? (playbackService.state.currentAudioTrackID == -1 ? nil : playbackService.state.currentAudioTrackID)
            : videoFile.lastAudioTrack
        let savedSubtitleTrackIndex = preservesCurrentSelections
            ? playbackService.state.currentSubtitleTrackID
            : videoFile.lastSubtitleTrack
        
        // Create new item
        var item = MediaItem(
            url: url, 
            title: title, 
            artist: nil,
            album: nil,
            artwork: nil,
            isRemote: videoFile.isRemote,
            jellyfinItemId: videoFile.jellyfinItemId,
            jellyfinServerId: videoFile.jellyfinServerId,
            serverType: videoFile.serverType,
            seriesId: videoFile.seriesId,
            seasonId: videoFile.seasonId,
            startPosition: (startFromBeginning || videoFile.shouldResetRemotePlayedStateOnPlaybackStart) ? 0 : videoFile.lastPlayedPosition,
            savedAudioTrackIndex: savedAudioTrackIndex,
            savedSubtitleTrackIndex: savedSubtitleTrackIndex
        )
        // Carry over server metadata for MediaInfo display
        item.serverMediaStreams = videoFile.serverMediaStreams
        item.serverContainer = videoFile.serverContainer
        item.serverSize = videoFile.serverSize
        item.serverBitrate = videoFile.serverBitrate
        item.serverPath = videoFile.serverPath
        item.remotePlaybackMethod = videoFile.remotePlaybackMethod
        item.shouldResetRemotePlayedStateOnPlaybackStart = videoFile.shouldResetRemotePlayedStateOnPlaybackStart
        item.videoFile = videoFile
        item.mediaSourceId = mediaSourceID(from: videoFile.url)
        item.playSessionId = playSessionID(from: videoFile.url)
        item.externalSubtitleCandidates = videoFile.externalSubtitleCandidates
        item.preferredAudioTrackQuery = videoFile.preferredAudioTrackQuery
        item.preferredSubtitleTrackQuery = videoFile.preferredSubtitleTrackQuery
        item.preferredAudioTrackOrdinal = videoFile.preferredAudioTrackOrdinal
        item.preferredSubtitleTrackOrdinal = videoFile.preferredSubtitleTrackOrdinal
        item.preferredPlaybackQualityID = videoFile.preferredPlaybackQualityID
        item.availablePlaybackQualityOptions = videoFile.availablePlaybackQualityOptions
        if videoFile.disableSubtitlesOnStart {
            item.savedSubtitleTrackIndex = -1
        }
        item.externalSubtitleURL = prepareExternalSubtitles(for: videoFile)
        
        // Update state and play
        currentMediaItem = item
        if shouldResolveRemotePlaybackForCurrentSession(videoFile) {
            sessionPlaybackQualityID = AppSettings.shared.resolvedRemotePlaybackQualityID(
                for: videoFile.preferredPlaybackQualityID ?? sessionPlaybackQualityID
            )
            playbackQualityOptions = AppSettings.shared.visibleRemotePlaybackQualityOptions(from: videoFile.availablePlaybackQualityOptions)
        } else {
            sessionPlaybackQualityID = nil
            playbackQualityOptions = []
        }
        playbackService.play(item: item)
        loadRemoteExternalSubtitlesIfNeeded(for: videoFile)
        hydrateDownloadedLibraryMetadataIfNeeded(for: videoFile)
        syncRemoteSkipAvailability(force: true)
        Task { await refreshPlaybackQualityOptions(for: videoFile) }
    }

    private func normalizeVideoPlayModeIfNeeded() {
        if !hasMultiplePlaylistItems {
            videoPlayMode = .sequential
        }
    }

    private func nextPlaylistIndex() -> Int? {
        guard let playlist = loadedPlaylist, !playlist.isEmpty else { return nil }
        let currentIndex = currentPlaylistIndex
        guard currentIndex >= 0 else { return nil }

        switch videoPlayMode {
        case .sequential:
            let nextIndex = currentIndex + 1
            return nextIndex < playlist.count ? nextIndex : nil
        case .shuffle:
            guard playlist.count > 1 else { return nil }
            let candidates = playlist.indices.filter { $0 != currentIndex }
            return candidates.randomElement()
        case .repeatOne:
            return currentIndex
        }
    }

    private func recordPlaybackHistoryIfNeeded(for origin: PlaylistNavigationOrigin, targetIndex: Int) {
        guard origin != .historyBack, origin != .replay else { return }

        let currentIndex = currentPlaylistIndex
        guard currentIndex >= 0, currentIndex != targetIndex else { return }
        guard let playlist = loadedPlaylist, targetIndex < playlist.count else { return }

        if videoPlaybackHistory.last != currentIndex {
            videoPlaybackHistory.append(currentIndex)
        }
    }

    private func popPlaybackHistoryIndex() -> Int? {
        guard let playlist = loadedPlaylist else { return nil }

        while let previousIndex = videoPlaybackHistory.popLast() {
            if previousIndex >= 0, previousIndex < playlist.count, previousIndex != currentPlaylistIndex {
                return previousIndex
            }
        }

        return nil
    }

    private func retryPlaybackAfterFailure() {
        playbackService.prepareForPlaybackRetry()
        if currentPlaylistIndex >= 0 {
            playItem(at: currentPlaylistIndex)
        } else if let item = currentMediaItem {
            playbackService.play(item: item)
        } else {
            playResolvedVideoFile(refreshedInitialPlaybackFile(initialFile), startFromBeginning: false)
        }
    }

    private func closePlayerAfterFailure() {
        playbackService.clearPlaybackFailure()
        playbackService.stop()
        presentationMode.wrappedValue.dismiss()
    }

    private func anchoredCurrentFile(current: VideoFile, fallback: VideoFile) -> VideoFile {
        var anchored = current
        if anchored.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            anchored.serverPath = fallback.serverPath
        }
        if anchored.serverType == nil {
            anchored.serverType = fallback.serverType
        }
        if anchored.jellyfinServerId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            anchored.jellyfinServerId = fallback.jellyfinServerId
        }
        return anchored
    }

    private func playlistItemMatches(_ file: VideoFile, mediaItem: MediaItem) -> Bool {
        if playlistURLsMatch(file.url, mediaItem.url) {
            return true
        }

        if let itemId = mediaItem.jellyfinItemId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !itemId.isEmpty,
           file.jellyfinItemId?.trimmingCharacters(in: .whitespacesAndNewlines) == itemId {
            return true
        }

        guard let lhs = normalizedPlaylistRemotePath(file.serverPath),
              let rhs = normalizedPlaylistRemotePath(mediaItem.serverPath) else {
            return false
        }
        return lhs == rhs
    }

    private func playlistItemsMatch(_ lhs: VideoFile, _ rhs: VideoFile) -> Bool {
        if playlistURLsMatch(lhs.url, rhs.url) {
            return true
        }

        if let lhsId = lhs.jellyfinItemId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !lhsId.isEmpty,
           let rhsId = rhs.jellyfinItemId?.trimmingCharacters(in: .whitespacesAndNewlines),
           lhsId == rhsId {
            return true
        }

        guard let lhsPath = normalizedPlaylistRemotePath(lhs.serverPath),
              let rhsPath = normalizedPlaylistRemotePath(rhs.serverPath) else {
            return false
        }
        return lhsPath == rhsPath
    }

    private func normalizedPlaylistRemotePath(_ rawPath: String?) -> String? {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawPath.isEmpty else {
            return nil
        }
        return normalizedPlaylistRemotePath(rawPath)
    }

    private func normalizedPlaylistRemotePath(_ rawPath: String) -> String {
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }

        var normalized = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        normalized = normalized.replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }

    private func playlistURLsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs == rhs {
            return true
        }

        if lhs.isFileURL || rhs.isFileURL {
            return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
        }

        let lhsScheme = lhs.scheme?.lowercased() ?? ""
        let rhsScheme = rhs.scheme?.lowercased() ?? ""
        guard lhsScheme == rhsScheme else {
            return false
        }

        return normalizedPlaylistRemotePath(lhs.path) == normalizedPlaylistRemotePath(rhs.path)
    }
}


private struct IOSPlayerSubtitleBrowser: View {
    @ObservedObject var playbackService: VLCPlaybackService

    var body: some View {
        if #available(iOS 16.0, *) {
            browser.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        } else {
            browser
        }
    }

    private var browser: some View {
        let session = playbackService.playbackAttemptID
        return SubtitleBrowserView(sources: playbackService.subtitleBrowserSources,
            currentTime: playbackService.state.currentTime,
            canSeek: playbackService.isSeekable || playbackService.onRequestSeekToTime != nil,
            onSeek: { time in
                guard playbackService.playbackAttemptID == session else { return }
                playbackService.seek(to: time)
            }, onClose: { playbackService.showSubtitleBrowser = false })
            .id(session)
    }
}
