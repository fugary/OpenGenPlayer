#if os(macOS)
import SwiftUI
import GenPlayerCore
import VLCKitSPM
import UniformTypeIdentifiers
import AVFoundation

public struct MacPlayerSheet: View {
    @StateObject private var playbackService = MacVLCPlaybackService()
    @AppStorage("enableMacPiPBeta") private var enableMacPiPBeta: Bool = true
    @State private var isInteractingWithPopover = false
    @State private var hoverPosition: Double? = nil
    @State private var isHoveringControls = false
    @StateObject private var previewGenerator = MacSeekPreviewThumbnailGenerator()
    @State private var playbackSwitchID = UUID()
    @State private var currentFile: VideoFile
    private let initialThumbnailURL: URL?
    private let initialThumbnailFileURL: URL
    private var thumbnailURL: URL? {
        // The caller's thumbnail belongs only to the item that opened this window.
        currentFile.url == initialThumbnailFileURL ? initialThumbnailURL : currentFile.customArtworkURL
    }
    private let onDismiss: () -> Void
    
    private var playbackServer: ServerConfig? {
        if let uuidString = currentFile.jellyfinServerId, let uuid = UUID(uuidString: uuidString) {
            return AppNetworkService.shared.servers.first { $0.id == uuid }
        }
        return AppNetworkService.shared.servers.first { $0.type == currentFile.serverType }
    }

    private var currentLiveProgramme: EPGProgramme? {
        guard let serverIdStr = currentFile.jellyfinServerId,
              let serverId = UUID(uuidString: serverIdStr) else {
            return nil
        }
        let dummy = IPTVChannel(
            id: currentFile.jellyfinItemId ?? "",
            name: currentFile.name,
            url: currentFile.url
        )
        return EPGService.shared.currentProgramme(for: dummy, in: serverId)
    }

    @State private var showControls: Bool = true
    @State private var showSubtitlePopover = false
    @State private var showAudioPopover = false
    @State private var showAspectRatioPopover = false
    @State private var showSpeedPopover = false
    @State private var showDisplayModePopover = false
    @State private var controlsTimer: Timer?
    @State private var activeRightSidebarTab: RightSidebarTab? = nil
    @ObservedObject private var epgService = EPGService.shared
    
    public enum RightSidebarTab: String, CaseIterable, Identifiable {
        case video = "Video"
        case audio = "Audio"
        case subtitle = "Subtitle"
        case info = "Info"
        case playlist = "Playlist"
        case sources = "Sources"
        case subtitleBrowser = "SB.Title"
        case epg = "Program Guide"
        public var id: String { self.rawValue }
    }
    @AppStorage("doubleTapSeekDuration") private var doubleTapSeekDuration: Double = 15.0
    @State private var volume: Double = 1.0
    @State private var brightness: Double = 1.0
    @State private var isSeeking = false
    @State private var lastSeekDate: Date = .distantPast
    @State private var pendingPosition: Double = 0
    @State private var toastIcon: String? = nil
    @State private var toastText: String? = nil
    @State private var toastOpacity: Double = 0.0
    @State private var toastHideWorkItem: DispatchWorkItem?
    @State private var mouseEventMonitor: Any?
    @State private var isFastForwarding: Bool = false
    @State private var fastForwardTimer: Timer?
    
    @State private var isHoveredPlay: Bool = false
    
    @State private var showsVolumePopover = false

    
    // Playlist support
    @State private var currentPlaylist: [VideoFile]?
    @State private var isHoveredPrev = false
    @State private var isHoveredNext = false
    @State private var isHoveredMode = false
    @State private var videoPlayMode: MacPlaybackSequenceMode = .sequential
    @AppStorage("defaultVideoScaleMode") private var videoScaleMode: String = "Fit"
    @AppStorage("defaultVideoAspectRatio") private var videoAspectRatio: String = "Default"
    @State private var videoPlaybackHistory: [Int] = []
    
    @AppStorage("enableSecondarySubtitlesBeta") private var enableSecondarySubtitlesBeta: Bool = false
    @AppStorage("secondarySubtitleSizeScale") private var secondarySubtitleSizeScale: Double = 1.0
    @AppStorage("secondarySubtitleVerticalPositionRatio.landscape") private var secondarySubtitlePositionRatio: Double = -1.0
    @State private var isSecondarySubtitlePositionAdjustmentActive: Bool = false
    @State private var secondarySubtitleDragInitialRatio: CGFloat?
    @State private var secondarySubtitleAdjustmentHideWorkItem: DispatchWorkItem?
    @State private var isHoveringSubtitle: Bool = false
    @State private var translationStatusKey = "Translation.SelectPrimary"

    private var secondaryTranslationFeedback: MacSubtitleTranslationFeedback? {
        guard playbackService.currentSecondarySubtitleTrackID == MacSubtitleTranslation.trackID else { return nil }
        return playbackService.subtitleTranslation.overlayFeedback(status: translationStatusKey)
    }
    
    @ObservedObject private var windowManager = MacPlayerWindowManager.shared
    @State private var isPinnedToTop: Bool = false
    @State private var isFullScreen: Bool = false
    @State private var isDropTargeted: Bool = false
    @State private var isShowingLiveTextViewer: Bool = false
    @State private var liveTextTargetImage: NSImage? = nil

    private func handleLiveTextExtraction() {
        guard LiveTextCapability.isSupported else { return }
        if playbackService.isPlaying {
            playbackService.pause()
        }
        let requestID = playbackSwitchID
        playbackService.captureLiveTextFrame { image in
            guard requestID == playbackSwitchID else { return }
            guard let image else {
                showToast(icon: "exclamationmark.triangle", text: platformShellString("FrameCapture.Failed"))
                return
            }
            liveTextTargetImage = image
            withAnimation(.easeInOut(duration: 0.18)) {
                isShowingLiveTextViewer = true
            }
        }
    }

    private var currentPlayerWindow: NSWindow? {
        MacPlayerWindowManager.shared.activeWindows[currentFile.id]?.window
            ?? MacPlayerWindowManager.shared.currentPlayerWindowController?.window
    }

    private func toggleFullScreen() {
        guard let window = currentPlayerWindow else { return }
        window.toggleFullScreen(nil)
        let willBeFullscreen = !window.styleMask.contains(.fullScreen)
        isFullScreen = willBeFullscreen
        showToast(
            icon: willBeFullscreen ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
            text: willBeFullscreen ? platformShellString("Full Screen") : platformShellString("Exit Full Screen")
        )
    }

    private func playerContentHorizontalPadding(width: CGFloat) -> CGFloat {
        if width < 360 {
            return 12
        } else if width < 500 {
            return 16
        } else {
            return 24
        }
    }

    public init(initialFile: VideoFile, playlist: [VideoFile]? = nil, thumbnailURL: URL? = nil, onDismiss: @escaping () -> Void) {
        self._currentFile = State(initialValue: initialFile)
        self._currentPlaylist = State(initialValue: playlist)
        self.initialThumbnailURL = thumbnailURL
        self.initialThumbnailFileURL = initialFile.url
        self.onDismiss = onDismiss
    }

    private var isDownloaded: Bool {
        if currentFile.url.isFileURL,
           DownloadCenterService.shared.isTrackedLocalDownload(currentFile.url) {
            return true
        }
        guard currentFile.isRemote else { return false }
        return DownloadCenterService.shared.isDownloaded(file: currentFile)
    }

