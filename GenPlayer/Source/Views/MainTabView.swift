import SwiftUI
#if os(iOS)
import UIKit
#endif

// Force Xcode Rebuild Trigger 3
private let floatingAudioDragCoordinateSpace = "MainTabFloatingAudioDragCoordinateSpace"

struct MainTabView: View {
    let appLanguage: String
    @AppStorage("selectedMainTab") private var selectedTab: Tab = .files
    
    enum Tab: String {
        case files, server, profile, settings
    }

    private var tabBarTitles: [String] {
        [
            NSLocalizedString("Local", comment: ""),
            NSLocalizedString("Network", comment: ""),
            NSLocalizedString("My", comment: ""),
            NSLocalizedString("Settings", comment: "")
        ]
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                TabView(selection: $selectedTab) {
                NavigationView {
                    FilesListView()
                }
                .navigationViewStyle(.stack)
                .tabItem {
                    Image(systemName: "folder")
                        .conditionalSymbolVariantsNone()
                    Text(NSLocalizedString("Local", comment: ""))
                }
                .tag(Tab.files)
                
                ServerListView()
                    .tabItem {
                        Image(systemName: "network")
                            .conditionalSymbolVariantsNone()
                        Text(NSLocalizedString("Network", comment: ""))
                    }
                    .tag(Tab.server)
                
                ProfileView()
                    .tabItem {
                        Image(systemName: "person.crop.circle.fill")
                            .conditionalSymbolVariantsNone()
                        Text(NSLocalizedString("My", comment: ""))
                    }
                    .tag(Tab.profile)

                NavigationView {
                    SettingsView()
                }
                .navigationViewStyle(.stack)
                .tabItem {
                    Image(systemName: "gearshape")
                        .conditionalSymbolVariantsNone()
                    Text(NSLocalizedString("Settings", comment: ""))
                }
                .tag(Tab.settings)

                }
                .conditionalSymbolVariantsNone()
                .background(
                    TabBarLocalizationConfigurator(
                        refreshKey: appLanguage,
                        titles: tabBarTitles
                    )
                )
                .onReceive(NotificationCenter.default.publisher(for: FileManagerService.didImportExternalFilesNotification)) { _ in
                    selectedTab = .files
                    DispatchQueue.main.async {
                        NavigationUtil.popToRootView()
                    }
                }
                FloatingAudioOverlayHost(
                    containerSize: geometry.size,
                    safeAreaInsets: geometry.safeAreaInsets
                )
            }
            .coordinateSpace(name: floatingAudioDragCoordinateSpace)
        }
    }
}

extension View {
    /// Attach to the server's navigation container so the mini player stays above
    /// its pushed pages, while sheets (including the expanded player) stay above it.
    func serverFloatingAudioOverlay() -> some View {
        overlay {
            GeometryReader { geometry in
                FloatingAudioOverlayHost(
                    containerSize: geometry.size,
                    safeAreaInsets: geometry.safeAreaInsets,
                    handlesVideoRestore: false
                )
                .coordinateSpace(name: floatingAudioDragCoordinateSpace)
            }
        }
    }
}

private struct FloatingAudioOverlayHost: View {
    private struct VideoRestorePresentation: Identifiable {
        let id = UUID()
        let file: VideoFile
    }

    @ObservedObject private var playbackService = VLCPlaybackService.shared
    @Environment(\.scenePhase) private var scenePhase
    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    var handlesVideoRestore = true

    @State private var audioSheetFile: VideoFile?
    @State private var restoredVideoPresentation: VideoRestorePresentation?
    @State private var pendingVideoRestoreFile: VideoFile?
    @State private var isShowingFloatingPlaylist = false
    @State private var restorePresentationAttempt = 0
    @State private var restorePresentationRevision = 0
    @State private var restorePlayerDidAppear = false

