import SwiftUI
import GenPlayerShell

struct AudioPlayerView: View {
    enum PlayMode: String, CaseIterable {
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
            case .sequential: return NSLocalizedString("Sequential", comment: "")
            case .shuffle: return NSLocalizedString("Shuffle", comment: "")
            case .repeatOne: return NSLocalizedString("Repeat One", comment: "")
            }
        }
    }

    @ObservedObject private var playbackService = VLCPlaybackService.shared
    let initialFile: VideoFile
    var playlist: [VideoFile]? = nil
    
    @Environment(\.presentationMode) var presentationMode
    
    @State private var isPlaylistLoaded: Bool = false
    @State private var loadedPlaylist: [VideoFile]? = nil
    @State private var loadedInitialIndex: Int = 0
    @State private var isDraggingSlider: Bool = false
    @State private var draggingTime: Double = 0
    @State private var showPlaylist: Bool = false
    @State private var showAudioInfo: Bool = false
    @State private var dominantColor: Color = Color(white: 0.15)
    @State private var lastProcessedArtwork: UIImage? = nil
    @State private var artworkColorRequest = UUID()
    @State private var currentPlaylistCount: Int = 1
    @State private var explicitCloseRequested = false
    @State private var activeMenuScreen: PlayerFloatingMenuScreen? = nil
    @State private var menuTriggerFrames: [PlayerFloatingMenuScreen: CGRect] = [:]
    @State private var safeAreaInsets: UIEdgeInsets = UIApplication.currentSafeAreaInsets()

    private var currentPlaylistIndex: Int {
        guard let playlist = loadedPlaylist,
              let currentItem = playbackService.state.currentItem else {
            return -1
        }

        return playlist.firstIndex { file in
            file.id == currentItem.id.uuidString ||
            file.id == currentItem.videoFile?.id ||
            file.name == currentItem.title ||
            playlistURLsMatch(file.url, currentItem.url)
        } ?? -1
    }
    
    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height * 1.25
            
            ZStack {
                SafeAreaInsetReader { insets in
                    if safeAreaInsets != insets {
                        safeAreaInsets = insets
                    }
                }
                .allowsHitTesting(false)

                // Background - dynamic color from artwork
                backgroundView
                
                if isLandscape {
                    VStack(spacing: 0) {
                        Spacer()

                        HStack(spacing: 40) {
                            // Left: Artwork
                            artworkView
                                .frame(width: min(geometry.size.height * 0.6, geometry.size.width * 0.4), height: min(geometry.size.height * 0.6, geometry.size.width * 0.4))
                                .padding(.leading, 40)

                            // Right: Controls
                            VStack(spacing: 20) {
                                Spacer()
                                trackInfoView
                                progressBarView
                                playbackControlsView(metrics: regularPlaybackControlsMetrics)
                                Spacer()
                            }
                            .padding(.trailing, 40)
                        }
                        
                        Spacer()
                    }
                } else {
                    // PORTRAIT LAYOUT
                    portraitLayoutView(for: geometry.size)
                }
                
                // Buffering Indicator (shows when loading/buffering and not playing)
                if (playbackService.isBuffering || !isPlaylistLoaded) && playbackService.activePlaybackFailure == nil && !playbackService.isPlaying {
                    if playbackService.loadingPhase == .waitingForChoice {
                        PlaybackLoadingOverlay(
                            phase: playbackService.loadingPhase,
                            onContinueWaiting: playbackService.continueWaitingForPlayback,
                            onRetry: retryPlaybackAfterFailure,
                            onClose: closePlayerAfterFailure
                        )
                        .zIndex(150)
                    } else {
                        VStack {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                            Text(NSLocalizedString(playbackService.loadingPhase == .slow
                                ? "Loading is taking longer than usual…" : "Loading...", comment: ""))
                                .foregroundColor(.white.opacity(0.7))
                                .font(.caption)
                                .padding(.top, 8)
                        }
                        .padding(20)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(12)
                    }
                }

                PlayerFloatingMenuOverlay(
                    playbackService: playbackService,
                    activeScreen: $activeMenuScreen,
                    triggerFrames: menuTriggerFrames,
                    onDismiss: dismissFloatingMenu
                )
            }
            .overlay(
                VStack {
                    if isLandscape {
                        CustomStatusBar()
                            .padding(.horizontal, 20)
                            .padding(.top, 8)
                            .ignoresSafeArea(.all, edges: .top)
                    }
                    Spacer()
                }
            )
        }
        .onPreferenceChange(PlayerMenuTriggerPreferenceKey.self) { frames in
            menuTriggerFrames = frames
        }
        .preferredColorScheme(.dark)
        .navigationBarTitle("", displayMode: .inline)
        .background(PlaybackFailureAlertPresenter(
            failure: playbackService.activePlaybackFailure,
            onRetry: retryPlaybackAfterFailure,
            onClose: closePlayerAfterFailure,
            onUseVLC: playbackService.canRecoverMPVWithVLC ? { playbackService.recoverMPVWithVLC() } : nil
        ))
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: {
                    explicitCloseRequested = true
                    playbackService.stop()
                    playbackService.hideFloatingAudio()
                    presentationMode.wrappedValue.dismiss()
                }) {
                    toolbarIcon("xmark", legacyWeight: .semibold)
                }
                
                Button(action: {
                    minimizePlayer()
                }) {
                    toolbarIcon("chevron.down", legacyWeight: .semibold)
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                AudioEngineMenu(
                    isUsingMPV: playbackService.isUsingMPV,
                    canSwitch: playbackService.canSwitchPlaybackEngine
                )
                .equatable()

                Button(action: { showAudioInfo = true }) {
                    toolbarIcon("info.circle")
                }

                Button(action: { showPlaylist = true }) {
                    toolbarIcon("list.bullet")
                }
            }
        }
        .onAppear {
            setupPlaylist()
            playbackService.onRequestNextTrack = { playbackService.playNextAudio() }
            playbackService.onRequestPreviousTrack = { playbackService.playPreviousAudio() }
            playbackService.onRequestSeekToTime = { time in
                playbackService.seek(to: time)
                return true
            }
            playbackService.updateRemoteSkipAvailability(canPrevious: playbackService.canPlayPreviousAudio, canNext: playbackService.canPlayNextAudio)
        }
        .onDisappear {
            dismissFloatingMenu()
            handleAudioPlayerDisappear()
        }
        .onReceive(playbackService.$state) { newState in
            let newArtwork = newState.currentItem?.artwork
            // Only recompute if artwork pointer actually changed
            if newArtwork !== lastProcessedArtwork {
                lastProcessedArtwork = newArtwork
                updateDominantColor(from: newArtwork)
            }

            playbackService.updateRemoteSkipAvailability(canPrevious: playbackService.canPlayPreviousAudio, canNext: playbackService.canPlayNextAudio)
        }
        .sheet(isPresented: $showPlaylist) {
            if let playlist = loadedPlaylist {
                PlaylistView(playbackService: playbackService, showPlaylist: $showPlaylist, playlist: playlist, onSelect: { index in
                     playbackService.playAudioItem(at: index)
                })
            } else { Text(NSLocalizedString("Loading...", comment: "")) }
        }
        .sheet(isPresented: $showAudioInfo) {
            VideoInfoView(playbackService: playbackService)
        }

    }
    
    @ViewBuilder
    private func toolbarIcon(
        _ systemName: String,
        style: AppToolbarIconStyle = .primary,
        legacyWeight: Font.Weight = .regular
    ) -> some View {
        if #available(iOS 26.0, *) {
            AppToolbarIcon(systemName: systemName, style: style)
        } else {
            // Preserve the original unframed audio toolbar labels on older iOS.
            Image(systemName: systemName)
                .font(.system(size: 20, weight: legacyWeight))
                .foregroundColor(.white)
        }
    }

    // MARK: - Actions
    
    private func minimizePlayer() {
        presentFloatingAudioIfNeeded()
        presentationMode.wrappedValue.dismiss()
    }

    private func presentFloatingAudioIfNeeded() {
        if let current = playbackService.state.currentItem {
            let file = current.videoFile ?? VideoFile(name: current.title, url: current.url, type: .audio, size: 0, date: Date(), isRemote: current.isRemote, duration: playbackService.state.duration, lastPlayedPosition: playbackService.state.currentTime)
            playbackService.showFloatingAudio(file: file, playlist: loadedPlaylist ?? [initialFile])
        }
    }

    private func handleAudioPlayerDisappear() {
        let shouldKeepFloating = !explicitCloseRequested

        if shouldKeepFloating && !showPlaylist && !playbackService.isAudioFloatingVisible {
            presentFloatingAudioIfNeeded()
        }

        if playbackService.isAudioFloatingVisible {
            playbackService.updateRemoteSkipAvailability(canPrevious: playbackService.canPlayPreviousAudio, canNext: playbackService.canPlayNextAudio)
        } else {
            playbackService.onRequestNextTrack = nil
            playbackService.onRequestPreviousTrack = nil
            playbackService.onRequestSeekToTime = nil
            playbackService.updateRemoteSkipAvailability(canPrevious: false, canNext: false)
        }

        if !showPlaylist && !playbackService.isAudioFloatingVisible {
            playbackService.stop()
        }
    }

    private func presentFloatingMenu(_ screen: PlayerFloatingMenuScreen) {
        playbackService.isMenuPresented = true
        activeMenuScreen = nil
        DispatchQueue.main.async {
            activeMenuScreen = screen
        }
    }

    private func dismissFloatingMenu() {
        activeMenuScreen = nil
        playbackService.isMenuPresented = false
        playbackService.flushDeferredTrackRefreshIfNeeded()
    }

    private func retryPlaybackAfterFailure() {
        playbackService.prepareForPlaybackRetry()
        if currentPlaylistIndex >= 0 {
            playbackService.playAudioItem(at: currentPlaylistIndex)
        } else {
            playbackService.retryCurrentItem()
        }
    }

    private func closePlayerAfterFailure() {
        playbackService.clearPlaybackFailure()
        explicitCloseRequested = true
        playbackService.stop()
        playbackService.hideFloatingAudio()
        presentationMode.wrappedValue.dismiss()
    }
    
    // MARK: - Background
    
    private var backgroundView: some View {
        ZStack {
            dominantColor
                .ignoresSafeArea()
            
            // Subtle gradient overlay for depth
            LinearGradient(
                colors: [
                    Color.black.opacity(0.1),
                    Color.black.opacity(0.3)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }
    
    // MARK: - Subviews
    
    private var artworkView: some View {
        Group {
            if let artwork = playbackService.state.currentItem?.artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.4), radius: 20, x: 0, y: 8)
            } else {
                // Placeholder artwork — Apple Music style
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Image(systemName: "music.note")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .padding(60)
                            .foregroundColor(.white.opacity(0.3))
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 20, x: 0, y: 8)
            }
        }
    }
    
    private var trackInfoView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(playbackService.state.currentItem?.title ?? initialFile.name)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .lineLimit(1)

                let subtitleText = (playbackService.displayedPrimarySubtitleParts + playbackService.currentSecondarySubtitleParts)
                    .compactMap { $0.text?.string }.joined(separator: "\n")
                if !subtitleText.isEmpty {
                    Text(subtitleText).font(.callout).foregroundColor(.white).lineLimit(3)
                }
                Text(audioSecondaryInfo)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.6))
                    .lineLimit(1)

                HStack(spacing: 10) {
                    Text(playbackService.state.duration > 0 ? playbackService.duration : NSLocalizedString("Unknown Duration", comment: ""))
                    Text("•")
                    Text(String(format: NSLocalizedString("%d tracks", comment: ""), currentPlaylistCount))
                }
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
            }
            
            Spacer()
        }
        .padding(.horizontal, 30)
    }

    private var audioSecondaryInfo: String {
        guard let item = playbackService.state.currentItem else {
            return NSLocalizedString("Audio File", comment: "")
        }

        let artist = (
            item.artist ??
            item.albumArtist ??
            item.author ??
            item.composer ??
            ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        let album = item.album?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !artist.isEmpty && !album.isEmpty {
            return "\(artist) — \(album)"
        }
        if !artist.isEmpty {
            return artist
        }
        if !album.isEmpty {
            return album
        }
        return NSLocalizedString("Audio File", comment: "")
    }

    private func portraitLayoutView(for size: CGSize) -> some View {
        let metrics = portraitLayoutMetrics(for: size)

        return VStack(spacing: 0) {
            Spacer(minLength: metrics.topSpacer)

            artworkView
                .frame(width: metrics.artworkSize, height: metrics.artworkSize)

            Spacer(minLength: metrics.middleSpacer)

            trackInfoView
                .padding(.bottom, metrics.infoBottomSpacing)

            progressBarView
                .padding(.horizontal, metrics.horizontalPadding)
                .padding(.bottom, metrics.progressBottomSpacing)

            playbackControlsView(metrics: metrics)
                .padding(.bottom, metrics.bottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    
    private var progressBarView: some View {
        VStack(spacing: 8) {
            AudioBufferedSlider(
                value: Binding(
                    get: { isDraggingSlider ? draggingTime : Double(playbackService.progress) },
                    set: { draggingTime = $0 }
                ),
                ranges: playbackService.bufferedRanges,
                duration: playbackService.maxDuration,
                onEditingChanged: { editing in
                    isDraggingSlider = editing
                    if !editing, playbackService.maxDuration > 0 {
                        playbackService.seek(to: draggingTime * playbackService.maxDuration)
                    }
                }
            )
            .frame(height: 31)
            
            HStack {
                Text(playbackService.currentTime)
                Spacer()
                if playbackService.state.currentItem?.isRemote == true, !playbackService.cacheReadIdle,
                   let rate = playbackService.cacheInputBytesPerSecond, rate > 0 {
                    Text("↓ " + ByteCountFormatter.string(fromByteCount: rate, countStyle: .file) + "/s")
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                Spacer()
                Text(playbackService.duration)
            }
            .font(.caption)
            .foregroundColor(.white.opacity(0.5))
        }
    }
    
    // MARK: - Playlist Logic
    
    private func playbackControlsView(metrics: AudioPlayerPortraitLayoutMetrics) -> some View {
        let shouldDisablePrimaryPlayPause =
            playbackService.isBuffering &&
            playbackService.state.currentItem?.isRemote == true

        return HStack {
            Button(action: {
                let allModes = AudioPlayMode.allCases
                let currentIndex = allModes.firstIndex(of: playbackService.audioPlayMode) ?? 0
                let nextIndex = (currentIndex + 1) % allModes.count
                playbackService.audioPlayMode = allModes[nextIndex]
            }) {
                Image(systemName: playbackService.audioPlayMode.icon)
                    .font(.system(size: metrics.secondaryButtonSize))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
            }
            
            Button(action: { 
                 _ = playbackService.playPreviousAudio()
            }) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: metrics.transportButtonSize))
                    .foregroundColor(playbackService.canPlayPreviousAudio ? .white : .white.opacity(0.3))
                    .frame(maxWidth: .infinity)
            }
            .disabled(!playbackService.canPlayPreviousAudio)
            
            Button(action: { playbackService.togglePlayPause() }) {
                Image(systemName: playbackService.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: metrics.primaryButtonSize))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
            }
            .disabled(shouldDisablePrimaryPlayPause)
            .opacity(shouldDisablePrimaryPlayPause ? 0.4 : 1.0)
            
            Button(action: { 
                 _ = playbackService.playNextAudio()
            }) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: metrics.transportButtonSize))
                    .foregroundColor(playbackService.canPlayNextAudio ? .white : .white.opacity(0.3))
                    .frame(maxWidth: .infinity)
            }
            .disabled(!playbackService.canPlayNextAudio)

            // Speed Menu
            AudioRateMenu(rate: playbackService.state.rate, rates: playbackService.availablePlaybackRates)
                .equatable()
            .buttonStyle(OverlayButtonStyle())
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, metrics.controlsHorizontalPadding)
    }

    private var regularPlaybackControlsMetrics: AudioPlayerPortraitLayoutMetrics {
        AudioPlayerPortraitLayoutMetrics(
            artworkSize: 320,
            topSpacer: 24,
            middleSpacer: 34,
            infoBottomSpacing: 30,
            progressBottomSpacing: 30,
            bottomPadding: 34,
            horizontalPadding: 30,
            controlsHorizontalPadding: 20,
            secondaryButtonSize: 20,
            transportButtonSize: 30,
            primaryButtonSize: 70
        )
    }

    private func portraitLayoutMetrics(for size: CGSize) -> AudioPlayerPortraitLayoutMetrics {
        let shortSide = min(size.width, size.height)
        let height = size.height
        let isHeightConstrained = height < 760
        let artworkByHeight = max(188, min(320, height * (isHeightConstrained ? 0.31 : 0.37)))
        let artworkByWidth = max(188, size.width - (isHeightConstrained ? 92 : 60))
        let bottomInsetPadding = max(safeAreaInsets.bottom + 12, isHeightConstrained ? 22 : 34)

        return AudioPlayerPortraitLayoutMetrics(
            artworkSize: min(artworkByHeight, artworkByWidth, shortSide - (isHeightConstrained ? 84 : 60)),
            topSpacer: isHeightConstrained ? 10 : 24,
            middleSpacer: isHeightConstrained ? 18 : 34,
            infoBottomSpacing: isHeightConstrained ? 18 : 30,
            progressBottomSpacing: isHeightConstrained ? 18 : 30,
            bottomPadding: bottomInsetPadding,
            horizontalPadding: isHeightConstrained ? 24 : 30,
            controlsHorizontalPadding: isHeightConstrained ? 14 : 20,
            secondaryButtonSize: isHeightConstrained ? 18 : 20,
            transportButtonSize: isHeightConstrained ? 26 : 30,
            primaryButtonSize: isHeightConstrained ? 60 : 70
        )
    }

    private func normalizedRemotePath(_ rawPath: String) -> String {
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
        if lhs == rhs { return true }
        if lhs.isFileURL || rhs.isFileURL {
            return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
        }

        let lhsScheme = lhs.scheme?.lowercased() ?? ""
        let rhsScheme = rhs.scheme?.lowercased() ?? ""
        guard lhsScheme == rhsScheme else {
            return false
        }

        return normalizedRemotePath(lhs.path) == normalizedRemotePath(rhs.path)
    }
    
    private func setupPlaylist() {
        let supportedAudioExtensions = VideoFile.FileType.audioExtensions

        if let playlist = playlist {
             let playlistFiles = playlist
                 .filter { file in
                     file.type == .audio ||
                     supportedAudioExtensions.contains(file.url.pathExtension.lowercased()) ||
                     supportedAudioExtensions.contains((file.name as NSString).pathExtension.lowercased())
                 }
             
             self.loadedPlaylist = playlistFiles.isEmpty ? [initialFile] : playlistFiles
             self.currentPlaylistCount = self.loadedPlaylist?.count ?? 1
             playbackService.floatingAudioPlaylist = self.loadedPlaylist ?? [initialFile]
             playInitialFileIfNeeded(playlist: self.loadedPlaylist ?? [initialFile])
             return
        }

        guard initialFile.url.isFileURL else {
            if let server = initialFile.resolvedServer,
               server.type.isFileServer {
                let hydratedServer = AppNetworkService.shared.hydratedServer(from: server)
                let parentPath = initialFile.remoteFolderPath
                Task {
                    do {
                        let files = try await AppNetworkService.shared.fetchContents(for: hydratedServer, at: parentPath)
                        await MainActor.run {
                            var playlistFiles = files.filter { $0.type == .audio }
                            if !playlistFiles.contains(where: { $0.id == initialFile.id || $0.name == initialFile.name || playlistURLsMatch($0.url, initialFile.url) }) {
                                playlistFiles.append(initialFile)
                            }
                            playlistFiles.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                            self.loadedPlaylist = playlistFiles.isEmpty ? [initialFile] : playlistFiles
                            self.currentPlaylistCount = self.loadedPlaylist?.count ?? 1
                            playbackService.floatingAudioPlaylist = self.loadedPlaylist ?? [initialFile]
                            playInitialFileIfNeeded(playlist: self.loadedPlaylist ?? [initialFile])
                        }
                    } catch {
                        await MainActor.run {
                            self.loadedPlaylist = [initialFile]
                            self.currentPlaylistCount = 1
                            playbackService.floatingAudioPlaylist = [initialFile]
                            playInitialFileIfNeeded(playlist: [initialFile])
                        }
                    }
                }
                return
            }

            self.loadedPlaylist = [initialFile]
            self.currentPlaylistCount = 1
            playbackService.floatingAudioPlaylist = [initialFile]
            playInitialFileIfNeeded(playlist: [initialFile])
            return
        }
        
        // Local File Logic
        let directoryURL = initialFile.url.deletingLastPathComponent()
        let fm = FileManager.default
        
        if let contents = try? fm.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
            let playlistFiles = contents
                .filter { url in
                    supportedAudioExtensions.contains(url.pathExtension.lowercased()) ||
                    supportedAudioExtensions.contains((url.lastPathComponent as NSString).pathExtension.lowercased())
                }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                .map { url -> VideoFile in
                    VideoFile(
                        name: url.lastPathComponent,
                        url: url,
                        type: .audio,
                        size: 0,
                        date: Date(),
                        isRemote: false
                    )
                }
            
            self.loadedPlaylist = playlistFiles.isEmpty ? [initialFile] : playlistFiles
            self.currentPlaylistCount = self.loadedPlaylist?.count ?? 1
            playbackService.floatingAudioPlaylist = self.loadedPlaylist ?? [initialFile]
            playInitialFileIfNeeded(playlist: self.loadedPlaylist ?? [initialFile])
        } else {
             // Fallback if directory listing fails
             self.loadedPlaylist = [initialFile]
             self.currentPlaylistCount = 1
             playbackService.floatingAudioPlaylist = self.loadedPlaylist ?? [initialFile]
             playInitialFileIfNeeded(playlist: [initialFile])
        }
    }
    
    private func playInitialFileIfNeeded(playlist: [VideoFile]) {
        let matchedIndex = playlist.firstIndex(where: {
            $0.id == initialFile.id ||
            $0.name == initialFile.name ||
            playlistURLsMatch($0.url, initialFile.url)
        }) ?? 0
        
        self.loadedInitialIndex = matchedIndex
        self.isPlaylistLoaded = true

        let selectedPlaylistURL = playlist[matchedIndex].url
        let isAlreadyAnchoredToSelectedItem = playbackService.isPlaying
            && playbackService.state.currentItem?.url == selectedPlaylistURL

        if !isAlreadyAnchoredToSelectedItem {
            playbackService.playAudioItem(at: matchedIndex)
        }
    }
    
    // MARK: - Dominant Color Extraction
    
    private func updateDominantColor(from image: UIImage?) {
        let request = UUID()
        artworkColorRequest = request
        guard let image = image, let cgImage = image.cgImage else {
            withAnimation(.easeInOut(duration: 0.6)) {
                dominantColor = Color(white: 0.15)
            }
            return
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let color = Self.extractDominantColor(from: cgImage)
            DispatchQueue.main.async {
                guard artworkColorRequest == request else { return }
                withAnimation(.easeInOut(duration: 0.6)) {
                    dominantColor = Color(color)
                }
            }
        }
    }
    
    /// Extract the dominant/average color from a CGImage by downsampling to a small size
    private static func extractDominantColor(from cgImage: CGImage) -> UIColor {
        let size = 40 // Sample at 40x40
        let width = size
        let height = size
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        
        var rawData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        
        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return UIColor(white: 0.15, alpha: 1.0)
        }
        
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var totalR: Double = 0
        var totalG: Double = 0
        var totalB: Double = 0
        let pixelCount = width * height
        
        for i in 0..<pixelCount {
            let offset = i * bytesPerPixel
            totalR += Double(rawData[offset])
            totalG += Double(rawData[offset + 1])
            totalB += Double(rawData[offset + 2])
        }
        
        var avgR = totalR / Double(pixelCount) / 255.0
        var avgG = totalG / Double(pixelCount) / 255.0
        var avgB = totalB / Double(pixelCount) / 255.0
        
        // Darken the color to ensure readability of white text
        // Target: keep hue/saturation but cap brightness around 0.35
        let maxBrightness: Double = 0.35
        let currentBrightness = max(avgR, avgG, avgB)
        if currentBrightness > maxBrightness {
            let scale = maxBrightness / currentBrightness
            avgR *= scale
            avgG *= scale
            avgB *= scale
        }
        
        return UIColor(red: avgR, green: avgG, blue: avgB, alpha: 1.0)
    }
}