    public var body: some View {
        GeometryReader { outerGeo in
            let isMiniPlayer = currentFile.type == .audio && (windowManager.isMiniPlayer(for: currentFile.id) || outerGeo.size.height <= 120)
            
            if isMiniPlayer {
                miniAudioPlayerStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            } else {
                playerStage
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .trailing) {
                        if let activeTab = activeRightSidebarTab {
                            HStack(spacing: 0) {
                                Divider()
                                    .background(Color.white.opacity(0.1))
                                    .frame(width: 1)
                                
                                Group {
                                    if activeTab == .subtitleBrowser {
                                        MacPlayerSubtitleBrowser(playbackService: playbackService,
                                            onClose: { withAnimation(.easeInOut(duration: 0.18)) { activeRightSidebarTab = nil } })
                                            .frame(width: min(360, max(0, outerGeo.size.width - 1)))
                                    } else if activeTab == .sources {
                                        vodSourceSidebar.frame(width: 320)
                                    } else if activeTab == .epg {
                                        let effectivePlaylist = currentPlaylist.flatMap { $0.isEmpty ? nil : $0 } ?? [currentFile]
                                        MacPlayerEPGSidebar(
                                            currentFile: $currentFile,
                                            playlist: effectivePlaylist,
                                            server: playbackServer,
                                            playbackService: playbackService,
                                            onSelect: switchPlayback(to:),
                                            onClose: { withAnimation(.easeInOut(duration: 0.18)) { activeRightSidebarTab = nil } }
                                        )
                                        .frame(width: 330)
                                    } else if activeTab == .playlist {
                                        let effectivePlaylist = currentPlaylist.flatMap { $0.isEmpty ? nil : $0 } ?? [currentFile]
                                        MacPlaylistSidebar(
                                            currentFile: $currentFile,
                                            playlist: effectivePlaylist,
                                            server: playbackServer,
                                            playbackService: playbackService,
                                            onSelect: switchPlayback(to:),
                                            onClose: { withAnimation(.easeInOut(duration: 0.18)) { activeRightSidebarTab = nil } }
                                        )
                                        .frame(width: 320)
                                    } else {
                                        MacPlayerRightSidebar(
                                            activeTab: Binding(
                                                get: { activeTab },
                                                set: { activeRightSidebarTab = $0 }
                                            ),
                                            file: currentFile,
                                            playbackService: playbackService,
                                            videoAspectRatio: $videoAspectRatio,
                                            thumbnailURL: thumbnailURL,
                                            currentPlaylist: currentPlaylist,
                                            playbackServer: playbackServer,
                                            onSwitchPlayback: switchPlayback(to:),
                                            onAction: { showToast(icon: $0, text: $1) },
                                            onClose: { withAnimation(.easeInOut(duration: 0.18)) { activeRightSidebarTab = nil } }
                                        )
                                        .frame(width: 320)
                                    }
                                }
                            }
                            .transition(.move(edge: .trailing))
                        }
                    }
                    .background(Color.black)
            }
        }
        .background(
            MacPlaybackFailureAlertPresenter(
                failureID: playbackService.playbackFailureID,
                message: playbackService.playbackErrorMessage,
                isCurrentFailure: { playbackService.playbackFailureID == $0 },
                onRetry: { playbackService.reloadCurrentItemPreservingPlaybackState() },
                onClose: onDismiss,
                onSwitchSource: currentFile.serverType == .vod ? { activeRightSidebarTab = .sources; revealControls() } : nil,
                onUseVLC: playbackService.canRecoverMPVWithVLC ? { playbackService.switchPlaybackEngine(to: .vlc) } : nil
            )
            .frame(width: 0, height: 0)
        )
        .overlay {
            if isDropTargeted {
                ZStack {
                    Color.black.opacity(0.65)
                    VStack(spacing: 14) {
                        Image(systemName: "arrow.down.doc.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.blue)
                        Text(platformShellString("Drop media to play"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.white)
                    }
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url = url else { return }
                    DispatchQueue.main.async {
                        self.handleDroppedFileURL(url)
                    }
                }
            }
            return true
        }
        .ignoresSafeArea()
        .background(MacSubtitleTranslationHost(model: playbackService.subtitleTranslation))
        .sheet(isPresented: $playbackService.showAudioSubtitleSheet) {
            MacAudioSubtitleControls(model: playbackService.audioSubtitles, translation: playbackService.subtitleTranslation)
        }
        .onReceive(playbackService.subtitleTranslation.$statusKey.removeDuplicates()) { status in
            translationStatusKey = status
        }
        .onChange(of: enableSecondarySubtitlesBeta) { enabled in
            if !enabled && (playbackService.isUsingMPV || playbackService.subtitleTranslation.enabled || playbackService.currentSecondarySubtitleTrackID == MacAudioSubtitlePlan.secondaryID) {
                playbackService.setSecondarySubtitleTrack(nil)
            }
        }
        .onAppear {
            loadPlaylistIfNeeded()
            MacPlayerWindowManager.shared.currentPlaybackService = playbackService
            MacPlayerWindowManager.shared.activePlaybackServices[currentFile.id] = playbackService
            if !playbackService.isUsingMPV || playbackService.mpvEngine == nil || playbackService.currentFile?.id != currentFile.id {
                playbackService.play(file: currentFile)
            }
            volume = Double(playbackService.volume) / 100.0

            let rateKey = currentFile.type == .audio ? "defaultAudioPlaybackSpeed" : "defaultPlaybackSpeed"
            let savedRate = UserDefaults.standard.float(forKey: rateKey)
            if savedRate > 0.1 {
                playbackService.setPlaybackRate(savedRate)
            }

            let savedAlwaysOnTop = UserDefaults.standard.bool(forKey: "macPlayerAlwaysOnTop")
            if savedAlwaysOnTop {
                if let window = MacPlayerWindowManager.shared.activeWindows[currentFile.id]?.window {
                    window.level = .floating
                }
                isPinnedToTop = true
            } else {
                isPinnedToTop = MacPlayerWindowManager.shared.isPinnedToTop(for: currentFile.id)
            }

            playbackService.onDidStartPiP = {
                onDismiss()
            }
            
            if let window = currentPlayerWindow {
                isFullScreen = window.styleMask.contains(.fullScreen)
            }
            
            startControlsTimer()
            MacPlayerWindowManager.shared.setWindowTitleBarButtonsHidden(!showControls, for: currentFile.id)
        }
        .onDisappear {
            playbackSwitchID = UUID()
            if !(playbackService.isUsingMPV && playbackService.isVideoPiPActive) {
                if MacPlayerWindowManager.shared.currentPlaybackService === playbackService {
                    MacPlayerWindowManager.shared.currentPlaybackService = nil
                }
                MacPlayerWindowManager.shared.activePlaybackServices.removeValue(forKey: currentFile.id)
            }
            controlsTimer?.invalidate()
            if !playbackService.isVideoPiPActive {
                playbackService.stop()
            }
            MacPlayerWindowManager.shared.setWindowTitleBarButtonsHidden(false, for: currentFile.id)
        }
        .onChange(of: showControls) { newValue in
            MacPlayerWindowManager.shared.setWindowTitleBarButtonsHidden(!newValue, for: currentFile.id)
        }
        .onReceive(playbackService.$videoNaturalSize) { newSize in
            if newSize.width > 1 && newSize.height > 1 {
                DispatchQueue.main.async {
                    MacPlayerWindowManager.shared.fitWindowToVideoAspectRatio(fileId: currentFile.id, videoSize: newSize)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { notif in
            if let window = notif.object as? NSWindow, window == currentPlayerWindow {
                isFullScreen = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { notif in
            if let window = notif.object as? NSWindow, window == currentPlayerWindow {
                isFullScreen = false
            }
        }
    }


    private var miniAudioPlayerStage: some View {
        ZStack {
            MacPlayerGestureView(
                onSingleTap: { },
                onDoubleTap: {
                    MacPlayerWindowManager.shared.toggleMiniPlayer(for: currentFile.id)
                },
                onLongPressStart: { },
                onLongPressEnd: { }
            )
            .ignoresSafeArea()

            HStack(spacing: 16) {
                // Left: Album Art with Progress Ring
                ZStack {
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 3)

                    Circle()
                        .trim(from: 0, to: max(CGFloat(playbackService.position), 0.001))
                        .stroke(
                            AngularGradient(
                                gradient: Gradient(colors: [Color.white.opacity(0.9), Color.white.opacity(0.4)]),
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 3, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    if let thumbnailURL = thumbnailURL {
                        MacCachedAsyncImage(url: thumbnailURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                ZStack {
                                    Color.white.opacity(0.1)
                                    Image(systemName: "music.note").font(.system(size: 24)).foregroundColor(.white.opacity(0.3))
                                }
                            }
                        }
                        .frame(width: 60, height: 60)
                        .clipShape(Circle())
                    } else {
                        MacRemoteFileImage(file: currentFile, server: playbackServer, siblingFiles: currentPlaylist)
                            .frame(width: 60, height: 60)
                            .clipShape(Circle())
                    }
                }
                .id(currentFile.url)
                .frame(width: 68, height: 68)
                .contentShape(Circle())
                .onTapGesture {
                    MacPlayerWindowManager.shared.toggleMiniPlayer(for: currentFile.id)
                }

                // Right: Info & Controls
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        if isDownloaded {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.green)
                                .font(.system(size: 12))
                                .offset(y: 2)
                        }
                        Text(currentFile.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .help(currentFile.name)
                        Spacer(minLength: 8)
                        Button {
                            MacPlayerWindowManager.shared.toggleMiniPlayer(for: currentFile.id)
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.8))
                                .frame(width: 24, height: 24)
                                .background(Color.white.opacity(0.1), in: Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)

                        Button {
                            MacPlayerWindowManager.shared.closePlayer(for: currentFile.id)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white.opacity(0.8))
                                .frame(width: 24, height: 24)
                                .background(Color.white.opacity(0.1), in: Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, -4)
                    }
                    
                    HStack(spacing: 12) {
                        Button(action: {
                            let allModes = MacPlaybackSequenceMode.allCases
                            let nextIndex = (allModes.firstIndex(of: videoPlayMode)! + 1) % allModes.count
                            videoPlayMode = allModes[nextIndex]
                        }) {
                            Image(systemName: videoPlayMode.icon)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.9))
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.1), in: Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)

                        Button(action: { playPreviousInPlaylist() }) {
                            Image(systemName: "backward.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.1), in: Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasPreviousInPlaylist)
                        .opacity(!hasPreviousInPlaylist ? 0.5 : 1.0)

                        Button(action: { playbackService.togglePlayPause() }) {
                            Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(.black)
                                .frame(width: 32, height: 32)
                                .background(Color.white.opacity(isHoveredPlay ? 0.8 : 1.0), in: Circle())
                                .scaleEffect(playbackService.isPlaying ? 0.95 : 1.0)
                                .scaleEffect(isHoveredPlay ? 1.05 : 1.0)
                                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: playbackService.isPlaying)
                        }
                        .buttonStyle(.plain)
                        .onHover { isHoveredPlay = $0 }

                        Button(action: { playNextInPlaylist() }) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                                .frame(width: 28, height: 28)
                                .background(Color.white.opacity(0.1), in: Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasNextInPlaylist)
                        .opacity(!hasNextInPlaylist ? 0.5 : 1.0)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.1).ignoresSafeArea())
    }

    private var playerStage: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if currentFile.type == .audio {
                ZStack {
                    if let thumbnailURL = thumbnailURL {
                        MacCachedAsyncImage(url: thumbnailURL) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                            case .success(let image):
                                ZStack {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                                        .blur(radius: 60)
                                        .opacity(0.6)
                                        .clipped()
                                    
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: 360, maxHeight: 360)
                                        .cornerRadius(16)
                                        .shadow(color: Color.black.opacity(0.5), radius: 40, y: 20)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 16)
                                                .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                        )
                                }
                            case .failure:
                                Image(systemName: "music.note")
                                    .font(.system(size: 100))
                                    .foregroundColor(.white.opacity(0.3))
                            }
                        }
                    } else {
                        ZStack {
                            MacRemoteFileImage(file: currentFile, server: playbackServer, siblingFiles: currentPlaylist, contentMode: .fill)
                                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                                .blur(radius: 60)
                                .opacity(0.6)
                                .clipped()
                            
                            MacRemoteFileImage(file: currentFile, server: playbackServer, siblingFiles: currentPlaylist, contentMode: .fit)
                                .frame(maxWidth: 360, maxHeight: 360)
                                .cornerRadius(16)
                                .shadow(color: Color.black.opacity(0.5), radius: 40, y: 20)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                                )
                        }
                    }
                }
                .id(currentFile.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
            }
            
            if currentFile.type == .audio {
                MacVLCVideoView(playbackService: playbackService, fillScreen: false)
                    .frame(width: 1, height: 1)
                    .opacity(0.01)
                    .allowsHitTesting(false)
            } else {
                MacVLCVideoView(playbackService: playbackService, fillScreen: videoScaleMode == "Fill")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
            }
            
            if brightness < 1.0 {
                Color.black.opacity(1.0 - brightness)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }

            if playbackService.isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(platformShellString("Loading..."))
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
                .zIndex(140)
            }
            
            MacPlayerGestureView(
                onSingleTap: {
                    if activeRightSidebarTab != nil {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            activeRightSidebarTab = nil
                        }
                    } else if showsVolumePopover || showAudioPopover || showSubtitlePopover || showSpeedPopover || showDisplayModePopover {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showsVolumePopover = false
                            showAudioPopover = false
                            showSubtitlePopover = false
                            showSpeedPopover = false
                            showDisplayModePopover = false
                        }
                    } else {
                        withAnimation {
                            showControls.toggle()
                        }
                    }
                    if showControls {
                        revealControls()
                        startControlsTimer()
                    }
                },
                onDoubleTap: {
                    if currentFile.type == .audio {
                        MacPlayerWindowManager.shared.toggleMiniPlayer(for: currentFile.id)
                    } else {
                        toggleFullScreen()
                    }
                },
                onLongPressStart: {
                    if currentFile.type != .audio {
                        isFastForwarding = true
                        playbackService.setPlaybackRate(2.0)
                        showToast(icon: "forward.fill", text: "2.0x")
                    }
                },
                onLongPressEnd: {
                    if currentFile.type != .audio {
                        isFastForwarding = false
                        playbackService.setPlaybackRate(playbackService.targetRate)
                        showToast(icon: "play.fill", text: "\(playbackService.targetRate)x")
                    }
                }
            )
            .ignoresSafeArea()

            if !playbackService.generatedPrimaryText.isEmpty {
                VStack {
                    Spacer()
                    VStack(spacing: 3) {
                        ForEach(playbackService.generatedPrimaryParts) { part in
                            generatedPrimaryPart(part)
                        }
                    }
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .shadow(color: .black, radius: 2)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                }
                .allowsHitTesting(false)
            }

            // Secondary Subtitles
            if (!playbackService.isUsingMPV || playbackService.usesMPVTextSecondary || playbackService.usesMPVNativeASSSecondary) && enableSecondarySubtitlesBeta && (playbackService.currentSecondarySubtitleTrackID != nil || !playbackService.currentSecondarySubtitleParts.isEmpty || playbackService.secondarySubtitleStatus == .loading || secondaryTranslationFeedback != nil) {
                GeometryReader { innerGeo in
                    let boxWidth = max(220, innerGeo.size.width - 64)
                    let nativeASS = playbackService.usesMPVNativeASSSecondary
                    let nativeRect = MPVSecondarySubtitleRendering.adjustmentRect(
                        bounds: playbackService.nativeASSBounds, viewport: CGRect(origin: .zero, size: innerGeo.size),
                        fallbackCenterY: secondarySubtitleVerticalPosition(in: innerGeo.size.height))
                    let isEmpty = nativeASS ? !playbackService.nativeASSHasContent : (playbackService.currentSecondarySubtitleParts.isEmpty &&
                        playbackService.secondarySubtitleStatus != .loading && secondaryTranslationFeedback == nil
                    )
                    let showsAdjustment = isSecondarySubtitlePositionAdjustmentActive || isHoveringSubtitle
                    VStack(spacing: 2) {
                        if isEmpty {
                            Label(platformShellString("Secondary Subtitle"), systemImage: "arrow.up.and.down")
                                .font(.callout)
                                .foregroundColor(.white.opacity(0.7))
                                .opacity(showsAdjustment ? 1 : 0)
                        }
                        if let feedback = secondaryTranslationFeedback {
                            secondarySubtitleText(
                                playbackService.subtitleTranslation.statusMessage(for: feedback.statusKey),
                                containerHeight: innerGeo.size.height
                            )
                        }
                        if playbackService.secondarySubtitleStatus == .loading {
                            secondarySubtitleText(
                                platformShellString("Loading..."),
                                containerHeight: innerGeo.size.height
                            )
                        } else if !nativeASS {
                            ForEach(playbackService.currentSecondarySubtitleParts, id: \.id) { part in
                                secondarySubtitlePart(part, containerHeight: innerGeo.size.height)
                                    .id("\(part.id)-\(secondarySubtitleSizeScale)")
                            }
                        }
                    }
                    .padding(.horizontal, nativeASS ? 0 : 36)
                    .padding(.vertical, nativeASS ? 0 : (showsAdjustment ? 14 : 4))
                    .frame(width: nativeASS ? ((isEmpty || showsAdjustment) ? boxWidth : nativeRect.width) : ((isEmpty || showsAdjustment) ? boxWidth : nil),
                           height: nativeASS ? nativeRect.height : (isEmpty ? 76 : nil))
                    .id("secondary_sub_\(secondarySubtitleSizeScale)")
                    .background(
                        Group {
                            if showsAdjustment {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.black.opacity(0.28))
                                    .shadow(color: Color.black.opacity(0.22), radius: 4, x: 0, y: 1)
                            } else {
                                Color.clear
                            }
                        }
                    )
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                handleSecondarySubtitleAdjustmentGestureChanged(value, in: innerGeo.size)
                            }
                            .onEnded { value in
                                handleSecondarySubtitleAdjustmentGestureEnded(value, in: innerGeo.size)
                            }
                    )
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHoveringSubtitle = hovering
                        }
                    }
                    .position(x: nativeASS && !isEmpty && !showsAdjustment ? nativeRect.midX : innerGeo.size.width / 2,
                              y: nativeASS ? nativeRect.midY : secondarySubtitleVerticalPosition(in: innerGeo.size.height))
                }
                .onDisappear {
                    isHoveringSubtitle = false
                    isSecondarySubtitlePositionAdjustmentActive = false
                    secondarySubtitleDragInitialRatio = nil
                    secondarySubtitleAdjustmentHideWorkItem?.cancel()
                }
            }

            if showControls {
                GeometryReader { geo in
                    let isCompact = geo.size.width < 800
                    let isShort = geo.size.height < 420
                    let sideSpacing: CGFloat = isShort ? 10 : (isCompact ? 16 : 24)
                    let sideButtonSize: CGFloat = isShort ? 28 : (isCompact ? 32 : 40)
                    let sideIconSize: CGFloat = isShort ? 14 : (isCompact ? 16 : 18)

                    ZStack {
                        VStack(spacing: 0) {
                            topControls(width: geo.size.width)
                            Spacer()
                            bottomControls(width: geo.size.width)
                        }
                        
                        // Center Floating Side Controls (Left: Pin & Fullscreen, Right: Snapshot & AspectRatio)
                        if currentFile.type != .audio && geo.size.height >= 260 {
                            HStack {
                                // Left Side: Window Controls
                                VStack(spacing: sideSpacing) {
                                    Button {
                                        MacPlayerWindowManager.shared.togglePinToTop(for: currentFile.id)
                                        isPinnedToTop = MacPlayerWindowManager.shared.isPinnedToTop(for: currentFile.id)
                                        showToast(
                                            icon: isPinnedToTop ? "pin.fill" : "pin",
                                            text: isPinnedToTop ? platformShellString("Always on Top") : platformShellString("Cancel Always on Top")
                                        )
                                    } label: {
                                        Image(systemName: isPinnedToTop ? "pin.fill" : "pin")
                                            .font(.system(size: sideIconSize, weight: .medium))
                                            .foregroundColor(isPinnedToTop ? .blue : .white)
                                            .frame(width: sideButtonSize, height: sideButtonSize)
                                            .contentShape(Circle())
                                            .macHoverEffect()
                                    }
                                    .buttonStyle(.plain)
                                    .help(isPinnedToTop ? platformShellString("Cancel Always on Top") : platformShellString("Always on Top"))

                                    Button {
                                        toggleFullScreen()
                                    } label: {
                                        Image(systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                            .font(.system(size: sideIconSize, weight: .medium))
                                            .foregroundColor(.white)
                                            .frame(width: sideButtonSize, height: sideButtonSize)
                                            .contentShape(Circle())
                                            .macHoverEffect()
                                    }
                                    .buttonStyle(.plain)
                                    .help(isFullScreen ? platformShellString("Exit Full Screen") : platformShellString("Full Screen"))
                                }
                                .padding(.leading, playerContentHorizontalPadding(width: geo.size.width))

                                Spacer()

                                // Right Side: Canvas & Video Controls
                                if activeRightSidebarTab == nil {
                                    VStack(spacing: sideSpacing) {
                                        Button {
                                            let requestID = playbackSwitchID
                                            playbackService.takeSnapshot { url, destinationName in
                                                guard requestID == playbackSwitchID else { return }
                                                guard let url else {
                                                    showToast(icon: "exclamationmark.triangle", text: platformShellString("FrameCapture.Failed"))
                                                    return
                                                }
                                                let toastText = String(format: platformShellString("Saved to %@"), destinationName)
                                                showToast(icon: "camera.viewfinder", text: toastText)
                                                NSWorkspace.shared.activateFileViewerSelecting([url])
                                            }
                                        } label: {
                                            Image(systemName: "camera.viewfinder")
                                                .font(.system(size: sideIconSize, weight: .light))
                                                .foregroundColor(.white)
                                                .frame(width: sideButtonSize, height: sideButtonSize)
                                                .contentShape(Circle())
                                                .macHoverEffect()
                                        }
                                        .buttonStyle(.plain)
                                        .help(platformShellString("Screenshot"))

                                        Button {
                                            if !showDisplayModePopover {
                                                closeAllPopoversExcept(displayMode: true)
                                            }
                                            showDisplayModePopover.toggle()
                                        } label: {
                                            Image(systemName: "aspectratio")
                                                .font(.system(size: sideIconSize, weight: .light))
                                                .foregroundColor(.white)
                                        }
                                        .buttonStyle(.plain)
                                        .frame(width: sideButtonSize, height: sideButtonSize)
                                        .contentShape(Circle())
                                        .macHoverEffect()
                                        .help(platformShellString("Aspect Ratio"))
                                        .popover(isPresented: $showDisplayModePopover, arrowEdge: .trailing) {
                                            VStack(alignment: .leading, spacing: 0) {
                                                let scaleModes = ["Fit", "Fill"]
                                                let currentScale = videoScaleMode
                                                
                                                Text(platformShellString("Display Mode"))
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundColor(.secondary)
                                                    .padding(.horizontal, 12)
                                                    .padding(.top, 8)
                                                    .padding(.bottom, 4)
                                                    
                                                ForEach(scaleModes, id: \.self) { mode in
                                                    Button(action: {
                                                        videoScaleMode = mode
                                                        showDisplayModePopover = false
                                                    }) {
                                                        HStack {
                                                            Text(platformShellString(mode))
                                                            Spacer()
                                                            if currentScale == mode {
                                                                Image(systemName: "checkmark")
                                                            }
                                                        }
                                                        .padding(.horizontal, 12)
                                                        .padding(.vertical, 8)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .contentShape(Rectangle())
                                                    }
                                                    .buttonStyle(.plain)
                                                    .macMenuHoverEffect()
                                                }
                                                
                                                Divider().padding(.vertical, 4)
                                                
                                                Text(platformShellString("Aspect Ratio"))
                                                    .font(.system(size: 11, weight: .medium))
                                                    .foregroundColor(.secondary)
                                                    .padding(.horizontal, 12)
                                                    .padding(.top, 4)
                                                    .padding(.bottom, 4)
                                                    
                                                let ratios = ["Default", "16:9", "4:3", "16:10", "2.35:1", "2.39:1"]
                                                let currentRatio = videoAspectRatio
                                                ForEach(ratios, id: \.self) { ratio in
                                                    Button(action: {
                                                        videoAspectRatio = ratio
                                                        playbackService.setAspectRatio(ratio)
                                                        showDisplayModePopover = false
                                                    }) {
                                                        HStack {
                                                            Text(platformShellString(ratio))
                                                            Spacer()
                                                            if (currentRatio.isEmpty ? "Default" : currentRatio) == ratio {
                                                                Image(systemName: "checkmark")
                                                            }
                                                        }
                                                        .padding(.horizontal, 12)
                                                        .padding(.vertical, 8)
                                                        .frame(maxWidth: .infinity, alignment: .leading)
                                                        .contentShape(Rectangle())
                                                    }
                                                    .buttonStyle(.plain)
                                                    .macMenuHoverEffect()
                                                }
                                            }
                                            .padding(.vertical, 6)
                                            .frame(minWidth: 140)
                                        }
                                    }
                                    .padding(.trailing, playerContentHorizontalPadding(width: geo.size.width))
                                }
                            }
                        }
                    }
                }
                .transition(.opacity)
            }
            
            // Play/Pause & Feedback Toast Overlay
            if let icon = toastIcon {
                if let text = toastText, !text.isEmpty {
                    VStack {
                        HStack(spacing: 8) {
                            Image(systemName: icon)
                                .font(.system(size: 15, weight: .semibold))
                            Text(text)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .lineLimit(1)
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.72))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                        )
                        .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 3)
                        .padding(.top, 24)
                        
                        Spacer()
                    }
                    .opacity(toastOpacity)
                    .allowsHitTesting(false)
                    .zIndex(150)
                } else {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.55))
                            .frame(width: 80, height: 80)
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                            )
                            .shadow(color: Color.black.opacity(0.35), radius: 8, x: 0, y: 3)
                        
                        Image(systemName: icon)
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(.white)
                            .offset(x: icon == "play.fill" ? 2.5 : 0)
                    }
                    .opacity(toastOpacity)
                    .allowsHitTesting(false)
                    .zIndex(150)
                }
            }

            if isShowingLiveTextViewer, let liveTextImage = liveTextTargetImage {
                PlayerLiveTextViewer(image: liveTextImage, onDismiss: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isShowingLiveTextViewer = false
                        liveTextTargetImage = nil
                    }
                })
                .transition(.opacity)
                .zIndex(200)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onChange(of: playbackService.isPlaying) { isPlaying in
            showToast(icon: isPlaying ? "play.fill" : "pause.fill", duration: 0.4)
        }
        .onChange(of: playbackService.hasReachedEnd) { ended in
            if ended {
                if let playlist = currentPlaylist, playlist.count > 1,
                   let currentIndex = playlist.firstIndex(where: { $0.id == currentFile.id }) {
                    if videoPlayMode == .sequential && currentIndex == playlist.count - 1 {
                        // End of playlist, just stay stopped
                    } else {
                        playNextInPlaylist()
                    }
                }
            }
        }
        .onChange(of: volume) { newValue in
            showToast(icon: newValue <= 0.01 ? "speaker.slash" : "speaker.wave.2", text: "\(Int(newValue * 100))%")
        }
        .onChange(of: brightness) { newValue in
            showToast(icon: "sun.max", text: "\(Int(newValue * 100))%")
        }
        .background(
            ZStack {
                Button("") { playbackService.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("") { seek(by: -Int32(doubleTapSeekDuration * 1000)) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { seek(by: Int32(doubleTapSeekDuration * 1000)) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { 
                    volume = min(1.0, volume + 0.05)
                    playbackService.setVolume(Int32(volume * 100))
                }
                .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { 
                    volume = max(0.0, volume - 0.05)
                    playbackService.setVolume(Int32(volume * 100))
                }
                .keyboardShortcut(.downArrow, modifiers: [])
            }
            .opacity(0)
            .allowsHitTesting(false)
            .disabled(activeRightSidebarTab == .subtitleBrowser)
        )
    }

    private func topControls(width: CGFloat) -> some View {
        let isCompact = width < 700
        let buttonSize: CGFloat = width < 500 ? 28 : (isCompact ? 30 : 36)
        let iconSize: CGFloat = width < 500 ? 14 : (isCompact ? 15 : 17)
        let buttonSpacing: CGFloat = width < 500 ? 6 : (isCompact ? 8 : 10)

        return HStack(spacing: 0) {
            // Keep the status below the title, inside the existing fading chrome.
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundColor(.green)
                            .font(.system(size: 13))
                    }
                    Text(currentFile.name)
                        .font(.system(size: width < 500 ? 14 : 16, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if currentFile.type == .video, playbackService.isUsingMPV, playbackService.mpvHDRInfo.isHDR {
                    MacHDRStatusBadges(info: playbackService.mpvHDRInfo, compact: width < 700) {
                        withAnimation(.easeInOut(duration: 0.18)) { activeRightSidebarTab = .info }
                        revealControls()
                    }
                }
            }
            .layoutPriority(0)

            Spacer(minLength: 8)

            // Right Side Controls: High layout priority so all buttons remain visible
            HStack(spacing: buttonSpacing) {
                Button {
                    MacPlayerWindowManager.shared.showMainWindow()
                } label: {
                    Image(systemName: "sidebar.left")
                        .font(.system(size: iconSize, weight: .regular))
                        .foregroundColor(.white)
                        .frame(width: buttonSize, height: buttonSize)
                        .contentShape(Circle())
                        .macHoverEffect()
                }
                .buttonStyle(.plain)
                .help(platformShellString("Main Window"))

                if currentFile.type == .video, LiveTextCapability.isSupported {
                    Button {
                        handleLiveTextExtraction()
                    } label: {
                        Image(systemName: "text.viewfinder")
                            .font(.system(size: iconSize, weight: .regular))
                            .foregroundColor(.white)
                            .frame(width: buttonSize, height: buttonSize)
                            .contentShape(Circle())
                            .macHoverEffect()
                    }
                    .buttonStyle(.plain)
                    .help(platformShellString("Live Text"))
                }
                
                if currentFile.type == .audio {
                    Button {
                        MacPlayerWindowManager.shared.toggleMiniPlayer(for: currentFile.id)
                    } label: {
                        Image(systemName: "pip.enter")
                            .font(.system(size: iconSize, weight: .regular))
                            .foregroundColor(.white)
                            .frame(width: buttonSize, height: buttonSize)
                            .contentShape(Circle())
                            .macHoverEffect()
                    }
                    .buttonStyle(.plain)
                } else if currentFile.type == .video, enableMacPiPBeta {
                    Button {
                        if playbackService.isVideoPiPActive {
                            playbackService.stopPictureInPicture()
                        } else {
                            _ = playbackService.startPictureInPicture(userInitiated: true)
                        }
                    } label: {
                        Image(systemName: playbackService.isVideoPiPActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: iconSize, weight: .regular))
                            .foregroundColor(playbackService.isVideoPiPActive ? .blue : .white)
                            .frame(width: buttonSize, height: buttonSize)
                            .contentShape(Circle())
                            .macHoverEffect()
                    }
                    .buttonStyle(.plain)
                }

                if EPGService.shared.hasAvailableEPG(for: currentFile, in: playbackServer) {
                    Button {
                        closeAllPopoversExcept()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if activeRightSidebarTab == .epg { activeRightSidebarTab = nil } else { activeRightSidebarTab = .epg }
                        }
                    } label: {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: iconSize, weight: .regular))
                            .foregroundColor(activeRightSidebarTab == .epg ? .blue : .white)
                            .frame(width: buttonSize, height: buttonSize)
                            .contentShape(Circle())
                            .macHoverEffect()
                    }
                    .buttonStyle(.plain)
                    .help(platformShellString("Program Guide"))
                }

                if currentFile.serverType == .vod {
                    Button {
                        closeAllPopoversExcept()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            activeRightSidebarTab = activeRightSidebarTab == .sources ? nil : .sources
                        }
                    } label: {
                        Image(systemName: "arrow.triangle.swap")
                            .font(.system(size: iconSize, weight: .regular))
                            .foregroundColor(activeRightSidebarTab == .sources ? .blue : .white)
                            .frame(width: buttonSize, height: buttonSize)
                            .contentShape(Circle())
                            .macHoverEffect()
                    }
                    .buttonStyle(.plain)
                    .help(platformShellString("VOD Check and Switch"))
                }

                if currentPlaylist != nil {
                    Button {
                        closeAllPopoversExcept()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if activeRightSidebarTab == .playlist { activeRightSidebarTab = nil } else { activeRightSidebarTab = .playlist }
                        }
                    } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: iconSize, weight: .regular))
                            .foregroundColor(activeRightSidebarTab == .playlist ? .blue : .white)
                            .frame(width: buttonSize, height: buttonSize)
                            .contentShape(Circle())
                            .macHoverEffect()
                    }
                    .buttonStyle(.plain)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .padding(.horizontal, playerContentHorizontalPadding(width: width))
        .padding(.top, width < 500 ? 28 : 40)
        .padding(.bottom, width < 500 ? 24 : 46)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [Color.black.opacity(0.85), Color.black.opacity(0.4), Color.clear]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            MacPlayerWindowManager.shared.toggleZoom(for: currentFile.id)
        }
    }

    @ViewBuilder
    private func bottomControls(width: CGFloat) -> some View {
        let isCompact = width < 700
        let isNarrow = width < 420
        let isUltraMini = width < 280
        let showExtraControls = width >= 540
        let isAudio = currentFile.type == .audio
        let isLive = currentFile.isLiveStream

        let buttonSize: CGFloat = isUltraMini ? 26 : (isNarrow ? 28 : (isCompact ? 30 : 38))
        let playButtonSize: CGFloat = isUltraMini ? 34 : (isNarrow ? 38 : (isCompact ? 42 : 52))
        let iconSize: CGFloat = isUltraMini ? 13 : (isNarrow ? 14 : (isCompact ? 15 : 18))
        let playIconSize: CGFloat = isUltraMini ? 16 : (isNarrow ? 18 : (isCompact ? 20 : 26))
        let rowSpacing: CGFloat = isUltraMini ? 4 : (isNarrow ? 6 : (isCompact ? 8 : 14))

        let controlsView = VStack(spacing: isUltraMini ? 8 : 16) {
            // 1. Progress Bar Row
            if isLive {
                let prog = currentLiveProgramme
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                        Text(platformShellString("LIVE"))
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.red.opacity(0.85)))
                    
                    Text(currentFile.name)
                        .font(.caption.weight(.bold))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                    
                    if let prog = prog {
                        Text("·")
                            .foregroundColor(.white.opacity(0.5))
                        Text(prog.title)
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.white.opacity(0.88))
                            .lineLimit(1)
                        Text(prog.formattedTimeSpan)
                            .font(.caption2.monospacedDigit())
                            .foregroundColor(.white.opacity(0.6))
                    }
                    
                    Spacer()
                    
                    let videoSize = playbackService.videoNaturalSize
                    if videoSize.width > 0 && videoSize.height > 0 {
                        Text("\(Int(videoSize.width))x\(Int(videoSize.height))")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.15)))
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 20)
            } else {
                VStack(spacing: isUltraMini ? 2 : 4) {
                    GeometryReader { proxy in
                        ZStack(alignment: .bottomLeading) {
                            MacPlayerProgressBar(
                                position: Binding(
                                    get: { (isSeeking || Date().timeIntervalSince(lastSeekDate) < 0.5) ? pendingPosition : Double(playbackService.position) },
                                    set: { newValue in
                                        pendingPosition = newValue
                                    }
                                ),
                                duration: Double(playbackService.duration),
                                bufferedRanges: playbackService.bufferedRanges,
                                onSeekStarted: {
                                    isSeeking = true
                                },
                                onSeekChanged: { newFraction in
                                    pendingPosition = newFraction
                                    lastSeekDate = Date()
                                },
                                onSeekEnded: { finalFraction in
                                    pendingPosition = finalFraction
                                    lastSeekDate = Date()
                                    playbackService.setPosition(Float(finalFraction))
                                    isSeeking = false
                                },
                                onHoverChanged: { newHover in
                                    hoverPosition = newHover
                                    if newHover == nil {
                                        previewGenerator.cancel()
                                    }
                                }
                            )
                            .onChange(of: playbackService.position) { newValue in
                                if !isSeeking {
                                    pendingPosition = Double(newValue)
                                }
                            }
                            .overlay(alignment: .bottomLeading) {
                                if let hoverPos = hoverPosition {
                                    let duration = playbackService.duration
                                    let time = duration > 0 ? Double(duration) * hoverPos : 0
                                    
                                    VStack(spacing: 8) {
                                        if currentFile.type != .audio {
                                            if let img = previewGenerator.previewImage {
                                                Image(nsImage: img)
                                                    .resizable()
                                                    .aspectRatio(contentMode: .fill)
                                                    .frame(width: 160, height: 90)
                                                    .clipped()
                                                    .cornerRadius(8)
                                                    .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                                                    .overlay(
                                                        Group {
                                                            if previewGenerator.isLoading {
                                                                ZStack {
                                                                    Color.black.opacity(0.4)
                                                                    ProgressView().controlSize(.small)
                                                                }
                                                                .cornerRadius(8)
                                                            }
                                                        }
                                                    )
                                            } else {
                                                ZStack {
                                                    LinearGradient(
                                                        gradient: Gradient(colors: [
                                                            Color.white.opacity(0.08),
                                                            Color.white.opacity(0.03),
                                                            Color.black.opacity(0.24)
                                                        ]),
                                                        startPoint: .topLeading,
                                                        endPoint: .bottomTrailing
                                                    )
                                                    if previewGenerator.isLoading {
                                                        ProgressView().controlSize(.small)
                                                    }
                                                }
                                                .frame(width: 160, height: 90)
                                                .cornerRadius(8)
                                                .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
                                                .overlay(
                                                    RoundedRectangle(cornerRadius: 8)
                                                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                                                )
                                            }
                                        }

                                        Text(formatTime(Int32(time)))
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                            .foregroundColor(.white)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color.black.opacity(0.75))
                                            .cornerRadius(6)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                                            )
                                    }
                                    .task(id: Int(time / 1000)) {
                                        if currentFile.type != .audio && duration > 0 {
                                            previewGenerator.generateThumbnail(
                                                for: currentFile,
                                                at: time,
                                                duration: Double(duration),
                                                mpvFallback: { playbackService.makeMPVSeekPreviewProvider(for: currentFile) }
                                            )
                                        }
                                    }
                                    .frame(width: 160)
                                    .offset(x: max(0, min(proxy.size.width - 160, proxy.size.width * CGFloat(hoverPos) - 80)), y: currentFile.type == .audio ? -12 : -30)
                                    .allowsHitTesting(false)
                                }
                            }
                        }
                    }
                    .frame(height: 18)

                    HStack {
                        Text(formatTime(playbackService.currentTime))
                            .font((isUltraMini ? Font.caption2 : Font.caption).monospacedDigit().weight(.medium))
                            .foregroundColor(.white.opacity(0.75))

                        Spacer(minLength: 8)

                        if playbackService.isUsingMPV && currentFile.isRemote && !isUltraMini,
                           !playbackService.cacheReadIdle,
                           let rate = playbackService.cacheInputBytesPerSecond, rate > 0 {
                            Text("↓ " + ByteCountFormatter.string(fromByteCount: rate, countStyle: .file) + "/s")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.white.opacity(0.85))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(-1)
                                .accessibilityLabel(String(format: platformShellString("MPV.Cache.Speed"), ByteCountFormatter.string(fromByteCount: rate, countStyle: .file)))
                            Spacer(minLength: 8)
                        }

                        Text(formatTime(playbackService.duration))
                            .font((isUltraMini ? Font.caption2 : Font.caption).monospacedDigit().weight(.medium))
                            .foregroundColor(.white.opacity(0.75))
                    }
                }
                .padding(.horizontal, isUltraMini ? 4 : (isNarrow ? 6 : 8))
            }

            // 2. Controls Row
            HStack(spacing: rowSpacing) {
                // Leading side (Audio, Subtitle) - hidden in ultra-mini mode to prioritize center playback controls
                if !isUltraMini && currentFile.type != .audio {
                    HStack(spacing: isCompact ? 6 : 12) {
                        // Audio Track Menu
                        Button {
                            if !showAudioPopover {
                                closeAllPopoversExcept(audio: true)
                            }
                            showAudioPopover.toggle()
                        } label: {
                            Image(systemName: "waveform")
                                .font(.system(size: iconSize, weight: .regular))
                                .foregroundColor(.white)
                                .frame(width: buttonSize, height: buttonSize)
                                .contentShape(Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showAudioPopover, arrowEdge: .top) {
                            VStack(spacing: 0) {
                                ForEach(playbackService.audioTracks) { track in
                                    Button(action: {
                                        playbackService.setAudioTrack(track.id)
                                        showToast(icon: "waveform", text: track.name)
                                        showAudioPopover = false
                                    }) {
                                        HStack {
                                            Text(track.name)
                                            Spacer()
                                            if track.id == playbackService.currentAudioTrackID {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .macListHoverEffect()
                                }
                            }
                            .padding(.vertical, 6)
                            .frame(minWidth: 150)
                        }

                        // Subtitle Track Menu
                        Button {
                            if !showSubtitlePopover {
                                closeAllPopoversExcept(subtitle: true)
                            }
                            showSubtitlePopover.toggle()
                        } label: {
                            Image(systemName: "captions.bubble")
                                .font(.system(size: iconSize, weight: .regular))
                                .foregroundColor(.white)
                                .frame(width: buttonSize, height: buttonSize)
                                .contentShape(Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showSubtitlePopover, arrowEdge: .top) {
                            MacSubtitleSelector(
                                playbackService: playbackService,
                                onImportExternalSubtitle: importExternalSubtitle,
                                onBrowseSubtitles: {
                                    showSubtitlePopover = false
                                    withAnimation(.easeInOut(duration: 0.18)) {
                                        activeRightSidebarTab = .subtitleBrowser
                                    }
                                    revealControls()
                                },
                                onAction: { showToast(icon: $0, text: $1) }
                            )
                        }
                    }
                }

                Spacer(minLength: 2)

                // Centered Playback Controls
                HStack(spacing: isUltraMini ? 6 : (isCompact ? 8 : 16)) {
                    let seekDelta = Int32(doubleTapSeekDuration * 1000)
                    let seekIconSuffix = Int(doubleTapSeekDuration)
                    
                    if showExtraControls && !isLive {
                        Button(action: {
                            replayCurrentItemFromBeginning()
                            showToast(icon: "arrow.counterclockwise", text: platformShellString("Replay from Start"))
                        }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: iconSize, weight: .regular))
                                .foregroundColor(.white)
                                .frame(width: buttonSize, height: buttonSize)
                                .contentShape(Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)
                        .help(platformShellString("Replay from Start"))
                        
                        if currentFile.type != .audio {
                            Button(action: { 
                                seek(by: -seekDelta)
                                showToast(icon: "gobackward.\(seekIconSuffix)", text: "\(Int(doubleTapSeekDuration))s")
                            }) {
                                Image(systemName: "gobackward.\(seekIconSuffix)")
                                    .font(.system(size: iconSize, weight: .regular))
                                    .foregroundColor(.white)
                                    .frame(width: buttonSize, height: buttonSize)
                                    .contentShape(Circle())
                                    .macHoverEffect()
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if hasPlaylist || showExtraControls {
                        Button(action: {
                            if hasPreviousInPlaylist {
                                playPreviousInPlaylist()
                            }
                        }) {
                            Image(systemName: "backward.end.fill")
                                .font(.system(size: isUltraMini ? 12 : (isCompact ? 14 : 18), weight: .regular))
                                .foregroundColor(.white)
                                .frame(width: buttonSize, height: buttonSize)
                                .contentShape(Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasPlaylist || !hasPreviousInPlaylist)
                        .opacity(!hasPlaylist || !hasPreviousInPlaylist ? 0.5 : 1.0)
                    } else if !isLive && currentFile.type != .audio {
                        Button(action: { 
                            seek(by: -seekDelta)
                            showToast(icon: "gobackward.\(seekIconSuffix)", text: "\(Int(doubleTapSeekDuration))s")
                        }) {
                            Image(systemName: "gobackward.\(seekIconSuffix)")
                                .font(.system(size: iconSize, weight: .regular))
                                .foregroundColor(.white)
                                .frame(width: buttonSize, height: buttonSize)
                                .contentShape(Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)
                    }
                    
                    Button(action: {
                        playbackService.togglePlayPause()
                        revealControls()
                        startControlsTimer()
                    }) {
                        Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: playIconSize, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: playButtonSize, height: playButtonSize)
                            .contentShape(Circle())
                            .macHoverEffect()
                    }
                    .buttonStyle(.plain)
                    
                    if hasPlaylist || showExtraControls {
                        Button(action: {
                            playNextInPlaylist()
                        }) {
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: isUltraMini ? 12 : (isCompact ? 14 : 18), weight: .regular))
                                .foregroundColor(.white)
                                .frame(width: buttonSize, height: buttonSize)
                                .contentShape(Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasPlaylist || !hasNextInPlaylist)
                        .opacity(!hasPlaylist || !hasNextInPlaylist ? 0.5 : 1.0)
                    } else if !isLive && currentFile.type != .audio {
                        Button(action: { 
                            seek(by: seekDelta)
                            showToast(icon: "goforward.\(seekIconSuffix)", text: "\(Int(doubleTapSeekDuration))s")
                        }) {
                            Image(systemName: "goforward.\(seekIconSuffix)")
                                .font(.system(size: iconSize, weight: .regular))
                                .foregroundColor(.white)
                                .frame(width: buttonSize, height: buttonSize)
                                .contentShape(Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)
                    }
                    
                    if showExtraControls && !isLive {
                        if currentFile.type != .audio {
                            Button(action: { 
                                seek(by: seekDelta)
                                showToast(icon: "goforward.\(seekIconSuffix)", text: "\(Int(doubleTapSeekDuration))s")
                            }) {
                                Image(systemName: "goforward.\(seekIconSuffix)")
                                    .font(.system(size: iconSize, weight: .regular))
                                    .foregroundColor(.white)
                                    .frame(width: buttonSize, height: buttonSize)
                                    .contentShape(Circle())
                                    .macHoverEffect()
                            }
                            .buttonStyle(.plain)
                        }

                        Button(action: {
                            let allModes = MacPlaybackSequenceMode.allCases
                            let nextIndex = (allModes.firstIndex(of: videoPlayMode)! + 1) % allModes.count
                            videoPlayMode = allModes[nextIndex]
                            showToast(icon: videoPlayMode.icon, text: videoPlayMode.title)
                            revealControls()
                            startControlsTimer()
                        }) {
                            Image(systemName: videoPlayMode.icon)
                                .font(.system(size: iconSize, weight: .regular))
                                .foregroundColor(.white)
                                .frame(width: buttonSize, height: buttonSize)
                                .contentShape(Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)
                        .disabled(!hasPlaylist)
                        .opacity(!hasPlaylist ? 0.5 : 1.0)
                    }
                }

                Spacer(minLength: 2)

                // Trailing side (Volume, Speed, More)
                HStack(spacing: isUltraMini ? 4 : (isCompact ? 6 : 12)) {
                    if showExtraControls {
                        // Volume
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showsVolumePopover.toggle()
                                if showsVolumePopover {
                                    closeAllPopoversExcept(volume: true)
                                }
                            }
                        } label: {
                            Image(systemName: volume <= 0.01 ? "speaker.slash" : "speaker.wave.2")
                                .font(.system(size: iconSize, weight: .regular))
                                .foregroundColor(.white)
                                .frame(width: buttonSize, height: buttonSize)
                                .contentShape(Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)
                        .overlay(alignment: .top) {
                            if showsVolumePopover {
                                VStack(spacing: 10) {
                                    MacVerticalSlider(value: Binding(
                                        get: { volume },
                                        set: { newValue in
                                            volume = newValue
                                            playbackService.setVolume(Int32(newValue * 100))
                                        }
                                    ), range: 0...1)
                                    .frame(width: 20, height: 100)
                                    Image(systemName: "speaker.wave.2")
                                        .font(.system(size: 13))
                                        .foregroundColor(.white.opacity(0.7))
                                }
                                .padding(.vertical, 14)
                                .padding(.horizontal, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color.black.opacity(0.85))
                                        .shadow(color: .black.opacity(0.4), radius: 10)
                                )
                                .offset(y: -150)
                                .transition(.asymmetric(
                                    insertion: .opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)).combined(with: .offset(y: 8)),
                                    removal: .opacity.combined(with: .scale(scale: 0.8, anchor: .bottom)).combined(with: .offset(y: 8))
                                ))
                            }
                        }
                    }

                    if !isUltraMini && currentFile.type != .audio && !isLive {
                        // Playback Speed Menu
                        Button {
                            if !showSpeedPopover {
                                closeAllPopoversExcept(speed: true)
                            }
                            showSpeedPopover.toggle()
                        } label: {
                            Text("\(String(format: "%g", playbackService.targetRate))x")
                                .font(.system(size: isUltraMini ? 10 : (isCompact ? 11 : 12), weight: .medium, design: .rounded))
                                .foregroundColor(.white)
                                .frame(width: buttonSize, height: buttonSize)
                                .contentShape(Circle())
                                .macHoverEffect()
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showSpeedPopover, arrowEdge: .top) {
                            VStack(spacing: 0) {
                                let speeds: [Float] = playbackService.isUsingMPV ? MPVPlaybackSpeed.rates : [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0]
                                ForEach(speeds, id: \.self) { rate in
                                    let title = "\(String(format: "%g", rate))x"
                                    Button(action: {
                                        playbackService.setPlaybackRate(rate)
                                        let rateKey = currentFile.type == .audio ? "defaultAudioPlaybackSpeed" : "defaultPlaybackSpeed"
                                        UserDefaults.standard.set(Double(rate), forKey: rateKey)
                                        showToast(icon: "gauge.with.dots.needle.bottom.50percent", text: "\(String(format: "%g", rate))x")
                                        showSpeedPopover = false
                                    }) {
                                        HStack {
                                            Text(title)
                                            Spacer()
                                            if abs(playbackService.targetRate - rate) < 0.01 {
                                                Image(systemName: "checkmark")
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .macListHoverEffect()
                                }
                            }
                            .padding(.vertical, 6)
                            .frame(minWidth: 100)
                        }
                    }

                    // More Menu (Side Drawer Trigger) - Always at the trailing end
                    let isMoreActive = activeRightSidebarTab != nil && activeRightSidebarTab != .epg && activeRightSidebarTab != .playlist && activeRightSidebarTab != .sources && activeRightSidebarTab != .subtitleBrowser
                    Button {
                        closeAllPopoversExcept()
                        withAnimation(.easeInOut(duration: 0.18)) {
                            if isMoreActive {
                                activeRightSidebarTab = nil
                            } else {
                                activeRightSidebarTab = currentFile.type == .audio ? .audio : .video
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: iconSize, weight: .regular))
                            .foregroundColor(isMoreActive ? .blue : .white)
                            .frame(width: buttonSize, height: buttonSize)
                            .contentShape(Circle())
                            .macHoverEffect()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        
        if isAudio {
            controlsView
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 24)
                        .fill(Color.black.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                )
                .shadow(color: Color.black.opacity(0.3), radius: 20, y: 10)
                .frame(maxWidth: 600)
                .padding(.bottom, 36)
                .onHover { isHovering in
                    isHoveringControls = isHovering
                }
        } else {
            controlsView
                .padding(.horizontal, playerContentHorizontalPadding(width: width))
                .padding(.bottom, 36)
                .padding(.top, 40)
                .background(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.clear, Color.black.opacity(0.8)]),
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .onHover { isHovering in
                    isHoveringControls = isHovering
                }
        }
    }

    private var displayedCurrentTime: Int32 {
        guard isSeeking, playbackService.duration > 0 else { return playbackService.currentTime }
        return Int32(Double(playbackService.duration) * pendingPosition)
    }

    private func seek(by delta: Int32) {
        let newTime = max(0, min(playbackService.duration, playbackService.currentTime + delta))
        
        let targetPos = Double(newTime) / Double(max(1, playbackService.duration))
        pendingPosition = targetPos
        isSeeking = true
        
        playbackService.prepareForSeek()
        if playbackService.isUsingMPV {
            playbackService.setPosition(Float(newTime) / Float(max(playbackService.duration, 1)))
        } else { playbackService.mediaPlayer?.time = VLCTime(int: newTime) }
        revealControls()
        startControlsTimer()
        
        let seconds = Int(abs(delta) / 1000)
        let standardSeconds = [5, 10, 15, 30, 45, 60, 75, 90]
        let icon = standardSeconds.contains(seconds) ? (delta >= 0 ? "goforward.\(seconds)" : "gobackward.\(seconds)") : (delta >= 0 ? "goforward" : "gobackward")
        let text = delta >= 0 ? "+\(seconds)s" : "-\(seconds)s"
        showToast(icon: icon, text: text)
        
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            await MainActor.run {
                if abs(pendingPosition - targetPos) < 0.0001 {
                    isSeeking = false
                }
            }
        }
    }

    private var isMenuOpen: Bool {
        return showsVolumePopover || activeRightSidebarTab != nil || showSubtitlePopover || showAudioPopover || showAspectRatioPopover || showSpeedPopover || showDisplayModePopover || isHoveringControls || isSecondarySubtitlePositionAdjustmentActive
    }

    private func startControlsTimer() {
        controlsTimer?.invalidate()
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { _ in
            if self.playbackService.isPlaying && !self.isMenuOpen && self.currentFile.type != .audio {
                withAnimation {
                    self.showControls = false
                }
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
    }

    private func revealControls() {
        withAnimation(.easeInOut(duration: 0.16)) {
            showControls = true
        }
    }
    
    private func importExternalSubtitle() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [
            UTType(filenameExtension: "srt")!,
            UTType(filenameExtension: "ass")!,
            UTType(filenameExtension: "ssa")!,
            UTType(filenameExtension: "vtt")!
        ]
        
        if panel.runModal() == .OK, let url = panel.url {
            playbackService.addExternalSubtitle(url: url)
        }
    }

    private func showToast(icon: String, text: String? = nil, duration: Double = 1.2) {
        toastHideWorkItem?.cancel()
        toastIcon = icon
        toastText = text
        withAnimation(.easeIn(duration: 0.1)) { toastOpacity = 1.0 }
        let workItem = DispatchWorkItem {
            withAnimation(.easeOut(duration: 0.3)) { toastOpacity = 0.0 }
        }
        toastHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
    }

    private func formatTime(_ ms: Int32) -> String {
        let seconds = ms / 1000
        let s = seconds % 60
        let m = (seconds / 60) % 60
        let h = seconds / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
    
    private func closeAllPopoversExcept(volume: Bool = false, audio: Bool = false, subtitle: Bool = false, speed: Bool = false, displayMode: Bool = false) {
        if !volume { showsVolumePopover = false }
        if !audio { showAudioPopover = false }
        if !subtitle { showSubtitlePopover = false }
        if !speed { showSpeedPopover = false }
        if !displayMode { showDisplayModePopover = false }
    }
    
    private func replayCurrentItemFromBeginning() {
        playbackService.restartFromBeginning()
        revealControls()
        startControlsTimer()
    }
    
    private var hasPlaylist: Bool {
        return (currentPlaylist?.count ?? 0) > 1
    }
    
    private func isFileMatchingCurrent(_ file: VideoFile) -> Bool {
        if file.id == currentFile.id { return true }
        if let currentServerPath = currentFile.serverPath, let fileServerPath = file.serverPath, !currentServerPath.isEmpty {
            return currentServerPath == fileServerPath
        }
        return file.name == currentFile.name
    }

    private var hasPreviousInPlaylist: Bool {
        guard let playlist = currentPlaylist, let currentIndex = playlist.firstIndex(where: { isFileMatchingCurrent($0) }) else { return false }
        return currentIndex - 1 >= 0
    }
    
    private var hasNextInPlaylist: Bool {
        guard let playlist = currentPlaylist, let currentIndex = playlist.firstIndex(where: { isFileMatchingCurrent($0) }) else { return false }
        return currentIndex + 1 < playlist.count
    }

    private func playPreviousInPlaylist() {
        guard let playlist = currentPlaylist, let currentIndex = playlist.firstIndex(where: { isFileMatchingCurrent($0) }) else { return }
        
        if videoPlayMode == .shuffle, !videoPlaybackHistory.isEmpty {
            let prevIndex = videoPlaybackHistory.removeLast()
            if prevIndex >= 0 && prevIndex < playlist.count {
                switchPlayback(to: playlist[prevIndex])
                return
            }
        }
        
        var prevIndex = currentIndex - 1
        if prevIndex < 0 {
            if videoPlayMode == .sequential {
                return
            } else {
                prevIndex = playlist.count - 1
            }
        }
        
        switchPlayback(to: playlist[prevIndex])
    }
    
    private func playNextInPlaylist() {
        guard let playlist = currentPlaylist, let currentIndex = playlist.firstIndex(where: { isFileMatchingCurrent($0) }) else { return }
        
        if videoPlayMode == .repeatOne {
            playbackService.restartFromBeginning()
            return
        }
        
        videoPlaybackHistory.append(currentIndex)
        if videoPlaybackHistory.count > 50 {
            videoPlaybackHistory.removeFirst()
        }
        
        if videoPlayMode == .shuffle {
            if playlist.count > 1 {
                var nextIndex = currentIndex
                while nextIndex == currentIndex {
                    nextIndex = Int.random(in: 0..<playlist.count)
                }
                switchPlayback(to: playlist[nextIndex])
            }
            return
        }
        
        var nextIndex = currentIndex + 1
        if nextIndex >= playlist.count {
            if videoPlayMode == .sequential {
                return
            } else {
                nextIndex = 0
            }
        }
        
        switchPlayback(to: playlist[nextIndex])
    }
    
    // MARK: - Secondary Subtitle Logic

    @ViewBuilder
    private func generatedPrimaryPart(_ part: SubtitlePart) -> some View {
        if let text = part.text, text.length > 0,
           let original = text.attribute(NSAttributedString.Key("GenPlayerSubtitleOriginal"), at: 0, effectiveRange: nil) as? String,
           let translated = text.attribute(NSAttributedString.Key("GenPlayerSubtitleTranslation"), at: 0, effectiveRange: nil) as? String {
            let originalFirst = text.attribute(NSAttributedString.Key("GenPlayerSubtitleOriginalFirst"), at: 0, effectiveRange: nil) as? Bool ?? true
            VStack(spacing: 3) {
                if originalFirst { Text(original).font(.system(size: 18, weight: .medium)) }
                Text(translated)
                if !originalFirst { Text(original).font(.system(size: 18, weight: .medium)) }
            }
        } else { Text(part.text?.string ?? "") }
    }

    @ViewBuilder
    private func secondarySubtitlePart(_ part: SubtitlePart, containerHeight: CGFloat) -> some View {
        if let text = part.text, text.length > 0,
           let original = text.attribute(NSAttributedString.Key("GenPlayerSubtitleOriginal"), at: 0, effectiveRange: nil) as? String,
           let translated = text.attribute(NSAttributedString.Key("GenPlayerSubtitleTranslation"), at: 0, effectiveRange: nil) as? String {
            let originalFirst = text.attribute(NSAttributedString.Key("GenPlayerSubtitleOriginalFirst"), at: 0, effectiveRange: nil) as? Bool ?? true
            VStack(spacing: 3) {
                if originalFirst { secondarySubtitleText(original, containerHeight: containerHeight, scale: 0.82) }
                secondarySubtitleText(translated, containerHeight: containerHeight)
                if !originalFirst { secondarySubtitleText(original, containerHeight: containerHeight, scale: 0.82) }
            }
        } else {
            secondarySubtitleText(part.text?.string ?? "", containerHeight: containerHeight)
        }
    }

    private func secondarySubtitleText(_ text: String, containerHeight: CGFloat, scale: CGFloat = 1) -> some View {
        Text(text)
            .font(
                .system(
                    size: MacVLCPlaybackService.secondarySubtitleBaseFontSize(
                        forContainerHeight: containerHeight
                    ) * CGFloat(secondarySubtitleSizeScale) * scale,
                    weight: .medium
                )
            )
            .foregroundColor(.white)
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .shadow(color: .black.opacity(0.88), radius: 1, x: 0, y: 1)
            .shadow(color: .black.opacity(0.88), radius: 1, x: 0, y: -1)
            .shadow(color: .black.opacity(0.88), radius: 1, x: 1, y: 0)
            .shadow(color: .black.opacity(0.88), radius: 1, x: -1, y: 0)
            .multilineTextAlignment(.center)
    }
    


    private func secondarySubtitleVerticalPosition(in containerHeight: CGFloat) -> CGFloat {
        if playbackService.usesMPVNativeASSSecondary && secondarySubtitlePositionRatio < 0 {
            return max(32, containerHeight - 48)
        }
        return MacVLCPlaybackService.secondarySubtitleCenterY(
            containerHeight: containerHeight,
            positionRatio: CGFloat(secondarySubtitlePositionRatio)
        )
    }

    private func currentSecondarySubtitleVerticalPositionRatio(in size: CGSize) -> CGFloat {
        if secondarySubtitlePositionRatio >= 0 {
            return CGFloat(secondarySubtitlePositionRatio)
        }
        guard size.height > 0 else { return 0.56 }
        if playbackService.usesMPVNativeASSSecondary, let bounds = playbackService.nativeASSBounds {
            return bounds.midY
        }
        let currentY = secondarySubtitleVerticalPosition(in: size.height)
        return currentY / size.height
    }

    private func handleSecondarySubtitleAdjustmentGestureChanged(_ value: DragGesture.Value, in size: CGSize) {
        activateSecondarySubtitleAdjustment(autoHide: false)
        if secondarySubtitleDragInitialRatio == nil {
            secondarySubtitleDragInitialRatio = currentSecondarySubtitleVerticalPositionRatio(in: size)
        }
        
        let distance = max(abs(value.translation.width), abs(value.translation.height))
        guard distance > 2 else { return }
        
        updateSecondarySubtitleVerticalPosition(value, in: size)
    }

    private func handleSecondarySubtitleAdjustmentGestureEnded(_ value: DragGesture.Value, in size: CGSize) {
        let distance = max(abs(value.translation.width), abs(value.translation.height))
        if distance <= 2 {
            activateSecondarySubtitleAdjustment(autoHide: true)
        } else {
            updateSecondarySubtitleVerticalPosition(value, in: size)
            scheduleSecondarySubtitleAdjustmentHide(after: 2.0)
        }
        secondarySubtitleDragInitialRatio = nil
    }

    private func updateSecondarySubtitleVerticalPosition(_ value: DragGesture.Value, in size: CGSize) {
        guard size.height > 0 else { return }
        let initialRatio = secondarySubtitleDragInitialRatio ?? currentSecondarySubtitleVerticalPositionRatio(in: size)
        if secondarySubtitleDragInitialRatio == nil {
            secondarySubtitleDragInitialRatio = initialRatio
        }
        
        let ratio = initialRatio + value.translation.height / size.height
        // Clamp between 0.08 and 0.92
        let clampedRatio = min(max(Double(ratio), 0.08), 0.92)
        secondarySubtitlePositionRatio = clampedRatio
        if playbackService.usesMPVNativeASSSecondary { playbackService.updateMPVSecondaryStyle() }
    }

    private func activateSecondarySubtitleAdjustment(autoHide: Bool) {
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
            withAnimation(.easeInOut(duration: 0.15)) {
                isSecondarySubtitlePositionAdjustmentActive = false
            }
        }
        secondarySubtitleAdjustmentHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private var vodSourceSidebar: some View {
            let openedFileID = currentFile.id
            return MacVODSourceSwitchView(file: currentFile, onClose: {
                withAnimation(.easeInOut(duration: 0.18)) { activeRightSidebarTab = nil }
            }, onSelect: { file, playlist, matched in
                guard currentFile.id == openedFileID else { return }
                playbackSwitchID = UUID()
                var next = file
                next.lastPlayedPosition = matched ? max(0, Double(playbackService.currentTime) / 1000) : 0
                let oldID = currentFile.id
                currentPlaylist = playlist
                currentFile = next
                MacPlayerWindowManager.shared.updatePlayingFile(from: oldID, to: next, playbackService: playbackService)
                playbackService.play(file: next)
                revealControls()
            })
    }

    private func switchPlayback(to newFile: VideoFile) {
        playbackSwitchID = UUID()
        let requestID = playbackSwitchID
        Task {
            let playbackFile = (try? await AppNetworkService.shared.resolvedPlaybackFile(newFile)) ?? newFile
            await MainActor.run {
                guard requestID == playbackSwitchID else { return }
                let oldFileId = currentFile.id
                currentFile = playbackFile
                MacPlayerWindowManager.shared.updatePlayingFile(from: oldFileId, to: playbackFile, playbackService: playbackService)
                
                revealControls()
                startControlsTimer()
                MacPlayerWindowManager.shared.setWindowTitleBarButtonsHidden(false, for: playbackFile.id)
                
                playbackService.play(file: playbackFile)
            }
        }
    }

    private func handleDroppedFileURL(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        if VideoFile.FileType.subtitleExtensions.contains(ext) {
            playbackService.addExternalSubtitle(url: url)
            showToast(icon: "captions.bubble", text: url.lastPathComponent)
            return
        }
        
        let type = VideoFile.FileType.determineType(from: url)
        guard type == .video || type == .audio else { return }
        
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.creationDate] as? Date) ?? Date()
        let newFile = VideoFile(name: url.lastPathComponent, url: url, type: type, size: size, date: date, isRemote: false)
        
        playbackSwitchID = UUID()
        let oldFileId = currentFile.id
        currentFile = newFile
        currentPlaylist = nil
        loadPlaylistIfNeeded()
        
        MacPlayerWindowManager.shared.updatePlayingFile(from: oldFileId, to: newFile, playbackService: playbackService)
        
        revealControls()
        startControlsTimer()
        MacPlayerWindowManager.shared.setWindowTitleBarButtonsHidden(false, for: newFile.id)
        
        playbackService.play(file: newFile)
    }

    private func loadPlaylistIfNeeded() {
        guard currentPlaylist == nil || currentPlaylist!.count <= 1 else { return }
        
        if let resolver = MacPlayerWindowManager.shared.playlistResolver {
            let requestedFile = currentFile
            Task {
                if let resolved = await resolver.resolvePlaylist(for: requestedFile), resolved.count > 1 {
                    await MainActor.run {
                        guard currentFile.id == requestedFile.id else { return }
                        self.currentPlaylist = resolved
                    }
                }
            }
        }
    }
}

private struct MacPlayerRoundButton: View {
    let systemImageName: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImageName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 42, height: 42)
                .background(isHovered ? .white.opacity(0.25) : .white.opacity(0.13), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
    }
}


struct MacListHoverEffect: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.white.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
    }
}
extension View {
    func macListHoverEffect() -> some View {
        self.modifier(MacListHoverEffect())
    }
}

struct MacHoverEffect: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.white.opacity(0.18) : Color.white.opacity(0.001), in: Circle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
    }
}
extension View {
    func macHoverEffect() -> some View {
        self.modifier(MacHoverEffect())
    }
}

struct MacMenuHoverEffect: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .background(isHovered ? Color.white.opacity(0.18) : Color.white.opacity(0.001), in: RoundedRectangle(cornerRadius: 6))
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovered = hovering
                }
            }
    }
}
extension View {
    func macMenuHoverEffect() -> some View {
        self.modifier(MacMenuHoverEffect())
    }
}