    private var restoreUIKitFallbackAttemptThreshold: Int {
        UIDevice.current.userInterfaceIdiom == .pad ? 1 : 2
    }

    private func handleRestorePlayerAppeared(for file: VideoFile, source: String) {
        guard pendingVideoRestoreFile?.id == file.id else { return }
        let revision = restorePresentationRevision
        pendingVideoRestoreFile = nil
        restorePresentationAttempt = 0
        restorePlayerDidAppear = true
        playbackService.clearRequestedVideoPlayerRestoreFile()
        print("[PiP] restored PlayerView appeared via \(source) for \(file.name)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard restorePlayerDidAppear,
                  restorePresentationRevision == revision else { return }
            playbackService.completeVideoPlayerRestoreFromPictureInPicture(success: true)
        }
    }

    private func presentRestorePlayerViaUIKit(for file: VideoFile) {
        guard pendingVideoRestoreFile?.id == file.id,
              !restorePlayerDidAppear,
              !playbackService.isVideoPiPActive else { return }
        guard let presenter = UIApplication.topMostViewController(),
              presenter.presentedViewController == nil,
              !presenter.isBeingPresented,
              !presenter.isBeingDismissed else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                presentRestorePlayerViaUIKit(for: file)
            }
            return
        }

        restoredVideoPresentation = nil
        let hostingController = UIHostingController(
            rootView: PlayerView(initialFile: file)
                .onAppear {
                    handleRestorePlayerAppeared(for: file, source: "UIKit")
                }
        )
        hostingController.modalPresentationStyle = .fullScreen
        print("[PiP] presenting restore PlayerView via UIKit for \(file.name)")
        presenter.present(hostingController, animated: true)
    }

    private func scheduleRestorePresentation(for file: VideoFile, delay: TimeInterval = 0.2) {
        restorePresentationAttempt += 1
        restorePresentationRevision += 1
        restorePlayerDidAppear = false
        let attempt = restorePresentationAttempt
        let revision = restorePresentationRevision

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard pendingVideoRestoreFile?.id == file.id,
                  restorePresentationRevision == revision,
                  scenePhase == .active,
                  !playbackService.isVideoPiPActive else { return }
            restoredVideoPresentation = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard pendingVideoRestoreFile?.id == file.id,
                      restorePresentationRevision == revision,
                      scenePhase == .active,
                      !playbackService.isVideoPiPActive else { return }
                restoredVideoPresentation = VideoRestorePresentation(file: file)
                playbackService.clearRequestedVideoPlayerRestoreFile()
                print("[PiP] presenting restore PlayerView for \(file.name) attempt=\(attempt)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                guard pendingVideoRestoreFile?.id == file.id,
                      restorePresentationRevision == revision,
                      !restorePlayerDidAppear else { return }
                if attempt >= restoreUIKitFallbackAttemptThreshold {
                    print("[PiP] SwiftUI restore presentation did not appear, falling back to UIKit for \(file.name)")
                    presentRestorePlayerViaUIKit(for: file)
                } else {
                    print("[PiP] retrying restore presentation for \(file.name)")
                    scheduleRestorePresentation(for: file, delay: 0.25)
                }
            }
        }
    }

    private func requestRestorePresentation(for file: VideoFile) {
        pendingVideoRestoreFile = file
        if scenePhase == .active, !playbackService.isVideoPiPActive {
            scheduleRestorePresentation(for: file)
        } else {
            print("[PiP] queued restore request until PiP stops and scene becomes active for \(file.name)")
        }
    }

    var body: some View {
        ZStack {
            Color.clear
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
            if playbackService.isAudioFloatingVisible,
               let file = playbackService.floatingAudioFile,
               VideoFile.FileType.determineType(from: playbackService.state.currentItem?.url ?? file.url) == .audio {
                FloatingAudioPlayerView(
                    file: file,
                    containerSize: containerSize,
                    safeAreaInsets: safeAreaInsets,
                    onExpand: {
                        audioSheetFile = file
                    },
                    onShowPlaylist: {
                        isShowingFloatingPlaylist = true
                    }
                )
                .transition(.opacity)
            }
        }
        .sheet(item: $audioSheetFile) { file in
            NavigationView {
                AudioPlayerView(initialFile: file, playlist: playbackService.floatingAudioPlaylist)
            }
            .navigationViewStyle(.stack)
        }
        .fullScreenCover(item: $restoredVideoPresentation, onDismiss: {
            if pendingVideoRestoreFile != nil || !restorePlayerDidAppear {
                print("[PiP] restore presentation dismissed before player attachment")
                playbackService.completeVideoPlayerRestoreFromPictureInPicture(success: false)
            } else {
                print("[PiP] restore presentation dismissed after successful attachment")
            }
            restorePlayerDidAppear = false
            restorePresentationAttempt = 0
            UIApplication.refreshInterfaceChrome()
        }) { presentation in
            PlayerView(initialFile: presentation.file)
                .onAppear {
                    handleRestorePlayerAppeared(for: presentation.file, source: "SwiftUI")
                }
        }
        .sheet(isPresented: $isShowingFloatingPlaylist) {
            if playbackService.floatingAudioPlaylist.isEmpty {
                Text(NSLocalizedString("Loading...", comment: ""))
            } else {
                PlaylistView(
                    playbackService: playbackService,
                    showPlaylist: $isShowingFloatingPlaylist,
                    playlist: playbackService.floatingAudioPlaylist,
                    onSelect: { index in
                        playbackService.playAudioItem(at: index)
                    }
                )
            }
        }
        .onReceive(playbackService.$requestedVideoPlayerRestoreFile) { file in
            guard handlesVideoRestore, let file else { return }
            print("[PiP] received restore request for \(file.name)")
            requestRestorePresentation(for: file)
        }
        .onChange(of: scenePhase) { phase in
            guard handlesVideoRestore, phase == .active,
                  let file = pendingVideoRestoreFile else { return }
            print("[PiP] scene became active, replaying restore for \(file.name)")
            requestRestorePresentation(for: file)
        }
        .onChange(of: playbackService.isVideoPiPActive) { isActive in
            guard handlesVideoRestore, !isActive,
                  let file = pendingVideoRestoreFile else { return }
            print("[PiP] PiP stopped, replaying restore for \(file.name)")
            requestRestorePresentation(for: file)
        }
    }
}