private struct AudioPlayerPortraitLayoutMetrics {
    let artworkSize: CGFloat
    let topSpacer: CGFloat
    let middleSpacer: CGFloat
    let infoBottomSpacing: CGFloat
    let progressBottomSpacing: CGFloat
    let bottomPadding: CGFloat
    let horizontalPadding: CGFloat
    let controlsHorizontalPadding: CGFloat
    let secondaryButtonSize: CGFloat
    let transportButtonSize: CGFloat
    let primaryButtonSize: CGFloat
}

/// Keep UIKit's thumb, accessibility and tracking, with cache painted in the same track.
private struct AudioBufferedSlider: UIViewRepresentable {
    @Binding var value: Double
    let ranges: [MPVBufferedRange]
    let duration: Double
    let onEditingChanged: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> BufferedSlider {
        let slider = BufferedSlider()
        slider.minimumValue = 0
        slider.maximumValue = 1
        slider.minimumTrackTintColor = .white
        slider.maximumTrackTintColor = .clear
        slider.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.began), for: .touchDown)
        slider.addTarget(context.coordinator, action: #selector(Coordinator.ended(_:)), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return slider
    }

    func updateUIView(_ slider: BufferedSlider, context: Context) {
        context.coordinator.parent = self
        if !slider.isTracking { slider.value = Float(value) }
        slider.ranges = MPVBufferedRange.normalized(ranges, duration: duration)
        slider.duration = duration
        slider.setNeedsLayout()
    }

    final class Coordinator: NSObject {
        var parent: AudioBufferedSlider
        init(_ parent: AudioBufferedSlider) { self.parent = parent }
        @objc func began() { parent.onEditingChanged(true) }
        @objc func changed(_ slider: UISlider) {
            parent.value = Double(slider.value)
            // Accessibility adjustments send valueChanged without a touch sequence.
            if !slider.isTracking { parent.onEditingChanged(false) }
        }
        @objc func ended(_ slider: UISlider) {
            parent.value = Double(slider.value)
            parent.onEditingChanged(false)
        }
    }

    final class BufferedSlider: UISlider {
        var ranges: [MPVBufferedRange] = []
        var duration: Double = 0
        private let cacheTrack = CALayer()
        private let cacheSegments = CAShapeLayer()

        override init(frame: CGRect) {
            super.init(frame: frame)
            cacheTrack.backgroundColor = UIColor.white.withAlphaComponent(0.18).cgColor
            cacheTrack.masksToBounds = true
            cacheSegments.fillColor = UIColor.white.withAlphaComponent(0.46).cgColor
            cacheTrack.addSublayer(cacheSegments)
            layer.insertSublayer(cacheTrack, at: 0)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let track = trackRect(forBounds: bounds)
            cacheTrack.frame = track
            cacheTrack.cornerRadius = track.height / 2
            cacheSegments.frame = cacheTrack.bounds
            let path = UIBezierPath()
            if duration.isFinite, duration > 0 {
                for range in ranges {
                    path.append(UIBezierPath(rect: CGRect(
                        x: track.width * CGFloat(range.start / duration), y: 0,
                        width: track.width * CGFloat((range.end - range.start) / duration), height: track.height
                    )))
                }
            }
            cacheSegments.path = path.cgPath
            CATransaction.commit()
        }
    }
}