private struct MacPlayerPosterPlaceholder: View {
    let file: VideoFile

    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [
                    Color.white.opacity(0.20),
                    Color.white.opacity(0.06)
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: file.type == .audio ? "music.note" : "film.fill")
                .font(.system(size: 40, weight: .semibold))
                .foregroundColor(.white.opacity(0.70))
        }
    }
}

private struct MacDarkInfoSection: View {
    let title: String
    let icon: String
    let items: [(key: String, value: String)]
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Section Header
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                
                Text(title)
                    .font(.system(.headline, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                
                Spacer()
            }
            .padding(.horizontal, 4)
            
            // Key-Value Rows
            VStack(spacing: 0) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 12) {
                        Text(items[index].key)
                            .font(.system(.subheadline, design: .rounded))
                            .fontWeight(.medium)
                            .foregroundColor(.white.opacity(0.6))
                            .frame(width: 100, alignment: .leading)
                        
                        Text(items[index].value)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .layoutPriority(1)
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 14)
                    
                    if index < items.count - 1 {
                        Divider()
                            .background(Color.white.opacity(0.1))
                            .padding(.leading, 14)
                    }
                }
            }
            .background(Color.white.opacity(0.08))
            .cornerRadius(12)
        }
    }
}
private struct MacVerticalSlider: NSViewRepresentable {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    
    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: context.coordinator, action: #selector(Coordinator.valueChanged(_:)))
        slider.isVertical = true
        slider.controlSize = .regular
        return slider
    }
    
    func updateNSView(_ nsView: NSSlider, context: Context) {
        nsView.doubleValue = value
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value)
    }
    
    class Coordinator: NSObject {
        @Binding var value: Double
        var isUpdatingFromBinding = false
        
        init(value: Binding<Double>) {
            self._value = value
        }
        
        @objc func valueChanged(_ sender: NSSlider) {
            self.value = sender.doubleValue
        }
    }
}

