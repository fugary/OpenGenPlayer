import SwiftUI

struct PlayerBottomBar: View {
    @ObservedObject var playbackService: VLCPlaybackService
    @Binding var isLocked: Bool
    @Binding var progressValue: Float
    var isLandscape: Bool = false
    var topPadding: CGFloat = 12
    var bottomPadding: CGFloat = 16
    var horizontalPadding: CGFloat = 16
    var contentPadding: EdgeInsets? = nil
    var maxContentWidth: CGFloat? = nil
    var currentTimeText: String? = nil
    var durationText: String? = nil
    var onAction: ((String, String) -> Void)?
    var showsExtendedTransportControls: Bool = false
    
    // Playlist Controls
    var canPlayPrevious: Bool = false
    var canPlayNext: Bool = false
    var canReplayCurrentItem: Bool = false
    var playbackSequenceMode: PlaybackSequenceMode = .sequential
    var canChangePlaybackSequence: Bool = false
    var onReplay: (() -> Void)? = nil
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSeekForward: (() -> Void)?
    var onCyclePlaybackSequenceMode: (() -> Void)? = nil
    var onInfo: (() -> Void)?
    var onImportSubtitle: (() -> Void)? = nil
    var playbackQualityOptions: [RemotePlaybackQualityOption] = []
    var selectedPlaybackQualityID: String? = nil
    var onSelectPlaybackQuality: ((String) -> Void)? = nil
    var onScrubBegan: (() -> Void)? = nil
    var onScrubPreviewChanged: ((Double) -> Void)? = nil
    var onScrubEnded: (() -> Void)? = nil
    var onTapSeek: ((Double) -> Void)? = nil
    var onMenuWillOpen: (() -> Void)? = nil
    var onMenuDismiss: (() -> Void)? = nil
    var onOpenAudioMenu: (() -> Void)? = nil
    var onOpenSubtitleMenu: (() -> Void)? = nil
    var onOpenSpeedMenu: (() -> Void)? = nil
    var onOpenMoreMenu: (() -> Void)? = nil
    var sideControlSpacing: CGFloat? = nil
    
    @State private var availableWidth: CGFloat = 0
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    
    // --- EPG live info cache (frozen while a native menu is open) ---
    // We do NOT observe EPGService directly with @ObservedObject because
    // EPGService.objectWillChange fires when EPG data loads, which would
    // cause a full body re-run of PlayerBottomBar exactly when the native
    // Menu is animating open — shifting the LIVE header layout and causing
    // visible flicker.  Instead we pull data into @State and only refresh
    // the cache when no menu is currently presented.
    @State private var cachedLiveProgramme: EPGProgramme? = nil
    @State private var cachedVideoResolution: String = ""

    private var isLiveStream: Bool {
        playbackService.state.currentItem?.isLiveStream == true
    }

    /// Resolve the current EPG programme straight from the shared service
    /// (read-only, no Combine subscription).
    private func resolveLiveProgramme() -> EPGProgramme? {
        guard let item = playbackService.state.currentItem,
              let serverIdStr = item.jellyfinServerId,
              let serverId = UUID(uuidString: serverIdStr) else {
            return nil
        }
        let dummy = IPTVChannel(
            id: item.jellyfinItemId ?? "",
            name: item.title,
            url: item.url
        )
        return EPGService.shared.currentProgramme(for: dummy, in: serverId)
    }

    /// Refresh the frozen cache only when no native menu is open.
    private func refreshLiveInfoCache() {
        guard !playbackService.isMenuPresented else { return }
        cachedLiveProgramme = resolveLiveProgramme()
        cachedVideoResolution = playbackService.state.videoResolution
    }

