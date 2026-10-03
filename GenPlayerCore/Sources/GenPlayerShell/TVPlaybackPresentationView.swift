#if os(tvOS)
import SwiftUI
import UIKit
import AVFoundation
import MediaPlayer
import CoreText
import Combine
import VLCKitSPM
import GenPlayerCore
import GenPlayerFontSupport


public struct TVPlaybackPresentationView: View {
    public let request: TVPlaybackCoordinator.Request

    @StateObject private var session: TVPlaybackSession
    private let playbackCoordinator = TVPlaybackCoordinator.shared

    public init(request: TVPlaybackCoordinator.Request) {
        self.request = request
        _session = StateObject(wrappedValue: TVPlaybackSession(request: request))
    }

    public var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if session.isAudioPlayback {
                TVAudioPlaybackBackdrop(session: session)
                    .ignoresSafeArea()
            } else {
                TVVLCSurfaceView(session: session)
                    .ignoresSafeArea()
            }

            if !session.shouldShowChrome {
                #if os(tvOS)
                TVPlaybackRemoteInputLayer(
                    onReveal: {
                        session.revealChromeTemporarily()
                    },
                    onTogglePlayPause: {
                        session.togglePlayPause()
                    },
                    onOpenControls: {
                        session.requestQuickActionControlFocus()
                    },
                    onClose: {
                        handleExitCommand()
                    },
                    onSeekBackward: {
                        session.seek(by: -session.configuredSeekDuration)
                    },
                    onSeekForward: {
                        session.seek(by: session.configuredSeekDuration)
                    }
                )
                .ignoresSafeArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #else
                Button(action: {
                    session.revealChromeTemporarily()
                }) {
                    Rectangle()
                        .fill(Color.clear)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .opacity(0.001)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #endif
            }

            if session.shouldShowLoadingIndicator {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    .scaleEffect(1.3)
            }

            if let feedback = session.seekFeedback {
                TVPlaybackSeekFeedbackOverlay(feedback: feedback)
                    .transition(.scale(scale: 0.92).combined(with: .opacity))
            }

            if session.shouldShowSecondarySubtitleOverlay {
                TVSecondarySubtitleOverlay(session: session)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if session.shouldShowChrome {
                GeometryReader { _ in
                    TVPlaybackChromeOverlay(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .ignoresSafeArea()
                .zIndex(20)
            }

            if session.isShowingPlaylistOverlay {
                TVPlaylistOverlay(session: session)
                    .zIndex(100)
            }

        }
        .onAppear {
            session.startIfNeeded()
            session.requestInitialAudioControlFocusIfNeeded()
        }
        .onDisappear {
            playbackCoordinator.traceExit("player-disappear panel=\(String(describing: session.activePanel)) nativeMenu=\(session.isNativeMenuPresented)", includeStack: true)
            session.stop()
        }
        .onChange(of: session.activePanel) { panel in
            guard panel == nil else { return }
            session.requestInitialAudioControlFocusIfNeeded()
        }
        .onPlayPauseCommand {
            session.togglePlayPause()
        }
        .onReceive(playbackCoordinator.exitCommands) { source in
            handleExitCommand(source: source)
        }
        #if os(tvOS)
        .onExitCommand {
            handleExitCommand()
        }
        #endif
        .animation(.easeInOut(duration: 0.18), value: session.shouldShowChrome)
        .animation(.easeOut(duration: 0.14), value: session.seekFeedback)
    }

    private func handleExitCommand(source: String = "swiftui") {
        guard session.shouldHandleExitCommand() else {
            playbackCoordinator.traceExit("duplicate source=\(source)")
            return
        }
        let action = TVPlaybackBackPolicy.action(
            nativeMenu: session.isNativeMenuPresented,
            positionAdjustment: session.isDirectSecondarySubtitlePositionAdjustmentActive,
            scrubbing: session.isScrubbing, playlist: session.isShowingPlaylistOverlay,
            submenu: session.activeTrackGroup != nil || session.activePlaybackGroup != nil ||
                session.activePictureGroup != nil || session.activeInfoSectionID != nil,
            panel: session.activePanel != nil,
            chrome: session.isChromeVisible && !session.isAudioPlayback && session.errorMessage == nil)
        playbackCoordinator.traceExit("handle source=\(source) action=\(action)")
        switch action {
        case .nativeMenu: session.dismissNativeMenu()
        case .positionAdjustment: session.finishDirectPositionAdjustment()
        case .scrubbing: session.cancelScrubbing()
        case .playlist: session.isShowingPlaylistOverlay = false
        case .submenu: session.popOptionsSubmenu()
        case .panel: session.closePanel(returnFocusTo: session.activeOptionsPanel)
        case .chrome: session.hideChrome()
        case .exit: closePlayback()
        }
    }

    private func closePlayback() {
        playbackCoordinator.dismiss(suppressExitCommandsFor: 1.0)
    }
}

// MARK: - Optional tvOS mpv session (existing remote/chrome/focus paths stay shared)
private extension TVPlaybackSession {
    var transport: any PlaybackTransport {
        if let mpv { return MPVPlaybackTransport(engine: mpv) }
        return VLCPlaybackTransport(player: player)
    }
    var canSwitchEngine: Bool {
        guard PlaybackEngineAvailability.current.vlc && PlaybackEngineAvailability.current.mpv else { return false }
        guard !isResolvingPlayback,
              TVMPVPlaybackPolicy.supports(url: displayFile.url, isVideo: !isAudioPlayback, isAudio: isAudioPlayback) else { return false }
        // The existing television panel also owns explicit recovery after failure.
        if errorMessage != nil { return true }
        return PlaybackEngineCapabilities.switchingRestriction(
            isPreparing: false, isStopped: false, hasFailed: false,
            isPictureInPicture: false, isLive: isLiveStream,
            isSeekable: transport.state.seekable,
            duration: Double(duration)) == nil
    }

    func switchEngine(_ value: String) {
        guard ["vlc", "mpv"].contains(value), canSwitchEngine,
              (value == "mpv") != isUsingMPV else { return }
        engineOverride = value
        reloadCurrentItemPreservingPlaybackState()
    }

    func mountMPV(_ engine: MPVPlaybackEngine, in view: UIView) {
        guard !isAudioPlayback else { return }
        player?.drawable = nil
        let surface = engine.videoSurfaceView
        guard surface.superview !== view else { return }
        surface.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            surface.topAnchor.constraint(equalTo: view.topAnchor),
            surface.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func mpvNetworkOptions(for file: VideoFile) -> [String: String] {
        var options: [String: String] = [:]
        if let server = tvPlaybackResolvedServer(for: file) {
            if server.type == .vod { options["user-agent"] = VODService.defaultUserAgent }
            if server.type == .pan115 {
                options["user-agent"] = Pan115Manager.defaultUserAgent
                options["referrer"] = "https://115.com"
                if let cookie = server.passwordSecret ?? server.accessToken, !cookie.isEmpty {
                    let header = "Cookie: " + cookie.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                    options["http-header-fields"] = "%\(header.utf8.count)%\(header)"
                }
            }
        }
        return options
    }

    private func mpvSourceURL(for file: VideoFile) -> URL {
        var url = RuntimeNetworkAddressResolver.runtimeURL(from: file.url)
        if file.serverType == .webdav, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
           parts.user == nil, let server = tvPlaybackResolvedServer(for: file) {
            parts.user = server.username
            parts.password = server.passwordSecret
            url = parts.url ?? url
        }
        return url
    }

    private func mpvStream(for file: VideoFile, url: URL, byteCache: MPVReadAheadByteCache? = nil) -> MacMPVStream? {
        let stream: MacMPVStream?
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "smb" {
            let reader = SMBAudioRangeReader(url: url)
            stream = MacMPVStream(metadata: { try await reader.metadata().size },
                read: { try await reader.read(offset: $0, count: $1) }, byteCache: byteCache)
        } else if ["ftp", "ftps", "sftp", "nfs"].contains(scheme) {
            let reader = FileAudioRangeReader(url: url,
                provider: file.serverType?.rawValue ?? (scheme == "ftps" ? "ftp" : scheme),
                serverID: file.jellyfinServerId, path: file.serverPath, itemID: file.jellyfinItemId)
            stream = MacMPVStream(metadata: { try await reader.metadata().size },
                read: { try await reader.read(offset: $0, count: $1) }, byteCache: byteCache)
        } else { stream = nil }
        return stream
    }

    func startMPV(file: VideoFile, subtitle: URL?, attempt: UUID) {
        let audioOnly = file.type == .audio
        isUsingMPV = true
        playbackRate = MPVPlaybackSpeed.clamped(playbackRate)
        pendingAudioTrack = nil // VLC numeric identifiers never enter mpv.
        pendingSubtitleTrack = nil
        // The VLC preparation branch may have suppressed these because it found
        // a numeric history ID. mpv must restore semantic preferences instead.
        let preference = tvStoredTrackQueryPreference(for: file)
        pendingAudioTrackQuery = file.preferredAudioTrackQuery ?? preference.audioQuery
        pendingAudioTrackOrdinal = file.preferredAudioTrackOrdinal
        pendingSubtitleTrackQuery = file.disableSubtitlesOnStart ? nil : (file.preferredSubtitleTrackQuery ?? preference.subtitleQuery)
        pendingSubtitleTrackOrdinal = file.disableSubtitlesOnStart ? nil : file.preferredSubtitleTrackOrdinal
        MacMPVTrackChoice.sanitizeStoredPreferences()
        mpvPreferenceKey = "tv." + MacMPVTrackChoice.mediaKey(url: file.url,
            serverID: file.jellyfinServerId, itemID: file.jellyfinItemId, path: file.serverPath)
        mpvChoices = UserDefaults.standard.data(forKey: mpvPreferenceKey).flatMap {
            try? JSONDecoder().decode([String: MacMPVTrackChoice].self, from: $0)
        } ?? [:]
        mpvPendingChoices = mpvChoices
        if file.preferredAudioTrackQuery != nil || file.preferredAudioTrackOrdinal != nil { mpvPendingChoices["audio"] = nil }
        if file.disableSubtitlesOnStart || file.preferredSubtitleTrackQuery != nil || file.preferredSubtitleTrackOrdinal != nil {
            mpvPendingChoices["sub"] = nil
        }
        if pendingCoreTracks["audio"] != nil {
            mpvPendingChoices["audio"] = nil; pendingAudioTrackQuery = nil; pendingAudioTrackOrdinal = nil
        }
        if pendingCoreTracks["sub"] != nil {
            mpvPendingChoices["sub"] = nil; pendingSubtitleTrackQuery = nil; pendingSubtitleTrackOrdinal = nil
        }
        let typography = IOSSubtitleTypography(fontURL: Bundle.module.url(forResource: "SourceHanSansSC-Regular", withExtension: "otf"))
        var options = ["pause": pauseRequested ? "yes" : "no",
            "hwdec": currentDecoder == .hardware ? "videotoolbox" : "no",
            "speed": String(playbackRate), "audio-delay": String(audioDelay),
            "sub-delay": String(subtitleDelay), "secondary-sub-delay": String(-subtitleDelay),
            "sid": file.disableSubtitlesOnStart ? "no" : "auto",
            "secondary-sid": "no", "secondary-sub-visibility": "no",
            "sub-use-margins": "no", "sub-scale-with-window": "no",
            "sub-ass-force-margins": "no", "sub-ass-scale-with-window": "no",
            "sub-font": typography.fontFamily,
            "sub-font-size": String(typography.mpvFontSize(vlcRelativeDivisor: preferredSubtitleRendererFontSize().doubleValue)),
            "video-aspect-override": aspectRatio.isEmpty ? "-1" : aspectRatio,
            "slang": Locale.preferredLanguages.joined(separator: ",")]
        options.merge(mpvNetworkOptions(for: file)) { _, network in network }
        let url = mpvSourceURL(for: file)
        if audioOnly { options["vid"] = "no"; options["sid"] = "no" }
        // NAS sidecars use independent bounded reads, including the preferred subtitle.
        let subtitles = audioOnly ? [] : (subtitle.flatMap { TVMPVSubtitleLoader.requiresDownload($0) ? nil : [$0] } ?? [])
        let previewReadCache = MPVReadAheadByteCache()
        mpvReadAheadByteCache = previewReadCache
        let stream = mpvStream(for: file, url: url, byteCache: previewReadCache)
        if let subtitle, let origin = currentExternalSubtitleURL { mpvExternalSources[subtitle] = origin }
        pendingMPVExternal = file.disableSubtitlesOnStart || pendingCoreTracks["sub"] != nil || mpvPendingChoices["sub"] != nil
            || pendingSubtitleTrackQuery != nil || pendingSubtitleTrackOrdinal != nil ? nil : subtitle.map { mpvExternalSources[$0] ?? $0 }
        let engine = MPVPlaybackEngine(configuration: .init(url: url, start: pendingInitialSeek ?? 0,
            options: options, subtitles: subtitles, audioOnly: audioOnly, stream: stream,
            readAheadCache: !file.isLiveStream && file.serverType != .iptv), onState: { [weak self] state in
            guard let self, self.playbackAttempt == attempt, self.isUsingMPV, self.errorMessage == nil else { return }
            self.applyMPVState(state)
        }, onError: { [weak self] failure in
            guard let self, self.playbackAttempt == attempt, self.isUsingMPV else { return }
            self.isPlaying = false
            self.isLoading = false
            self.mpvSidecarTask?.cancel(); self.mpvSidecarTask = nil
            self.systemAudio?.stop(); self.systemAudio = nil
            self.errorMessage = platformShellString(failure.isInitialization ? "MPV.InitializationFailed" : "MPV.PlaybackFailed")
            self.isChromeVisible = true
            self.syncHistoryProgress()
            self.syncServerProgress(eventName: "stop", force: true)
        })
        mpv = engine
        if audioOnly {
            // A cover-art screen has no video drawable to trigger engine startup.
            let controls = TVMPVAudioControls()
            systemAudio = controls
            controls.activate { [weak self, weak engine] ready in
                guard let self, let engine, self.playbackAttempt == attempt, self.mpv === engine else { return }
                guard ready else {
                    self.isPlaying = false; self.isLoading = false
                    self.errorMessage = platformShellString("MPV.InitializationFailed")
                    return
                }
                controls.install(play: { [weak self] in
                    guard let self, self.pauseRequested || self.mpvSnapshot?.ended == true else { return }
                    self.togglePlayPause()
                }, pause: { [weak self] in
                    guard let self, !self.pauseRequested else { return }
                    self.togglePlayPause()
                }, next: { [weak self] in self?.playNextItem() }, previous: { [weak self] in self?.playPreviousItem() },
                seek: { [weak self] time in self?.seekAudioFromSystem(to: time) }, stop: { [weak self] in self?.stop() })
                engine.startAudio()
            }
            prepareMPVAudioPresentation(for: file)
        } else if let drawableView { mountMPV(engine, in: drawableView) }
        guard !audioOnly else { return }
        var candidates = currentExternalSubtitleCandidates()
        if let source = currentExternalSubtitleURL, TVMPVSubtitleLoader.requiresDownload(source) {
            candidates.removeAll { $0.url == source }
            candidates.insert(.init(url: source, displayName: source.lastPathComponent), at: 0)
        }
        let remote = candidates.filter { TVMPVSubtitleLoader.requiresDownload($0.url) }
        for candidate in candidates where !TVMPVSubtitleLoader.requiresDownload(candidate.url) && (candidate.url != currentExternalSubtitleURL || subtitles.isEmpty) {
            engine.addSubtitle(candidate.url, title: candidate.displayName)
        }
        attachMPVRemoteSubtitles(remote, engine: engine, attempt: attempt)
    }

    private func attachMPVRemoteSubtitles(_ candidates: [ExternalSubtitleCandidate], engine: MPVPlaybackEngine, attempt: UUID) {
        mpvSidecarTask?.cancel()
        guard !candidates.isEmpty else { mpvSidecarTask = nil; return }
        let serverID = resolvedFile?.jellyfinServerId
        mpvSidecarTask = Task { @MainActor [weak self, weak engine] in
            defer {
                if self?.playbackAttempt == attempt { self?.mpvSidecarTask = nil }
            }
            // Sequential reads cap memory and connections even with many sidecars.
            for candidate in candidates {
                guard !Task.isCancelled, self?.playbackAttempt == attempt else { return }
                var temporary: URL?
                defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
                do {
                    let source = candidate.url
                    let size: UInt64
                    let read: (UInt64, Int) async throws -> Data
                    let scheme = source.scheme?.lowercased() ?? ""
                    if scheme == "smb" {
                        let reader = SMBAudioRangeReader(url: source)
                        size = try await reader.metadata().size
                        read = { try await reader.read(offset: $0, count: $1) }
                    } else {
                        let reader = FileAudioRangeReader(url: source, provider: scheme == "ftps" ? "ftp" : scheme,
                            serverID: serverID, path: source.path, itemID: nil)
                        size = try await reader.metadata().size
                        read = { try await reader.read(offset: $0, count: $1) }
                    }
                    let data = try await TVMPVSubtitleLoader.load(size: size, read: read)
                    guard let self, self.playbackAttempt == attempt, let engine, self.mpv === engine,
                          self.errorMessage == nil, !Task.isCancelled else { return }
                    let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                        .appendingPathExtension(source.pathExtension.isEmpty ? "srt" : source.pathExtension)
                    temporary = local
                    // Preserve the existing text-encoding normalization without leaving an extra cached copy.
                    var text = self.decodeExternalSubtitleText(data: data)?
                        .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                    if text?.hasPrefix("\u{FEFF}") == true { text?.removeFirst() }
                    let output = text?.data(using: .utf8) ?? data
                    try output.write(to: local, options: .atomic)
                    engine.addCachedSubtitle(local, source: source)
                    self.mpvExternalSources[local] = source
                    temporary = nil // Engine now owns the file and maps it back to the source URL.
                } catch {
                    if Task.isCancelled { return }
                    // A missing/oversized sidecar must not prevent other candidates or playback.
                    continue
                }
            }
        }
    }

    func applyMPVState(_ incoming: MPVPlaybackEngine.State) {
        var state = incoming
        state.tracks = incoming.tracks.map { track in
            var track = track
            if let url = track.externalURL, let source = mpvExternalSources[url] {
                track.externalFilename = source.absoluteString
            }
            return track
        }
        let old = mpvSnapshot
        guard old != state else { return }
        if old?.hdrInfo != state.hdrInfo { objectWillChange.send() }
        mpvSnapshot = state
        if timeProgress.bufferedRanges != state.bufferedRanges { timeProgress.bufferedRanges = state.bufferedRanges }
        #if os(macOS) || os(iOS) || os(tvOS)
        if timeProgress.cacheInputBytesPerSecond != state.cacheInputBytesPerSecond {
            timeProgress.cacheInputBytesPerSecond = state.cacheInputBytesPerSecond
        }
        if timeProgress.cacheReadIdle != state.cacheReadIdle {
            timeProgress.cacheReadIdle = state.cacheReadIdle
        }
        #endif
        if isAudioPlayback, old?.metadata != state.metadata {
            var metadata = TVAudioPresentationMetadata()
            metadata.title = state.metadata["title"]
            metadata.artist = state.metadata["artist"]
            metadata.album = state.metadata["album"]
            applyAudioMetadata(metadata, targetURL: displayFile.url)
        }
        if state.loaded {
            currentTime = state.time
            duration = max(state.duration, displayFile.duration ?? 0)
            pendingInitialSeek = nil
        }
        let newIsPlaying = state.loaded && !state.paused && !pauseRequested && !state.ended
        if isPlaying != newIsPlaying { isPlaying = newIsPlaying }
        let newIsLoading = !state.loaded || (!pauseRequested && state.buffering && !state.ended)
        if isLoading != newIsLoading { isLoading = newIsLoading }
        if state.loaded && !state.buffering { markPlaybackStartedIfNeeded() }
        if mpvSelectionRequest == nil, currentSubtitleTrackID != state.subtitle { currentSubtitleTrackID = state.subtitle }
        if currentAudioTrackID != state.audio { currentAudioTrackID = state.audio }
        if old?.tracks != state.tracks || old?.loaded != state.loaded { refreshMPVTracks() }
        if old?.subtitle != state.subtitle, mpvSecondaryID != nil, mpvSelectionRequest == nil { selectMPVSubtitles() }
        updateMPVSecondary()
        if old?.size != state.size { updateDrawableLayout() }
        if isAudioPlayback {
            systemAudio?.update(title: audioMetadataTitle ?? displayFile.name, artist: audioMetadataArtist,
                album: audioMetadataAlbum, artwork: audioArtwork, time: currentTime, duration: duration,
                rate: isPlaying ? playbackRate : 0, canNext: canPlayNextItem, canPrevious: canPlayPreviousItem)
        }
        if abs(currentTime - lastMPVHistoryTime) >= 5 || old?.paused != state.paused {
            lastMPVHistoryTime = currentTime
            syncHistoryProgress()
        }
        if state.loaded { syncServerProgress(eventName: nil) }
        if state.ended && old?.ended != true {
            syncHistoryProgress()
            syncServerProgress(eventName: "stop", force: true)
            isChromeVisible = true
            let attempt = playbackAttempt
            if canPlayNextItem {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playbackAttempt == attempt else { return }
                    self.playNextItem()
                }
            }
        }
    }

    func refreshMPVTracks() {
        guard let state = mpvSnapshot else { return }
        if isNativeMenuPresented { deferredNativeMenuTrackRefreshNeeded = true; return }
        func name(_ track: MacMPVTrack) -> String {
            let text = [mpvTrackTitle(track), track.language, track.codec].filter { !$0.isEmpty }.joined(separator: " · ")
            return text.isEmpty ? "\(track.id)" : text
        }
        if state.loaded, let file = resolvedFile {
            // Match the desktop server fallback after the container's tracks are known.
            for track in serverSecondarySubtitleTracks(for: file) {
                guard track.primaryTrackID == nil, track.isSelectable,
                      track.isExternal || file.mediaSourceId?.isEmpty == false,
                      let url = track.sourceURL,
                      mpvServerSubtitlesRegistered.insert(track.id).inserted else { continue }
                let key = tvSubtitleCandidateKey(url)
                guard !state.tracks.contains(where: {
                    $0.externalURL.map { tvSubtitleCandidateKey(mpvExternalSources[$0] ?? $0) } == key
                }) else { continue }
                mpv?.addSubtitle(url, title: track.displayName, language: track.language ?? "")
            }
        }
        audioTracks = state.tracks.filter { $0.type == "audio" }.map { .init(id: $0.id, name: name($0), isExternal: $0.external) }
        subtitleTracks = state.tracks.filter { $0.type == "sub" }.map { .init(id: $0.id, name: name($0), isExternal: $0.external) }
        for type in ["audio", "sub"] {
            let tracks = state.tracks.filter { $0.type == type }
            var desired: Int?
            if let pending = pendingCoreTracks[type] {
                desired = pending.resolve(embeddedIDs: tracks.filter { !$0.external }.map(\.id))
                if desired != nil { pendingCoreTracks[type] = nil }
            } else if let choice = mpvPendingChoices[type] {
                desired = choice.resolve(in: tracks)
                if desired != nil { mpvPendingChoices[type] = nil }
            } else if state.loaded {
                let ordinal = type == "audio" ? pendingAudioTrackOrdinal : pendingSubtitleTrackOrdinal
                let query = type == "audio" ? pendingAudioTrackQuery : pendingSubtitleTrackQuery
                desired = IOSMPVTrackPreference.resolve(query: query, ordinal: ordinal,
                    tracks: tracks, displayNames: tracks.map(name))
            }
            if let desired {
                if type == "audio" { transport.selectAudioTrack(desired) }
                else { currentSubtitleTrackID = desired; selectMPVSubtitles() }
                if type == "audio" { pendingAudioTrackQuery = nil; pendingAudioTrackOrdinal = nil }
                else { pendingSubtitleTrackQuery = nil; pendingSubtitleTrackOrdinal = nil }
            }
        }
        if let pendingMPVExternal, let track = state.tracks.first(where: { $0.externalURL == pendingMPVExternal }) {
            self.pendingMPVExternal = nil
            currentSubtitleTrackID = track.id
            selectMPVSubtitles()
        }
        refreshSecondarySubtitleTracks()
    }

    func seekAudioFromSystem(to seconds: Double) {
        guard isAudioPlayback, isUsingMPV, mpvSnapshot?.seekable == true, seconds.isFinite else { return }
        mpv?.seek(seconds: min(max(seconds, 0), duration))
    }

    func rememberMPVTrack(_ id: Int, type: String) {
        guard let choice = MacMPVTrackChoice.selected(id, in: mpvSnapshot?.tracks.filter { $0.type == (type == "secondary" ? "sub" : type) } ?? []) else { return }
        mpvPendingChoices[type] = nil
        mpvChoices[type] = choice
        if let data = try? JSONEncoder().encode(mpvChoices) { UserDefaults.standard.set(data, forKey: mpvPreferenceKey) }
    }

    private func mpvTrackTitle(_ track: MacMPVTrack) -> String {
        let externalSource = track.externalURL.flatMap { mpvExternalSources[$0] ?? $0 }
        if let source = externalSource,
           let candidate = currentExternalSubtitleCandidates().first(where: { tvSubtitleCandidateKey($0.url) == tvSubtitleCandidateKey(source) }),
           !candidate.displayName.isEmpty { return candidate.displayName }
        if let externalSource, externalSource.isFileURL {
            let name = externalSource.deletingPathExtension().lastPathComponent
            if !name.isEmpty { return name }
        }
        return track.title
    }

    func mpvSecondaryTracks() -> [EmbeddedSubtitleTrack] {
        (mpvSnapshot?.tracks.filter { $0.type == "sub" } ?? []).map { track in
            let title = mpvTrackTitle(track)
            let name = [title, track.language, track.codec].filter { !$0.isEmpty }.joined(separator: " · ")
            return EmbeddedSubtitleTrack(id: "tv.mpv.\(track.id)", source: .remoteContainer,
                primaryTrackID: track.id, codec: track.codec, language: track.language, title: title,
                displayName: name.isEmpty ? String(track.id) : name,
                sourceURL: track.externalURL.map { mpvExternalSources[$0] ?? $0 },
                supportLevel: track.isBitmap ? .unsupportedBitmap :
                    (TVMPVPlaybackPolicy.supportsText(track.codec) ? .textBestEffort : .unsupportedUnknown), isExternal: track.external)
        }
    }

    var nativeSecondaryRendering: MPVSecondarySubtitleRendering? {
        guard let id = mpvSecondaryID else { return nil }
        return MPVSecondarySubtitleRendering(trackID: id, tracks: mpvSnapshot?.tracks ?? [])
    }

    var isNativeBitmapSecondarySubtitle: Bool {
        playbackCapabilities.supports(.secondaryBitmap, isVideo: displayFile.type == .video) &&
        nativeSecondaryRendering?.isBitmap == true
    }

    var isNativeASSSecondarySubtitle: Bool {
        guard isUsingMPV, let rendering = nativeSecondaryRendering else { return false }
        return rendering.rendersASSNatively(primary: currentSubtitleTrackID)
    }

    var isNativeRenderedSecondarySubtitle: Bool {
        isNativeBitmapSecondarySubtitle || isNativeASSSecondarySubtitle
    }

    func updateMPVSecondaryRendering() {
        guard let mpv else { return }
        let nativeASS = isNativeASSSecondarySubtitle
        let isNative = isNativeRenderedSecondarySubtitle && secondarySubtitleStatus == .ready
        // Both distinct tracks and mirrors use the secondary region. Move the
        // native ASS layer as a whole while retaining its fonts/styles/effects.
        let ratio = currentSecondarySubtitleVerticalPositionRatio()
        mpv.set("secondary-sub-visibility", isNative ? "yes" : "no")
        mpv.set("secondary-sub-ass-override", nativeASS
            ? MPVSecondarySubtitleRendering.assOverride(hasCustomPosition: true)
            : (isNativeBitmapSecondarySubtitle ? "yes" : "strip"))
        if nativeASS {
            let scale = (UserDefaults.standard.object(forKey: "secondarySubtitleSizeScale") as? Double) ?? 1.0
            mpv.configureSecondaryASS(track: mpvSecondaryID ?? -1,
                                     scale: scale > 0 ? scale : 1.0,
                                     centerY: ratio)
            mpv.set("secondary-sub-pos", "100")
        } else if isNativeBitmapSecondarySubtitle {
            mpv.set("secondary-sub-pos", String(MPVSecondarySubtitleRendering.nativePosition(
                ratio: ratio)))
        }
    }

    func selectMPVSubtitles() {
        if nativeSecondaryRendering?.canSelect(primary: currentSubtitleTrackID) == false {
            clearSecondarySubtitleTrack(persistPreference: true)
        }
        let request = UUID(), attempt = playbackAttempt
        mpvSelectionRequest = request
        let primary = currentSubtitleTrackID, secondary = mpvSecondaryID ?? -1
        if mpvSecondaryID != nil { secondarySubtitleStatus = .loading }
        updateMPVSecondaryRendering()
        mpv?.selectSubtitles(primary: primary, secondary: secondary) { [weak self] p, s in
            guard let self, self.playbackAttempt == attempt, self.mpvSelectionRequest == request,
                  self.errorMessage == nil else { return }
            self.mpvSelectionRequest = nil
            self.currentSubtitleTrackID = p
            if self.mpvSecondaryID != nil {
                self.secondarySubtitleStatus = self.nativeSecondaryRendering?.isSelected(primary: p, secondary: s) == true ? .ready : .failed
            }
            self.updateMPVSecondaryRendering()
        }
    }

    func updateMPVSecondary() {
        if isNativeRenderedSecondarySubtitle {
            if !secondarySubtitleParts.isEmpty { secondarySubtitleParts = [] }
            return
        }
        guard isSecondarySubtitlesEnabled, let id = mpvSecondaryID, let state = mpvSnapshot,
              mpvSelectionRequest == nil, secondarySubtitleStatus == .ready else {
            if !secondarySubtitleParts.isEmpty { secondarySubtitleParts = [] }
            return
        }
        let mirror = state.subtitle == id
        let text = mirror ? state.primaryText : (state.secondary == id ? state.secondaryText : "")
        let start = mirror ? state.primaryStart : state.secondaryStart
        let end = mirror ? state.primaryEnd : state.secondaryEnd
        let time = currentTime + subtitleDelay
        let parts: [SubtitlePart]
        if let start, let end, start <= time, time < end, !text.isEmpty {
            parts = [.init(start: start, end: end, text: NSAttributedString(string: text))]
        } else { parts = [] }
        if secondarySubtitleParts != parts { secondarySubtitleParts = parts }
    }
}

private struct TVVLCSurfaceView: UIViewRepresentable {
    let session: TVPlaybackSession

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        session.attachDrawable(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        session.attachDrawable(uiView)
        session.updateDrawableLayout()
    }
}

#if os(tvOS)
private struct TVPlaybackRemoteInputLayer: UIViewRepresentable {
    let onReveal: () -> Void
    let onTogglePlayPause: () -> Void
    let onOpenControls: () -> Void
    let onClose: () -> Void
    let onSeekBackward: () -> Void
    let onSeekForward: () -> Void

    func makeUIView(context: Context) -> TVPlaybackRemoteInputView {
        let view = TVPlaybackRemoteInputView()
        view.onReveal = onReveal
        view.onTogglePlayPause = onTogglePlayPause
        view.onOpenControls = onOpenControls
        view.onClose = onClose
        view.onSeekBackward = onSeekBackward
        view.onSeekForward = onSeekForward
        return view
    }

    func updateUIView(_ uiView: TVPlaybackRemoteInputView, context: Context) {
        uiView.onReveal = onReveal
        uiView.onTogglePlayPause = onTogglePlayPause
        uiView.onOpenControls = onOpenControls
        uiView.onClose = onClose
        uiView.onSeekBackward = onSeekBackward
        uiView.onSeekForward = onSeekForward
        DispatchQueue.main.async {
            uiView.setNeedsFocusUpdate()
            uiView.updateFocusIfNeeded()
        }
    }
}

private final class TVPlaybackRemoteInputView: UIView {
    var onReveal: (() -> Void)?
    var onTogglePlayPause: (() -> Void)?
    var onOpenControls: (() -> Void)?
    var onClose: (() -> Void)?
    var onSeekBackward: (() -> Void)?
    var onSeekForward: (() -> Void)?

    override var canBecomeFocused: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureInputView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureInputView()
    }

    private func configureInputView() {
        backgroundColor = .clear
        isUserInteractionEnabled = true
        addGestureRecognizer(swipeGesture(direction: .left))
        addGestureRecognizer(swipeGesture(direction: .right))
    }

    private func swipeGesture(direction: UISwipeGestureRecognizer.Direction) -> UISwipeGestureRecognizer {
        let gesture = UISwipeGestureRecognizer(target: self, action: #selector(handleSwipe(_:)))
        gesture.direction = direction
        return gesture
    }

    @objc private func handleSwipe(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended else { return }
        if gesture.direction.contains(.left) {
            onSeekBackward?()
        } else if gesture.direction.contains(.right) {
            onSeekForward?()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.setNeedsFocusUpdate()
            self?.updateFocusIfNeeded()
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var didHandlePress = false

        for press in presses {
            switch press.type {
            case .select:
                onTogglePlayPause?()
                didHandlePress = true
            case .downArrow:
                onReveal?()
                didHandlePress = true
            case .upArrow:
                onOpenControls?()
                didHandlePress = true
            case .leftArrow:
                onSeekBackward?()
                didHandlePress = true
            case .rightArrow:
                onSeekForward?()
                didHandlePress = true
            case .menu:
                didHandlePress = true
            default:
                break
            }
        }

        if !didHandlePress {
            super.pressesBegan(presses, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { $0.type != .menu }
        if remaining.count != presses.count { onClose?() }
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { $0.type != .menu }
        if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
    }
}
#endif

private struct TVPlaybackSeekFeedback: Equatable {
    let delta: TimeInterval
    let targetTime: TimeInterval

    var isForward: Bool {
        delta >= 0
    }

    var seconds: Int {
        max(1, Int(abs(delta).rounded()))
    }

    var secondsText: String {
        "\(isForward ? "+" : "-")\(seconds)s"
    }

    var systemImageName: String {
        "\(isForward ? "goforward" : "gobackward").\(seconds)"
    }
}

private struct TVPlaybackMediaInfoSection: Identifiable {
    let id: String
    let title: String
    let icon: String
    let items: [(key: String, value: String)]

    init(title: String, icon: String, items: [(key: String, value: String)]) {
        self.id = title
        self.title = title
        self.icon = icon
        self.items = items
    }
}

private struct TVPlaybackPlaylistItem: Identifiable, Equatable {
    let index: Int
    let title: String
    let subtitle: String?
    let artworkURL: URL?
    let type: VideoFile.FileType
    let durationText: String?
    let progressText: String?
    let progress: Double
    let metadataText: String?
    let isCurrent: Bool

    var id: Int { index }
}

private extension VideoDisplayMode {
    var tvLocalizedTitle: String {
        switch self {
        case .fit:
            return platformShellString("Fit to Screen")
        case .fill:
            return platformShellString("Fill Screen")
        }
    }
}

private enum TVPlaybackVideoDecoder: String, CaseIterable, Identifiable {
    case hardware = "hw"
    case software = "sw"

    var id: String { rawValue }

    var localizedName: String {
        switch self {
        case .hardware:
            return platformShellString("Hardware (HW)")
        case .software:
            return platformShellString("Software (SW)")
        }
    }

    var systemImageName: String {
        switch self {
        case .hardware:
            return "cpu"
        case .software:
            return "cpu.fill"
        }
    }

    static var defaultPreference: TVPlaybackVideoDecoder {
        let rawValue = UserDefaults.standard.string(forKey: "defaultVideoDecoder") ?? TVPlaybackVideoDecoder.hardware.rawValue
        return TVPlaybackVideoDecoder(rawValue: rawValue) ?? .hardware
    }

    static func resolved(_ decoder: TVPlaybackVideoDecoder) -> TVPlaybackVideoDecoder {
        #if targetEnvironment(simulator)
        return .software
        #else
        return decoder
        #endif
    }
}

private enum TVPlaybackSettings {
    private static let secondarySubtitlePositionKey = "secondarySubtitleVerticalPositionRatio"
    private static let secondarySubtitleMinimumPositionRatio = 0.08
    private static let secondarySubtitleMaximumPositionRatio = 0.92

    static func defaultPlaybackRate(for type: VideoFile.FileType) -> Float {
        let key = type == .audio ? "defaultAudioPlaybackSpeed" : "defaultPlaybackSpeed"
        let defaults = UserDefaults.standard
        let storedValue = defaults.object(forKey: key) == nil ? 1.0 : defaults.double(forKey: key)
        guard storedValue.isFinite, storedValue > 0 else { return 1.0 }
        return Float(min(max(storedValue, 0.25), 8.0))
    }

    static var audioDelaySeconds: Double {
        get { UserDefaults.standard.double(forKey: "audioDelaySeconds") }
        set { UserDefaults.standard.set(min(max(newValue, -10.0), 10.0), forKey: "audioDelaySeconds") }
    }

    static var subtitleDelaySeconds: Double {
        get { UserDefaults.standard.double(forKey: "subtitleDelaySeconds") }
        set { UserDefaults.standard.set(min(max(newValue, -10.0), 10.0), forKey: "subtitleDelaySeconds") }
    }

    static var isPlaybackQualitySwitchingEnabled: Bool {
        false
    }

    static var isSecondarySubtitlesEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta") }
        set { UserDefaults.standard.set(newValue, forKey: "enableSecondarySubtitlesBeta") }
    }

    static var secondarySubtitleVerticalPositionRatio: Double? {
        get {
            guard UserDefaults.standard.object(forKey: secondarySubtitlePositionKey) != nil else {
                return nil
            }
            let storedValue = UserDefaults.standard.double(forKey: secondarySubtitlePositionKey)
            guard storedValue >= 0 else { return nil }
            return clampedSecondarySubtitlePositionRatio(storedValue)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(
                    clampedSecondarySubtitlePositionRatio(newValue),
                    forKey: secondarySubtitlePositionKey
                )
            } else {
                UserDefaults.standard.set(-1.0, forKey: secondarySubtitlePositionKey)
            }
        }
    }

    static func clampedSecondarySubtitlePositionRatio(_ ratio: Double) -> Double {
        min(max(ratio, secondarySubtitleMinimumPositionRatio), secondarySubtitleMaximumPositionRatio)
    }

    static func resolvedRemotePlaybackQualityOption(for optionID: String?) -> RemotePlaybackQualityOption {
        guard isPlaybackQualitySwitchingEnabled else { return .original }
        return RemotePlaybackQualityOption.option(for: optionID)
    }

    static func resolvedRemotePlaybackQualityID(for optionID: String?) -> String {
        resolvedRemotePlaybackQualityOption(for: optionID).id
    }

    static func visibleRemotePlaybackQualityOptions(from options: [RemotePlaybackQualityOption]) -> [RemotePlaybackQualityOption] {
        guard isPlaybackQualitySwitchingEnabled, options.count > 1 else { return [] }
        return options
    }
}

struct TVMediaBrowserChapter: Sendable {
    let index: Int
    let name: String?
    let startPositionSeconds: TimeInterval
    let imageTag: String?
}

struct TVMediaBrowserSeekPreviewManifest: Sendable {
    let trickplay: TVMediaBrowserTrickplayManifest?
    let chapters: [TVMediaBrowserChapter]
}

struct TVMediaBrowserTrickplayManifest: Sendable {
    let mediaSourceId: String?
    let pathWidth: Int
    let tileWidth: Int
    let tileHeight: Int
    let thumbnailWidth: Int
    let thumbnailHeight: Int
    let thumbnailCount: Int
    let intervalMilliseconds: Int

    private var thumbnailsPerTile: Int {
        max(1, tileWidth * tileHeight)
    }

    var tileCount: Int {
        max(1, ((thumbnailCount - 1) / thumbnailsPerTile) + 1)
    }

    func frame(at targetTime: TimeInterval) -> TVMediaBrowserTrickplayFrame? {
        guard tileWidth > 0,
              tileHeight > 0,
              thumbnailWidth > 0,
              thumbnailHeight > 0,
              thumbnailCount > 0 else {
            return nil
        }

        let interval = max(1, intervalMilliseconds)
        let targetMilliseconds = max(0, Int((targetTime * 1000).rounded()))
        let thumbnailIndex = min(thumbnailCount - 1, targetMilliseconds / interval)
        let tileIndex = thumbnailIndex / thumbnailsPerTile
        let indexInTile = thumbnailIndex % thumbnailsPerTile
        return TVMediaBrowserTrickplayFrame(
            tileIndex: tileIndex,
            row: indexInTile / tileWidth,
            column: indexInTile % tileWidth,
            thumbnailIndex: thumbnailIndex
        )
    }
}

struct TVMediaBrowserTrickplayFrame {
    let tileIndex: Int
    let row: Int
    let column: Int
    let thumbnailIndex: Int
}

enum TVMediaBrowserTrickplayManifestParser {
    static func parse(
        itemPayload: [String: Any],
        preferredMediaSourceId: String?,
        preferredThumbnailWidth: Int = 320,
        duration: TimeInterval?
    ) -> TVMediaBrowserSeekPreviewManifest? {
        let fallbackDuration: TimeInterval?
        if let rawTicks = intValue(forKeys: ["RunTimeTicks", "runTimeTicks"], in: itemPayload), rawTicks > 0 {
            fallbackDuration = Double(rawTicks) / 10_000_000.0
        } else {
            fallbackDuration = nil
        }
        let effectiveDuration = duration ?? fallbackDuration

        // 1. Parse Trickplay Variants
        var sourceVariants: [(mediaSourceId: String?, variants: [String: Any])] = []

        if let rawTrickplay = dictionaryValue(for: "Trickplay", in: itemPayload) {
            sourceVariants.append(contentsOf: normalizedSourceVariants(from: rawTrickplay))
        }

        if let mediaSources = itemPayload["MediaSources"] as? [[String: Any]] ?? itemPayload["mediaSources"] as? [[String: Any]] {
            for source in mediaSources {
                let sourceId = stringValue(forKeys: ["Id", "id"], in: source)
                if let sourceTrickplay = dictionaryValue(for: "Trickplay", in: source) {
                    let variants = normalizedSourceVariants(from: sourceTrickplay)
                    for variant in variants {
                        let effectiveId = variant.mediaSourceId ?? sourceId
                        if !sourceVariants.contains(where: { normalizedIdentifier($0.mediaSourceId) == normalizedIdentifier(effectiveId) && $0.variants.keys == variant.variants.keys }) {
                            sourceVariants.append((mediaSourceId: effectiveId, variants: variant.variants))
                        }
                    }
                }
            }
        }

        let normalizedPreferredSourceId = normalizedIdentifier(preferredMediaSourceId)
        let orderedVariantMaps = orderedSourceVariantMaps(
            from: sourceVariants,
            preferredMediaSourceId: normalizedPreferredSourceId
        )

        let candidateVariants = orderedVariantMaps.flatMap { variantMap in
            variantMap.variants.compactMap { widthKey, rawValue -> TVMediaBrowserTrickplayManifest? in
                guard let info = rawValue as? [String: Any] else { return nil }

                let pathWidth = intValue(forKeys: ["Width", "width"], in: info) ?? Int(widthKey) ?? 0
                let thumbnailWidth = intValue(forKeys: ["Width", "width"], in: info) ?? pathWidth
                let thumbnailHeight = intValue(forKeys: ["Height", "height"], in: info) ?? 0
                let tileWidth = intValue(forKeys: ["TileWidth", "tileWidth"], in: info) ?? 0
                let tileHeight = intValue(forKeys: ["TileHeight", "tileHeight"], in: info) ?? 0
                let rawThumbnailCount = intValue(forKeys: ["ThumbnailCount", "thumbnailCount"], in: info) ?? 0

                guard pathWidth > 0,
                      thumbnailWidth > 0,
                      thumbnailHeight > 0,
                      tileWidth > 0,
                      tileHeight > 0,
                      rawThumbnailCount > 0 else {
                    return nil
                }

                let intervalMilliseconds = resolvedIntervalMilliseconds(
                    rawInterval: intValue(forKeys: ["Interval", "interval"], in: info),
                    duration: effectiveDuration,
                    thumbnailCount: rawThumbnailCount
                )
                guard intervalMilliseconds > 0 else { return nil }

                let thumbnailCount = resolvedThumbnailCount(
                    rawThumbnailCount: rawThumbnailCount,
                    tileWidth: tileWidth,
                    tileHeight: tileHeight,
                    intervalMilliseconds: intervalMilliseconds,
                    duration: effectiveDuration
                )
                guard thumbnailCount > 0 else { return nil }

                return TVMediaBrowserTrickplayManifest(
                    mediaSourceId: variantMap.mediaSourceId,
                    pathWidth: pathWidth,
                    tileWidth: tileWidth,
                    tileHeight: tileHeight,
                    thumbnailWidth: thumbnailWidth,
                    thumbnailHeight: thumbnailHeight,
                    thumbnailCount: thumbnailCount,
                    intervalMilliseconds: intervalMilliseconds
                )
            }
        }

        let bestTrickplay = candidateVariants.min { lhs, rhs in
            let lhsDistance = abs(lhs.pathWidth - preferredThumbnailWidth)
            let rhsDistance = abs(rhs.pathWidth - preferredThumbnailWidth)
            if lhsDistance != rhsDistance {
                return lhsDistance < rhsDistance
            }

            let lhsIsPreferredSource = normalizedIdentifier(lhs.mediaSourceId) == normalizedPreferredSourceId
            let rhsIsPreferredSource = normalizedIdentifier(rhs.mediaSourceId) == normalizedPreferredSourceId
            if lhsIsPreferredSource != rhsIsPreferredSource {
                return lhsIsPreferredSource
            }

            if lhs.thumbnailCount != rhs.thumbnailCount {
                return lhs.thumbnailCount > rhs.thumbnailCount
            }

            return lhs.pathWidth < rhs.pathWidth
        }

        // 2. Parse Chapters (fallback for items without trickplay sprite generation, e.g. 4K items)
        var chapters: [TVMediaBrowserChapter] = []
        if let rawChapters = itemPayload["Chapters"] as? [[String: Any]] ?? itemPayload["chapters"] as? [[String: Any]] {
            for (index, chapterDict) in rawChapters.enumerated() {
                let ticks = intValue(forKeys: ["StartPositionTicks", "startPositionTicks"], in: chapterDict) ?? 0
                let seconds = Double(ticks) / 10_000_000.0
                let name = stringValue(forKeys: ["Name", "name"], in: chapterDict)
                let imageTag = stringValue(forKeys: ["ImageTag", "imageTag"], in: chapterDict)
                chapters.append(
                    TVMediaBrowserChapter(
                        index: index,
                        name: name,
                        startPositionSeconds: seconds,
                        imageTag: imageTag
                    )
                )
            }
        }

        guard bestTrickplay != nil || !chapters.isEmpty else {
            return nil
        }

        return TVMediaBrowserSeekPreviewManifest(
            trickplay: bestTrickplay,
            chapters: chapters
        )
    }

    private static func normalizedSourceVariants(from rawValue: Any) -> [(mediaSourceId: String?, variants: [String: Any])] {
        guard let dictionary = rawValue as? [String: Any], !dictionary.isEmpty else {
            return []
        }

        if dictionary.values.allSatisfy(looksLikeVariantInfo) {
            return [(mediaSourceId: nil, variants: dictionary)]
        }

        return dictionary.compactMap { key, value in
            guard let variants = value as? [String: Any], !variants.isEmpty else {
                return nil
            }
            return (mediaSourceId: key, variants: variants)
        }
    }

    private static func orderedSourceVariantMaps(
        from variants: [(mediaSourceId: String?, variants: [String: Any])],
        preferredMediaSourceId: String?
    ) -> [(mediaSourceId: String?, variants: [String: Any])] {
        var remaining = variants
        var ordered: [(mediaSourceId: String?, variants: [String: Any])] = []

        if let preferredMediaSourceId,
           let preferredIndex = remaining.firstIndex(where: {
               normalizedIdentifier($0.mediaSourceId) == preferredMediaSourceId
           }) {
            ordered.append(remaining.remove(at: preferredIndex))
        }

        if let sourceLessIndex = remaining.firstIndex(where: {
            normalizedIdentifier($0.mediaSourceId) == nil
        }) {
            ordered.append(remaining.remove(at: sourceLessIndex))
        }

        ordered.append(contentsOf: remaining.sorted {
            ($0.mediaSourceId ?? "") < ($1.mediaSourceId ?? "")
        })
        return ordered
    }

    private static func looksLikeVariantInfo(_ rawValue: Any) -> Bool {
        guard let dictionary = rawValue as? [String: Any] else { return false }
        return intValue(forKeys: ["ThumbnailCount", "thumbnailCount"], in: dictionary) != nil &&
            intValue(forKeys: ["TileWidth", "tileWidth"], in: dictionary) != nil
    }

    private static func resolvedThumbnailCount(
        rawThumbnailCount: Int,
        tileWidth: Int,
        tileHeight: Int,
        intervalMilliseconds: Int,
        duration: TimeInterval?
    ) -> Int {
        guard rawThumbnailCount > 0 else { return 0 }

        let thumbnailsPerTile = max(1, tileWidth * tileHeight)
        guard thumbnailsPerTile > 1,
              let estimatedThumbnailCount = estimatedThumbnailCount(
                  duration: duration,
                  intervalMilliseconds: intervalMilliseconds
              ),
              estimatedThumbnailCount > max(rawThumbnailCount, rawThumbnailCount * 4) else {
            return rawThumbnailCount
        }

        let expandedThumbnailCount = min(
            estimatedThumbnailCount,
            rawThumbnailCount * thumbnailsPerTile
        )
        guard expandedThumbnailCount > rawThumbnailCount else {
            return rawThumbnailCount
        }

        let rawDistance = abs(estimatedThumbnailCount - rawThumbnailCount)
        let expandedDistance = abs(estimatedThumbnailCount - expandedThumbnailCount)
        return expandedDistance < rawDistance ? expandedThumbnailCount : rawThumbnailCount
    }

    private static func resolvedIntervalMilliseconds(
        rawInterval: Int?,
        duration: TimeInterval?,
        thumbnailCount: Int
    ) -> Int {
        if let rawInterval, rawInterval > 0 {
            return rawInterval
        }

        guard let duration, duration > 0, thumbnailCount > 0 else {
            return 0
        }

        return max(1, Int((duration * 1000.0) / Double(thumbnailCount)))
    }

    private static func estimatedThumbnailCount(
        duration: TimeInterval?,
        intervalMilliseconds: Int
    ) -> Int? {
        guard let duration,
              duration > 0,
              intervalMilliseconds > 0 else {
            return nil
        }

        let durationMilliseconds = max(1, Int((duration * 1000.0).rounded(.down)))
        return max(1, durationMilliseconds / intervalMilliseconds)
    }

    private static func dictionaryValue(for key: String, in dictionary: [String: Any]) -> Any? {
        dictionary.first { candidate, _ in
            candidate.caseInsensitiveCompare(key) == .orderedSame
        }?.value
    }

    private static func intValue(forKeys keys: [String], in dictionary: [String: Any]) -> Int? {
        for key in keys {
            guard let rawValue = dictionaryValue(for: key, in: dictionary) else { continue }
            if let intValue = rawValue as? Int {
                return intValue
            }
            if let number = rawValue as? NSNumber {
                return number.intValue
            }
            if let doubleValue = rawValue as? Double {
                return Int(doubleValue)
            }
            if let stringValue = rawValue as? String,
               let intValue = Int(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return intValue
            }
        }

        return nil
    }

    private static func stringValue(forKeys keys: [String], in dictionary: [String: Any]) -> String? {
        for key in keys {
            guard let rawValue = dictionaryValue(for: key, in: dictionary) else { continue }
            if let stringValue = rawValue as? String {
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private static func normalizedIdentifier(_ rawValue: String?) -> String? {
        let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return nil }
        return trimmed.lowercased()
    }
}

private final class TVRemoteSeekPreviewService {
    static let shared = TVRemoteSeekPreviewService()

    private let session: URLSession
    private let finalImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 160
        return cache
    }()
    private let tileImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 60
        return cache
    }()
    private let manifestCache = TVRemoteTrickplayManifestCache()

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 4
        configuration.timeoutIntervalForResource = 8
        session = URLSession(configuration: configuration)
    }

    func canPreview(_ file: VideoFile) -> Bool {
        guard file.isRemote,
              tvTrimmedPlaybackText(file.jellyfinItemId) != nil,
              let server = tvPlaybackResolvedServer(for: file) else {
            return false
        }
        switch server.type {
        case .jellyfin, .emby, .plex:
            return previewToken(for: file, server: server) != nil
        default:
            return false
        }
    }

    func previewImage(for file: VideoFile, targetTime: TimeInterval) async -> UIImage? {
        guard let context = await resolvedContext(for: file) else { return nil }

        switch context.server.type {
        case .jellyfin, .emby:
            return await mediaBrowserPreviewImage(context: context, targetTime: targetTime)
        case .plex:
            return await plexPreviewImage(context: context, targetTime: targetTime)
        default:
            return nil
        }
    }

    private func mediaBrowserPreviewImage(
        context: TVRemoteSeekPreviewContext,
        targetTime: TimeInterval
    ) async -> UIImage? {
        guard let manifest = await mediaBrowserManifest(context: context) else {
            return nil
        }

        // 1. Try high-precision trickplay sprite sheet first
        if let trickplay = manifest.trickplay, let frame = trickplay.frame(at: targetTime) {
            let tileContext = context.withMediaSourceId(trickplay.mediaSourceId ?? context.mediaSourceId)
            let frameCacheKey = trickplayFrameCacheKey(
                for: tileContext,
                width: trickplay.pathWidth,
                frame: frame
            ) as NSString
            if let cachedImage = finalImageCache.object(forKey: frameCacheKey) {
                return cachedImage
            }

            if let tileImage = await trickplayTileImage(
                context: tileContext,
                width: trickplay.pathWidth,
                tileIndex: frame.tileIndex
            ) {
                prefetchAdjacentTrickplayTiles(around: frame.tileIndex, manifest: trickplay, context: tileContext)
                let croppedImage = crop(tileImage: tileImage, manifest: trickplay, frame: frame)
                if let croppedImage {
                    finalImageCache.setObject(croppedImage, forKey: frameCacheKey)
                    return croppedImage
                }
            }
        }

        // 2. Fall back to chapter preview image (e.g. 4K items without trickplay sprite generation)
        if !manifest.chapters.isEmpty {
            if let chapter = matchingChapter(for: targetTime, in: manifest.chapters) {
                let cacheKey = "tv-remote-seek-chapter|\(context.server.id.uuidString)|\(context.itemId)|\(chapter.index)" as NSString
                if let cachedImage = finalImageCache.object(forKey: cacheKey) {
                    return cachedImage
                }

                if let chapterImage = await chapterPreviewImage(context: context, chapter: chapter) {
                    finalImageCache.setObject(chapterImage, forKey: cacheKey)
                    return chapterImage
                }
            }
        }

        return nil
    }

    private func matchingChapter(
        for targetTime: TimeInterval,
        in chapters: [TVMediaBrowserChapter]
    ) -> TVMediaBrowserChapter? {
        let validChapters = chapters.sorted { $0.startPositionSeconds < $1.startPositionSeconds }
        guard let first = validChapters.first, targetTime >= first.startPositionSeconds else {
            return validChapters.first
        }
        return validChapters.last { $0.startPositionSeconds <= targetTime }
    }

    private func chapterPreviewImage(
        context: TVRemoteSeekPreviewContext,
        chapter: TVMediaBrowserChapter
    ) async -> UIImage? {
        guard let url = mediaBrowserChapterImageURL(context: context, chapter: chapter) else {
            return nil
        }

        do {
            var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            request.setValue("image/jpeg,image/*;q=0.9", forHTTPHeaderField: "Accept")
            applyMediaBrowserHeaders(to: &request, context: context)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let image = UIImage(data: data) else {
                return nil
            }

            return image
        } catch {
            return nil
        }
    }

    private func mediaBrowserManifest(context: TVRemoteSeekPreviewContext) async -> TVMediaBrowserSeekPreviewManifest? {
        let manifestKey = trickplayManifestKey(for: context)
        return await manifestCache.manifest(forKey: manifestKey) {
            await self.fetchMediaBrowserManifest(context: context)
        }
    }

    private func fetchMediaBrowserManifest(context: TVRemoteSeekPreviewContext) async -> TVMediaBrowserSeekPreviewManifest? {
        guard let url = mediaBrowserItemDetailsURL(context: context) else {
            return nil
        }

        do {
            var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
            request.httpMethod = "GET"
            request.timeoutInterval = 8
            applyMediaBrowserHeaders(to: &request, context: context)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return nil
            }

            return TVMediaBrowserTrickplayManifestParser.parse(
                itemPayload: payload,
                preferredMediaSourceId: context.mediaSourceId,
                duration: context.duration
            )
        } catch {
            return nil
        }
    }

    private func trickplayTileImage(
        context: TVRemoteSeekPreviewContext,
        width: Int,
        tileIndex: Int
    ) async -> UIImage? {
        let cacheKey = trickplayTileCacheKey(for: context, width: width, tileIndex: tileIndex)
        if let cachedImage = tileImageCache.object(forKey: cacheKey as NSString) {
            return cachedImage
        }

        guard let url = mediaBrowserTrickplayTileURL(context: context, width: width, tileIndex: tileIndex) else {
            return nil
        }

        do {
            var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
            request.httpMethod = "GET"
            request.timeoutInterval = 5
            request.setValue("image/jpeg,image/*;q=0.9", forHTTPHeaderField: "Accept")
            applyMediaBrowserHeaders(to: &request, context: context)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let image = UIImage(data: data) else {
                return nil
            }

            tileImageCache.setObject(image, forKey: cacheKey as NSString)
            return image
        } catch {
            return nil
        }
    }

    private func prefetchAdjacentTrickplayTiles(
        around tileIndex: Int,
        manifest: TVMediaBrowserTrickplayManifest,
        context: TVRemoteSeekPreviewContext
    ) {
        let candidateTileIndices: [Int]
        if manifest.tileCount <= 12 {
            candidateTileIndices = (0..<manifest.tileCount)
                .filter { $0 != tileIndex }
                .sorted { abs($0 - tileIndex) < abs($1 - tileIndex) }
        } else {
            candidateTileIndices = [tileIndex + 1, tileIndex - 1].filter {
                $0 >= 0 && $0 < manifest.tileCount
            }
        }

        for adjacentTileIndex in candidateTileIndices {
            let cacheKey = trickplayTileCacheKey(
                for: context,
                width: manifest.pathWidth,
                tileIndex: adjacentTileIndex
            )
            if tileImageCache.object(forKey: cacheKey as NSString) != nil {
                continue
            }

            Task(priority: .utility) { [weak self] in
                guard let self else { return }
                _ = await self.trickplayTileImage(
                    context: context,
                    width: manifest.pathWidth,
                    tileIndex: adjacentTileIndex
                )
            }
        }
    }

    private func plexPreviewImage(
        context: TVRemoteSeekPreviewContext,
        targetTime: TimeInterval
    ) async -> UIImage? {
        guard let partId = context.plexPartId,
              let url = plexPreviewURL(context: context, partId: partId, targetTime: targetTime) else {
            return nil
        }

        let cacheKey = plexPreviewCacheKey(for: context, partId: partId, targetTime: targetTime) as NSString
        if let cachedImage = finalImageCache.object(forKey: cacheKey) {
            return cachedImage
        }

        do {
            var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
            request.httpMethod = "GET"
            request.timeoutInterval = 1.8
            request.setValue("image/jpeg,image/*;q=0.9", forHTTPHeaderField: "Accept")
            applyPlexHeaders(to: &request, context: context)

            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200...299).contains(httpResponse.statusCode),
                  let image = UIImage(data: data) else {
                return nil
            }

            finalImageCache.setObject(image, forKey: cacheKey)
            return image
        } catch {
            return nil
        }
    }

    private func crop(
        tileImage: UIImage,
        manifest: TVMediaBrowserTrickplayManifest,
        frame: TVMediaBrowserTrickplayFrame
    ) -> UIImage? {
        guard let cgImage = tileImage.cgImage else { return tileImage }

        let scaleX = CGFloat(cgImage.width) / max(tileImage.size.width, 1)
        let scaleY = CGFloat(cgImage.height) / max(tileImage.size.height, 1)
        let cropRect = CGRect(
            x: CGFloat(frame.column * manifest.thumbnailWidth) * scaleX,
            y: CGFloat(frame.row * manifest.thumbnailHeight) * scaleY,
            width: CGFloat(manifest.thumbnailWidth) * scaleX,
            height: CGFloat(manifest.thumbnailHeight) * scaleY
        ).integral

        guard cropRect.width > 0,
              cropRect.height > 0,
              cropRect.maxX <= CGFloat(cgImage.width),
              cropRect.maxY <= CGFloat(cgImage.height),
              let cropped = cgImage.cropping(to: cropRect) else {
            return tileImage
        }

        return UIImage(cgImage: cropped, scale: tileImage.scale, orientation: tileImage.imageOrientation)
    }

    private func resolvedContext(for file: VideoFile) async -> TVRemoteSeekPreviewContext? {
        guard file.isRemote,
              let itemId = tvTrimmedPlaybackText(file.jellyfinItemId),
              let server = tvPlaybackResolvedServer(for: file),
              let token = previewToken(for: file, server: server) else {
            return nil
        }

        let mediaSourceId = tvTrimmedPlaybackText(
            tvPlaybackQueryValue(named: "MediaSourceId", in: file.url)
        )
        let userId: String?
        if server.type == .jellyfin || server.type == .emby {
            if let storedUserId = tvTrimmedPlaybackText(server.userId) {
                userId = storedUserId
            } else {
                userId = try? await tvPlaybackResolvedUserId(server: server)
            }
        } else {
            userId = nil
        }

        return TVRemoteSeekPreviewContext(
            server: server,
            itemId: itemId,
            token: token,
            userId: userId,
            mediaSourceId: mediaSourceId,
            duration: file.duration,
            plexPartId: plexPartId(for: file)
        )
    }

    private func previewToken(for file: VideoFile, server: ServerConfig) -> String? {
        switch server.type {
        case .jellyfin, .emby:
            return tvTrimmedPlaybackText(tvPlaybackQueryValue(named: "api_key", in: file.url))
                ?? tvTrimmedPlaybackText(tvPlaybackQueryValue(named: "X-Emby-Token", in: file.url))
                ?? tvTrimmedPlaybackText(server.accessToken)
        case .plex:
            return tvTrimmedPlaybackText(tvPlaybackQueryValue(named: "X-Plex-Token", in: file.url))
                ?? tvTrimmedPlaybackText(server.accessToken)
                ?? tvTrimmedPlaybackText(server.passwordSecret)
        default:
            return nil
        }
    }

    private func mediaBrowserItemDetailsURL(context: TVRemoteSeekPreviewContext) -> URL? {
        let baseURL = context.server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path: String
        if let userId = tvTrimmedPlaybackText(context.userId) {
            path = "/Users/\(userId)/Items/\(context.itemId)"
        } else {
            path = "/Items/\(context.itemId)"
        }

        guard var components = URLComponents(string: "\(baseURL)\(path)") else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "Fields", value: "Trickplay,MediaSources,Chapters"),
            URLQueryItem(name: "api_key", value: context.token)
        ]
        return components.url
    }

    private func mediaBrowserChapterImageURL(
        context: TVRemoteSeekPreviewContext,
        chapter: TVMediaBrowserChapter
    ) -> URL? {
        let baseURL = context.server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(
            string: "\(baseURL)/Items/\(context.itemId)/Images/Chapter/\(chapter.index)"
        ) else {
            return nil
        }

        var queryItems = [
            URLQueryItem(name: "api_key", value: context.token),
            URLQueryItem(name: "maxWidth", value: "480")
        ]
        if let tag = chapter.imageTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
            queryItems.append(URLQueryItem(name: "tag", value: tag))
        }
        components.queryItems = queryItems
        return components.url
    }

    private func mediaBrowserTrickplayTileURL(
        context: TVRemoteSeekPreviewContext,
        width: Int,
        tileIndex: Int
    ) -> URL? {
        let baseURL = context.server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard var components = URLComponents(
            string: "\(baseURL)/Videos/\(context.itemId)/Trickplay/\(width)/\(tileIndex).jpg"
        ) else {
            return nil
        }

        var queryItems = [URLQueryItem(name: "api_key", value: context.token)]
        if let mediaSourceId = tvTrimmedPlaybackText(context.mediaSourceId) {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
        }
        components.queryItems = queryItems
        return components.url
    }

    private func plexPreviewURL(
        context: TVRemoteSeekPreviewContext,
        partId: String,
        targetTime: TimeInterval
    ) -> URL? {
        let baseURL = context.server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let offsetMilliseconds = max(0, Int64((targetTime * 1000.0).rounded()))
        guard var components = URLComponents(
            string: "\(baseURL)/library/parts/\(partId)/indexes/sd/\(offsetMilliseconds)"
        ) else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "X-Plex-Token", value: context.token)]
        return components.url
    }

    private func applyMediaBrowserHeaders(
        to request: inout URLRequest,
        context: TVRemoteSeekPreviewContext
    ) {
        request.setValue("application/json,image/jpeg,image/*;q=0.9", forHTTPHeaderField: "Accept")
        request.setValue(context.token, forHTTPHeaderField: "X-Emby-Token")
        request.setValue(context.token, forHTTPHeaderField: "X-MediaBrowser-Token")
        request.setValue(
            "MediaBrowser Client=\"GenPlayer-tvOS\", Device=\"Apple TV\", DeviceId=\"GenPlayerTV\", Version=\"1.0\", Token=\"\(context.token)\"",
            forHTTPHeaderField: "Authorization"
        )
    }

    private func applyPlexHeaders(
        to request: inout URLRequest,
        context: TVRemoteSeekPreviewContext
    ) {
        request.setValue("GenPlayer", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("tvOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("GenPlayer-tvOS", forHTTPHeaderField: "X-Plex-Device")
        request.setValue("GenPlayerTV", forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(context.token, forHTTPHeaderField: "X-Plex-Token")
    }

    private func plexPartId(for file: VideoFile) -> String? {
        let components = file.url.pathComponents
        guard let partIndex = components.firstIndex(of: "parts"),
              partIndex + 1 < components.count else {
            return nil
        }
        return tvTrimmedPlaybackText(components[partIndex + 1])
    }

    private func trickplayManifestKey(for context: TVRemoteSeekPreviewContext) -> String {
        "tv-remote-seek-manifest|\(context.server.type.rawValue)|\(context.server.id.uuidString)|\(context.itemId)|\(context.mediaSourceId ?? "default")"
    }

    private func trickplayTileCacheKey(
        for context: TVRemoteSeekPreviewContext,
        width: Int,
        tileIndex: Int
    ) -> String {
        "tv-remote-seek-tile|\(context.server.type.rawValue)|\(context.server.id.uuidString)|\(context.itemId)|\(context.mediaSourceId ?? "default")|\(width)|\(tileIndex)"
    }

    private func trickplayFrameCacheKey(
        for context: TVRemoteSeekPreviewContext,
        width: Int,
        frame: TVMediaBrowserTrickplayFrame
    ) -> String {
        "tv-remote-seek-frame|\(context.server.type.rawValue)|\(context.server.id.uuidString)|\(context.itemId)|\(context.mediaSourceId ?? "default")|\(width)|\(frame.thumbnailIndex)"
    }

    private func plexPreviewCacheKey(
        for context: TVRemoteSeekPreviewContext,
        partId: String,
        targetTime: TimeInterval
    ) -> String {
        let roundedTimeBucket = Int((max(targetTime, 0) * 2.0).rounded())
        return "tv-remote-seek-plex|\(context.server.id.uuidString)|\(partId)|\(roundedTimeBucket)"
    }
}

private struct TVRemoteSeekPreviewContext {
    let server: ServerConfig
    let itemId: String
    let token: String
    let userId: String?
    let mediaSourceId: String?
    let duration: TimeInterval?
    let plexPartId: String?

    func withMediaSourceId(_ mediaSourceId: String?) -> TVRemoteSeekPreviewContext {
        TVRemoteSeekPreviewContext(
            server: server,
            itemId: itemId,
            token: token,
            userId: userId,
            mediaSourceId: mediaSourceId,
            duration: duration,
            plexPartId: plexPartId
        )
    }
}

actor TVRemoteTrickplayManifestCache {
    private var manifests: [String: TVMediaBrowserSeekPreviewManifest] = [:]
    private var missingManifestTimestamps: [String: Date] = [:]
    private var inFlightTasks: [String: Task<TVMediaBrowserSeekPreviewManifest?, Never>] = [:]
    private let missingManifestRetryInterval: TimeInterval = 3

    func manifest(
        forKey key: String,
        loader: @escaping () async -> TVMediaBrowserSeekPreviewManifest?
    ) async -> TVMediaBrowserSeekPreviewManifest? {
        if let manifest = manifests[key] {
            return manifest
        }

        if let markedAt = missingManifestTimestamps[key] {
            if Date().timeIntervalSince(markedAt) < missingManifestRetryInterval {
                return nil
            }
            missingManifestTimestamps.removeValue(forKey: key)
        }

        if let inFlightTask = inFlightTasks[key] {
            return await inFlightTask.value
        }

        let task = Task<TVMediaBrowserSeekPreviewManifest?, Never> {
            await loader()
        }
        inFlightTasks[key] = task

        let resolvedManifest = await task.value
        inFlightTasks.removeValue(forKey: key)

        if let resolvedManifest {
            manifests[key] = resolvedManifest
            missingManifestTimestamps.removeValue(forKey: key)
        } else {
            manifests.removeValue(forKey: key)
            missingManifestTimestamps[key] = Date()
        }

        return resolvedManifest
    }
}

private struct TVAudioPresentationMetadata {
    var title: String?
    var artist: String?
    var album: String?
    var artwork: UIImage?

    var isEmpty: Bool {
        title == nil && artist == nil && album == nil && artwork == nil
    }
}

private enum TVAudioPresentationMetadataExtractor {
    static func localMetadata(from url: URL) async -> TVAudioPresentationMetadata {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: extractLocalMetadata(from: url))
            }
        }
    }

    private static func extractLocalMetadata(from url: URL) -> TVAudioPresentationMetadata {
        let asset = AVURLAsset(url: url)
        var metadata = metadata(from: asset.commonMetadata)

        for format in asset.availableMetadataFormats where metadata.artwork == nil ||
            metadata.title == nil ||
            metadata.artist == nil ||
            metadata.album == nil {
            let formatMetadata = self.metadata(from: asset.metadata(forFormat: format))
            metadata.title = metadata.title ?? formatMetadata.title
            metadata.artist = metadata.artist ?? formatMetadata.artist
            metadata.album = metadata.album ?? formatMetadata.album
            metadata.artwork = metadata.artwork ?? formatMetadata.artwork
        }

        return metadata
    }

    private static func metadata(from items: [AVMetadataItem]) -> TVAudioPresentationMetadata {
        var metadata = TVAudioPresentationMetadata()

        for item in items {
            if metadata.title == nil, item.commonKey == .commonKeyTitle {
                metadata.title = tvPlaybackNormalizedMetadataText(item.stringValue)
            }
            if metadata.artist == nil, item.commonKey == .commonKeyArtist {
                metadata.artist = tvPlaybackNormalizedMetadataText(item.stringValue)
            }
            if metadata.album == nil, item.commonKey == .commonKeyAlbumName {
                metadata.album = tvPlaybackNormalizedMetadataText(item.stringValue)
            }
            if metadata.artwork == nil, let artwork = artwork(from: item) {
                metadata.artwork = artwork
            }
        }

        return metadata
    }

    private static func artwork(from item: AVMetadataItem) -> UIImage? {
        let identifier = item.identifier?.rawValue.lowercased() ?? ""
        let looksLikeArtwork = item.commonKey == .commonKeyArtwork ||
            identifier.contains("artwork") ||
            identifier.contains("cover") ||
            identifier.contains("covr") ||
            identifier.contains("apic")
        guard looksLikeArtwork else { return nil }

        if let data = item.dataValue {
            return UIImage(data: data)
        }
        if let data = item.value as? Data {
            return UIImage(data: data)
        }
        return item.value as? UIImage
    }
}

@MainActor
final class TVPlaybackTimeProgress: ObservableObject {
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var isScrubbing = false
    @Published var scrubTime: TimeInterval = 0
    @Published var bufferedRanges: [MPVBufferedRange] = []
    @Published var cacheInputBytesPerSecond: Int64?
    @Published var cacheReadIdle: Bool = false

    var displayCurrentTime: TimeInterval {
        isScrubbing ? scrubTime : currentTime
    }
}

@MainActor
private final class TVPlaybackSession: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    enum Panel: String, Identifiable, CaseIterable, Equatable, Hashable {
        case tracks
        case playback
        case picture
        case info

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tracks:
                return platformShellString("Audio & Subtitles")
            case .playback:
                return platformShellString("Playback Tuning")
            case .picture:
                return platformShellString("Display")
            case .info:
                return platformShellString("Details")
            }
        }

        var systemImageName: String {
            switch self {
            case .tracks:
                return "captions.bubble"
            case .playback:
                return "slider.horizontal.3"
            case .picture:
                return "rectangle.inset.filled"
            case .info:
                return "info.circle"
            }
        }
    }

    struct ControlFocusRequest: Identifiable {
        enum Target: Equatable {
            case panel(Panel)
            case transport
            case quickActions
        }

        let target: Target
        let id = UUID()
    }

    @Published var activeTrackGroup: TVPlaybackTrackGroup?
    @Published var activePlaybackGroup: TVPlaybackPlaybackGroup?
    @Published var activePictureGroup: TVPlaybackPictureGroup?
    @Published var activeInfoSectionID: String?

    @discardableResult
    func popOptionsSubmenu() -> Bool {
        let hadSubmenu = activeTrackGroup != nil || activePlaybackGroup != nil || activePictureGroup != nil || activeInfoSectionID != nil
        activeTrackGroup = nil
        activePlaybackGroup = nil
        activePictureGroup = nil
        activeInfoSectionID = nil
        return hadSubmenu
    }

    @Published var isLoading = true
    @Published var errorMessage: String?
    let timeProgress = TVPlaybackTimeProgress()

    var currentTime: TimeInterval {
        get { timeProgress.currentTime }
        set { timeProgress.currentTime = newValue }
    }

    var duration: TimeInterval {
        get { timeProgress.duration }
        set { timeProgress.duration = newValue }
    }

    var isScrubbing: Bool {
        get { timeProgress.isScrubbing }
        set { timeProgress.isScrubbing = newValue }
    }

    var scrubTime: TimeInterval {
        get { timeProgress.scrubTime }
        set { timeProgress.scrubTime = newValue }
    }

    var displayCurrentTime: TimeInterval {
        timeProgress.displayCurrentTime
    }

    @Published var audioTracks: [MediaTrack] = []
    @Published var subtitleTracks: [MediaTrack] = []
    @Published var currentAudioTrackID: Int = -1
    @Published var currentSubtitleTrackID: Int = -1
    @Published var secondarySubtitleTracks: [EmbeddedSubtitleTrack] = []
    @Published var currentSecondarySubtitleTrackID: String?
    @Published var secondarySubtitleStatus: SecondarySubtitleStatus = .disabled
    @Published var secondarySubtitleParts: [SubtitlePart] = []
    @Published var secondarySubtitleVerticalPositionRatio: Double? = TVPlaybackSettings.secondarySubtitleVerticalPositionRatio
    @Published var isSecondarySubtitlePositionAdjustmentActive = false
    @Published var isDirectSecondarySubtitlePositionAdjustmentActive = false
    @Published var isSecondarySubtitlesPreferenceEnabled = TVPlaybackSettings.isSecondarySubtitlesEnabled
    @Published var isChromeVisible = true
    @Published var activePanel: Panel?
    @Published var isShowingPlaylistOverlay: Bool = false
    @Published var requestedTrackGroup: TVPlaybackTrackGroup?
    @Published var requestedPlaybackGroup: TVPlaybackPlaybackGroup?
    @Published var controlFocusRequest: ControlFocusRequest?
    @Published var isPlaying = false
    @Published var seekFeedback: TVPlaybackSeekFeedback?
    @Published var scrubPreviewImage: UIImage?
    @Published var isScrubPreviewLoading = false
    @Published var audioArtwork: UIImage?
    @Published var audioMetadataTitle: String?
    @Published var audioMetadataArtist: String?
    @Published var audioMetadataAlbum: String?
    @Published var canPlayPreviousItem = false
    @Published var canPlayNextItem = false
    @Published var playbackRate: Float = 1.0
    @Published var videoDisplayMode: VideoDisplayMode = .fit
    @Published var aspectRatio: String = ""
    @Published var decoderPreference: TVPlaybackVideoDecoder = TVPlaybackVideoDecoder.defaultPreference
    @Published var currentDecoder: TVPlaybackVideoDecoder = TVPlaybackVideoDecoder.resolved(TVPlaybackVideoDecoder.defaultPreference)
    @Published var audioDelay: Double = TVPlaybackSettings.audioDelaySeconds
    @Published var subtitleDelay: Double = TVPlaybackSettings.subtitleDelaySeconds
    @Published var playbackQualityOptions: [RemotePlaybackQualityOption] = []
    @Published var selectedPlaybackQualityID: String = RemotePlaybackQualityOption.original.id

    let request: TVPlaybackCoordinator.Request
    private(set) var player: VLCMediaPlayer? = VLCPlaybackTransport.makePlayer()
    @Published private(set) var isUsingMPV = false
    private var mpv: MPVPlaybackEngine?
    private var mpvReadAheadByteCache: MPVReadAheadByteCache?
    private var mpvSnapshot: MPVPlaybackEngine.State?
    private var systemAudio: TVMPVAudioControls?
    private var playbackAttempt = UUID()
    private var engineOverride: String?
    private var pauseRequested = false
    private var mpvChoices: [String: MacMPVTrackChoice] = [:]
    private var mpvPendingChoices: [String: MacMPVTrackChoice] = [:]
    private var mpvPreferenceKey = ""
    private var mpvSelectionRequest: UUID?
    private var pendingCoreTracks: [String: IOSPlaybackTrackSelection] = [:]
    private var lastMPVHistoryTime: Double = -10
    private var mpvSecondaryID: Int?
    private var mpvExternalSources: [URL: URL] = [:]
    private var mpvServerSubtitlesRegistered = Set<String>()
    private var mpvSidecarTask: Task<Void, Never>?
    private var pendingMPVExternal: URL?
    private var pendingSecondChoice: IOSPlaybackSecondarySelection?
    private var pendingSecondOff = false
    private var isResolvingPlayback = false
    private var videoSize: CGSize { mpvSnapshot?.size ?? (player?.videoSize ?? .zero) }
    private var engineName: String { isUsingMPV ? "mpv" : "VLC" }


    /// Cached bundled CJK font metadata for VLC freetype/libass subtitle rendering.
    private var resolvedCJKFontFamily = "HelveticaNeue"
    private var resolvedCJKFontDirectory: String?
    private var resolvedFile: VideoFile?
    private weak var drawableView: UIView?
    private var didStart = false
    private var pendingInitialSeek: TimeInterval?
    private var currentPlaySessionId: String = UUID().uuidString
    private var lastServerProgressReportTime: TimeInterval = 0
    private var serverReportTask: Task<Void, Never>?
    private var hasReportedServerStart = false
    private var pendingAudioTrack: Int?
    private var pendingSubtitleTrack: Int?
    private var pendingAudioTrackQuery: String?
    private var pendingSubtitleTrackQuery: String?
    private var pendingAudioTrackOrdinal: Int?
    private var pendingSubtitleTrackOrdinal: Int?
    private var pendingSecondarySubtitleTrackQuery: String?
    private var pendingSecondarySubtitleTrackOrdinal: Int?
    private var hasPresentedFirstFrame = false
    private var hideChromeWorkItem: DispatchWorkItem?
    private var hideSeekFeedbackWorkItem: DispatchWorkItem?
    private var nativeMenuDismissAction: (() -> Void)?
    private(set) var isNativeMenuPresented = false
    private var lastExitCommandTimestamp: Date = .distantPast

    func shouldHandleExitCommand() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastExitCommandTimestamp) >= 0.35 else { return false }
        lastExitCommandTimestamp = now
        return true
    }
    private var deferredNativeMenuTrackRefreshNeeded = false
    private var lastTrackRefreshTime: TimeInterval = 0
    private var normalizedSubtitleCache: [String: URL] = [:]
    private var currentExternalSubtitleURL: URL?
    private var externalSubtitleResolvedTrackIDs: [String: Int] = [:]
    private var hasAdjustedScrubTime = false
    private var scrubPreviewDebounceWorkItem: DispatchWorkItem?
    private var scrubPreviewRemoteTask: Task<Void, Never>?
    private var scrubPreviewThumbnailGenerator: (any PlaybackPreviewProvider)?
    private var scrubPreviewRequestID: UUID?
    private var scrubPreviewCache: [String: UIImage] = [:]
    private var scrubPreviewCacheOrder: [String] = []
    private var audioMetadataWorkItems: [DispatchWorkItem] = []
    private var localAudioMetadataTask: Task<Void, Never>?
    private var remoteAudioArtworkTask: Task<Void, Never>?
    private var remoteAudioMetadataTask: Task<Void, Never>?
    private var playlistFiles: [VideoFile] = []
    private var currentPlaylistIndex: Int = -1
    private var playbackTask: Task<Void, Never>?
    private var secondarySubtitleLoadTask: Task<Void, Never>?
    private var secondarySubtitleTimeline: SubtitleTimeline?
    private var secondarySubtitleTimelineCache: [String: SubtitleTimeline] = [:]
    private var secondarySubtitleTimelineCacheOrder: [String] = []
    private var localEmbeddedSubtitleDescriptorCache: [String: [SharedLocalEmbeddedSubtitleDescriptor]] = [:]
    private var secondarySubtitleAdjustmentHideWorkItem: DispatchWorkItem?
    private var sessionPlaybackRate: Float?

    private let subtitleTrackOffID = -1
    private let externalSubtitleTrackBaseID = 10_000
    private let scrubPreviewCacheLimit = 18
    private let secondarySubtitleTimelineCacheLimit = 24

    var displayTitle: String {
        if tvPlaybackIsAListFile(request.file) {
            return request.file.name
        }
        return resolvedFile?.name ?? request.file.name
    }

    var displayPlaybackTitle: String {
        if isAudioPlayback,
           !tvPlaybackIsAListFile(displayFile),
           let title = tvPlaybackNormalizedMetadataText(audioMetadataTitle) {
            return title
        }
        return displayTitle
    }

    var audioSubtitleText: String {
        if let status = playbackStatusText {
            return status
        }

        let artist = tvPlaybackNormalizedMetadataText(audioMetadataArtist)
        let album = tvPlaybackNormalizedMetadataText(audioMetadataAlbum)
        switch (artist, album) {
        case let (artist?, album?):
            return "\(artist) · \(album)"
        case let (artist?, nil):
            return artist
        case let (nil, album?):
            return album
        default:
            return platformShellString("Audio")
        }
    }

    var displayFile: VideoFile {
        resolvedFile ?? request.file
    }

    @MainActor
    var showsDownloadedIconBeforeTitle: Bool {
        [displayFile, request.file].contains { file in
            if file.url.isFileURL,
               DownloadCenterService.shared.isTrackedLocalDownload(file.url) {
                return true
            }
            guard file.isRemote else { return false }
            return DownloadCenterService.shared.isDownloaded(file: file)
        }
    }

    var isAudioPlayback: Bool {
        displayFile.type == .audio
    }

    var isLiveStream: Bool {
        displayFile.isLiveStream
    }

    var shouldShowLoadingIndicator: Bool {
        isLoading && errorMessage == nil
    }

    var shouldShowChrome: Bool {
        isAudioPlayback || isChromeVisible || activePanel != nil || errorMessage != nil || isShowingPlaylistOverlay
    }

    var playbackStatusText: String? {
        if let errorMessage {
            return errorMessage
        }
        if isLoading {
            return platformShellString("Platform Shell TV Loading")
        }
        return nil
    }

    var playPauseTitle: String {
        isPlaying ? platformShellString("Pause") : platformShellString("Play")
    }

    var hasAudioTrackOptions: Bool {
        !audioTracks.isEmpty
    }

    var isSecondarySubtitlesEnabled: Bool {
        isSecondarySubtitlesPreferenceEnabled && !isAudioPlayback
    }

    var hasSubtitleTrackOptions: Bool {
        !subtitleTracks.isEmpty || (isSecondarySubtitlesEnabled && !secondarySubtitleTracks.isEmpty)
    }

    var hasSecondarySubtitleTrackOptions: Bool {
        isSecondarySubtitlesEnabled && !secondarySubtitleTracks.isEmpty
    }

    var hasPlaylistOptions: Bool {
        playlistFiles.count > 1
    }

    var quickActionSnapshot: TVPlaybackQuickActionsView.Snapshot {
        TVPlaybackQuickActionsView.Snapshot(
            hasPlaylistOptions: hasPlaylistOptions,
            isShowingPlaylistOverlay: isShowingPlaylistOverlay,
            hasAudioTrackOptions: hasAudioTrackOptions,
            audioTracks: audioTracks,
            currentAudioTrackID: currentAudioTrackID,
            hasSubtitleTrackOptions: hasSubtitleTrackOptions,
            subtitleTracks: subtitleTracks,
            currentSubtitleTrackID: currentSubtitleTrackID,
            isSecondarySubtitlesEnabled: isSecondarySubtitlesEnabled,
            secondarySubtitleTracks: secondarySubtitleTracks,
            currentSecondarySubtitleTrackID: currentSecondarySubtitleTrackID,
            isLiveStream: isLiveStream,
            availablePlaybackRates: availablePlaybackRates,
            playbackRate: playbackRate,
            isAudioPlayback: isAudioPlayback,
            selectedPlaybackQualityID: selectedPlaybackQualityID,
            playbackQualityOptions: playbackQualityOptions,
            videoDisplayMode: videoDisplayMode,
            aspectRatio: aspectRatio,
            availableAspectRatios: tvAvailableAspectRatios,
            isOptionsDrawerActive: activePanel != nil,
            controlFocusTarget: controlFocusRequest?.target,
            shouldPreferQuickActionControlFocus: shouldPreferQuickActionControlFocus
        )
    }

    var playlistItems: [TVPlaybackPlaylistItem] {
        playlistFiles.enumerated().map { index, file in
            let isCurrent = index == currentPlaylistIndex
            let effectiveDuration = max(file.duration ?? 0, isCurrent ? duration : 0)
            let resumeTime = max(isCurrent ? currentTime : (file.lastPlayedPosition ?? 0), 0)
            let progress = effectiveDuration > 0
                ? min(max(resumeTime / effectiveDuration, 0), 1)
                : 0
            let durationText = effectiveDuration > 0 ? tvPlaybackTimeText(effectiveDuration) : nil
            let progressText: String?
            if effectiveDuration > 0, resumeTime > 0 {
                progressText = "\(tvPlaybackTimeText(resumeTime)) / \(tvPlaybackTimeText(effectiveDuration))"
            } else {
                progressText = durationText
            }

            return TVPlaybackPlaylistItem(
                index: index,
                title: file.name,
                subtitle: progressText,
                artworkURL: tvPlaybackStoredArtworkURL(for: file),
                type: file.type,
                durationText: durationText,
                progressText: progressText,
                progress: progress,
                metadataText: tvPlaybackPlaylistMetadataText(for: file),
                isCurrent: isCurrent
            )
        }
    }

    var canAdjustSecondarySubtitlePosition: Bool {
        isSecondarySubtitlesEnabled &&
            (currentSecondarySubtitleTrackID != nil ||
                !secondarySubtitleParts.isEmpty ||
                secondarySubtitleStatus == .loading)
    }

    var secondarySubtitlePositionSummary: String {
        let ratio = currentSecondarySubtitleVerticalPositionRatio()
        return String(format: "%d%%", Int((ratio * 100.0).rounded()))
    }

    var optionPanels: [Panel] {
        var panels: [Panel] = []
        if hasAudioTrackOptions || hasSubtitleTrackOptions {
            panels.append(.tracks)
        }
        panels.append(.playback)
        if !isAudioPlayback {
            panels.append(.picture)
        }
        panels.append(.info)
        return panels
    }

    var hasPlaybackOptions: Bool {
        !optionPanels.isEmpty
    }

    var activeOptionsPanel: Panel? {
        if let activePanel, optionPanels.contains(activePanel) {
            return activePanel
        }
        return defaultOptionsPanel
    }

    var shouldShowSecondarySubtitleOverlay: Bool {
        isSecondarySubtitlesEnabled &&
            (!secondarySubtitleParts.isEmpty ||
                secondarySubtitleStatus == .loading ||
                isSecondarySubtitlePositionAdjustmentActive)
    }

    var shouldPreferTransportControlFocus: Bool {
        guard activePanel == nil else { return false }
        guard let request = controlFocusRequest else { return true }
        return request.target == .transport
    }

    var shouldPreferQuickActionControlFocus: Bool {
        guard activePanel == nil else { return false }
        return controlFocusRequest?.target == .quickActions
    }

    private var defaultOptionsPanel: Panel? {
        if hasAudioTrackOptions || hasSubtitleTrackOptions {
            return .tracks
        }
        return .playback
    }

    var configuredSeekDuration: TimeInterval {
        let fallback: TimeInterval = 15
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "doubleTapSeekDuration") != nil else {
            return fallback
        }

        let storedValue = defaults.double(forKey: "doubleTapSeekDuration")
        guard storedValue.isFinite, storedValue > 0 else {
            return fallback
        }

        return storedValue
    }

    var mediaInfoSections: [TVPlaybackMediaInfoSection] {
        var sections: [TVPlaybackMediaInfoSection] = []
        let file = displayFile
        let streams = file.serverMediaStreams ?? []
        let hasServerStreams = !streams.isEmpty

        var general: [(key: String, value: String)] = []
        appendInfoRow(&general, platformShellString("MPV.Engine"), engineName)
        appendInfoRow(&general, platformShellString("Title"), file.name)
        appendInfoRow(&general, platformShellString("Path"), file.serverPath ?? file.url.path)

        let container = file.serverContainer ?? file.url.pathExtension
        appendInfoRow(&general, platformShellString("Container"), container.uppercased())

        if !sessionQualityTitle.isEmpty {
            appendInfoRow(&general, platformShellString("Requested Quality"), sessionQualityTitle)
        }

        if let method = file.remotePlaybackMethod {
            appendInfoRow(&general, platformShellString("Play Method"), localizedPlaybackMethod(method))
        }

        if let playbackResolution = currentPlaybackResolutionDisplay() {
            appendInfoRow(
                &general,
                hasServerStreams ? platformShellString("Playback Resolution") : platformShellString("Resolution"),
                playbackResolution
            )
        }

        if duration > 0 {
            appendInfoRow(&general, platformShellString("Duration"), tvPlaybackTimeText(duration))
        } else if let fileDuration = file.duration, fileDuration > 0 {
            appendInfoRow(&general, platformShellString("Duration"), tvPlaybackTimeText(fileDuration))
        }

        if let size = file.serverSize, size > 0 {
            appendInfoRow(&general, platformShellString("Size"), tvPlaybackFileSizeText(size))
        } else if file.size > 0 {
            appendInfoRow(&general, platformShellString("Size"), tvPlaybackFileSizeText(file.size))
        }

        if let bitrate = file.serverBitrate, bitrate > 0 {
            appendInfoRow(&general, platformShellString("Bitrate"), tvPlaybackBitrateText(bitrate))
        }

        if !isAudioPlayback {
            appendInfoRow(&general, platformShellString("Decoder Preference"), decoderPreference.localizedName)
            appendInfoRow(&general, platformShellString("Effective Decoder"), currentDecoder.localizedName)
        }

        if !general.isEmpty {
            sections.append(TVPlaybackMediaInfoSection(
                title: platformShellString("General"),
                icon: "info.circle.fill",
                items: general
            ))
        }

        if hasServerStreams {
            sections.append(contentsOf: serverStreamInfoSections(from: streams))
        } else if isAudioPlayback {
            sections.append(contentsOf: localTrackInfoSections())
        }

        if !isAudioPlayback, isUsingMPV, let info = mpvSnapshot?.hdrInfo, info.isHDR {
            sections.insert(TVPlaybackMediaInfoSection(title: platformShellString("HDR.Info.Title"), icon: "sun.max.fill",
                items: info.rows(localize: platformShellString)), at: min(1, sections.count))
        }

        return sections
    }

    private var sessionQualityTitle: String {
        tvPlaybackQualityTitle(for: RemotePlaybackQualityOption.option(for: selectedPlaybackQualityID))
    }

    func decoderDetailText(for decoder: TVPlaybackVideoDecoder) -> String? {
        let resolved = TVPlaybackVideoDecoder.resolved(decoder)
        guard resolved != decoder else { return nil }
        return String(format: platformShellString("Effective Decoder Format"), resolved.localizedName)
    }

    private func serverStreamInfoSections(from streams: [[String: Any]]) -> [TVPlaybackMediaInfoSection] {
        var sections: [TVPlaybackMediaInfoSection] = []

        if isAudioPlayback {
            let audioStreams = streams.filter { tvStreamString($0, "Type") == "Audio" }
            let audioCount = audioStreams.count
            for (index, stream) in audioStreams.enumerated() {
                let title = audioCount > 1
                    ? "\(platformShellString("Audio")) \(index + 1)"
                    : platformShellString("Audio")
                sections.append(TVPlaybackMediaInfoSection(
                    title: title,
                    icon: "speaker.wave.2.fill",
                    items: audioStreamInfoRows(stream)
                ))
            }
            return sections
        }

        let videoStreams = streams.filter { tvStreamString($0, "Type") == "Video" }
        let videoCount = videoStreams.count
        for (index, stream) in videoStreams.enumerated() {
            let title = videoCount > 1
                ? "\(platformShellString("Video")) \(index + 1)"
                : platformShellString("Video")
            sections.append(TVPlaybackMediaInfoSection(
                title: title,
                icon: "film.fill",
                items: videoStreamInfoRows(stream)
            ))
        }

        return sections
    }

    private func localTrackInfoSections() -> [TVPlaybackMediaInfoSection] {
        var sections: [TVPlaybackMediaInfoSection] = []

        if !audioTracks.isEmpty {
            for (index, track) in audioTracks.enumerated() {
                let title = audioTracks.count > 1
                    ? "\(platformShellString("Audio")) \(index + 1)"
                    : platformShellString("Audio")
                sections.append(TVPlaybackMediaInfoSection(
                    title: title,
                    icon: "speaker.wave.2.fill",
                    items: [(key: platformShellString("Title"), value: track.name)]
                ))
            }
        }

        if !subtitleTracks.isEmpty {
            for (index, track) in subtitleTracks.enumerated() {
                let title = subtitleTracks.count > 1
                    ? "\(platformShellString("Subtitle")) \(index + 1)"
                    : platformShellString("Subtitle")
                sections.append(TVPlaybackMediaInfoSection(
                    title: title,
                    icon: "captions.bubble.fill",
                    items: [(key: platformShellString("Title"), value: track.name)]
                ))
            }
        }

        return sections
    }

    private func videoStreamInfoRows(_ stream: [String: Any]) -> [(key: String, value: String)] {
        var items: [(key: String, value: String)] = []
        appendInfoRow(&items, platformShellString("Title"), tvStreamString(stream, "DisplayTitle"))
        appendInfoRow(&items, platformShellString("Codec"), tvStreamString(stream, "Codec")?.uppercased())
        if let width = tvStreamInt(stream, "Width"),
           let height = tvStreamInt(stream, "Height"),
           width > 0,
           height > 0 {
            appendInfoRow(&items, platformShellString("Resolution"), "\(width)x\(height)")
        }
        if let bitrate = tvStreamInt(stream, "BitRate"), bitrate > 0 {
            appendInfoRow(&items, platformShellString("Bitrate"), tvPlaybackBitrateText(bitrate))
        }
        if let fps = tvStreamDouble(stream, "RealFrameRate") ?? tvStreamDouble(stream, "AverageFrameRate"), fps > 0 {
            appendInfoRow(&items, platformShellString("Framerate"), String(format: "%.3f fps", fps))
        }
        appendInfoRow(&items, platformShellString("Profile"), tvStreamString(stream, "Profile"))
        if let level = tvStreamInt(stream, "Level") {
            appendInfoRow(&items, platformShellString("Level"), "\(level)")
        }
        appendInfoRow(&items, platformShellString("Aspect Ratio"), tvStreamString(stream, "AspectRatio"))
        if let bitDepth = tvStreamInt(stream, "BitDepth") {
            appendInfoRow(&items, platformShellString("Bit Depth"), "\(bitDepth) bit")
        }
        appendInfoRow(&items, platformShellString("Pixel Format"), tvStreamString(stream, "PixelFormat"))
        appendInfoRow(&items, platformShellString("Video Range"), tvStreamString(stream, "VideoRange"))
        return items
    }

    private func audioStreamInfoRows(_ stream: [String: Any]) -> [(key: String, value: String)] {
        var items: [(key: String, value: String)] = []
        appendInfoRow(&items, platformShellString("Title"), tvStreamString(stream, "DisplayTitle"))
        appendInfoRow(&items, platformShellString("Language"), tvStreamString(stream, "Language"))
        appendInfoRow(&items, platformShellString("Codec"), tvStreamString(stream, "Codec")?.uppercased())
        appendInfoRow(&items, platformShellString("Layout"), tvStreamString(stream, "ChannelLayout"))
        if let channels = tvStreamInt(stream, "Channels"), channels > 0 {
            appendInfoRow(&items, platformShellString("Channels"), "\(channels) ch")
        }
        if let rate = tvStreamInt(stream, "SampleRate"), rate > 0 {
            appendInfoRow(&items, platformShellString("Sample Rate"), "\(rate) Hz")
        }
        if let bitrate = tvStreamInt(stream, "BitRate"), bitrate > 0 {
            appendInfoRow(&items, platformShellString("Bitrate"), tvPlaybackBitrateText(bitrate))
        }
        if let isDefault = tvStreamBool(stream, "IsDefault") {
            appendInfoRow(&items, platformShellString("Default"), tvPlaybackYesNoText(isDefault))
        }
        return items
    }

    private func subtitleStreamInfoRows(_ stream: [String: Any]) -> [(key: String, value: String)] {
        var items: [(key: String, value: String)] = []
        appendInfoRow(&items, platformShellString("Title"), tvStreamString(stream, "DisplayTitle"))
        appendInfoRow(&items, platformShellString("Language"), tvStreamString(stream, "Language"))
        appendInfoRow(&items, platformShellString("Codec"), tvStreamString(stream, "Codec")?.uppercased())
        if let isDefault = tvStreamBool(stream, "IsDefault") {
            appendInfoRow(&items, platformShellString("Default"), tvPlaybackYesNoText(isDefault))
        }
        if tvStreamBool(stream, "IsForced") == true {
            appendInfoRow(&items, platformShellString("Forced"), platformShellString("Yes"))
        }
        if tvStreamBool(stream, "IsExternal") == true {
            appendInfoRow(&items, platformShellString("External"), platformShellString("Yes"))
        }
        return items
    }

    private func currentPlaybackResolutionDisplay() -> String? {
        let videoSize = self.videoSize
        if videoSize.width > 0, videoSize.height > 0 {
            return "\(Int(videoSize.width))x\(Int(videoSize.height))"
        }

        guard let streams = displayFile.serverMediaStreams else { return nil }
        guard let videoStream = streams.first(where: { tvStreamString($0, "Type") == "Video" }) else { return nil }
        guard let width = tvStreamInt(videoStream, "Width"),
              let height = tvStreamInt(videoStream, "Height"),
              width > 0,
              height > 0 else {
            return nil
        }
        return "\(width)x\(height)"
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

    private func appendInfoRow(
        _ items: inout [(key: String, value: String)],
        _ key: String,
        _ value: String?
    ) {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return
        }
        items.append((key: key, value: value))
    }

    init(request: TVPlaybackCoordinator.Request) {
        self.request = request
        let normalizedPlaylist = Self.normalizedPlaylist(for: request)
        self.playlistFiles = normalizedPlaylist.files
        self.currentPlaylistIndex = normalizedPlaylist.index
        super.init()
        player?.delegate = self
        configureTextRenderer(for: player)
        updatePlaylistAvailability()
    }

    private static func normalizedPlaylist(for request: TVPlaybackCoordinator.Request) -> (files: [VideoFile], index: Int) {
        let rawPlaylist = request.playlist ?? []
        let typedPlaylist = rawPlaylist.filter { file in
            request.file.type == .unknown || file.type == request.file.type
        }
        var files = typedPlaylist.isEmpty ? rawPlaylist : typedPlaylist
        if files.isEmpty {
            files = [request.file]
        }

        if !files.contains(where: { playlistItemsMatch($0, request.file) }) {
            files.append(request.file)
        }

        let index = files.firstIndex(where: { playlistItemsMatch($0, request.file) }) ?? 0
        return (files, index)
    }

    private static func playlistItemsMatch(_ lhs: VideoFile, _ rhs: VideoFile) -> Bool {
        if let lhsItemId = tvTrimmedPlaybackText(lhs.jellyfinItemId),
           let rhsItemId = tvTrimmedPlaybackText(rhs.jellyfinItemId),
           lhsItemId == rhsItemId {
            let lhsServerId = tvTrimmedPlaybackText(lhs.jellyfinServerId)
            let rhsServerId = tvTrimmedPlaybackText(rhs.jellyfinServerId)
            return lhsServerId == nil || rhsServerId == nil || lhsServerId == rhsServerId
        }

        if lhs.url == rhs.url {
            return true
        }

        return RuntimeNetworkAddressResolver.runtimeURL(from: lhs.url) == RuntimeNetworkAddressResolver.runtimeURL(from: rhs.url)
    }

    func attachDrawable(_ view: UIView) {
        guard drawableView !== view else { return }
        drawableView = view
        view.clipsToBounds = true
        if let mpv { mountMPV(mpv, in: view) }
        else { player?.drawable = view }
        updateDrawableLayout()
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        startPlayback(file: request.file, playlistIndex: currentPlaylistIndex)
    }

    private func startPlayback(file sourceFile: VideoFile, playlistIndex: Int,
                               rebuilding: Bool = false, startPaused: Bool = false) {
        if player?.media != nil || mpv != nil {
            syncHistoryProgress()
            syncServerProgress(eventName: "stop")
            player?.stop()
        }
        let replacingMPV = mpv != nil
        playbackAttempt = UUID()
        let attempt = playbackAttempt
        mpvSidecarTask?.cancel(); mpvSidecarTask = nil
        isResolvingPlayback = true
        systemAudio?.stop(keepingAudioSession: true); systemAudio = nil
        mpv?.stop()
        mpv?.videoSurfaceView.removeFromSuperview()
        mpv = nil
        mpvReadAheadByteCache = nil
        mpvSnapshot = nil
        timeProgress.bufferedRanges = []
        timeProgress.cacheInputBytesPerSecond = nil
        timeProgress.cacheReadIdle = false
        isUsingMPV = false
        mpvSelectionRequest = nil
        mpvSecondaryID = nil
        mpvExternalSources.removeAll()
        mpvServerSubtitlesRegistered.removeAll()
        pendingMPVExternal = nil
        lastMPVHistoryTime = -10
        pauseRequested = startPaused
        if !rebuilding {
            engineOverride = nil
            pendingCoreTracks = [:]
            pendingSecondChoice = nil
            pendingSecondOff = false
        }
        // A VLC object used before mpv must not deliver queued events to a new VLC attempt.
        if (rebuilding && engineOverride != nil) || replacingMPV {
            let old = player
            old?.delegate = nil
            old?.drawable = nil
            player = VLCPlaybackTransport.makePlayer()
            player?.delegate = self
            configureTextRenderer(for: player)
        }
        hasReportedServerStart = false
        playbackTask?.cancel()
        secondarySubtitleLoadTask?.cancel()
        secondarySubtitleLoadTask = nil
        secondarySubtitleAdjustmentHideWorkItem?.cancel()
        secondarySubtitleAdjustmentHideWorkItem = nil
        cancelAudioPresentationLoads()
        hideChromeWorkItem?.cancel()
        hideChromeWorkItem = nil
        hideSeekFeedbackWorkItem?.cancel()
        hideSeekFeedbackWorkItem = nil
        clearScrubPreview()
        activePanel = nil
        popOptionsSubmenu()
        isNativeMenuPresented = false
        nativeMenuDismissAction = nil
        deferredNativeMenuTrackRefreshNeeded = false
        seekFeedback = nil
        isScrubbing = false
        hasAdjustedScrubTime = false
        errorMessage = nil
        isLoading = true
        isChromeVisible = true
        audioArtwork = nil
        audioMetadataTitle = nil
        audioMetadataArtist = nil
        audioMetadataAlbum = nil
        currentTime = 0
        duration = sourceFile.duration ?? 0
        audioTracks = []
        subtitleTracks = []
        currentAudioTrackID = -1
        currentSubtitleTrackID = -1
        secondarySubtitleTracks = []
        currentSecondarySubtitleTrackID = nil
        secondarySubtitleStatus = .disabled
        secondarySubtitleParts = []
        secondarySubtitleTimeline = nil
        secondarySubtitleVerticalPositionRatio = TVPlaybackSettings.secondarySubtitleVerticalPositionRatio
        isSecondarySubtitlePositionAdjustmentActive = false
        isSecondarySubtitlesPreferenceEnabled = TVPlaybackSettings.isSecondarySubtitlesEnabled
        playbackRate = sessionPlaybackRate ?? TVPlaybackSettings.defaultPlaybackRate(for: sourceFile.type)
        if !rebuilding { videoDisplayMode = .fit; aspectRatio = "" }
        audioDelay = TVPlaybackSettings.audioDelaySeconds
        subtitleDelay = TVPlaybackSettings.subtitleDelaySeconds
        playbackQualityOptions = []
        selectedPlaybackQualityID = TVPlaybackSettings.resolvedRemotePlaybackQualityID(for: sourceFile.preferredPlaybackQualityID)
        pendingInitialSeek = nil
        pendingAudioTrack = nil
        pendingSubtitleTrack = nil
        pendingAudioTrackQuery = nil
        pendingSubtitleTrackQuery = nil
        pendingAudioTrackOrdinal = nil
        pendingSubtitleTrackOrdinal = nil
        pendingSecondarySubtitleTrackQuery = nil
        pendingSecondarySubtitleTrackOrdinal = nil
        currentPlaySessionId = UUID().uuidString
        hasReportedServerStart = false
        lastServerProgressReportTime = 0
        lastTrackRefreshTime = 0
        currentExternalSubtitleURL = nil
        externalSubtitleResolvedTrackIDs = [:]
        hasPresentedFirstFrame = false
        currentPlaylistIndex = playlistIndex
        updatePlaylistAvailability()
        revealChromeTemporarily()

        playbackTask = Task {
            do {
                let offlineSourceFile = await MainActor.run {
                    DownloadCenterService.shared.localPlaybackFile(for: sourceFile)
                }
                var file = try await tvResolvePlaybackFile(from: offlineSourceFile ?? sourceFile)
                if Task.isCancelled { return }

                if file.type == .video {
                    file.externalSubtitleCandidates = tvPlaybackSidecarCandidates(
                        for: file, playlist: request.playlist ?? playlistFiles
                    )
                }

                let storedTrackPreference = tvStoredTrackQueryPreference(for: file)
                let preferredAudioQuery = file.preferredAudioTrackQuery ?? storedTrackPreference.audioQuery
                let preferredSubtitleQuery = file.preferredSubtitleTrackQuery ?? storedTrackPreference.subtitleQuery
                let shouldDisableSubtitles = file.disableSubtitlesOnStart
                    || (file.preferredSubtitleTrackQuery == nil && file.preferredSubtitleTrackOrdinal == nil
                        && storedTrackPreference.subtitlesDisabled == true)
                if shouldDisableSubtitles {
                    file.disableSubtitlesOnStart = true
                }
                resolvedFile = file
                playbackQualityOptions = TVPlaybackSettings.visibleRemotePlaybackQualityOptions(
                    from: file.availablePlaybackQualityOptions
                )
                selectedPlaybackQualityID = TVPlaybackSettings.resolvedRemotePlaybackQualityID(
                    for: file.preferredPlaybackQualityID
                )
                await hydrateSeasonPlaylistIfNeeded(for: file)
                guard !Task.isCancelled, playbackAttempt == attempt else { return }
                currentPlaylistIndex = normalizedPlaylistIndex(for: file, fallback: playlistIndex)
                updatePlaylistAvailability()
                pendingInitialSeek = file.lastPlayedPosition
                let shouldSaveHistory = HistoryService.isHistoryEnabled(for: file)
                let savedTracks = shouldSaveHistory
                    ? HistoryService.shared.getLastTrackSelection(for: file.url)
                    : nil
                let seriesTracks = tvStoredSeriesTrackPreference(for: file)
                let savedAudioTrack = file.lastAudioTrack ?? savedTracks?.audio ?? seriesTracks?.audio
                let savedSubtitleTrack = file.lastSubtitleTrack ?? savedTracks?.subtitle ?? seriesTracks?.subtitle
                pendingAudioTrack = pendingCoreTracks["audio"] == nil ? savedAudioTrack : nil
                pendingSubtitleTrack = shouldDisableSubtitles ? subtitleTrackOffID : (pendingCoreTracks["sub"] == nil ? savedSubtitleTrack : nil)
                pendingAudioTrackQuery = savedAudioTrack == nil ? preferredAudioQuery : nil
                pendingSubtitleTrackQuery = (!shouldDisableSubtitles && savedSubtitleTrack == nil) ? preferredSubtitleQuery : nil
                pendingAudioTrackOrdinal = savedAudioTrack == nil ? file.preferredAudioTrackOrdinal : nil
                pendingSubtitleTrackOrdinal = (!shouldDisableSubtitles && savedSubtitleTrack == nil) ? file.preferredSubtitleTrackOrdinal : nil
                if pendingCoreTracks["audio"] != nil { pendingAudioTrackQuery = nil; pendingAudioTrackOrdinal = nil }
                if pendingCoreTracks["sub"] != nil { pendingSubtitleTrackQuery = nil; pendingSubtitleTrackOrdinal = nil }
                let preferredSecondarySubtitle = storedSecondarySubtitlePreference(for: file)
                pendingSecondarySubtitleTrackQuery = preferredSecondarySubtitle.query
                pendingSecondarySubtitleTrackOrdinal = preferredSecondarySubtitle.ordinal
                if shouldSaveHistory {
                    HistoryService.shared.addToHistory(file)
                }

                let preferredExternalSubtitleURL = shouldDisableSubtitles || file.type == .audio ? nil : tvPreferredSubtitleURL(
                    for: file,
                    playlist: request.playlist ?? playlistFiles
                )
                currentExternalSubtitleURL = preferredExternalSubtitleURL
                guard let selectedEngine = PlaybackEngineAvailability.current.resolve(
                    preferred: engineOverride ?? UserDefaults.standard.string(forKey: "tvPlaybackEngine"),
                    supportsMPV: TVMPVPlaybackPolicy.supports(url: file.url, isVideo: file.type == .video, isAudio: file.type == .audio)) else {
                    isResolvingPlayback = false
                    isLoading = false
                    errorMessage = PlaybackEngineAvailability.unavailableMessage
                    playbackTask = nil
                    return
                }
                let usesMPV = selectedEngine == .mpv
                let preparedSubtitleURL: URL?
                if usesMPV && (preferredExternalSubtitleURL == nil || preferredExternalSubtitleURL.map(TVMPVSubtitleLoader.requiresDownload) == true) {
                    // Do not fall back to preparing a preferred sidecar when subtitles are off.
                    preparedSubtitleURL = preferredExternalSubtitleURL
                } else {
                    preparedSubtitleURL = file.type == .audio ? nil : await prepareSubtitlePlaybackURL(
                        for: file, playlist: request.playlist ?? playlistFiles, preferredSubtitleURL: preferredExternalSubtitleURL
                    )
                }
                guard !Task.isCancelled, playbackAttempt == attempt else { return }
                isResolvingPlayback = false
                if usesMPV {
                    startMPV(file: file, subtitle: preparedSubtitleURL, attempt: attempt)
                    playbackTask = nil
                    return
                }
                let media = playbackMedia(for: file)
                configureCJKFontOptions(for: media)
                configureSubtitleOptions(
                    for: media,
                    file: file,
                    preparedSubtitleURL: preparedSubtitleURL
                )
                configurePlaybackOptions(for: media, file: file)
                if Task.isCancelled { return }
                if pauseRequested {
                    media.addOption(":start-paused")
                    if let time = pendingInitialSeek, time > 0 {
                        media.addOption(":start-time=\(time)")
                        pendingInitialSeek = nil
                    }
                }
                player?.drawable = drawableView
                player?.videoAspectRatio = aspectRatio.isEmpty ? nil : UnsafeMutablePointer<Int8>(mutating: (aspectRatio as NSString).utf8String)
                player?.media = media
                prepareAudioPresentation(for: file, media: media)
                isLoading = true
                player?.play()
                applyPlaybackRate(playbackRate, persistsInSession: false, nudgesPlayback: false)
                playbackTask = nil
            } catch {
                if Task.isCancelled { return }
                isLoading = false
                isResolvingPlayback = false
                errorMessage = error.localizedDescription
                isChromeVisible = true
                playbackTask = nil
            }
        }
    }

    func stop() {
        playbackAttempt = UUID()
        mpvSidecarTask?.cancel(); mpvSidecarTask = nil
        isResolvingPlayback = false
        playbackTask?.cancel()
        playbackTask = nil
        secondarySubtitleLoadTask?.cancel()
        secondarySubtitleLoadTask = nil
        secondarySubtitleAdjustmentHideWorkItem?.cancel()
        secondarySubtitleAdjustmentHideWorkItem = nil
        cancelAudioPresentationLoads()
        secondarySubtitleTracks = []
        currentSecondarySubtitleTrackID = nil
        secondarySubtitleStatus = .disabled
        secondarySubtitleParts = []
        secondarySubtitleTimeline = nil
        isSecondarySubtitlePositionAdjustmentActive = false
        hideChromeWorkItem?.cancel()
        hideChromeWorkItem = nil
        hideSeekFeedbackWorkItem?.cancel()
        hideSeekFeedbackWorkItem = nil
        nativeMenuDismissAction = nil
        isNativeMenuPresented = false
        deferredNativeMenuTrackRefreshNeeded = false
        currentExternalSubtitleURL = nil
        externalSubtitleResolvedTrackIDs = [:]
        seekFeedback = nil
        isScrubbing = false
        hasAdjustedScrubTime = false
        clearScrubPreview()
        syncHistoryProgress()
        syncServerProgress(eventName: "stop")
        systemAudio?.stop(); systemAudio = nil
        mpv?.stop()
        mpv?.videoSurfaceView.removeFromSuperview()
        mpv = nil
        mpvReadAheadByteCache = nil
        mpvSnapshot = nil
        timeProgress.bufferedRanges = []
        timeProgress.cacheInputBytesPerSecond = nil
        timeProgress.cacheReadIdle = false
        player?.delegate = nil
        player?.stop()
        isPlaying = false
        drawableView?.transform = .identity
        player?.drawable = nil
        drawableView = nil
    }

    func togglePlayPause() {
        revealChromeTemporarily()
        if isResolvingPlayback { pauseRequested.toggle(); isPlaying = !pauseRequested; return }
        if let mpv {
            if mpvSnapshot?.ended == true {
                reloadPlayback(file: displayFile, fromBeginning: true)
                return
            }
            if errorMessage != nil { reloadCurrentItemPreservingPlaybackState(); return }
            pauseRequested = !pauseRequested
            systemAudio?.cancelPendingResume()
            if !pauseRequested, let systemAudio {
                let attempt = playbackAttempt
                systemAudio.resume { [weak self, weak mpv] ready in
                    guard let self, let mpv, self.playbackAttempt == attempt,
                          self.mpv === mpv, !self.pauseRequested, self.errorMessage == nil else { return }
                    self.pauseRequested = !ready
                    self.isPlaying = ready
                    let control = MPVPlaybackTransport(engine: mpv)
                    if ready { control.resume() } else { control.pause() }
                }
            } else {
                let control = MPVPlaybackTransport(engine: mpv)
                if pauseRequested { control.pause() } else { control.resume() }
                isPlaying = !pauseRequested
            }
            syncServerProgress(eventName: pauseRequested ? "pause" : "play", force: true)
            requestTransportControlFocus()
            return
        }
        if (player?.isPlaying ?? false) {
            pauseRequested = true
            transport.pause()
            isPlaying = false
        } else {
            pauseRequested = false
            transport.resume()
            isPlaying = true
        }
        requestTransportControlFocus()
    }

    func setPlaybackRate(_ rate: Float) {
        applyPlaybackRate(rate, persistsInSession: true)
    }

    func setVideoDisplayMode(_ mode: VideoDisplayMode) {
        guard videoDisplayMode != mode else { return }
        videoDisplayMode = mode
        updateDrawableLayout()
        revealChromeTemporarily()
    }

    func setAspectRatio(_ ratio: String) {
        guard aspectRatio != ratio else { return }
        aspectRatio = ratio
        mpv?.set("video-aspect-override", ratio.isEmpty ? "-1" : ratio)
        if ratio.isEmpty {
            player?.videoAspectRatio = nil
        } else {
            player?.videoAspectRatio = UnsafeMutablePointer<Int8>(mutating: (ratio as NSString).utf8String)
        }
        updateDrawableLayout()
        revealChromeTemporarily()
    }

    func setDecoder(_ decoder: TVPlaybackVideoDecoder) {
        guard decoderPreference != decoder else { return }
        let resolvedDecoder = TVPlaybackVideoDecoder.resolved(decoder)
        decoderPreference = decoder
        currentDecoder = resolvedDecoder
        reloadCurrentItemPreservingPlaybackState()
    }

    func setAudioDelay(_ seconds: Double) {
        let clamped = min(max(seconds, -10.0), 10.0)
        guard abs(audioDelay - clamped) > 0.001 else { return }
        audioDelay = clamped
        TVPlaybackSettings.audioDelaySeconds = clamped
        if let mpv { mpv.set("audio-delay", String(clamped)) }
        else { reloadCurrentItemPreservingPlaybackState() }
    }

    func setSubtitleDelay(_ seconds: Double) {
        let clamped = min(max(seconds, -10.0), 10.0)
        guard abs(subtitleDelay - clamped) > 0.001 else { return }
        subtitleDelay = clamped
        TVPlaybackSettings.subtitleDelaySeconds = clamped
        if let mpv {
            mpv.set("sub-delay", String(clamped))
            mpv.set("secondary-sub-delay", String(-clamped))
        } else { reloadCurrentItemPreservingPlaybackState() }
    }

    func setSecondarySubtitlesEnabled(_ enabled: Bool) {
        guard !isAudioPlayback else { return }
        guard isSecondarySubtitlesPreferenceEnabled != enabled else { return }
        TVPlaybackSettings.isSecondarySubtitlesEnabled = enabled
        isSecondarySubtitlesPreferenceEnabled = enabled
        if enabled {
            refreshSecondarySubtitleTracks()
        } else {
            clearSecondarySubtitleTrack()
            secondarySubtitleTracks = []
            secondarySubtitleStatus = .disabled
            secondarySubtitleParts = []
            secondarySubtitleTimeline = nil
            isSecondarySubtitlePositionAdjustmentActive = false
        }
        if let activePanel, !optionPanels.contains(activePanel) {
            self.activePanel = defaultOptionsPanel
        }
        revealChromeTemporarily()
    }

    func selectPlaybackQuality(_ optionID: String) {
        let resolvedID = TVPlaybackSettings.resolvedRemotePlaybackQualityID(for: optionID)
        guard selectedPlaybackQualityID != resolvedID else { return }
        selectedPlaybackQualityID = resolvedID
        var file = displayFile
        file.preferredPlaybackQualityID = resolvedID
        reloadPlayback(file: file)
    }

    func revealChromeTemporarily() {
        isChromeVisible = true
        guard activePanel == nil else { return }
        guard !isDirectSecondarySubtitlePositionAdjustmentActive else { return }
        guard !isAudioPlayback else { return }
        scheduleChromeAutoHide()
    }

    func hideChrome() {
        hideChromeWorkItem?.cancel()
        hideChromeWorkItem = nil
        guard !isAudioPlayback else {
            isChromeVisible = true
            return
        }
        guard activePanel == nil, !isDirectSecondarySubtitlePositionAdjustmentActive, !isScrubbing, errorMessage == nil else { return }
        isChromeVisible = false
    }

    func openOptionsDrawer() {
        guard let targetPanel = activeOptionsPanel else {
            revealChromeTemporarily()
            return
        }
        openPanel(targetPanel)
    }

    func openPanel(_ panel: Panel) {
        if isScrubbing {
            isScrubbing = false
            hasAdjustedScrubTime = false
            clearScrubPreview()
        }
        activePanel = optionPanels.contains(panel) ? panel : defaultOptionsPanel
        isChromeVisible = true
        hideChromeWorkItem?.cancel()
        hideChromeWorkItem = nil
    }

    func openTrackGroup(_ group: TVPlaybackTrackGroup) {
        requestedTrackGroup = group
        openPanel(.tracks)
    }

    func openPlaybackGroup(_ group: TVPlaybackPlaybackGroup) {
        requestedPlaybackGroup = group
        openPanel(.playback)
    }

    func closePanel(returnFocusTo panel: Panel? = nil) {
        activePanel = nil
        popOptionsSubmenu()
        revealChromeTemporarily()
        if let panel {
            controlFocusRequest = ControlFocusRequest(target: .panel(panel))
        }
    }

    func requestTransportControlFocus() {
        guard activePanel == nil else { return }
        isChromeVisible = true
        hideChromeWorkItem?.cancel()
        hideChromeWorkItem = nil
        controlFocusRequest = ControlFocusRequest(target: .transport)
    }

    func requestInitialAudioControlFocusIfNeeded() {
        guard isAudioPlayback, activePanel == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.isAudioPlayback,
                  self.activePanel == nil else {
                return
            }
            self.requestTransportControlFocus()
        }
    }

    func requestQuickActionControlFocus() {
        guard activePanel == nil else { return }
        isChromeVisible = true
        hideChromeWorkItem?.cancel()
        hideChromeWorkItem = nil
        controlFocusRequest = ControlFocusRequest(target: .quickActions)
    }

    func beginNativeMenuPresentation(dismiss: @escaping () -> Void) {
        isNativeMenuPresented = true
        nativeMenuDismissAction = dismiss
        isChromeVisible = true
        hideChromeWorkItem?.cancel()
        hideChromeWorkItem = nil
    }

    func dismissNativeMenu() {
        nativeMenuDismissAction?()
    }

    func finishNativeMenuPresentation() {
        lastExitCommandTimestamp = Date()
        nativeMenuDismissAction = nil
        let shouldRefreshTracks = deferredNativeMenuTrackRefreshNeeded
        deferredNativeMenuTrackRefreshNeeded = false
        isNativeMenuPresented = false
        syncPublishedPlaybackTiming()
        if shouldRefreshTracks { refreshTracks() }
        revealChromeTemporarily()
    }

    private func currentPlaybackTiming() -> (time: TimeInterval, duration: TimeInterval) {
        if isUsingMPV { return (currentTime, duration) }
        let currentTimeMs = (player?.time.intValue ?? 0)
        let mediaDurationMs = player?.media?.length.intValue ?? 0
        let resolvedDuration = max(Double(mediaDurationMs) / 1000.0, resolvedFile?.duration ?? 0)
        return (
            time: max(Double(currentTimeMs) / 1000.0, 0),
            duration: max(resolvedDuration, 0)
        )
    }

    private func syncPublishedPlaybackTiming() {
        let timing = currentPlaybackTiming()
        currentTime = timing.time
        duration = timing.duration
        updateCurrentSecondarySubtitleParts(at: timing.time)
    }

    func clearControlFocusRequest(id: UUID) {
        guard controlFocusRequest?.id == id else { return }
        controlFocusRequest = nil
    }

    private func prepareMPVAudioPresentation(for file: VideoFile) {
        guard file.type == .audio else { return }
        let attempt = playbackAttempt
        if let artworkURL = tvPlaybackStoredArtworkURL(for: file) {
            loadAudioArtwork(from: artworkURL, targetURL: file.url)
        }
        localAudioMetadataTask?.cancel()
        localAudioMetadataTask = Task { @MainActor [weak self] in
            let result: EmbeddedAudioArtworkReader.Metadata?
            if file.url.isFileURL {
                result = try? await EmbeddedAudioArtworkReader.readMetadata(file.url)
            } else {
                result = try? await RemoteAudioArtworkReader.readMetadata(url: file.url,
                    provider: file.serverType?.rawValue, serverID: file.jellyfinServerId,
                    path: file.serverPath, itemID: file.jellyfinItemId)
            }
            guard !Task.isCancelled, let self, self.playbackAttempt == attempt,
                  self.isUsingMPV, self.isCurrentAudioPresentationTarget(file.url), let result else { return }
            var metadata = TVAudioPresentationMetadata()
            metadata.title = result.tags["title"]
            metadata.artist = result.tags["artist"]
            metadata.album = result.tags["album"]
            metadata.artwork = result.artwork.flatMap { UIImage(data: $0) }
            self.applyAudioMetadata(metadata, targetURL: file.url)
        }
    }

    private func prepareAudioPresentation(for file: VideoFile, media: VLCMedia) {
        guard file.type == .audio,
              !tvPlaybackIsAListFile(file) else {
            return
        }

        _ = media.parse(options: .fetchLocal)
        applyAudioMetadata(from: media, targetURL: file.url)

        for delay in [0.45, 1.25, 2.5] {
            let attempt = playbackAttempt
            let workItem = DispatchWorkItem { [weak self, media] in
                guard let self, self.playbackAttempt == attempt else { return }
                self.applyAudioMetadata(from: media, targetURL: file.url)
            }
            audioMetadataWorkItems.append(workItem)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }

        if let artworkURL = tvPlaybackStoredArtworkURL(for: file) {
            loadAudioArtwork(from: artworkURL, targetURL: file.url)
        }

        if file.url.isFileURL {
            localAudioMetadataTask?.cancel()
            localAudioMetadataTask = Task { [weak self] in
                let metadata = await TVAudioPresentationMetadataExtractor.localMetadata(from: file.url)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.applyAudioMetadata(metadata, targetURL: file.url)
                }
            }
        } else {
            loadRemoteAudioMetadataFallback(for: file, targetURL: file.url)
        }
    }

    private func applyAudioMetadata(from media: VLCMedia, targetURL: URL) {
        guard isCurrentAudioPresentationTarget(targetURL) else { return }

        let metadata = media.metaData
        var extracted = TVAudioPresentationMetadata()
        extracted.title = tvPlaybackNormalizedMetadataText(metadata.title)
        extracted.artist = tvPlaybackNormalizedMetadataText(metadata.artist)
        extracted.album = tvPlaybackNormalizedMetadataText(metadata.album)
        extracted.artwork = metadata.artwork
        applyAudioMetadata(extracted, targetURL: targetURL)

        if audioArtwork == nil,
           let artworkURL = metadata.artworkURL {
            loadAudioArtwork(from: artworkURL, targetURL: targetURL)
        }
    }

    private func applyAudioMetadata(_ metadata: TVAudioPresentationMetadata, targetURL: URL) {
        guard !metadata.isEmpty,
              isCurrentAudioPresentationTarget(targetURL) else {
            return
        }

        if audioMetadataTitle == nil,
           let title = tvPlaybackNormalizedMetadataText(metadata.title) {
            audioMetadataTitle = title
        }
        if audioMetadataArtist == nil,
           let artist = tvPlaybackNormalizedMetadataText(metadata.artist) {
            audioMetadataArtist = artist
        }
        if audioMetadataAlbum == nil,
           let album = tvPlaybackNormalizedMetadataText(metadata.album) {
            audioMetadataAlbum = album
        }
        if audioArtwork == nil,
           let artwork = metadata.artwork {
            audioArtwork = artwork
            #if os(tvOS)
            TVImageCache.shared.save(artwork, for: targetURL)
            #endif
        }
    }

    private func loadAudioArtwork(from artworkURL: URL, targetURL: URL) {
        guard isCurrentAudioPresentationTarget(targetURL),
              audioArtwork == nil else {
            return
        }

        #if os(tvOS)
        if let cachedImage = TVImageCache.shared.image(for: artworkURL) {
            audioArtwork = cachedImage
            return
        }
        #endif

        let attempt = playbackAttempt
        remoteAudioArtworkTask?.cancel()
        remoteAudioArtworkTask = Task { [weak self] in
            #if os(tvOS)
            guard let permit = await TVArtworkLoadLimiter.shared.acquire(.mediaLibraryImage) else {
                return
            }
            defer { permit.release() }
            if Task.isCancelled { return }
            #endif

            let image: UIImage?
            if artworkURL.isFileURL {
                image = UIImage(contentsOfFile: artworkURL.path)
            } else {
                do {
                    let requestURL = RuntimeNetworkAddressResolver.runtimeURL(from: artworkURL)
                    let (data, response) = try await URLSession.shared.data(
                        for: URLRequest(url: requestURL, timeoutInterval: 14)
                    )
                    if let httpResponse = response as? HTTPURLResponse,
                       !(200...299).contains(httpResponse.statusCode) {
                        image = nil
                    } else {
                        image = UIImage(data: data)
                    }
                } catch {
                    image = nil
                }
            }

            guard !Task.isCancelled, let image else { return }
            #if os(tvOS)
            TVImageCache.shared.save(image, for: artworkURL)
            #endif
            await MainActor.run {
                guard !Task.isCancelled, let self, self.playbackAttempt == attempt,
                      self.isCurrentAudioPresentationTarget(targetURL),
                      self.audioArtwork == nil else {
                    return
                }
                self.audioArtwork = image
            }
        }
    }

    private func loadRemoteAudioMetadataFallback(for file: VideoFile, targetURL: URL) {
        guard file.isRemote,
              !file.url.isFileURL,
              shouldLoadRemoteAudioMetadataFallback(for: file),
              let server = tvPlaybackResolvedServer(for: file) else {
            return
        }

        remoteAudioMetadataTask?.cancel()
        remoteAudioMetadataTask = Task { [weak self] in
            do {
                #if os(tvOS)
                guard let permit = await TVArtworkLoadLimiter.shared.acquire(.playbackMetadata) else {
                    return
                }
                defer { permit.release() }
                if Task.isCancelled { return }
                #endif

                let localURL = try await AppNetworkService.shared.downloadFile(
                    server: server,
                    at: file.remoteDownloadPath
                )
                defer { tvPlaybackCleanupTemporaryDownload(at: localURL) }

                guard !Task.isCancelled else { return }
                let metadata = await TVAudioPresentationMetadataExtractor.localMetadata(from: localURL)
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    self?.applyAudioMetadata(metadata, targetURL: targetURL)
                }
            } catch {
                return
            }
        }
    }

    private func shouldLoadRemoteAudioMetadataFallback(for file: VideoFile) -> Bool {
        guard file.type == .audio else { return false }
        guard audioArtwork == nil ||
                audioMetadataTitle == nil ||
                audioMetadataArtist == nil ||
                audioMetadataAlbum == nil else {
            return false
        }

        guard let server = tvPlaybackResolvedServer(for: file) else {
            return false
        }

        switch server.type {
        case .smb, .webdav, .alist, .pan115, .onedrive, .googledrive:
            return true
        case .ftp, .sftp, .nfs, .jellyfin, .emby, .plex, .iptv, .vod:
            return false
        }
    }

    private func cancelAudioPresentationLoads() {
        audioMetadataWorkItems.forEach { $0.cancel() }
        audioMetadataWorkItems.removeAll()
        localAudioMetadataTask?.cancel()
        localAudioMetadataTask = nil
        remoteAudioArtworkTask?.cancel()
        remoteAudioArtworkTask = nil
        remoteAudioMetadataTask?.cancel()
        remoteAudioMetadataTask = nil
    }

    private func isCurrentAudioPresentationTarget(_ targetURL: URL) -> Bool {
        guard isAudioPlayback else { return false }
        let currentURL = displayFile.url
        return currentURL == targetURL ||
            RuntimeNetworkAddressResolver.runtimeURL(from: currentURL) == RuntimeNetworkAddressResolver.runtimeURL(from: targetURL)
    }

    func beginScrubbing() {
        guard !isAudioPlayback, duration > 0 else { return }
        scrubTime = min(max(currentTime, 0), duration)
        hasAdjustedScrubTime = false
        isScrubbing = true
        isChromeVisible = true
        prepareScrubPreview(for: scrubTime)
        hideChromeWorkItem?.cancel()
        hideChromeWorkItem = nil
    }

    func adjustScrubbing(by delta: TimeInterval) {
        if isAudioPlayback {
            seek(by: delta)
            return
        }

        guard duration > 0 else {
            seek(by: delta)
            return
        }

        if !isScrubbing {
            beginScrubbing()
        }

        let baseTime = isScrubbing ? scrubTime : currentTime
        scrubTime = min(max(baseTime + delta, 0), duration)
        hasAdjustedScrubTime = true
        prepareScrubPreview(for: scrubTime)
        isChromeVisible = true
        hideChromeWorkItem?.cancel()
        hideChromeWorkItem = nil
    }

    func commitScrubbing() {
        guard !isAudioPlayback else {
            revealChromeTemporarily()
            return
        }

        guard isScrubbing else {
            beginScrubbing()
            return
        }

        defer {
            isScrubbing = false
            hasAdjustedScrubTime = false
            clearScrubPreview()
            revealChromeTemporarily()
        }

        guard hasAdjustedScrubTime else { return }

        let target = min(max(scrubTime, 0), duration)
        let delta = target - currentTime
        transport.seek(to: target)
        currentTime = target
        updateCurrentSecondarySubtitleParts(at: target)
        markPlaybackStartedIfNeeded()
        if abs(delta) >= 0.5 {
            presentSeekFeedback(delta: delta, targetTime: target)
        }
        syncHistoryProgress()
    }

    func cancelScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        hasAdjustedScrubTime = false
        scrubTime = currentTime
        clearScrubPreview()
        revealChromeTemporarily()
    }

    func selectAudioTrack(_ trackID: Int, closesPanel: Bool = true) {
        pendingCoreTracks["audio"] = nil
        pendingAudioTrack = nil
        pendingAudioTrackQuery = nil
        pendingAudioTrackOrdinal = nil
        if mpv != nil {
            mpvPendingChoices["audio"] = nil
            currentAudioTrackID = trackID
            transport.selectAudioTrack(trackID)
            rememberMPVTrack(trackID, type: "audio")
            if closesPanel { closePanel(returnFocusTo: .tracks) }
            return
        }
        currentAudioTrackID = trackID
        transport.selectAudioTrack(trackID)
        if (player?.isPlaying ?? false) {
            if let player { player.time = player.time }
        }
        resolvedFile?.lastAudioTrack = trackID
        saveTrackQueryPreferenceIfNeeded()
        syncHistoryProgress()
        if closesPanel {
            closePanel(returnFocusTo: .tracks)
        }
    }

    func selectSubtitleTrack(_ trackID: Int, closesPanel: Bool = true) {
        pendingCoreTracks["sub"] = nil
        pendingSubtitleTrack = nil
        pendingSubtitleTrackQuery = nil
        pendingSubtitleTrackOrdinal = nil
        if isUsingMPV {
            mpvPendingChoices["sub"] = nil
            pendingMPVExternal = nil
            currentExternalSubtitleURL = nil
            currentSubtitleTrackID = trackID
            selectMPVSubtitles()
            rememberMPVTrack(trackID, type: "sub")
            if closesPanel { closePanel(returnFocusTo: .tracks) }
            return
        }
        if let externalURL = externalSubtitleURL(forTrackID: trackID) {
            selectExternalSubtitleTrack(trackID, sourceURL: externalURL, closesPanel: closesPanel)
            return
        }

        currentSubtitleTrackID = trackID
        player?.currentVideoSubTitleIndex = Int32(trackID)
        currentExternalSubtitleURL = nil
        if (player?.isPlaying ?? false) {
            if let player { player.time = player.time }
        }
        resolvedFile?.lastSubtitleTrack = trackID
        saveTrackQueryPreferenceIfNeeded()
        refreshSecondarySubtitleTracks()
        syncHistoryProgress()
        if closesPanel {
            closePanel(returnFocusTo: .tracks)
        }
    }

    private func selectExternalSubtitleTrack(_ trackID: Int, sourceURL: URL, closesPanel: Bool) {
        currentSubtitleTrackID = trackID
        currentExternalSubtitleURL = sourceURL
        resolvedFile?.lastSubtitleTrack = trackID
        saveTrackQueryPreferenceIfNeeded()
        syncHistoryProgress()

        let key = tvSubtitleCandidateKey(sourceURL)
        if let mappedTrackID = externalSubtitleResolvedTrackIDs[key],
           subtitleTracks.contains(where: { $0.id == mappedTrackID }) {
            player?.currentVideoSubTitleIndex = Int32(mappedTrackID)
            currentSubtitleTrackID = mappedTrackID
            refreshSecondarySubtitleTracks()
            if closesPanel {
                closePanel(returnFocusTo: .tracks)
            }
            return
        }

        let attempt = playbackAttempt
        Task { [weak self] in
            guard let self else { return }
            let playbackURL: URL
            if sourceURL.isFileURL {
                playbackURL = await self.normalizedSubtitleURLForParsing(sourceURL)
            } else if let cachedURL = await self.cacheRemoteSubtitleToLocalIfNeeded(sourceURL) {
                playbackURL = await self.normalizedSubtitleURLForParsing(cachedURL)
            } else {
                playbackURL = await self.normalizedSubtitleURLForParsing(sourceURL)
            }

            await MainActor.run {
                guard self.playbackAttempt == attempt, !self.isUsingMPV,
                      self.currentExternalSubtitleURL.map(tvSubtitleCandidateKey) == tvSubtitleCandidateKey(sourceURL) else {
                    return
                }
                self.loadExternalSubtitleSlave(playbackURL: playbackURL, sourceURL: sourceURL, fallbackTrackID: trackID)
                self.refreshSecondarySubtitleTracks()
                if closesPanel {
                    self.closePanel(returnFocusTo: .tracks)
                }
            }
        }
    }

    private func loadExternalSubtitleSlave(playbackURL: URL, sourceURL: URL, fallbackTrackID: Int) {
        let result = player?.addPlaybackSlave(
            playbackURL,
            type: .subtitle,
            enforce: true
        )
        if let result, result < 0, playbackURL != sourceURL {
            _ = player?.addPlaybackSlave(
                sourceURL,
                type: .subtitle,
                enforce: true
            )
        }

        refreshTracks()
        syncExternalSubtitleSelection(sourceURL: sourceURL, fallbackTrackID: fallbackTrackID)
        let attempt = playbackAttempt
        for delay in [0.25, 0.8, 1.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.playbackAttempt == attempt, !self.isUsingMPV,
                      self.currentExternalSubtitleURL == sourceURL else { return }
                self.refreshTracks()
                self.syncExternalSubtitleSelection(sourceURL: sourceURL, fallbackTrackID: fallbackTrackID)
            }
        }
    }

    private func syncExternalSubtitleSelection(sourceURL: URL, fallbackTrackID: Int) {
        let key = tvSubtitleCandidateKey(sourceURL)
        let actualTrackID = Int((player?.currentVideoSubTitleIndex ?? -1))
        if actualTrackID != subtitleTrackOffID,
           subtitleTracks.contains(where: { $0.id == actualTrackID }) {
            externalSubtitleResolvedTrackIDs[key] = actualTrackID
            currentSubtitleTrackID = actualTrackID
            currentExternalSubtitleURL = sourceURL
            if (player?.isPlaying ?? false) {
                if let player { player.time = player.time }
            }
            return
        }

        if let mappedTrackID = externalSubtitleResolvedTrackIDs[key],
           subtitleTracks.contains(where: { $0.id == mappedTrackID }) {
            player?.currentVideoSubTitleIndex = Int32(mappedTrackID)
            currentSubtitleTrackID = mappedTrackID
            currentExternalSubtitleURL = sourceURL
            if (player?.isPlaying ?? false) {
                if let player { player.time = player.time }
            }
            return
        }

        currentSubtitleTrackID = fallbackTrackID
        currentExternalSubtitleURL = sourceURL
    }

    func selectSecondarySubtitleTrack(_ trackID: String?, closesPanel: Bool = false) {
        pendingSecondChoice = nil
        pendingSecondOff = trackID == nil
        guard isSecondarySubtitlesEnabled else {
            clearSecondarySubtitleTrack()
            return
        }

        guard let trackID else {
            clearSecondarySubtitleTrack(persistPreference: true)
            if closesPanel {
                closePanel(returnFocusTo: .tracks)
            }
            return
        }

        guard let track = secondarySubtitleTracks.first(where: { $0.id == trackID }) else { return }
        guard canSelectSecondarySubtitle(track) else {
            currentSecondarySubtitleTrackID = track.id
            secondarySubtitleStatus = .unsupported
            secondarySubtitleParts = []
            secondarySubtitleTimeline = nil
            return
        }

        applySecondarySubtitleTrack(track, persistPreference: true)
        if closesPanel {
            closePanel(returnFocusTo: .tracks)
        }
    }

    func canSelectSecondarySubtitle(_ track: EmbeddedSubtitleTrack) -> Bool {
        if isUsingMPV, let id = track.primaryTrackID,
           let rendering = MPVSecondarySubtitleRendering(trackID: id, tracks: mpvSnapshot?.tracks ?? []),
           rendering.isBitmap {
            return rendering.canSelect(primary: currentSubtitleTrackID)
        }
        return track.isSelectable
    }

    func secondarySubtitleDetailText(for track: EmbeddedSubtitleTrack) -> String? {
        if isUsingMPV, let id = track.primaryTrackID,
           let rendering = MPVSecondarySubtitleRendering(trackID: id, tracks: mpvSnapshot?.tracks ?? []), rendering.isBitmap {
            return platformShellString(rendering.canSelect(primary: currentSubtitleTrackID) ? "MPV.BitmapPositionHint" : "MPV.BitmapPrimaryConflict")
        }
        switch track.supportLevel {
        case .textSupported, .textBestEffort:
            return nil
        case .unsupportedBitmap:
            return platformShellString("Unsupported Bitmap Subtitle")
        case .unsupportedUnknown:
            return platformShellString("Unsupported Subtitle Format")
        }
    }

    func secondarySubtitleDisplayTitle(for track: EmbeddedSubtitleTrack) -> String {
        secondarySubtitleDisplayName(for: track)
    }

    func moveSecondarySubtitlePosition(by delta: Double) {
        guard canAdjustSecondarySubtitlePosition else { return }
        let current = currentSecondarySubtitleVerticalPositionRatio()
        setSecondarySubtitleVerticalPositionRatio(current + delta)
        activateSecondarySubtitleAdjustment(autoHide: !isDirectSecondarySubtitlePositionAdjustmentActive)
        revealChromeTemporarily()
    }

    func resetSecondarySubtitlePosition() {
        TVPlaybackSettings.secondarySubtitleVerticalPositionRatio = nil
        secondarySubtitleVerticalPositionRatio = nil
        updateMPVSecondaryRendering()
        activateSecondarySubtitleAdjustment(autoHide: !isDirectSecondarySubtitlePositionAdjustmentActive)
        revealChromeTemporarily()
    }

    func startDirectPositionAdjustment() {
        isDirectSecondarySubtitlePositionAdjustmentActive = true
        activePanel = nil
        popOptionsSubmenu()
        isSecondarySubtitlePositionAdjustmentActive = true
        secondarySubtitleAdjustmentHideWorkItem?.cancel()
        hideChromeWorkItem?.cancel()
    }

    func finishDirectPositionAdjustment() {
        isDirectSecondarySubtitlePositionAdjustmentActive = false
        isSecondarySubtitlePositionAdjustmentActive = false
        requestedTrackGroup = .secondarySubtitlePosition
        activePanel = .tracks
    }

    func secondarySubtitleVideoRect(in containerSize: CGSize) -> CGRect {
        guard containerSize.width > 1, containerSize.height > 1 else {
            return CGRect(origin: .zero, size: containerSize)
        }
        guard videoDisplayMode != .fill,
              let aspectRatio = tvResolvedVideoAspectRatio(
                override: aspectRatio,
                naturalSize: videoSize
              ) else {
            return CGRect(origin: .zero, size: containerSize)
        }
        return tvScaledVideoRect(
            containerSize: containerSize,
            aspectRatio: aspectRatio,
            usesFillScale: false
        )
    }

    func secondarySubtitleVerticalPosition(in videoHeight: CGFloat) -> CGFloat {
        guard videoHeight > 0 else { return 0 }
        let ratio = currentSecondarySubtitleVerticalPositionRatio()
        let centerY = videoHeight * CGFloat(ratio)
        return min(max(centerY, 42), max(42, videoHeight - 42))
    }

    func currentSecondarySubtitleVerticalPositionRatio() -> Double {
        TVPlaybackSettings.clampedSecondarySubtitlePositionRatio(
            TVMPVPlaybackPolicy.secondarySubtitlePosition(customPosition: secondarySubtitleVerticalPositionRatio))
    }

    func seek(by delta: TimeInterval) {
        guard !isLiveStream else { return }
        let currentSeconds = isUsingMPV ? currentTime : max(Double((player?.time.intValue ?? 0)) / 1000.0, currentTime)
        let knownDuration = isUsingMPV ? duration : max(Double(player?.media?.length.intValue ?? 0) / 1000.0, duration, resolvedFile?.duration ?? 0)
        let upperBound = knownDuration > 0 ? knownDuration : max(currentSeconds + abs(delta), currentSeconds)
        let target = min(max(currentSeconds + delta, 0), upperBound)
        transport.seek(to: target)
        currentTime = target
        updateCurrentSecondarySubtitleParts(at: target)
        markPlaybackStartedIfNeeded()
        presentSeekFeedback(delta: delta, targetTime: target)
        revealChromeTemporarily()
        syncHistoryProgress()
    }

    func playPreviousItem() {
        guard canPlayPreviousItem else {
            revealChromeTemporarily()
            return
        }
        let previousIndex = currentPlaylistIndex - 1
        guard playlistFiles.indices.contains(previousIndex) else { return }
        startPlayback(file: playlistFiles[previousIndex], playlistIndex: previousIndex)
    }

    func playNextItem() {
        guard canPlayNextItem else {
            revealChromeTemporarily()
            return
        }
        let nextIndex = currentPlaylistIndex + 1
        guard playlistFiles.indices.contains(nextIndex) else { return }
        startPlayback(file: playlistFiles[nextIndex], playlistIndex: nextIndex)
    }

    func selectPlaylistItem(at index: Int) {
        guard playlistFiles.indices.contains(index) else { return }
        let targetFile = playlistFiles[index]
        isShowingPlaylistOverlay = false
        guard index != currentPlaylistIndex else { return }
        startPlayback(file: targetFile, playlistIndex: index)
    }

    func updateDrawableLayout() {
        guard let drawableView else { return }
        let bounds = drawableView.bounds
        guard bounds.width > 1, bounds.height > 1 else {
            drawableView.transform = .identity
            return
        }

        let scale = tvVideoDisplayScale(
            containerSize: bounds.size,
            naturalVideoSize: videoSize,
            aspectRatioOverride: aspectRatio,
            displayMode: videoDisplayMode
        )
        drawableView.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    var availablePlaybackRates: [Float] { isUsingMPV ? MPVPlaybackSpeed.rates : tvAvailablePlaybackRates }

    private func applyPlaybackRate(
        _ rate: Float,
        persistsInSession: Bool,
        nudgesPlayback: Bool = true
    ) {
        let clamped = max(0.25, MPVPlaybackSpeed.clamped(rate, maximum: isUsingMPV ? 8 : 3))
        playbackRate = clamped
        transport.setRate(clamped)
        if persistsInSession {
            sessionPlaybackRate = clamped
        }
        if nudgesPlayback, (player?.isPlaying ?? false) {
            if let player { player.time = player.time }
        }
        revealChromeTemporarily()
    }

    var playbackCapabilities: PlaybackEngineCapabilities {
        .init(platform: .tvOS, engine: isUsingMPV ? .mpv : .vlc)
    }

    private func reloadCurrentItemPreservingPlaybackState() {
        reloadPlayback(file: displayFile)
    }

    private func reloadPlayback(file sourceFile: VideoFile, fromBeginning: Bool = false) {
        var file = sourceFile
        pendingCoreTracks = [:]
        for (type, id, tracks) in [("audio", currentAudioTrackID, audioTracks), ("sub", currentSubtitleTrackID, subtitleTracks)] {
            pendingCoreTracks[type] = IOSPlaybackTrackSelection.capture(id: id, embeddedIDs: tracks.filter { !$0.isExternal }.map(\.id))
        }
        if let selected = secondarySubtitleTracks.first(where: { $0.id == currentSecondarySubtitleTrackID }) {
            let selection = selected.primaryTrackID.flatMap {
                IOSPlaybackTrackSelection.capture(id: $0, embeddedIDs: subtitleTracks.filter { !$0.isExternal }.map(\.id))
            }
            pendingSecondChoice = .init(selection: selection, sourceURL: selected.sourceURL, descriptorID: selected.id)
        }
        pendingSecondOff = currentSecondarySubtitleTrackID == nil && pendingSecondChoice == nil
        file.lastAudioTrack = nil
        file.lastSubtitleTrack = nil
        file.disableSubtitlesOnStart = currentSubtitleTrackID == -1
        let selectedExternalURL = isUsingMPV
            ? mpvSnapshot?.tracks.first(where: { $0.id == currentSubtitleTrackID && $0.type == "sub" })?.externalURL
            : currentExternalSubtitleURL
        let current = PlaybackSessionSnapshot(position: currentTime, duration: duration,
            paused: pauseRequested, rate: playbackRate,
            selections: .init(embedded: pendingCoreTracks,
                primarySourceURL: selectedExternalURL.map { mpvExternalSources[$0] ?? $0 },
                secondary: pendingSecondOff ? .init(selection: .off, sourceURL: nil, descriptorID: nil) : pendingSecondChoice))
        let snapshot = fromBeginning ? current.replaying() : current
        pendingCoreTracks = snapshot.selections.embedded
        pendingSecondOff = snapshot.selections.secondary?.selection == .off
        pendingSecondChoice = pendingSecondOff ? nil : snapshot.selections.secondary
        if let url = snapshot.selections.primarySourceURL {
            let source = url
            if !file.externalSubtitleCandidates.contains(where: { $0.url == source }) {
                file.externalSubtitleCandidates.append(.init(url: source, displayName: source.lastPathComponent))
            }
            file.preferredSubtitleTrackQuery = source.deletingPathExtension().lastPathComponent
            file.preferredSubtitleTrackOrdinal = nil
        }
        file.lastPlayedPosition = snapshot.position
        sessionPlaybackRate = snapshot.rate
        file.preferredPlaybackQualityID = selectedPlaybackQualityID
        startPlayback(file: file, playlistIndex: max(currentPlaylistIndex, 0), rebuilding: true, startPaused: snapshot.paused)
    }

    private func normalizedPlaylistIndex(for file: VideoFile, fallback: Int) -> Int {
        if let index = playlistFiles.firstIndex(where: { Self.playlistItemsMatch($0, file) }) {
            return index
        }

        if playlistFiles.indices.contains(fallback) {
            return fallback
        }

        return playlistFiles.isEmpty ? -1 : 0
    }

    private func updatePlaylistAvailability() {
        canPlayPreviousItem = playlistFiles.indices.contains(currentPlaylistIndex - 1)
        canPlayNextItem = playlistFiles.indices.contains(currentPlaylistIndex + 1)
    }

    private func hydrateSeasonPlaylistIfNeeded(for file: VideoFile) async {
        #if os(tvOS)
        guard playlistFiles.count <= 1 else { return }

        if file.type == .video,
           let rawServer = tvPlaybackResolvedServer(for: file) ?? file.resolvedServer,
           (rawServer.type == .jellyfin || rawServer.type == .emby || rawServer.type == .plex) {
            let server = AppNetworkService.shared.hydratedServer(from: rawServer)
            let explicitSeasonId = tvTrimmedPlaybackText(file.seasonId)
            let itemId = tvTrimmedPlaybackText(file.jellyfinItemId)

            var targetSeasonId = explicitSeasonId
            if targetSeasonId == nil, let itemId {
                if let node = try? await tvFetchMediaLibraryNode(server: server, itemId: itemId) {
                    targetSeasonId = tvTrimmedPlaybackText(node.seasonId) ?? (node.rawItemType.lowercased() == "season" ? node.id : nil)
                }
            }

            if let seasonId = targetSeasonId {
                do {
                    if let seasonNode = try await tvFetchMediaLibraryNode(server: server, itemId: seasonId) {
                        let episodeNodes = try await tvFetchMediaLibraryNodes(server: server, parentNode: seasonNode)
                        var episodeFiles = episodeNodes.compactMap { node in
                            tvPlayableLibraryFile(server: server, node: node)
                        }
                        if episodeFiles.count > 1 {
                            if !episodeFiles.contains(where: { Self.playlistItemsMatch($0, file) }) {
                                episodeFiles.append(file)
                            }
                            playlistFiles = episodeFiles
                            return
                        }
                    }
                } catch {
                    // fall through
                }
            }
        } else if file.isRemote,
                  let rawServer = tvPlaybackResolvedServer(for: file) ?? file.resolvedServer,
                  rawServer.type.isFileServer {
            let server = AppNetworkService.shared.hydratedServer(from: rawServer)
            let parentPath = file.remoteFolderPath
            let targetType: VideoFile.FileType = file.type == .audio ? .audio : .video
            if let networkFiles = try? await AppNetworkService.shared.fetchContents(for: server, at: parentPath) {
                var candidates = networkFiles.filter { $0.type == targetType }
                guard candidates.count > 1 else { return }
                if let matchedIndex = candidates.firstIndex(where: { Self.playlistItemsMatch($0, file) }) {
                    candidates[matchedIndex] = file
                } else {
                    candidates.append(file)
                }
                candidates.sort { ($0.name as NSString).localizedStandardCompare($1.name) == .orderedAscending }
                playlistFiles = candidates
            }
        } else if !file.isRemote {
            let directoryURL = file.url.deletingLastPathComponent()
            let targetType: VideoFile.FileType = file.type == .audio ? .audio : .video
            if let contents = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) {
                var candidates = contents.compactMap { url -> VideoFile? in
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
                guard candidates.count > 1 else { return }
                if let matchedIndex = candidates.firstIndex(where: { Self.playlistItemsMatch($0, file) }) {
                    candidates[matchedIndex] = file
                } else {
                    candidates.append(file)
                }
                candidates.sort { ($0.name as NSString).localizedStandardCompare($1.name) == .orderedAscending }
                playlistFiles = candidates
            }
        }
        #endif
    }

    private func presentSeekFeedback(delta: TimeInterval, targetTime: TimeInterval) {
        let feedback = TVPlaybackSeekFeedback(delta: delta, targetTime: targetTime)
        seekFeedback = feedback
        hideSeekFeedbackWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.seekFeedback == feedback else { return }
            self.seekFeedback = nil
            self.hideSeekFeedbackWorkItem = nil
        }
        hideSeekFeedbackWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: workItem)
    }

    private func prepareScrubPreview(for targetTime: TimeInterval) {
        scrubPreviewDebounceWorkItem?.cancel()
        scrubPreviewDebounceWorkItem = nil

        guard displayFile.type == .video, duration > 0.5 else {
            scrubPreviewRemoteTask?.cancel()
            scrubPreviewRemoteTask = nil
            scrubPreviewThumbnailGenerator?.cancel()
            scrubPreviewThumbnailGenerator = nil
            scrubPreviewRequestID = nil
            scrubPreviewImage = nil
            isScrubPreviewLoading = false
            return
        }

        let clampedTarget = min(max(targetTime, 0), duration)
        let cacheKey = scrubPreviewCacheKey(for: clampedTarget, file: displayFile)
        if let cachedImage = scrubPreviewCache[cacheKey] {
            scrubPreviewRemoteTask?.cancel()
            scrubPreviewRemoteTask = nil
            scrubPreviewThumbnailGenerator?.cancel()
            scrubPreviewThumbnailGenerator = nil
            scrubPreviewRequestID = nil
            scrubPreviewImage = cachedImage
            isScrubPreviewLoading = false
            return
        }

        isScrubPreviewLoading = true
        let requestID = UUID()
        scrubPreviewRequestID = requestID

        let workItem = DispatchWorkItem { [weak self] in
            self?.startScrubPreviewRequest(at: clampedTarget, requestID: requestID)
        }
        scrubPreviewDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func startScrubPreviewRequest(at targetTime: TimeInterval, requestID: UUID) {
        guard scrubPreviewRequestID == requestID,
              displayFile.type == .video,
              duration > 0.5 else {
            return
        }

        let clampedTarget = min(max(targetTime, 0), duration)
        let cacheKey = scrubPreviewCacheKey(for: clampedTarget, file: displayFile)
        if let cachedImage = scrubPreviewCache[cacheKey] {
            scrubPreviewImage = cachedImage
            isScrubPreviewLoading = false
            return
        }

        let file = displayFile
        scrubPreviewRemoteTask?.cancel()
        scrubPreviewRemoteTask = nil
        scrubPreviewThumbnailGenerator?.cancel()
        scrubPreviewThumbnailGenerator = nil

        guard TVRemoteSeekPreviewService.shared.canPreview(file) else {
            startLegacyScrubPreviewRequest(
                for: file,
                at: clampedTarget,
                requestID: requestID,
                cacheKey: cacheKey
            )
            return
        }

        scrubPreviewRemoteTask = Task { [weak self] in
            guard let self else { return }
            let serverImage = await TVRemoteSeekPreviewService.shared.previewImage(
                for: file,
                targetTime: clampedTarget
            )

            guard !Task.isCancelled else { return }
            guard self.scrubPreviewRequestID == requestID else { return }
            self.scrubPreviewRemoteTask = nil

            if let serverImage {
                self.cacheScrubPreview(serverImage, forKey: cacheKey)
                self.scrubPreviewImage = serverImage
                self.isScrubPreviewLoading = false
                return
            }

            self.startLegacyScrubPreviewRequest(
                for: file,
                at: clampedTarget,
                requestID: requestID,
                cacheKey: cacheKey
            )
        }
    }

    private func startLegacyScrubPreviewRequest(
        for file: VideoFile,
        at targetTime: TimeInterval,
        requestID: UUID,
        cacheKey: String
    ) {
        guard scrubPreviewRequestID == requestID,
              displayFile.type == .video,
              duration > 0.5 else {
            return
        }

        let legacy: () -> (any PlaybackPreviewProvider)? = { [weak self] in
            guard let self, PlaybackEngineAvailability.current.vlc else { return nil }
            let media = self.playbackMedia(for: file)
            self.configurePlaybackOptions(for: media, file: file)
            return VLCPlaybackPreviewProvider(media: media, width: 540)
        }
        let generator: any PlaybackPreviewProvider
        if playbackCapabilities.previewBackend == .independent {
            let total = duration
            let size = videoSize
            generator = MPVPlaybackPreviewProvider(duration: total, sourceSize: size, maximumDimension: 540) { [weak self] time in
                guard let self, self.scrubPreviewRequestID == requestID else { return nil }
                let url = self.mpvSourceURL(for: file)
                return .init(url: url, start: time, options: self.mpvNetworkOptions(for: file),
                             subtitles: [], stream: self.mpvStream(for: file, url: url, byteCache: self.mpvReadAheadByteCache))
            }
        } else {
            guard let provider = legacy() else { isScrubPreviewLoading = false; return }
            generator = provider
        }
        scrubPreviewThumbnailGenerator?.cancel()
        scrubPreviewThumbnailGenerator = generator

        let snapshotPosition = Float(min(max(targetTime / duration, 0), 0.999))
        generator.generate(snapshotPosition: snapshotPosition) { [weak self, weak generator] frame in
            let image = frame.map { UIImage(cgImage: $0) }
            Task { @MainActor in
                guard let self,
                      self.scrubPreviewRequestID == requestID,
                      self.scrubPreviewThumbnailGenerator === generator else {
                    return
                }

                self.scrubPreviewThumbnailGenerator = nil
                self.isScrubPreviewLoading = false

                if let image {
                    self.cacheScrubPreview(image, forKey: cacheKey)
                    self.scrubPreviewImage = image
                }
            }
        }
    }

    private func clearScrubPreview() {
        scrubPreviewDebounceWorkItem?.cancel()
        scrubPreviewDebounceWorkItem = nil
        scrubPreviewRemoteTask?.cancel()
        scrubPreviewRemoteTask = nil
        scrubPreviewThumbnailGenerator?.cancel()
        scrubPreviewThumbnailGenerator = nil
        scrubPreviewRequestID = nil
        scrubPreviewImage = nil
        isScrubPreviewLoading = false
    }

    private func scrubPreviewCacheKey(for targetTime: TimeInterval, file: VideoFile) -> String {
        let sourceHash = String(file.url.absoluteString.hashValue, radix: 16)
        let timeBucket = Int(floor(max(targetTime, 0) / 5.0))
        return "\(file.id)|\(sourceHash)|\(timeBucket)"
    }

    private func cacheScrubPreview(_ image: UIImage, forKey key: String) {
        if scrubPreviewCache[key] == nil {
            scrubPreviewCacheOrder.append(key)
        }
        scrubPreviewCache[key] = image

        while scrubPreviewCacheOrder.count > scrubPreviewCacheLimit {
            let removedKey = scrubPreviewCacheOrder.removeFirst()
            scrubPreviewCache[removedKey] = nil
        }
    }

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        guard !isUsingMPV, !isResolvingPlayback, let callbackPlayer = aNotification.object as? VLCMediaPlayer,
              callbackPlayer === player else {
            return
        }

        switch player?.state {
        case .buffering, .opening:
            if !hasPresentedFirstFrame {
                isLoading = true
            }
        case .playing:
            pauseRequested = false
            isPlaying = true
            markPlaybackStartedIfNeeded()
            applyPlaybackRate(playbackRate, persistsInSession: false, nudgesPlayback: false)
            updateDrawableLayout()
            if let seekTime = pendingInitialSeek, seekTime > 0 {
                player?.time = VLCTime(int: Int32(seekTime * 1000))
                pendingInitialSeek = nil
            }
            refreshTracks()
            scheduleTrackRefresh(after: 0.6)
            scheduleTrackRefresh(after: 1.2)
            revealChromeTemporarily()
        case .paused:
            pauseRequested = true
            refreshTracks()
            scheduleTrackRefresh(after: 0.6)
            isPlaying = false
            isLoading = false
            isChromeVisible = true
            hideChromeWorkItem?.cancel()
            hideChromeWorkItem = nil
            syncHistoryProgress()
            syncServerProgress(eventName: "pause", force: true)
        case .ended:
            isPlaying = false
            isLoading = false
            isChromeVisible = true
            hideChromeWorkItem?.cancel()
            hideChromeWorkItem = nil
            syncHistoryProgress()
            syncServerProgress(eventName: "stop", force: true)
            if canPlayNextItem {
                let attempt = playbackAttempt
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.playbackAttempt == attempt else { return }
                    self.playNextItem()
                }
            }
        case .stopped:
            isPlaying = false
            isLoading = false
            isChromeVisible = true
            hideChromeWorkItem?.cancel()
            hideChromeWorkItem = nil
            syncHistoryProgress()
            syncServerProgress(eventName: "stop", force: true)
        case .error:
            isPlaying = false
            isLoading = false
            errorMessage = platformShellString("Connection Failed")
            isChromeVisible = true
            hideChromeWorkItem?.cancel()
            hideChromeWorkItem = nil
            syncHistoryProgress()
            syncServerProgress(eventName: "stop", force: true)
        default:
            break
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        guard !isUsingMPV, !isResolvingPlayback, let callbackPlayer = aNotification.object as? VLCMediaPlayer,
              callbackPlayer === player else {
            return
        }

        let timing = currentPlaybackTiming()

        if isPlaying != (player?.isPlaying ?? false) {
            isPlaying = (player?.isPlaying ?? false)
        }
        updateDrawableLayout()

        if (player?.isPlaying ?? false) || timing.time > 0.3 {
            markPlaybackStartedIfNeeded()
        }

        timeProgress.currentTime = timing.time
        timeProgress.duration = timing.duration
        updateCurrentSecondarySubtitleParts(at: timing.time)

        if let seekTime = pendingInitialSeek,
           seekTime > 0,
           (player?.isSeekable ?? false),
           timing.time > 0.3 {
            player?.time = VLCTime(int: Int32(seekTime * 1000))
            pendingInitialSeek = nil
        }

        if abs(timing.time - lastTrackRefreshTime) >= 4.0 {
            lastTrackRefreshTime = timing.time
            refreshTracks()
        }

        syncHistoryProgress()
        syncServerProgress(eventName: nil, force: false)
    }

    private func syncHistoryProgress() {
        guard let file = resolvedFile else { return }
        guard HistoryService.isHistoryEnabled(for: file) else { return }
        let currentTimeMs = isUsingMPV ? Int32(clamping: Int64(currentTime * 1000)) : (player?.time.intValue ?? 0)
        let durationMs = isUsingMPV ? Int32(clamping: Int64(duration * 1000)) : (player?.media?.length.intValue ?? Int32((duration > 0 ? duration : (file.duration ?? 0)) * 1000.0))
        guard currentTimeMs > 0, durationMs > 0 else { return }

        _ = HistoryService.shared.updateProgress(
            for: file.url,
            time: Double(currentTimeMs) / 1000.0,
            duration: Double(durationMs) / 1000.0,
            audioTrack: isUsingMPV || currentAudioTrackID == -1 ? nil : currentAudioTrackID,
            subtitleTrack: isUsingMPV ? nil : currentSubtitleTrackID,
            jellyfinItemId: file.jellyfinItemId,
            jellyfinServerId: file.jellyfinServerId,
            serverPath: file.serverPath
        )
    }

    private func serverSyncContext(for file: VideoFile) -> (server: ServerConfig, serverType: ServerConfig.ServerType, itemId: String, token: String, userId: String)? {
        guard let itemId = file.jellyfinItemId, !itemId.isEmpty else { return nil }

        let allServers = AppNetworkService.shared.servers
        var resolvedServer: ServerConfig?
        if let serverId = file.jellyfinServerId {
            resolvedServer = allServers.first(where: {
                $0.id.uuidString.caseInsensitiveCompare(serverId) == .orderedSame
            })
        }

        if resolvedServer == nil,
           let itemComponents = URLComponents(url: file.url, resolvingAgainstBaseURL: false),
           let host = itemComponents.host?.lowercased() {
            let preferredType = file.serverType
            let itemPort = itemComponents.port ?? (itemComponents.scheme?.lowercased() == "https" ? 443 : 80)
            resolvedServer = allServers.first { server in
                guard server.type == .jellyfin || server.type == .emby || server.type == .plex else { return false }
                if let preferredType, server.type != preferredType { return false }

                guard let serverComponents = URLComponents(string: server.fullURL),
                      let serverHost = serverComponents.host?.lowercased() else {
                    return false
                }
                let serverPort = serverComponents.port ?? (serverComponents.scheme?.lowercased() == "https" ? 443 : 80)
                return serverHost == host && serverPort == itemPort
            }
        }

        if resolvedServer == nil {
            let preferredType = file.serverType
            if let preferredType {
                resolvedServer = allServers.first(where: { $0.type == preferredType })
            } else if allServers.count == 1 {
                resolvedServer = allServers.first
            }
        }

        guard let server = resolvedServer else {
            return nil
        }
        let serverType = file.serverType ?? server.type
        guard serverType == .jellyfin || serverType == .emby || serverType == .plex else { return nil }

        let hydratedServer = AppNetworkService.shared.hydratedServer(from: server)
        let token = hydratedServer.accessToken
            ?? URLComponents(url: file.url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "api_key" || $0.name == "X-Plex-Token" })?
                .value
        guard let token, !token.isEmpty else {
            return nil
        }

        return (server: hydratedServer, serverType: serverType, itemId: itemId, token: token, userId: hydratedServer.userId ?? "")
    }

    private func syncServerProgress(eventName: String?, force: Bool = false) {
        guard let file = resolvedFile ?? (request.file.isRemote ? request.file : nil) else { return }
        guard let context = serverSyncContext(for: file) else { return }

        let currentTimeMs = isUsingMPV ? Int32(clamping: Int64(currentTime * 1000)) : (player?.time.intValue ?? 0)
        let durationMs = isUsingMPV ? Int32(clamping: Int64(duration * 1000)) : (player?.media?.length.intValue ?? Int32((duration > 0 ? duration : (file.duration ?? 0)) * 1000.0))

        let effectiveTime: Double
        if let seekTime = pendingInitialSeek, seekTime > 0 {
            effectiveTime = seekTime
        } else if currentTimeMs > 0 {
            effectiveTime = Double(currentTimeMs) / 1000.0
        } else {
            effectiveTime = max(0, timeProgress.currentTime)
        }

        let now = Date().timeIntervalSince1970
        let isForced = force || eventName != nil
        if !isForced {
            let timeSinceLast = now - lastServerProgressReportTime
            guard timeSinceLast >= 10.0 else { return }
        }
        lastServerProgressReportTime = now

        let positionTicks = Int64(effectiveTime * 10_000_000)
        let durationTicks = durationMs > 0 ? Int64(durationMs) * 10000 : (file.duration.map { Int64($0 * 10_000_000) })
        let isPaused = isUsingMPV ? pauseRequested : !(player?.isPlaying ?? false)
        let sessionId = currentPlaySessionId
        let mediaSourceId = file.mediaSourceId
        let playMethod: String
        if file.url.isFileURL || !file.isRemote {
            playMethod = RemotePlaybackMethod.directPlay.rawValue
        } else {
            playMethod = file.remotePlaybackMethod?.rawValue ?? RemotePlaybackMethod.directPlay.rawValue
        }

        let targetServer = context.server
        let targetItemId = context.itemId

        if eventName == "stop" {
            Task.detached(priority: .userInitiated) {
                try? await tvReportMediaPlaybackProgress(
                    server: targetServer,
                    itemId: targetItemId,
                    positionTicks: positionTicks,
                    durationTicks: durationTicks,
                    isPaused: isPaused,
                    eventName: eventName,
                    playSessionId: sessionId,
                    mediaSourceId: mediaSourceId,
                    playMethod: playMethod
                )
            }
        } else {
            serverReportTask?.cancel()
            serverReportTask = Task {
                try? await tvReportMediaPlaybackProgress(
                    server: targetServer,
                    itemId: targetItemId,
                    positionTicks: positionTicks,
                    durationTicks: durationTicks,
                    isPaused: isPaused,
                    eventName: eventName,
                    playSessionId: sessionId,
                    mediaSourceId: mediaSourceId,
                    playMethod: playMethod
                )
            }
        }
    }

    private func configureSubtitleOptions(
        for media: VLCMedia,
        file: VideoFile,
        preparedSubtitleURL: URL?
    ) {
        guard !file.disableSubtitlesOnStart else {
            media.addOption(":sub-autodetect-file=0")
            media.addOption(":subsdec-autodetect-utf8=1")
            return
        }

        guard let preparedSubtitleURL else {
            media.addOption(":subsdec-autodetect-utf8=1")
            return
        }

        media.addOption(":sub-autodetect-file=0")
        media.addOption(":sub-file=\(preparedSubtitleURL.absoluteString)")
        media.addOption(":subsdec-encoding=UTF-8")
        media.addOption(":subsdec-autodetect-utf8=1")
    }

    private func markPlaybackStartedIfNeeded() {
        if !hasReportedServerStart {
            hasReportedServerStart = true
            syncServerProgress(eventName: "start", force: true)
        }
        hasPresentedFirstFrame = true
        if isLoading {
            isLoading = false
        }
        if errorMessage != nil {
            errorMessage = nil
        }
    }

    private func scheduleChromeAutoHide() {
        hideChromeWorkItem?.cancel()
        hideChromeWorkItem = nil

        guard !isAudioPlayback,
              !isNativeMenuPresented,
              (player?.isPlaying ?? false) || isPlaying,
              errorMessage == nil else { return }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard ((self.player?.isPlaying ?? false) || self.isPlaying),
                  self.activePanel == nil,
                  !self.isScrubbing,
                  self.errorMessage == nil else {
                return
            }
            self.isChromeVisible = false
        }
        hideChromeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0, execute: workItem)
    }

    private func scheduleTrackRefresh(after delay: TimeInterval) {
        let attempt = playbackAttempt
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.playbackAttempt == attempt else { return }
            self.refreshTracks()
        }
    }

    private func refreshTracks() {
        if isUsingMPV { refreshMPVTracks(); return }
        guard !isNativeMenuPresented else {
            deferredNativeMenuTrackRefreshNeeded = true
            return
        }

        let refreshedAudioTracks = tvApplyingServerTrackNames(
            tvTracks(
                names: player?.audioTrackNames,
                indexes: player?.audioTrackIndexes,
                fallbackPrefix: platformShellString("Audio")
            ),
            type: "Audio",
            external: nil,
            streams: resolvedFile?.serverMediaStreams
        )
        var refreshedSubtitleTracks = tvApplyingServerTrackNames(
            tvTracks(
                names: player?.videoSubTitlesNames,
                indexes: player?.videoSubTitlesIndexes,
                fallbackPrefix: platformShellString("Subtitle")
            ),
            type: "Subtitle",
            external: false,
            streams: resolvedFile?.serverMediaStreams
        )
        resolveNativeExternalSubtitleTrackIDs(in: refreshedSubtitleTracks)
        refreshedSubtitleTracks = applyingResolvedExternalSubtitleDisplayNames(to: refreshedSubtitleTracks)
        refreshedSubtitleTracks = appendingSyntheticExternalSubtitleTracks(to: refreshedSubtitleTracks)

        audioTracks = refreshedAudioTracks
        subtitleTracks = refreshedSubtitleTracks
        // VLC also assigns small native IDs to attached sidecars. Classify them before
        // checking the container count; numeric ID ranges alone cannot identify them.
        for (type, selection) in pendingCoreTracks {
            let tracks = type == "audio" ? audioTracks : subtitleTracks
            let ids = tracks.filter { $0.id >= 0 && !$0.isExternal }.map(\.id)
            if let id = selection.resolve(embeddedIDs: ids) {
                if type == "audio" { pendingAudioTrack = id } else { pendingSubtitleTrack = id }
                pendingCoreTracks[type] = nil
            }
        }
        refreshSecondarySubtitleTracks()
        if let activePanel, !optionPanels.contains(activePanel) {
            self.activePanel = defaultOptionsPanel
        }

        if let pendingAudioTrack,
           pendingAudioTrack == subtitleTrackOffID {
            currentAudioTrackID = subtitleTrackOffID
            player?.currentAudioTrackIndex = Int32(subtitleTrackOffID)
            self.pendingAudioTrack = nil
            pendingAudioTrackQuery = nil
            pendingAudioTrackOrdinal = nil
        } else if let pendingAudioTrack,
                  audioTracks.contains(where: { $0.id == pendingAudioTrack }) {
            currentAudioTrackID = pendingAudioTrack
            player?.currentAudioTrackIndex = Int32(pendingAudioTrack)
            self.pendingAudioTrack = nil
            pendingAudioTrackQuery = nil
            pendingAudioTrackOrdinal = nil
        } else if pendingAudioTrack != nil, !audioTracks.isEmpty {
            self.pendingAudioTrack = nil
        } else if let query = pendingAudioTrackQuery {
            if let matched = audioTracks.first(where: { $0.id != subtitleTrackOffID && tvTrackName($0.name, matches: query) }) {
                currentAudioTrackID = matched.id
                player?.currentAudioTrackIndex = Int32(matched.id)
                pendingAudioTrackQuery = nil
                pendingAudioTrackOrdinal = nil
            } else if let ordinal = pendingAudioTrackOrdinal,
                      let fallback = tvSelectableTrack(at: ordinal, from: audioTracks) {
                currentAudioTrackID = fallback.id
                player?.currentAudioTrackIndex = Int32(fallback.id)
                pendingAudioTrackQuery = nil
                pendingAudioTrackOrdinal = nil
            } else if audioTracks.contains(where: { $0.id != subtitleTrackOffID }) {
                pendingAudioTrackQuery = nil
                pendingAudioTrackOrdinal = nil
            }
        } else if (player?.currentAudioTrackIndex ?? -1) == Int32(subtitleTrackOffID),
                  let firstValid = audioTracks.first(where: { $0.id != subtitleTrackOffID }) {
            currentAudioTrackID = firstValid.id
            player?.currentAudioTrackIndex = Int32(firstValid.id)
        } else {
            currentAudioTrackID = Int((player?.currentAudioTrackIndex ?? -1))
        }

        if let pendingSubtitleTrack {
            if pendingSubtitleTrack == subtitleTrackOffID {
                currentSubtitleTrackID = subtitleTrackOffID
                player?.currentVideoSubTitleIndex = Int32(subtitleTrackOffID)
                currentExternalSubtitleURL = nil
                self.pendingSubtitleTrack = nil
                pendingSubtitleTrackQuery = nil
                pendingSubtitleTrackOrdinal = nil
            } else if let externalURL = externalSubtitleURL(forTrackID: pendingSubtitleTrack) {
                self.pendingSubtitleTrack = nil
                pendingSubtitleTrackQuery = nil
                pendingSubtitleTrackOrdinal = nil
                selectExternalSubtitleTrack(pendingSubtitleTrack, sourceURL: externalURL, closesPanel: false)
            } else if subtitleTracks.contains(where: { $0.id == pendingSubtitleTrack }) {
                currentSubtitleTrackID = pendingSubtitleTrack
                player?.currentVideoSubTitleIndex = Int32(pendingSubtitleTrack)
                currentExternalSubtitleURL = nil
                self.pendingSubtitleTrack = nil
                pendingSubtitleTrackQuery = nil
                pendingSubtitleTrackOrdinal = nil
            } else if !subtitleTracks.isEmpty {
                self.pendingSubtitleTrack = nil
            }
        } else if let query = pendingSubtitleTrackQuery {
            if let matched = subtitleTracks.first(where: { $0.id != subtitleTrackOffID && tvTrackName($0.name, matches: query) }) {
                if let externalURL = externalSubtitleURL(forTrackID: matched.id) {
                    selectExternalSubtitleTrack(matched.id, sourceURL: externalURL, closesPanel: false)
                } else {
                    currentSubtitleTrackID = matched.id
                    player?.currentVideoSubTitleIndex = Int32(matched.id)
                    currentExternalSubtitleURL = nil
                }
                pendingSubtitleTrackQuery = nil
                pendingSubtitleTrackOrdinal = nil
            } else if let ordinal = pendingSubtitleTrackOrdinal,
                      let fallback = tvSelectableTrack(at: ordinal, from: subtitleTracks) {
                if let externalURL = externalSubtitleURL(forTrackID: fallback.id) {
                    selectExternalSubtitleTrack(fallback.id, sourceURL: externalURL, closesPanel: false)
                } else {
                    currentSubtitleTrackID = fallback.id
                    player?.currentVideoSubTitleIndex = Int32(fallback.id)
                    currentExternalSubtitleURL = nil
                }
                pendingSubtitleTrackQuery = nil
                pendingSubtitleTrackOrdinal = nil
            } else if subtitleTracks.contains(where: { $0.id != subtitleTrackOffID }) {
                pendingSubtitleTrackQuery = nil
                pendingSubtitleTrackOrdinal = nil
            }
        } else {
            let actualSubtitleTrackID = Int((player?.currentVideoSubTitleIndex ?? -1))
            if actualSubtitleTrackID == subtitleTrackOffID,
               let externalURL = currentExternalSubtitleURL {
                if currentSubtitleTrackID == subtitleTrackOffID,
                   let syntheticTrackID = externalSubtitleTrackID(for: externalURL) {
                    currentSubtitleTrackID = syntheticTrackID
                }
                // Keep the external selection while VLCKit is still exposing the slave track.
            } else {
                currentSubtitleTrackID = actualSubtitleTrackID
                if currentSubtitleTrackID == subtitleTrackOffID {
                    currentExternalSubtitleURL = nil
                }
            }
        }
    }

    private func refreshSecondarySubtitleTracks() {
        guard isSecondarySubtitlesEnabled, let file = resolvedFile else {
            secondarySubtitleTracks = []
            clearSecondarySubtitleTrack()
            return
        }

        let tracks = isUsingMPV ? mpvSecondaryTracks() : availableSecondarySubtitleTracks(for: file)
        if secondarySubtitleTracks != tracks {
            secondarySubtitleTracks = tracks
        }

        if let selectedID = currentSecondarySubtitleTrackID,
           !tracks.contains(where: { $0.id == selectedID }) {
            clearSecondarySubtitleTrack()
        }

        restorePendingSecondarySubtitleSelectionIfNeeded()
    }

    private func currentExternalSubtitleCandidates() -> [ExternalSubtitleCandidate] {
        var candidates = resolvedFile?.externalSubtitleCandidates ?? []
        let subtitleExtensions = Set(VideoFile.FileType.subtitleExtensions)
        let playlist = (request.playlist ?? []) + playlistFiles
        for item in playlist where item.type == .subtitle || subtitleExtensions.contains(item.url.pathExtension.lowercased()) {
            if !candidates.contains(where: { tvSubtitleCandidateKey($0.url) == tvSubtitleCandidateKey(item.url) }) {
                candidates.append(.init(url: item.url, displayName: item.name))
            }
        }
        return tvDeduplicatedExternalSubtitleCandidates(candidates)
    }

    private func externalSubtitleDisplayName(for url: URL, fallbackIndex: Int) -> String {
        let key = tvSubtitleCandidateKey(url)
        if let candidate = currentExternalSubtitleCandidates().first(where: { tvSubtitleCandidateKey($0.url) == key }),
           !candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return candidate.displayName
        }
        let fileName = url.deletingPathExtension().lastPathComponent
        return fileName.isEmpty ? "\(platformShellString("Subtitle")) \(fallbackIndex + 1)" : fileName
    }

    private func externalSubtitleURL(forTrackID trackID: Int) -> URL? {
        let candidates = currentExternalSubtitleCandidates()
        if trackID >= externalSubtitleTrackBaseID {
            let index = trackID - externalSubtitleTrackBaseID
            guard index >= 0, index < candidates.count else { return nil }
            return candidates[index].url
        }

        guard let key = externalSubtitleResolvedTrackIDs.first(where: { $0.value == trackID })?.key else {
            return nil
        }
        return candidates.first { tvSubtitleCandidateKey($0.url) == key }?.url
    }

    private func externalSubtitleTrackID(for url: URL) -> Int? {
        let key = tvSubtitleCandidateKey(url)
        guard let index = currentExternalSubtitleCandidates().firstIndex(where: { tvSubtitleCandidateKey($0.url) == key }) else {
            return nil
        }
        return externalSubtitleTrackBaseID + index
    }

    private func isExternalSubtitleTrack(_ trackID: Int) -> Bool {
        trackID >= externalSubtitleTrackBaseID || externalSubtitleResolvedTrackIDs.values.contains(trackID)
    }

    private func resolveNativeExternalSubtitleTrackIDs(in tracks: [MediaTrack]) {
        let candidates = currentExternalSubtitleCandidates()
        guard !candidates.isEmpty else {
            externalSubtitleResolvedTrackIDs = [:]
            return
        }

        let candidateKeys = Set(candidates.map { tvSubtitleCandidateKey($0.url) })
        externalSubtitleResolvedTrackIDs = externalSubtitleResolvedTrackIDs.filter { candidateKeys.contains($0.key) }

        var usedTrackIDs = Set(externalSubtitleResolvedTrackIDs.values.filter { resolvedID in
            tracks.contains(where: { $0.id == resolvedID })
        })
        for (offset, candidate) in candidates.enumerated() {
            let key = tvSubtitleCandidateKey(candidate.url)
            if let resolvedID = externalSubtitleResolvedTrackIDs[key],
               tracks.contains(where: { $0.id == resolvedID }) {
                usedTrackIDs.insert(resolvedID)
                continue
            }

            let displayName = candidate.displayName.isEmpty
                ? externalSubtitleDisplayName(for: candidate.url, fallbackIndex: offset)
                : candidate.displayName
            guard let matchedID = matchingNativeSubtitleTrackID(
                for: displayName,
                among: tracks,
                excluding: usedTrackIDs
            ) else { continue }

            externalSubtitleResolvedTrackIDs[key] = matchedID
            usedTrackIDs.insert(matchedID)
        }
    }

    private func applyingResolvedExternalSubtitleDisplayNames(to tracks: [MediaTrack]) -> [MediaTrack] {
        guard !tracks.isEmpty, !externalSubtitleResolvedTrackIDs.isEmpty else { return tracks }

        return tracks.map { track in
            guard track.id != subtitleTrackOffID,
                  let sourceURL = externalSubtitleURL(forTrackID: track.id) else {
                return track
            }

            let displayName = externalSubtitleDisplayName(for: sourceURL, fallbackIndex: 0)
            let shouldReplaceName = isGenericNativeSubtitleTrackName(track.name) ||
                tvTrackName(track.name, matches: displayName)
            return MediaTrack(
                id: track.id,
                name: shouldReplaceName ? displayName : track.name,
                isExternal: true
            )
        }
    }

    private func appendingSyntheticExternalSubtitleTracks(to tracks: [MediaTrack]) -> [MediaTrack] {
        let candidates = currentExternalSubtitleCandidates()
        guard !candidates.isEmpty else { return tracks }

        var result = tracks
        let nativeIDs = Set(tracks.map(\.id))
        for (offset, candidate) in candidates.enumerated() {
            let key = tvSubtitleCandidateKey(candidate.url)
            if let resolvedID = externalSubtitleResolvedTrackIDs[key],
               nativeIDs.contains(resolvedID) {
                continue
            }
            let syntheticID = externalSubtitleTrackBaseID + offset
            guard !nativeIDs.contains(syntheticID),
                  !result.contains(where: { $0.id == syntheticID }) else {
                continue
            }
            result.append(MediaTrack(
                id: syntheticID,
                name: externalSubtitleDisplayName(for: candidate.url, fallbackIndex: offset),
                isExternal: true
            ))
        }
        return result
    }

    private func matchingNativeSubtitleTrackID(
        for displayName: String,
        among tracks: [MediaTrack],
        excluding excludedTrackIDs: Set<Int>
    ) -> Int? {
        let candidates = tracks.filter {
            $0.id != subtitleTrackOffID && !excludedTrackIDs.contains($0.id)
        }
        let exactMatches = candidates.filter {
            tvNormalizedTrackQuery($0.name) == tvNormalizedTrackQuery(displayName)
        }
        if exactMatches.count == 1 {
            return exactMatches[0].id
        }

        let relaxedMatches = candidates.filter { tvTrackName($0.name, matches: displayName) }
        if relaxedMatches.count == 1 {
            return relaxedMatches[0].id
        }

        let genericMatches = candidates.filter { isGenericNativeSubtitleTrackName($0.name) }
        return genericMatches.count == 1 ? genericMatches[0].id : nil
    }

    private func isGenericNativeSubtitleTrackName(_ name: String) -> Bool {
        let normalized = tvNormalizedTrackQuery(name)
        return normalized.hasPrefix("track") || normalized.hasPrefix("subtitle")
    }

    private func availableSecondarySubtitleTracks(for file: VideoFile) -> [EmbeddedSubtitleTrack] {
        let tracks = localContainerSecondarySubtitleTracks(for: file) +
            serverSecondarySubtitleTracks(for: file) +
            externalSecondarySubtitleTracks(for: file) +
            nativeSecondarySubtitleTracks(for: file)
        var seenIDs = Set<String>()
        var seenURLKeys = Set<String>()
        var result: [EmbeddedSubtitleTrack] = []

        for track in tracks {
            guard seenIDs.insert(track.id).inserted else { continue }
            if let sourceURL = track.sourceURL {
                let key = tvSubtitleCandidateKey(sourceURL)
                guard seenURLKeys.insert(key).inserted else { continue }
            }
            if let duplicateIndex = result.firstIndex(where: {
                secondarySubtitleTracksRepresentSameCandidate($0, track)
            }) {
                if shouldPreferSecondarySubtitleTrack(track, over: result[duplicateIndex]) {
                    result[duplicateIndex] = track
                }
                continue
            }
            result.append(track)
        }

        return result
    }

    private func secondarySubtitleTracksRepresentSameCandidate(
        _ lhs: EmbeddedSubtitleTrack,
        _ rhs: EmbeddedSubtitleTrack
    ) -> Bool {
        if let leftPrimary = lhs.primaryTrackID,
           let rightPrimary = rhs.primaryTrackID,
           leftPrimary != subtitleTrackOffID,
           rightPrimary != subtitleTrackOffID,
           leftPrimary == rightPrimary {
            return true
        }

        if secondarySubtitleTracksLikelySame(lhs, rhs) {
            if lhs.isExternal && rhs.isExternal {
                return true
            }
            if !lhs.isSelectable || !rhs.isSelectable {
                return true
            }
        }

        if let leftIndex = lhs.streamIndex,
           let rightIndex = rhs.streamIndex,
           leftIndex == rightIndex,
           lhs.source == rhs.source {
            return true
        }

        return false
    }

    private func shouldPreferSecondarySubtitleTrack(
        _ candidate: EmbeddedSubtitleTrack,
        over existing: EmbeddedSubtitleTrack
    ) -> Bool {
        let candidateRank = secondarySubtitleSupportRank(candidate.supportLevel)
        let existingRank = secondarySubtitleSupportRank(existing.supportLevel)
        if candidateRank != existingRank {
            return candidateRank > existingRank
        }
        if (candidate.sourceURL != nil) != (existing.sourceURL != nil) {
            return candidate.sourceURL != nil
        }
        if candidate.source == .externalFile && existing.source != .externalFile {
            return false
        }
        return false
    }

    private func secondarySubtitleSupportRank(_ supportLevel: EmbeddedSubtitleSupportLevel) -> Int {
        switch supportLevel {
        case .textSupported:
            return 3
        case .textBestEffort:
            return 2
        case .unsupportedBitmap:
            return 1
        case .unsupportedUnknown:
            return 0
        }
    }

    private func secondarySubtitleTracksLikelySame(
        _ lhs: EmbeddedSubtitleTrack,
        _ rhs: EmbeddedSubtitleTrack
    ) -> Bool {
        if let leftURL = lhs.sourceURL,
           let rightURL = rhs.sourceURL,
           tvSubtitleCandidateKey(leftURL) == tvSubtitleCandidateKey(rightURL) {
            return true
        }

        return secondarySubtitleNamesLikelyMatch(lhs.displayName, rhs.displayName)
    }

    private func secondarySubtitleNamesLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedSecondarySubtitleName(lhs)
        let right = normalizedSecondarySubtitleName(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }

    private func normalizedSecondarySubtitleName(_ value: String) -> String {
        let lowered = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        return String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private func secondarySubtitleDisplayName(for track: EmbeddedSubtitleTrack) -> String {
        if let primaryTrackID = track.primaryTrackID,
           let primaryTrack = subtitleTracks.first(where: { $0.id == primaryTrackID && $0.id != subtitleTrackOffID }),
           secondarySubtitleNamesLikelyMatch(track.displayName, primaryTrack.name) {
            return primaryTrack.name
        }
        if track.isExternal,
           let sourceURL = track.sourceURL {
            let sourceKey = tvSubtitleCandidateKey(sourceURL)
            if let primaryTrack = subtitleTracks.first(where: { primaryTrack in
                guard primaryTrack.id != subtitleTrackOffID,
                      let primaryURL = externalSubtitleURL(forTrackID: primaryTrack.id) else {
                    return false
                }
                return tvSubtitleCandidateKey(primaryURL) == sourceKey
            }) {
                return primaryTrack.name
            }
        }
        return track.displayName
    }

    private func selectedSecondarySubtitleOrdinal(for track: EmbeddedSubtitleTrack) -> Int? {
        let selectableTracks = secondarySubtitleTracks.filter { $0.isSelectable }
        return selectableTracks.firstIndex(where: { $0.id == track.id })
    }

    private func storedSecondarySubtitlePreference(for file: VideoFile) -> (query: String?, ordinal: Int?) {
        guard let prefix = secondarySubtitlePreferencePrefix(for: file) else {
            return (nil, nil)
        }
        let defaults = UserDefaults.standard
        return (
            defaults.string(forKey: "\(prefix).query"),
            defaults.object(forKey: "\(prefix).ordinal") as? Int
        )
    }

    private func saveStoredSecondarySubtitlePreference(for file: VideoFile, track: EmbeddedSubtitleTrack?) {
        guard let prefix = secondarySubtitlePreferencePrefix(for: file) else { return }
        let defaults = UserDefaults.standard
        let queryKey = "\(prefix).query"
        let ordinalKey = "\(prefix).ordinal"

        if let track {
            if let query = tvTrimmedPlaybackText(secondarySubtitleDisplayName(for: track)) {
                defaults.set(query, forKey: queryKey)
            } else {
                defaults.removeObject(forKey: queryKey)
            }
            if let ordinal = selectedSecondarySubtitleOrdinal(for: track) {
                defaults.set(ordinal, forKey: ordinalKey)
            } else {
                defaults.removeObject(forKey: ordinalKey)
            }
        } else {
            defaults.removeObject(forKey: queryKey)
            defaults.removeObject(forKey: ordinalKey)
        }
    }

    private func secondarySubtitlePreferencePrefix(for file: VideoFile) -> String? {
        if let provider = file.serverType?.rawValue,
           let serverId = tvTrimmedPlaybackText(file.jellyfinServerId),
           let scopeKey = secondarySubtitlePreferenceScopeKey(for: file) {
            return "tvSecondarySubtitle.\(provider).\(serverId).\(scopeKey)"
        }

        let mediaKey = secondarySubtitleMediaKey(for: file)
        guard !mediaKey.isEmpty else { return nil }
        return "tvSecondarySubtitle.media.\(tvStableHashHex(for: mediaKey))"
    }

    private func secondarySubtitlePreferenceScopeKey(for file: VideoFile) -> String? {
        if let seriesId = tvTrimmedPlaybackText(file.seriesId) {
            return "series.\(seriesId)"
        }
        if let itemId = tvTrimmedPlaybackText(file.jellyfinItemId) {
            return "item.\(itemId)"
        }
        return nil
    }

    private func serverSecondarySubtitleTracks(for file: VideoFile) -> [EmbeddedSubtitleTrack] {
        guard let streams = file.serverMediaStreams, !streams.isEmpty else { return [] }
        guard file.serverType == .jellyfin || file.serverType == .emby || file.serverType == .plex else { return [] }

        let subtitleStreams = streams.filter { isSubtitleServerStream($0) }
        guard !subtitleStreams.isEmpty else { return [] }

        let nativeSubtitleTracks = subtitleTracks.filter { $0.id != subtitleTrackOffID && !$0.isExternal }
        let source = file.serverType == .emby
            ? EmbeddedSubtitleSource.embyMediaStream
            : EmbeddedSubtitleSource.jellyfinMediaStream
        let itemID = tvTrimmedPlaybackText(file.jellyfinItemId)
        let fallbackMediaSourceID = tvTrimmedPlaybackText(file.mediaSourceId) ?? embeddedSubtitleMediaSourceID(from: file.url)
        let server = embeddedSubtitleServer(for: file)
        let token = server.map { embeddedSubtitleToken(for: file, server: $0) } ?? ""

        var nativeFallbackOffset = 0
        return subtitleStreams.enumerated().compactMap { offset, stream in
            let streamIndex = subtitleStreamIndex(stream) ?? offset
            let codec = cleanedEmbeddedSubtitleValue(tvStreamString(stream, "Codec") ?? tvStreamString(stream, "codec"))
            let supportLevel = embeddedSubtitleSupportLevel(codec: codec, stream: stream)
            let isExternal = embeddedSubtitleStreamIsExternal(stream)
            let mediaSourceID = embeddedSubtitleMediaSourceID(from: stream) ?? fallbackMediaSourceID
            let sourceURL = server.flatMap { server in
                embeddedSubtitleURL(
                    server: server,
                    itemID: itemID,
                    mediaSourceID: mediaSourceID,
                    streamIndex: streamIndex,
                    codec: codec,
                    deliveryURL: tvStreamString(stream, "DeliveryUrl") ?? tvStreamString(stream, "DeliveryURL") ?? tvStreamString(stream, "key"),
                    token: token
                )
            }
            if isExternal,
               let sourceURL {
                let sourceKey = tvSubtitleCandidateKey(sourceURL)
                let isAlreadyRepresentedByExternalCandidate = currentExternalSubtitleCandidates().contains {
                    tvSubtitleCandidateKey($0.url) == sourceKey
                }
                if isAlreadyRepresentedByExternalCandidate {
                    return nil
                }
            }
            let resolvedSupportLevel = sourceURL == nil ? .unsupportedUnknown : supportLevel

            let nativeFallbackTrackID: Int?
            if isExternal {
                nativeFallbackTrackID = nil
            } else {
                nativeFallbackTrackID = nativeFallbackOffset < nativeSubtitleTracks.count
                    ? nativeSubtitleTracks[nativeFallbackOffset].id
                    : nil
                nativeFallbackOffset += 1
            }
            let exactPrimaryTrackID = subtitleTracks.contains(where: { $0.id == streamIndex }) ? streamIndex : nil
            let primaryTrackID: Int?
            if isUsingMPV {
                let descriptors = subtitleStreams.filter { !embeddedSubtitleStreamIsExternal($0) }.map {
                    (codec: tvStreamString($0, "Codec"), language: tvStreamString($0, "Language"), title: tvStreamString($0, "Title"))
                }
                primaryTrackID = isExternal ? nil : mpvSnapshot?.tracks.first(where: {
                    MacMPVSubtitleMapping.ordinal(selectedID: $0.id, tracks: mpvSnapshot?.tracks ?? [], descriptors: descriptors) == nativeFallbackOffset - 1 && $0.type == "sub"
                })?.id
            } else {
                primaryTrackID = isExternal ? exactPrimaryTrackID : (exactPrimaryTrackID ?? nativeFallbackTrackID)
            }
            let idParts = [
                source.rawValue,
                itemID ?? "unknown-item",
                mediaSourceID ?? "unknown-source",
                "\(streamIndex)",
                codec ?? "unknown"
            ]

            return EmbeddedSubtitleTrack(
                id: idParts.joined(separator: "|"),
                source: source,
                streamIndex: streamIndex,
                primaryTrackID: primaryTrackID,
                codec: codec,
                language: cleanedEmbeddedSubtitleValue(tvStreamString(stream, "Language") ?? tvStreamString(stream, "language")),
                title: cleanedEmbeddedSubtitleValue(tvStreamString(stream, "Title") ?? tvStreamString(stream, "title")),
                displayName: embeddedSubtitleDisplayName(stream: stream, fallbackIndex: offset),
                sourceURL: sourceURL,
                supportLevel: resolvedSupportLevel,
                isExternal: isExternal
            )
        }
    }

    private func externalSecondarySubtitleTracks(for file: VideoFile) -> [EmbeddedSubtitleTrack] {
        let mediaKey = secondarySubtitleMediaKey(for: file)
        return tvDeduplicatedExternalSubtitleCandidates(file.externalSubtitleCandidates)
            .enumerated()
            .map { offset, candidate in
                let key = tvSubtitleCandidateKey(candidate.url)
                let codec = cleanedEmbeddedSubtitleValue(candidate.url.pathExtension)
                let supportLevel = externalSubtitleSupportLevel(for: candidate.url, displayName: candidate.displayName)
                let idParts = [
                    EmbeddedSubtitleSource.externalFile.rawValue,
                    mediaKey,
                    key
                ]
                return EmbeddedSubtitleTrack(
                    id: idParts.joined(separator: "|"),
                    source: .externalFile,
                    streamIndex: nil,
                    primaryTrackID: nil,
                    codec: codec,
                    language: nil,
                    title: candidate.displayName,
                    displayName: candidate.displayName.isEmpty
                        ? "\(platformShellString("Subtitle")) \(offset + 1)"
                        : candidate.displayName,
                    sourceURL: candidate.url,
                    supportLevel: supportLevel,
                    isExternal: true
                )
            }
    }

    private func localContainerSecondarySubtitleTracks(for file: VideoFile) -> [EmbeddedSubtitleTrack] {
        guard file.url.isFileURL else { return [] }

        let descriptors = localEmbeddedSubtitleDescriptors(for: file.url)
        guard !descriptors.isEmpty else { return [] }

        let nativeSubtitleTracks = subtitleTracks.filter { track in
            track.id != subtitleTrackOffID && !track.isExternal
        }
        let mediaKey = secondarySubtitleMediaKey(for: file)

        return descriptors.map { descriptor in
            let primaryTrack = descriptor.trackIndex < nativeSubtitleTracks.count
                ? nativeSubtitleTracks[descriptor.trackIndex]
                : nil
            let displayName = primaryTrack?.name ??
                localEmbeddedSubtitleDisplayName(for: descriptor, fallbackIndex: descriptor.trackIndex)
            let sourceURL = descriptor.supportLevel == .textSupported || descriptor.supportLevel == .textBestEffort
                ? localEmbeddedSubtitleOutputURL(
                    for: file.url,
                    trackIndex: descriptor.trackIndex,
                    codec: descriptor.codec
                )
                : nil
            let idParts = [
                EmbeddedSubtitleSource.localContainer.rawValue,
                mediaKey,
                "\(descriptor.trackIndex)",
                descriptor.codec ?? "unknown"
            ]

            return EmbeddedSubtitleTrack(
                id: idParts.joined(separator: "|"),
                source: .localContainer,
                streamIndex: descriptor.trackIndex,
                primaryTrackID: primaryTrack?.id,
                codec: descriptor.codec,
                language: descriptor.language,
                title: descriptor.title,
                displayName: displayName,
                sourceURL: sourceURL,
                supportLevel: descriptor.supportLevel,
                isExternal: false
            )
        }
    }

    private func localEmbeddedSubtitleDescriptors(for mediaURL: URL) -> [SharedLocalEmbeddedSubtitleDescriptor] {
        let key = tvSubtitleCandidateKey(mediaURL)
        if let cached = localEmbeddedSubtitleDescriptorCache[key] {
            return cached
        }

        let descriptors = SharedLocalEmbeddedSubtitleExtractor.descriptors(for: mediaURL)
        localEmbeddedSubtitleDescriptorCache[key] = descriptors
        return descriptors
    }

    private func localEmbeddedSubtitleDisplayName(
        for descriptor: SharedLocalEmbeddedSubtitleDescriptor,
        fallbackIndex: Int
    ) -> String {
        var pieces: [String] = []
        if let title = descriptor.title, !title.isEmpty {
            pieces.append(title)
        }
        if let language = descriptor.language,
           !language.isEmpty,
           !pieces.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
            pieces.append(language.uppercased())
        }
        if let codec = descriptor.codec, !codec.isEmpty {
            pieces.append(codec.uppercased())
        }
        if pieces.isEmpty {
            return "\(platformShellString("Subtitle")) \(fallbackIndex + 1)"
        }
        return pieces.joined(separator: " · ")
    }

    private func localEmbeddedSubtitleOutputURL(
        for mediaURL: URL,
        trackIndex: Int,
        codec: String?
    ) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TVLocalEmbeddedSubtitles", isDirectory: true)
        let baseName = tvSanitizedSubtitleFileName(from: mediaURL.deletingPathExtension().lastPathComponent)
        let normalizedCodec = codec?.lowercased()
        let outputExtension: String
        switch normalizedCodec {
        case "ass":
            outputExtension = "ass"
        case "ssa":
            outputExtension = "ssa"
        case "webvtt", "vtt":
            outputExtension = "vtt"
        default:
            outputExtension = "srt"
        }
        let key = "\(tvSubtitleCandidateKey(mediaURL))|\(trackIndex)|\(normalizedCodec ?? "unknown")"
        let hash = tvStableHashHex(for: key)
        return folder.appendingPathComponent("\(baseName)_track\(trackIndex + 1)_\(hash).\(outputExtension)")
    }

    private func nativeSecondarySubtitleTracks(for file: VideoFile) -> [EmbeddedSubtitleTrack] {
        let mediaKey = secondarySubtitleMediaKey(for: file)
        return subtitleTracks
            .filter { $0.id != subtitleTrackOffID && !$0.isExternal && !isExternalSubtitleTrack($0.id) }
            .enumerated()
            .map { offset, track in
                let idParts = [
                    EmbeddedSubtitleSource.localContainer.rawValue,
                    mediaKey,
                    "\(track.id)",
                    normalizedSecondarySubtitleName(track.name)
                ]
                return EmbeddedSubtitleTrack(
                    id: idParts.joined(separator: "|"),
                    source: .localContainer,
                    streamIndex: offset,
                    primaryTrackID: track.id,
                    codec: nil,
                    language: nil,
                    title: track.name,
                    displayName: track.name,
                    sourceURL: nil,
                    supportLevel: .unsupportedUnknown,
                    isExternal: false
                )
            }
    }

    private func applySecondarySubtitleTrack(
        _ track: EmbeddedSubtitleTrack,
        persistPreference: Bool
    ) {
        currentSecondarySubtitleTrackID = track.id
        secondarySubtitleStatus = .loading
        secondarySubtitleParts = []
        secondarySubtitleTimeline = nil
        if persistPreference, let file = resolvedFile {
            if isUsingMPV, let id = track.primaryTrackID { rememberMPVTrack(id, type: "secondary") }
            else { saveStoredSecondarySubtitlePreference(for: file, track: track) }
        }
        activateSecondarySubtitleAdjustment(autoHide: true)
        loadSecondarySubtitleTimeline(for: track)
    }

    private func restorePendingSecondarySubtitleSelectionIfNeeded() {
        guard isSecondarySubtitlesEnabled else { return }
        if pendingSecondOff { return }
        if let selection = pendingSecondChoice {
            let id = selection.resolve(candidates: secondarySubtitleTracks.map {
                .init(id: $0.id, sourceURL: $0.sourceURL, nativeID: $0.primaryTrackID)
            }, embeddedIDs: subtitleTracks.filter { !$0.isExternal }.map(\.id))
            guard let track = secondarySubtitleTracks.first(where: { $0.id == id }) else { return }
            if isUsingMPV, let nativeID = track.primaryTrackID,
               MPVSecondarySubtitleRendering(trackID: nativeID, tracks: mpvSnapshot?.tracks ?? [])?.canSelect(primary: currentSubtitleTrackID) == false {
                pendingSecondChoice = nil
                pendingSecondOff = true
                return
            }
            guard canSelectSecondarySubtitle(track) else { return }
            pendingSecondChoice = nil
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            applySecondarySubtitleTrack(track, persistPreference: false)
            return
        }
        if isUsingMPV {
            guard let choice = mpvPendingChoices["secondary"],
                  let id = choice.resolve(in: mpvSnapshot?.tracks.filter { $0.type == "sub" } ?? []) else { return }
            if id < 0 { mpvPendingChoices["secondary"] = nil; return }
            guard let track = secondarySubtitleTracks.first(where: { $0.primaryTrackID == id }) else { return }
            if MPVSecondarySubtitleRendering(trackID: id, tracks: mpvSnapshot?.tracks ?? [])?.canSelect(primary: currentSubtitleTrackID) == false {
                mpvPendingChoices["secondary"] = nil
                return
            }
            guard canSelectSecondarySubtitle(track) else { return }
            mpvPendingChoices["secondary"] = nil
            applySecondarySubtitleTrack(track, persistPreference: false)
            return
        }
        guard isSecondarySubtitlesEnabled else {
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            return
        }

        guard currentSecondarySubtitleTrackID == nil else {
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            return
        }

        let selectableTracks = secondarySubtitleTracks.filter { $0.isSelectable }
        guard !selectableTracks.isEmpty else { return }

        if let query = pendingSecondarySubtitleTrackQuery,
           let matched = selectableTracks.first(where: {
               secondarySubtitleNamesLikelyMatch(secondarySubtitleDisplayName(for: $0), query) ||
               secondarySubtitleNamesLikelyMatch($0.displayName, query)
           }) {
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            applySecondarySubtitleTrack(matched, persistPreference: false)
            return
        }

        if let ordinal = pendingSecondarySubtitleTrackOrdinal,
           ordinal >= 0,
           ordinal < selectableTracks.count {
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            applySecondarySubtitleTrack(selectableTracks[ordinal], persistPreference: false)
            return
        }

        if pendingSecondarySubtitleTrackQuery != nil || pendingSecondarySubtitleTrackOrdinal != nil {
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
        }
    }

    private func clearSecondarySubtitleTrack(persistPreference: Bool = false) {
        mpvSecondaryID = nil
        mpvSelectionRequest = nil
        mpv?.set("secondary-sid", "no")
        mpv?.set("secondary-sub-visibility", "no")
        if persistPreference { pendingSecondOff = true; pendingSecondChoice = nil }
        secondarySubtitleLoadTask?.cancel()
        secondarySubtitleLoadTask = nil
        secondarySubtitleTimeline = nil
        currentSecondarySubtitleTrackID = nil
        secondarySubtitleStatus = .disabled
        secondarySubtitleParts = []
        isSecondarySubtitlePositionAdjustmentActive = false
        if persistPreference, let file = resolvedFile {
            if isUsingMPV { rememberMPVTrack(-1, type: "secondary") }
            else { saveStoredSecondarySubtitlePreference(for: file, track: nil) }
        }
    }

    private func loadSecondarySubtitleTimeline(for track: EmbeddedSubtitleTrack) {
        secondarySubtitleLoadTask?.cancel()
        if isUsingMPV, let id = track.primaryTrackID {
            mpvSecondaryID = id
            selectMPVSubtitles()
            return
        }

        guard let sourceURL = track.sourceURL else {
            secondarySubtitleStatus = .unsupported
            secondarySubtitleParts = []
            return
        }

        let cacheKey = secondarySubtitleTimelineCacheKey(for: track)
        if let cachedTimeline = cachedSecondarySubtitleTimeline(for: cacheKey) {
            secondarySubtitleTimeline = cachedTimeline
            secondarySubtitleStatus = .ready
            updateCurrentSecondarySubtitleParts(at: currentTime)
            return
        }

        let selectedTrackID = track.id
        let mediaKey = secondarySubtitleMediaKey(for: displayFile)
        let parserFormat = subtitleParserFormat(for: track)
        secondarySubtitleLoadTask = Task { [weak self] in
            guard let self else { return }

            do {
                let readableURL: URL
                if track.source == .localContainer {
                    guard let trackIndex = track.streamIndex else {
                        throw NSError(domain: "TVPlaybackSession.LocalEmbeddedSubtitle", code: -1)
                    }
                    readableURL = try await SharedLocalEmbeddedSubtitleExtractor.extractSubtitle(
                        from: self.displayFile.url,
                        trackIndex: trackIndex,
                        outputURL: sourceURL
                    )
                } else if sourceURL.isFileURL {
                    readableURL = await self.normalizedSubtitleURLForParsing(sourceURL)
                } else if let cachedURL = await self.cacheRemoteSubtitleToLocalIfNeeded(sourceURL) {
                    readableURL = await self.normalizedSubtitleURLForParsing(cachedURL)
                } else {
                    throw NSError(domain: "TVPlaybackSession.SecondarySubtitle", code: -1)
                }

                let parts = try SubtitleModel.loadParts(from: readableURL, format: parserFormat)
                let timeline = SubtitleTimeline(parts: parts)
                await MainActor.run {
                    guard !Task.isCancelled, !self.isUsingMPV,
                          self.secondarySubtitleMediaKey(for: self.displayFile) == mediaKey,
                          self.currentSecondarySubtitleTrackID == selectedTrackID else { return }
                    self.storeSecondarySubtitleTimeline(timeline, for: cacheKey)
                    self.secondarySubtitleTimeline = timeline
                    self.secondarySubtitleStatus = .ready
                    self.updateCurrentSecondarySubtitleParts(at: self.currentTime)
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled, !self.isUsingMPV,
                          self.secondarySubtitleMediaKey(for: self.displayFile) == mediaKey,
                          self.currentSecondarySubtitleTrackID == selectedTrackID else { return }
                    self.secondarySubtitleStatus = .failed
                    self.secondarySubtitleParts = []
                    self.secondarySubtitleTimeline = nil
                    self.activateSecondarySubtitleAdjustment(autoHide: true)
                    print("[Subtitle] Failed to parse TV secondary subtitle: \(error.localizedDescription)")
                }
            }
        }
    }

    private func normalizedSubtitleURLForParsing(_ url: URL) -> URL {
        normalizedExternalSubtitleURL(for: url)
    }

    private func updateCurrentSecondarySubtitleParts(at time: TimeInterval) {
        guard isSecondarySubtitlesEnabled else {
            if mpvSecondaryID != nil { clearSecondarySubtitleTrack() }
            if !secondarySubtitleParts.isEmpty {
                secondarySubtitleParts = []
            }
            return
        }

        if isUsingMPV { updateMPVSecondary(); return }
        guard let timeline = secondarySubtitleTimeline,
              secondarySubtitleStatus == .ready else {
            if !secondarySubtitleParts.isEmpty {
                secondarySubtitleParts = []
            }
            return
        }

        let parts = timeline.activeParts(at: time + subtitleDelay)
        if secondarySubtitleParts != parts {
            secondarySubtitleParts = parts
        }
    }

    private func setSecondarySubtitleVerticalPositionRatio(_ ratio: Double) {
        let clamped = TVPlaybackSettings.clampedSecondarySubtitlePositionRatio(ratio)
        TVPlaybackSettings.secondarySubtitleVerticalPositionRatio = clamped
        secondarySubtitleVerticalPositionRatio = clamped
        updateMPVSecondaryRendering()
    }

    private func activateSecondarySubtitleAdjustment(autoHide: Bool) {
        guard isSecondarySubtitlesEnabled else { return }
        isSecondarySubtitlePositionAdjustmentActive = true
        secondarySubtitleAdjustmentHideWorkItem?.cancel()
        secondarySubtitleAdjustmentHideWorkItem = nil
        if autoHide {
            scheduleSecondarySubtitleAdjustmentHide(after: 3.0)
        }
    }

    private func scheduleSecondarySubtitleAdjustmentHide(after delay: TimeInterval) {
        secondarySubtitleAdjustmentHideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.isSecondarySubtitlePositionAdjustmentActive = false
        }
        secondarySubtitleAdjustmentHideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func secondarySubtitleTimelineCacheKey(for track: EmbeddedSubtitleTrack) -> String {
        [
            track.source.rawValue,
            track.id,
            track.sourceURL.map(tvSubtitleCandidateKey) ?? "no-url",
            track.codec ?? "unknown"
        ].joined(separator: "|")
    }

    private func cachedSecondarySubtitleTimeline(for key: String) -> SubtitleTimeline? {
        guard let timeline = secondarySubtitleTimelineCache[key] else { return nil }
        secondarySubtitleTimelineCacheOrder.removeAll { $0 == key }
        secondarySubtitleTimelineCacheOrder.append(key)
        return timeline
    }

    private func storeSecondarySubtitleTimeline(_ timeline: SubtitleTimeline, for key: String) {
        secondarySubtitleTimelineCache[key] = timeline
        secondarySubtitleTimelineCacheOrder.removeAll { $0 == key }
        secondarySubtitleTimelineCacheOrder.append(key)

        while secondarySubtitleTimelineCacheOrder.count > secondarySubtitleTimelineCacheLimit {
            let evictedKey = secondarySubtitleTimelineCacheOrder.removeFirst()
            secondarySubtitleTimelineCache.removeValue(forKey: evictedKey)
        }
    }

    private func subtitleParserFormat(for track: EmbeddedSubtitleTrack) -> String {
        if let codec = track.codec?.lowercased() {
            if codec == "subrip" { return "srt" }
            if codec == "webvtt" { return "vtt" }
            if codec == "mov_text" || codec == "tx3g" { return "srt" }
            return codec
        }
        return track.sourceURL?.pathExtension.lowercased() ?? "srt"
    }

    private func secondarySubtitleMediaKey(for file: VideoFile) -> String {
        file.url.isFileURL ? file.url.standardizedFileURL.path : file.url.absoluteString
    }

    private func isSubtitleServerStream(_ stream: [String: Any]) -> Bool {
        let rawType = (tvStreamString(stream, "Type") ?? tvStreamString(stream, "type") ?? "").lowercased()
        if rawType == "subtitle" || rawType.contains("subtitle") || rawType.contains("caption") {
            return true
        }
        if tvStreamInt(stream, "streamType") == 3 {
            return true
        }
        return false
    }

    private func subtitleStreamIndex(_ stream: [String: Any]) -> Int? {
        tvStreamInt(stream, "Index")
            ?? tvStreamInt(stream, "index")
            ?? tvStreamInt(stream, "StreamIndex")
            ?? tvStreamInt(stream, "streamIndex")
            ?? tvStreamInt(stream, "id")
    }

    private func embeddedSubtitleStreamIsExternal(_ stream: [String: Any]) -> Bool {
        if tvStreamBool(stream, "IsExternal") == true || tvStreamBool(stream, "isExternal") == true {
            return true
        }
        if tvStreamString(stream, "DeliveryUrl") != nil || tvStreamString(stream, "DeliveryURL") != nil {
            return true
        }
        if let deliveryMethod = tvStreamString(stream, "DeliveryMethod")?.lowercased(),
           deliveryMethod.contains("external") {
            return true
        }
        return false
    }

    private func embeddedSubtitleSupportLevel(
        codec: String?,
        stream: [String: Any]
    ) -> EmbeddedSubtitleSupportLevel {
        if tvStreamBool(stream, "IsTextSubtitleStream") == true || tvStreamBool(stream, "isTextSubtitleStream") == true {
            return .textSupported
        }

        switch codec?.lowercased() {
        case "srt", "subrip", "webvtt", "vtt", "mov_text", "tx3g":
            return .textSupported
        case "ass", "ssa":
            return .textBestEffort
        case "pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "vobsub", "dvbsub", "dvb_subtitle":
            return .unsupportedBitmap
        default:
            return .unsupportedUnknown
        }
    }

    private func externalSubtitleSupportLevel(for url: URL, displayName: String? = nil) -> EmbeddedSubtitleSupportLevel {
        var ext = url.pathExtension.lowercased()
        
        func isSupported(_ format: String) -> Bool {
            let f = format.lowercased()
            return ["srt", "vtt", "webvtt", "subrip", "ass", "ssa", "sub"].contains(f)
        }
        
        if !isSupported(ext) {
            if let path = url.path.components(separatedBy: "/").last?.lowercased() {
                if let dotRange = path.range(of: ".", options: .backwards) {
                    let pathExt = String(path[dotRange.upperBound...])
                    if isSupported(pathExt) {
                        ext = pathExt
                    }
                }
            }
        }
        
        if !isSupported(ext) {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                if let formatQuery = components.queryItems?.first(where: { $0.name.lowercased() == "format" || $0.name.lowercased() == "codec" })?.value?.lowercased() {
                    if isSupported(formatQuery) {
                        ext = formatQuery
                    }
                }
            }
        }
        
        if !isSupported(ext), let displayName = displayName?.lowercased() {
            if displayName.contains("ass") || displayName.contains("ssa") {
                ext = "ass"
            } else if displayName.contains("srt") || displayName.contains("subrip") {
                ext = "srt"
            } else if displayName.contains("vtt") || displayName.contains("webvtt") {
                ext = "vtt"
            } else if displayName.contains("sub") {
                ext = "sub"
            }
        }
        
        switch ext {
        case "srt", "vtt", "webvtt", "subrip":
            return .textSupported
        case "ass", "ssa", "sub":
            return .textBestEffort
        case "pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "vobsub", "dvbsub", "dvb_subtitle":
            return .unsupportedBitmap
        default:
            return .unsupportedUnknown
        }
    }

    private func embeddedSubtitleDisplayName(stream: [String: Any], fallbackIndex: Int) -> String {
        var pieces: [String] = []
        [
            tvStreamString(stream, "DisplayTitle"),
            tvStreamString(stream, "displayTitle"),
            tvStreamString(stream, "Title"),
            tvStreamString(stream, "title"),
            tvStreamString(stream, "DisplayLanguage"),
            tvStreamString(stream, "displayLanguage"),
            tvStreamString(stream, "Language"),
            tvStreamString(stream, "language")
        ].forEach { value in
            guard let cleaned = cleanedEmbeddedSubtitleValue(value) else { return }
            if !pieces.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
                pieces.append(cleaned)
            }
        }

        if tvStreamBool(stream, "IsDefault") == true || tvStreamBool(stream, "default") == true {
            pieces.append(platformShellString("Default"))
        }
        if tvStreamBool(stream, "IsForced") == true || tvStreamBool(stream, "forced") == true {
            pieces.append(platformShellString("Forced"))
        }
        if let codec = cleanedEmbeddedSubtitleValue(tvStreamString(stream, "Codec") ?? tvStreamString(stream, "codec")) {
            pieces.append(codec.uppercased())
        }

        if pieces.isEmpty {
            return "\(platformShellString("Subtitle")) \(fallbackIndex + 1)"
        }
        return pieces.joined(separator: " · ")
    }

    private func embeddedSubtitleServer(for file: VideoFile) -> ServerConfig? {
        let servers = AppNetworkService.shared.savedServers
        if let serverID = file.jellyfinServerId,
           let uuid = UUID(uuidString: serverID),
           let matched = servers.first(where: { $0.id == uuid }) {
            return matched
        }

        guard let host = file.url.host?.lowercased() else { return nil }
        return servers.first { server in
            guard server.type == file.serverType else { return false }
            return normalizeServerHost(server.fullURL) == host || normalizeServerHost(server.address) == host
        }
    }

    private func embeddedSubtitleToken(for file: VideoFile, server: ServerConfig) -> String {
        let queryItems = URLComponents(url: file.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return queryItems.first(where: { $0.name.caseInsensitiveCompare("api_key") == .orderedSame })?.value
            ?? queryItems.first(where: { $0.name.caseInsensitiveCompare("X-Emby-Token") == .orderedSame })?.value
            ?? queryItems.first(where: { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame })?.value
            ?? server.accessToken
            ?? server.passwordSecret
            ?? ""
    }

    private func embeddedSubtitleMediaSourceID(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame })?
            .value
    }

    private func embeddedSubtitleMediaSourceID(from stream: [String: Any]) -> String? {
        cleanedEmbeddedSubtitleValue(
            tvStreamString(stream, "MediaSourceId")
                ?? tvStreamString(stream, "MediaSourceID")
                ?? tvStreamString(stream, "mediaSourceId")
                ?? tvStreamString(stream, "mediaSourceID")
        )
    }

    private func embeddedSubtitleURL(
        server: ServerConfig,
        itemID: String?,
        mediaSourceID: String?,
        streamIndex: Int,
        codec: String?,
        deliveryURL: String?,
        token: String
    ) -> URL? {
        let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if let url = tvResolvedMediaServerURL(
            baseURL: baseURL,
            rawPath: deliveryURL,
            tokenQueryName: "api_key",
            token: token
        ) {
            return url
        }

        guard let itemID, let mediaSourceID else { return nil }
        let ext = embeddedSubtitleExportExtension(codec: codec)
        guard var components = URLComponents(string: "\(baseURL)/Videos/\(itemID)/\(mediaSourceID)/Subtitles/\(streamIndex)/Stream.\(ext)") else {
            return nil
        }
        if !token.isEmpty {
            components.queryItems = [URLQueryItem(name: "api_key", value: token)]
        }
        return components.url
    }

    private func embeddedSubtitleExportExtension(codec: String?) -> String {
        switch codec?.lowercased() {
        case "srt", "subrip":
            return "srt"
        case "webvtt", "vtt":
            return "vtt"
        case "ass":
            return "ass"
        case "ssa":
            return "ssa"
        case "mov_text", "tx3g":
            return "srt"
        default:
            return "srt"
        }
    }

    private func cleanedEmbeddedSubtitleValue(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }
        let lowered = cleaned
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let placeholders: Set<String> = ["und", "undefined", "unknown", "undetermined", "n/a", "na", "none", "null"]
        return placeholders.contains(lowered) ? nil : cleaned
    }

    private func saveTrackQueryPreferenceIfNeeded() {
        guard let file = resolvedFile else { return }
        tvSaveSeriesTrackPreference(
            for: file,
            audio: currentAudioTrackID,
            subtitle: currentSubtitleTrackID
        )
        tvSaveTrackQueryPreference(
            for: file,
            audioQuery: audioTracks.first(where: { $0.id == currentAudioTrackID })?.name,
            subtitleQuery: subtitleTracks.first(where: { $0.id == currentSubtitleTrackID })?.name,
            subtitlesDisabled: currentSubtitleTrackID == subtitleTrackOffID
        )
    }

    private func configureTextRenderer(for player: VLCMediaPlayer?) {
        guard let player else { return }
        var fallbackFontFamily = "HelveticaNeue"
        if let fontURL = Bundle.main.url(forResource: "SourceHanSansSC-Regular", withExtension: "otf")
            ?? Bundle.module.url(forResource: "SourceHanSansSC-Regular", withExtension: "otf") {
            var error: Unmanaged<CFError>?
            CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
            fallbackFontFamily = "Source Han Sans SC"
            resolvedCJKFontFamily = fallbackFontFamily
            resolvedCJKFontDirectory = fontURL.deletingLastPathComponent().path
        }
        #if os(tvOS)
        GenPlayerInstallCJKFontInterceptor()
        #endif

        let fontSelector = NSSelectorFromString("setTextRendererFont:")
        if player.responds(to: fontSelector) {
            player.perform(fontSelector, with: fallbackFontFamily)
        }

        let fontSizeSelector = NSSelectorFromString("setTextRendererFontSize:")
        if player.responds(to: fontSizeSelector) {
            player.perform(fontSizeSelector, with: preferredSubtitleRendererFontSize())
        }
    }

    /// Apply CJK font and subtitle encoding options directly on the VLC media object.
    /// This ensures both embedded and external subtitle rendering use the bundled
    /// Source Han Sans font, which supports CJK glyphs that the system default
    /// HelveticaNeue does not, preventing garbled Chinese/Japanese/Korean subtitles.
    private func configureCJKFontOptions(for media: VLCMedia) {
        media.addOption(":text-renderer=freetype")
        media.addOption(":freetype-font=\(resolvedCJKFontFamily)")
        media.addOption(":freetype-monofont=\(resolvedCJKFontFamily)")
        if let fontDirectory = resolvedCJKFontDirectory {
            media.addOption(":ssa-fontsdir=\(fontDirectory)")
        }
        let fontSize = preferredSubtitleRendererFontSize().intValue
        media.addOption(":freetype-fontsize=\(fontSize)")
        // Force UTF-8 detection for embedded subtitle text tracks.
        media.addOption(":subsdec-autodetect-utf8=1")
    }

    /// Configure buffering, clock, and decoding options for smooth playback.
    /// Matches the iOS VLCPlaybackService.configureMediaOptions behavior.
    private func configurePlaybackOptions(for media: VLCMedia, file: VideoFile) {
        // Network buffering for remote streams.
        if file.isRemote {
            let cachingMs = (file.serverType?.requiresDynamicPlaybackURL == true)
                ? (file.type == .audio ? 750 : 1200)
                : 3000
            media.addOption(":network-caching=\(cachingMs)")
            media.addOption(":live-caching=\(cachingMs)")
            media.addOption(":file-caching=\(cachingMs)")
        }

        // Reduce audio sync delay on resume.
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")
        media.addOption(":no-sub-autodetect-file")

        let scheme = file.url.scheme?.lowercased() ?? ""
        let embeddedUser = file.url.user
        let embeddedPassword = file.url.password

        if let server = tvPlaybackResolvedServer(for: file) {
            switch server.type {
            case .smb:
                guard scheme == "smb" else { break }
                let user = tvTrimmedPlaybackText(embeddedUser) ?? tvTrimmedPlaybackText(server.username)
                let password = tvTrimmedPlaybackText(embeddedPassword) ?? tvTrimmedPlaybackText(server.passwordSecret)
                if let user {
                    media.addOption(":smb-user=\(user)")
                }
                if let password {
                    media.addOption(":smb-pwd=\(password)")
                }
            case .webdav, .alist, .pan115, .onedrive, .googledrive:
                guard scheme == "http" || scheme == "https" else { break }
                if server.type == .webdav, let user = tvTrimmedPlaybackText(server.username) {
                    media.addOption(":http-user=\(user)")
                }
                if server.type == .webdav, let password = tvTrimmedPlaybackText(server.passwordSecret) {
                    media.addOption(":http-pwd=\(password)")
                }
                if server.type == .pan115 {
                    media.addOption(":http-user-agent=\(Pan115Manager.defaultUserAgent)")
                    media.addOption(":http-referrer=https://115.com")
                    if let cookie = server.passwordSecret ?? server.accessToken, !cookie.isEmpty {
                        media.addOption(":http-cookie=\(cookie)")
                        media.addOption(":http-cookies=\(cookie)")
                    }
                }
            case .vod:
                guard scheme == "http" || scheme == "https" else { break }
                media.addOption(":http-user-agent=\(VODService.defaultUserAgent)")
            default:
                break
            }
        }

        if abs(subtitleDelay) > 0.001 {
            media.addOption(":sub-delay=\(subtitleDelay)")
            media.addOption(":spu-delay=\(Int(subtitleDelay * 1_000_000))")
        }

        let audioDelayMs = Int(audioDelay * 1000)
        if audioDelayMs != 0 {
            media.addOption(":audio-desync=\(audioDelayMs)")
        }

        switch currentDecoder {
        case .hardware:
            media.addOption(":avcodec-hw=any")
        case .software:
            media.addOption(":avcodec-hw=none")
            media.addOption(":codec=avcodec")
        }
    }

    private func preferredSubtitleRendererFontSize() -> NSNumber {
        let shorterSide = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let scaledSize = max(24.0, min(30.0, round(shorterSide * 0.034)))
        return NSNumber(value: Double(scaledSize))
    }

    private func playbackMedia(for file: VideoFile) -> VLCMedia {
        let runtimeURL = RuntimeNetworkAddressResolver.runtimeURL(from: file.url)
        let scheme = runtimeURL.scheme?.lowercased()

        var mediaURL = runtimeURL
        var embeddedUser: String?
        var embeddedPassword: String?

        if scheme == "smb",
           var components = URLComponents(url: runtimeURL, resolvingAgainstBaseURL: false) {
            embeddedUser = components.user
            embeddedPassword = components.password
            components.user = nil
            components.password = nil
            mediaURL = components.url ?? runtimeURL
        }

        let media = VLCMedia(url: mediaURL)
        configureRemoteFileAccessOptions(
            for: media,
            file: file,
            embeddedUser: embeddedUser,
            embeddedPassword: embeddedPassword,
            scheme: scheme
        )
        return media
    }

    private func configureRemoteFileAccessOptions(
        for media: VLCMedia,
        file: VideoFile,
        embeddedUser: String?,
        embeddedPassword: String?,
        scheme: String?
    ) {
        guard file.isRemote,
              let server = tvPlaybackResolvedServer(for: file) else {
            return
        }

        switch server.type {
        case .smb:
            guard scheme == "smb" else { return }
            let user = tvTrimmedPlaybackText(embeddedUser) ?? tvTrimmedPlaybackText(server.username)
            let password = tvTrimmedPlaybackText(embeddedPassword) ?? tvTrimmedPlaybackText(server.passwordSecret)
            if let user {
                media.addOption(":smb-user=\(user)")
            }
            if let password {
                media.addOption(":smb-pwd=\(password)")
            }
        case .webdav, .alist, .pan115, .onedrive, .googledrive:
            guard scheme == "http" || scheme == "https" else { return }
            if server.type == .webdav, let user = tvTrimmedPlaybackText(server.username) {
                media.addOption(":http-user=\(user)")
            }
            if server.type == .webdav, let password = tvTrimmedPlaybackText(server.passwordSecret) {
                media.addOption(":http-pwd=\(password)")
            }
            if server.type == .pan115 {
                media.addOption(":http-user-agent=\(Pan115Manager.defaultUserAgent)")
                media.addOption(":http-referrer=https://115.com")
                if let cookie = server.passwordSecret ?? server.accessToken, !cookie.isEmpty {
                    media.addOption(":http-cookie=\(cookie)")
                    media.addOption(":http-cookies=\(cookie)")
                }
            }
        default:
            break
        }
    }

    private func prepareSubtitlePlaybackURL(
        for file: VideoFile,
        playlist: [VideoFile]?,
        preferredSubtitleURL: URL? = nil
    ) async -> URL? {
        guard let subtitleURL = preferredSubtitleURL ?? tvPreferredSubtitleURL(for: file, playlist: playlist) else {
            return nil
        }

        let localSourceURL = await cacheRemoteSubtitleToLocalIfNeeded(subtitleURL) ?? subtitleURL
        return normalizedExternalSubtitleURL(for: localSourceURL)
    }

    private func cacheRemoteSubtitleToLocalIfNeeded(_ originalURL: URL) async -> URL? {
        let key = subtitleURLKey(originalURL)
        if let cached = normalizedSubtitleCache[key],
           cached.isFileURL,
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let scheme = originalURL.scheme?.lowercased()
        guard scheme == "smb" || scheme == "http" || scheme == "https" else {
            return nil
        }

        do {
            let downloadedURL: URL
            if let server = resolveServerForSubtitle(originalURL) {
                let path: String
                if server.type == .jellyfin || server.type == .emby || server.type == .plex {
                    path = originalURL.absoluteString
                } else {
                    path = originalURL.path.removingPercentEncoding ?? originalURL.path
                }
                guard !path.isEmpty else { return nil }
                downloadedURL = try await AppNetworkService.shared.downloadFile(server: server, at: path)
            } else {
                let request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: originalURL))
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    return nil
                }

                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(originalURL.pathExtension.isEmpty ? "sub" : originalURL.pathExtension)
                try data.write(to: tempURL, options: .atomic)
                downloadedURL = tempURL
            }

            let localURL = tvRemoteSubtitleOutputURL(for: originalURL, key: key)
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: localURL.path) {
                try fileManager.removeItem(at: localURL)
            }
            try fileManager.copyItem(at: downloadedURL, to: localURL)
            normalizedSubtitleCache[key] = localURL
            return localURL
        } catch {
            return nil
        }
    }

    private func resolveServerForSubtitle(_ subtitleURL: URL) -> ServerConfig? {
        let servers = AppNetworkService.shared.savedServers
        if let serverID = resolvedFile?.jellyfinServerId,
           let uuid = UUID(uuidString: serverID),
           let matched = servers.first(where: { $0.id == uuid }) {
            return matched
        }

        guard let host = subtitleURL.host?.lowercased() else { return nil }
        return servers.first { server in
            normalizeServerHost(server.address) == host
        }
    }

    private func normalizeServerHost(_ rawAddress: String) -> String {
        var address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if address.hasPrefix("smb://") { address.removeFirst("smb://".count) }
        if address.hasPrefix("http://") { address.removeFirst("http://".count) }
        if address.hasPrefix("https://") { address.removeFirst("https://".count) }
        if let slashIndex = address.firstIndex(of: "/") {
            address = String(address[..<slashIndex])
        }
        if let colonIndex = address.firstIndex(of: ":") {
            address = String(address[..<colonIndex])
        }
        return address
    }

    private func normalizedExternalSubtitleURL(for originalURL: URL) -> URL {
        let key = subtitleURLKey(originalURL)
        if let cached = normalizedSubtitleCache[key] {
            if cached.isFileURL, !FileManager.default.fileExists(atPath: cached.path) {
                normalizedSubtitleCache.removeValue(forKey: key)
            } else {
                return cached
            }
        }

        if let scheme = originalURL.scheme?.lowercased(),
           scheme == "smb",
           var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false),
           components.user != nil {
            components.user = nil
            components.password = nil
            let sanitizedURL = components.url ?? originalURL
            normalizedSubtitleCache[key] = sanitizedURL
            return sanitizedURL
        }

        guard originalURL.isFileURL else {
            normalizedSubtitleCache[key] = originalURL
            return originalURL
        }

        guard let data = try? Data(contentsOf: originalURL), !data.isEmpty else {
            normalizedSubtitleCache[key] = originalURL
            return originalURL
        }

        guard let decodedText = decodeExternalSubtitleText(data: data) else {
            normalizedSubtitleCache[key] = originalURL
            return originalURL
        }

        var normalizedText = decodedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalizedText.hasPrefix("\u{FEFF}") {
            normalizedText.removeFirst()
        }

        guard let normalizedData = normalizedText.data(using: .utf8) else {
            normalizedSubtitleCache[key] = originalURL
            return originalURL
        }

        let outputURL = tvNormalizedSubtitleOutputURL(for: originalURL, key: key)
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try normalizedData.write(to: outputURL, options: .atomic)
            normalizedSubtitleCache[key] = outputURL
            return outputURL
        } catch {
            normalizedSubtitleCache[key] = originalURL
            return originalURL
        }
    }

    private func subtitleURLKey(_ url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    private func decodeExternalSubtitleText(data: Data) -> String? {
        var candidates: [String.Encoding] = []
        if let bom = tvBOMDetectedEncoding(in: data) {
            candidates.append(bom)
        }

        candidates.append(contentsOf: [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .unicode,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.shiftJIS.rawValue))),
            .windowsCP1252
        ])

        var deduped: [String.Encoding] = []
        var seen = Set<UInt>()
        for encoding in candidates {
            if seen.insert(encoding.rawValue).inserted {
                deduped.append(encoding)
            }
        }

        var bestText: String?
        var bestScore = Int.min
        for encoding in deduped {
            guard let text = String(data: data, encoding: encoding), !text.isEmpty else { continue }
            let score = subtitleDecodeScore(for: text)
            if score > bestScore {
                bestScore = score
                bestText = text
            }
        }

        guard bestScore >= 0 else { return nil }
        return bestText
    }

    private func subtitleDecodeScore(for text: String) -> Int {
        if text.isEmpty {
            return Int.min
        }

        var score = 0
        if text.contains("-->") { score += 30 }
        if text.localizedCaseInsensitiveContains("Dialogue:") { score += 30 }
        if text.localizedCaseInsensitiveContains("WEBVTT") { score += 20 }

        let lineCount = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        if lineCount >= 3 { score += 10 }

        let replacementCount = text.filter { $0 == "\u{FFFD}" }.count
        score -= replacementCount * 40

        var controlCharCount = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar),
               scalar != "\n",
               scalar != "\r",
               scalar != "\t" {
                controlCharCount += 1
            }
        }
        score -= controlCharCount * 8

        let totalScalars = max(text.unicodeScalars.count, 1)
        let printableScalars = text.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\r" || scalar == "\t"
        }.count
        let printableRatio = Double(printableScalars) / Double(totalScalars)
        if printableRatio > 0.97 {
            score += 15
        } else if printableRatio < 0.90 {
            score -= 15
        }

        let cjkScalarCount = text.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x3040...0x30FF, 0xAC00...0xD7AF:
                return true
            default:
                return false
            }
        }.count
        if cjkScalarCount > 0 {
            score += min(45, cjkScalarCount * 2)
        }

        let mojibakeMarkers = ["Ã", "Â", "Ð", "Æ", "â€", "â€™", "鈥", "锟", "�"]
        for marker in mojibakeMarkers where text.contains(marker) {
            score -= 24
        }

        return score
    }
}

private struct TVAudioPlaybackBackdrop: View {
    @ObservedObject var session: TVPlaybackSession
    @State private var dominantColor: Color? = nil
    @State private var artworkColorRequest = UUID()

    private var accent: Color {
        tvPlaybackAccentColor(for: session.displayFile.type)
    }

    var body: some View {
        VStack(spacing: 28) {
            TVAudioArtworkPlate(
                artwork: session.audioArtwork,
                accent: accent
            )

            VStack(spacing: 10) {
                Text(session.displayPlaybackTitle)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 820)

                Text(session.audioSubtitleText)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white.opacity(0.66))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 120)
        .offset(y: -74)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(background)
        .onAppear {
            updateDominantColor(from: session.audioArtwork)
        }
        .onChange(of: session.audioArtwork) { newArtwork in
            updateDominantColor(from: newArtwork)
        }
    }

    @ViewBuilder
    private var background: some View {
        ZStack {
            if let dominantColor {
                dominantColor.ignoresSafeArea()
            } else {
                LinearGradient(
                    colors: [
                        Color(red: 0.06, green: 0.05, blue: 0.08),
                        Color(red: 0.10, green: 0.07, blue: 0.10),
                        Color.black
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }
            
            if let artwork = session.audioArtwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .opacity(0.15)
                    .blur(radius: 60)
                    .blendMode(.luminosity)
                    .clipped()
            } else {
                Image(systemName: "waveform")
                    .font(.system(size: 620, weight: .regular))
                    .foregroundColor(accent.opacity(0.10))
                    .rotationEffect(.degrees(-8))
                    .offset(x: 250, y: -80)
            }
            
            LinearGradient(
                colors: [
                    Color.black.opacity(0.3),
                    Color.black.opacity(0.7)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private func updateDominantColor(from image: UIImage?) {
        let request = UUID()
        artworkColorRequest = request
        guard let image = image, let cgImage = image.cgImage else {
            dominantColor = nil
            return
        }
        Task.detached(priority: .background) {
            let color = extractDominantColor(from: cgImage)
            await MainActor.run {
                guard artworkColorRequest == request else { return }
                self.dominantColor = Color(color)
            }
        }
    }

    private func extractDominantColor(from cgImage: CGImage) -> UIColor {
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

private struct TVAudioArtworkPlate: View {
    let artwork: UIImage?
    let accent: Color

    var body: some View {
        ZStack {
            if let artwork {
                Image(uiImage: artwork)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 340, height: 340)
                    .clipped()
            } else {
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                accent.opacity(0.78),
                                Color(red: 0.18, green: 0.13, blue: 0.18),
                                Color.black.opacity(0.84)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "waveform")
                    .font(.system(size: 145, weight: .regular))
                    .foregroundColor(.white.opacity(0.72))
            }
        }
        .frame(width: 340, height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.38), radius: 32, x: 0, y: 22)
    }
}

private struct TVSecondarySubtitleOverlay: View {
    @ObservedObject var session: TVPlaybackSession

    var body: some View {
        GeometryReader { geometry in
            let videoRect = session.secondarySubtitleVideoRect(in: geometry.size)
            let maxWidth = max(0, videoRect.width - 120)
            let parts = subtitleParts
            let fontSize = secondarySubtitleFontSize(for: videoRect.height)

            if !session.isNativeRenderedSecondarySubtitle,
               videoRect.width > 0,
               videoRect.height > 0,
               (!parts.isEmpty || session.isSecondarySubtitlePositionAdjustmentActive) {
                ZStack {
                    if !parts.isEmpty {
                        subtitleOverlayView(parts, maxWidth: maxWidth, fontSize: fontSize)
                            .position(
                                x: videoRect.width / 2,
                                y: session.secondarySubtitleVerticalPosition(in: videoRect.height)
                            )
                    } else if session.isSecondarySubtitlePositionAdjustmentActive {
                        adjustmentBackground(maxWidth: maxWidth)
                            .position(
                                x: videoRect.width / 2,
                                y: session.secondarySubtitleVerticalPosition(in: videoRect.height)
                            )
                    }
                }
                .frame(width: videoRect.width, height: videoRect.height)
                .position(x: videoRect.midX, y: videoRect.midY)
            }
        }
    }

    private var subtitleParts: [SubtitlePart] {
        if session.secondarySubtitleStatus == .loading {
            return [
                SubtitlePart(
                    start: 0,
                    end: .greatestFiniteMagnitude,
                    text: NSAttributedString(string: platformShellString("Platform Shell TV Loading"))
                )
            ]
        }
        if session.secondarySubtitleStatus == .failed {
            return [
                SubtitlePart(
                    start: 0,
                    end: .greatestFiniteMagnitude,
                    text: NSAttributedString(string: platformShellString("Secondary Subtitle Load Failed"))
                )
            ]
        }
        return session.secondarySubtitleParts
    }

    @ViewBuilder
    private func subtitleOverlayView(_ parts: [SubtitlePart], maxWidth: CGFloat, fontSize: CGFloat) -> some View {
        if session.isSecondarySubtitlePositionAdjustmentActive {
            let boxWidth = adjustmentBoxWidth(maxWidth: maxWidth)
            let horizontalPadding: CGFloat = 48
            let verticalPadding: CGFloat = 16
            let contentWidth = max(0, boxWidth - horizontalPadding * 2)

            subtitlePartsView(parts, maxWidth: contentWidth, fontSize: fontSize)
                .frame(width: contentWidth)
                .padding(.vertical, verticalPadding)
                .frame(width: boxWidth)
                .background(adjustmentBackgroundShape)
        } else {
            subtitlePartsView(parts, maxWidth: maxWidth, fontSize: fontSize)
        }
    }

    private func adjustmentBackground(maxWidth: CGFloat) -> some View {
        adjustmentBackgroundShape
            .frame(width: adjustmentBoxWidth(maxWidth: maxWidth), height: 92)
    }

    private var adjustmentBackgroundShape: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.black.opacity(0.30))
            .shadow(color: Color.black.opacity(0.24), radius: 7, x: 0, y: 2)
    }

    private func adjustmentBoxWidth(maxWidth: CGFloat) -> CGFloat {
        max(320, maxWidth)
    }

    private func secondarySubtitleFontSize(for videoHeight: CGFloat) -> CGFloat {
        min(max(videoHeight * 0.030, 24), 30)
    }

    private func subtitlePartsView(_ parts: [SubtitlePart], maxWidth: CGFloat, fontSize: CGFloat) -> some View {
        VStack(spacing: 4) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                subtitlePartView(part, maxWidth: maxWidth, fontSize: fontSize)
            }
        }
        .frame(maxWidth: maxWidth)
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
            let isDrawingCommand = textString.hasPrefix("m ") ||
                (textString.contains(" m ") && textString.range(of: #"[0-9\-\s]+$"#, options: .regularExpression) != nil)

            if !textString.isEmpty && !isDrawingCommand {
                TVSecondarySubtitleTextView(attributedText: attrText, fontSize: fontSize)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: maxWidth)
            }
        }
    }
}

private struct TVSecondarySubtitleTextView: UIViewRepresentable {
    let attributedText: NSAttributedString
    let fontSize: CGFloat

    func makeUIView(context: Context) -> TVSubtitlePaddedLabel {
        let label = TVSubtitlePaddedLabel()
        label.numberOfLines = 0
        label.textAlignment = .center
        label.backgroundColor = .clear
        label.textInsets = UIEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)
        label.outlineColor = UIColor.black.withAlphaComponent(0.90)
        label.outlineWidth = 2.2
        return label
    }

    func updateUIView(_ uiView: TVSubtitlePaddedLabel, context: Context) {
        let mutableAttr = NSMutableAttributedString(attributedString: attributedText)
        let range = NSRange(location: 0, length: mutableAttr.length)
        let baseFontSize = min(max(fontSize, 22), 32)
        uiView.outlineWidth = max(1.8, min(baseFontSize * 0.075, 2.3))

        [
            NSAttributedString.Key.foregroundColor,
            NSAttributedString.Key.strokeColor,
            NSAttributedString.Key.strokeWidth,
            NSAttributedString.Key.shadow,
            NSAttributedString.Key.backgroundColor
        ].forEach { key in
            mutableAttr.removeAttribute(key, range: range)
        }

        var hasFont = false
        mutableAttr.enumerateAttribute(.font, in: range, options: []) { value, attrRange, _ in
            if let font = value as? UIFont {
                hasFont = true
                let traits = font.fontDescriptor.symbolicTraits
                let weight: UIFont.Weight = traits.contains(.traitBold) ? .bold : .semibold
                let pointSize = min(max(font.pointSize * 0.62, baseFontSize * 0.88), baseFontSize * 1.08)
                mutableAttr.addAttribute(.font, value: UIFont.systemFont(ofSize: pointSize, weight: weight), range: attrRange)
            }
        }
        if !hasFont {
            mutableAttr.addAttribute(.font, value: UIFont.systemFont(ofSize: baseFontSize, weight: .semibold), range: range)
        }

        mutableAttr.addAttribute(.foregroundColor, value: UIColor.white, range: range)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineSpacing = max(2, baseFontSize * 0.08)
        mutableAttr.addAttribute(.paragraphStyle, value: paragraphStyle, range: range)
        uiView.attributedText = mutableAttr
    }
}

private final class TVSubtitlePaddedLabel: UILabel {
    var textInsets = UIEdgeInsets.zero {
        didSet { invalidateIntrinsicContentSize() }
    }
    var outlineColor = UIColor.black.withAlphaComponent(0.90)
    var outlineWidth: CGFloat = 2.2

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let insetRect = bounds.inset(by: textInsets)
        let textRect = super.textRect(forBounds: insetRect, limitedToNumberOfLines: numberOfLines)
        let invertedInsets = UIEdgeInsets(
            top: -textInsets.top,
            left: -textInsets.left,
            bottom: -textInsets.bottom,
            right: -textInsets.right
        )
        return textRect.inset(by: invertedInsets)
    }

    override func drawText(in rect: CGRect) {
        let insetRect = rect.inset(by: textInsets)
        guard let attributedText, attributedText.length > 0 else {
            super.drawText(in: insetRect)
            return
        }

        let range = NSRange(location: 0, length: attributedText.length)
        let drawOptions: NSStringDrawingOptions = [
            .usesLineFragmentOrigin,
            .usesFontLeading
        ]

        if outlineWidth > 0 {
            let outlineText = NSMutableAttributedString(attributedString: attributedText)
            outlineText.addAttributes([
                .strokeColor: outlineColor,
                .strokeWidth: outlineWidth
            ], range: range)
            outlineText.draw(with: insetRect, options: drawOptions, context: nil)
        }

        if let context = UIGraphicsGetCurrentContext() {
            context.saveGState()
            context.setShadow(
                offset: CGSize(width: 0, height: 1.0),
                blur: 1.6,
                color: UIColor.black.withAlphaComponent(0.78).cgColor
            )
            attributedText.draw(with: insetRect, options: drawOptions, context: nil)
            context.restoreGState()
        } else {
            attributedText.draw(with: insetRect, options: drawOptions, context: nil)
        }
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: size.width + textInsets.left + textInsets.right,
            height: size.height + textInsets.top + textInsets.bottom
        )
    }
}

private struct TVPlaybackSeekFeedbackOverlay: View {
    let feedback: TVPlaybackSeekFeedback

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: feedback.systemImageName)
                .font(.system(size: 54, weight: .semibold))
                .foregroundColor(.white)

            Text(feedback.secondsText)
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Text(tvPlaybackTimeText(feedback.targetTime))
                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.72))
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 24)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color.black.opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.34), radius: 22, x: 0, y: 12)
        .allowsHitTesting(false)
    }
}

private struct TVPlaybackBlurSurface: UIViewRepresentable {
    let style: UIBlurEffect.Style
    var tintColor: UIColor = UIColor.black.withAlphaComponent(0.22)

    func makeUIView(context: Context) -> UIVisualEffectView {
        let view = UIVisualEffectView(effect: UIBlurEffect(style: style))
        view.backgroundColor = tintColor
        return view
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: style)
        uiView.backgroundColor = tintColor
    }
}

private func tvStreamString(_ stream: [String: Any], _ key: String) -> String? {
    guard let value = stream[key] as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

private func tvStreamInt(_ stream: [String: Any], _ key: String) -> Int? {
    if let value = stream[key] as? Int {
        return value
    }
    if let value = stream[key] as? Int64 {
        return Int(clamping: value)
    }
    if let value = stream[key] as? Double {
        return Int(value)
    }
    if let value = stream[key] as? String {
        return Int(value)
    }
    return nil
}

private func tvStreamDouble(_ stream: [String: Any], _ key: String) -> Double? {
    if let value = stream[key] as? Double {
        return value
    }
    if let value = stream[key] as? Float {
        return Double(value)
    }
    if let value = stream[key] as? Int {
        return Double(value)
    }
    if let value = stream[key] as? String {
        return Double(value)
    }
    return nil
}

private func tvStreamBool(_ stream: [String: Any], _ key: String) -> Bool? {
    if let value = stream[key] as? Bool {
        return value
    }
    if let value = stream[key] as? Int {
        return value != 0
    }
    if let value = stream[key] as? String {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true", "yes", "1":
            return true
        case "false", "no", "0":
            return false
        default:
            return nil
        }
    }
    return nil
}

private func tvPlaybackFileSizeText(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1.0 {
        return String(format: "%.1f GB", gb)
    }
    let mb = Double(bytes) / 1_048_576
    if mb >= 1.0 {
        return String(format: "%.0f MB", mb)
    }
    let kb = Double(bytes) / 1024
    return String(format: "%.0f KB", max(kb, 0))
}

private func tvPlaybackBitrateText(_ bitrate: Int) -> String {
    "\(bitrate / 1000) kbps"
}

private func tvPlaybackYesNoText(_ value: Bool) -> String {
    value ? platformShellString("Yes") : platformShellString("No")
}

private struct TVPlaybackChromeOverlay: View {
    @ObservedObject var session: TVPlaybackSession

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                chromeBackdrop

                if session.activePanel != nil {
                    Color.black.opacity(0.30)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }

                if session.activePanel != nil {
                    let layout = TVPlaybackDrawerLayout(viewportHeight: geometry.size.height, isAudio: session.isAudioPlayback)
                    TVPlaybackOptionsDrawer(session: session, layout: layout)
                        .padding(.horizontal, session.isAudioPlayback ? 128 : 96)
                        .padding(.top, layout.topInset)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                        .tvPlaybackFocusSectionIfAvailable()
                        .transition(.opacity)
                } else if session.isDirectSecondarySubtitlePositionAdjustmentActive {
                    TVSecondarySubtitleAdjustmentHUD(session: session)
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .center)
                } else if !session.isShowingPlaylistOverlay {
                    if session.isAudioPlayback {
                        TVPlaybackTransportBar(session: session)
                            .padding(.horizontal, 96)
                            .padding(.bottom, 50)
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
                    } else {
                        TVPlaybackTransportBar(session: session)
                            .padding(.horizontal, 96)
                            .padding(.bottom, 54)
                            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottom)
        }
        .ignoresSafeArea()

    }

    private var chromeBackdrop: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: session.isAudioPlayback
                    ? [
                        Color.black.opacity(0.00),
                        Color.black.opacity(0.10),
                        Color.black.opacity(0.64)
                    ]
                    : [
                        Color.black.opacity(0.00),
                        Color.black.opacity(0.08),
                        Color.black.opacity(0.62)
                    ],
                startPoint: .top,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [
                    Color.black.opacity(0.00),
                    Color.black.opacity(session.isAudioPlayback ? 0.72 : 0.66)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: session.isAudioPlayback ? 420 : 360)
        }
        .ignoresSafeArea()
    }
}

private struct TVPlaybackQuickActionsView: View, Equatable {
    struct Snapshot: Equatable {
        let hasPlaylistOptions: Bool
        let isShowingPlaylistOverlay: Bool
        let hasAudioTrackOptions: Bool
        let audioTracks: [MediaTrack]
        let currentAudioTrackID: Int
        let hasSubtitleTrackOptions: Bool
        let subtitleTracks: [MediaTrack]
        let currentSubtitleTrackID: Int
        let isSecondarySubtitlesEnabled: Bool
        let secondarySubtitleTracks: [EmbeddedSubtitleTrack]
        let currentSecondarySubtitleTrackID: String?
        let isLiveStream: Bool
        let availablePlaybackRates: [Float]
        let playbackRate: Float
        let isAudioPlayback: Bool
        let selectedPlaybackQualityID: String?
        let playbackQualityOptions: [RemotePlaybackQualityOption]
        let videoDisplayMode: VideoDisplayMode
        let aspectRatio: String
        let availableAspectRatios: [String]
        let isOptionsDrawerActive: Bool
        let controlFocusTarget: TVPlaybackSession.ControlFocusRequest.Target?
        let shouldPreferQuickActionControlFocus: Bool
    }

    let snapshot: Snapshot
    let session: TVPlaybackSession

    static func == (lhs: TVPlaybackQuickActionsView, rhs: TVPlaybackQuickActionsView) -> Bool {
        lhs.snapshot == rhs.snapshot
    }

    private enum QuickActionFocusSlot {
        case playlist
        case audio
        case subtitles
        case speed
        case display
        case more
    }

    var body: some View {
        HStack(spacing: 14) {
            if snapshot.hasPlaylistOptions {
                quickActionButton(
                    title: platformShellString("Playlist"),
                    systemImageName: "list.bullet",
                    isActive: snapshot.isShowingPlaylistOverlay,
                    prefersDefaultFocus: shouldPreferQuickActionFocus(.playlist)
                ) {
                    session.isShowingPlaylistOverlay.toggle()
                }
            }

            if snapshot.hasAudioTrackOptions {
                quickActionMenu(
                    title: platformShellString("Audio"),
                    systemImageName: "waveform",
                    prefersDefaultFocus: shouldPreferControlFocus(for: .tracks) ||
                        shouldPreferQuickActionFocus(.audio),
                    fallbackAction: { session.openTrackGroup(.audio) },
                    menu: audioMenu
                )
            }

            if snapshot.hasSubtitleTrackOptions {
                quickActionMenu(
                    title: platformShellString("Subtitles"),
                    systemImageName: "captions.bubble",
                    prefersDefaultFocus: shouldPreferQuickActionFocus(.subtitles),
                    fallbackAction: { session.openTrackGroup(.primarySubtitle) },
                    menu: subtitleMenu
                )
            }

            if !snapshot.isLiveStream {
                quickActionMenu(
                    title: platformShellString("Speed"),
                    systemImageName: "speedometer",
                    prefersDefaultFocus: shouldPreferQuickActionFocus(.speed),
                    fallbackAction: { session.openPlaybackGroup(.speed) },
                    menu: speedMenu
                )
            }

            if !snapshot.isAudioPlayback {
                quickActionMenu(
                    title: platformShellString("Display"),
                    systemImageName: "rectangle.inset.filled",
                    prefersDefaultFocus: shouldPreferControlFocus(for: .picture) ||
                        shouldPreferQuickActionFocus(.display),
                    fallbackAction: { session.openPanel(.picture) },
                    menu: displayMenu
                )
            }

            quickActionButton(
                title: platformShellString("More"),
                systemImageName: "ellipsis",
                isActive: snapshot.isOptionsDrawerActive,
                prefersDefaultFocus: shouldPreferControlFocus(for: .info) ||
                    shouldPreferQuickActionFocus(.more)
            ) {
                session.openOptionsDrawer()
            }
        }
    }

    private func menuAction(_ title: String, selected: Bool, enabled: Bool = true,
                            action: @escaping () -> Void) -> UIAction {
        UIAction(title: title, attributes: enabled ? [] : [.disabled], state: selected ? .on : .off) { _ in action() }
    }

    private var audioMenu: UIMenu {
        UIMenu(children: snapshot.audioTracks.map { track in
            menuAction(track.name, selected: snapshot.currentAudioTrackID == track.id) {
                session.selectAudioTrack(track.id, closesPanel: false)
            }
        })
    }

    private var subtitleMenu: UIMenu {
        var primary: [UIMenuElement] = [menuAction(platformShellString("Off"), selected: snapshot.currentSubtitleTrackID == -1) {
            session.selectSubtitleTrack(-1, closesPanel: false)
        }]
        primary += snapshot.subtitleTracks.map { track in
            menuAction(track.name, selected: snapshot.currentSubtitleTrackID == track.id) {
                session.selectSubtitleTrack(track.id, closesPanel: false)
            }
        }
        guard snapshot.isSecondarySubtitlesEnabled else { return UIMenu(children: primary) }
        var secondary: [UIMenuElement] = [menuAction(platformShellString("Off"), selected: snapshot.currentSecondarySubtitleTrackID == nil) {
            session.selectSecondarySubtitleTrack(nil, closesPanel: false)
        }]
        secondary += snapshot.secondarySubtitleTracks.map { track in
            menuAction(secondarySubtitleMenuTitle(for: track), selected: snapshot.currentSecondarySubtitleTrackID == track.id,
                       enabled: session.canSelectSecondarySubtitle(track)) {
                session.selectSecondarySubtitleTrack(track.id, closesPanel: false)
            }
        }
        return UIMenu(children: [
            UIMenu(title: platformShellString("Secondary Subtitles"), options: .displayInline, children: secondary),
            UIMenu(title: platformShellString("Primary Subtitle"), options: .displayInline, children: primary)
        ])
    }

    private var speedMenu: UIMenu {
        UIMenu(children: snapshot.availablePlaybackRates.map { rate in
            menuAction("\(String(format: "%g", rate))x", selected: abs(snapshot.playbackRate - rate) < 0.01) {
                session.setPlaybackRate(rate)
            }
        })
    }

    private var displayMenu: UIMenu {
        var groups: [UIMenuElement] = []
        if snapshot.playbackQualityOptions.count > 1 {
            groups.append(UIMenu(title: platformShellString("Playback Quality"), options: .displayInline,
                                 children: snapshot.playbackQualityOptions.map { option in
                menuAction(tvPlaybackQualityTitle(for: option), selected: snapshot.selectedPlaybackQualityID == option.id) {
                    session.selectPlaybackQuality(option.id)
                }
            }))
        }
        groups.append(UIMenu(title: platformShellString("Screen Mode"), options: .displayInline,
                             children: VideoDisplayMode.allCases.map { mode in
            menuAction(mode.tvLocalizedTitle, selected: snapshot.videoDisplayMode == mode) { session.setVideoDisplayMode(mode) }
        }))
        groups.append(UIMenu(title: platformShellString("Aspect Ratio"), options: .displayInline,
                             children: snapshot.availableAspectRatios.map { ratio in
            menuAction(ratio.isEmpty ? platformShellString("Auto") : ratio, selected: snapshot.aspectRatio == ratio) {
                session.setAspectRatio(ratio)
            }
        }))
        return UIMenu(children: groups)
    }

    @ViewBuilder
    private func quickActionMenu(
        title: String,
        systemImageName: String,
        isActive: Bool = false,
        prefersDefaultFocus: Bool = false,
        fallbackAction: @escaping () -> Void,
        menu: UIMenu
    ) -> some View {
        if #available(tvOS 17.0, *) {
            TVPlaybackNativeMenu(title: title, systemImage: systemImageName, menu: menu,
                                 onPresent: { interaction in
                session.beginNativeMenuPresentation { [weak interaction] in interaction?.dismissMenu() }
            }, onDismiss: {
                session.finishNativeMenuPresentation()
            })
            .frame(width: 48, height: 48)
        } else {
            quickActionButton(title: title, systemImageName: systemImageName, isActive: isActive,
                              prefersDefaultFocus: prefersDefaultFocus, action: fallbackAction)
        }
    }

    private func secondarySubtitleMenuTitle(for track: EmbeddedSubtitleTrack) -> String {
        guard let detail = session.secondarySubtitleDetailText(for: track),
              !detail.isEmpty else {
            return session.secondarySubtitleDisplayTitle(for: track)
        }
        return "\(session.secondarySubtitleDisplayTitle(for: track)) · \(detail)"
    }

    private func quickActionButton(
        title: String,
        systemImageName: String,
        isActive: Bool,
        prefersDefaultFocus: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TVPlaybackIconActionControl(
                title: title,
                systemImageName: systemImageName,
                isActive: isActive
            )
        }
        .buttonStyle(TVPlaybackPlainButtonStyle())
        .tvPlaybackDisableSystemFocusEffectIfAvailable()
    }

    private func shouldPreferControlFocus(for panel: TVPlaybackSession.Panel) -> Bool {
        guard !snapshot.isOptionsDrawerActive,
              case .panel(let requestedPanel) = snapshot.controlFocusTarget else {
            return false
        }
        return requestedPanel == panel
    }

    private func shouldPreferQuickActionFocus(_ slot: QuickActionFocusSlot) -> Bool {
        snapshot.shouldPreferQuickActionControlFocus && firstQuickActionFocusSlot == slot
    }

    private var firstQuickActionFocusSlot: QuickActionFocusSlot {
        if snapshot.hasPlaylistOptions { return .playlist }
        if snapshot.hasAudioTrackOptions { return .audio }
        if snapshot.hasSubtitleTrackOptions { return .subtitles }
        if !snapshot.isLiveStream { return .speed }
        if !snapshot.isAudioPlayback { return .display }
        return .more
    }
}

private struct TVPlaybackTransportBar: View {
    @ObservedObject var session: TVPlaybackSession
    @Namespace private var controlFocusNamespace
    #if os(tvOS)
    @Environment(\.resetFocus) private var resetFocus
    #endif

    private var barMaxWidth: CGFloat {
        1640
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerRow

            progressSection

            HStack(alignment: .center) {
                Spacer(minLength: 0)
                transportControls
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: barMaxWidth)
        .padding(.horizontal, 10)
        .tvPlaybackFocusScopeIfAvailable(controlFocusNamespace)
        .tvPlaybackFocusSectionIfAvailable()
        .onAppear {
            session.requestInitialAudioControlFocusIfNeeded()
        }
        .onChange(of: session.controlFocusRequest?.id) { _ in
            requestControlFocus()
        }
    }

    private var headerRow: some View {
        HStack(alignment: .bottom, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if session.showsDownloadedIconBeforeTitle {
                        TVPlaybackDownloadedStatusIcon(size: session.isAudioPlayback ? 18 : 20)
                    }

                    Text(session.displayPlaybackTitle)
                        .font(.system(size: session.isAudioPlayback ? 27 : 31, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .shadow(color: .black.opacity(0.72), radius: 10, x: 0, y: 3)
                }

                if !session.shouldShowLoadingIndicator, let status = session.playbackStatusText {
                    TVPlaybackStatusCapsule(text: status)
                }
            }

            Spacer(minLength: 18)

            quickActionControls
        }
    }

    private var quickActionControls: some View {
        TVPlaybackQuickActionsView(
            snapshot: session.quickActionSnapshot,
            session: session
        )
    }

    private var progressSection: some View {
        TVPlaybackProgressRow(session: session, timeProgress: session.timeProgress)
    }

    private var transportControls: some View {
        HStack(spacing: 30) {
            Button(action: { session.playPreviousItem() }) {
                TVPlaybackRoundControl(
                    title: platformShellString(session.isAudioPlayback ? "Previous Track" : "Previous Episode"),
                    systemImageName: "backward.end.fill",
                    size: 56,
                    iconSize: 20
                )
            }
            .buttonStyle(TVPlaybackPlainButtonStyle())
            .disabled(!session.canPlayPreviousItem)
            .tvPlaybackDisableSystemFocusEffectIfAvailable()

            Button(action: { session.togglePlayPause() }) {
                TVPlaybackRoundControl(
                    title: session.playPauseTitle,
                    systemImageName: session.isPlaying ? "pause.fill" : "play.fill",
                    size: 80,
                    iconSize: 32,
                    isPrimary: true
                )
            }
            .buttonStyle(TVPlaybackPlainButtonStyle())
            .tvPlaybackPrefersDefaultFocusIfAvailable(session.shouldPreferTransportControlFocus, in: controlFocusNamespace)
            .tvPlaybackDisableSystemFocusEffectIfAvailable()

            Button(action: { session.playNextItem() }) {
                TVPlaybackRoundControl(
                    title: platformShellString(session.isAudioPlayback ? "Next Track" : "Next Episode"),
                    systemImageName: "forward.end.fill",
                    size: 56,
                    iconSize: 20
                )
            }
            .buttonStyle(TVPlaybackPlainButtonStyle())
            .disabled(!session.canPlayNextItem)
            .tvPlaybackDisableSystemFocusEffectIfAvailable()
        }
        .padding(.top, 2)
        .tvPlaybackFocusSectionIfAvailable()
    }

    private func requestControlFocus() {
        #if os(tvOS)
        guard let request = session.controlFocusRequest else { return }
        for delay in [0.0, 0.08, 0.20] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                resetFocus(in: controlFocusNamespace)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.34) {
            session.clearControlFocusRequest(id: request.id)
        }
        #endif
    }
}

private struct TVPlaybackProgressRow: View {
    let session: TVPlaybackSession
    @ObservedObject var timeProgress: TVPlaybackTimeProgress
    @ObservedObject private var epgService = EPGService.shared

    private var currentLiveProgramme: EPGProgramme? {
        let file = session.displayFile
        guard let serverIdStr = file.jellyfinServerId,
              let serverId = UUID(uuidString: serverIdStr) else {
            return nil
        }
        let dummy = IPTVChannel(
            id: file.jellyfinItemId ?? "",
            name: file.name,
            url: file.url
        )
        return epgService.currentProgramme(for: dummy, in: serverId)
    }

    var body: some View {
        if session.isLiveStream {
            let prog = currentLiveProgramme
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                        Text("LIVE")
                            .font(.system(size: 15, weight: .heavy))
                            .foregroundColor(.white)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.red.opacity(0.85))
                    )

                    Text(session.displayPlaybackTitle)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white.opacity(0.95))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.68), radius: 8, x: 0, y: 2)

                    if let prog = prog {
                        Text("·")
                            .foregroundColor(.white.opacity(0.6))
                        Text(prog.title)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text(prog.formattedTimeSpan)
                            .font(.system(size: 16, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                    }

                    Spacer()
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
        } else {
            VStack(spacing: 8) {
                TVPlaybackProgressScrubber(session: session, timeProgress: timeProgress)
                    .frame(maxWidth: .infinity)

                HStack(alignment: .center) {
                    timeLabel(tvPlaybackTimeText(timeProgress.displayCurrentTime), isCurrent: true)

                    Spacer(minLength: 24)

                    if !timeProgress.cacheReadIdle,
                       let rate = timeProgress.cacheInputBytesPerSecond, rate > 0 {
                        Text("↓ " + ByteCountFormatter.string(fromByteCount: rate, countStyle: .file) + "/s")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.72))
                            .lineLimit(1)
                            .shadow(color: .black.opacity(0.68), radius: 8, x: 0, y: 2)

                        Spacer(minLength: 24)
                    }

                    timeLabel(tvPlaybackTimeText(timeProgress.duration), isCurrent: false)
                }
                .padding(.horizontal, 2)
            }
        }
    }

    private func timeLabel(_ text: String, isCurrent: Bool) -> some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold, design: .monospaced))
            .foregroundColor(isCurrent ? .white : .white.opacity(0.56))
            .frame(minWidth: 92, alignment: isCurrent ? .leading : .trailing)
            .shadow(color: .black.opacity(0.68), radius: 8, x: 0, y: 2)
    }
}

private struct TVPlaybackProgressScrubber: View {
    let session: TVPlaybackSession
    @ObservedObject var timeProgress: TVPlaybackTimeProgress
    @State private var isFocused = false

    private var progress: CGFloat {
        guard timeProgress.duration > 0 else { return 0 }
        return CGFloat(min(max(timeProgress.displayCurrentTime / timeProgress.duration, 0), 1))
    }

    private var isActive: Bool {
        isFocused || timeProgress.isScrubbing
    }

    var body: some View {
        ZStack {
            TVPlaybackScrubberFocusHost(
                isFocused: $isFocused,
                onSelect: {
                    session.commitScrubbing()
                },
                onFocusChanged: { focused in
                    if !focused {
                        session.cancelScrubbing()
                    }
                },
                onMoveLeft: {
                    session.adjustScrubbing(by: -session.configuredSeekDuration)
                },
                onMoveRight: {
                    session.adjustScrubbing(by: session.configuredSeekDuration)
                }
            )
            .frame(height: 40)

            GeometryReader { geometry in
                let width = max(geometry.size.width, 1)
                let trackHeight: CGFloat = isActive ? 8 : 5
                let thumbSize: CGFloat = isActive ? 22 : 13
                let filledWidth = width * progress
                let thumbX = min(max(filledWidth - thumbSize / 2, 0), max(width - thumbSize, 0))
                let previewWidth: CGFloat = 280
                let previewHeight: CGFloat = 166
                let previewCenterX = min(max(filledWidth, previewWidth / 2), max(width - previewWidth / 2, previewWidth / 2))

                ZStack(alignment: .leading) {
                    if session.isScrubbing && !session.isAudioPlayback {
                        TVPlaybackScrubPreviewBubble(
                            image: session.scrubPreviewImage,
                            isLoading: session.isScrubPreviewLoading,
                            timeText: tvPlaybackTimeText(session.displayCurrentTime)
                        )
                        .frame(width: previewWidth, height: previewHeight)
                        .position(x: previewCenterX, y: -88)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                        .zIndex(2)
                    }

                    Capsule()
                        .fill(Color.white.opacity(isFocused ? 0.30 : 0.20))
                        .frame(height: trackHeight)

                    MPVBufferedTrack(ranges: timeProgress.bufferedRanges, duration: timeProgress.duration)
                        .frame(height: trackHeight)

                    Capsule()
                        .fill(Color.white)
                        .frame(width: max(progress > 0 ? trackHeight : 0, filledWidth), height: trackHeight)

                    Circle()
                        .fill(Color.white)
                        .frame(width: thumbSize, height: thumbSize)
                        .shadow(color: Color.white.opacity(isActive ? 0.34 : 0.18), radius: isActive ? 11 : 5)
                        .offset(x: thumbX)
                }
                .frame(height: geometry.size.height)
                .animation(.easeOut(duration: 0.14), value: isActive)
                .animation(.easeOut(duration: 0.10), value: progress)
            }
            .allowsHitTesting(false)
        }
        .frame(height: 40)
    }
}

private struct TVPlaybackScrubPreviewBubble: View {
    let image: UIImage?
    let isLoading: Bool
    let timeText: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.16),
                                Color.black.opacity(0.72)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "film")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundColor(.white.opacity(0.58))
                        Capsule()
                            .fill(Color.white.opacity(0.22))
                            .frame(width: 74, height: 5)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                LinearGradient(
                    colors: [
                        Color.black.opacity(0.0),
                        Color.black.opacity(0.74)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                if isLoading {
                    Color.black.opacity(image == nil ? 0.10 : 0.30)
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.94)))
                        .scaleEffect(0.82)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                Text(timeText)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.58))
                    )
                    .padding(12)
            }
            .frame(width: 280, height: 154)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.48), radius: 26, x: 0, y: 14)

            Capsule()
                .fill(Color.white.opacity(0.52))
                .frame(width: 34, height: 4)
        }
        .allowsHitTesting(false)
    }
}

private struct TVPlaybackScrubberFocusHost: UIViewRepresentable {
    @Binding var isFocused: Bool
    let onSelect: () -> Void
    let onFocusChanged: (Bool) -> Void
    let onMoveLeft: () -> Void
    let onMoveRight: () -> Void

    func makeUIView(context: Context) -> TVPlaybackScrubberFocusView {
        let view = TVPlaybackScrubberFocusView()
        updateUIView(view, context: context)
        return view
    }

    func updateUIView(_ uiView: TVPlaybackScrubberFocusView, context: Context) {
        uiView.onSelect = onSelect
        uiView.onMoveLeft = onMoveLeft
        uiView.onMoveRight = onMoveRight
        uiView.onFocusChanged = { focused in
            DispatchQueue.main.async {
                isFocused = focused
                onFocusChanged(focused)
            }
        }
    }
}

private final class TVPlaybackScrubberFocusView: UIView {
    var onSelect: (() -> Void)?
    var onFocusChanged: ((Bool) -> Void)?
    var onMoveLeft: (() -> Void)?
    var onMoveRight: (() -> Void)?

    override var canBecomeFocused: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = true
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        onFocusChanged?(isFocused)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var didHandlePress = false

        for press in presses {
            switch press.type {
            case .select:
                onSelect?()
                didHandlePress = true
            case .leftArrow:
                onMoveLeft?()
                didHandlePress = true
            case .rightArrow:
                onMoveRight?()
                didHandlePress = true
            default:
                break
            }
        }

        if !didHandlePress {
            super.pressesBegan(presses, with: event)
        }
    }
}

private struct TVPlaybackPlainButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.86 : 1.0)
    }
}

private extension View {
    @ViewBuilder
    func tvPlaybackFocusSectionIfAvailable() -> some View {
        #if os(tvOS)
        if #available(tvOS 15.0, *) {
            self.focusSection()
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func tvPlaybackDisableSystemFocusEffectIfAvailable() -> some View {
        #if os(tvOS)
        if #available(tvOS 17.0, *) {
            self.focusEffectDisabled(true)
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func tvPlaybackFocusableIfAvailable(_ isFocusable: Bool = true) -> some View {
        #if os(tvOS)
        self.focusable(isFocusable)
        #else
        self
        #endif
    }

    @ViewBuilder
    func tvPlaybackFocusScopeIfAvailable(_ namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        self.focusScope(namespace)
        #else
        self
        #endif
    }

    @ViewBuilder
    func tvPlaybackPrefersDefaultFocusIfAvailable(_ prefersDefaultFocus: Bool, in namespace: Namespace.ID) -> some View {
        #if os(tvOS)
        self.prefersDefaultFocus(prefersDefaultFocus, in: namespace)
        #else
        self
        #endif
    }
}

private enum TVPlaybackTrackGroup: String, Identifiable, Equatable {
    case audio
    case primarySubtitle
    case secondarySubtitle
    case secondarySubtitlePosition

    var id: String { rawValue }

    var systemImageName: String {
        switch self {
        case .audio:
            return "waveform"
        case .primarySubtitle:
            return "captions.bubble"
        case .secondarySubtitle:
            return "captions.bubble.fill"
        case .secondarySubtitlePosition:
            return "arrow.up.and.down"
        }
    }
}

private enum TVPlaybackPlaybackGroup: String, Identifiable, Equatable {
    case engine
    case speed
    case videoDecoder
    case audioDelay
    case subtitleDelay

    var id: String { rawValue }

    var systemImageName: String {
        switch self {
        case .engine:
            return "play.rectangle"
        case .speed:
            return "speedometer"
        case .videoDecoder:
            return "cpu"
        case .audioDelay:
            return "speaker.wave.2"
        case .subtitleDelay:
            return "captions.bubble"
        }
    }
}

private enum TVPlaybackPictureGroup: String, Identifiable, Equatable {
    case playbackQuality
    case screenMode
    case aspectRatio

    var id: String { rawValue }

    var systemImageName: String {
        switch self {
        case .playbackQuality:
            return "antenna.radiowaves.left.and.right"
        case .screenMode:
            return "rectangle.inset.filled"
        case .aspectRatio:
            return "aspectratio"
        }
    }
}

private enum TVPlaybackFocusTarget: Hashable {
    case tab(TVPlaybackSession.Panel)
    case content
    case engine(String)
    case submenuBack
    case audio(Int)
    case primarySubtitle(Int)
    case secondarySubtitle(String?)
}

private struct TVPlaybackDrawerContentHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TVPlaybackOptionsDrawer: View {
    @ObservedObject var session: TVPlaybackSession
    let layout: TVPlaybackDrawerLayout
    @State private var measuredContentHeight: CGFloat = 0
    @State private var pendingFocusRequestID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedPanel: TVPlaybackSession.Panel = .tracks
    @Namespace private var drawerFocusNamespace
    @FocusState private var focusedTarget: TVPlaybackFocusTarget?
    #if os(tvOS)
    @Environment(\.resetFocus) private var resetFocus
    #endif

    private var panels: [TVPlaybackSession.Panel] {
        session.optionPanels
    }

    private func selectPanel(_ panel: TVPlaybackSession.Panel) {
        guard selectedPanel != panel || isShowingSubmenu else { return }
        // Clicking a tab leaves the current subpage, including the current tab.
        // Merely moving focus over tabs is guarded by onFocused below.
        session.activeTrackGroup = nil
        session.activePlaybackGroup = nil
        session.activePictureGroup = nil
        session.activeInfoSectionID = nil
        selectedPanel = panel
    }

    private var contentHeight: CGFloat { layout.contentHeight(measured: measuredContentHeight) }

    private var contentIdentity: String {
        [selectedPanel.rawValue, session.activeTrackGroup?.rawValue ?? "",
         session.activePlaybackGroup?.rawValue ?? "", session.activePictureGroup?.rawValue ?? "",
         session.activeInfoSectionID ?? ""].joined(separator: "|")
    }

    private var availableTrackGroups: [TVPlaybackTrackGroup] {
        var groups: [TVPlaybackTrackGroup] = []
        if session.hasAudioTrackOptions {
            groups.append(.audio)
        }
        if !session.isAudioPlayback {
            groups.append(.primarySubtitle)
            if session.isSecondarySubtitlesEnabled {
                groups.append(.secondarySubtitle)
                groups.append(.secondarySubtitlePosition)
            }
        }
        return groups
    }

    private var availablePlaybackGroups: [TVPlaybackPlaybackGroup] {
        var groups: [TVPlaybackPlaybackGroup] = [.engine]
        if !session.isLiveStream {
            groups.append(.speed)
        }
        groups.append(.audioDelay)
        if !session.isAudioPlayback {
            groups.append(.videoDecoder)
            if !session.isLiveStream {
                groups.append(.subtitleDelay)
            }
        }
        return groups
    }

    private var availablePictureGroups: [TVPlaybackPictureGroup] {
        var groups: [TVPlaybackPictureGroup] = []
        if session.playbackQualityOptions.count > 1 {
            groups.append(.playbackQuality)
        }
        groups.append(.screenMode)
        groups.append(.aspectRatio)
        return groups
    }

    private var isShowingSubmenu: Bool {
        session.activeTrackGroup != nil ||
            session.activePlaybackGroup != nil ||
            session.activePictureGroup != nil ||
            session.activeInfoSectionID != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            topBar
                .tvPlaybackFocusSectionIfAvailable()

            Rectangle()
                .fill(Color.white.opacity(0.09))
                .frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    panelContent
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .id("drawer-content-top")
                        .background(GeometryReader { content in
                            Color.clear.preference(key: TVPlaybackDrawerContentHeight.self, value: content.size.height)
                        })
                }
                .frame(height: contentHeight, alignment: .top)
                .onPreferenceChange(TVPlaybackDrawerContentHeight.self) { height in
                    guard height > 0, abs(measuredContentHeight - height) > 0.5 else { return }
                    measuredContentHeight = height
                }
                .onChange(of: contentIdentity) { _ in
                    // Keep the focus container alive when resetting page scroll.
                    proxy.scrollTo("drawer-content-top", anchor: .top)
                    requestDrawerFocus()
                }
                .tvPlaybackFocusSectionIfAvailable()
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .frame(maxWidth: 980, alignment: .topLeading)
        .background(
            TVPlaybackBlurSurface(style: .dark, tintColor: UIColor.black.withAlphaComponent(0.32))
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.30), radius: 30, x: 0, y: 16)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: contentHeight)
        .tvPlaybackFocusScopeIfAvailable(drawerFocusNamespace)
        .onAppear {
            if let initial = session.activeOptionsPanel {
                selectedPanel = initial
            }
            applyRequestedSubmenus()
            requestDrawerFocus()
        }
        .onDisappear { pendingFocusRequestID = nil }
        .onChange(of: session.activePanel) { panel in
            if let panel {
                selectedPanel = panel
                applyRequestedSubmenus()
            }
        }
        .onChange(of: session.requestedTrackGroup) { _ in
            applyRequestedSubmenus()
        }
        .onChange(of: session.requestedPlaybackGroup) { _ in
            applyRequestedSubmenus()
        }
        .onChange(of: selectedPanel) { panel in
            if panel != .tracks {
                session.activeTrackGroup = nil
            }
            if panel != .playback {
                session.activePlaybackGroup = nil
            }
            if panel != .picture {
                session.activePictureGroup = nil
            }
            if panel != .info {
                session.activeInfoSectionID = nil
            }
            requestDrawerFocus()
        }
    }

    private func applyRequestedSubmenus() {
        if let group = session.requestedTrackGroup {
            session.activeTrackGroup = group
            selectedPanel = .tracks
            session.requestedTrackGroup = nil
        }

        if let group = session.requestedPlaybackGroup {
            session.activePlaybackGroup = group
            selectedPanel = .playback
            session.requestedPlaybackGroup = nil
        }
    }

    private var topBar: some View {
        VStack(spacing: 18) {
            Text(platformShellString("Playback Options"))
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(.white.opacity(0.96))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .center)

            segmentedTabs
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity)
    }

    private var segmentedTabs: some View {
        HStack(spacing: 6) {
            ForEach(panels) { panel in
                Button(action: {
                    selectPanel(panel)
                }) {
                    TVPlaybackDrawerTabButton(
                        panel: panel,
                        isSelected: panel == selectedPanel,
                        onFocused: {
                            guard !isShowingSubmenu else { return }
                            selectPanel(panel)
                        }
                    )
                }
                .buttonStyle(TVPlaybackPlainButtonStyle())
                .focused($focusedTarget, equals: .tab(panel))
                .tvPlaybackPrefersDefaultFocusIfAvailable(!isShowingSubmenu && panel == selectedPanel, in: drawerFocusNamespace)
                .tvPlaybackDisableSystemFocusEffectIfAvailable()
            }
        }
        .padding(4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .frame(maxWidth: 900)
    }

    @ViewBuilder
    private var panelContent: some View {
        switch selectedPanel {
        case .tracks:
            trackRows
        case .playback:
            playbackRows
        case .picture:
            pictureRows
        case .info:
            infoRows
        }
    }

    @ViewBuilder
    private var trackRows: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let group = session.activeTrackGroup,
               availableTrackGroups.contains(group) {
                trackSubmenuRows(for: group)
            } else {
                trackCategoryRows
            }
        }
    }

    private var trackCategoryRows: some View {
        TVPlaybackOptionSection(title: platformShellString("Audio & Subtitles"), showsTitle: false) {
            ForEach(availableTrackGroups) { group in
                Button(action: { session.activeTrackGroup = group }) {
                    TVPlaybackNavigationRow(
                        title: title(for: group),
                        subtitle: subtitle(for: group),
                        systemImageName: group.systemImageName
                    )
                }
                .buttonStyle(TVPlaybackPlainButtonStyle())
                .focused($focusedTarget, equals: .content)
                .tvPlaybackDisableSystemFocusEffectIfAvailable()
            }
        }
    }

    @ViewBuilder
    private func trackSubmenuRows(for group: TVPlaybackTrackGroup) -> some View {
        Button(action: { session.activeTrackGroup = nil }) {
            TVPlaybackNavigationRow(
                title: platformShellString("Back"),
                subtitle: title(for: group),
                systemImageName: "chevron.left",
                trailingSystemImageName: nil
            )
        }
        .buttonStyle(TVPlaybackPlainButtonStyle())
        .focused($focusedTarget, equals: .submenuBack)
        .tvPlaybackPrefersDefaultFocusIfAvailable(true, in: drawerFocusNamespace)
        .onAppear { requestDrawerFocus() }
        .tvPlaybackDisableSystemFocusEffectIfAvailable()

        TVPlaybackOptionSection(title: title(for: group)) {
            switch group {
            case .audio:
                audioTrackRows
            case .primarySubtitle:
                primarySubtitleRows
            case .secondarySubtitle:
                secondarySubtitleRows
            case .secondarySubtitlePosition:
                secondarySubtitlePositionRows
            }
        }
    }

    private var audioTrackRows: some View {
        ForEach(session.audioTracks) { track in
            Button(action: { session.selectAudioTrack(track.id, closesPanel: false) }) {
                TVPlaybackTrackRow(
                    title: track.name,
                    isSelected: session.currentAudioTrackID == track.id
                )
            }
            .buttonStyle(TVPlaybackPlainButtonStyle())
            .focused($focusedTarget, equals: .audio(track.id))
            .tvPlaybackDisableSystemFocusEffectIfAvailable()
        }
    }

    private var primarySubtitleRows: some View {
        Group {
            Button(action: { session.selectSubtitleTrack(-1, closesPanel: false) }) {
                TVPlaybackTrackRow(
                    title: platformShellString("Off"),
                    isSelected: session.currentSubtitleTrackID == -1
                )
            }
            .buttonStyle(TVPlaybackPlainButtonStyle())
            .focused($focusedTarget, equals: .primarySubtitle(-1))
            .tvPlaybackDisableSystemFocusEffectIfAvailable()

            ForEach(session.subtitleTracks) { track in
                Button(action: { session.selectSubtitleTrack(track.id, closesPanel: false) }) {
                    TVPlaybackTrackRow(
                        title: track.name,
                        isSelected: session.currentSubtitleTrackID == track.id
                    )
                }
                .buttonStyle(TVPlaybackPlainButtonStyle())
                .focused($focusedTarget, equals: .primarySubtitle(track.id))
                .tvPlaybackDisableSystemFocusEffectIfAvailable()
            }
        }
    }

    private var secondarySubtitleRows: some View {
        Group {
            Button(action: { session.selectSecondarySubtitleTrack(nil, closesPanel: false) }) {
                TVPlaybackTrackRow(
                    title: platformShellString("Off"),
                    isSelected: session.currentSecondarySubtitleTrackID == nil
                )
            }
            .buttonStyle(TVPlaybackPlainButtonStyle())
            .focused($focusedTarget, equals: .secondarySubtitle(nil))
            .tvPlaybackDisableSystemFocusEffectIfAvailable()

            if session.secondarySubtitleTracks.isEmpty {
                TVPlaybackTrackRow(
                    title: platformShellString("No Subtitle Tracks"),
                    isSelected: false
                )
                .disabled(true)
            } else {
                ForEach(session.secondarySubtitleTracks) { track in
                    Button(action: { session.selectSecondarySubtitleTrack(track.id, closesPanel: false) }) {
                        TVPlaybackTrackRow(
                            title: session.secondarySubtitleDisplayTitle(for: track),
                            subtitle: session.secondarySubtitleDetailText(for: track),
                            isSelected: session.currentSecondarySubtitleTrackID == track.id
                        )
                    }
                    .buttonStyle(TVPlaybackPlainButtonStyle())
                    .focused($focusedTarget, equals: .secondarySubtitle(track.id))
                    .tvPlaybackDisableSystemFocusEffectIfAvailable()
                    .disabled(!session.canSelectSecondarySubtitle(track))
                }
            }
        }
    }

    private var secondarySubtitlePositionRows: some View {
        Group {
            Button(action: { session.startDirectPositionAdjustment() }) {
                TVPlaybackNavigationRow(
                    title: platformShellString("Adjust Position"),
                    subtitle: session.isNativeBitmapSecondarySubtitle ? platformShellString("MPV.BitmapPositionHint") : "\(Int(round(session.currentSecondarySubtitleVerticalPositionRatio() * 100)))%",
                    systemImageName: "arrow.up.and.down",
                    trailingSystemImageName: "chevron.right"
                )
            }
            .buttonStyle(TVPlaybackPlainButtonStyle())
            .focused($focusedTarget, equals: .content)
            .tvPlaybackDisableSystemFocusEffectIfAvailable()
            .disabled(!session.canAdjustSecondarySubtitlePosition)

            Button(action: { session.resetSecondarySubtitlePosition() }) {
                TVPlaybackNavigationRow(
                    title: platformShellString("Reset Position"),
                    subtitle: nil,
                    systemImageName: "arrow.counterclockwise",
                    trailingSystemImageName: nil
                )
            }
            .buttonStyle(TVPlaybackPlainButtonStyle())
            .focused($focusedTarget, equals: .content)
            .tvPlaybackDisableSystemFocusEffectIfAvailable()
            .disabled(!session.canAdjustSecondarySubtitlePosition)
        }
    }

    private func title(for group: TVPlaybackTrackGroup) -> String {
        switch group {
        case .audio:
            return platformShellString("Audio")
        case .primarySubtitle:
            return platformShellString(session.isSecondarySubtitlesEnabled ? "Primary" : "Subtitles")
        case .secondarySubtitle:
            return platformShellString("Secondary")
        case .secondarySubtitlePosition:
            return platformShellString("Secondary Subtitle Position")
        }
    }

    private func subtitle(for group: TVPlaybackTrackGroup) -> String? {
        switch group {
        case .audio:
            return session.audioTracks.first(where: { $0.id == session.currentAudioTrackID })?.name
        case .primarySubtitle:
            if session.currentSubtitleTrackID == -1 {
                return platformShellString("Off")
            }
            return session.subtitleTracks.first(where: { $0.id == session.currentSubtitleTrackID })?.name
        case .secondarySubtitle:
            guard let selectedID = session.currentSecondarySubtitleTrackID else {
                return platformShellString("Off")
            }
            return session.secondarySubtitleTracks
                .first(where: { $0.id == selectedID })
                .map { session.secondarySubtitleDisplayTitle(for: $0) }
        case .secondarySubtitlePosition:
            return session.secondarySubtitlePositionSummary
        }
    }

    private var playbackRows: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let group = session.activePlaybackGroup,
               availablePlaybackGroups.contains(group) {
                playbackSubmenuRows(for: group)
            } else {
                playbackCategoryRows
            }
        }
    }

    private var playbackCategoryRows: some View {
        TVPlaybackOptionSection(title: platformShellString("Playback Tuning"), showsTitle: false) {
            if !session.isAudioPlayback {
                Button(action: {
                    session.setSecondarySubtitlesEnabled(!session.isSecondarySubtitlesPreferenceEnabled)
                }) {
                    TVPlaybackToggleRow(
                        title: platformShellString("Secondary Subtitles"),
                        systemImageName: "captions.bubble.fill",
                        isOn: session.isSecondarySubtitlesPreferenceEnabled
                    )
                }
                .buttonStyle(TVPlaybackPlainButtonStyle())
                .focused($focusedTarget, equals: .content)
                .tvPlaybackDisableSystemFocusEffectIfAvailable()
            }

            ForEach(availablePlaybackGroups) { group in
                Button(action: { session.activePlaybackGroup = group }) {
                    TVPlaybackNavigationRow(
                        title: title(for: group),
                        subtitle: subtitle(for: group),
                        systemImageName: group.systemImageName,
                        usesInlineValue: true
                    )
                }
                .buttonStyle(TVPlaybackPlainButtonStyle())
                .focused($focusedTarget, equals: .content)
                .tvPlaybackDisableSystemFocusEffectIfAvailable()
            }
        }
    }

    @ViewBuilder
    private func playbackSubmenuRows(for group: TVPlaybackPlaybackGroup) -> some View {
        Button(action: { session.activePlaybackGroup = nil }) {
            TVPlaybackNavigationRow(
                title: platformShellString("Back"),
                subtitle: title(for: group),
                systemImageName: "chevron.left",
                trailingSystemImageName: nil
            )
        }
        .buttonStyle(TVPlaybackPlainButtonStyle())
        .focused($focusedTarget, equals: .submenuBack)
        .tvPlaybackPrefersDefaultFocusIfAvailable(true, in: drawerFocusNamespace)
        .onAppear { requestDrawerFocus() }
        .tvPlaybackDisableSystemFocusEffectIfAvailable()

        TVPlaybackOptionSection(title: title(for: group)) {
            switch group {
            case .engine:
                engineRows
            case .speed:
                speedRows
            case .videoDecoder:
                videoDecoderRows
            case .audioDelay:
                delayRows(selectedValue: session.audioDelay) { value in
                    session.setAudioDelay(value)
                }
            case .subtitleDelay:
                delayRows(selectedValue: session.subtitleDelay) { value in
                    session.setSubtitleDelay(value)
                }
            }
        }
    }

    private var engineRows: some View {
        ForEach(["mpv", "vlc"], id: \.self) { engine in
            Button(action: { session.switchEngine(engine) }) {
                TVPlaybackTrackRow(
                    title: engine == "mpv" ? "mpv" : "VLC",
                    isSelected: (engine == "mpv") == session.isUsingMPV)
            }
            .buttonStyle(TVPlaybackPlainButtonStyle())
            .focused($focusedTarget, equals: .engine(engine))
            .tvPlaybackDisableSystemFocusEffectIfAvailable()
            .disabled(!session.canSwitchEngine)
        }
    }

    private var speedRows: some View {
        ForEach(session.availablePlaybackRates, id: \.self) { rate in
            let title = "\(String(format: "%g", rate))x"
            Button(action: { session.setPlaybackRate(rate) }) {
                TVPlaybackTrackRow(
                    title: title,
                    isSelected: abs(session.playbackRate - rate) < 0.01
                )
            }
            .buttonStyle(TVPlaybackPlainButtonStyle())
            .focused($focusedTarget, equals: .content)
            .tvPlaybackDisableSystemFocusEffectIfAvailable()
        }
    }

    private var videoDecoderRows: some View {
        ForEach(TVPlaybackVideoDecoder.allCases) { decoder in
            Button(action: { session.setDecoder(decoder) }) {
                TVPlaybackTrackRow(
                    title: decoder.localizedName,
                    subtitle: session.decoderDetailText(for: decoder),
                    isSelected: session.currentDecoder == decoder
                )
            }
            .buttonStyle(TVPlaybackPlainButtonStyle())
            .focused($focusedTarget, equals: .content)
            .tvPlaybackDisableSystemFocusEffectIfAvailable()
        }
    }

    private func title(for group: TVPlaybackPlaybackGroup) -> String {
        switch group {
        case .engine:
            return platformShellString("MPV.Engine")
        case .speed:
            return platformShellString("Speed")
        case .videoDecoder:
            return platformShellString("Video Decoder")
        case .audioDelay:
            return platformShellString("Audio Delay")
        case .subtitleDelay:
            return platformShellString("Subtitle Delay")
        }
    }

    private func subtitle(for group: TVPlaybackPlaybackGroup) -> String? {
        switch group {
        case .engine:
            return session.isUsingMPV ? "mpv" : "VLC"
        case .speed:
            return "\(String(format: "%g", session.playbackRate))x"
        case .videoDecoder:
            return session.currentDecoder.localizedName
        case .audioDelay:
            return tvPlaybackDelayLabel(for: session.audioDelay)
        case .subtitleDelay:
            return tvPlaybackDelayLabel(for: session.subtitleDelay)
        }
    }

    @ViewBuilder
    private var pictureRows: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let group = session.activePictureGroup,
               availablePictureGroups.contains(group) {
                pictureSubmenuRows(for: group)
            } else {
                pictureCategoryRows
            }
        }
    }

    private var pictureCategoryRows: some View {
        TVPlaybackOptionSection(title: platformShellString("Display"), showsTitle: false) {
            ForEach(availablePictureGroups) { group in
                Button(action: { session.activePictureGroup = group }) {
                    TVPlaybackNavigationRow(
                        title: title(for: group),
                        subtitle: subtitle(for: group),
                        systemImageName: group.systemImageName,
                        usesInlineValue: true
                    )
                }
                .buttonStyle(TVPlaybackPlainButtonStyle())
                .focused($focusedTarget, equals: .content)
                .tvPlaybackDisableSystemFocusEffectIfAvailable()
            }
        }
    }

    @ViewBuilder
    private func pictureSubmenuRows(for group: TVPlaybackPictureGroup) -> some View {
        Button(action: { session.activePictureGroup = nil }) {
            TVPlaybackNavigationRow(
                title: platformShellString("Back"),
                subtitle: title(for: group),
                systemImageName: "chevron.left",
                trailingSystemImageName: nil
            )
        }
        .buttonStyle(TVPlaybackPlainButtonStyle())
        .focused($focusedTarget, equals: .submenuBack)
        .tvPlaybackPrefersDefaultFocusIfAvailable(true, in: drawerFocusNamespace)
        .onAppear { requestDrawerFocus() }
        .tvPlaybackDisableSystemFocusEffectIfAvailable()

        TVPlaybackOptionSection(title: title(for: group)) {
            switch group {
            case .playbackQuality:
                playbackQualityRows
            case .screenMode:
                ForEach(VideoDisplayMode.allCases, id: \.rawValue) { mode in
                    Button(action: { session.setVideoDisplayMode(mode) }) {
                        TVPlaybackTrackRow(
                            title: mode.tvLocalizedTitle,
                            isSelected: session.videoDisplayMode == mode
                        )
                    }
                    .buttonStyle(TVPlaybackPlainButtonStyle())
                    .focused($focusedTarget, equals: .content)
                    .tvPlaybackDisableSystemFocusEffectIfAvailable()
                }
            case .aspectRatio:
                ForEach(tvAvailableAspectRatios, id: \.self) { ratio in
                    let title = ratio.isEmpty ? platformShellString("Auto") : ratio
                    Button(action: { session.setAspectRatio(ratio) }) {
                        TVPlaybackTrackRow(
                            title: title,
                            isSelected: session.aspectRatio == ratio
                        )
                    }
                    .buttonStyle(TVPlaybackPlainButtonStyle())
                    .focused($focusedTarget, equals: .content)
                    .tvPlaybackDisableSystemFocusEffectIfAvailable()
                }
            }
        }
    }

    private var playbackQualityRows: some View {
        ForEach(session.playbackQualityOptions) { option in
            Button(action: { session.selectPlaybackQuality(option.id) }) {
                TVPlaybackTrackRow(
                    title: tvPlaybackQualityTitle(for: option),
                    subtitle: tvPlaybackQualitySubtitle(for: option),
                    isSelected: session.selectedPlaybackQualityID == option.id
                )
            }
            .buttonStyle(TVPlaybackPlainButtonStyle())
            .focused($focusedTarget, equals: .content)
            .tvPlaybackDisableSystemFocusEffectIfAvailable()
        }
    }

    private func title(for group: TVPlaybackPictureGroup) -> String {
        switch group {
        case .playbackQuality:
            return platformShellString("Playback Quality")
        case .screenMode:
            return platformShellString("Screen Mode")
        case .aspectRatio:
            return platformShellString("Aspect Ratio")
        }
    }

    private func subtitle(for group: TVPlaybackPictureGroup) -> String? {
        switch group {
        case .playbackQuality:
            return tvPlaybackQualityTitle(for: RemotePlaybackQualityOption.option(for: session.selectedPlaybackQualityID))
        case .screenMode:
            return session.videoDisplayMode.tvLocalizedTitle
        case .aspectRatio:
            return session.aspectRatio.isEmpty ? platformShellString("Auto") : session.aspectRatio
        }
    }

    @ViewBuilder
    private var infoRows: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let section = activeInfoSection {
                Button(action: { session.activeInfoSectionID = nil }) {
                    TVPlaybackNavigationRow(
                        title: platformShellString("Back"),
                        subtitle: section.title,
                        systemImageName: "chevron.left",
                        trailingSystemImageName: nil
                    )
                }
                .buttonStyle(TVPlaybackPlainButtonStyle())
                .focused($focusedTarget, equals: .submenuBack)
                .tvPlaybackPrefersDefaultFocusIfAvailable(true, in: drawerFocusNamespace)
                .onAppear { requestDrawerFocus() }
                .tvPlaybackDisableSystemFocusEffectIfAvailable()

                TVPlaybackInfoSection(section: section, focusedTarget: $focusedTarget)
            } else {
                let sections = session.mediaInfoSections
                if sections.count == 1, let section = sections.first {
                    TVPlaybackInfoSection(section: section, focusedTarget: $focusedTarget)
                } else {
                    TVPlaybackOptionSection(title: platformShellString("Details"), showsTitle: false) {
                        ForEach(sections) { section in
                            Button(action: { session.activeInfoSectionID = section.id }) {
                                TVPlaybackNavigationRow(
                                    title: section.title,
                                    subtitle: subtitle(for: section),
                                    systemImageName: section.icon
                                )
                            }
                            .buttonStyle(TVPlaybackPlainButtonStyle())
                            .focused($focusedTarget, equals: .content)
                            .tvPlaybackDisableSystemFocusEffectIfAvailable()
                        }
                    }
                }
            }
        }
    }

    private var activeInfoSection: TVPlaybackMediaInfoSection? {
        guard let activeInfoSectionID = session.activeInfoSectionID else { return nil }
        return session.mediaInfoSections.first { $0.id == activeInfoSectionID }
    }

    private func subtitle(for section: TVPlaybackMediaInfoSection) -> String? {
        guard let firstItem = section.items.first else { return nil }
        return "\(firstItem.key): \(firstItem.value)"
    }

    private func delayRows(
        selectedValue: Double,
        onSelect: @escaping (Double) -> Void
    ) -> some View {
        ForEach(tvPlaybackDelayValues, id: \.self) { value in
            let title = tvPlaybackDelayLabel(for: value)
            Button(action: { onSelect(value) }) {
                TVPlaybackTrackRow(
                    title: title,
                    isSelected: abs(selectedValue - value) < 0.001
                )
            }
            .buttonStyle(TVPlaybackPlainButtonStyle())
            .focused($focusedTarget, equals: .content)
            .tvPlaybackDisableSystemFocusEffectIfAvailable()
        }
    }

    private func requestDrawerFocus() {
        #if os(tvOS)
        let requestID = UUID()
        let page = contentIdentity
        pendingFocusRequestID = requestID
        DispatchQueue.main.async {
            guard pendingFocusRequestID == requestID, contentIdentity == page,
                  session.activePanel != nil else { return }
            resetFocus(in: drawerFocusNamespace)
            focusedTarget = isShowingSubmenu ? .submenuBack : .tab(selectedPanel)
            pendingFocusRequestID = nil
        }
        #endif
    }
}

private struct TVPlaybackStatusCapsule: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(.white.opacity(0.72))
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.09))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )
    }
}

private struct TVPlaybackDownloadedStatusIcon: View {
    var size: CGFloat = 18

    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(Color(red: 0.42, green: 0.88, blue: 0.58))
            .shadow(color: Color.black.opacity(0.28), radius: 8, x: 0, y: 4)
    }
}

private struct TVPlaybackRoundControl: View {
    let title: String
    let systemImageName: String
    let size: CGFloat
    let iconSize: CGFloat
    var isPrimary: Bool = false

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var foregroundColor: Color {
        guard isEnabled else { return .white.opacity(0.28) }
        return isFocused ? .black : .white
    }

    private var fillColor: Color {
        guard isEnabled else { return Color.white.opacity(0.055) }
        return isFocused ? Color.white : Color.white.opacity(isPrimary ? 0.28 : 0.13)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(fillColor)

            Image(systemName: systemImageName)
                .font(.system(size: iconSize, weight: isPrimary ? .bold : .semibold))
                .foregroundColor(foregroundColor)
        }
        .frame(width: size, height: size)
        .overlay(
            Circle()
                .stroke(Color.white.opacity(isEnabled ? (isFocused ? 0.96 : 0.14) : 0.055), lineWidth: isFocused && isEnabled ? 3 : 1)
        )
        .shadow(color: isFocused && isEnabled ? Color.white.opacity(0.18) : Color.black.opacity(isEnabled ? 0.20 : 0.06), radius: isFocused && isEnabled ? 13 : 8, x: 0, y: isFocused && isEnabled ? 0 : 5)
        .scaleEffect(isFocused && isEnabled ? 1.065 : 1.0)
        .opacity(isEnabled ? 1 : 0.62)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeOut(duration: 0.15), value: isEnabled)
        .accessibilityLabel(Text(title))
    }
}

private struct TVPlaybackIconActionControl: View {
    let title: String
    let systemImageName: String
    var isActive: Bool = false
    var onFocusChanged: ((Bool) -> Void)? = nil

    @Environment(\.isFocused) private var isFocused

    private var foregroundColor: Color {
        isFocused ? .black : .white
    }

    private var fillOpacity: Double {
        if isFocused { return 0.96 }
        return isActive ? 0.24 : 0.115
    }

    private var strokeOpacity: Double {
        if isFocused { return 0.98 }
        return isActive ? 0.34 : 0.13
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(fillOpacity))

            Image(systemName: systemImageName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(foregroundColor)
        }
        .frame(width: 48, height: 48)
        .overlay(
            Circle()
                .stroke(Color.white.opacity(strokeOpacity), lineWidth: isFocused ? 3 : 1)
        )
        .shadow(color: isFocused ? Color.white.opacity(0.17) : Color.black.opacity(0.18), radius: isFocused ? 13 : 7, x: 0, y: isFocused ? 0 : 4)
        .scaleEffect(isFocused ? 1.055 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeOut(duration: 0.15), value: isActive)
        .onChange(of: isFocused) { focused in
            onFocusChanged?(focused)
        }
        .accessibilityLabel(Text(title))
    }
}

private struct TVPlaybackPillControl: View {
    let title: String
    let systemImageName: String
    var isActive: Bool = false

    @Environment(\.isFocused) private var isFocused

    private var foregroundColor: Color {
        isFocused ? .black : .white
    }

    private var fillOpacity: Double {
        if isFocused { return 0.96 }
        return isActive ? 0.22 : 0.12
    }

    private var strokeOpacity: Double {
        if isFocused { return 0.96 }
        return isActive ? 0.34 : 0.14
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImageName)
                .font(.system(size: 17, weight: .semibold))
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundColor(foregroundColor)
        .padding(.horizontal, 17)
        .frame(height: 48)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(fillOpacity))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(strokeOpacity), lineWidth: isFocused ? 3 : 1)
        )
        .shadow(color: isFocused ? Color.white.opacity(0.16) : Color.black.opacity(0.18), radius: isFocused ? 12 : 7, x: 0, y: isFocused ? 0 : 4)
        .scaleEffect(isFocused ? 1.04 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .accessibilityLabel(Text(title))
    }
}

private struct TVPlaybackPlaylistRow: View {
    let item: TVPlaybackPlaylistItem
    @Environment(\.isFocused) private var isFocused

    private var showsFocus: Bool {
        isFocused
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .topLeading) {
                TVPlaybackPlaylistArtworkView(
                    url: item.artworkURL,
                    type: item.type
                )

                Text(String(format: "%02d", item.index + 1))
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.88))
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.56))
                    )
                    .padding(8)
            }
            .frame(width: 116, height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(item.title)
                    .font(.system(size: 22, weight: item.isCurrent ? .bold : .semibold))
                    .foregroundColor(showsFocus ? .black.opacity(0.90) : .white.opacity(0.98))
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 10) {
                    if item.progress > 0 {
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(showsFocus ? Color.black.opacity(0.12) : Color.white.opacity(0.16))
                                    .frame(height: 4)
                                Capsule()
                                    .fill(showsFocus ? Color.black.opacity(0.56) : Color.white.opacity(item.isCurrent ? 0.88 : 0.48))
                                    .frame(width: geometry.size.width * CGFloat(item.progress), height: 4)
                            }
                        }
                        .frame(width: 86, height: 4)
                    }

                    if let progressText = item.progressText {
                        Text(progressText)
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundColor(showsFocus ? .black.opacity(0.60) : .white.opacity(0.58))
                            .lineLimit(1)
                    }
                }

                if let metadataText = item.metadataText, !metadataText.isEmpty {
                    Text(metadataText)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(showsFocus ? .black.opacity(0.50) : .white.opacity(0.46))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if item.isCurrent {
                Image(systemName: "waveform")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(showsFocus ? .black.opacity(0.76) : .white.opacity(0.92))
                    .frame(width: 32)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(showsFocus ? .black.opacity(0.50) : .white.opacity(0.34))
                    .frame(width: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(showsFocus ? Color.white.opacity(0.94) : Color.white.opacity(item.isCurrent ? 0.14 : 0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(showsFocus ? 0.96 : (item.isCurrent ? 0.18 : 0.08)), lineWidth: showsFocus ? 2.5 : 1)
        )
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeOut(duration: 0.15), value: item.progress)
    }
}

private struct TVPlaybackPlaylistArtworkView: View {
    let url: URL?
    let type: VideoFile.FileType
    @State private var image: UIImage?
    @State private var loadToken: UUID?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.16),
                            Color.white.opacity(0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Image(systemName: placeholderSystemImageName)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(.white.opacity(0.66))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .onAppear(perform: loadImage)
        .onChange(of: url) { _ in loadImage() }
    }

    private var placeholderSystemImageName: String {
        switch type {
        case .audio:
            return "music.note"
        case .image:
            return "photo"
        case .folder:
            return "folder.fill"
        case .subtitle:
            return "captions.bubble"
        case .document:
            return "doc.text"
        case .video, .unknown:
            return "play.rectangle.fill"
        }
    }

    private func loadImage() {
        image = nil
        guard let url else {
            loadToken = nil
            return
        }

        let token = UUID()
        loadToken = token

        if url.isFileURL {
            guard type == .image,
                  let loadedImage = UIImage(contentsOfFile: url.path) else {
                return
            }
            image = loadedImage
            return
        }

        var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
        request.timeoutInterval = 18
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let data,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  let loadedImage = UIImage(data: data) else {
                return
            }
            DispatchQueue.main.async {
                guard loadToken == token else { return }
                image = loadedImage
            }
        }.resume()
    }
}

private struct TVPlaybackDrawerTabButton: View {
    let panel: TVPlaybackSession.Panel
    let isSelected: Bool
    let onFocused: () -> Void

    @Environment(\.isFocused) private var isFocused

    private var primaryColor: Color {
        isFocused ? .black.opacity(0.9) : .white.opacity(isSelected ? 0.96 : 0.62)
    }

    private var fillColor: Color {
        if isFocused {
            return Color.white.opacity(0.92)
        }
        if isSelected {
            return Color.white.opacity(0.14)
        }
        return Color.clear
    }

    private var strokeOpacity: Double {
        if isFocused { return 0.92 }
        return isSelected ? 0.16 : 0.0
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: panel.systemImageName)
                .font(.system(size: 16, weight: .semibold))

            Text(panel.title)
                .font(.system(size: 18, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .foregroundColor(primaryColor)
        .padding(.horizontal, 14)
        .frame(height: 52)
        .frame(maxWidth: .infinity)
        .contentShape(Capsule(style: .continuous))
        .background(
            Capsule(style: .continuous)
                .fill(fillColor)
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(strokeOpacity), lineWidth: isFocused ? 2 : 1)
        )
        .scaleEffect(isFocused ? 1.015 : 1.0)
        .animation(.easeOut(duration: 0.14), value: isFocused)
        .animation(.easeOut(duration: 0.14), value: isSelected)
        .onChange(of: isFocused) { focused in
            guard focused else { return }
            onFocused()
        }
        .accessibilityLabel(Text(panel.title))
    }
}

private struct TVPlaybackOptionSection<Content: View>: View {
    let title: String
    let showsTitle: Bool
    let content: () -> Content

    init(title: String, showsTitle: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.showsTitle = showsTitle
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsTitle {
                Text(title)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(.white.opacity(0.64))
                    .lineLimit(1)
                    .padding(.horizontal, 20)
            }
            VStack(alignment: .leading, spacing: 6) { content() }
        }
    }
}

private struct TVPlaybackNavigationRow: View {
    let title: String
    var subtitle: String? = nil
    let systemImageName: String
    var usesInlineValue = false
    var trailingSystemImageName: String? = "chevron.right"

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImageName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(showsFocus ? .black.opacity(0.82) : .white.opacity(isEnabled ? 0.82 : 0.34))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(showsFocus ? .black.opacity(0.9) : .white.opacity(isEnabled ? 0.98 : 0.42))
                    .lineLimit(1)

                if !usesInlineValue, let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(showsFocus ? .black.opacity(0.58) : .white.opacity(isEnabled ? 0.58 : 0.32))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if usesInlineValue, let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(showsFocus ? .black.opacity(0.60) : .white.opacity(0.66))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 260, alignment: .trailing)
            }

            if let trailingSystemImageName {
                Image(systemName: trailingSystemImageName)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(showsFocus ? .black.opacity(0.58) : .white.opacity(isEnabled ? 0.42 : 0.20))
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(minHeight: 76)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(showsFocus ? Color.white.opacity(0.94) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(showsFocus ? 0.8 : 0), lineWidth: 1)
        )
        .scaleEffect(showsFocus ? 1.008 : 1.0)
        .shadow(color: Color.black.opacity(showsFocus ? 0.12 : 0), radius: 8, x: 0, y: 3)
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .animation(.easeOut(duration: 0.15), value: isEnabled)
    }
}

private struct TVPlaybackToggleRow: View {
    let title: String
    var subtitle: String? = nil
    let systemImageName: String
    let isOn: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImageName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(showsFocus ? .black.opacity(0.82) : .white.opacity(isEnabled ? 0.82 : 0.34))
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(showsFocus ? .black.opacity(0.9) : .white.opacity(isEnabled ? 0.98 : 0.42))
                    .lineLimit(1)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(showsFocus ? .black.opacity(0.58) : .white.opacity(isEnabled ? 0.58 : 0.32))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 7) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .bold))
                Text(platformShellString(isOn ? "On" : "Off"))
                    .font(.system(size: 16, weight: .bold))
                    .lineLimit(1)
            }
            .foregroundColor(showsFocus ? .black.opacity(0.82) : .white.opacity(isEnabled ? 0.82 : 0.34))
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(
                Capsule(style: .continuous)
                    .fill(showsFocus ? Color.black.opacity(0.08) : Color.white.opacity(isOn ? 0.16 : 0.07))
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(minHeight: 76)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(showsFocus ? Color.white.opacity(0.94) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(showsFocus ? 0.8 : 0), lineWidth: 1)
        )
        .scaleEffect(showsFocus ? 1.008 : 1.0)
        .shadow(color: Color.black.opacity(showsFocus ? 0.12 : 0), radius: 8, x: 0, y: 3)
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .animation(.easeOut(duration: 0.15), value: isEnabled)
        .animation(.easeOut(duration: 0.15), value: isOn)
    }
}

private struct TVPlaybackInfoSection: View {
    let section: TVPlaybackMediaInfoSection
    @FocusState.Binding var focusedTarget: TVPlaybackFocusTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: section.icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white.opacity(0.76))

                Text(section.title)
                    .font(.system(size: 17, weight: .bold))
                    .foregroundColor(.white.opacity(0.82))
                    .lineLimit(1)
            }
            .padding(.horizontal, 4)

            VStack(spacing: 0) {
                ForEach(section.items.indices, id: \.self) { index in
                    Button(action: {}) {
                        TVPlaybackInfoRow(
                            key: section.items[index].key,
                            value: section.items[index].value,
                            showsDivider: index < section.items.count - 1
                        )
                    }
                    .buttonStyle(TVPlaybackPlainButtonStyle())
                    .focused($focusedTarget, equals: .content)
                    .tvPlaybackDisableSystemFocusEffectIfAvailable()
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
        }
    }
}

private struct TVPlaybackInfoRow: View {
    let key: String
    let value: String
    let showsDivider: Bool

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Text(key)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(isFocused ? .black.opacity(0.58) : .white.opacity(0.55))
                    .frame(width: 170, alignment: .leading)

                Text(value)
                    .font(.system(size: 17, weight: .medium, design: .monospaced))
                    .foregroundColor(isFocused ? .black.opacity(0.88) : .white.opacity(0.9))
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isFocused ? Color.white.opacity(0.94) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.white.opacity(isFocused ? 0.92 : 0.0), lineWidth: isFocused ? 2 : 0)
            )
            .scaleEffect(isFocused ? 1.015 : 1.0)
            .shadow(color: Color.black.opacity(isFocused ? 0.18 : 0), radius: 8, x: 0, y: 4)
            .animation(.easeOut(duration: 0.18), value: isFocused)

            if showsDivider {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
                    .padding(.leading, 18)
            }
        }
    }
}

private struct TVPlaybackTrackRow: View {
    let title: String
    var subtitle: String? = nil
    let isSelected: Bool
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(showsFocus ? .black.opacity(0.84) : (isSelected ? .white.opacity(isEnabled ? 1.0 : 0.38) : .white.opacity(isEnabled ? 0.48 : 0.24)))
                .frame(width: 30, height: 30, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 22, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(showsFocus ? .black.opacity(0.88) : .white.opacity(isEnabled ? 1.0 : 0.40))
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundColor(showsFocus ? .black.opacity(0.58) : .white.opacity(isEnabled ? 0.58 : 0.32))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 15)
        .frame(minHeight: 76)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(showsFocus ? Color.white.opacity(0.94) : Color.white.opacity(isEnabled && isSelected ? 0.06 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(showsFocus ? 0.8 : 0), lineWidth: 1)
        )
        .scaleEffect(showsFocus ? 1.008 : 1.0)
        .shadow(color: Color.black.opacity(showsFocus ? 0.12 : 0), radius: 8, x: 0, y: 3)
        .animation(.easeOut(duration: 0.18), value: isFocused)
        .animation(.easeOut(duration: 0.15), value: isEnabled)
    }
}

private struct TVPlaybackIconChip: View {
    let systemImageName: String

    var body: some View {
        Image(systemName: systemImageName)
            .font(.title3.weight(.semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 15)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.15))
            )
    }
}

private let tvAvailablePlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
private let tvAvailableAspectRatios: [String] = ["", "16:9", "4:3", "1:1", "16:10", "2.35:1"]
private let tvPlaybackDelayValues: [Double] = [-3.0, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 3.0]

private func tvPlaybackPlaylistMetadataText(for file: VideoFile) -> String? {
    var segments: [String] = []
    segments.append(platformShellString(file.type == .audio ? "Audio" : "Video"))

    if let resolution = tvPlaybackPlaylistResolutionText(for: file) {
        segments.append(resolution)
    }

    if let container = tvTrimmedPlaybackText(file.serverContainer ?? file.url.pathExtension) {
        segments.append(container.uppercased())
    }

    if let bitrate = file.serverBitrate, bitrate > 0 {
        segments.append(tvPlaybackBitrateText(bitrate))
    }

    return segments.isEmpty ? nil : segments.joined(separator: " · ")
}

private func tvPlaybackPlaylistResolutionText(for file: VideoFile) -> String? {
    guard let streams = file.serverMediaStreams else { return nil }
    guard let videoStream = streams.first(where: {
        (tvStreamString($0, "Type") ?? tvStreamString($0, "type")) == "Video"
    }) else {
        return nil
    }
    guard let width = tvStreamInt(videoStream, "Width") ?? tvStreamInt(videoStream, "width"),
          let height = tvStreamInt(videoStream, "Height") ?? tvStreamInt(videoStream, "height"),
          width > 0,
          height > 0 else {
        return nil
    }
    return "\(width)x\(height)"
}

private func tvPlaybackStoredArtworkURL(for file: VideoFile) -> URL? {
    if file.type == .image {
        return file.url
    }

    guard let server = tvPlaybackResolvedServer(for: file) else {
        return nil
    }

    switch server.type {
    case .jellyfin:
        if let seriesID = tvTrimmedPlaybackText(file.seriesId) {
            return tvPlaybackJellyfinImageURL(server: server, itemID: seriesID, imageType: "Primary", maxWidth: 700)
        }
        if let itemID = tvTrimmedPlaybackText(file.jellyfinItemId) {
            return tvPlaybackJellyfinImageURL(server: server, itemID: itemID, imageType: "Primary", maxWidth: 700)
        }
    case .emby:
        if let seriesID = tvTrimmedPlaybackText(file.seriesId) {
            return tvPlaybackEmbyImageURL(server: server, itemID: seriesID, imageType: "Primary", maxWidth: 700)
        }
        if let itemID = tvTrimmedPlaybackText(file.jellyfinItemId) {
            return tvPlaybackEmbyImageURL(server: server, itemID: itemID, imageType: "Primary", maxWidth: 700)
        }
    case .plex:
        return tvPlaybackPlexArtworkURL(server: server, itemID: tvTrimmedPlaybackText(file.seriesId) ?? tvTrimmedPlaybackText(file.jellyfinItemId))
    case .smb, .webdav, .alist, .pan115, .onedrive, .googledrive, .ftp, .sftp, .nfs:
        return file.type == .image ? file.url : nil
    case .iptv, .vod:
        return file.customArtworkURL
    }

    return nil
}

private func tvPlaybackCleanupTemporaryDownload(at fileURL: URL) {
    let containerURL = fileURL.deletingLastPathComponent()
    try? FileManager.default.removeItem(at: fileURL)
    try? FileManager.default.removeItem(at: containerURL)
}

private func tvPlaybackJellyfinImageURL(
    server: ServerConfig,
    itemID: String,
    imageType: String,
    maxWidth: Int
) -> URL? {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/Items/\(itemID)/Images/\(imageType)") else {
        return nil
    }

    var queryItems = [URLQueryItem(name: "maxWidth", value: String(maxWidth))]
    if let token = tvTrimmedPlaybackText(server.accessToken) {
        queryItems.append(URLQueryItem(name: "api_key", value: token))
    }
    components.queryItems = queryItems
    return components.url
}

private func tvPlaybackEmbyImageURL(
    server: ServerConfig,
    itemID: String,
    imageType: String,
    maxWidth: Int
) -> URL? {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/Items/\(itemID)/Images/\(imageType)") else {
        return nil
    }

    var queryItems = [URLQueryItem(name: "MaxWidth", value: String(maxWidth))]
    if let token = tvTrimmedPlaybackText(server.accessToken) {
        queryItems.append(URLQueryItem(name: "api_key", value: token))
    }
    components.queryItems = queryItems
    return components.url
}

private func tvPlaybackPlexArtworkURL(server: ServerConfig, itemID: String?) -> URL? {
    guard let itemID else { return nil }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/library/metadata/\(itemID)/thumb") else {
        return nil
    }

    if let token = tvTrimmedPlaybackText(server.accessToken) ?? tvTrimmedPlaybackText(server.passwordSecret) {
        components.queryItems = [URLQueryItem(name: "X-Plex-Token", value: token)]
    }
    return components.url
}

private func tvPlaybackDelayLabel(for value: Double) -> String {
    if abs(value) < 0.001 {
        return "0s"
    }
    let sign = value > 0 ? "+" : ""
    return "\(sign)\(String(format: "%.1f", value))s"
}

private func tvPlaybackQualityTitle(for option: RemotePlaybackQualityOption) -> String {
    switch option.preset {
    case .auto:
        return platformShellString("Auto")
    case .original:
        return platformShellString("Original")
    case .p1080, .p720, .p480:
        return option.title
    }
}

private func tvPlaybackQualitySubtitle(for option: RemotePlaybackQualityOption) -> String? {
    switch option.preset {
    case .auto:
        return platformShellString("Prefer smooth playback")
    case .original:
        return platformShellString("Prefer original quality")
    case .p1080:
        return platformShellString("Up to 1080p")
    case .p720:
        return platformShellString("Up to 720p")
    case .p480:
        return platformShellString("Up to 480p")
    }
}

private func tvVideoDisplayScale(
    containerSize: CGSize,
    naturalVideoSize: CGSize,
    aspectRatioOverride: String,
    displayMode: VideoDisplayMode
) -> CGFloat {
    guard displayMode == .fill,
          containerSize.width > 1,
          containerSize.height > 1,
          let aspectRatio = tvResolvedVideoAspectRatio(
            override: aspectRatioOverride,
            naturalSize: naturalVideoSize
          ) else {
        return 1.0
    }

    let fitRect = tvScaledVideoRect(
        containerSize: containerSize,
        aspectRatio: aspectRatio,
        usesFillScale: false
    )
    guard fitRect.width > 1, fitRect.height > 1 else { return 1.0 }

    let scale = max(containerSize.width / fitRect.width, containerSize.height / fitRect.height)
    guard scale.isFinite, scale > 1.0 else { return 1.0 }
    return scale
}

private func tvResolvedVideoAspectRatio(
    override aspectRatio: String,
    naturalSize: CGSize
) -> CGFloat? {
    if let forcedRatio = tvParsedAspectRatioValue(from: aspectRatio) {
        return forcedRatio
    }

    guard naturalSize.width > 0, naturalSize.height > 0 else {
        return nil
    }
    let naturalRatio = naturalSize.width / naturalSize.height
    guard naturalRatio.isFinite, naturalRatio > 0 else {
        return nil
    }
    return naturalRatio
}

private func tvParsedAspectRatioValue(from ratio: String) -> CGFloat? {
    let trimmed = ratio.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let parts = trimmed.split(separator: ":")
    guard parts.count == 2,
          let width = Double(parts[0]),
          let height = Double(parts[1]),
          height > 0 else {
        return nil
    }
    let value = width / height
    guard value.isFinite, value > 0 else { return nil }
    return CGFloat(value)
}

private func tvScaledVideoRect(
    containerSize: CGSize,
    aspectRatio: CGFloat,
    usesFillScale: Bool
) -> CGRect {
    guard containerSize.width > 0,
          containerSize.height > 0,
          aspectRatio.isFinite,
          aspectRatio > 0 else {
        return CGRect(origin: .zero, size: containerSize)
    }

    let containerAspect = containerSize.width / containerSize.height
    let shouldMatchWidth = usesFillScale ? (aspectRatio < containerAspect) : (aspectRatio > containerAspect)
    let videoWidth: CGFloat
    let videoHeight: CGFloat

    if shouldMatchWidth {
        videoWidth = containerSize.width
        videoHeight = videoWidth / aspectRatio
    } else {
        videoHeight = containerSize.height
        videoWidth = videoHeight * aspectRatio
    }

    return CGRect(
        x: (containerSize.width - videoWidth) / 2,
        y: (containerSize.height - videoHeight) / 2,
        width: videoWidth,
        height: videoHeight
    )
}

private func tvPlaybackAccentColor(for type: VideoFile.FileType) -> Color {
    switch type {
    case .audio:
        return Color(red: 0.96, green: 0.53, blue: 0.72)
    case .video:
        return Color(red: 0.66, green: 0.55, blue: 0.98)
    default:
        return Color(red: 0.44, green: 0.68, blue: 0.98)
    }
}

private func tvTracks(names: Any?, indexes: Any?, fallbackPrefix: String) -> [MediaTrack] {
    guard let names = names as? [String],
          let indexes = indexes as? [Int] else {
        return []
    }

    var tracks: [MediaTrack] = []
    var seen = Set<Int>()

    for (offset, trackID) in indexes.enumerated() {
        guard offset < names.count else { continue }
        guard seen.insert(trackID).inserted else { continue }
        guard trackID != -1 else { continue }

        let trimmedName = names[offset].trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmedName.isEmpty ? "\(fallbackPrefix) \(tracks.count + 1)" : trimmedName
        tracks.append(MediaTrack(id: trackID, name: name, isExternal: false))
    }

    return tracks
}

private struct TVStoredTrackQueryPreference {
    let audioQuery: String?
    let subtitleQuery: String?
    let subtitlesDisabled: Bool?
}

private func tvStoredSeriesTrackPreference(for file: VideoFile) -> (audio: Int?, subtitle: Int?)? {
    guard let provider = file.serverType?.rawValue,
          let serverId = tvTrimmedPlaybackText(file.jellyfinServerId),
          let seriesId = tvTrimmedPlaybackText(file.seriesId) else {
        return nil
    }

    let defaults = UserDefaults.standard
    let prefix = "seriesTrack.\(provider).\(serverId).\(seriesId)"
    return (
        defaults.object(forKey: "\(prefix).audio") as? Int,
        defaults.object(forKey: "\(prefix).subtitle") as? Int
    )
}

private func tvSaveSeriesTrackPreference(
    for file: VideoFile,
    audio: Int?,
    subtitle: Int?
) {
    guard let provider = file.serverType?.rawValue,
          let serverId = tvTrimmedPlaybackText(file.jellyfinServerId),
          let seriesId = tvTrimmedPlaybackText(file.seriesId) else {
        return
    }

    let defaults = UserDefaults.standard
    let prefix = "seriesTrack.\(provider).\(serverId).\(seriesId)"
    if let audio {
        defaults.set(audio, forKey: "\(prefix).audio")
    } else {
        defaults.removeObject(forKey: "\(prefix).audio")
    }
    if let subtitle {
        defaults.set(subtitle, forKey: "\(prefix).subtitle")
    } else {
        defaults.removeObject(forKey: "\(prefix).subtitle")
    }
}

private func tvStoredTrackQueryPreference(for file: VideoFile) -> TVStoredTrackQueryPreference {
    guard let prefix = tvTrackQueryPreferencePrefix(for: file) else {
        return TVStoredTrackQueryPreference(audioQuery: nil, subtitleQuery: nil, subtitlesDisabled: nil)
    }

    let defaults = UserDefaults.standard
    return TVStoredTrackQueryPreference(
        audioQuery: defaults.string(forKey: "\(prefix).audioQuery"),
        subtitleQuery: defaults.string(forKey: "\(prefix).subtitleQuery"),
        subtitlesDisabled: defaults.object(forKey: "\(prefix).subtitlesDisabled") as? Bool
    )
}

private func tvSaveTrackQueryPreference(
    for file: VideoFile,
    audioQuery: String?,
    subtitleQuery: String?,
    subtitlesDisabled: Bool
) {
    guard let prefix = tvTrackQueryPreferencePrefix(for: file) else { return }

    let defaults = UserDefaults.standard
    let audioKey = "\(prefix).audioQuery"
    let subtitleKey = "\(prefix).subtitleQuery"
    let disabledKey = "\(prefix).subtitlesDisabled"

    if let audioQuery = tvTrimmedPlaybackText(audioQuery) {
        defaults.set(audioQuery, forKey: audioKey)
    } else {
        defaults.removeObject(forKey: audioKey)
    }

    if !subtitlesDisabled, let subtitleQuery = tvTrimmedPlaybackText(subtitleQuery) {
        defaults.set(subtitleQuery, forKey: subtitleKey)
    } else {
        defaults.removeObject(forKey: subtitleKey)
    }

    defaults.set(subtitlesDisabled, forKey: disabledKey)
}

private func tvTrackQueryPreferencePrefix(for file: VideoFile) -> String? {
    guard let provider = file.serverType?.rawValue,
          let serverId = tvTrimmedPlaybackText(file.jellyfinServerId),
          let scopeKey = tvTrackQueryScopeKey(for: file) else {
        return nil
    }
    return "trackQuery.\(provider).\(serverId).\(scopeKey)"
}

private func tvTrackQueryScopeKey(for file: VideoFile) -> String? {
    if let seriesId = tvTrimmedPlaybackText(file.seriesId) {
        return "series.\(seriesId)"
    }
    if let itemId = tvTrimmedPlaybackText(file.jellyfinItemId) {
        return "item.\(itemId)"
    }
    return nil
}

private func tvApplyingServerTrackNames(
    _ tracks: [MediaTrack],
    type: String,
    external: Bool?,
    streams: [[String: Any]]?
) -> [MediaTrack] {
    let serverNames = tvServerTrackDisplayNames(type: type, external: external, streams: streams)
    let selectableIndices = tracks.indices.filter { index in
        tracks[index].id != -1 && (external == nil || tracks[index].isExternal == external)
    }

    guard !serverNames.isEmpty, selectableIndices.count == serverNames.count else {
        return tracks
    }

    var renamed = tracks
    for (offset, index) in selectableIndices.enumerated() {
        let displayName = serverNames[offset]
        guard !displayName.isEmpty else { continue }
        renamed[index] = MediaTrack(
            id: tracks[index].id,
            name: displayName,
            isExternal: tracks[index].isExternal
        )
    }
    return renamed
}

private func tvServerTrackDisplayNames(
    type: String,
    external: Bool?,
    streams: [[String: Any]]?
) -> [String] {
    guard let streams, !streams.isEmpty else { return [] }

    return streams.compactMap { stream in
        guard ((stream["Type"] as? String) ?? "") == type else { return nil }
        if let external, ((stream["IsExternal"] as? Bool) ?? false) != external {
            return nil
        }

        if type == "Subtitle" {
            return tvFormattedServerSubtitleTrackDisplayName(stream)
        }

        if let title = tvCleanedServerTrackMetadataValue(stream["DisplayTitle"] as? String), !title.isEmpty {
            return title
        }

        let language = tvCleanedServerTrackMetadataValue(stream["Language"] as? String)
        let codec = tvCleanedServerTrackMetadataValue(stream["Codec"] as? String)
        let channels = stream["Channels"] as? Int

        var parts: [String] = []
        if let language, !language.isEmpty { parts.append(language.uppercased()) }
        if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        if let channels, channels > 0, type == "Audio" { parts.append("\(channels)ch") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private func tvFormattedServerSubtitleTrackDisplayName(_ stream: [String: Any]) -> String? {
    let title = tvCleanedServerSubtitlePresentationMetadataValue(stream["DisplayTitle"] as? String)
    let alternateTitle = tvCleanedServerSubtitlePresentationMetadataValue(stream["Title"] as? String)
    let displayLanguage = tvCleanedServerSubtitleLanguageMetadataValue(stream["DisplayLanguage"] as? String)
    let language = tvCleanedServerSubtitleLanguageMetadataValue(stream["Language"] as? String)
    let codec = tvCleanedServerTrackMetadataValue(stream["Codec"] as? String)?.uppercased()
    let isDefault = stream["IsDefault"] as? Bool
    let isForced = stream["IsForced"] as? Bool
    let normalizedTitle = tvNormalizedServerTrackMetadataValue(title)

    var parts: [String] = []
    if let title,
       !title.isEmpty,
       !tvIsGenericServerSubtitleDisplayTitle(title, codec: codec) {
        parts.append(title)
    }

    if let alternateTitle,
       !alternateTitle.isEmpty,
       !normalizedTitle.contains(tvNormalizedServerTrackMetadataValue(alternateTitle)),
       !parts.contains(where: { tvNormalizedServerTrackMetadataValue($0) == tvNormalizedServerTrackMetadataValue(alternateTitle) }),
       !tvIsGenericServerSubtitleDisplayTitle(alternateTitle, codec: codec) {
        parts.append(alternateTitle)
    }

    if let displayLanguage,
       !displayLanguage.isEmpty,
       !normalizedTitle.contains(tvNormalizedServerTrackMetadataValue(displayLanguage)),
       !parts.contains(where: { tvNormalizedServerTrackMetadataValue($0) == tvNormalizedServerTrackMetadataValue(displayLanguage) }) {
        parts.append(displayLanguage)
    }

    if let language,
       !language.isEmpty,
       !normalizedTitle.contains(tvNormalizedServerTrackMetadataValue(language)),
       !parts.contains(where: { tvNormalizedServerTrackMetadataValue($0) == tvNormalizedServerTrackMetadataValue(language) }) {
        parts.append(language)
    }

    var flags: [String] = []
    if isDefault == true, !normalizedTitle.contains("default") {
        flags.append(platformShellString("Default"))
    }
    if isForced == true, !normalizedTitle.contains("forced") {
        flags.append(platformShellString("Forced"))
    }
    if !flags.isEmpty {
        parts.append(flags.joined(separator: " "))
    }

    if let codec,
       !codec.isEmpty,
       !normalizedTitle.contains(tvNormalizedServerTrackMetadataValue(codec)),
       !parts.contains(where: { tvNormalizedServerTrackMetadataValue($0) == tvNormalizedServerTrackMetadataValue(codec) }) {
        parts.append(codec)
    }

    if parts.isEmpty {
        return title ?? alternateTitle ?? displayLanguage ?? language ?? codec
    }
    return parts.joined(separator: " · ")
}

private func tvCleanedServerTrackMetadataValue(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
        return nil
    }
    return value
}

private func tvCleanedServerSubtitleLanguageMetadataValue(_ value: String?) -> String? {
    tvCleanedServerSubtitlePresentationMetadataValue(value)
}

private func tvCleanedServerSubtitlePresentationMetadataValue(_ value: String?) -> String? {
    guard let cleaned = tvCleanedServerTrackMetadataValue(value) else { return nil }

    let lowered = cleaned
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .lowercased()
    let placeholderValues: Set<String> = [
        "und", "undefined", "unknown", "undetermined", "n/a", "na", "none", "null",
        "未定义", "未指定", "未知", "不明", "未設定", "未設置"
    ]

    return placeholderValues.contains(lowered) ? nil : cleaned
}

private func tvIsGenericServerSubtitleDisplayTitle(_ title: String, codec: String?) -> Bool {
    var normalized = tvNormalizedServerTrackMetadataValue(title)
    if let codec, !codec.isEmpty {
        normalized = normalized.replacingOccurrences(of: tvNormalizedServerTrackMetadataValue(codec), with: "")
    }

    let genericTokens = ["default", "forced", "subtitle", "subtitles", "captions", "caption", "external", "internal"]
    genericTokens.forEach { token in
        normalized = normalized.replacingOccurrences(of: token, with: "")
    }
    return normalized.isEmpty
}

private func tvTrackName(_ trackName: String, matches query: String) -> Bool {
    let normalizedTrack = tvNormalizedTrackQuery(trackName)
    let normalizedQuery = tvNormalizedTrackQuery(query)
    guard !normalizedTrack.isEmpty, !normalizedQuery.isEmpty else { return false }
    return normalizedTrack.contains(normalizedQuery) || normalizedQuery.contains(normalizedTrack)
}

private func tvSelectableTrack(at ordinal: Int, from tracks: [MediaTrack]) -> MediaTrack? {
    guard ordinal >= 0 else { return nil }
    let selectable = tracks.filter { $0.id != -1 }
    guard ordinal < selectable.count else { return nil }
    return selectable[ordinal]
}

private func tvNormalizedTrackQuery(_ value: String) -> String {
    let lowered = value
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .lowercased()
    return String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
}

private func tvNormalizedServerTrackMetadataValue(_ value: String?) -> String {
    guard let value = value?
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .lowercased() else {
        return ""
    }
    return String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
}

private func tvPlaybackTimeText(_ time: TimeInterval) -> String {
    guard time.isFinite, time > 0 else { return "00:00" }

    let totalSeconds = Int(time.rounded(.down))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
}

private func tvPreferredSubtitleURL(for video: VideoFile, playlist: [VideoFile]?) -> URL? {
    let subtitleExtensions = Set(VideoFile.FileType.subtitleExtensions)
    let videoName = video.url.deletingPathExtension().lastPathComponent.lowercased()
    let orderedRemoteCandidates = tvOrderedRemoteSubtitleCandidates(
        video.externalSubtitleCandidates,
        preferredQuery: video.preferredSubtitleTrackQuery,
        preferredOrdinal: video.preferredSubtitleTrackOrdinal,
        videoName: videoName
    )
    var orderedURLs: [URL] = orderedRemoteCandidates.map(\.url)
    var seenKeys = Set(orderedURLs.map(tvSubtitleCandidateKey))

    if let playlist {
        let playlistURLs = playlist.compactMap { file in
            subtitleExtensions.contains(file.url.pathExtension.lowercased()) ? file.url : nil
        }
        for url in tvRankedSubtitleURLs(playlistURLs, for: videoName)
        where seenKeys.insert(tvSubtitleCandidateKey(url)).inserted {
            orderedURLs.append(url)
        }
    }

    if video.url.isFileURL {
        let directoryURL = video.url.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let localURLs = contents.filter { url in
            subtitleExtensions.contains(url.pathExtension.lowercased())
        }
        for url in tvRankedSubtitleURLs(localURLs, for: videoName)
        where seenKeys.insert(tvSubtitleCandidateKey(url)).inserted {
            orderedURLs.append(url)
        }
    }

    return orderedURLs.first
}

// Keep every discovered sidecar in the resolved media, not just the preferred
// one returned by tvPreferredSubtitleURL. This also survives engine rebuilding.
private func tvPlaybackSidecarCandidates(for video: VideoFile, playlist: [VideoFile]?) -> [ExternalSubtitleCandidate] {
    var candidates = video.externalSubtitleCandidates
    let extensions = Set(VideoFile.FileType.subtitleExtensions)
    for item in playlist ?? [] where item.type == .subtitle || extensions.contains(item.url.pathExtension.lowercased()) {
        candidates.append(.init(url: item.url, displayName: item.name))
    }
    if video.url.isFileURL {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: video.url.deletingLastPathComponent(), includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        let urls = contents.filter { extensions.contains($0.pathExtension.lowercased()) }
        let videoName = video.url.deletingPathExtension().lastPathComponent.lowercased()
        for url in tvRankedSubtitleURLs(urls, for: videoName) {
            candidates.append(.init(url: url, displayName: url.deletingPathExtension().lastPathComponent))
        }
    }
    return tvDeduplicatedExternalSubtitleCandidates(candidates)
}

private func tvRankedSubtitleURLs(_ subtitleURLs: [URL], for videoName: String) -> [URL] {
    let deduped = tvDeduplicatedSubtitleURLs(subtitleURLs)
    let scored = deduped.compactMap { url -> (url: URL, score: Int)? in
        let subtitleName = url.deletingPathExtension().lastPathComponent.lowercased()
        guard let score = tvSubtitleMatchScore(videoName: videoName, subtitleName: subtitleName) else {
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

    return deduped.sorted {
        $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
}

private func tvSubtitleMatchScore(videoName: String, subtitleName: String) -> Int? {
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

    return 10
}

private func tvOrderedRemoteSubtitleCandidates(
    _ candidates: [ExternalSubtitleCandidate],
    preferredQuery: String?,
    preferredOrdinal: Int?,
    videoName: String
) -> [ExternalSubtitleCandidate] {
    let deduped = tvDeduplicatedExternalSubtitleCandidates(candidates)
    let rankedURLs = tvRankedSubtitleURLs(deduped.map(\.url), for: videoName)
    let rankMap = Dictionary(uniqueKeysWithValues: rankedURLs.enumerated().map { index, url in
        (tvSubtitleCandidateKey(url), index)
    })
    let normalizedPreferredQuery = preferredQuery.map(tvNormalizedSubtitleSearchText)
    let preferredKey: String?
    if let preferredOrdinal,
       preferredOrdinal >= 0,
       preferredOrdinal < deduped.count {
        preferredKey = tvSubtitleCandidateKey(deduped[preferredOrdinal].url)
    } else {
        preferredKey = nil
    }

    return deduped.sorted { lhs, rhs in
        let lhsPreferredOrdinal = preferredKey == tvSubtitleCandidateKey(lhs.url)
        let rhsPreferredOrdinal = preferredKey == tvSubtitleCandidateKey(rhs.url)
        if lhsPreferredOrdinal != rhsPreferredOrdinal {
            return lhsPreferredOrdinal && !rhsPreferredOrdinal
        }

        let lhsPreferred = normalizedPreferredQuery.map { tvRemoteSubtitleCandidate(lhs, matches: $0) } ?? false
        let rhsPreferred = normalizedPreferredQuery.map { tvRemoteSubtitleCandidate(rhs, matches: $0) } ?? false
        if lhsPreferred != rhsPreferred {
            return lhsPreferred && !rhsPreferred
        }

        let lhsRank = rankMap[tvSubtitleCandidateKey(lhs.url)] ?? Int.max
        let rhsRank = rankMap[tvSubtitleCandidateKey(rhs.url)] ?? Int.max
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }

        return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
    }
}

private func tvRemoteSubtitleCandidate(_ candidate: ExternalSubtitleCandidate, matches normalizedQuery: String) -> Bool {
    guard !normalizedQuery.isEmpty else { return false }
    let displayName = tvNormalizedSubtitleSearchText(candidate.displayName)
    let fileName = tvNormalizedSubtitleSearchText(candidate.url.deletingPathExtension().lastPathComponent)
    return displayName.contains(normalizedQuery)
        || normalizedQuery.contains(displayName)
        || fileName.contains(normalizedQuery)
        || normalizedQuery.contains(fileName)
}

private func tvNormalizedSubtitleSearchText(_ value: String) -> String {
    let lowered = value
        .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        .lowercased()
    let allowed = CharacterSet.alphanumerics
    return String(lowered.unicodeScalars.filter { allowed.contains($0) })
}

private func tvSubtitleCandidateKey(_ url: URL) -> String {
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
            return name != "api_key" && name != "x-emby-token" && name != "x-plex-token"
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

private func tvDeduplicatedExternalSubtitleCandidates(_ candidates: [ExternalSubtitleCandidate]) -> [ExternalSubtitleCandidate] {
    var seen = Set<String>()
    var result: [ExternalSubtitleCandidate] = []
    for candidate in candidates {
        let key = tvSubtitleCandidateKey(candidate.url)
        guard seen.insert(key).inserted else { continue }
        result.append(candidate)
    }
    return result
}

private func tvDeduplicatedSubtitleURLs(_ urls: [URL]) -> [URL] {
    var seen = Set<String>()
    var result: [URL] = []
    for url in urls {
        let key = tvSubtitleCandidateKey(url)
        guard seen.insert(key).inserted else { continue }
        result.append(url)
    }
    return result
}

private func tvBOMDetectedEncoding(in data: Data) -> String.Encoding? {
    if data.count >= 3,
       data[data.startIndex] == 0xEF,
       data[data.startIndex + 1] == 0xBB,
       data[data.startIndex + 2] == 0xBF {
        return .utf8
    }

    if data.count >= 2 {
        let first = data[data.startIndex]
        let second = data[data.startIndex + 1]
        if first == 0xFF && second == 0xFE {
            return .utf16LittleEndian
        }
        if first == 0xFE && second == 0xFF {
            return .utf16BigEndian
        }
    }

    return nil
}

private func tvNormalizedSubtitleOutputURL(for originalURL: URL, key: String) -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TVNormalizedSubtitles", isDirectory: true)
    let baseName = tvSanitizedSubtitleFileName(from: originalURL.deletingPathExtension().lastPathComponent)
    let ext = originalURL.pathExtension.isEmpty ? "srt" : originalURL.pathExtension
    let hash = tvStableHashHex(for: key)
    return folder.appendingPathComponent("\(baseName)_\(hash).\(ext)")
}

private func tvRemoteSubtitleOutputURL(for originalURL: URL, key: String) -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TVRemoteSubtitleCache", isDirectory: true)
    let baseName = tvSanitizedSubtitleFileName(from: originalURL.deletingPathExtension().lastPathComponent)
    let ext = originalURL.pathExtension.isEmpty ? "sub" : originalURL.pathExtension
    let hash = tvStableHashHex(for: key)
    return folder.appendingPathComponent("\(baseName)_\(hash).\(ext)")
}

private func tvSanitizedSubtitleFileName(from value: String) -> String {
    let sanitized = value.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "_")
    let trimmed = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    return trimmed.isEmpty ? "subtitle" : trimmed
}

private func tvStableHashHex(for input: String) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    let prime: UInt64 = 0x100000001b3
    for byte in input.utf8 {
        hash ^= UInt64(byte)
        hash &*= prime
    }
    return String(format: "%016llx", hash)
}

private func tvResolvePlaybackFile(from file: VideoFile) async throws -> VideoFile {
    if file.isRemote,
       let server = tvPlaybackResolvedServer(for: file),
       server.type.requiresDynamicPlaybackURL {
        return try await AppNetworkService.shared.resolvedPlaybackFile(file)
    }

    guard file.isRemote,
          let itemId = tvTrimmedPlaybackText(file.jellyfinItemId),
          let server = tvPlaybackResolvedServer(for: file) else {
        return file
    }

    switch server.type {
    case .jellyfin:
        let preparedServer = try await tvPlaybackPreparedMediaLibraryServer(server)
        guard let token = tvTrimmedPlaybackText(preparedServer.accessToken),
              let userId = try await tvPlaybackResolvedUserId(server: preparedServer),
              !userId.isEmpty else {
            throw NSError(
                domain: "GenPlayerShell",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
            )
        }

        let baseURL = preparedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard
            let itemURL = URL(string: "\(baseURL)/Users/\(userId)/Items/\(itemId)?Fields=MediaSources,UserData,SeriesId,SeasonId,RunTimeTicks"),
            var components = URLComponents(string: "\(baseURL)/Videos/\(itemId)/stream")
        else {
            throw URLError(.badURL)
        }

        let item: JellyfinItem = try await tvPlaybackFetchDecodable(from: itemURL, server: preparedServer)
        let mediaSources = item.mediaSources ?? []
        let qualityOptions = tvJellyfinPlaybackQualityOptions(from: mediaSources)
        let playbackQuality = TVPlaybackSettings.resolvedRemotePlaybackQualityOption(for: file.preferredPlaybackQualityID)
        let preferredSource = tvPreferredJellyfinMediaSource(from: mediaSources, playbackQuality: playbackQuality)
        let lastPlayedPosition = file.shouldResetRemotePlayedStateOnPlaybackStart
            ? 0
            : item.userData?.resumeDecision(runtimeTicks: item.runTimeTicks).startPosition
        let streamURL = try tvResolvedJellyfinPlaybackURL(
            server: preparedServer,
            itemId: itemId,
            token: token,
            fallbackComponents: components,
            mediaSource: preferredSource,
            playbackQuality: playbackQuality
        )

        return tvPlaybackRebuiltFile(
            from: file,
            name: item.displayTitle,
            url: RuntimeNetworkAddressResolver.runtimeURL(from: streamURL),
            duration: item.runTimeTicks.map { TimeInterval($0) / 10_000_000.0 },
            lastPlayedPosition: lastPlayedPosition,
            seriesId: item.seriesId,
            seasonId: item.seasonId,
            serverId: preparedServer.id.uuidString,
            preferredPlaybackQualityID: playbackQuality.id,
            availablePlaybackQualityOptions: qualityOptions,
            externalSubtitleCandidates: tvJellyfinExternalSubtitleCandidates(
                server: preparedServer,
                itemId: itemId,
                mediaSources: mediaSources,
                token: token,
                preferredMediaSourceId: preferredSource?.id
            ),
            serverMediaStreams: preferredSource?.mediaStreams?.map { $0.toDictionary() },
            serverContainer: preferredSource?.container,
            serverSize: preferredSource?.size,
            serverBitrate: preferredSource?.bitrate,
            serverPath: preferredSource?.path,
            mediaSourceId: preferredSource?.id,
            remotePlaybackMethod: playbackQuality.prefersConstrainedPlayback
                ? .transcode
                : tvRemotePlaybackMethod(
                    resolvedURL: streamURL,
                    hasDirectStreamURL: !(preferredSource?.directStreamUrl?.isEmpty ?? true)
                )
        )

    case .emby:
        let preparedServer = try await tvPlaybackPreparedMediaLibraryServer(server)
        guard let token = tvTrimmedPlaybackText(preparedServer.accessToken),
              let userId = try await tvPlaybackResolvedUserId(server: preparedServer),
              !userId.isEmpty else {
            throw NSError(
                domain: "GenPlayerShell",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: platformShellString("Platform Shell TV Library Server Sign In Hint")]
            )
        }

        let baseURL = preparedServer.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard
            let itemURL = URL(string: "\(baseURL)/Users/\(userId)/Items/\(itemId)?Fields=MediaSources,UserData,SeriesId,SeasonId,RunTimeTicks"),
            var components = URLComponents(string: "\(baseURL)/Videos/\(itemId)/stream")
        else {
            throw URLError(.badURL)
        }

        let item: EmbyItem = try await tvPlaybackFetchDecodable(from: itemURL, server: preparedServer)
        let mediaSources = item.mediaSources ?? []
        let qualityOptions = tvEmbyPlaybackQualityOptions(from: mediaSources)
        let playbackQuality = TVPlaybackSettings.resolvedRemotePlaybackQualityOption(for: file.preferredPlaybackQualityID)
        let preferredSource = tvPreferredEmbyMediaSource(from: mediaSources, playbackQuality: playbackQuality)
        let lastPlayedPosition = file.shouldResetRemotePlayedStateOnPlaybackStart
            ? 0
            : item.userData?.resumeDecision(runtimeTicks: item.runTimeTicks).startPosition
        let streamURL = try tvResolvedEmbyPlaybackURL(
            server: preparedServer,
            itemId: itemId,
            token: token,
            fallbackComponents: components,
            mediaSource: preferredSource,
            playbackQuality: playbackQuality,
            startTimeTicks: tvPlaybackStartTimeTicks(lastPlayedPosition)
        )

        return tvPlaybackRebuiltFile(
            from: file,
            name: item.displayTitle,
            url: RuntimeNetworkAddressResolver.runtimeURL(from: streamURL),
            duration: item.runTimeTicks.map { TimeInterval($0) / 10_000_000.0 },
            lastPlayedPosition: lastPlayedPosition,
            seriesId: item.seriesId,
            seasonId: item.seasonId,
            serverId: preparedServer.id.uuidString,
            preferredPlaybackQualityID: playbackQuality.id,
            availablePlaybackQualityOptions: qualityOptions,
            externalSubtitleCandidates: tvEmbyExternalSubtitleCandidates(
                server: preparedServer,
                itemId: itemId,
                mediaSources: mediaSources,
                token: token,
                preferredMediaSourceId: preferredSource?.id
            ),
            serverMediaStreams: preferredSource?.mediaStreams?.map { $0.toDictionary() },
            serverContainer: preferredSource?.container,
            serverSize: preferredSource?.size,
            serverBitrate: preferredSource?.bitrate,
            serverPath: preferredSource?.path,
            mediaSourceId: preferredSource?.id,
            remotePlaybackMethod: playbackQuality.prefersConstrainedPlayback
                ? .transcode
                : tvRemotePlaybackMethod(
                    resolvedURL: streamURL,
                    hasDirectStreamURL: !(preferredSource?.directStreamUrl?.isEmpty ?? true)
                )
        )

    case .plex:
        let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let itemURL = URL(string: "\(baseURL)/library/metadata/\(itemId)") else {
            throw URLError(.badURL)
        }

        let root = try await tvPlaybackFetchJSONObject(from: itemURL, server: server)
        guard
            let container = root["MediaContainer"] as? [String: Any],
            let metadata = (container["Metadata"] as? [[String: Any]])?.first
        else {
            throw NSError(
                domain: "GenPlayerShell",
                code: NSURLErrorCannotDecodeContentData,
                userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection Failed")]
            )
        }

        let item = PlexItem(dictionary: metadata)
        guard let mediaPartKey = item.mediaPartKey else {
            throw NSError(
                domain: "GenPlayerShell",
                code: NSURLErrorBadServerResponse,
                userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection Failed")]
            )
        }

        guard var components = URLComponents(string: baseURL + mediaPartKey) else {
            throw URLError(.badURL)
        }
        if let token = tvTrimmedPlaybackText(server.accessToken) ?? tvTrimmedPlaybackText(server.passwordSecret) {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
            components.queryItems = queryItems
        }
        guard let directStreamURL = components.url else {
            throw URLError(.badURL)
        }
        let qualityOptions = tvPlexPlaybackQualityOptions(for: item)
        let playbackQuality = TVPlaybackSettings.resolvedRemotePlaybackQualityOption(for: file.preferredPlaybackQualityID)
        let streamURL = tvResolvedPlexPlaybackURL(
            server: server,
            item: item,
            directStreamURL: directStreamURL,
            playbackQuality: playbackQuality,
            startPosition: file.shouldResetRemotePlayedStateOnPlaybackStart ? 0 : item.resumeDecision.startPosition
        )

        return tvPlaybackRebuiltFile(
            from: file,
            name: item.displayTitle,
            url: RuntimeNetworkAddressResolver.runtimeURL(from: streamURL),
            duration: item.durationSeconds,
            lastPlayedPosition: file.shouldResetRemotePlayedStateOnPlaybackStart ? 0 : item.resumeDecision.startPosition,
            seriesId: item.grandparentRatingKey ?? item.parentRatingKey,
            seasonId: item.parentRatingKey,
            serverId: server.id.uuidString,
            preferredPlaybackQualityID: playbackQuality.id,
            availablePlaybackQualityOptions: qualityOptions,
            externalSubtitleCandidates: tvPlexExternalSubtitleCandidates(
                server: server,
                metadata: metadata
            ),
            serverMediaStreams: item.mediaStreams.map { $0.toDictionary() },
            serverContainer: item.mediaContainer,
            serverSize: item.mediaSize,
            serverBitrate: item.mediaBitrate,
            serverPath: item.mediaFilePath,
            remotePlaybackMethod: playbackQuality.prefersConstrainedPlayback
                ? .transcode
                : tvRemotePlaybackMethod(
                    resolvedURL: streamURL,
                    hasDirectStreamURL: true
                )
        )

    default:
        return file
    }
}

private func tvPlaybackIsAListFile(_ file: VideoFile) -> Bool {
    guard file.isRemote else { return false }
    return tvPlaybackResolvedServer(for: file)?.type == .alist
}

private func tvPlaybackResolvedServer(for file: VideoFile) -> ServerConfig? {
    let servers = AppNetworkService.shared.savedServers

    if let serverId = tvTrimmedPlaybackText(file.jellyfinServerId),
       let uuid = UUID(uuidString: serverId),
       let match = servers.first(where: { $0.id == uuid }) {
        return match
    }

    guard let host = file.url.host?.lowercased() else { return nil }
    return servers.first { server in
        let serverHost = (URLComponents(string: server.fullURL)?.host ?? server.address)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return host == serverHost
    }
}

private func tvPlaybackResolvedUserId(server: ServerConfig) async throws -> String? {
    if let userId = tvTrimmedPlaybackText(server.userId) {
        return userId
    }
    guard server.type == .jellyfin || server.type == .emby else {
        return nil
    }
    guard let token = tvTrimmedPlaybackText(server.accessToken) else {
        return nil
    }

    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard let url = URL(string: "\(baseURL)/Users/Me") else {
        return nil
    }

    var request = tvPlaybackMediaLibraryRequest(url: url, server: server)
    request.setValue(token, forHTTPHeaderField: "X-Emby-Token")

    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return json["Id"] as? String
}

private func tvPlaybackPreparedMediaLibraryServer(_ server: ServerConfig) async throws -> ServerConfig {
    guard server.type == .jellyfin || server.type == .emby else {
        return server
    }

    if let token = tvTrimmedPlaybackText(server.accessToken) {
        var verifiedServer = server
        verifiedServer.accessToken = token
        if let userId = try await tvPlaybackResolvedUserId(server: server), !userId.isEmpty {
            verifiedServer.userId = userId
        }
        return verifiedServer
    }

    return server
}

private func tvPlaybackFetchJSONObject(
    from url: URL,
    server: ServerConfig
) async throws -> [String: Any] {
    let request = tvPlaybackMediaLibraryRequest(url: url, server: server)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        throw NSError(
            domain: "GenPlayerShell",
            code: (response as? HTTPURLResponse)?.statusCode ?? -1,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection Failed")]
        )
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(
            domain: "GenPlayerShell",
            code: NSURLErrorCannotDecodeContentData,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection Failed")]
        )
    }
    return json
}

private func tvPlaybackFetchDecodable<Response: Decodable>(
    from url: URL,
    server: ServerConfig
) async throws -> Response {
    let request = tvPlaybackMediaLibraryRequest(url: url, server: server)
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        throw NSError(
            domain: "GenPlayerShell",
            code: (response as? HTTPURLResponse)?.statusCode ?? -1,
            userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection Failed")]
        )
    }
    return try JSONDecoder().decode(Response.self, from: data)
}

private func tvPlaybackMediaLibraryRequest(url: URL, server: ServerConfig) -> URLRequest {
    var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
    request.timeoutInterval = 20
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    switch server.type {
    case .jellyfin, .emby:
        if let token = tvTrimmedPlaybackText(server.accessToken) {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            request.setValue(token, forHTTPHeaderField: "X-MediaBrowser-Token")
        }
        request.setValue(
            "MediaBrowser Client=\"GenPlayer-tvOS\", Device=\"Apple TV\", DeviceId=\"GenPlayerTV\", Version=\"1.0\"",
            forHTTPHeaderField: "X-Emby-Authorization"
        )
    case .plex:
        request.setValue("GenPlayer", forHTTPHeaderField: "X-Plex-Product")
        request.setValue("tvOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("GenPlayer-tvOS", forHTTPHeaderField: "X-Plex-Device")
        request.setValue("GenPlayerTV", forHTTPHeaderField: "X-Plex-Client-Identifier")
        if let token = tvTrimmedPlaybackText(server.accessToken) ?? tvTrimmedPlaybackText(server.passwordSecret) {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
    default:
        break
    }

    return request
}

private func tvTrimmedPlaybackText(_ text: String?) -> String? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty else {
        return nil
    }
    return text
}

private func tvPlaybackNormalizedMetadataText(_ text: String?) -> String? {
    guard let trimmed = tvTrimmedPlaybackText(text) else { return nil }
    let lowered = trimmed.lowercased()
    if lowered == "unknown" ||
        lowered == "untitled" ||
        lowered == "<unknown>" {
        return nil
    }
    return trimmed
}

private func tvPlaybackQueryValue(named name: String, in url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return nil
    }

    return components.queryItems?.first(where: {
        $0.name.caseInsensitiveCompare(name) == .orderedSame
    })?.value
}

private func tvPlaybackRebuiltFile(
    from original: VideoFile,
    name: String,
    url: URL,
    duration: TimeInterval?,
    lastPlayedPosition: TimeInterval?,
    seriesId: String?,
    seasonId: String?,
    serverId: String,
    preferredPlaybackQualityID: String? = nil,
    availablePlaybackQualityOptions: [RemotePlaybackQualityOption]? = nil,
    externalSubtitleCandidates: [ExternalSubtitleCandidate]? = nil,
    serverMediaStreams: [[String: Any]]? = nil,
    serverContainer: String? = nil,
    serverSize: Int64? = nil,
    serverBitrate: Int? = nil,
    serverPath: String? = nil,
    mediaSourceId: String? = nil,
    remotePlaybackMethod: RemotePlaybackMethod? = nil
) -> VideoFile {
    var rebuilt = VideoFile(
        name: name,
        url: url,
        type: original.type,
        size: original.size,
        date: original.date,
        isRemote: original.isRemote,
        duration: duration,
        lastPlayedPosition: lastPlayedPosition,
        videoAspectRatioHint: original.videoAspectRatioHint,
        lastAudioTrack: original.lastAudioTrack,
        lastSubtitleTrack: original.lastSubtitleTrack,
        jellyfinItemId: original.jellyfinItemId,
        jellyfinServerId: serverId,
        serverType: original.serverType,
        itemCount: original.itemCount,
        seriesId: seriesId ?? original.seriesId,
        seasonId: seasonId ?? original.seasonId,
        preferredAudioTrackQuery: original.preferredAudioTrackQuery,
        preferredSubtitleTrackQuery: original.preferredSubtitleTrackQuery,
        disableSubtitlesOnStart: original.disableSubtitlesOnStart,
        shouldResetRemotePlayedStateOnPlaybackStart: original.shouldResetRemotePlayedStateOnPlaybackStart,
        externalSubtitleCandidates: original.externalSubtitleCandidates
    )
    rebuilt.preferredAudioTrackOrdinal = original.preferredAudioTrackOrdinal
    rebuilt.preferredSubtitleTrackOrdinal = original.preferredSubtitleTrackOrdinal
    rebuilt.preferredPlaybackQualityID = preferredPlaybackQualityID ?? original.preferredPlaybackQualityID
    rebuilt.availablePlaybackQualityOptions = availablePlaybackQualityOptions ?? original.availablePlaybackQualityOptions
    rebuilt.externalSubtitleCandidates = externalSubtitleCandidates ?? original.externalSubtitleCandidates
    rebuilt.serverMediaStreams = serverMediaStreams ?? original.serverMediaStreams
    rebuilt.serverContainer = serverContainer ?? original.serverContainer
    rebuilt.serverSize = serverSize ?? original.serverSize
    rebuilt.serverBitrate = serverBitrate ?? original.serverBitrate
    rebuilt.serverPath = serverPath ?? original.serverPath
    rebuilt.mediaSourceId = mediaSourceId ?? original.mediaSourceId
    rebuilt.remotePlaybackMethod = remotePlaybackMethod ?? original.remotePlaybackMethod
    return rebuilt
}

private func tvJellyfinPlaybackQualityOptions(from mediaSources: [JellyfinMediaSource]) -> [RemotePlaybackQualityOption] {
    let maxWidth = mediaSources.compactMap { $0.videoStream?.width }.max()
    let maxHeight = mediaSources.compactMap { $0.videoStream?.height }.max()
    let supportsTranscoding = mediaSources.contains {
        $0.supportsTranscoding == true || !(($0.transcodingUrl ?? "").isEmpty)
    }
    return RemotePlaybackQualityCatalog.options(
        maxVideoWidth: maxWidth,
        maxVideoHeight: maxHeight,
        supportsTranscoding: supportsTranscoding
    )
}

private func tvEmbyPlaybackQualityOptions(from mediaSources: [EmbyMediaSource]) -> [RemotePlaybackQualityOption] {
    let maxWidth = mediaSources.compactMap { $0.videoStream?.width }.max()
    let maxHeight = mediaSources.compactMap { $0.videoStream?.height }.max()
    let supportsTranscoding = mediaSources.contains {
        $0.supportsTranscoding == true || !(($0.transcodingUrl ?? "").isEmpty)
    }
    return RemotePlaybackQualityCatalog.options(
        maxVideoWidth: maxWidth,
        maxVideoHeight: maxHeight,
        supportsTranscoding: supportsTranscoding
    )
}

private func tvPlexPlaybackQualityOptions(for item: PlexItem) -> [RemotePlaybackQualityOption] {
    RemotePlaybackQualityCatalog.options(
        maxVideoWidth: item.maxVideoWidth,
        maxVideoHeight: item.maxVideoHeight,
        supportsTranscoding: item.isPlayable && !(item.mediaPartKey?.isEmpty ?? true)
    )
}

private func tvPreferredJellyfinMediaSource(
    from mediaSources: [JellyfinMediaSource],
    playbackQuality: RemotePlaybackQualityOption = .auto
) -> JellyfinMediaSource? {
    mediaSources.max { lhs, rhs in
        tvPlaybackSourceScore(
            supportsDirectPlay: lhs.supportsDirectPlay,
            supportsDirectStream: lhs.supportsDirectStream,
            supportsTranscoding: lhs.supportsTranscoding,
            directStreamURL: lhs.directStreamUrl,
            transcodingURL: lhs.transcodingUrl,
            streamCount: lhs.mediaStreams?.count ?? 0,
            playbackQuality: playbackQuality
        ) < tvPlaybackSourceScore(
            supportsDirectPlay: rhs.supportsDirectPlay,
            supportsDirectStream: rhs.supportsDirectStream,
            supportsTranscoding: rhs.supportsTranscoding,
            directStreamURL: rhs.directStreamUrl,
            transcodingURL: rhs.transcodingUrl,
            streamCount: rhs.mediaStreams?.count ?? 0,
            playbackQuality: playbackQuality
        )
    } ?? mediaSources.first
}

private func tvPreferredEmbyMediaSource(
    from mediaSources: [EmbyMediaSource],
    playbackQuality: RemotePlaybackQualityOption = .auto
) -> EmbyMediaSource? {
    mediaSources.max { lhs, rhs in
        tvPlaybackSourceScore(
            supportsDirectPlay: lhs.supportsDirectPlay,
            supportsDirectStream: lhs.supportsDirectStream,
            supportsTranscoding: lhs.supportsTranscoding,
            directStreamURL: lhs.directStreamUrl,
            transcodingURL: lhs.transcodingUrl,
            streamCount: lhs.mediaStreams?.count ?? 0,
            playbackQuality: playbackQuality
        ) < tvPlaybackSourceScore(
            supportsDirectPlay: rhs.supportsDirectPlay,
            supportsDirectStream: rhs.supportsDirectStream,
            supportsTranscoding: rhs.supportsTranscoding,
            directStreamURL: rhs.directStreamUrl,
            transcodingURL: rhs.transcodingUrl,
            streamCount: rhs.mediaStreams?.count ?? 0,
            playbackQuality: playbackQuality
        )
    } ?? mediaSources.first
}

private func tvPlaybackSourceScore(
    supportsDirectPlay: Bool?,
    supportsDirectStream: Bool?,
    supportsTranscoding: Bool?,
    directStreamURL: String?,
    transcodingURL: String?,
    streamCount: Int,
    playbackQuality: RemotePlaybackQualityOption = .auto
) -> Int {
    var score = streamCount
    if supportsDirectPlay == true { score += 200 }
    if supportsDirectStream == true { score += 120 }
    if let directStreamURL, !directStreamURL.isEmpty { score += 80 }
    if supportsTranscoding == true { score += 20 }
    if let transcodingURL, !transcodingURL.isEmpty { score += 10 }
    if playbackQuality.prefersConstrainedPlayback {
        score += (supportsTranscoding == true || !(transcodingURL?.isEmpty ?? true)) ? 1_000 : -1_000
    }
    return score
}

private func tvResolvedJellyfinPlaybackURL(
    server: ServerConfig,
    itemId: String,
    token: String,
    fallbackComponents: URLComponents,
    mediaSource: JellyfinMediaSource?,
    playbackQuality: RemotePlaybackQualityOption
) throws -> URL {
    if playbackQuality.prefersConstrainedPlayback,
       let mediaSource,
       let transcodeURL = tvManualMediaBrowserTranscodingURL(
            server: server,
            itemId: itemId,
            token: token,
            mediaSourceId: mediaSource.id,
            pathExtension: "master.m3u8",
            playbackQuality: playbackQuality,
            startTimeTicks: nil
       ) {
        return transcodeURL
    }

    return try tvResolvedMediaServerPlaybackURL(
        baseURL: server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
        tokenQueryName: "api_key",
        token: token,
        fallbackComponents: fallbackComponents,
        mediaSourceId: mediaSource?.id,
        directStreamPath: mediaSource?.directStreamUrl
    )
}

private func tvResolvedEmbyPlaybackURL(
    server: ServerConfig,
    itemId: String,
    token: String,
    fallbackComponents: URLComponents,
    mediaSource: EmbyMediaSource?,
    playbackQuality: RemotePlaybackQualityOption,
    startTimeTicks: Int64?
) throws -> URL {
    if playbackQuality.prefersConstrainedPlayback,
       let mediaSource,
       let transcodeURL = tvManualMediaBrowserTranscodingURL(
            server: server,
            itemId: itemId,
            token: token,
            mediaSourceId: mediaSource.id,
            pathExtension: "stream.ts",
            playbackQuality: playbackQuality,
            startTimeTicks: startTimeTicks
       ) {
        return transcodeURL
    }

    return try tvResolvedMediaServerPlaybackURL(
        baseURL: server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
        tokenQueryName: "api_key",
        token: token,
        fallbackComponents: fallbackComponents,
        mediaSourceId: mediaSource?.id,
        directStreamPath: mediaSource?.directStreamUrl
    )
}

private func tvManualMediaBrowserTranscodingURL(
    server: ServerConfig,
    itemId: String,
    token: String,
    mediaSourceId: String,
    pathExtension: String,
    playbackQuality: RemotePlaybackQualityOption,
    startTimeTicks: Int64?
) -> URL? {
    guard playbackQuality.prefersConstrainedPlayback else { return nil }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: "\(baseURL)/Videos/\(itemId)/\(pathExtension)") else {
        return nil
    }

    var queryItems: [URLQueryItem] = [
        URLQueryItem(name: "MediaSourceId", value: mediaSourceId),
        URLQueryItem(name: "DeviceId", value: "GenPlayerTV"),
        URLQueryItem(name: "VideoCodec", value: "h264"),
        URLQueryItem(name: "AudioCodec", value: "aac,mp3,ac3,eac3"),
        URLQueryItem(name: "api_key", value: token)
    ]

    if pathExtension == "master.m3u8" {
        queryItems.append(contentsOf: [
            URLQueryItem(name: "Container", value: "ts"),
            URLQueryItem(name: "TranscodingContainer", value: "ts"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls")
        ])
    } else {
        queryItems.append(contentsOf: [
            URLQueryItem(name: "Static", value: "false"),
            URLQueryItem(name: "EnableAutoStreamCopy", value: "false")
        ])
    }

    if let startTimeTicks, startTimeTicks > 0 {
        queryItems.append(URLQueryItem(name: "StartTimeTicks", value: String(startTimeTicks)))
    }

    queryItems = tvAppendingPlaybackQualityQueryItems(queryItems, for: playbackQuality)
    components.queryItems = queryItems
    return components.url
}

private func tvAppendingPlaybackQualityQueryItems(
    _ queryItems: [URLQueryItem],
    for quality: RemotePlaybackQualityOption
) -> [URLQueryItem] {
    var updated = queryItems
    let containsKey: (String) -> Bool = { key in
        updated.contains { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    if let maxStreamingBitrate = quality.maxStreamingBitrate {
        if !containsKey("MaxStreamingBitrate") {
            updated.append(URLQueryItem(name: "MaxStreamingBitrate", value: String(maxStreamingBitrate)))
        }
        if !containsKey("VideoBitrate") {
            updated.append(URLQueryItem(name: "VideoBitrate", value: String(maxStreamingBitrate)))
        }
        if !containsKey("AudioBitrate") {
            updated.append(URLQueryItem(name: "AudioBitrate", value: "320000"))
        }
    }
    if let maxWidth = quality.maxWidth, !containsKey("MaxWidth") {
        updated.append(URLQueryItem(name: "MaxWidth", value: String(maxWidth)))
    }
    if let maxHeight = quality.maxHeight, !containsKey("MaxHeight") {
        updated.append(URLQueryItem(name: "MaxHeight", value: String(maxHeight)))
    }
    return updated
}

private func tvPlaybackStartTimeTicks(_ seconds: TimeInterval?) -> Int64? {
    guard let seconds, seconds > 0 else { return nil }
    return Int64((seconds * 10_000_000.0).rounded())
}

private func tvResolvedMediaServerPlaybackURL(
    baseURL: String,
    tokenQueryName: String,
    token: String,
    fallbackComponents: URLComponents,
    mediaSourceId: String?,
    directStreamPath: String?
) throws -> URL {
    if let directStreamURL = tvResolvedMediaServerURL(
        baseURL: baseURL,
        rawPath: directStreamPath,
        tokenQueryName: tokenQueryName,
        token: token
    ) {
        return directStreamURL
    }

    var components = fallbackComponents
    components.queryItems = [
        URLQueryItem(name: "static", value: "true"),
        URLQueryItem(name: tokenQueryName, value: token)
    ]
    if let mediaSourceId = tvTrimmedPlaybackText(mediaSourceId) {
        components.queryItems?.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceId))
    }
    guard let resolvedURL = components.url else {
        throw URLError(.badURL)
    }
    return resolvedURL
}

private func tvResolvedMediaServerURL(
    baseURL: String,
    rawPath: String?,
    tokenQueryName: String,
    token: String
) -> URL? {
    guard let rawPath = tvTrimmedPlaybackText(rawPath) else { return nil }
    let resolvedURL: URL?
    if rawPath.hasPrefix("http://") || rawPath.hasPrefix("https://") {
        resolvedURL = URL(string: rawPath)
    } else {
        resolvedURL = URL(string: baseURL + (rawPath.hasPrefix("/") ? rawPath : "/\(rawPath)"))
    }
    guard let resolvedURL,
          var components = URLComponents(url: resolvedURL, resolvingAgainstBaseURL: false) else {
        return nil
    }
    var queryItems = components.queryItems ?? []
    if !queryItems.contains(where: { $0.name.caseInsensitiveCompare(tokenQueryName) == .orderedSame }) {
        queryItems.append(URLQueryItem(name: tokenQueryName, value: token))
    }
    components.queryItems = queryItems
    return components.url
}

private func tvResolvedPlexPlaybackURL(
    server: ServerConfig,
    item: PlexItem,
    directStreamURL: URL,
    playbackQuality: RemotePlaybackQualityOption,
    startPosition: TimeInterval?
) -> URL {
    guard playbackQuality.prefersConstrainedPlayback,
          item.isPlayable,
          let transcodeURL = tvPlexTranscodeURL(
            server: server,
            item: item,
            playbackQuality: playbackQuality,
            startPosition: startPosition
          ) else {
        return directStreamURL
    }
    return transcodeURL
}

private func tvPlexTranscodeURL(
    server: ServerConfig,
    item: PlexItem,
    playbackQuality: RemotePlaybackQualityOption,
    startPosition: TimeInterval?
) -> URL? {
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    guard var components = URLComponents(string: baseURL) else { return nil }
    components.path = "/video/:/transcode/universal/start.m3u8"
    components.queryItems = tvPlexTranscodeQueryItems(
        server: server,
        item: item,
        playbackQuality: playbackQuality,
        startPosition: startPosition
    )
    return components.url
}

private func tvPlexTranscodeQueryItems(
    server: ServerConfig,
    item: PlexItem,
    playbackQuality: RemotePlaybackQualityOption,
    startPosition: TimeInterval?
) -> [URLQueryItem] {
    let sessionIdentifier = UUID().uuidString
    let sourceWidth = max(item.maxVideoWidth ?? playbackQuality.maxWidth ?? 0, 1)
    let sourceHeight = max(item.maxVideoHeight ?? playbackQuality.maxHeight ?? 0, 1)
    let targetWidth = playbackQuality.maxWidth ?? sourceWidth
    let targetHeight = playbackQuality.maxHeight ?? sourceHeight
    let fittedResolution = tvFittedVideoResolution(
        sourceWidth: sourceWidth,
        sourceHeight: sourceHeight,
        targetWidth: targetWidth,
        targetHeight: targetHeight
    )

    var queryItems: [URLQueryItem] = [
        URLQueryItem(name: "path", value: "/library/metadata/\(item.id)"),
        URLQueryItem(name: "mediaIndex", value: "0"),
        URLQueryItem(name: "partIndex", value: "0"),
        URLQueryItem(name: "transcodeSessionId", value: sessionIdentifier),
        URLQueryItem(name: "protocol", value: "hls"),
        URLQueryItem(name: "copyts", value: "1"),
        URLQueryItem(name: "fastSeek", value: "1"),
        URLQueryItem(name: "location", value: "wan"),
        URLQueryItem(name: "directPlay", value: playbackQuality.allowsDirectPlay ? "1" : "0"),
        URLQueryItem(name: "directStream", value: playbackQuality.allowsDirectStream ? "1" : "0"),
        URLQueryItem(name: "directStreamAudio", value: playbackQuality.allowsDirectStream ? "1" : "0"),
        URLQueryItem(name: "hasMDE", value: playbackQuality.allowsDirectPlay ? "1" : "0"),
        URLQueryItem(name: "autoAdjustQuality", value: playbackQuality.preset == .auto ? "1" : "0"),
        URLQueryItem(name: "videoQuality", value: "\(tvPlexVideoQualityValue(for: playbackQuality))"),
        URLQueryItem(name: "videoResolution", value: "\(fittedResolution.width)x\(fittedResolution.height)"),
        URLQueryItem(name: "mediaBufferSize", value: "102400"),
        URLQueryItem(name: "secondsPerSegment", value: "5"),
        URLQueryItem(name: "disableResolutionRotation", value: "1"),
        URLQueryItem(name: "subtitles", value: "auto"),
        URLQueryItem(name: "X-Plex-Client-Identifier", value: "GenPlayerTV"),
        URLQueryItem(name: "X-Plex-Product", value: "GenPlayer"),
        URLQueryItem(name: "X-Plex-Version", value: "1.0"),
        URLQueryItem(name: "X-Plex-Platform", value: "tvOS"),
        URLQueryItem(name: "X-Plex-Platform-Version", value: UIDevice.current.systemVersion),
        URLQueryItem(name: "X-Plex-Device", value: "Apple TV"),
        URLQueryItem(name: "X-Plex-Device-Name", value: UIDevice.current.name),
        URLQueryItem(name: "X-Plex-Client-Profile-Name", value: "generic"),
        URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionIdentifier)
    ]

    if let token = tvTrimmedPlaybackText(server.accessToken) ?? tvTrimmedPlaybackText(server.passwordSecret) {
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
    }
    if let bitrate = playbackQuality.maxStreamingBitrate {
        let kbps = max(1, bitrate / 1000)
        queryItems.append(URLQueryItem(name: "videoBitrate", value: "\(kbps)"))
        queryItems.append(URLQueryItem(name: "peakBitrate", value: "\(kbps)"))
    }
    if let startPosition, startPosition > 0 {
        queryItems.append(URLQueryItem(name: "offset", value: String(format: "%.3f", startPosition)))
    }

    return queryItems
}

private func tvFittedVideoResolution(
    sourceWidth: Int,
    sourceHeight: Int,
    targetWidth: Int,
    targetHeight: Int
) -> (width: Int, height: Int) {
    guard sourceWidth > 0, sourceHeight > 0, targetWidth > 0, targetHeight > 0 else {
        return (max(targetWidth, 1), max(targetHeight, 1))
    }

    let sourceAspect = Double(sourceWidth) / Double(sourceHeight)
    let targetAspect = Double(targetWidth) / Double(targetHeight)
    let resolvedWidth: Int
    let resolvedHeight: Int

    if sourceAspect > targetAspect {
        resolvedWidth = min(sourceWidth, targetWidth)
        resolvedHeight = Int((Double(resolvedWidth) / sourceAspect).rounded(.down))
    } else {
        resolvedHeight = min(sourceHeight, targetHeight)
        resolvedWidth = Int((Double(resolvedHeight) * sourceAspect).rounded(.down))
    }

    return (
        width: max(resolvedWidth / 2 * 2, 2),
        height: max(resolvedHeight / 2 * 2, 2)
    )
}

private func tvPlexVideoQualityValue(for playbackQuality: RemotePlaybackQualityOption) -> Int {
    switch playbackQuality.preset {
    case .auto:
        return 60
    case .original:
        return 80
    case .p1080:
        return 60
    case .p720:
        return 50
    case .p480:
        return 40
    }
}

private func tvJellyfinExternalSubtitleCandidates(
    server: ServerConfig,
    itemId: String,
    mediaSources: [JellyfinMediaSource],
    token: String,
    preferredMediaSourceId: String?
) -> [ExternalSubtitleCandidate] {
    let orderedSources: [JellyfinMediaSource]
    if let preferredMediaSourceId,
       let preferred = mediaSources.first(where: { $0.id.caseInsensitiveCompare(preferredMediaSourceId) == .orderedSame }) {
        orderedSources = [preferred]
    } else {
        orderedSources = mediaSources
    }

    var seen = Set<String>()
    var result: [ExternalSubtitleCandidate] = []
    for source in orderedSources {
        for stream in source.mediaStreams ?? [] {
            guard tvJellyfinSubtitleStreamIsExternal(stream) else { continue }
            guard let url = tvJellyfinSubtitleURL(
                server: server,
                itemId: itemId,
                mediaSourceId: source.id,
                stream: stream,
                token: token
            ) else {
                continue
            }
            let key = tvSubtitleCandidateKey(url)
            guard seen.insert(key).inserted else { continue }
            result.append(ExternalSubtitleCandidate(url: url, displayName: tvSubtitleDisplayName(for: stream)))
        }
    }
    return result
}

private func tvEmbyExternalSubtitleCandidates(
    server: ServerConfig,
    itemId: String,
    mediaSources: [EmbyMediaSource],
    token: String,
    preferredMediaSourceId: String?
) -> [ExternalSubtitleCandidate] {
    let orderedSources: [EmbyMediaSource]
    if let preferredMediaSourceId,
       let preferred = mediaSources.first(where: { $0.id.caseInsensitiveCompare(preferredMediaSourceId) == .orderedSame }) {
        orderedSources = [preferred]
    } else {
        orderedSources = mediaSources
    }

    var seen = Set<String>()
    var result: [ExternalSubtitleCandidate] = []
    for source in orderedSources {
        for stream in source.mediaStreams ?? [] {
            guard tvEmbySubtitleStreamIsExternal(stream) else { continue }
            guard let url = tvEmbySubtitleURL(
                server: server,
                itemId: itemId,
                mediaSourceId: source.id,
                stream: stream,
                token: token
            ) else {
                continue
            }
            let key = tvSubtitleCandidateKey(url)
            guard seen.insert(key).inserted else { continue }
            result.append(ExternalSubtitleCandidate(url: url, displayName: tvSubtitleDisplayName(for: stream)))
        }
    }
    return result
}

private func tvJellyfinSubtitleStreamIsExternal(_ stream: JellyfinMediaStream) -> Bool {
    let normalizedType = stream.type.lowercased()
    guard normalizedType == "subtitle" || normalizedType.contains("subtitle") || normalizedType.contains("caption") else {
        return false
    }
    if stream.isExternal == true {
        return true
    }
    if let deliveryURL = stream.deliveryUrl, !deliveryURL.isEmpty {
        return true
    }
    if let deliveryMethod = stream.deliveryMethod?.lowercased(), deliveryMethod.contains("external") {
        return true
    }
    return false
}

private func tvEmbySubtitleStreamIsExternal(_ stream: EmbyMediaStream) -> Bool {
    let normalizedType = stream.type.lowercased()
    guard normalizedType == "subtitle" || normalizedType.contains("subtitle") || normalizedType.contains("caption") else {
        return false
    }
    if stream.isExternal == true {
        return true
    }
    if let deliveryURL = stream.deliveryUrl, !deliveryURL.isEmpty {
        return true
    }
    if let deliveryMethod = stream.deliveryMethod?.lowercased(), deliveryMethod.contains("external") {
        return true
    }
    return false
}

private func tvJellyfinSubtitleURL(
    server: ServerConfig,
    itemId: String,
    mediaSourceId: String,
    stream: JellyfinMediaStream,
    token: String
) -> URL? {
    if let url = tvResolvedMediaServerURL(
        baseURL: server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
        rawPath: stream.deliveryUrl,
        tokenQueryName: "api_key",
        token: token
    ) {
        return url
    }

    guard let index = stream.index else { return nil }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let format = TVMPVSubtitleLoader.fileExtension(forCodec: stream.codec)
    guard var components = URLComponents(string: "\(baseURL)/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(index)/Stream.\(format)") else {
        return nil
    }
    components.queryItems = [URLQueryItem(name: "api_key", value: token)]
    return components.url
}

private func tvEmbySubtitleURL(
    server: ServerConfig,
    itemId: String,
    mediaSourceId: String,
    stream: EmbyMediaStream,
    token: String
) -> URL? {
    if let url = tvResolvedMediaServerURL(
        baseURL: server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
        rawPath: stream.deliveryUrl,
        tokenQueryName: "api_key",
        token: token
    ) {
        return url
    }

    guard let index = stream.index else { return nil }
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let format = TVMPVSubtitleLoader.fileExtension(forCodec: stream.codec)
    guard var components = URLComponents(string: "\(baseURL)/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(index)/Stream.\(format)") else {
        return nil
    }
    components.queryItems = [URLQueryItem(name: "api_key", value: token)]
    return components.url
}

private func tvSubtitleDisplayName(for stream: JellyfinMediaStream) -> String {
    tvSubtitleDisplayName(
        title: stream.displayTitle,
        fallbackTitle: stream.title,
        language: stream.displayLanguage ?? stream.language,
        codec: stream.codec,
        isForced: stream.isForced
    )
}

private func tvSubtitleDisplayName(for stream: EmbyMediaStream) -> String {
    tvSubtitleDisplayName(
        title: stream.displayTitle,
        fallbackTitle: stream.title,
        language: stream.displayLanguage ?? stream.language,
        codec: stream.codec,
        isForced: stream.isForced
    )
}

private func tvSubtitleDisplayName(
    title: String?,
    fallbackTitle: String?,
    language: String?,
    codec: String?,
    isForced: Bool?
) -> String {
    if let title = tvTrimmedPlaybackText(title) ?? tvTrimmedPlaybackText(fallbackTitle) {
        return title
    }

    var pieces: [String] = []
    if let language = tvTrimmedPlaybackText(language) {
        pieces.append(language)
    }
    if let codec = tvTrimmedPlaybackText(codec) {
        pieces.append(codec.uppercased())
    }
    return pieces.isEmpty ? platformShellString("Subtitle") : pieces.joined(separator: " · ")
}

private func tvPlexExternalSubtitleCandidates(
    server: ServerConfig,
    metadata: [String: Any]
) -> [ExternalSubtitleCandidate] {
    guard let media = (metadata["Media"] as? [[String: Any]])?.first,
          let part = (media["Part"] as? [[String: Any]])?.first else {
        return []
    }

    let streams = (part["Stream"] as? [[String: Any]]) ?? []
    let baseURL = server.fullURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let token = tvTrimmedPlaybackText(server.accessToken) ?? tvTrimmedPlaybackText(server.passwordSecret)
    var seen = Set<String>()
    var result: [ExternalSubtitleCandidate] = []

    for stream in streams {
        guard PlexValue.int(stream["streamType"]) == 3 else { continue }
        guard let rawKey = tvTrimmedPlaybackText(PlexValue.string(stream["key"])) else { continue }
        let rawURL = rawKey.hasPrefix("http://") || rawKey.hasPrefix("https://")
            ? rawKey
            : baseURL + (rawKey.hasPrefix("/") ? rawKey : "/\(rawKey)")
        guard var components = URLComponents(string: rawURL) else { continue }
        if let token,
           !(components.queryItems ?? []).contains(where: { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame }) {
            var queryItems = components.queryItems ?? []
            queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
            components.queryItems = queryItems
        }
        guard let url = components.url else { continue }
        let key = tvSubtitleCandidateKey(url)
        guard seen.insert(key).inserted else { continue }

        let displayName = tvSubtitleDisplayName(
            title: PlexValue.string(stream["displayTitle"]) ?? PlexValue.string(stream["extendedDisplayTitle"]),
            fallbackTitle: PlexValue.string(stream["title"]),
            language: PlexValue.string(stream["language"]),
            codec: PlexValue.string(stream["codec"]),
            isForced: PlexValue.bool(stream["forced"])
        )
        result.append(ExternalSubtitleCandidate(url: url, displayName: displayName))
    }

    return result
}

private func tvRemotePlaybackMethod(
    resolvedURL: URL,
    hasDirectStreamURL: Bool
) -> RemotePlaybackMethod {
    let loweredURL = resolvedURL.absoluteString.lowercased()
    if loweredURL.contains("transcode") || loweredURL.contains("m3u8") {
        return .transcode
    }
    return hasDirectStreamURL ? .directStream : .directPlay
}

private struct TVPlaylistOverlay: View {
    @ObservedObject var session: TVPlaybackSession
    @Environment(\.isFocused) private var isFocused
    @Namespace private var playlistFocusNamespace
    #if os(tvOS)
    @Environment(\.resetFocus) private var resetFocus
    #endif

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)
                .ignoresSafeArea()

            HStack {
                Spacer()

                VStack(alignment: .leading, spacing: 24) {
                    Text(platformShellString("Playlist"))
                        .font(.system(size: 42, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 32)
                        .padding(.top, 40)

                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                ForEach(session.playlistItems) { item in
                                    Button(action: {
                                        session.selectPlaylistItem(at: item.index)
                                    }) {
                                        TVPlaybackPlaylistRow(item: item)
                                    }
                                    .buttonStyle(TVPlaybackPlainButtonStyle())
                                    .id(item.index)
                                    .tvPlaybackPrefersDefaultFocusIfAvailable(item.isCurrent, in: playlistFocusNamespace)
                                }
                            }
                            .padding(.horizontal, 32)
                            .padding(.bottom, 60)
                        }
                        .onAppear {
                            if let index = session.playlistItems.first(where: { $0.isCurrent })?.index {
                                proxy.scrollTo(index, anchor: .center)
                            }
                            #if os(tvOS)
                            for delay in [0.0, 0.08, 0.20] {
                                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                    resetFocus(in: playlistFocusNamespace)
                                }
                            }
                            #endif
                        }
                    }
                }
                .frame(width: 800)
                .background(
                    Rectangle()
                        .fill(Color.black.opacity(0.6))
                        .background(Material.regular)
                        .ignoresSafeArea()
                )
                .tvPlaybackFocusScopeIfAvailable(playlistFocusNamespace)
            }
        }
    }
}

extension View {
    @ViewBuilder
    func tvPlaybackOnExitCommand(active: Bool, perform action: @escaping () -> Void) -> some View {
        if active {
            self.onExitCommand(perform: action)
        } else {
            self
        }
    }
}

private struct TVSecondarySubtitleAdjustmentHUD: View {
    @ObservedObject var session: TVPlaybackSession
    @FocusState private var isFocused: Bool
    
    var body: some View {
        VStack {
            Spacer()
            
            HStack(spacing: 24) {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(platformShellString("Adjusting Position"))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundColor(.white)
                    Text(platformShellString("Adjust Position Tip"))
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.7))
                }
                
                Spacer()
                
                Text("\(Int(round(session.currentSecondarySubtitleVerticalPositionRatio() * 100)))%")
                    .font(.system(size: 32, weight: .semibold, design: .monospaced))
                    .foregroundColor(Color(UIColor.systemIndigo))
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(12)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 24)
            .frame(width: 800)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.black.opacity(0.75))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.15), lineWidth: 1)
                    )
            )
            .shadow(color: Color.black.opacity(0.4), radius: 15, x: 0, y: 10)
            .padding(.bottom, 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable(true)
        .focused($isFocused)
        .onAppear {
            isFocused = true
        }
        .onMoveCommand { direction in
            switch direction {
            case .up:
                session.moveSecondarySubtitlePosition(by: -0.01)
                return
            case .down:
                session.moveSecondarySubtitlePosition(by: 0.01)
                return
            default:
                break
            }
        }
        .onPlayPauseCommand {
            session.finishDirectPositionAdjustment()
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                session.finishDirectPositionAdjustment()
            }
        )
    }
}
#endif