private struct MacPopoverSlider: View {
    @Binding var value: Double
    let iconName: String
    
    var body: some View {
        VStack(spacing: 12) {
            MacVerticalSlider(value: $value, range: 0...1)
                .frame(width: 20, height: 100)
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(.white)
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
        .padding(.horizontal, 12)
        .background(Color.black.opacity(0.8))
        .cornerRadius(12)
    }
}

// MARK: - Mac In-Player EPG Program Guide Sidebar

struct MacPlayerEPGSidebar: View {
    @Binding var currentFile: VideoFile
    let playlist: [VideoFile]
    let server: ServerConfig?
    @ObservedObject var playbackService: MacVLCPlaybackService
    let onSelect: (VideoFile) -> Void
    let onClose: () -> Void
    
    @ObservedObject private var epgService = EPGService.shared
    @State private var selectedDateIndex: Int = 1 // 0: Yesterday, 1: Today, 2: Tomorrow
    
    private let availableDates: [Date] = {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return [
            calendar.date(byAdding: .day, value: -1, to: today) ?? today,
            today,
            calendar.date(byAdding: .day, value: 1, to: today) ?? today,
            calendar.date(byAdding: .day, value: 2, to: today) ?? today
        ]
    }()
    
    private var currentChannel: IPTVChannel {
        IPTVChannel(
            id: currentFile.jellyfinItemId ?? "",
            name: currentFile.name,
            url: currentFile.url
        )
    }
    