    var body: some View {
        let narrowPhone = availableWidth > 0 && availableWidth <= 320
        let resolvedCurrentTimeText = currentTimeText ?? playbackService.currentTime
        let resolvedDurationText = durationText ?? playbackService.duration
        
        VStack(spacing: isLocked ? 0 : 10) {
            if !isLocked {
                if isLiveStream {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                            Text("LIVE")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                        
                        if let title = playbackService.state.currentItem?.title {
                            Text(title)
                                .font(.caption.weight(.bold))
                                .foregroundColor(.white.opacity(0.95))
                                .lineLimit(1)
                        }
                        
                        // Use the frozen cache so EPG updates don't reflow the
                        // header while a native Menu is animating open.
                        if let prog = cachedLiveProgramme {
                            Text("·")
                                .foregroundColor(.white.opacity(0.5))
                            Text(prog.title)
                                .font(.caption.weight(.medium))
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)
                            
                            Text(prog.formattedTimeSpan)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.white.opacity(0.7))
                        }
                        
                        Spacer()
                        
                        if !cachedVideoResolution.isEmpty {
                            Text(cachedVideoResolution)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.white.opacity(0.75))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.15)))
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    VStack(spacing: 0) {
                        CustomProgressBar(value: $progressValue, onEditingChanged: { editing in
                            playbackService.isScrubbing = editing
                        }, duration: playbackService.maxDuration, bufferedRanges: playbackService.bufferedRanges, onScrubBegan: onScrubBegan, onScrubTimeChanged: onScrubPreviewChanged, onScrubEnded: onScrubEnded, onTapSeek: onTapSeek)
                        .frame(height: 18)

                        HStack {
                            Text(resolvedCurrentTimeText)
                            Spacer()
                            if playbackService.state.currentItem?.isRemote == true, !playbackService.cacheReadIdle,
                               let rate = playbackService.cacheInputBytesPerSecond, rate > 0 {
                                Text("↓ " + ByteCountFormatter.string(fromByteCount: rate, countStyle: .file) + "/s")
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            Spacer()
                            Text(resolvedDurationText)
                        }
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, narrowPhone ? 4 : 6)
                }
            }

            UnifiedPlayerControls(
                playbackService: playbackService,
                isLocked: $isLocked,
                isLandscape: isLandscape,
                onAction: onAction,
                showsExtendedTransportControls: showsExtendedTransportControls,
                canPlayPrevious: canPlayPrevious,
                canPlayNext: canPlayNext,
                canReplayCurrentItem: canReplayCurrentItem,
                playbackSequenceMode: playbackSequenceMode,
                canChangePlaybackSequence: canChangePlaybackSequence,
                onReplay: onReplay,
                onPrevious: onPrevious,
                onNext: onNext,
                onSeekBackward: onSeekBackward,
                onSeekForward: onSeekForward,
                onCyclePlaybackSequenceMode: onCyclePlaybackSequenceMode,
                onInfo: onInfo,
                onImportSubtitle: onImportSubtitle,
                playbackQualityOptions: playbackQualityOptions,
                selectedPlaybackQualityID: selectedPlaybackQualityID,
                onSelectPlaybackQuality: onSelectPlaybackQuality,
                onMenuWillOpen: onMenuWillOpen,
                onMenuDismiss: onMenuDismiss,
                onOpenAudioMenu: onOpenAudioMenu,
                onOpenSubtitleMenu: onOpenSubtitleMenu,
                onOpenSpeedMenu: onOpenSpeedMenu,
                onOpenMoreMenu: onOpenMoreMenu,
                sideControlSpacing: sideControlSpacing
            )
        }
        .onWidthChange { availableWidth = $0 }
        .frame(maxWidth: maxContentWidth ?? .infinity)
        .frame(maxWidth: .infinity)
        .padding(.top, topPadding)
        .padding(.bottom, bottomPadding)
        .padding(contentPadding ?? EdgeInsets(
            top: 0,
            leading: narrowPhone ? min(horizontalPadding, 12) : horizontalPadding,
            bottom: 0,
            trailing: narrowPhone ? min(horizontalPadding, 12) : horizontalPadding
        ))
        .background(
            GradientOverlay(position: .bottom)
                .ignoresSafeArea()
        )
        .accentColor(.white)
        // Keep the cache fresh: update whenever EPG data arrives or the
        // current item changes, but skip the update while a menu is open.
        .onReceive(EPGService.shared.$epgTables) { _ in
            refreshLiveInfoCache()
        }
        .onChange(of: playbackService.state.currentItem?.id) { _ in
            refreshLiveInfoCache()
        }
        .onChange(of: playbackService.state.videoResolution) { _ in
            refreshLiveInfoCache()
        }
        // When the menu closes, immediately flush the cache so any EPG or
        // resolution updates that arrived while frozen become visible.
        .onChange(of: playbackService.isMenuPresented) { isPresented in
            if !isPresented {
                refreshLiveInfoCache()
            }
        }
        .onAppear {
            refreshLiveInfoCache()
        }
    }
}