// Like the video player's menu snapshots, these values deliberately exclude the
// playback clock. SwiftUI must not replace an open menu on every progress tick.
private struct AudioEngineMenu: View, Equatable {
    let isUsingMPV: Bool
    let canSwitch: Bool

    var body: some View {
        Menu {
            Menu(NSLocalizedString("MPV.Engine", comment: "")) {
                Picker(NSLocalizedString("MPV.Engine", comment: ""), selection: Binding(
                    get: { isUsingMPV ? "mpv" : "vlc" },
                    set: { VLCPlaybackService.shared.switchPlaybackEngine(to: $0) }
                )) {
                    Text("VLC").tag("vlc")
                    Text("mpv").tag("mpv")
                }
                .disabled(!canSwitch)
            }
        } label: {
            if #available(iOS 26.0, *) {
                AppToolbarIcon(systemName: "ellipsis.circle")
            } else {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20))
                    .foregroundColor(.white)
            }
        }
    }
}

private struct AudioRateMenu: View, Equatable {
    let rate: Float
    let rates: [Float]

    var body: some View {
        Menu {
            Picker(NSLocalizedString("Speed", comment: ""), selection: Binding(
                get: { rate },
                set: { VLCPlaybackService.shared.setPlaybackRate($0) }
            )) {
                ForEach(rates, id: \.self) { value in
                    Text("\(String(format: "%g", value))x").tag(value)
                }
            }
        } label: {
            Text("\(String(format: "%g", rate))x")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        }
    }
}