    private var serverId: UUID? {
        if let serverIdStr = currentFile.jellyfinServerId {
            return UUID(uuidString: serverIdStr)
        }
        return server?.id
    }
    
    private var selectedDate: Date {
        if selectedDateIndex >= 0 && selectedDateIndex < availableDates.count {
            return availableDates[selectedDateIndex]
        }
        return Date()
    }
    
    private var dayProgrammes: [EPGProgramme] {
        guard let serverId = serverId else { return [] }
        return epgService.programmes(for: currentChannel, in: serverId, on: selectedDate)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(currentFile.name)
                        .font(.headline)
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(platformShellString("Program Guide"))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.black.opacity(0.4))
            
            // Date Picker Tabs
            HStack(spacing: 6) {
                ForEach(0..<availableDates.count, id: \.self) { idx in
                    let date = availableDates[idx]
                    let isSelected = selectedDateIndex == idx
                    let title = dateTitle(for: date, index: idx)
                    
                    Button {
                        selectedDateIndex = idx
                    } label: {
                        Text(title)
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium))
                            .foregroundColor(isSelected ? .white : .white.opacity(0.7))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.blue : Color.white.opacity(0.1))
                            )
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.2))
            
            // Program Schedule List
            if dayProgrammes.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.25))
                    Text(platformShellString("No Program Guide Available"))
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 6) {
                            ForEach(dayProgrammes) { prog in
                                MacPlayerEPGRow(programme: prog)
                                    .id(prog.id)
                            }
                        }
                        .padding(10)
                    }
                    .onAppear {
                        if let liveProg = dayProgrammes.first(where: { $0.isLive() }) {
                            proxy.scrollTo(liveProg.id, anchor: .center)
                        }
                    }
                }
            }
        }
        .background(
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                Rectangle()
                    .fill(Color.black.opacity(0.6))
            }
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: -2, y: 0)
        .ignoresSafeArea()
    }
    
    private func dateTitle(for date: Date, index: Int) -> String {
        if index == 0 {
            return platformShellString("Yesterday")
        } else if index == 1 {
            return platformShellString("Today")
        } else if index == 2 {
            return platformShellString("Tomorrow")
        } else {
            return EPGDateFormatter.dayOfWeekFormatter.string(from: date)
        }
    }
}