struct FloatingAudioPlayerView: View {
    private enum DockEdge {
        case left
        case right
    }

    @ObservedObject private var playbackService = VLCPlaybackService.shared
    let file: VideoFile
    let containerSize: CGSize
    let safeAreaInsets: EdgeInsets
    var onExpand: () -> Void
    var onShowPlaylist: () -> Void

    @State private var anchorPosition: CGPoint = .zero
    @State private var dragStartAnchor: CGPoint = .zero
    @State private var isEdgeCollapsed: Bool = false
    @State private var dockedEdge: DockEdge = .right
    @State private var isDragging: Bool = false
    @State private var dragMoved: Bool = false
    @State private var hasInitializedPosition: Bool = false
    @State private var expandedMeasuredSize: CGSize = .zero

    private let expandedWidth: CGFloat = 252
    private let expandedFallbackHeight: CGFloat = 126
    private let collapsedSize: CGFloat = 64
    private let collapsePushDistance: CGFloat = 90
    private let horizontalMargin: CGFloat = 16
    private let titleTrailingReserve: CGFloat = 30

    var body: some View {
        Group {
            if isEdgeCollapsed {
                collapsedView
            } else {
                expandedView
            }
        }
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .position(displayAnchorPosition)
        .onTapGesture {
            guard !dragMoved else { return }
            if isEdgeCollapsed {
                expandFromCollapsedIfNeeded()
            } else {
                onExpand()
            }
        }
        .onAppear {
            initializePositionIfNeeded()
        }
        .onPreferenceChange(FloatingAudioExpandedSizePreferenceKey.self) { size in
            guard size.width > 0, size.height > 0 else { return }
            let widthChanged = abs(expandedMeasuredSize.width - size.width) > 0.5
            let heightChanged = abs(expandedMeasuredSize.height - size.height) > 0.5
            guard widthChanged || heightChanged else { return }
            expandedMeasuredSize = size
            clampPositionToBounds()
        }
        .onChange(of: containerSize.width) { _ in
            clampPositionToBounds()
        }
        .onChange(of: containerSize.height) { _ in
            clampPositionToBounds()
        }
        .onChange(of: safeAreaInsets) { _ in
            clampPositionToBounds()
        }
    }