struct UnifiedPlayerControls: View {
    @ObservedObject var playbackService: VLCPlaybackService
    @Binding var isLocked: Bool
    var isLandscape: Bool = false
    var onAction: ((String, String) -> Void)?
    var showsExtendedTransportControls: Bool = false
    var canPlayPrevious: Bool
    var canPlayNext: Bool
    var canReplayCurrentItem: Bool = false
    var playbackSequenceMode: PlaybackSequenceMode = .sequential
    var canChangePlaybackSequence: Bool = false
    var onReplay: (() -> Void)? = nil
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSeekForward: (() -> Void)?
    var onCyclePlaybackSequenceMode: (() -> Void)? = nil
    var onInfo: (() -> Void)?
    var onImportSubtitle: (() -> Void)? = nil
    var playbackQualityOptions: [RemotePlaybackQualityOption] = []
    var selectedPlaybackQualityID: String? = nil
    var onSelectPlaybackQuality: ((String) -> Void)? = nil
    var onMenuWillOpen: (() -> Void)? = nil
    var onMenuDismiss: (() -> Void)? = nil
    var onOpenAudioMenu: (() -> Void)? = nil
    var onOpenSubtitleMenu: (() -> Void)? = nil
    var onOpenSpeedMenu: (() -> Void)? = nil
    var onOpenMoreMenu: (() -> Void)? = nil
    var sideControlSpacing: CGFloat? = nil
    
    @State private var availableWidth: CGFloat = 0
    @Environment(\.horizontalSizeClass) var horizontalSizeClass
    
    private var isLiveStream: Bool {
        playbackService.state.currentItem?.isLiveStream == true
    }
    
    var body: some View {
        let isCompact = horizontalSizeClass != .regular
        let stacksControls = AdaptiveMediaLayout.usesStackedTransportControls(
            availableWidth: availableWidth, regularWidth: !isCompact
        )
        let narrowPhone = availableWidth > 0 && availableWidth <= 320
        let resolvedSideSpacing = sideControlSpacing ?? (isLandscape
            ? (narrowPhone ? 22 : (isCompact ? 26 : 28))
            : (narrowPhone ? 14 : (isCompact ? 12 : 20)))
        let transportSpacing: CGFloat = showsExtendedTransportControls
            ? (narrowPhone ? 14 : (isCompact ? 16 : 22))
            : (narrowPhone ? 16 : (isCompact ? 20 : 30))
        let auxiliaryTransportControlWidth: CGFloat = narrowPhone ? 28 : (isCompact ? 30 : 34)
        let secondaryTransportControlWidth: CGFloat = narrowPhone ? 36 : (isCompact ? 40 : 44)
        let primaryTransportControlWidth: CGFloat = narrowPhone ? 48 : (isCompact ? 52 : 58)
        let shouldDisablePrimaryPlayPause =
            playbackService.isBuffering &&
            playbackService.state.currentItem?.isRemote == true
        
        ZStack {
            // BACKGROUND LAYER: Left and Right Controls
            HStack(alignment: .center) {
                // LEFT GROUP: Audio, Subtitle
                if !isLocked {
                    HStack(spacing: resolvedSideSpacing) {
                        // Audio
                        AudioSelectionMenuButton(
                            playbackService: playbackService,
                            onMenuWillOpen: onMenuWillOpen,
                            onAction: onAction,
                            onDismiss: onMenuDismiss,
                            legacyOnOpen: onOpenAudioMenu
                        )
                        .equatable()
                        .buttonStyle(OverlayButtonStyle())
                        
                        // Subtitle
                        SubtitleSelectionMenuButton(
                            playbackService: playbackService,
                            onMenuWillOpen: onMenuWillOpen,
                            onImportSubtitle: onImportSubtitle,
                            onAction: onAction,
                            onDismiss: onMenuDismiss,
                            legacyOnOpen: onOpenSubtitleMenu
                        )
                        .equatable()
                        .buttonStyle(OverlayButtonStyle())
                    }
                }
                
                Spacer() // Pushes left and right groups to the edges
                
                // RIGHT GROUP: Speed, Info
                if !isLocked {
                     HStack(spacing: resolvedSideSpacing) {
                        // Speed (Hidden for live streams)
                        if !isLiveStream {
                            PlaybackSpeedMenuButton(
                                playbackService: playbackService,
                                currentRate: playbackService.state.rate,
                                onMenuWillOpen: onMenuWillOpen,
                                onAction: onAction,
                                onDismiss: onMenuDismiss,
                                legacyOnOpen: onOpenSpeedMenu
                            )
                            .equatable()
                            .buttonStyle(OverlayButtonStyle())
                        }
                        
                         // More (Overflow Menu)
                         MoreMenuButton(
                            playbackService: playbackService,
                            onMenuWillOpen: onMenuWillOpen,
                            onInfo: onInfo,
                            playbackQualityOptions: playbackQualityOptions,
                            selectedPlaybackQualityID: selectedPlaybackQualityID,
                            onSelectPlaybackQuality: onSelectPlaybackQuality,
                            onAction: onAction,
                            onDismiss: onMenuDismiss,
                            legacyOnOpen: onOpenMoreMenu
                         )
                         .equatable()
                         .buttonStyle(OverlayButtonStyle())
                    }
                }
            }
            .frame(maxHeight: stacksControls ? .infinity : nil, alignment: .bottom)
            
            // Keep transport above the menus when a split window is too narrow.
            if !isLocked {
                HStack(spacing: transportSpacing) {
                    if showsExtendedTransportControls && !isLiveStream {
                        Button(action: { onReplay?() }) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 20, weight: .medium))
                                .frame(width: auxiliaryTransportControlWidth, height: auxiliaryTransportControlWidth)
                        }
                        .disabled(!canReplayCurrentItem)
                        .opacity(canReplayCurrentItem ? 1 : 0.4)
                        .accessibilityLabel(Text(NSLocalizedString("Replay from Start", comment: "")))
                    }

                    if showsExtendedTransportControls && !isLiveStream {
                        Button(action: { onSeekBackward?() }) {
                            let seekSeconds = Int(AppSettings.shared.doubleTapSeekDuration)
                            Image(systemName: "gobackward")
                                .font(.system(size: 22, weight: .medium))
                                .overlay(
                                    Text("\(seekSeconds)")
                                        .font(.system(size: 10, weight: .bold))
                                        .offset(y: 1)
                                )
                                .frame(width: auxiliaryTransportControlWidth, height: auxiliaryTransportControlWidth)
                        }
                    }

                    Button(action: { onPrevious?() }) {
                        Image(systemName: "backward.end.fill")
                            .font(.system(size: 28))
                            .frame(width: secondaryTransportControlWidth, height: secondaryTransportControlWidth)
                    }
                    .disabled(!canPlayPrevious)
                    .opacity(canPlayPrevious ? 1 : 0.4)
                    
                    Button(action: { playbackService.togglePlayPause() }) {
                        Image(systemName: playbackService.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 44))
                            .frame(width: primaryTransportControlWidth, height: primaryTransportControlWidth)
                    }
                    .disabled(shouldDisablePrimaryPlayPause)
                    .opacity(shouldDisablePrimaryPlayPause ? 0.4 : 1.0)
                    