struct MacPlayerEPGRow: View {
    let programme: EPGProgramme
    
    private var isLive: Bool { programme.isLive() }
    private var isPast: Bool { programme.isPast() }
    
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(programme.formattedStartTime)
                .font(.system(size: 12, weight: isLive ? .bold : .medium, design: .monospaced))
                .foregroundColor(isLive ? .blue : (isPast ? .white.opacity(0.4) : .white.opacity(0.7)))
                .frame(width: 44, alignment: .leading)
            
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(programme.title)
                        .font(.system(size: 12.5, weight: isLive ? .bold : .medium))
                        .foregroundColor(isLive ? .white : (isPast ? .white.opacity(0.55) : .white.opacity(0.9)))
                        .lineLimit(2)
                    
                    if isLive {
                        Text(platformShellString("LIVE"))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.red))
                    }
                }
                
                if let desc = programme.desc?.trimmingCharacters(in: .whitespacesAndNewlines), !desc.isEmpty {
                    Text(desc)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(2)
                }
                
                if isLive {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.15))
                                .frame(height: 3)
                            Capsule()
                                .fill(Color.blue)
                                .frame(width: max(0, min(geo.size.width, geo.size.width * CGFloat(programme.progress()))), height: 3)
                        }
                    }
                    .frame(height: 3)
                    .padding(.top, 2)
                }
            }
            
            Spacer()
            
            Text(programme.formattedEndTime)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isLive ? Color.blue.opacity(0.15) : Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isLive ? Color.blue.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }
}

struct MacPlaylistSidebar: View {
    @Binding var currentFile: VideoFile
    let playlist: [VideoFile]
    let server: ServerConfig?
    @ObservedObject var playbackService: MacVLCPlaybackService
    let onSelect: (VideoFile) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(platformShellString("Playlist"))
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.7))
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding()
            .background(Color.black.opacity(0.4))
            
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(playlist.indices), id: \.self) { index in
                            let file = playlist[index]
                            let isPlaying = file.id == currentFile.id || (file.serverPath != nil && file.serverPath == currentFile.serverPath) || file.name == currentFile.name
                            
                            MacPlaylistRow(
                                file: file,
                                isPlaying: isPlaying,
                                server: server,
                                playlist: playlist,
                                playbackService: playbackService
                            )
                            .id(index)
                            .onTapGesture {
                                onSelect(file)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 8)
                }
                .onAppear {
                    if let currentIndex = playlist.firstIndex(where: { $0.id == currentFile.id || ($0.serverPath != nil && $0.serverPath == currentFile.serverPath) || $0.name == currentFile.name }) {
                        proxy.scrollTo(currentIndex, anchor: .center)
                    }
                }
            }
        }
        .background(
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                Rectangle()
                    .fill(Color.black.opacity(0.55))
            }
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: -2, y: 0)
        .ignoresSafeArea()
    }
}

struct MacPlaylistRow: View {
    let file: VideoFile
    let isPlaying: Bool
    let server: ServerConfig?
    let playlist: [VideoFile]
    @ObservedObject var playbackService: MacVLCPlaybackService
    
    @State private var progress: Double = 0
    @State private var lastPosition: Double = 0
    @State private var duration: Double = 0
    @State private var resolvedFileSize: Int64 = 0
    @State private var resolvedResolution: String?
    @State private var resolvedCodec: String?
    @State private var didRequestLocalMetadata = false
    
    private var progressText: String {
        let knownDuration = duration > 0 ? duration : (file.duration ?? 0)
        if knownDuration > 0 {
            if lastPosition > 0 {
                return "\(formatDuration(Int32(lastPosition * 1000))) / \(formatDuration(Int32(knownDuration * 1000)))"
            }
            return formatDuration(Int32(knownDuration * 1000))
        }
        return platformShellString("Unknown Duration")
    }
    
    private var secondaryMetadataLine: String {
        var segments: [String] = []
        segments.append(file.type == .audio ? platformShellString("Audio") : platformShellString("Video"))
        
        if let codec = resolvedCodec {
            segments.append(codec.uppercased())
        }
        if let resolution = resolvedResolution {
            segments.append(resolution)
        }
        let size = resolvedFileSize > 0 ? resolvedFileSize : (file.serverSize ?? file.size)
        if size > 0 {
            segments.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        
        return segments.joined(separator: " · ")
    }
    
    private var liveProgramTitle: String? {
        guard file.isLiveStream || file.serverType == .iptv,
              let serverIdStr = file.jellyfinServerId,
              let serverId = UUID(uuidString: serverIdStr) else {
            return nil
        }
        let dummy = IPTVChannel(
            id: file.jellyfinItemId ?? "",
            name: file.name,
            url: file.url
        )
        return EPGService.shared.currentProgramme(for: dummy, in: serverId)?.title
    }
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPlaying ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                    .frame(width: 56, height: 38)
                
                MacRemoteFileImage(
                    file: file,
                    server: server,
                    siblingFiles: playlist,
                    contentMode: .fill
                )
                .frame(width: 56, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(file.name)
                    .font(.system(size: 13, weight: isPlaying ? .semibold : .regular))
                    .foregroundColor(isPlaying ? .blue : .white)
                    .lineLimit(1)
                
                HStack(spacing: 8) {
                    let knownDuration = duration > 0 ? duration : (file.duration ?? 0)
                    if knownDuration > 0 && !file.isLiveStream {
                        ZStack(alignment: .leading) {
                            Capsule()
                                .fill(Color.white.opacity(0.2))
                                .frame(height: 3)
                            Capsule()
                                .fill(isPlaying ? Color.blue : Color.white.opacity(0.5))
                                .frame(width: 60 * CGFloat(min(progress, 1.0)), height: 3)
                        }
                        .frame(width: 60, height: 3)
                    }
                    
                    if file.isLiveStream {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 6, height: 6)
                            Text(platformShellString("LIVE"))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.red)
                        }
                    } else {
                        Text(progressText)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                }
                