    private var displayAnchorPosition: CGPoint {
        hasInitializedPosition ? anchorPosition : defaultAnchorPosition(collapsed: isEdgeCollapsed)
    }

    private var expandedView: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    RotatingArtworkProgressView(
                        artwork: playbackService.state.currentItem?.artwork,
                        isPlaying: playbackService.isPlaying,
                        progress: playbackProgress,
                        size: 52,
                        lineWidth: 3
                    )

                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            MarqueeText(
                                text: playbackService.state.currentItem?.title ?? file.name,
                                font: .subheadline.weight(.semibold),
                                foregroundColor: .white,
                                speed: 26,
                                trailingClipInset: 0
                            )
                            Text(secondaryLine)
                                .font(.caption2)
                                .foregroundColor(.white.opacity(0.76))
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        // Reserve a hard no-text zone for the top-right close button.
                        Color.clear
                            .frame(width: titleTrailingReserve, height: 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

                HStack(spacing: 22) {
                    Button(action: {
                        let allModes = AudioPlayMode.allCases
                        let currentIndex = allModes.firstIndex(of: playbackService.audioPlayMode) ?? 0
                        let nextIndex = (currentIndex + 1) % allModes.count
                        playbackService.audioPlayMode = allModes[nextIndex]
                    }) {
                        Image(systemName: playbackService.audioPlayMode.icon)
                            .foregroundColor(.white.opacity(0.85))
                            .font(.system(size: 16))
                    }

                    Button(action: { _ = playbackService.onRequestPreviousTrack?() }) {
                        Image(systemName: "backward.fill")
                            .foregroundColor(
                                playbackService.canPlayPreviousAudio ? .white : .white.opacity(0.3)
                            )
                            .font(.system(size: 20))
                    }
                    .disabled(!playbackService.canPlayPreviousAudio)

                    Button(action: { playbackService.togglePlayPause() }) {
                        Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                            .foregroundColor(.white)
                            .font(.system(size: 28))
                    }

                    Button(action: { _ = playbackService.onRequestNextTrack?() }) {
                        Image(systemName: "forward.fill")
                            .foregroundColor(
                                playbackService.canPlayNextAudio ? .white : .white.opacity(0.3)
                            )
                            .font(.system(size: 20))
                    }
                    .disabled(!playbackService.canPlayNextAudio)

                    Button(action: { onShowPlaylist() }) {
                        Image(systemName: "list.bullet")
                            .foregroundColor(.white.opacity(0.85))
                            .font(.system(size: 16))
                    }
                }
                .padding(.bottom, 16)
            }