                    Button(action: { onNext?() }) {
                        Image(systemName: "forward.end.fill")
                            .font(.system(size: 28))
                            .frame(width: secondaryTransportControlWidth, height: secondaryTransportControlWidth)
                    }
                    .disabled(!canPlayNext)
                    .opacity(canPlayNext ? 1 : 0.4)

                    if showsExtendedTransportControls && !isLiveStream {
                        Button(action: { onSeekForward?() }) {
                            let seekSeconds = Int(AppSettings.shared.doubleTapSeekDuration)
                            Image(systemName: "goforward")
                                .font(.system(size: 22, weight: .medium))
                                .overlay(
                                    Text("\(seekSeconds)")
                                        .font(.system(size: 10, weight: .bold))
                                        .offset(y: 1)
                                )
                                .frame(width: auxiliaryTransportControlWidth, height: auxiliaryTransportControlWidth)
                        }

                        Button(action: { onCyclePlaybackSequenceMode?() }) {
                            Image(systemName: playbackSequenceMode.icon)
                                .font(.system(size: 20, weight: .medium))
                                .frame(width: auxiliaryTransportControlWidth, height: auxiliaryTransportControlWidth)
                        }
                        .disabled(!canChangePlaybackSequence)
                        .opacity(canChangePlaybackSequence ? 1 : 0.4)
                        .accessibilityLabel(Text(playbackSequenceMode.title))
                    }
                }
                .foregroundColor(.white)
                .frame(maxHeight: stacksControls ? .infinity : nil, alignment: .top)
            }
        }
        .frame(height: stacksControls ? 108 : nil)
        .onWidthChange { availableWidth = $0 }
    }
}