                if let progTitle = liveProgramTitle {
                    Text(progTitle)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(isPlaying ? .blue : Color.accentColor)
                        .lineLimit(1)
                } else if !secondaryMetadataLine.isEmpty {
                    Text(secondaryMetadataLine)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            if isPlaying {
                Image(systemName: "waveform")
                    .foregroundColor(.blue)
                    .font(.system(size: 11))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isPlaying ? Color.blue.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .macListHoverEffect()
        .onAppear {
            loadProgress()
            loadSupplementalMetadataIfNeeded()
        }
        .onChange(of: playbackService.duration) { _ in
            if isPlaying {
                loadProgress()
            }
        }
    }

    private func loadProgress() {
        let url = file.url
        
        if let pos = HistoryService.shared.getLastPlayedPosition(for: file), pos > 0 {
            self.lastPosition = pos
            if let histFile = HistoryService.shared.allHistory.first(where: { $0.url.path == url.path }),
               let dur = histFile.duration,
               dur > 0 {
                self.duration = dur
                self.progress = pos / dur
            } else if let fileDur = file.duration, fileDur > 0 {
                self.duration = fileDur
                self.progress = pos / fileDur
            } else if isPlaying, playbackService.duration > 0 {
                let maxDur = Double(playbackService.duration) / 1000.0
                self.duration = maxDur
                self.progress = pos / maxDur
            }
        } else if let fileDur = file.duration, fileDur > 0 {
            self.duration = fileDur
            if let pos = file.lastPlayedPosition {
                self.lastPosition = pos
                self.progress = pos / fileDur
            }
        } else if isPlaying, playbackService.duration > 0 {
            let maxDur = Double(playbackService.duration) / 1000.0
            self.duration = maxDur
            let currentTime = Double(playbackService.currentTime) / 1000.0
            self.lastPosition = currentTime
            self.progress = currentTime / maxDur
        }
    }
    
    private func loadSupplementalMetadataIfNeeded() {
        guard !didRequestLocalMetadata else { return }
        didRequestLocalMetadata = true
        
        if let streams = file.serverMediaStreams {
            resolvedResolution = videoResolution(from: streams)
            resolvedCodec = preferredCodec(from: streams)
        }
        
        let knownSize = file.serverSize ?? file.size
        if knownSize > 0 {
            resolvedFileSize = knownSize
        }
        
        guard file.url.isFileURL else { return }
        
        DispatchQueue.global(qos: .utility).async {
            let resourceValues = try? file.url.resourceValues(forKeys: [.fileSizeKey])
            let localSize = Int64(resourceValues?.fileSize ?? 0)
            
            let asset = AVURLAsset(url: file.url)
            let assetDuration = asset.duration.seconds
            
            var resolution: String?
            var codec: String?
            
            if file.type == .video, let videoTrack = asset.tracks(withMediaType: .video).first {
                let transformedSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
                let width = Int(abs(transformedSize.width))
                let height = Int(abs(transformedSize.height))
                if width > 0 && height > 0 {
                    resolution = "\(width)x\(height)"
                }
                if let formatDescription = videoTrack.formatDescriptions.first {
                    let desc = formatDescription as! CMFormatDescription
                    let mediaType = CMFormatDescriptionGetMediaType(desc)
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                    if mediaType == kCMMediaType_Video {
                        if mediaSubType == kCMVideoCodecType_H264 { codec = "H264" }
                        else if mediaSubType == kCMVideoCodecType_HEVC { codec = "HEVC" }
                        else { codec = String(format: "%C%C%C%C",
                                              UInt8((mediaSubType >> 24) & 0xff),
                                              UInt8((mediaSubType >> 16) & 0xff),
                                              UInt8((mediaSubType >> 8) & 0xff),
                                              UInt8(mediaSubType & 0xff)).trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                }
            } else if file.type == .audio, let audioTrack = asset.tracks(withMediaType: .audio).first {
                if let formatDescription = audioTrack.formatDescriptions.first {
                    let desc = formatDescription as! CMFormatDescription
                    let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                    codec = String(format: "%C%C%C%C",
                                   UInt8((mediaSubType >> 24) & 0xff),
                                   UInt8((mediaSubType >> 16) & 0xff),
                                   UInt8((mediaSubType >> 8) & 0xff),
                                   UInt8(mediaSubType & 0xff)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            
            DispatchQueue.main.async {
                if self.resolvedFileSize == 0, localSize > 0 {
                    self.resolvedFileSize = localSize
                }
                if self.duration <= 0, assetDuration.isFinite, assetDuration > 0 {
                    self.duration = assetDuration
                    if self.lastPosition > 0 {
                        self.progress = self.lastPosition / assetDuration
                    }
                }
                if self.resolvedResolution == nil {
                    self.resolvedResolution = resolution
                }
                if self.resolvedCodec == nil {
                    self.resolvedCodec = codec
                }
            }
        }
    }
    
    private func videoResolution(from streams: [[String: Any]]) -> String? {
        guard let stream = streams.first(where: { (($0["Type"] as? String) ?? "").caseInsensitiveCompare("Video") == .orderedSame }) else {
            return nil
        }
        guard let width = stream["Width"] as? Int,
              let height = stream["Height"] as? Int,
              width > 0,
              height > 0 else {
            return nil
        }
        return "\(width)x\(height)"
    }
    
    private func preferredCodec(from streams: [[String: Any]]) -> String? {
        if let videoStream = streams.first(where: { (($0["Type"] as? String) ?? "").caseInsensitiveCompare("Video") == .orderedSame }),
           let codec = videoStream["Codec"] as? String, !codec.isEmpty {
            return codec
        }
        if let audioStream = streams.first(where: { (($0["Type"] as? String) ?? "").caseInsensitiveCompare("Audio") == .orderedSame }),
           let codec = audioStream["Codec"] as? String, !codec.isEmpty {
            return codec
        }
        return nil
    }
    
    private func formatDuration(_ ms: Int32) -> String {
        guard ms > 0 else { return "00:00" }
        let seconds = ms / 1000
        let s = seconds % 60
        let m = (seconds / 60) % 60
        let h = seconds / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }
}

private struct MacDarkConfigSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundColor(.gray)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(12)
            .background(Color.white.opacity(0.08))
            .cornerRadius(10)
        }
    }
}

public enum MacPlaybackSequenceMode: String, CaseIterable {
    case sequential
    case shuffle
    case repeatOne

    var icon: String {
        switch self {
        case .sequential: return "repeat"
        case .shuffle: return "shuffle"
        case .repeatOne: return "repeat.1"
        }
    }

    var title: String {
        switch self {
        case .sequential: return platformShellString("Sequential")
        case .shuffle: return platformShellString("Shuffle")
        case .repeatOne: return platformShellString("Repeat One")
        }
    }
}

struct MacMediaInfoSection: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let items: [(key: String, value: String)]
}

struct MacPlayerInfoSidebar: View {
    let file: VideoFile
    @ObservedObject var playbackService: MacVLCPlaybackService
    let thumbnailURL: URL?
    let playbackServer: ServerConfig?
    let currentPlaylist: [VideoFile]?
    let onClose: () -> Void

    private var mpvCacheStatusText: String {
        let speed: String
        if playbackService.cacheReadIdle {
            speed = String(format: platformShellString("MPV.Cache.Speed"), "0 B") + " (" + platformShellString("MPV.Cache.Idle") + ")"
        } else if let rate = playbackService.cacheInputBytesPerSecond {
            speed = String(format: platformShellString("MPV.Cache.Speed"),
                           ByteCountFormatter.string(fromByteCount: rate, countStyle: .file))
        } else {
            speed = platformShellString("MPV.Cache.SpeedUnavailable")
        }
        let ahead = MPVBufferedRange.aheadSeconds(playbackService.bufferedRanges,
            time: Double(playbackService.currentTime) / 1000, duration: Double(playbackService.duration) / 1000)
        let cached = ahead.map { String(format: platformShellString("MPV.Cache.Ahead"), Int(min($0, Double(Int32.max)))) }
            ?? platformShellString("MPV.Cache.RangeUnavailable")
        let storage: String
        switch playbackService.diskCacheMode {
        case .inactive: storage = ""
        case .disk:
            storage = String(format: platformShellString("MPV.Cache.Disk"),
                ByteCountFormatter.string(fromByteCount: playbackService.diskCacheBytes, countStyle: .file))
        case .memory:
            let retained = playbackService.diskCacheBytes > 0
                ? " · " + String(format: platformShellString("MPV.Cache.Disk"),
                    ByteCountFormatter.string(fromByteCount: playbackService.diskCacheBytes, countStyle: .file)) : ""
            let reason = playbackService.diskCacheReason.map { " (" + platformShellString($0.localizationKey) + ")" } ?? ""
            storage = platformShellString("MPV.Cache.Memory") + reason + retained
        }
        return [speed, cached, storage].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var fallbackArtworkCard: some View {
        Color.white.opacity(0.08)
            .frame(height: 150)
            .cornerRadius(8)
            .overlay(
                Image(systemName: file.type == .audio ? "music.note" : "film")
                    .font(.system(size: 40))
                    .foregroundColor(.white.opacity(0.4))
            )
    }

    private var infoSections: [MacMediaInfoSection] {
        var sections: [MacMediaInfoSection] = []
        let hasServerStreams = !(file.serverMediaStreams ?? []).isEmpty
        
        // 1. General Section
        var general: [(key: String, value: String)] = []
        
        general.append((key: platformShellString("Title"), value: file.name))
        
        func normalized(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }
        
        func appendMetadataRow(_ key: String, value: String?) {
            guard let value = normalized(value) else { return }
            general.append((key: key, value: value))
        }
        
        // Read from VLCMedia metadata if available
        let meta = playbackService.mediaPlayer?.media?.metaData
        let preferredArtist = playbackService.isUsingMPV
            ? normalized(playbackService.mpvMetadata["artist"]) ?? normalized(playbackService.mpvMetadata["albumArtist"])
            : normalized(meta?.artist) ?? normalized(meta?.albumArtist)
            
        appendMetadataRow(platformShellString("Artist"), value: preferredArtist)
        appendMetadataRow(platformShellString("Album"), value: playbackService.isUsingMPV ? playbackService.mpvMetadata["album"] : meta?.album)
        
        let displayPath = file.serverPath ?? file.url.path
        general.append((key: platformShellString("Path"), value: displayPath))
        
        let container = file.serverContainer ?? file.url.pathExtension.uppercased()
        if !container.isEmpty {
            general.append((key: platformShellString("Container"), value: container.uppercased()))
        }
        
        if let qualityID = file.preferredPlaybackQualityID {
            general.append((
                key: platformShellString("Requested Quality"),
                value: RemotePlaybackQualityCatalog.currentOptionTitle(from: qualityID)
            ))
        }
        
        if let method = file.remotePlaybackMethod {
            general.append((
                key: platformShellString("Play Method"),
                value: localizedPlaybackMethod(method)
            ))
        }
        
        if let playbackResolution = currentPlaybackResolutionDisplay() {
            general.append((
                key: hasServerStreams
                    ? platformShellString("Playback Resolution")
                    : platformShellString("Resolution"),
                value: playbackResolution
            ))
        }
        
        if playbackService.duration > 0 {
            general.append((key: platformShellString("Duration"), value: formatDuration(playbackService.duration)))
        }
        
        let size = file.serverSize ?? file.size
        if size > 0 {
            general.append((key: platformShellString("Size"), value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))
        }
        
        if !hasServerStreams {
            let bitrate = file.serverBitrate ?? 0
            if bitrate > 0 {
                general.append((key: platformShellString("Bitrate"), value: "\(bitrate / 1000) kbps"))
            }
        }
        
        if !general.isEmpty {
            sections.append(MacMediaInfoSection(title: platformShellString("General"), icon: "info.circle.fill", items: general))
        }
        
        if file.type == .video, playbackService.isUsingMPV, playbackService.mpvHDRInfo.isHDR {
            sections.append(MacMediaInfoSection(title: platformShellString("HDR.Info.Title"), icon: "sun.max.fill",
                items: playbackService.mpvHDRInfo.rows(localize: platformShellString)))
        }

        // 2. Server-provided rich media streams (Jellyfin/Emby)
        if let streams = file.serverMediaStreams, !streams.isEmpty {
            let typeOrder: [String: Int] = ["Video": 0, "Audio": 1, "Subtitle": 2]
            let sortedStreams = streams.sorted { a, b in
                let typeA = (a["Type"] as? String) ?? ""
                let typeB = (b["Type"] as? String) ?? ""
                return (typeOrder[typeA] ?? 3) < (typeOrder[typeB] ?? 3)
            }
            
            var videoIndex = 0
            var audioIndex = 0
            var subtitleIndex = 0
            
            let videoCount = sortedStreams.filter { ($0["Type"] as? String) == "Video" }.count
            let audioCount = sortedStreams.filter { ($0["Type"] as? String) == "Audio" }.count
            let subtitleCount = sortedStreams.filter { ($0["Type"] as? String) == "Subtitle" }.count
            
            for stream in sortedStreams {
                let streamType = (stream["Type"] as? String) ?? ""
                
                if streamType == "Video" {
                    videoIndex += 1
                    var items: [(key: String, value: String)] = []
                    if let title = stream["DisplayTitle"] as? String, !title.isEmpty {
                        items.append((key: platformShellString("Title"), value: title))
                    }
                    if let codec = stream["Codec"] as? String, !codec.isEmpty {
                        items.append((key: platformShellString("Codec"), value: codec.uppercased()))
                    }
                    if let w = stream["Width"] as? Int, let h = stream["Height"] as? Int, w > 0 {
                        items.append((key: platformShellString("Resolution"), value: "\(w)x\(h)"))
                    }
                    if let bitrate = stream["BitRate"] as? Int, bitrate > 0 {
                        items.append((key: platformShellString("Bitrate"), value: "\(bitrate / 1000) kbps"))
                    }
                    if let fps = stream["RealFrameRate"] as? Double, fps > 0 {
                        items.append((key: platformShellString("Framerate"), value: String(format: "%.3f fps", fps)))
                    }
                    let sectionTitle = videoCount > 1 ? "\(platformShellString("Video")) \(videoIndex)" : platformShellString("Video")
                    sections.append(MacMediaInfoSection(title: sectionTitle, icon: "film.fill", items: items))
                    
                } else if streamType == "Audio" {
                    audioIndex += 1
                    var items: [(key: String, value: String)] = []
                    if let title = stream["DisplayTitle"] as? String, !title.isEmpty {
                        items.append((key: platformShellString("Title"), value: title))
                    }
                    if let lang = stream["Language"] as? String, !lang.isEmpty {
                        items.append((key: platformShellString("Language"), value: lang))
                    }
                    if let codec = stream["Codec"] as? String, !codec.isEmpty {
                        items.append((key: platformShellString("Codec"), value: codec.uppercased()))
                    }
                    if let layout = stream["ChannelLayout"] as? String, !layout.isEmpty {
                        items.append((key: platformShellString("Layout"), value: layout))
                    }
                    if let channels = stream["Channels"] as? Int, channels > 0 {
                        items.append((key: platformShellString("Channels"), value: "\(channels) ch"))
                    }
                    if let rate = stream["SampleRate"] as? Int, rate > 0 {
                        items.append((key: platformShellString("Sample Rate"), value: "\(rate) Hz"))
                    }
                    let sectionTitle = audioCount > 1 ? "\(platformShellString("Audio")) \(audioIndex)" : platformShellString("Audio")
                    sections.append(MacMediaInfoSection(title: sectionTitle, icon: "speaker.wave.2.fill", items: items))
                    
                } else if streamType == "Subtitle" {
                    subtitleIndex += 1
                    var items: [(key: String, value: String)] = []
                    if let title = stream["DisplayTitle"] as? String, !title.isEmpty {
                        items.append((key: platformShellString("Title"), value: title))
                    }
                    if let lang = stream["Language"] as? String, !lang.isEmpty {
                        items.append((key: platformShellString("Language"), value: lang))
                    }
                    if let codec = stream["Codec"] as? String, !codec.isEmpty {
                        items.append((key: platformShellString("Codec"), value: codec.uppercased()))
                    }
                    let sectionTitle = subtitleCount > 1 ? "\(platformShellString("Subtitle")) \(subtitleIndex)" : platformShellString("Subtitle")
                    sections.append(MacMediaInfoSection(title: sectionTitle, icon: "captions.bubble.fill", items: items))
                }
            }
        } else {
            // Fallback for local files: use VLC track names
            if !playbackService.audioTracks.isEmpty {
                for (i, track) in playbackService.audioTracks.enumerated() {
                    let items: [(key: String, value: String)] = [
                        (key: platformShellString("Title"), value: track.name)
                    ]
                    let title = playbackService.audioTracks.count > 1 ? "\(platformShellString("Audio")) \(i + 1)" : platformShellString("Audio")
                    sections.append(MacMediaInfoSection(title: title, icon: "speaker.wave.2.fill", items: items))
                }
            }
            if !playbackService.subtitleTracks.isEmpty {
                let selectableTracks = playbackService.subtitleTracks.filter { $0.id != -1 }
                for (i, track) in selectableTracks.enumerated() {
                    let items: [(key: String, value: String)] = [
                        (key: platformShellString("Title"), value: track.name)
                    ]
                    let title = selectableTracks.count > 1 ? "\(platformShellString("Subtitle")) \(i + 1)" : platformShellString("Subtitle")
                    sections.append(MacMediaInfoSection(title: title, icon: "captions.bubble.fill", items: items))
                }
            }
        }
        
        // Server Section (Remote only)
        if file.isRemote {
            var serverItems: [(key: String, value: String)] = []
            if let serverId = file.jellyfinServerId {
                serverItems.append((key: platformShellString("Server ID"), value: serverId))
            }
            if let itemId = file.jellyfinItemId {
                serverItems.append((key: platformShellString("Item ID"), value: itemId))
            }
            if let serverType = file.serverType {
                serverItems.append((key: platformShellString("Type"), value: serverType.displayName))
            }
            if !serverItems.isEmpty {
                sections.append(MacMediaInfoSection(title: platformShellString("Server Info"), icon: "network", items: serverItems))
            }
        }
        
        return sections
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    if let thumb = thumbnailURL {
                        MacCachedAsyncImage(url: thumb) { phase in
                            if let image = phase.image {
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .cornerRadius(8)
                            } else if phase.error != nil {
                                fallbackArtworkCard
                            } else {
                                ProgressView().frame(height: 150)
                            }
                        }
                    } else if let vlcArtwork = playbackService.playbackArtwork {
                        Image(nsImage: vlcArtwork)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .cornerRadius(8)
                    } else if let playbackServer = playbackServer {
                        MacRemoteFileImage(file: file, server: playbackServer, siblingFiles: currentPlaylist)
                            .frame(height: 150)
                            .frame(maxWidth: .infinity)
                    } else {
                        fallbackArtworkCard
                    }
                    
                    Text(file.name)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    
                    if playbackService.isUsingMPV && file.isRemote {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(platformShellString("Cache"), systemImage: "internaldrive")
                                .font(.subheadline.weight(.medium))
                            Text(mpvCacheStatusText)
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color.white.opacity(0.06))
                        .cornerRadius(8)
                    }

                    ForEach(infoSections) { section in
                        MacDarkInfoSection(title: section.title, icon: section.icon, items: section.items)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 320)
        .background(Material.ultraThin)
        .edgesIgnoringSafeArea(.bottom)
    }

    private func formatDuration(_ ms: Int32) -> String {
        guard ms > 0 else { return "--:--" }
        let seconds = ms / 1000
        let s = seconds % 60
        let m = (seconds / 60) % 60
        let h = seconds / 3600
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private func localizedPlaybackMethod(_ method: RemotePlaybackMethod) -> String {
        switch method {
        case .directPlay:
            return platformShellString("Direct Play")
        case .directStream:
            return platformShellString("Direct Stream")
        case .transcode:
            return platformShellString("Transcode")
        }
    }
    
    private func currentPlaybackResolutionDisplay() -> String? {
        let videoSize = playbackService.videoNaturalSize
        if videoSize.width > 0 && videoSize.height > 0 {
            return "\(Int(videoSize.width))x\(Int(videoSize.height))"
        }

        guard let streams = file.serverMediaStreams else { return nil }
        guard let videoStream = streams.first(where: { (($0["Type"] as? String) ?? "").caseInsensitiveCompare("Video") == .orderedSame }) else {
            return nil
        }

        let width = videoStream["Width"] as? Int ?? 0
        let height = videoStream["Height"] as? Int ?? 0
        guard width > 0 && height > 0 else { return nil }
        return "\(width)x\(height)"
    }
}
struct TrackingAreaView: NSViewRepresentable {
    let onHover: (CGPoint?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = TrackingNSView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? TrackingNSView {
            view.onHover = onHover
        }
    }

    class TrackingNSView: NSView {
        var onHover: ((CGPoint?) -> Void)?
        private var trackingArea: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? {
            return nil
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let trackingArea = trackingArea {
                removeTrackingArea(trackingArea)
                self.trackingArea = nil
            }
            if let window = window {
                let options: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect]
                let newTrackingArea = NSTrackingArea(rect: .zero, options: options, owner: self, userInfo: nil)
                addTrackingArea(newTrackingArea)
                trackingArea = newTrackingArea
                
                checkMouseLocation(in: window)
            }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let window = self.window {
                checkMouseLocation(in: window)
            }
        }

        override func mouseEntered(with event: NSEvent) {
            reportLocation(event: event)
        }

        override func mouseMoved(with event: NSEvent) {
            reportLocation(event: event)
        }

        override func mouseExited(with event: NSEvent) {
            guard let window = self.window else {
                return
            }
            let mouseLoc = window.mouseLocationOutsideOfEventStream
            let localPoint = self.convert(mouseLoc, from: nil)
            if self.bounds.width > 0 && self.bounds.height > 0 && self.bounds.contains(localPoint) {
                return
            }
            onHover?(nil)
        }

        private func reportLocation(event: NSEvent) {
            let location = convert(event.locationInWindow, from: nil)
            onHover?(location)
        }

        private func checkMouseLocation(in window: NSWindow) {
            let mouseLoc = window.mouseLocationOutsideOfEventStream
            let localPoint = self.convert(mouseLoc, from: nil)
            if self.bounds.width > 0 && self.bounds.height > 0 && self.bounds.contains(localPoint) {
                onHover?(localPoint)
            }
        }
    }
}



struct MacPlayerProgressBar: View {
    @Binding var position: Double
    let duration: Double
    var bufferedRanges: [MPVBufferedRange] = []
    let onSeekStarted: () -> Void
    let onSeekChanged: (Double) -> Void
    let onSeekEnded: (Double) -> Void
    let onHoverChanged: (Double?) -> Void

    @State private var isHovering: Bool = false
    @State private var isDragging: Bool = false
    @State private var dragPosition: Double? = nil

    var body: some View {
        GeometryReader { proxy in
            let totalWidth = max(1, proxy.size.width)
            let currentFraction = min(max(isDragging ? (dragPosition ?? position) : position, 0), 1)
            let barHeight: CGFloat = (isHovering || isDragging) ? 6 : 4
            let knobSize: CGFloat = (isHovering || isDragging) ? 14 : 10

            ZStack(alignment: .leading) {
                // Invisible extended interactive height
                Rectangle()
                    .fill(Color.clear)
                    .frame(height: 24)
                    .contentShape(Rectangle())

                // Track Background
                Capsule()
                    .fill(Color.black.opacity(0.35))
                    .overlay(Capsule().fill(Color.white.opacity(0.16)))
                    .frame(height: barHeight)

                MPVBufferedTrack(ranges: bufferedRanges, duration: duration / 1000, highContrast: false)
                    .frame(height: barHeight)

                // Played Progress Bar
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(0, totalWidth * CGFloat(currentFraction)), height: barHeight)

                // Thumb Knob
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: Color.black.opacity(0.4), radius: 3, x: 0, y: 1)
                    .offset(x: max(0, min(totalWidth - knobSize, totalWidth * CGFloat(currentFraction) - knobSize / 2)))
            }
            .animation(.easeInOut(duration: 0.12), value: isHovering)
            .animation(.easeInOut(duration: 0.12), value: isDragging)
            .overlay(
                TrackingAreaView { location in
                    if let location = location {
                        isHovering = true
                        let fraction = min(max(Double(location.x / totalWidth), 0), 1)
                        onHoverChanged(fraction)
                    } else {
                        isHovering = false
                        if !isDragging {
                            onHoverChanged(nil)
                        }
                    }
                }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onSeekStarted()
                        }
                        let fraction = min(max(Double(value.location.x / totalWidth), 0), 1)
                        dragPosition = fraction
                        onSeekChanged(fraction)
                        onHoverChanged(fraction)
                    }
                    .onEnded { value in
                        let fraction = min(max(Double(value.location.x / totalWidth), 0), 1)
                        dragPosition = nil
                        isDragging = false
                        onSeekEnded(fraction)
                        if !isHovering {
                            onHoverChanged(nil)
                        }
                    }
            )
        }
        .frame(height: 20)
    }
}