            Button(action: {
                playbackService.stop()
                playbackService.hideFloatingAudio()
            }) {
                if #available(iOS 15.0, *) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundColor(.white.opacity(0.6))
                        .font(.system(size: 24))
                        .padding(6)
                } else {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.6))
                        .font(.system(size: 24))
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .padding(.top, 2)
            .padding(.trailing, 2)
            .zIndex(2)
        }
        .frame(width: expandedWidth)
        .background(
            Group {
                #if os(macOS)
                    Rectangle().fill(.regularMaterial).environment(\.colorScheme, .dark)
                #else
                if #available(iOS 15.0, *) {
                    Rectangle().fill(.regularMaterial).environment(\.colorScheme, .dark)
                } else {
                    VisualEffectBlur(blurStyle: .systemMaterialDark)
                }
                #endif
            }
        )
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(isDragging ? Color.white.opacity(0.52) : Color.white.opacity(0.18), lineWidth: isDragging ? 1.8 : 1.0)
        )
        .scaleEffect(isDragging ? 1.03 : 1.0)
        .shadow(color: .black.opacity(isDragging ? 0.4 : 0.28), radius: isDragging ? 16 : 12, x: 0, y: isDragging ? 10 : 8)
        .animation(.easeOut(duration: 0.14), value: isDragging)
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: FloatingAudioExpandedSizePreferenceKey.self,
                    value: geometry.size
                )
            }
        )
    }

    private var collapsedView: some View {
        RotatingArtworkProgressView(
            artwork: playbackService.state.currentItem?.artwork,
            isPlaying: playbackService.isPlaying,
            progress: playbackProgress,
            size: 56,
            lineWidth: 3.5
        )
        .frame(width: collapsedSize, height: collapsedSize)
        .background(
            Group {
                if #available(iOS 15.0, *) {
                    Circle().fill(.regularMaterial).environment(\.colorScheme, .dark)
                } else {
                    VisualEffectBlur(blurStyle: .systemMaterialDark)
                        .clipShape(Circle())
                }
            }
        )
        .clipShape(Circle())
        .overlay(
            Circle()
                .stroke(isDragging ? Color.white.opacity(0.62) : Color.white.opacity(0.24), lineWidth: isDragging ? 2.1 : 1.2)
        )
        .scaleEffect(isDragging ? 1.06 : 1.0)
        .shadow(color: .black.opacity(isDragging ? 0.42 : 0.28), radius: isDragging ? 14 : 10, x: 0, y: isDragging ? 9 : 6)
        .animation(.easeOut(duration: 0.14), value: isDragging)
    }

    private var dragGesture: some Gesture {
        DragGesture(
            minimumDistance: 1,
            coordinateSpace: .named(floatingAudioDragCoordinateSpace)
        )
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragStartAnchor = anchorPosition
                    triggerHaptic(.light)
                }
                if abs(value.translation.width) > 3 || abs(value.translation.height) > 3 {
                    dragMoved = true
                }

                let limits = dragLimits(
                    collapsed: isEdgeCollapsed,
                    allowEdgePush: !isEdgeCollapsed
                )
                let rawX = dragStartAnchor.x + value.translation.width
                let rawY = dragStartAnchor.y + value.translation.height
                let liveX = clamped(rawX, minValue: limits.minX, maxValue: limits.maxX)
                let liveY = clamped(rawY, minValue: limits.minY, maxValue: limits.maxY)
                anchorPosition = CGPoint(x: liveX, y: liveY)
            }
            .onEnded { value in
                let rawX = dragStartAnchor.x + value.translation.width
                let rawY = dragStartAnchor.y + value.translation.height
                if isEdgeCollapsed {
                    finalizeCollapsedDrag(rawX: rawX, rawY: rawY)
                } else {
                    finalizeExpandedDrag(rawX: rawX, rawY: rawY)
                }
                isDragging = false
                dragStartAnchor = anchorPosition
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    dragMoved = false
                }
            }
    }

    private func dragLimits(collapsed: Bool, allowEdgePush: Bool) -> (minX: CGFloat, maxX: CGFloat, minY: CGFloat, maxY: CGFloat) {
        let size = collapsed ? collapsedPlayerSize : expandedPlayerSize
        // MainTabView's GeometryReader already excludes the horizontal safe area.
        // Positions and drag translations use that same container coordinate space.
        let baseMinX = size.width / 2 + horizontalMargin
        let baseMaxX = containerSize.width - size.width / 2 - horizontalMargin
        let pushExtra = allowEdgePush ? collapsePushDistance + 24 : 0
        let minX = baseMinX - pushExtra
        let maxX = baseMaxX + pushExtra
        let minY = safeAreaInsets.top + size.height / 2 + topDragClearance(collapsed: collapsed)
        let baseMaxY = containerSize.height - max(0, safeAreaInsets.bottom) - bottomDockingReserve(collapsed: collapsed) - size.height / 2
        let maxY = max(minY, baseMaxY)
        return (min(maxX, minX), max(maxX, minX), minY, maxY)
    }

    private var collapsedPlayerSize: CGSize {
        CGSize(width: collapsedSize, height: collapsedSize)
    }

    private var expandedPlayerSize: CGSize {
        CGSize(
            width: max(expandedMeasuredSize.width, expandedWidth),
            height: max(expandedMeasuredSize.height, expandedFallbackHeight)
        )
    }

    private func finalizeExpandedDrag(rawX: CGFloat, rawY: CGFloat) {
        let baseExpandedLimits = dragLimits(collapsed: false, allowEdgePush: false)
        var finalX = clamped(
            rawX,
            minValue: baseExpandedLimits.minX,
            maxValue: baseExpandedLimits.maxX
        )
        var finalY = clamped(
            rawY,
            minValue: baseExpandedLimits.minY,
            maxValue: baseExpandedLimits.maxY
        )

        let pushedLeftEdge = rawX <= baseExpandedLimits.minX - collapsePushDistance
        let pushedRightEdge = rawX >= baseExpandedLimits.maxX + collapsePushDistance

        if pushedLeftEdge || pushedRightEdge {
            let targetEdge: DockEdge = pushedLeftEdge ? .left : .right
            let collapsedLimits = dragLimits(collapsed: true, allowEdgePush: false)
            finalX = targetEdge == .left ? collapsedLimits.minX : collapsedLimits.maxX
            finalY = clamped(finalY, minValue: collapsedLimits.minY, maxValue: collapsedLimits.maxY)

            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                isEdgeCollapsed = true
                dockedEdge = targetEdge
                anchorPosition = CGPoint(x: finalX, y: finalY)
            }
            triggerHaptic(.medium)
            return
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
            anchorPosition = CGPoint(x: finalX, y: finalY)
        }
    }

    private func finalizeCollapsedDrag(rawX: CGFloat, rawY: CGFloat) {
        let collapsedLimits = dragLimits(collapsed: true, allowEdgePush: false)
        let finalY = clamped(
            rawY,
            minValue: collapsedLimits.minY,
            maxValue: collapsedLimits.maxY
        )

        let midpoint = (collapsedLimits.minX + collapsedLimits.maxX) * 0.5
        let finalEdge: DockEdge = rawX < midpoint ? .left : .right
        let previousEdge = dockedEdge

        let finalX = finalEdge == .left ? collapsedLimits.minX : collapsedLimits.maxX
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            dockedEdge = finalEdge
            anchorPosition = CGPoint(x: finalX, y: finalY)
        }
        if finalEdge != previousEdge {
            triggerHaptic(.light)
        }
    }

    private func clamped(_ value: CGFloat, minValue: CGFloat, maxValue: CGFloat) -> CGFloat {
        min(max(value, minValue), maxValue)
    }

    private func topDragClearance(collapsed: Bool) -> CGFloat {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return collapsed ? 4 : 8
        }
        return collapsed ? 0 : 2
    }

    private func bottomDockingReserve(collapsed: Bool) -> CGFloat {
        if UIDevice.current.userInterfaceIdiom == .pad {
            return collapsed ? 14 : 18
        }
        return collapsed ? 28 : 34
    }

    private var playbackProgress: CGFloat {
        let duration = playbackService.state.duration
        guard duration > 0 else { return 0 }
        let ratio = playbackService.state.currentTime / duration
        return CGFloat(min(max(ratio, 0), 1))
    }

    private var secondaryLine: String {
        if let item = playbackService.state.currentItem,
           let artist = item.artist,
           !artist.isEmpty {
            return artist
        }
        return playbackService.isPlaying
            ? NSLocalizedString("Playing", comment: "")
            : NSLocalizedString("Paused", comment: "")
    }

    private func triggerHaptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.prepare()
        generator.impactOccurred()
    }

    private func initializePositionIfNeeded() {
        guard !hasInitializedPosition, containerSize.width > 0, containerSize.height > 0 else { return }
        anchorPosition = defaultAnchorPosition(collapsed: isEdgeCollapsed)
        hasInitializedPosition = true
    }

    private func defaultAnchorPosition(collapsed: Bool) -> CGPoint {
        guard containerSize.width > 0, containerSize.height > 0 else { return .zero }
        let limits = dragLimits(collapsed: collapsed, allowEdgePush: false)
        let x = collapsed
            ? (dockedEdge == .left ? limits.minX : limits.maxX)
            : limits.maxX
        return CGPoint(x: x, y: limits.maxY)
    }

    private func clampPositionToBounds() {
        guard hasInitializedPosition else { return }
        let limits = dragLimits(collapsed: isEdgeCollapsed, allowEdgePush: false)
        let targetX: CGFloat
        if isEdgeCollapsed {
            targetX = dockedEdge == .left ? limits.minX : limits.maxX
        } else {
            targetX = clamped(anchorPosition.x, minValue: limits.minX, maxValue: limits.maxX)
        }
        let targetY = clamped(anchorPosition.y, minValue: limits.minY, maxValue: limits.maxY)
        anchorPosition = CGPoint(x: targetX, y: targetY)
    }

    private func expandFromCollapsedIfNeeded() {
        guard isEdgeCollapsed else { return }
        let expandedLimits = dragLimits(collapsed: false, allowEdgePush: false)
        let targetX = dockedEdge == .left ? expandedLimits.minX : expandedLimits.maxX
        let targetY = clamped(anchorPosition.y, minValue: expandedLimits.minY, maxValue: expandedLimits.maxY)
        withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
            isEdgeCollapsed = false
            anchorPosition = CGPoint(x: targetX, y: targetY)
        }
    }
}