struct MacSubtitleSelector: View {
    @ObservedObject var playbackService: MacVLCPlaybackService
    let onImportExternalSubtitle: () -> Void
    var onBrowseSubtitles: (() -> Void)? = nil
    var onAction: ((String, String) -> Void)? = nil
    @Environment(\.presentationMode) var presentationMode
    @AppStorage("enableSecondarySubtitlesBeta") private var enableSecondarySubtitlesBeta: Bool = false

    enum SubtitleType: String, CaseIterable, Identifiable {
        case primary = "Primary"
        case secondary = "Secondary"
        var id: String { rawValue }
    }

    @State private var currentTab: SubtitleType = .primary
    private let trackRowHeight: CGFloat = 32

    private var canOfferTranslation: Bool {
        if #available(macOS 15.0, *) {
            return playbackService.hasPrimarySubtitleForTranslation || playbackService.audioSubtitles.translatesAudio
        }
        return false
    }

    private var showsTranslationControls: Bool {
        enableSecondarySubtitlesBeta && currentTab == .secondary && canOfferTranslation
            && playbackService.currentSecondarySubtitleTrackID == MacSubtitleTranslation.trackID
    }

    var body: some View {
        VStack(spacing: 0) {
            if let onBrowseSubtitles, playbackService.currentFile?.type == .video {
                Button(platformShellString("SB.Title"), action: onBrowseSubtitles)
                    .padding(12)
                Divider()
            }
            if enableSecondarySubtitlesBeta {
                Picker("", selection: $currentTab) {
                    ForEach(SubtitleType.allCases) { tab in
                        Text(platformShellString(tab.rawValue)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(16)
            }

            if !enableSecondarySubtitlesBeta || currentTab == .primary {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        trackButton(title: platformShellString("Off"), id: -1, currentID: playbackService.currentSubtitleTrackID) {
                            playbackService.audioSubtitles.noteManualSubtitleSelection()
                            playbackService.setSubtitleTrack(-1)
                            onAction?("captions.bubble", platformShellString("Off"))
                        }
                        if playbackService.audioSubtitles.canDisplay {
                            trackButton(title: playbackService.generatedSubtitleName, id: MacAudioSubtitlePlan.primaryID,
                                        currentID: playbackService.currentSubtitleTrackID) {
                                playbackService.setSubtitleTrack(MacAudioSubtitlePlan.primaryID)
                            }
                        }
                        ForEach(playbackService.subtitleTracks) { track in
                            trackButton(title: track.name, id: track.id, currentID: playbackService.currentSubtitleTrackID) {
                                playbackService.audioSubtitles.noteManualSubtitleSelection()
                                playbackService.setSubtitleTrack(track.id)
                                onAction?("captions.bubble.fill", track.name)
                            }
                            .disabled(!playbackService.canSelectMPVSubtitle(track.id, secondary: false))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .frame(height: listHeight(rows: playbackService.subtitleTracks.count + (playbackService.audioSubtitles.canDisplay ? 2 : 1), limit: 300))
                .clipped()
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    trackButton(title: platformShellString("Off"), id: nil as String?, currentID: playbackService.currentSecondarySubtitleTrackID) {
                        playbackService.audioSubtitles.noteManualSubtitleSelection()
                        playbackService.setSecondarySubtitleTrack(nil)
                        onAction?("character.bubble", platformShellString("Off"))
                    }
                    if playbackService.audioSubtitles.canDisplay {
                        trackButton(title: playbackService.generatedSubtitleName, id: MacAudioSubtitlePlan.secondaryID as String?,
                                    currentID: playbackService.currentSecondarySubtitleTrackID) {
                            playbackService.setSecondarySubtitleTrack(MacAudioSubtitlePlan.secondaryID)
                        }
                    }
                    if canOfferTranslation {
                        trackButton(title: platformShellString(playbackService.audioSubtitles.translatesAudio ? "SI.TranslatedSecondary" : "Translation.Primary"), id: MacSubtitleTranslation.trackID as String?, currentID: playbackService.currentSecondarySubtitleTrackID) {
                            playbackService.audioSubtitles.noteManualSubtitleSelection()
                            playbackService.setSecondarySubtitleTrack(MacSubtitleTranslation.trackID)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                if showsTranslationControls {
                    Divider()
                    MacSubtitleTranslationControls(model: playbackService.subtitleTranslation)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(16)
                }

                if !playbackService.secondarySubtitleTracks.isEmpty {
                    Divider()
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(playbackService.secondarySubtitleTracks) { track in
                                trackButton(title: track.displayName, id: track.id as String?, currentID: playbackService.currentSecondarySubtitleTrackID) {
                                    playbackService.audioSubtitles.noteManualSubtitleSelection()
                                    playbackService.setSecondarySubtitleTrack(track.id)
                                    onAction?("character.bubble.fill", track.displayName)
                                }
                                .disabled(!playbackService.canSelectMPVSubtitle(track.primaryTrackID ?? -1, secondary: true))
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .frame(height: listHeight(rows: playbackService.secondarySubtitleTracks.count,
                                              limit: showsTranslationControls ? 160 : 300))
                    .clipped()
                }
            }

            if playbackService.currentFile?.type == .video {
                Divider()
                Button(platformShellString("AS.Title")) {
                    playbackService.showAudioSubtitleSheet = true
                    presentationMode.wrappedValue.dismiss()
                }
                .padding(12)
            }
            Divider()
            Button {
                onImportExternalSubtitle()
                presentationMode.wrappedValue.dismiss()
            } label: {
                HStack {
                    Text(platformShellString("Load Subtitle File"))
                    Spacer()
                    Image(systemName: "plus.rectangle.on.folder")
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .macListHoverEffect()
            .padding(.bottom, 8)
        }
        .frame(width: enableSecondarySubtitlesBeta ? 320 : 250)
        .fixedSize(horizontal: false, vertical: true)
        .transaction { $0.animation = nil }
    }

    private func listHeight(rows: Int, limit: CGFloat) -> CGFloat {
        min(CGFloat(rows) * trackRowHeight + 16, limit)
    }

    @ViewBuilder
    private func trackButton<T: Equatable>(title: String, id: T, currentID: T, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .lineLimit(1)
                Spacer()
                if id == currentID {
                    Image(systemName: "checkmark")
                }
            }
            .frame(height: trackRowHeight)
            .padding(.horizontal, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .macListHoverEffect()
    }
}

struct MacPlayerGestureView: NSViewRepresentable {
    let onSingleTap: () -> Void
    let onDoubleTap: () -> Void
    let onLongPressStart: () -> Void
    let onLongPressEnd: () -> Void
    
    func makeNSView(context: Context) -> NSView {
        let view = MacPlayerGestureNSView()
        view.onSingleTap = onSingleTap
        view.onDoubleTap = onDoubleTap
        view.onLongPressStart = onLongPressStart
        view.onLongPressEnd = onLongPressEnd
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        if let gestureView = nsView as? MacPlayerGestureNSView {
            gestureView.onSingleTap = onSingleTap
            gestureView.onDoubleTap = onDoubleTap
            gestureView.onLongPressStart = onLongPressStart
            gestureView.onLongPressEnd = onLongPressEnd
        }
    }
}

class MacPlayerGestureNSView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    
    var onSingleTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var onLongPressStart: (() -> Void)?
    var onLongPressEnd: (() -> Void)?
    
    private var longPressTimer: Timer?
    private var isLongPressing = false
    
    override func mouseDown(with event: NSEvent) {
        let startPoint = event.locationInWindow
        let startTime = event.timestamp
        isLongPressing = false
        
        if event.clickCount == 2 {
            onDoubleTap?()
            return
        }
        
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.isLongPressing = true
            self.onLongPressStart?()
        }
        
        if let window = self.window {
            window.performDrag(with: event)
            
            longPressTimer?.invalidate()
            longPressTimer = nil
            
            if isLongPressing {
                onLongPressEnd?()
            } else {
                let endPoint = window.mouseLocationOutsideOfEventStream
                let dx = endPoint.x - startPoint.x
                let dy = endPoint.y - startPoint.y
                let dist = sqrt(dx*dx + dy*dy)
                let timeDiff = (NSApp.currentEvent?.timestamp ?? event.timestamp) - startTime
                
                if dist < 5 && timeDiff < 0.35 {
                    onSingleTap?()
                }
            }
        }
    }
}

struct MacPlayerLayoutMenuButton: View {
    var body: some View {
        Button {
            showMenu()
        } label: {
            Image(systemName: "rectangle.split.2x2")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
                .macHoverEffect()
        }
        .buttonStyle(.plain)
        .help(platformShellString("Player Window Layout"))
    }
    
    private func showMenu() {
        let menu = NSMenu()
        
        // 1. Tile Horizontally (Keep Aspect)
        let horizSub = NSMenu()
        let alignTop = NSMenuItem(title: platformShellString("Align Top"), action: #selector(MacPlayerMenuActionHandler.alignTop), keyEquivalent: "")
        alignTop.image = NSImage(systemSymbolName: "arrow.up.to.line", accessibilityDescription: nil)
        alignTop.target = MacPlayerMenuActionHandler.shared
        horizSub.addItem(alignTop)
        
        let alignCenterH = NSMenuItem(title: platformShellString("Align Center"), action: #selector(MacPlayerMenuActionHandler.alignCenterH), keyEquivalent: "")
        alignCenterH.image = NSImage(systemSymbolName: "align.vertical.center", accessibilityDescription: nil)
        alignCenterH.target = MacPlayerMenuActionHandler.shared
        horizSub.addItem(alignCenterH)
        
        let alignBottom = NSMenuItem(title: platformShellString("Align Bottom"), action: #selector(MacPlayerMenuActionHandler.alignBottom), keyEquivalent: "")
        alignBottom.image = NSImage(systemSymbolName: "arrow.down.to.line", accessibilityDescription: nil)
        alignBottom.target = MacPlayerMenuActionHandler.shared
        horizSub.addItem(alignBottom)
        
        let horizItem = NSMenuItem(title: platformShellString("Tile Horizontally (Keep Aspect)"), action: nil, keyEquivalent: "")
        horizItem.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        horizItem.submenu = horizSub
        menu.addItem(horizItem)
        
        // 2. Tile Vertically (Keep Aspect)
        let vertSub = NSMenu()
        let alignLeft = NSMenuItem(title: platformShellString("Align Left"), action: #selector(MacPlayerMenuActionHandler.alignLeft), keyEquivalent: "")
        alignLeft.image = NSImage(systemSymbolName: "arrow.left.to.line", accessibilityDescription: nil)
        alignLeft.target = MacPlayerMenuActionHandler.shared
        vertSub.addItem(alignLeft)
        
        let alignCenterV = NSMenuItem(title: platformShellString("Align Center"), action: #selector(MacPlayerMenuActionHandler.alignCenterV), keyEquivalent: "")
        alignCenterV.image = NSImage(systemSymbolName: "align.horizontal.center", accessibilityDescription: nil)
        alignCenterV.target = MacPlayerMenuActionHandler.shared
        vertSub.addItem(alignCenterV)
        
        let alignRight = NSMenuItem(title: platformShellString("Align Right"), action: #selector(MacPlayerMenuActionHandler.alignRight), keyEquivalent: "")
        alignRight.image = NSImage(systemSymbolName: "arrow.right.to.line", accessibilityDescription: nil)
        alignRight.target = MacPlayerMenuActionHandler.shared
        vertSub.addItem(alignRight)
        
        let vertItem = NSMenuItem(title: platformShellString("Tile Vertically (Keep Aspect)"), action: nil, keyEquivalent: "")
        vertItem.image = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: nil)
        vertItem.submenu = vertSub
        menu.addItem(vertItem)
        
        menu.addItem(NSMenuItem.separator())
        
        // 3. Tile Horizontally (Fill Screen)
        let horizFull = NSMenuItem(title: platformShellString("Tile Horizontally (Fill Screen)"), action: #selector(MacPlayerMenuActionHandler.tileHorizontalFull), keyEquivalent: "")
        horizFull.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
        horizFull.target = MacPlayerMenuActionHandler.shared
        menu.addItem(horizFull)
        
        // 4. Tile Vertically (Fill Screen)
        let vertFull = NSMenuItem(title: platformShellString("Tile Vertically (Fill Screen)"), action: #selector(MacPlayerMenuActionHandler.tileVerticalFull), keyEquivalent: "")
        vertFull.image = NSImage(systemSymbolName: "rectangle.split.1x2", accessibilityDescription: nil)
        vertFull.target = MacPlayerMenuActionHandler.shared
        menu.addItem(vertFull)
        
        // 5. Tile Grid
        let grid = NSMenuItem(title: platformShellString("Tile Grid"), action: #selector(MacPlayerMenuActionHandler.tileGrid), keyEquivalent: "")
        grid.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        grid.target = MacPlayerMenuActionHandler.shared
        menu.addItem(grid)
        
        menu.addItem(NSMenuItem.separator())
        
        // 6. Cascade Windows
        let cascade = NSMenuItem(title: platformShellString("Cascade Windows"), action: #selector(MacPlayerMenuActionHandler.cascade), keyEquivalent: "")
        cascade.image = NSImage(systemSymbolName: "rectangle.on.rectangle", accessibilityDescription: nil)
        cascade.target = MacPlayerMenuActionHandler.shared
        menu.addItem(cascade)
        
        // 7. Close Other Windows
        let closeOthers = NSMenuItem(title: platformShellString("Close Other Windows"), action: #selector(MacPlayerMenuActionHandler.closeOtherWindows), keyEquivalent: "")
        closeOthers.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: nil)
        closeOthers.target = MacPlayerMenuActionHandler.shared
        menu.addItem(closeOthers)
        
        menu.addItem(NSMenuItem.separator())
        
        // 8. Restore Original Layout
        let restore = NSMenuItem(title: platformShellString("Restore Original Layout"), action: #selector(MacPlayerMenuActionHandler.restore), keyEquivalent: "")
        restore.image = NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: nil)
        restore.target = MacPlayerMenuActionHandler.shared
        menu.addItem(restore)
        
        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }
}

@objc private class MacPlayerMenuActionHandler: NSObject {
    static let shared = MacPlayerMenuActionHandler()
    
    @objc func alignTop() { MacPlayerWindowManager.shared.arrangeWindows(style: .tileHorizontalAspect(vAlign: .top)) }
    @objc func alignCenterH() { MacPlayerWindowManager.shared.arrangeWindows(style: .tileHorizontalAspect(vAlign: .center)) }
    @objc func alignBottom() { MacPlayerWindowManager.shared.arrangeWindows(style: .tileHorizontalAspect(vAlign: .bottom)) }
    
    @objc func alignLeft() { MacPlayerWindowManager.shared.arrangeWindows(style: .tileVerticalAspect(hAlign: .left)) }
    @objc func alignCenterV() { MacPlayerWindowManager.shared.arrangeWindows(style: .tileVerticalAspect(hAlign: .center)) }
    @objc func alignRight() { MacPlayerWindowManager.shared.arrangeWindows(style: .tileVerticalAspect(hAlign: .right)) }
    
    @objc func tileHorizontalFull() { MacPlayerWindowManager.shared.arrangeWindows(style: .tileHorizontalFull) }
    @objc func tileVerticalFull() { MacPlayerWindowManager.shared.arrangeWindows(style: .tileVerticalFull) }
    @objc func tileGrid() { MacPlayerWindowManager.shared.arrangeWindows(style: .tileGrid) }
    @objc func cascade() { MacPlayerWindowManager.shared.arrangeWindows(style: .cascade) }
    @objc func closeOtherWindows() { MacPlayerWindowManager.shared.closeOtherWindows(except: nil) }
    @objc func restore() { MacPlayerWindowManager.shared.arrangeWindows(style: .restoreOriginal) }
}
#endif