private struct FloatingAudioExpandedSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next.width > 0, next.height > 0 {
            value = next
        }
    }
}

private struct MarqueeText: View {
    let text: String
    let font: Font
    let foregroundColor: Color
    let speed: Double
    let trailingClipInset: CGFloat

    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var startWorkItem: DispatchWorkItem?
    @State private var animationCycleID = UUID()

    private let initialDelay: TimeInterval = 1.0
    private let edgePause: TimeInterval = 0.75
    private let scrollActivationThreshold: CGFloat = 36

    var body: some View {
        GeometryReader { geometry in
            let visibleWidth = max(0, geometry.size.width - trailingClipInset)
            ZStack(alignment: .leading) {
                label
                    .offset(x: offset)
            }
            .frame(width: visibleWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .background(
                label
                    .hidden()
                    .fixedSize(horizontal: true, vertical: false)
                    .readWidth { width in
                        if abs(textWidth - width) > 0.5 {
                            textWidth = width
                        }
                    }
            )
            .onAppear {
                containerWidth = visibleWidth
                restartAnimationIfNeeded()
            }
            .onChange(of: geometry.size.width) { width in
                let adjustedWidth = max(0, width - trailingClipInset)
                if abs(containerWidth - adjustedWidth) > 0.5 {
                    containerWidth = adjustedWidth
                    restartAnimationIfNeeded()
                }
            }
            .onChange(of: text) { _ in
                restartAnimationIfNeeded()
            }
            .onChange(of: textWidth) { _ in
                restartAnimationIfNeeded()
            }
            .onDisappear {
                startWorkItem?.cancel()
                startWorkItem = nil
                animationCycleID = UUID()
            }
        }
        .frame(height: 18)
    }

    private var label: some View {
        Text(text)
            .font(font)
            .foregroundColor(foregroundColor)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var shouldScroll: Bool {
        containerWidth > 0 && textWidth > containerWidth + scrollActivationThreshold
    }

    private func restartAnimationIfNeeded() {
        startWorkItem?.cancel()
        startWorkItem = nil
        animationCycleID = UUID()
        offset = 0

        guard shouldScroll else { return }

        let overflow = max(0, textWidth - containerWidth)
        guard overflow > 0.5 else { return }

        let cycleID = UUID()
        animationCycleID = cycleID
        scheduleForward(overflow: overflow, cycleID: cycleID, delay: initialDelay)
    }

    private func scheduleForward(overflow: CGFloat, cycleID: UUID, delay: TimeInterval) {
        let workItem = DispatchWorkItem {
            guard animationCycleID == cycleID, shouldScroll else { return }
            let duration = Double(overflow) / max(speed, 1)
            withAnimation(.linear(duration: duration)) {
                offset = -overflow
            }
            scheduleBackward(
                overflow: overflow,
                cycleID: cycleID,
                delay: duration + edgePause
            )
        }
        startWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func scheduleBackward(overflow: CGFloat, cycleID: UUID, delay: TimeInterval) {
        let workItem = DispatchWorkItem {
            guard animationCycleID == cycleID, shouldScroll else { return }
            let duration = Double(overflow) / max(speed, 1)
            withAnimation(.linear(duration: duration)) {
                offset = 0
            }
            scheduleForward(
                overflow: overflow,
                cycleID: cycleID,
                delay: duration + edgePause
            )
        }
        startWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

private struct WidthReader: ViewModifier {
    let onChange: (CGFloat) -> Void

    func body(content: Content) -> some View {
        content.background(
            GeometryReader { geometry in
                Color.clear
                    .preference(key: WidthPreferenceKey.self, value: geometry.size.width)
            }
        )
        .onPreferenceChange(WidthPreferenceKey.self, perform: onChange)
    }
}

private struct WidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

private struct RotatingArtworkProgressView: View {
    let artwork: UIImage?
    let isPlaying: Bool
    let progress: CGFloat
    let size: CGFloat
    let lineWidth: CGFloat

    @State private var rotationAngle: Double = 0
    @State private var lastTick = Date()
    private let rotationTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.17), lineWidth: lineWidth)

            Circle()
                .trim(from: 0, to: max(progress, 0.001))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [Color.white.opacity(0.98), Color.white.opacity(0.4)]),
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))

            Group {
                if let artwork = artwork {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        Color.white.opacity(0.16)
                        Image(systemName: "music.note")
                            .font(.system(size: size * 0.22, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
            }
            .frame(width: size - lineWidth * 2 - 6, height: size - lineWidth * 2 - 6)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 1))
            .rotationEffect(.degrees(rotationAngle))
        }
        .frame(width: size, height: size)
        .onAppear {
            lastTick = Date()
        }
        .onReceive(rotationTimer) { now in
            let delta = now.timeIntervalSince(lastTick)
            lastTick = now
            guard isPlaying else { return }
            rotationAngle = (rotationAngle + delta * 22.0).truncatingRemainder(dividingBy: 360)
        }
    }
}

extension View {
    @ViewBuilder
    func conditionalSymbolVariantsNone() -> some View {
        if #available(iOS 15.0, *) {
            self.environment(\.symbolVariants, .none)
        } else {
            self
        }
    }

    func readWidth(onChange: @escaping (CGFloat) -> Void) -> some View {
        modifier(WidthReader(onChange: onChange))
    }
}

#Preview {
    MainTabView(appLanguage: "system")
}
