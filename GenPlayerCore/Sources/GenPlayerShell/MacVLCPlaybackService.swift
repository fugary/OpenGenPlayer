#if os(macOS)
import AppKit
import Foundation
import Combine
import AVKit
import AVFoundation
import VLCKitSPM
import MediaPlayer
import CoreMedia
import ImageIO
import GenPlayerCore
import GenPlayerVLCBridge

public class MacVLCPlaybackService: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    public private(set) var mediaPlayer: VLCMediaPlayer?
    @Published public private(set) var isUsingMPV = false
    @Published public private(set) var bufferedRanges: [MPVBufferedRange] = []
    @Published public private(set) var cacheInputBytesPerSecond: Int64?
    @Published public private(set) var cacheReadIdle = false
    @Published public private(set) var diskCacheMode: MacMPVDiskCacheMode = .inactive
    @Published public private(set) var diskCacheBytes: Int64 = 0
    @Published public private(set) var diskCacheReason: MacMPVDiskCacheReason?
    @Published private(set) var vlcVideoViewID = UUID()
    private var pendingVLCVideoStart: UUID?
    @Published private(set) var mpvEngine: MacMPVEngine?
    @Published private(set) var mpvHDRInfo = MPVHDRInfo()
    @Published var nativeASSBounds: CGRect?
    @Published var nativeASSHasContent = false
    @Published var mpvTranslationSourceIsPartial = false
    var mpvTranslationSourceKey: String?
    var mpvTranslationUsesDecodedText = false
    var mpvDecodedSubtitles = MacMPVDecodedSubtitles()
    @Published private(set) var mpvMetadata: [String: String] = [:]
    private var mpvLoaded = false
    private var mpvIPTVSnapshotScheduled = false
    private var mpvServerSubtitlesRegistered = Set<String>()
    @Published private(set) var mpvArtwork: NSImage?
    private var mpvArtworkTask: Task<Void, Never>?

    var playbackArtwork: NSImage? { isUsingMPV ? mpvArtwork : mediaPlayer?.media?.metaData.artwork }
    private var mpvGeneration = UUID()
    private var mpvSeekPreviewURL: URL?
    private var mpvSeekPreviewFile: VideoFile?
    private var mpvSeekPreviewOptions: [String: String] = [:]
    private var mpvSeekPreviewReadCache: MPVReadAheadByteCache?
    private var mpvPauseRequested = false
    private var mpvSubtitleSelectionRequest: UUID?
    var mpvMirroredSecondaryID: Int?
    var mpvMirroredSecondaryText = ""
    var mpvTracks: [MacMPVTrack] = []
    @Published private(set) var mpvSeekable = false
    private var mpvTrackPreferenceKey: String?
    private var mpvTrackChoices: [String: MacMPVTrackChoice] = [:]
    private var mpvPendingTrackChoices: [String: MacMPVTrackChoice] = [:]
    private var mpvApplyingAutomaticSelection = false
    private var mpvPendingImportedSubtitle: URL?
    var mpvSidecarTask: Task<Void, Never>?

    private var engineOverride: (mediaKey: String, engine: PlaybackEngineID)?
    private var rebuildingSession = false
    private var startsPaused = false
    private var pendingEngineTracks: [String: IOSPlaybackTrackSelection] = [:]
    private var pendingPrimarySource: URL?
    private var pendingSecondaryHandoff: IOSPlaybackSecondarySelection?
    private var applyingEngineHandoff = false
    private var pendingAudioOutputRestore = false

    var canSeek: Bool { transport.state.seekable }

    private var transport: any PlaybackTransport {
        if let mpvEngine { return MPVPlaybackTransport(engine: mpvEngine) }
        return VLCPlaybackTransport(player: mediaPlayer)
    }


    @Published public var isPlaying: Bool = false
    @Published public var isLoading: Bool = false
    @Published public var currentTime: Int32 = 0 {
        didSet { audioSubtitles.playbackTime = Double(currentTime) / 1000 }
    }
    @Published public var duration: Int32 = 0
    @Published public var position: Float = 0.0
    @Published public var volume: Int32 = 100
    @Published public var hasReachedEnd: Bool = false
    @Published public var videoNaturalSize: CGSize = .zero

    public var currentFile: VideoFile?
    @Published public var targetRate: Float = 1.0
    public var onDidStartPiP: (() -> Void)?
    
    @Published public var audioTracks: [MediaTrack] = []
    @Published public var subtitleTracks: [MediaTrack] = []
    @Published public var currentAudioTrackID: Int = -1
    @Published public var currentSubtitleTrackID: Int = -1 {
        didSet {
            if oldValue != currentSubtitleTrackID { refreshPrimarySubtitleTranslation() }
        }
    }
    let subtitleTranslation = MacSubtitleTranslation()
    let audioSubtitles = MacAudioSubtitleJob()
    var audioSubtitleTranslationActive = false
    @Published var showAudioSubtitleSheet = false
    var hasPrimarySubtitleForTranslation: Bool {
        currentFile != nil && currentSubtitleTrackID != -1
    }
    internal var translationImportedSubtitleURLs: [Int: URL] = [:]
    internal var subtitleImportQueue = MacSubtitleImportQueue()
    private var subtitleImportPoll: DispatchWorkItem?
    private var subtitleSelectionID = UUID()
    internal var primaryServerSubtitleTracks: [Int: EmbeddedSubtitleTrack] = [:]
    internal var translationPlaybackGeneration = UUID()
    internal var subtitleBrowserRemoteCache: [String: SubtitleBrowserDocument] = [:]
    internal var pendingPrimarySubtitleTranslationRestore = false
    private var isPausedSeek = false
    
    @Published public var secondarySubtitleTracks: [EmbeddedSubtitleTrack] = []
    public enum SecondarySubtitleStatus { case idle, loading, ready, error, unsupported }
    @Published public var secondarySubtitleStatus: SecondarySubtitleStatus = .idle
    @Published public var currentSecondarySubtitleTrackID: String? = nil
    @Published public var currentSecondarySubtitleParts: [SubtitlePart] = []

    public var hasSelectableSubtitles: Bool {
        let selectableTracks = self.subtitleTracks.filter { $0.id != -1 }
        let hasInternal = !selectableTracks.isEmpty
        let hasExternal = !self.translationImportedSubtitleURLs.isEmpty || !self.secondarySubtitleTracks.isEmpty
        return hasInternal || hasExternal || audioSubtitles.canDisplay
    }
    
    public var hasSelectableAudio: Bool {
        let selectableTracks = self.audioTracks.filter { $0.id != -1 }
        return selectableTracks.count > 1
    }

    public var secondarySubtitleTimeline: SubtitleTimeline?
    public var secondarySubtitleLoadTask: Task<Void, Never>?
    private var pendingInitialSeek: TimeInterval?
    private var pendingStopWorkItem: DispatchWorkItem?
    
    public var pendingSecondarySubtitleTrackQuery: String? = nil
    public var pendingSecondarySubtitleTrackOrdinal: Int? = nil
    public var pendingAudioTrackQuery: String? = nil
    public var pendingSubtitleTrackQuery: String? = nil
    public var disableSubtitlesOnStart: Bool = false
    private var hasResolvedAutomaticSubtitleSelection = false
    internal var nativeToExternalTrackIDs: [Int: Int] = [:]
    internal var externalSubtitleResolvedTrackIDs: [String: Int] = [:]

    private var nowPlayingInfo: [String: Any] = [:]
    
    // PiP state
    @Published public var isVideoPiPActive: Bool = false
    @Published public private(set) var playbackFailureID: UUID? = nil
    @Published public var playbackErrorMessage: String? = nil {
        didSet {
            if playbackErrorMessage != oldValue {
                playbackFailureID = playbackErrorMessage.map { _ in UUID() }
            }
        }
    }
    private var startupWatchdogTimer: Timer?
    private var mpvPiPController: MacMPVPictureInPicture?
    private var videoPiPController: MacVLCPlayerPictureInPictureController?
    private var pendingDrawablePlaybackSessionRestoreAfterPictureInPicture = false
    private var isRestoringPlayerFromPictureInPicture = false
    private var pendingPictureInPictureRestoreFile: VideoFile?
    public weak var activeVideoView: VLCVideoView?
    
    // VM / CoreAnimation rendering state
    public weak var activeSampleBufferHostView: MacSampleBufferHostView?
    private var vmFrameBridge: GenPlayerVLCFrameBridge?
    private let vmFrameRenderQueue = DispatchQueue(label: "com.genplayer.mac.vm.frameRender", qos: .userInteractive)
    private var vmCachedFormatDescription: CMVideoFormatDescription?
    private var vmCachedFormatDescriptionDimensions: (Int, Int) = (0, 0)
    
    // History & Sync tracking
    private var lastJellyfinSyncTime: Double = -100
    private var hasReportedServerPlaying: Bool = false
    private var hasStartedPlaybackForCurrentItem: Bool = false
    private var hasRenderedFirstFrame: Bool = false
    private var isUserInitiatedStop: Bool = false
    private var lastSavedHistoryTime: Double = -100
    internal var remoteSecondarySubtitleURLs: [Int: URL] = [:]

    public override init() {
        self.mediaPlayer = VLCPlaybackTransport.makePlayer(options: [
            "--no-snapshot-preview",
            "--no-osd",
            "--no-video-title-show"
        ])
        super.init()
        MacMPVTrackChoice.sanitizeStoredPreferences()
        subtitleTranslation.onResultsChanged = { [weak self] in
            guard let self, self.subtitleTranslation.enabled else { return }
            self.updateCurrentSecondarySubtitleParts(at: Double(self.currentTime) / 1000.0)
            self.objectWillChange.send()
        }
        configureAudioSubtitles()
        self.mediaPlayer?.delegate = self
        self.mediaPlayer?.audio?.volume = self.volume
        setupRemoteCommandCenter()
        configureTextRenderer(for: self.mediaPlayer)
    }

    public func startStartupWatchdog(for file: VideoFile) {
        stopStartupWatchdog()
        let isOfflineLibraryItem = !file.isRemote && (file.jellyfinItemId?.isEmpty == false)
        let timeoutSeconds: TimeInterval
        if file.isLiveStream || file.serverType == .iptv {
            timeoutSeconds = 8.0
        } else if file.serverType?.requiresDynamicPlaybackURL == true {
            timeoutSeconds = 25.0
        } else if file.isRemote {
            timeoutSeconds = 18.0
        } else if isOfflineLibraryItem {
            timeoutSeconds = 10.0
        } else {
            timeoutSeconds = 5.0
        }
        let targetFileId = file.id
        let targetFileName = file.name
        let timer = Timer(timeInterval: timeoutSeconds, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard let currentFile = self.currentFile, currentFile.id == targetFileId else { return }
            guard !self.isUserInitiatedStop else { return }
            
            let isTrulyPlaying = self.isPlaying && (self.hasRenderedFirstFrame || self.currentTime > 500 || currentFile.type == .audio)
            let isActivelyBuffering = self.mediaPlayer?.state == .buffering || self.mediaPlayer?.state == .opening
            if !isTrulyPlaying && !isActivelyBuffering {
                print("[MacVLC] Playback startup timed out for \(targetFileName)")
                self.isLoading = false
                if self.playbackErrorMessage == nil {
                    self.playbackErrorMessage = platformShellString("Playback timed out. The file or stream may be unavailable.")
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        startupWatchdogTimer = timer
    }

    public func stopStartupWatchdog() {
        startupWatchdogTimer?.invalidate()
        startupWatchdogTimer = nil
    }

    public func play(file: VideoFile, forceSwDecoding: Bool = false, preparePlayer: ((VLCMediaPlayer) throws -> Void)? = nil,
                     rebuilding: Bool = false, startPaused: Bool = false) {
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        rebuildingSession = rebuilding
        startsPaused = startPaused
        if !rebuilding {
            pendingEngineTracks.removeAll()
            pendingPrimarySource = nil
            pendingSecondaryHandoff = nil
            pendingAudioOutputRestore = false
        }
        let key = MacMPVTrackChoice.mediaKey(url: file.url, serverID: file.jellyfinServerId,
            itemID: file.jellyfinItemId, path: file.serverPath)
        if engineOverride?.mediaKey != key { engineOverride = nil }
        let wasUsingMPV = isUsingMPV
        let wasWaitingForVLCVideo = pendingVLCVideoStart != nil
        pendingVLCVideoStart = nil
        if isUsingMPV || rebuilding { saveProgress(); reportServerStopped() }
        stopMPVPictureInPicture(restoringWindow: true)
        mpvGeneration = UUID()
        mpvSeekPreviewURL = nil
        mpvSeekPreviewFile = nil
        mpvSeekPreviewOptions = [:]
        mpvSeekPreviewReadCache = nil
        mpvSidecarTask?.cancel(); mpvSidecarTask = nil
        mpvArtworkTask?.cancel(); mpvArtworkTask = nil
        mpvEngine?.stop()
        mpvEngine = nil
        mpvHDRInfo = MPVHDRInfo()
        bufferedRanges = []
        cacheInputBytesPerSecond = nil
        cacheReadIdle = false
        diskCacheMode = .inactive
        diskCacheBytes = 0
        diskCacheReason = nil
        mpvTracks = []
        nativeASSBounds = nil
        nativeASSHasContent = false
        mpvSeekable = false
        let selectedEngine = PlaybackEngineAvailability.current.resolve(
            preferred: engineOverride?.engine.rawValue ?? UserDefaults.standard.string(forKey: "macVideoPlaybackEngine"),
            supportsMPV: MacMPVPlaybackPolicy.supports(url: file.url, isVideo: file.type == .video,
                isLive: file.isLiveStream || file.serverType == .iptv,
                requiresVLCBridge: forceSwDecoding || preparePlayer != nil,
                isVirtualMachine: MacEnvironmentDetector.isVirtualMachine))
        guard let selectedEngine else {
            mediaPlayer?.stop()
            isUsingMPV = false
            currentFile = file
            isLoading = false
            isPlaying = false
            playbackErrorMessage = PlaybackEngineAvailability.unavailableMessage
            return
        }
        isUsingMPV = selectedEngine == .mpv
        let waitsForVLCVideo = !isUsingMPV && (wasUsingMPV || wasWaitingForVLCVideo)
            && file.type == .video && !MacEnvironmentDetector.isVirtualMachine
            && !isPictureInPictureActiveOrStarting
        if rebuilding && isUsingMPV != wasUsingMPV {
            mediaPlayer?.delegate = nil
            mediaPlayer?.stop()
            mediaPlayer?.drawable = nil
            mediaPlayer = VLCPlaybackTransport.makePlayer(options: ["--no-snapshot-preview", "--no-osd", "--no-video-title-show"])
            mediaPlayer?.audio?.volume = volume
        }
        if isUsingMPV || wasUsingMPV {
            // The old VLC view belongs to the removed SwiftUI branch. Never
            // start a replacement player against it (or a nil drawable).
            mediaPlayer?.drawable = nil
            activeVideoView = nil
            vlcVideoViewID = UUID()
        }
        mediaPlayer?.delegate = isUsingMPV ? nil : self
        if isUsingMPV { mediaPlayer?.stop(); mediaPlayer?.media = nil }
        if isUsingMPV || wasUsingMPV {
            clearSecondarySubtitleTrack()
            secondarySubtitleTracks = []
        }
        if currentSecondarySubtitleTrackID == MacAudioSubtitlePlan.secondaryID { clearSecondarySubtitleTrack() }
        if !rebuilding {
            audioSubtitleTranslationActive = false
            audioSubtitles.reset()
            audioSubtitles.setPlaybackReadAheadCache(nil)
        } else if !isUsingMPV {
            // Keep the old cache through same-item MPV rebuilds until the new
            // stream attaches its cache. A rebuild that switches to VLC detaches it.
            audioSubtitles.setPlaybackReadAheadCache(nil)
        }
        if currentSubtitleTrackID == MacAudioSubtitlePlan.primaryID { currentSubtitleTrackID = -1 }
        showAudioSubtitleSheet = false
        self.playbackErrorMessage = nil
        let wasTranslating = subtitleTranslation.enabled
        if !rebuilding || !audioSubtitles.translatesAudio { subtitleTranslation.setEnabled(false) }
        if wasTranslating { clearSecondarySubtitleTrack() }
        translationImportedSubtitleURLs.removeAll()
        resetSubtitleImports()
        primaryServerSubtitleTracks.removeAll()
        translationPlaybackGeneration = UUID()
        subtitleBrowserRemoteCache.removeAll()
        self.currentFile = file
        if !rebuilding { subtitleTranslation.bindPreference(key: primarySubtitleTranslationPreferenceKey(for: file)) }
        pendingPrimarySubtitleTranslationRestore = storedPrimarySubtitleTranslationPreference(for: file)
        isPausedSeek = false
        if !rebuilding { self.videoNaturalSize = .zero }
        self.isUserInitiatedStop = false
        self.hasRenderedFirstFrame = false
        self.hasStartedPlaybackForCurrentItem = false

        // Check local file existence before asking VLC to load
        if !file.isRemote {
            if !FileManager.default.fileExists(atPath: file.url.path) {
                self.isLoading = false
                self.playbackErrorMessage = platformShellString("The local file does not exist or has been deleted.")
                return
            }
        }

        self.isLoading = true
        self.isPlaying = false
        if !isUsingMPV && !waitsForVLCVideo { startStartupWatchdog(for: file) } else { stopStartupWatchdog() }
        self.nativeToExternalTrackIDs.removeAll()
        self.externalSubtitleResolvedTrackIDs.removeAll()
        self.hasResolvedAutomaticSubtitleSelection = false
        configureTextRenderer(for: self.mediaPlayer)
        
        let preferredSecondarySubtitle = self.storedSecondarySubtitlePreference(for: file)
        self.pendingSecondarySubtitleTrackQuery = pendingPrimarySubtitleTranslationRestore ? nil : preferredSecondarySubtitle.query
        self.pendingSecondarySubtitleTrackOrdinal = pendingPrimarySubtitleTranslationRestore ? nil : preferredSecondarySubtitle.ordinal
        
        // Load track query preferences
        let prefs = self.storedTrackQueryPreference(for: file)
        self.pendingAudioTrackQuery = file.preferredAudioTrackQuery ?? prefs.audioQuery
        self.pendingSubtitleTrackQuery = file.preferredSubtitleTrackQuery ?? prefs.subtitleQuery
        self.disableSubtitlesOnStart = file.disableSubtitlesOnStart || (file.preferredSubtitleTrackQuery == nil && prefs.subtitlesDisabled == true)

        let playbackServer = FilePlaybackCredentials.matchingServer(for: file, in: AppNetworkService.shared.servers)
            .map { AppNetworkService.shared.hydratedServer(from: $0) }
        let authenticatedURL = file.isRemote ? FilePlaybackCredentials.runtimeURL(file.url, server: playbackServer) : file.url
        let resolvedRuntimeURL = RuntimeNetworkAddressResolver.runtimeURL(from: authenticatedURL)
        var finalURL = resolvedRuntimeURL
        var smbUser: String? = nil
        var smbPwd: String? = nil
        
        // VLC receives SMB credentials as media options; the mpv reader needs them in its runtime URL.
        if !isUsingMPV, file.url.scheme == "smb",
           var components = URLComponents(url: resolvedRuntimeURL, resolvingAgainstBaseURL: false),
           components.user != nil {
            smbUser = components.user
            smbPwd = components.password
            components.user = nil
            components.password = nil
            finalURL = components.url ?? resolvedRuntimeURL
        }
        
        // Ensure remote media server (Jellyfin / Emby / Plex) URLs carry authentication tokens
        if file.isRemote, finalURL.scheme?.hasPrefix("http") == true {
            let serverType = file.serverType
            let isMediaServer = serverType == .jellyfin || serverType == .emby || serverType == .plex || file.jellyfinItemId != nil || file.jellyfinServerId != nil
            if isMediaServer {
                let allServers = AppNetworkService.shared.servers
                var matchedServer: ServerConfig?
                if let serverId = file.jellyfinServerId {
                    matchedServer = allServers.first(where: { $0.id.uuidString.caseInsensitiveCompare(serverId) == .orderedSame })
                }
                if matchedServer == nil, let host = finalURL.host?.lowercased() {
                    let port = finalURL.port ?? (finalURL.scheme?.lowercased() == "https" ? 443 : 80)
                    matchedServer = allServers.first { s in
                        guard s.type == .jellyfin || s.type == .emby || s.type == .plex else { return false }
                        guard let sComp = URLComponents(string: s.fullURL), let sHost = sComp.host?.lowercased() else { return false }
                        let sPort = sComp.port ?? (sComp.scheme?.lowercased() == "https" ? 443 : 80)
                        return sHost == host && sPort == port
                    }
                }
                let effectiveType = file.serverType ?? matchedServer?.type
                if let token = matchedServer?.accessToken, !token.isEmpty,
                   var components = URLComponents(url: finalURL, resolvingAgainstBaseURL: false) {
                    var items = components.queryItems ?? []
                    if effectiveType == .jellyfin || effectiveType == .emby {
                        let hasApiKey = items.contains(where: { $0.name.caseInsensitiveCompare("api_key") == .orderedSame })
                        if !hasApiKey {
                            items.append(URLQueryItem(name: "api_key", value: token))
                        }
                        if effectiveType == .emby && !items.contains(where: { $0.name.caseInsensitiveCompare("DeviceId") == .orderedSame }) {
                            items.append(URLQueryItem(name: "DeviceId", value: "GenPlayerMac"))
                        }
                        components.queryItems = items
                        if let updated = components.url {
                            finalURL = updated
                        }
                    } else if effectiveType == .plex {
                        let hasPlexToken = items.contains(where: { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame })
                        if !hasPlexToken {
                            items.append(URLQueryItem(name: "X-Plex-Token", value: token))
                            components.queryItems = items
                            if let updated = components.url {
                                finalURL = updated
                            }
                        }
                    }
                }
            }
        }
        
        if finalURL != resolvedRuntimeURL {
            self.currentFile?.url = finalURL
        }
        
        let historyEnabled = HistoryService.isHistoryEnabled(for: file)
        let startPosSeconds: Double
        if file.shouldResetRemotePlayedStateOnPlaybackStart {
            startPosSeconds = 0
        } else {
            let historyPos = historyEnabled ? HistoryService.shared.getLastPlayedPosition(for: file) : nil
            startPosSeconds = file.lastPlayedPosition ?? historyPos ?? 0
        }

        if !rebuilding, file.lastAudioTrack == nil && file.lastSubtitleTrack == nil {
            if let savedTracks = HistoryService.shared.getLastTrackSelection(for: file) {
                if var mut = currentFile {
                    if savedTracks.audio != nil { mut.lastAudioTrack = savedTracks.audio }
                    if savedTracks.subtitle != nil { mut.lastSubtitleTrack = savedTracks.subtitle }
                    self.currentFile = mut
                }
            }
        }

        if isUsingMPV {
            startMPV(file: file, url: finalURL, start: startPosSeconds)
            return
        }

        let media = VLCMedia(url: finalURL)
        var options: [String] = []
        if startPaused { options.append(":start-paused") }
        if file.isRemote {
            let cachingMs = (file.serverType?.requiresDynamicPlaybackURL == true)
                ? (file.type == .audio ? 750 : 1200)
                : 3000
            options.append(":network-caching=\(cachingMs)")
            options.append(":live-caching=\(cachingMs)")
            options.append(":file-caching=\(cachingMs)")
        } else {
            options.append("--network-caching=1500")
        }
        
        if startPosSeconds > 0 {
            options.append(":start-time=\(startPosSeconds)")
        }

        options.append(":clock-jitter=0")
        options.append(":clock-synchro=0")
        
        if let u = smbUser { options.append(":smb-user=\(u)") }
        if let p = smbPwd { options.append(":smb-pwd=\(p)") }
        
        if file.serverType == .pan115 || (file.url.host?.contains("115.com") == true) {
            options.append(":http-user-agent=\(Pan115Manager.defaultUserAgent)")
            options.append(":http-referrer=https://115.com")
            if let serverId = file.jellyfinServerId,
               let server = AppNetworkService.shared.savedServers.first(where: { $0.id.uuidString == serverId }),
               let cookie = server.passwordSecret ?? server.accessToken,
               !cookie.isEmpty {
                options.append(":http-cookie=\(cookie)")
                options.append(":http-cookies=\(cookie)")
            }
        } else if file.serverType == .vod {
            options.append(":http-user-agent=\(VODService.defaultUserAgent)")
        }
        // For PiP mode (forceSwDecoding=true) or Virtual Machine environments,
        // override to software decoding. libvlc_video_set_callbacks (vmem output)
        // only receives frames when VLC uses software decoding.
        let isVM = MacEnvironmentDetector.isVirtualMachine
        let decoder = (forceSwDecoding || isVM) ? "sw" : (UserDefaults.standard.string(forKey: "defaultVideoDecoder") ?? "hw")
        if decoder == "hw" {
            options.append(":avcodec-hw=any")
        } else {
            options.append(":avcodec-hw=none")
            options.append(":codec=avcodec")
        }

        let audioDelay = UserDefaults.standard.double(forKey: "audioDelaySeconds")
        if audioDelay != 0 {
            options.append(":audio-desync=\(Int(audioDelay * 1000))")
        }

        let subtitleDelay = UserDefaults.standard.double(forKey: "subtitleDelaySeconds")
        if subtitleDelay != 0 {
            options.append(":sub-delay=\(subtitleDelay)")
            options.append(":spu-delay=\(Int(subtitleDelay * 1_000_000))")
        }

        options.append(":no-snapshot-preview")
        options.append(":no-osd")
        options.append(":no-video-title-show")

        for option in options {
            media.addOption(option)
        }
        
        media.addOption(":text-renderer=freetype")

        let rateKey = file.type == .audio ? "defaultAudioPlaybackSpeed" : "defaultPlaybackSpeed"
        let savedRate = UserDefaults.standard.double(forKey: rateKey)
        self.targetRate = MPVPlaybackSpeed.clamped(Float(savedRate), maximum: 4)

        let savedRatio = UserDefaults.standard.string(forKey: "defaultVideoAspectRatio") ?? ""
        if savedRatio != "Default" && !savedRatio.isEmpty {
            mediaPlayer?.videoAspectRatio = UnsafeMutablePointer<Int8>(mutating: (savedRatio as NSString).utf8String)
        } else {
            mediaPlayer?.videoAspectRatio = nil
        }

        mediaPlayer?.media = media
        if let preparePlayer, let mediaPlayer {
            try? preparePlayer(mediaPlayer)
        }
        if isVM && !isPictureInPictureActiveOrStarting {
            setupVMFrameBridgeIfNeeded()
        }
        if waitsForVLCVideo {
            pendingVLCVideoStart = mpvGeneration
            let generation = mpvGeneration, viewID = vlcVideoViewID
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pendingVLCVideoStart == generation,
                      let view = self.activeVideoView else { return }
                self.videoViewDidBecomeReady(view, sessionID: viewID)
            }
        } else {
            mediaPlayer?.play()
        }
        
        updateNowPlayingInfo()
        
        hasReachedEnd = false
        hasReportedServerPlaying = false
        hasStartedPlaybackForCurrentItem = false
        pendingInitialSeek = startPosSeconds > 1.0 ? startPosSeconds : nil
        lastJellyfinSyncTime = -100
        lastSavedHistoryTime = -100

        self.currentTime = Int32(startPosSeconds * 1000)
        if !rebuilding { bindAudioSubtitles(for: file) }
        let fileDur = file.duration ?? 0
        if fileDur > 0 {
            self.duration = Int32(fileDur * 1000)
            if startPosSeconds > 0 {
                self.position = Float(startPosSeconds / fileDur)
            } else {
                self.position = 0.0
            }
        } else {
            self.duration = 0
            self.position = 0.0
        }
        
        let trackGeneration = mpvGeneration
        // Setup timers to fetch tracks once media starts parsing
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.mpvGeneration == trackGeneration else { return }
            self.refreshTracks()
        }
        // Retry for remote media that may need more time to expose tracks
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self, self.mpvGeneration == trackGeneration else { return }
            if self.audioTracks.isEmpty || self.subtitleTracks.isEmpty {
                self.refreshTracks()
            }
        }
    }

    public var isNearEnd: Bool {
        guard let file = currentFile, !file.isLiveStream, file.serverType != .iptv else { return false }
        let dur = duration > 0 ? duration : (mediaPlayer?.media?.length.intValue ?? 0)
        guard dur > 0 else { return false }
        let time = currentTime > 0 ? currentTime : (mediaPlayer?.time.intValue ?? 0)
        let pos = position > 0 ? position : (mediaPlayer?.position ?? 0)
        let nearEndTime = time >= max(dur - 3000, Int32(Double(dur) * 0.98))
        let nearEndPos = pos >= 0.98
        return nearEndTime || nearEndPos
    }

    public var shouldRestartFromBeginning: Bool {
        guard currentFile != nil else { return false }
        if isUsingMPV { return hasReachedEnd || playbackErrorMessage != nil }
        if hasReachedEnd || mediaPlayer?.state == .ended {
            return true
        }
        if mediaPlayer?.state == .stopped {
            return true
        }
        if isNearEnd {
            return true
        }
        if mediaPlayer?.state == .error {
            return true
        }
        return false
    }

    public func restartFromBeginning() {
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        hasReachedEnd = false
        playbackErrorMessage = nil
        if var file = currentFile {
            file.lastPlayedPosition = 0
            file.shouldResetRemotePlayedStateOnPlaybackStart = true
            self.currentFile = file
            self.play(file: file)
        }
    }

    public func togglePlayPause() {
        if pendingVLCVideoStart != nil { return }
        if mpvEngine != nil {
            if shouldRestartFromBeginning { restartFromBeginning(); return }
            mpvPauseRequested.toggle()
            if mpvPauseRequested { transport.pause() } else { transport.resume() }
            isPlaying = !mpvPauseRequested
            isLoading = false
            updateNowPlayingInfo()
            reportServerProgress(force: true, reason: "paused")
            return
        }
        if (mediaPlayer?.isPlaying ?? false) {
            if isNearEnd || hasReachedEnd {
                restartFromBeginning()
                return
            }
            transport.pause()
            MPNowPlayingInfoCenter.default().playbackState = .paused
        } else {
            if shouldRestartFromBeginning {
                restartFromBeginning()
                return
            }
            isPausedSeek = false
            transport.resume()
            MPNowPlayingInfoCenter.default().playbackState = .playing
        }
        updateNowPlayingInfo()
    }

    public func pause() {
        if mpvEngine != nil {
            mpvPauseRequested = true
            transport.pause()
            isPlaying = false
            isLoading = false
            saveProgress()
            updateNowPlayingInfo()
            reportServerProgress(force: true, reason: "paused")
            return
        }
        if (mediaPlayer?.isPlaying ?? false) {
            transport.pause()
            MPNowPlayingInfoCenter.default().playbackState = .paused
            updateNowPlayingInfo()
        }
    }

    public func setPosition(_ newPosition: Float) {
        if mpvEngine != nil {
            guard mpvSeekable, duration > 0 else { return }
            let fraction = min(max(newPosition.isFinite ? newPosition : 0, 0), 1)
            hasReachedEnd = false
            position = fraction
            currentTime = Int32(Double(duration) * Double(fraction))
            audioSubtitles.seek(to: Double(currentTime) / 1000)
            transport.seek(to: Double(currentTime) / 1000)
            updateCurrentSecondarySubtitleParts(at: Double(currentTime) / 1000)
            if mpvPauseRequested { isLoading = false }
            return
        }
        if hasReachedEnd || mediaPlayer?.state == .ended || mediaPlayer?.state == .stopped {
            pendingStopWorkItem?.cancel()
            pendingStopWorkItem = nil
            hasReachedEnd = false
            playbackErrorMessage = nil
            if var file = currentFile {
                let dur = duration > 0 ? duration : (mediaPlayer?.media?.length.intValue ?? 0)
                let targetSec = dur > 0 ? Double(newPosition) * Double(dur) / 1000.0 : 0
                file.lastPlayedPosition = targetSec
                if targetSec <= 0.5 {
                    file.shouldResetRemotePlayedStateOnPlaybackStart = true
                }
                self.currentFile = file
                self.play(file: file)
                return
            }
        }

        prepareForSeek()
        let length = mediaPlayer?.media?.length.value?.int32Value ?? 0
        self.position = newPosition
        
        if length > 0 {
            let targetTimeMs = Int32(newPosition * Float(length))
            self.currentTime = targetTimeMs
            transport.seek(to: Double(targetTimeMs) / 1000)
        } else {
            mediaPlayer?.position = newPosition
            if length > 0 {
                self.currentTime = Int32(newPosition * Float(length))
            }
        }
        audioSubtitles.seek(to: Double(currentTime) / 1000)
        self.updateCurrentSecondarySubtitleParts(at: Double(self.currentTime) / 1000.0)
    }

    public func setVolume(_ newVolume: Int32) {
        self.volume = newVolume
        transport.setVolume(newVolume)
    }

    public func stop() {
        pendingVLCVideoStart = nil
        rebuildingSession = false
        pendingEngineTracks.removeAll()
        pendingPrimarySource = nil
        pendingSecondaryHandoff = nil
        pendingAudioOutputRestore = false
        if currentSecondarySubtitleTrackID == MacAudioSubtitlePlan.secondaryID { clearSecondarySubtitleTrack() }
        audioSubtitleTranslationActive = false
        audioSubtitles.reset()
        if currentSubtitleTrackID == MacAudioSubtitlePlan.primaryID { currentSubtitleTrackID = -1 }
        showAudioSubtitleSheet = false
        pendingPrimarySubtitleTranslationRestore = false
        isPausedSeek = false
        subtitleTranslation.setEnabled(false)
        if currentSecondarySubtitleTrackID == MacSubtitleTranslation.trackID { clearSecondarySubtitleTrack() }
        resetSubtitleImports()
        translationPlaybackGeneration = UUID()
        subtitleBrowserRemoteCache.removeAll()
        isUserInitiatedStop = true
        playbackErrorMessage = nil
        stopStartupWatchdog()
        isLoading = false
        saveProgress()
        reportServerStopped()
        stopMPVPictureInPicture()
        mpvGeneration = UUID()
        mpvSeekPreviewURL = nil
        mpvSeekPreviewFile = nil
        mpvSeekPreviewOptions = [:]
        mpvSeekPreviewReadCache = nil
        audioSubtitles.setPlaybackReadAheadCache(nil)
        if isUsingMPV {
            secondarySubtitleLoadTask?.cancel()
            secondarySubtitleLoadTask = nil
            secondarySubtitleTimeline = nil
            mpvMirroredSecondaryID = nil
            mpvMirroredSecondaryText = ""
            mpvSubtitleSelectionRequest = nil
        }
        mpvSidecarTask?.cancel(); mpvSidecarTask = nil
        mpvArtworkTask?.cancel(); mpvArtworkTask = nil
        mpvEngine?.stop()
        mpvEngine = nil
        mpvHDRInfo = MPVHDRInfo()
        bufferedRanges = []
        cacheInputBytesPerSecond = nil
        cacheReadIdle = false
        diskCacheMode = .inactive
        diskCacheBytes = 0
        diskCacheReason = nil
        mpvTracks = []
        nativeASSBounds = nil
        nativeASSHasContent = false
        mpvSeekable = false
        if isUsingMPV {
            translationPlaybackGeneration = UUID()
            subtitleBrowserRemoteCache.removeAll()
        }
        isPlaying = false
        mediaPlayer?.stop()
        activeSampleBufferHostView?.bufferDisplayLayer.flushAndRemoveImage()
        audioTracks = []
        subtitleTracks = []
        currentAudioTrackID = -1
        currentSubtitleTrackID = -1
    }
    
    public struct MacSnapshotDestination {
        public let folderURL: URL
        public let displayName: String
        public let securityScopedURL: URL?
        
        public init(folderURL: URL, displayName: String, securityScopedURL: URL? = nil) {
            self.folderURL = folderURL
            self.displayName = displayName
            self.securityScopedURL = securityScopedURL
        }
    }

    public final class MacSnapshotDestinationManager {
        public static let shared = MacSnapshotDestinationManager()
        
        public let desktopBookmarkKey = "macSnapshotDesktopFolderBookmark"
        public let downloadsBookmarkKey = "macSnapshotDownloadsFolderBookmark"
        public let customBookmarkKey = "macSnapshotCustomFolderBookmark"
        public let customPathKey = "macSnapshotCustomFolderPath"
        public let locationKey = "macSnapshotSaveLocation"
        
        public var containerScreenshotsDirectory: URL {
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let screenshots = pictures.appendingPathComponent("GenPlayer", isDirectory: true)
            try? FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
            return screenshots
        }
        
        public func isLocationAuthorized(_ location: String) -> Bool {
            if location == "desktop" {
                if let url = resolveBookmark(forKey: desktopBookmarkKey) {
                    return isFolderWritable(url)
                }
                if let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
                    return isFolderWritable(desktop)
                }
                return false
            } else if location == "downloads" {
                if let url = resolveBookmark(forKey: downloadsBookmarkKey) {
                    return isFolderWritable(url)
                }
                if let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    return isFolderWritable(downloads)
                }
                return false
            } else if location == "custom" {
                if let url = resolveBookmark(forKey: customBookmarkKey) {
                    return isFolderWritable(url)
                }
                if let customPath = UserDefaults.standard.string(forKey: customPathKey), !customPath.isEmpty {
                    return isFolderWritable(URL(fileURLWithPath: customPath))
                }
                return false
            }
            return false
        }
        
        public func resolveBookmark(forKey key: String) -> URL? {
            guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
            var isStale = false
            do {
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                if isStale {
                    if let freshData = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        UserDefaults.standard.set(freshData, forKey: key)
                    }
                }
                return url
            } catch {
                return nil
            }
        }
        
        public func saveBookmark(for url: URL, key: String) {
            do {
                let bookmarkData = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                UserDefaults.standard.set(bookmarkData, forKey: key)
            } catch {
                print("[Snapshot] Failed to save bookmark for \(url.path): \(error)")
            }
        }
        
        @discardableResult
        public func authorizeFolder(location: String) -> Bool {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true
            panel.prompt = platformShellString("Select")
            panel.message = platformShellString("Choose Screenshot Save Location")
            
            let targetKey: String
            let fallbackURL: URL?
            if location == "downloads" {
                targetKey = downloadsBookmarkKey
                fallbackURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            } else if location == "custom" {
                targetKey = customBookmarkKey
                if let customPath = UserDefaults.standard.string(forKey: customPathKey), !customPath.isEmpty {
                    fallbackURL = URL(fileURLWithPath: customPath)
                } else {
                    fallbackURL = FileManager.default.homeDirectoryForCurrentUser
                }
            } else {
                targetKey = desktopBookmarkKey
                fallbackURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            }
            
            if let fallbackURL = fallbackURL {
                panel.directoryURL = fallbackURL
            }
            
            if panel.runModal() == .OK, let selectedURL = panel.url {
                saveBookmark(for: selectedURL, key: targetKey)
                if location == "custom" {
                    UserDefaults.standard.set(selectedURL.path, forKey: customPathKey)
                }
                UserDefaults.standard.set(location, forKey: locationKey)
                return true
            }
            return false
        }
        
        public func resolveDestination(allowPrompt: Bool = false) -> MacSnapshotDestination {
            let location = UserDefaults.standard.string(forKey: locationKey) ?? "desktop"
            
            if location == "downloads" {
                if let url = resolveBookmark(forKey: downloadsBookmarkKey) {
                    if url.startAccessingSecurityScopedResource() {
                        return MacSnapshotDestination(folderURL: url, displayName: platformShellString("Downloads"), securityScopedURL: url)
                    }
                }
                if let defaultDownloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                    if isFolderWritable(defaultDownloads) {
                        return MacSnapshotDestination(folderURL: defaultDownloads, displayName: platformShellString("Downloads"))
                    }
                }
                if allowPrompt {
                    if authorizeFolder(location: "downloads"), let url = resolveBookmark(forKey: downloadsBookmarkKey) {
                        if url.startAccessingSecurityScopedResource() {
                            return MacSnapshotDestination(folderURL: url, displayName: platformShellString("Downloads"), securityScopedURL: url)
                        }
                    }
                }
            } else if location == "custom" {
                if let url = resolveBookmark(forKey: customBookmarkKey) {
                    if url.startAccessingSecurityScopedResource() {
                        return MacSnapshotDestination(folderURL: url, displayName: url.lastPathComponent, securityScopedURL: url)
                    }
                }
                if let customPath = UserDefaults.standard.string(forKey: customPathKey), !customPath.isEmpty {
                    let url = URL(fileURLWithPath: customPath)
                    if isFolderWritable(url) {
                        return MacSnapshotDestination(folderURL: url, displayName: url.lastPathComponent)
                    }
                }
                if allowPrompt {
                    if authorizeFolder(location: "custom"), let url = resolveBookmark(forKey: customBookmarkKey) {
                        if url.startAccessingSecurityScopedResource() {
                            return MacSnapshotDestination(folderURL: url, displayName: url.lastPathComponent, securityScopedURL: url)
                        }
                    }
                }
            } else {
                // Default: Desktop
                if let url = resolveBookmark(forKey: desktopBookmarkKey) {
                    if url.startAccessingSecurityScopedResource() {
                        return MacSnapshotDestination(folderURL: url, displayName: platformShellString("Desktop"), securityScopedURL: url)
                    }
                }
                if let defaultDesktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
                    if isFolderWritable(defaultDesktop) {
                        return MacSnapshotDestination(folderURL: defaultDesktop, displayName: platformShellString("Desktop"))
                    }
                }
                if allowPrompt {
                    if authorizeFolder(location: "desktop"), let url = resolveBookmark(forKey: desktopBookmarkKey) {
                        if url.startAccessingSecurityScopedResource() {
                            return MacSnapshotDestination(folderURL: url, displayName: platformShellString("Desktop"), securityScopedURL: url)
                        }
                    }
                }
            }
            
            // Fallback: Sandbox container Screenshots folder
            let fallbackURL = containerScreenshotsDirectory
            return MacSnapshotDestination(folderURL: fallbackURL, displayName: platformShellString("Screenshots"))
        }
        
        public func isFolderWritable(_ url: URL) -> Bool {
            let testPath = url.appendingPathComponent(".gp_write_test_\(UUID().uuidString)")
            do {
                try "ok".write(to: testPath, atomically: true, encoding: .utf8)
                try? FileManager.default.removeItem(at: testPath)
                return true
            } catch {
                return false
            }
        }
    }

    private func generateSnapshotURL(in folderURL: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        
        let rawName = currentFile?.url.deletingPathExtension().lastPathComponent ?? "video"
        let safeName = rawName.replacingOccurrences(of: "[^\\w\\-]", with: "_", options: .regularExpression)
        let truncated = String(safeName.prefix(50))
        let fileName = "GenPlayer_\(truncated)_\(formatter.string(from: Date())).png"
        return folderURL.appendingPathComponent(fileName)
    }

    private func generateProcessedTempSnapshot(
        prefix: String,
        renderTargetPixelSize: NSSize? = nil,
        completion: @escaping (URL?) -> Void
    ) {
        if isUsingMPV {
            guard let engine = mpvEngine else { completion(nil); return }
            let generation = mpvGeneration
            let parts = usesMPVTextSecondary ? currentSecondarySubtitleParts : []
            let primary = generatedPrimaryParts
            let defaults = UserDefaults.standard
            let ratio = defaults.object(forKey: "secondarySubtitleVerticalPositionRatio.landscape") as? Double ?? -1
            let scale = defaults.object(forKey: "secondarySubtitleSizeScale") as? Double ?? 1
            let reference = engine.videoView?.bounds.size ?? .zero
            engine.snapshot { [weak self] url in
                guard let self, self.isUsingMPV, self.mpvGeneration == generation else {
                    if let url { try? FileManager.default.removeItem(at: url) }
                    completion(nil); return
                }
                guard let url else { completion(nil); return }
                DispatchQueue.global(qos: .userInitiated).async {
                    self.processAndOptimizeSnapshot(onFileAt: url, parts: parts, enableSecondary: !parts.isEmpty,
                        positionRatio: ratio, sizeScale: scale, overlayReferenceSize: reference,
                        renderTargetPixelSize: renderTargetPixelSize, primaryParts: primary)
                    DispatchQueue.main.async {
                        guard self.mpvGeneration == generation else {
                            try? FileManager.default.removeItem(at: url); completion(nil); return
                        }
                        completion(url)
                    }
                }
            }
            return
        }
        guard (mediaPlayer?.hasVideoOut ?? false), mediaPlayer?.state != .stopped, mediaPlayer?.state != .ended, mediaPlayer?.state != .error else {
            completion(nil)
            return
        }
        
        let tempSnapshotURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenPlayer_\(prefix)_\(UUID().uuidString).png")
        
        mediaPlayer?.saveVideoSnapshot(at: tempSnapshotURL.path, withWidth: 0, andHeight: 0)
        
        let parts = self.currentSecondarySubtitleParts
        let enableSecondary = UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta")
        var posRatio: Double = -1.0
        if UserDefaults.standard.object(forKey: "secondarySubtitleVerticalPositionRatio.landscape") != nil {
            posRatio = UserDefaults.standard.double(forKey: "secondarySubtitleVerticalPositionRatio.landscape")
        } else if UserDefaults.standard.object(forKey: "secondarySubtitleVerticalPositionRatio") != nil {
            posRatio = UserDefaults.standard.double(forKey: "secondarySubtitleVerticalPositionRatio")
        }
        let sizeScale = UserDefaults.standard.double(forKey: "secondarySubtitleSizeScale")
        let overlayReferenceSize = activeVideoView?.bounds.size ?? .zero
        
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var fileReady = false
            for i in 0..<50 {
                if FileManager.default.fileExists(atPath: tempSnapshotURL.path) {
                    if let attrs = try? FileManager.default.attributesOfItem(atPath: tempSnapshotURL.path),
                       let size = attrs[.size] as? UInt64, size > 0 {
                        fileReady = true
                        break
                    }
                }
                if i == 2 || i == 6 || i == 14 {
                    // If paused/pausing and file hasn't appeared yet, nudge libvlc vout by advancing one frame
                    DispatchQueue.main.async { [weak self] in
                        if self?.mediaPlayer?.state == .paused || (self?.mediaPlayer?.isPlaying ?? false) == false {
                            self?.mediaPlayer?.gotoNextFrame()
                        }
                    }
                }
                Thread.sleep(forTimeInterval: 0.03)
            }
            
            guard fileReady, let self = self else {
                try? FileManager.default.removeItem(at: tempSnapshotURL)
                DispatchQueue.main.async { completion(nil) }
                return
            }
            
            self.processAndOptimizeSnapshot(
                onFileAt: tempSnapshotURL,
                parts: parts,
                enableSecondary: enableSecondary && !parts.isEmpty,
                positionRatio: CGFloat(posRatio),
                sizeScale: CGFloat(sizeScale > 0 ? sizeScale : 1.0),
                overlayReferenceSize: overlayReferenceSize,
                renderTargetPixelSize: renderTargetPixelSize
            )
            
            DispatchQueue.main.async {
                completion(tempSnapshotURL)
            }
        }
    }

    public func takeSnapshot(completion: @escaping (URL?, String) -> Void) {
        generateProcessedTempSnapshot(prefix: "snap") { [weak self] tempSnapshotURL in
            guard let tempSnapshotURL = tempSnapshotURL, let self = self else {
                completion(nil, "")
                return
            }
            
            let destination = MacSnapshotDestinationManager.shared.resolveDestination(allowPrompt: false)
            let outputURL = self.generateSnapshotURL(in: destination.folderURL)
            
            do {
                try FileManager.default.createDirectory(at: destination.folderURL, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: outputURL.path) {
                    try? FileManager.default.removeItem(at: outputURL)
                }
                try FileManager.default.copyItem(at: tempSnapshotURL, to: outputURL)
                try? FileManager.default.removeItem(at: tempSnapshotURL)
                destination.securityScopedURL?.stopAccessingSecurityScopedResource()
                completion(outputURL, destination.displayName)
            } catch {
                print("[Snapshot] Failed copying to \(outputURL.path): \(error). Falling back to container screenshots.")
                let fallbackDir = MacSnapshotDestinationManager.shared.containerScreenshotsDirectory
                try? FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
                let fallbackURL = self.generateSnapshotURL(in: fallbackDir)
                let saved = (try? FileManager.default.copyItem(at: tempSnapshotURL, to: fallbackURL)) != nil
                try? FileManager.default.removeItem(at: tempSnapshotURL)
                destination.securityScopedURL?.stopAccessingSecurityScopedResource()
                completion(saved ? fallbackURL : nil, platformShellString("Screenshots"))
            }
        }
    }

    public func captureLiveTextFrame(completion: @escaping (NSImage?) -> Void) {
        // The image is presented at the current player size in the Live Text
        // viewer. Render a larger canvas when the video source is lower
        // resolution than that view so the custom subtitle glyphs are not
        // enlarged after they have already been rasterized.
        let renderTargetPixelSize = liveTextRenderTargetPixelSize()
        generateProcessedTempSnapshot(
            prefix: "livetext",
            renderTargetPixelSize: renderTargetPixelSize
        ) { tempSnapshotURL in
            guard let tempSnapshotURL = tempSnapshotURL else {
                completion(nil)
                return
            }
            
            let image = NSImage(contentsOf: tempSnapshotURL)
            if let image = image, let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
                image.size = NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
            }
            try? FileManager.default.removeItem(at: tempSnapshotURL)
            
            completion(image)
        }
    }

    private func processAndOptimizeSnapshot(
        onFileAt fileURL: URL,
        parts: [SubtitlePart],
        enableSecondary: Bool,
        positionRatio: CGFloat,
        sizeScale: CGFloat,
        overlayReferenceSize: CGSize,
        renderTargetPixelSize: NSSize?,
        primaryParts: [SubtitlePart] = []
    ) {
        guard (enableSecondary && !parts.isEmpty) || !primaryParts.isEmpty else { return }
        guard let originalImage = NSImage(contentsOf: fileURL) else { return }
        
        let texts = parts.compactMap { part -> String? in
            guard let text = part.text?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            let isDrawingCommand = text.hasPrefix("m ") ||
                (text.contains(" m ") && text.range(of: #"[0-9\-\s]+$"#, options: .regularExpression) != nil)
            return isDrawingCommand ? nil : text
        }
        guard !texts.isEmpty || !primaryParts.isEmpty else { return }
        
        let originalRep = originalImage.representations.first
        let pixelWidth = originalRep?.pixelsWide ?? Int(originalImage.size.width)
        let pixelHeight = originalRep?.pixelsHigh ?? Int(originalImage.size.height)
        guard pixelWidth > 0, pixelHeight > 0 else { return }
        let sourceImageSize = NSSize(width: pixelWidth, height: pixelHeight)
        let imageSize = snapshotPixelSize(
            sourceImageSize: sourceImageSize,
            renderTargetPixelSize: renderTargetPixelSize
        )
        let outputPixelWidth = Int(imageSize.width.rounded(.up))
        let outputPixelHeight = Int(imageSize.height.rounded(.up))
        
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: outputPixelWidth,
            pixelsHigh: outputPixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        bitmapRep.size = imageSize
        
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        NSGraphicsContext.current = context
        
        // Live Text uses the whole player canvas, including its letterbox area.
        // The subtitle overlay is positioned in that same coordinate space.
        NSColor.black.setFill()
        NSRect(origin: .zero, size: imageSize).fill()
        let videoScale = min(imageSize.width / sourceImageSize.width, imageSize.height / sourceImageSize.height)
        let videoSize = NSSize(width: sourceImageSize.width * videoScale, height: sourceImageSize.height * videoScale)
        originalImage.draw(in: NSRect(
            x: (imageSize.width - videoSize.width) / 2,
            y: (imageSize.height - videoSize.height) / 2,
            width: videoSize.width,
            height: videoSize.height
        ))
        
        let resolvedScale = sizeScale > 0 ? sizeScale : 1.0
        let snapshotScale: CGFloat
        if overlayReferenceSize.height > 1 {
            snapshotScale = imageSize.height / overlayReferenceSize.height
        } else {
            snapshotScale = max(1, imageSize.height / 720)
        }
        if !primaryParts.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black; shadow.shadowBlurRadius = 2 * snapshotScale
            let text = NSAttributedString(string: primaryParts.compactMap { $0.text?.string }.joined(separator: "\n"),
                attributes: [.font: NSFont.systemFont(ofSize: 22 * snapshotScale, weight: .medium),
                    .foregroundColor: NSColor.white, .paragraphStyle: paragraph, .shadow: shadow])
            let width = max(1, imageSize.width - 48 * snapshotScale)
            let rect = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading])
            text.draw(in: NSRect(x: (imageSize.width - width) / 2, y: 28 * snapshotScale, width: width, height: rect.height))
        }
        let fontSize = Self.secondarySubtitleBaseFontSize(
            forContainerHeight: overlayReferenceSize.height
        ) * resolvedScale * snapshotScale
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        paragraphStyle.lineBreakMode = .byWordWrapping
        let maxTextWidth = max(100, imageSize.width - 72 * snapshotScale)
        
        let referenceHeight = overlayReferenceSize.height > 1 ? overlayReferenceSize.height : imageSize.height / snapshotScale
        let centerYFromBottom = imageSize.height - Self.secondarySubtitleCenterY(
            containerHeight: referenceHeight,
            positionRatio: positionRatio
        ) * snapshotScale
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraphStyle
        ]
        let attributedTexts = texts.map { NSAttributedString(string: $0, attributes: attributes) }
        let textRects = attributedTexts.map {
            $0.boundingRect(
                with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
        }
        let spacing = 2 * snapshotScale
        let totalHeight = textRects.reduce(CGFloat(0)) { $0 + $1.height } +
            CGFloat(max(0, textRects.count - 1)) * spacing
        var currentY = centerYFromBottom + totalHeight / 2

        for (attributedText, textRect) in zip(attributedTexts, textRects) {
            currentY -= textRect.height
            let drawRect = NSRect(
                x: (imageSize.width - textRect.width) / 2,
                y: currentY,
                width: textRect.width,
                height: textRect.height
            )

            for offset in [
                NSSize(width: 0, height: 1),
                NSSize(width: 0, height: -1),
                NSSize(width: 1, height: 0),
                NSSize(width: -1, height: 0)
            ] {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.88)
                shadow.shadowOffset = NSSize(
                    width: offset.width * snapshotScale,
                    height: offset.height * snapshotScale
                )
                shadow.shadowBlurRadius = snapshotScale
                shadow.set()
                attributedText.draw(in: drawRect)
                NSGraphicsContext.restoreGraphicsState()
            }
            attributedText.draw(in: drawRect)
            currentY -= spacing
        }
        
        NSGraphicsContext.restoreGraphicsState()
        
        if let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            try? pngData.write(to: fileURL, options: .atomic)
        }
    }

    private func liveTextRenderTargetPixelSize() -> NSSize? {
        guard let videoView: NSView = isUsingMPV ? mpvEngine?.videoView : activeVideoView else { return nil }
        let viewSize = videoView.bounds.size
        guard viewSize.width > 1, viewSize.height > 1 else { return nil }

        let backingScale = videoView.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        return NSSize(
            width: (viewSize.width * backingScale).rounded(.up),
            height: (viewSize.height * backingScale).rounded(.up)
        )
    }

    private func snapshotPixelSize(
        sourceImageSize: NSSize,
        renderTargetPixelSize: NSSize?
    ) -> NSSize {
        guard let renderTargetPixelSize,
              sourceImageSize.width > 1,
              sourceImageSize.height > 1,
              renderTargetPixelSize.width > 1,
              renderTargetPixelSize.height > 1 else {
            return sourceImageSize
        }

        // Preserve the player aspect ratio, not just the source-video aspect
        // ratio; otherwise fitting the result shifts the subtitle overlay.
        return NSSize(
            width: renderTargetPixelSize.width.rounded(.up),
            height: renderTargetPixelSize.height.rounded(.up)
        )
    }

    static func secondarySubtitleCenterY(containerHeight: CGFloat, positionRatio: CGFloat) -> CGFloat {
        guard containerHeight > 0 else { return 0 }
        let centerY = positionRatio >= 0 ? containerHeight * positionRatio : containerHeight - 92
        return min(max(centerY, 32), max(32, containerHeight - 32))
    }

    static func secondarySubtitleBaseFontSize(forContainerHeight height: CGFloat) -> CGFloat {
        guard height > 1 else { return 22 }
        return min(max(height * 0.035, 18), 34)
    }
    
    public func captureIPTVSnapshotIfNeeded() {
        if let engine = mpvEngine {
            guard isPlaying, let file = currentFile, file.isLiveStream || file.serverType == .iptv,
                  let channel = file.jellyfinItemId, let server = file.jellyfinServerId.flatMap(UUID.init(uuidString:)) else { return }
            let generation = mpvGeneration
            engine.snapshot { [weak self] url in
                guard let url else { return }
                defer { try? FileManager.default.removeItem(at: url) }
                guard let self, self.mpvGeneration == generation,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: 480,
                        kCGImageSourceCreateThumbnailWithTransform: true
                      ] as CFDictionary),
                      let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                _ = IPTVArtworkService.shared.saveSnapshot(data: data, for: channel, in: server)
            }
            return
        }
        guard (mediaPlayer?.hasVideoOut ?? false),
              (mediaPlayer?.isPlaying ?? false),
              let file = currentFile,
              file.isLiveStream || file.serverType == .iptv,
              let channelId = file.jellyfinItemId,
              let serverIdStr = file.jellyfinServerId,
              let serverId = UUID(uuidString: serverIdStr) else {
            return
        }
        let targetPath = IPTVArtworkService.shared.snapshotPath(for: channelId, in: serverId)
        let parentDir = URL(fileURLWithPath: targetPath).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
        
        mediaPlayer?.saveVideoSnapshot(at: targetPath, withWidth: 480, andHeight: 270)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            IPTVArtworkService.shared.notifySnapshotSaved()
        }
    }
    
    public func setAudioTrack(_ id: Int) {
        if !applyingEngineHandoff { pendingEngineTracks["audio"] = nil }
        if mpvEngine != nil {
            guard id == -1 || audioTracks.contains(where: { $0.id == id }) else { return }
            pendingAudioTrackQuery = nil
            mpvPendingTrackChoices["audio"] = nil
            saveMPVTrackChoice(slot: "audio", id: id)
            transport.selectAudioTrack(id)
            currentAudioTrackID = id
            audioSubtitles.refreshDefaultAudioTrack()
            if let file = currentFile { saveTrackQueryPreferenceIfNeeded(for: file) }
            return
        }
        transport.selectAudioTrack(id)
        currentAudioTrackID = id
        audioSubtitles.refreshDefaultAudioTrack()
        if let file = currentFile {
            saveSeriesTrackPreferenceIfNeeded(for: file)
        }
    }
    
    internal func activateConfiguredAudioPrimary() {
        resetSubtitleImports()
        subtitleSelectionID = UUID()
        pendingSubtitleTrackQuery = nil
        disableSubtitlesOnStart = false
        hasResolvedAutomaticSubtitleSelection = true
        if let mpvEngine {
            mpvPendingTrackChoices["primary"] = nil
            mpvPendingImportedSubtitle = nil
            mpvEngine.set("sid", "no")
        } else { mediaPlayer?.currentVideoSubTitleIndex = -1 }
        currentSubtitleTrackID = MacAudioSubtitlePlan.primaryID
        if isUsingMPV { applyMPVSubtitleSelection() }
    }

    public func setSubtitleTrack(_ id: Int) {
        if !applyingEngineHandoff { pendingEngineTracks["sub"] = nil; pendingPrimarySource = nil }
        guard canSelectMPVSubtitle(id, secondary: false) else { return }
        hasResolvedAutomaticSubtitleSelection = true
        pendingSubtitleTrackQuery = nil
        if audioSubtitles.isConfigured {
            if id == MacAudioSubtitlePlan.primaryID { audioSubtitles.setOriginalDestination(.primary); return }
            audioSubtitles.release(.primary)
        }
        if id == MacAudioSubtitlePlan.primaryID {
            guard audioSubtitles.canDisplay else { return }
            resetSubtitleImports()
            subtitleSelectionID = UUID()
            pendingSubtitleTrackQuery = nil
            disableSubtitlesOnStart = false
            hasResolvedAutomaticSubtitleSelection = true
            if currentSecondarySubtitleTrackID == MacAudioSubtitlePlan.secondaryID { clearSecondarySubtitleTrack() }
            if let mpvEngine {
                mpvPendingTrackChoices["primary"] = nil
                mpvPendingImportedSubtitle = nil
                mpvEngine.set("sid", "no")
            } else { mediaPlayer?.currentVideoSubTitleIndex = -1 }
            currentSubtitleTrackID = id
            if isUsingMPV { applyMPVSubtitleSelection() }
            if audioSubtitles.display != .primary { audioSubtitles.select(.primary) }
            restorePendingPrimarySubtitleTranslationIfNeeded()
            return
        }
        if audioSubtitles.display == .primary { audioSubtitles.select(.off) }
        if id == -1 {
            pendingPrimarySubtitleTranslationRestore = false
            if let file = currentFile { savePrimarySubtitleTranslationPreference(for: file, enabled: false) }
        }
        if mpvEngine != nil {
            guard id == -1 || subtitleTracks.contains(where: { $0.id == id }) else { return }
            pendingSubtitleTrackQuery = nil
            mpvPendingTrackChoices["primary"] = nil
            mpvPendingImportedSubtitle = nil
            hasResolvedAutomaticSubtitleSelection = true
            disableSubtitlesOnStart = id == -1
            if !mpvApplyingAutomaticSelection { saveMPVTrackChoice(slot: "primary", id: id) }
            subtitleSelectionID = UUID()
            currentSubtitleTrackID = id
            applyMPVSubtitleSelection()
            refreshPrimarySubtitleTranslation()
            if let file = currentFile { saveTrackQueryPreferenceIfNeeded(for: file) }
            return
        }
        subtitleSelectionID = UUID()
        if id >= 10000 {
            guard let url = remoteSecondarySubtitleURLs[id] else { return }
            let key = subtitleURLKey(url)
            currentSubtitleTrackID = id
            if let resolved = externalSubtitleResolvedTrackIDs[key] {
                mediaPlayer?.currentVideoSubTitleIndex = Int32(resolved)
            } else {
                enqueueSubtitleImport(url: url, primaryTrackID: id)
            }
            if let file = currentFile { saveSeriesTrackPreferenceIfNeeded(for: file) }
            return
        }
        mediaPlayer?.currentVideoSubTitleIndex = Int32(id)
        currentSubtitleTrackID = id
        if let file = currentFile {
            saveSeriesTrackPreferenceIfNeeded(for: file)
        }
    }
    
    public func setSecondarySubtitleTrack(_ id: String?, persistTranslationPreference: Bool = true) {
        if !applyingEngineHandoff { pendingSecondaryHandoff = nil }
        if let id, let trackID = Int(id.replacingOccurrences(of: "mpv-", with: "")) {
            guard canSelectMPVSubtitle(trackID, secondary: true) else { return }
        }
        if audioSubtitles.isConfigured {
            if id == MacAudioSubtitlePlan.secondaryID { audioSubtitles.setOriginalDestination(.secondary); return }
            if id == MacSubtitleTranslation.trackID && audioSubtitles.translatesAudio {
                audioSubtitles.setTranslationDestination(.secondary)
                return
            }
            audioSubtitles.release(.secondary)
            if id == MacSubtitleTranslation.trackID && audioSubtitles.isConfigured {
                audioSubtitles.select(audioSubtitles.uses(.primary) ? .primary : .off)
            }
        }
        if id == MacAudioSubtitlePlan.secondaryID {
            guard audioSubtitles.canDisplay, UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta") else { return }
            clearSecondarySubtitleTrack()
            pendingPrimarySubtitleTranslationRestore = false
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            if let file = currentFile { savePrimarySubtitleTranslationPreference(for: file, enabled: false) }
            currentSecondarySubtitleTrackID = id
            secondarySubtitleStatus = .ready
            if audioSubtitles.display != .secondary { audioSubtitles.select(.secondary) }
            updateCurrentSecondarySubtitleParts(at: Double(currentTime) / 1000)
            return
        }
        if audioSubtitles.display == .secondary ||
            (audioSubtitles.display == .translatedSecondary && id != MacSubtitleTranslation.trackID) { audioSubtitles.select(.off) }
        if id == MacSubtitleTranslation.trackID {
            guard #available(macOS 15.0, *), (hasPrimarySubtitleForTranslation || audioSubtitles.display == .translatedSecondary),
                  UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta") else { return }
            pendingPrimarySubtitleTranslationRestore = false
            if let file = currentFile { savePrimarySubtitleTranslationPreference(for: file, enabled: audioSubtitles.display != .translatedSecondary) }
            secondarySubtitleLoadTask?.cancel()
            secondarySubtitleTimeline = nil
            currentSecondarySubtitleParts = []
            secondarySubtitleStatus = .idle
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            clearMPVSecondarySelection(persistPreference: false)
            currentSecondarySubtitleTrackID = id
            subtitleTranslation.setEnabled(true)
            refreshPrimarySubtitleTranslation()
            return
        }
        if persistTranslationPreference {
            pendingPrimarySubtitleTranslationRestore = false
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            if let file = currentFile { savePrimarySubtitleTranslationPreference(for: file, enabled: false) }
        }
        if !(audioSubtitles.isConfigured && audioSubtitles.translatesAudio) { subtitleTranslation.setEnabled(false) }
        if mpvEngine != nil {
            let track = secondarySubtitleTracks.first { $0.id == id }
            guard id == nil || (UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta") && track != nil) else { return }
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            mpvPendingTrackChoices["secondary"] = nil
            saveMPVTrackChoice(slot: "secondary", id: track?.primaryTrackID ?? -1)
            currentSecondarySubtitleTrackID = track?.id
            applyMPVSubtitleSelection()
            updateMPVSecondaryStyle()
            secondarySubtitleStatus = track == nil ? .idle : .ready
            currentSecondarySubtitleParts = []
            if let file = currentFile { saveStoredSecondarySubtitlePreference(for: file, track: track) }
            return
        }
        currentSecondarySubtitleTrackID = id
        if id == nil {
            secondarySubtitleLoadTask?.cancel()
            secondarySubtitleTimeline = nil
            currentSecondarySubtitleParts = []
            secondarySubtitleStatus = .idle
            if let file = currentFile {
                saveStoredSecondarySubtitlePreference(for: file, track: nil)
            }
            return
        }
        
        guard let track = self.secondarySubtitleTracks.first(where: { $0.id == id }) else {
            secondarySubtitleLoadTask?.cancel()
            secondarySubtitleTimeline = nil
            currentSecondarySubtitleParts = []
            secondarySubtitleStatus = .unsupported
            if let file = currentFile {
                saveStoredSecondarySubtitlePreference(for: file, track: nil)
            }
            return
        }
        
        if let file = currentFile {
            saveStoredSecondarySubtitlePreference(for: file, track: track)
        }
        
        loadSecondarySubtitleTimeline(for: track)
    }
    
    internal func updateCurrentSecondarySubtitleParts(at time: Double) {
        if audioSubtitles.isConfigured {
            let primaryTime = time - UserDefaults.standard.double(forKey: "subtitleDelaySeconds")
            let secondaryTime = primaryTime - UserDefaults.standard.double(forKey: "secondarySubtitleDelaySeconds")
            subtitleTranslation.playbackTime = audioSubtitles.activeTranslationDestination == .primary ? primaryTime : secondaryTime
            if audioSubtitles.uses(.secondary) {
                let parts = subtitleTranslation.audioParts(at: secondaryTime, cues: audioSubtitles.cues,
                    original: audioSubtitles.activeOriginalDestination == .secondary,
                    translated: audioSubtitles.activeTranslationDestination == .secondary)
                if currentSecondarySubtitleParts != parts { currentSecondarySubtitleParts = parts }
                return
            }
        }
        if currentSecondarySubtitleTrackID == MacAudioSubtitlePlan.secondaryID {
            let effective = time - UserDefaults.standard.double(forKey: "subtitleDelaySeconds")
                - UserDefaults.standard.double(forKey: "secondarySubtitleDelaySeconds")
            let parts = audioSubtitles.activeCues(at: effective).map {
                SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text))
            }
            if currentSecondarySubtitleParts != parts { currentSecondarySubtitleParts = parts }
            return
        }
        if subtitleTranslation.enabled && (!audioSubtitles.isConfigured || !audioSubtitles.hasActiveOutput) {
            let primaryDelay = UserDefaults.standard.double(forKey: "subtitleDelaySeconds")
            let secondaryDelay = UserDefaults.standard.double(forKey: "secondarySubtitleDelaySeconds")
            let effectiveTime = (isUsingMPV || currentSubtitleTrackID == MacAudioSubtitlePlan.primaryID || audioSubtitles.display == .translatedSecondary)
                ? time - primaryDelay - secondaryDelay : time + primaryDelay + secondaryDelay
            subtitleTranslation.playbackTime = effectiveTime
            let parts = subtitleTranslation.activeParts(at: effectiveTime, content: .translated)
            if currentSecondarySubtitleParts != parts { currentSecondarySubtitleParts = parts }
            return
        }
        if isUsingMPV {
            if mpvMirroredSecondaryID != nil { updateMPVMirroredSecondaryParts(at: time) }
            return // Other native text comes from mpv's time-adjusted decoder.
        }
        guard let timeline = secondarySubtitleTimeline else {
            if !currentSecondarySubtitleParts.isEmpty {
                currentSecondarySubtitleParts = []
                secondarySubtitleStatus = .idle
            }
            return
        }
        let primaryDelay = UserDefaults.standard.double(forKey: "subtitleDelaySeconds")
        let secondaryDelay = UserDefaults.standard.double(forKey: "secondarySubtitleDelaySeconds")
        let effectiveTime = MPVSecondarySubtitleRendering.sourceTime(playbackTime: time,
            primary: primaryDelay, secondary: secondaryDelay)
        let active = timeline.activeParts(at: effectiveTime)
        if currentSecondarySubtitleParts != active {
            currentSecondarySubtitleParts = active
        }
    }
    
    public func setPlaybackRate(_ rate: Float) {
        targetRate = MPVPlaybackSpeed.clamped(rate, maximum: isUsingMPV ? 8 : 4)
        transport.setRate(targetRate)
    }
    
    public func refreshTracks() {
        guard !isUsingMPV else { return }
        let generation = translationPlaybackGeneration
        guard let media = mediaPlayer?.media else { return }
        
        let audioTrackNames = mediaPlayer?.audioTrackNames as? [String] ?? []
        let audioTrackIndexes = mediaPlayer?.audioTrackIndexes as? [NSNumber] ?? []
        var newAudioTracks: [MediaTrack] = []
        for i in 0..<min(audioTrackNames.count, audioTrackIndexes.count) {
            let name = audioTrackNames[i]
            let id = audioTrackIndexes[i].intValue
            if name.lowercased() == "disable" || id == -1 { continue }
            newAudioTracks.append(MediaTrack(id: id, name: name, isExternal: false))
        }
        
        let subtitleTrackNames = mediaPlayer?.videoSubTitlesNames as? [String] ?? []
        let subtitleTrackIndexes = mediaPlayer?.videoSubTitlesIndexes as? [NSNumber] ?? []
        var newSubtitleTracks: [MediaTrack] = []
        for i in 0..<min(subtitleTrackNames.count, subtitleTrackIndexes.count) {
            let name = subtitleTrackNames[i]
            let id = subtitleTrackIndexes[i].intValue
            if name.lowercased() == "disable" || id == -1 { continue }
            newSubtitleTracks.append(MediaTrack(id: id, name: name, isExternal: false))
        }
        
        // Refresh Secondary Tracks from Local Container
        var newSecondaryTracks: [MediaTrack] = []
        self.remoteSecondarySubtitleURLs.removeAll()
        
        if let url = currentFile?.url {
            let descriptors = SharedLocalEmbeddedSubtitleExtractor.descriptors(for: url)
            for desc in descriptors {
                if desc.supportLevel == .textSupported || desc.supportLevel == .textBestEffort {
                    newSecondaryTracks.append(MediaTrack(id: desc.trackIndex, name: desc.title ?? "Subtitle \(desc.trackIndex)", isExternal: false))
                }
            }
        }
        

        
        
        
        var newExternalTracks: [MediaTrack] = []
        var seenURLs = Set<URL>()
        
        if let candidates = currentFile?.externalSubtitleCandidates {
            for (index, candidate) in candidates.enumerated() {
                let id = 10000 + index
                newExternalTracks.append(MediaTrack(id: id, name: candidate.displayName, isExternal: true))
                self.remoteSecondarySubtitleURLs[id] = candidate.url
                seenURLs.insert(candidate.url)
            }
        }
        
        // Add embedded server media streams for Jellyfin/Emby
        if currentFile?.serverMediaStreams == nil {
            fetchServerMediaStreamsIfNeeded()
        }
        
        primaryServerSubtitleTracks.removeAll()
        if let item = currentFile {
            for (index, track) in embeddedServerSubtitleTracks(for: item).enumerated() {
                guard let url = track.sourceURL else { continue }
                let id = 20000 + index
                primaryServerSubtitleTracks[id] = track
                remoteSecondarySubtitleURLs[id] = url
                if seenURLs.insert(url).inserted {
                    let stream = item.serverMediaStreams?.first { ($0["Index"] as? Int) == track.streamIndex }
                    let name = stream.flatMap { formattedServerSubtitleTrackDisplayName($0) } ?? track.displayName
                    newExternalTracks.append(MediaTrack(id: id, name: name, isExternal: true))
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.translationPlaybackGeneration == generation else { return }
            self.resolveSubtitleImportIfNeeded()
            self.audioTracks = self.applyingServerTrackNames(newAudioTracks, type: "Audio")
            
            // Keep server/candidate menu entries stable after VLC creates their native slaves.
            let nativeTracks = newSubtitleTracks.filter {
                self.nativeToExternalTrackIDs[$0.id] == nil && self.translationImportedSubtitleURLs[$0.id] == nil
            }
            var combinedSubtitles = self.applyingServerTrackNames(nativeTracks, type: "Subtitle", external: false)
            for track in newSubtitleTracks where self.nativeToExternalTrackIDs[track.id] == nil {
                if let imported = self.translationImportedSubtitleURLs[track.id] {
                    combinedSubtitles.append(MediaTrack(id: track.id, name: imported.lastPathComponent, isExternal: true))
                }
            }

            let videoDir = self.currentFile?.url.deletingLastPathComponent()
            for track in newExternalTracks {
                guard let url = self.remoteSecondarySubtitleURLs[track.id] else { continue }
                // If the external subtitle is in the same directory as the video, VLCKit likely
                // auto-detected it natively. Skip appending to avoid duplicates in the primary menu.
                if self.externalSubtitleResolvedTrackIDs[self.subtitleURLKey(url)] == nil,
                   let videoDir = videoDir, url.deletingLastPathComponent() == videoDir {
                    continue
                }
                
                // To avoid duplicate entries (e.g. built-in track also returned by API), filter by name
                if !combinedSubtitles.contains(where: { $0.name == track.name }) {
                    combinedSubtitles.append(track)
                }
            }
            self.subtitleTracks = combinedSubtitles
            self.refreshSecondarySubtitleTracks()
            
            // Restore Pending Audio Track Query
            if let query = self.pendingAudioTrackQuery {
                if let matched = self.audioTracks.first(where: { $0.id != -1 && self.trackNameMatches($0.name, query: query) }) {
                    self.setAudioTrack(matched.id)
                    self.pendingAudioTrackQuery = nil
                } else if self.audioTracks.contains(where: { $0.id != -1 }) {
                    self.pendingAudioTrackQuery = nil
                }
            } else {
                self.currentAudioTrackID = Int((self.mediaPlayer?.currentAudioTrackIndex ?? -1))
            }
            
            // Restore Pending Subtitle Track Query / Disable
            if self.disableSubtitlesOnStart {
                if self.rebuildingSession && (self.audioSubtitles.uses(.primary) || self.audioSubtitles.display == .primary) {
                    self.mediaPlayer?.currentVideoSubTitleIndex = -1
                    self.currentSubtitleTrackID = MacAudioSubtitlePlan.primaryID
                } else {
                    self.setSubtitleTrack(-1)
                }
                self.disableSubtitlesOnStart = false
                self.pendingSubtitleTrackQuery = nil
            } else if let query = self.pendingSubtitleTrackQuery {
                if let matched = self.subtitleTracks.first(where: { $0.id != -1 && self.trackNameMatches($0.name, query: query) }) {
                    self.setSubtitleTrack(matched.id)
                    self.pendingSubtitleTrackQuery = nil
                } else if self.subtitleTracks.contains(where: { $0.id != -1 }) {
                    self.pendingSubtitleTrackQuery = nil
                }
            } else {
                if self.currentSubtitleTrackID != MacAudioSubtitlePlan.primaryID && self.subtitleImportQueue.active == nil && !self.applyAutomaticSubtitleSelectionIfNeeded() {
                    let nativeSubIndex = Int((self.mediaPlayer?.currentVideoSubTitleIndex ?? -1))
                    if let extID = self.nativeToExternalTrackIDs[nativeSubIndex] {
                        self.currentSubtitleTrackID = extID
                    } else {
                        self.currentSubtitleTrackID = nativeSubIndex
                    }
                }
            }
            
            self.restoreEngineHandoff()

            // Note: If subtitles were changed externally, we might need to sync the current index
            self.audioSubtitles.refreshDefaultAudioTrack()
            self.restorePendingPrimarySubtitleTranslationIfNeeded()
            self.refreshPrimarySubtitleTranslation()
        }
    }
    
    private func fetchServerMediaStreamsIfNeeded() {
        guard let serverType = currentFile?.serverType,
              (serverType == .jellyfin || serverType == .emby),
              let serverId = currentFile?.jellyfinServerId,
              let itemId = currentFile?.jellyfinItemId,
              let server = AppNetworkService.shared.servers.first(where: { $0.id.uuidString.lowercased() == serverId.lowercased() }),
              let userId = server.userId,
              let token = server.accessToken else {
            return
        }
        
        let urlStr = "\(server.fullURL)/Users/\(userId)/Items/\(itemId)?Fields=MediaSources"
        guard let url = URL(string: urlStr) else { return }
        
        var request = URLRequest(url: url)
        let authValue = "MediaBrowser Client=\"GenPlayer\", Device=\"Mac\", DeviceId=\"Mac\", Version=\"1.0\", Token=\"\(token)\""
        if serverType == .jellyfin {
            request.setValue(authValue, forHTTPHeaderField: "Authorization")
        } else {
            request.setValue(authValue, forHTTPHeaderField: "X-Emby-Authorization")
        }
        
        let requestGeneration = translationPlaybackGeneration
        let mpvRequest = isUsingMPV
        let selectedSourceID = currentFile?.mediaSourceId ?? currentFile.flatMap {
            URLComponents(url: $0.url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame }?.value
        }
        Task { [weak self] in
            do {
                let (data, _) = try await URLSession.shared.data(for: request)
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let mediaSources = json["MediaSources"] as? [[String: Any]] {
                    let index = mpvRequest ? MacMPVMediaSourceSelection.index(requestedID: selectedSourceID,
                        sourceIDs: mediaSources.map { $0["Id"] as? String }) : (mediaSources.isEmpty ? nil : 0)
                    guard let index else { return }
                    let firstSource = mediaSources[index]
                    await MainActor.run {
                        guard self?.translationPlaybackGeneration == requestGeneration,
                              self?.currentFile?.jellyfinItemId == itemId else { return }
                        self?.currentFile?.serverMediaStreams = firstSource["MediaStreams"] as? [[String: Any]]
                        if mpvRequest { self?.currentFile?.mediaSourceId = firstSource["Id"] as? String }
                        if self?.isUsingMPV == true { self?.prepareMPVServerSubtitles() }
                        else { self?.refreshTracks() }
                    }
                }
            } catch {
                print("[MacVLCPlaybackService] Failed to fetch serverMediaStreams: \(error)")
            }
        }
    }
    
    public func addExternalSubtitle(url: URL, refreshAfter _: Bool = true) {
        if let mpvEngine {
            let key = MacMPVTrackChoice.mediaKey(url: url)
            if let existing = mpvTracks.first(where: { $0.type == "sub" && $0.externalURL.map { MacMPVTrackChoice.mediaKey(url: $0) } == key }) {
                setSubtitleTrack(existing.id)
                return
            }
            pendingSubtitleTrackQuery = nil
            mpvPendingTrackChoices["primary"] = nil
            hasResolvedAutomaticSubtitleSelection = true
            disableSubtitlesOnStart = false
            mpvPendingImportedSubtitle = url
            // Import without automatic selection. Only the latest still-active
            // request may select its track once it appears in the track list.
            mpvEngine.set("sid", currentSubtitleTrackID < 0 ? "no" : String(currentSubtitleTrackID))
            mpvEngine.addSubtitle(url)
            return
        }
        guard mediaPlayer?.media != nil else { return }
        audioSubtitles.noteManualSubtitleSelection()
        if audioSubtitles.isConfigured { audioSubtitles.release(.primary) }
        if audioSubtitles.display == .primary { audioSubtitles.select(.off) }
        subtitleSelectionID = UUID()
        if let nativeID = translationImportedSubtitleURLs.first(where: { $0.value == url })?.key {
            mediaPlayer?.currentVideoSubTitleIndex = Int32(nativeID)
            currentSubtitleTrackID = nativeID
            return
        }
        enqueueSubtitleImport(url: url, primaryTrackID: nil)
    }

    private func resetSubtitleImports() {
        subtitleImportPoll?.cancel()
        subtitleImportPoll = nil
        subtitleImportQueue = MacSubtitleImportQueue()
        subtitleSelectionID = UUID()
    }

    private func enqueueSubtitleImport(url: URL, primaryTrackID: Int?) {
        subtitleImportQueue.enqueue(.init(id: subtitleSelectionID, url: url, primaryTrackID: primaryTrackID))
        startNextSubtitleImport()
    }

    private func startNextSubtitleImport() {
        let knownIDs = Set((mediaPlayer?.videoSubTitlesIndexes as? [NSNumber] ?? []).map(\.intValue))
        guard let request = subtitleImportQueue.startNext(knownIDs: knownIDs) else { return }
        // A prior queued import may already have mounted this URL.
        if let nativeID = externalSubtitleResolvedTrackIDs[subtitleURLKey(request.url)]
            ?? translationImportedSubtitleURLs.first(where: { $0.value == request.url })?.key {
            subtitleImportQueue.discardActive()
            finishSubtitleImport(request, nativeID: nativeID)
            return
        }
        _ = mediaPlayer?.addPlaybackSlave(request.url, type: .subtitle, enforce: false)
        pollSubtitleImport(requestID: request.id, generation: translationPlaybackGeneration, attempts: 100)
    }

    private func pollSubtitleImport(requestID: UUID, generation: UUID, attempts: Int) {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.translationPlaybackGeneration == generation,
                  self.subtitleImportQueue.active?.request.id == requestID else { return }
            self.resolveSubtitleImportIfNeeded()
            guard self.subtitleImportQueue.active?.request.id == requestID else { return }
            if attempts > 0 {
                self.pollSubtitleImport(requestID: requestID, generation: generation, attempts: attempts - 1)
            } else {
                // A late registration must never be attributed to the next queued file.
                self.resetSubtitleImports()
                self.refreshTracks()
            }
        }
        subtitleImportPoll = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func resolveSubtitleImportIfNeeded() {
        let knownIDs = Set((mediaPlayer?.videoSubTitlesIndexes as? [NSNumber] ?? []).map(\.intValue))
        guard let result = subtitleImportQueue.resolve(knownIDs: knownIDs) else { return }
        subtitleImportPoll?.cancel()
        finishSubtitleImport(result.request, nativeID: result.nativeID)
    }

    private func finishSubtitleImport(_ request: MacSubtitleImportQueue.Request, nativeID: Int) {
        translationImportedSubtitleURLs[nativeID] = request.url
        if let primaryID = request.primaryTrackID {
            externalSubtitleResolvedTrackIDs[subtitleURLKey(request.url)] = nativeID
            nativeToExternalTrackIDs[nativeID] = primaryID
        }
        if request.id == subtitleSelectionID {
            mediaPlayer?.currentVideoSubTitleIndex = Int32(nativeID)
            currentSubtitleTrackID = request.primaryTrackID ?? nativeID
            if let file = currentFile { saveSeriesTrackPreferenceIfNeeded(for: file) }
        }
        startNextSubtitleImport()
        refreshTracks()
    }

    public func setAudioDelay(_ seconds: Double) {
        let clamped = min(max(seconds, -10.0), 10.0)
        guard abs(UserDefaults.standard.double(forKey: "audioDelaySeconds") - clamped) > 0.001 else { return }
        UserDefaults.standard.set(clamped, forKey: "audioDelaySeconds")
        if let mpvEngine { mpvEngine.set("audio-delay", String(clamped)); return }
        reloadCurrentItemPreservingPlaybackState()
    }
    
    public func setSubtitleDelay(_ seconds: Double) {
        let clamped = min(max(seconds, -10.0), 10.0)
        guard abs(UserDefaults.standard.double(forKey: "subtitleDelaySeconds") - clamped) > 0.001 else { return }
        UserDefaults.standard.set(clamped, forKey: "subtitleDelaySeconds")
        if let mpvEngine { mpvEngine.set("sub-delay", String(clamped)); updateMPVSecondaryStyle(); updateCurrentSecondarySubtitleParts(at: Double(currentTime) / 1000); return }
        reloadCurrentItemPreservingPlaybackState()
    }
    
    public func setDecoder(_ decoder: String) {
        let currentDecoder = UserDefaults.standard.string(forKey: "defaultVideoDecoder") ?? "hw"
        guard currentDecoder != decoder else { return }
        UserDefaults.standard.set(decoder, forKey: "defaultVideoDecoder")
        if let mpvEngine { mpvEngine.set("hwdec", decoder == "hw" ? "videotoolbox" : "no"); return }
        reloadCurrentItemPreservingPlaybackState()
    }
    
    public func setAspectRatio(_ ratio: String) {
        UserDefaults.standard.set(ratio, forKey: "defaultVideoAspectRatio")
        if let mpvEngine { mpvEngine.set("video-aspect-override", ratio == "Default" || ratio.isEmpty ? "-1" : ratio); return }
        if ratio == "Default" || ratio.isEmpty {
            mediaPlayer?.videoAspectRatio = nil
        } else {
            mediaPlayer?.videoAspectRatio = UnsafeMutablePointer<Int8>(mutating: (ratio as NSString).utf8String)
        }
    }
    
    // MARK: - VLCMediaPlayerDelegate

    public func mediaPlayerStateChanged(_ aNotification: Notification!) {
        let generation = mpvGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isUsingMPV, self.mpvGeneration == generation else { return }
            self.isPlaying = (self.mediaPlayer?.isPlaying ?? false)
            
            if self.isPlaying {
                self.isPausedSeek = false
                self.playbackErrorMessage = nil
                self.isLoading = false
                MPNowPlayingInfoCenter.default().playbackState = .playing
                self.updateNowPlayingInfo()
                
                if (self.mediaPlayer?.hasVideoOut ?? false) || self.currentTime > 500 || self.currentFile?.type == .audio {
                    self.hasRenderedFirstFrame = true
                    self.stopStartupWatchdog()
                }
                
                if self.duration == 0 && self.mediaPlayer?.media?.length.intValue ?? 0 > 0 {
                    self.duration = self.mediaPlayer?.media?.length.intValue ?? 0
                    self.updateNowPlayingInfo()
                }
                
                let vSize = (self.mediaPlayer?.videoSize ?? .zero)
                if vSize.width > 1 && vSize.height > 1 && self.videoNaturalSize != vSize {
                    self.videoNaturalSize = vSize
                }
                
                if !self.hasStartedPlaybackForCurrentItem {
                    self.hasStartedPlaybackForCurrentItem = true
                    
                    self.setVolume(self.volume) // Apply volume when playback starts
                    
                    if let initialSeek = self.pendingInitialSeek, initialSeek > 0 {
                        let currentSec = Double((self.mediaPlayer?.time.intValue ?? 0)) / 1000.0
                        if abs(currentSec - initialSeek) > 2.0 {
                            self.mediaPlayer?.time = VLCTime(int: Int32(initialSeek * 1000.0))
                        }
                        self.pendingInitialSeek = nil
                    }
                    if let trackID = self.currentFile?.lastAudioTrack {
                        self.setAudioTrack(trackID)
                    }
                    if let trackID = self.currentFile?.lastSubtitleTrack {
                        self.setSubtitleTrack(trackID)
                    }
                }
                if !self.hasReportedServerPlaying {
                    self.hasReportedServerPlaying = self.reportServerPlaying()
                }
                if self.currentFile?.isLiveStream == true || self.currentFile?.serverType == .iptv {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                        guard let self = self, self.isPlaying, (self.mediaPlayer?.hasVideoOut ?? false) else { return }
                        self.captureIPTVSnapshotIfNeeded()
                    }
                }
            } else if self.mediaPlayer?.state == .stopped || self.mediaPlayer?.state == .ended {
                self.stopStartupWatchdog()
                self.isLoading = false
                MPNowPlayingInfoCenter.default().playbackState = .stopped
                self.saveProgress()
                self.reportServerStopped()

                let isLive = self.currentFile?.isLiveStream == true || self.currentFile?.serverType == .iptv
                let isNormalEnd = !isLive && (self.isNearEnd || self.hasReachedEnd)

                if !self.isUserInitiatedStop && !isNormalEnd && !self.hasReachedEnd {
                    if self.playbackErrorMessage == nil {
                        self.playbackErrorMessage = platformShellString("Playback failed. This file may be unavailable or unsupported.")
                    }
                }

                if self.mediaPlayer?.state == .ended || isNormalEnd {
                    self.hasReachedEnd = true
                    let stopItem = DispatchWorkItem { [weak self] in
                        self?.isUserInitiatedStop = true
                        self?.mediaPlayer?.stop()
                    }
                    self.pendingStopWorkItem = stopItem
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: stopItem)
                }
            } else if self.mediaPlayer?.state == .paused {
                self.isLoading = false
                if let length = self.mediaPlayer?.media?.length.intValue, length > 0 { self.duration = length }
                let size = (self.mediaPlayer?.videoSize ?? .zero)
                if size.width > 1 && size.height > 1 && self.videoNaturalSize != size { self.videoNaturalSize = size }
                self.stopStartupWatchdog()
                MPNowPlayingInfoCenter.default().playbackState = .paused
                self.saveProgress()
                self.reportServerProgress(force: true, reason: "paused")
            } else if self.mediaPlayer?.state == .buffering || self.mediaPlayer?.state == .opening {
                self.isLoading = !self.isPausedSeek
            } else if self.mediaPlayer?.state == .error {
                self.stopStartupWatchdog()
                self.isLoading = false
                if !self.isUserInitiatedStop && !self.hasReachedEnd && !self.isNearEnd && self.playbackErrorMessage == nil {
                    self.playbackErrorMessage = platformShellString("Playback failed. This file may be unavailable or unsupported.")
                }
            }
            
            self.currentTime = (self.mediaPlayer?.time.intValue ?? 0)
            
            let vlcAudioCount = (self.mediaPlayer?.audioTrackIndexes as? [NSNumber] ?? []).count
            let vlcSubtitleCount = (self.mediaPlayer?.videoSubTitlesIndexes as? [NSNumber] ?? []).count
            if (self.audioTracks.isEmpty && vlcAudioCount > 0) || (self.subtitleTracks.isEmpty && vlcSubtitleCount > 0) {
                self.refreshTracks()
            }
            if self.isPlaying && self.targetRate != 1.0 && (self.mediaPlayer?.rate ?? 1) != self.targetRate {
                self.mediaPlayer?.rate = self.targetRate
            }
        }
    }

    public func mediaPlayerTimeChanged(_ aNotification: Notification!) {
        let generation = mpvGeneration
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { [weak self] in
            guard let self, !self.isUsingMPV, self.mpvGeneration == generation else { return }
            self.currentTime = (self.mediaPlayer?.time.intValue ?? 0)
            self.position = (self.mediaPlayer?.position ?? 0)
            self.updateCurrentSecondarySubtitleParts(at: Double(self.currentTime) / 1000.0)
            
            if (self.mediaPlayer?.hasVideoOut ?? false) || self.currentTime > 500 {
                self.hasRenderedFirstFrame = true
                self.stopStartupWatchdog()
            }
            
            let vSize = (self.mediaPlayer?.videoSize ?? .zero)
            if vSize.width > 1 && vSize.height > 1 && self.videoNaturalSize != vSize {
                self.videoNaturalSize = vSize
            }
            
            let vlcAudioCount = (self.mediaPlayer?.audioTrackIndexes as? [NSNumber] ?? []).count
            let vlcSubtitleCount = (self.mediaPlayer?.videoSubTitlesIndexes as? [NSNumber] ?? []).count
            if (self.audioTracks.isEmpty && vlcAudioCount > 0) || (self.subtitleTracks.isEmpty && vlcSubtitleCount > 0) {
                self.refreshTracks()
            }
            
            // Periodically update Now Playing Center (every 5 seconds)
            if self.currentTime % 5000 < 500 {
                self.updateNowPlayingInfo()
            }
            
            let timeInSeconds = Double(self.currentTime) / 1000.0
            
            // Periodic history and server sync
            if abs(timeInSeconds - self.lastSavedHistoryTime) >= 5.0 {
                self.saveProgress()
                self.lastSavedHistoryTime = timeInSeconds
            }
            
            if abs(timeInSeconds - self.lastJellyfinSyncTime) >= 10.0 {
                self.reportServerProgress(force: false, reason: "periodic")
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
    
    private func setupRemoteCommandCenter() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if let engine = self.mpvEngine {
                    if self.shouldRestartFromBeginning { self.restartFromBeginning(); return }
                    self.mpvPauseRequested = false
                    engine.set("pause", "no")
                    self.updateNowPlayingInfo()
                } else { self.mediaPlayer?.play() }
            }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.pause() }
            return .success
        }
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async { self?.togglePlayPause() }
            return .success
        }
    }

    private func updateNowPlayingInfo() {
        guard let file = currentFile else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        nowPlayingInfo[MPMediaItemPropertyTitle] = file.name
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = Double(isUsingMPV ? currentTime : (mediaPlayer?.time.intValue ?? 0)) / 1000.0
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = Double(isUsingMPV ? duration : (mediaPlayer?.media?.length.intValue ?? 0)) / 1000.0
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = (isUsingMPV ? isPlaying : (mediaPlayer?.isPlaying ?? false)) ? targetRate : 0.0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    }

    // MARK: - History & Server Sync
    
    private func saveProgress() {
        guard let file = currentFile, !isUsingMPV || hasStartedPlaybackForCurrentItem else { return }
        let timeInSeconds = Double(currentTime) / 1000.0
        let durationInSeconds = Double(duration) / 1000.0
        
        let isVideo = file.type == .video
        let enableVideoHistory = UserDefaults.standard.object(forKey: "enableVideoHistory") as? Bool ?? true
        let enableAudioHistory = UserDefaults.standard.object(forKey: "enableAudioHistory") as? Bool ?? true
        if isVideo && !enableVideoHistory { return }
        if !isVideo && !enableAudioHistory { return }
        
        let updated = HistoryService.shared.updateProgress(
            for: file.url,
            time: timeInSeconds,
            duration: durationInSeconds,
            videoAspectRatioHint: nil,
            audioTrack: isUsingMPV || currentAudioTrackID == -1 ? nil : currentAudioTrackID,
            subtitleTrack: isUsingMPV || currentSubtitleTrackID < 0 ? nil : currentSubtitleTrackID,
            jellyfinItemId: file.jellyfinItemId,
            jellyfinServerId: file.jellyfinServerId,
            externalSubtitleCandidates: file.externalSubtitleCandidates,
            serverPath: file.serverPath
        )
        
        if updated == nil {
            var newFile = file
            if (newFile.serverType?.requiresDynamicPlaybackURL == true), let serverPath = newFile.serverPath, !serverPath.isEmpty {
                newFile.url = URL(fileURLWithPath: serverPath)
            }
            newFile.lastPlayedPosition = timeInSeconds
            newFile.duration = durationInSeconds
            if !isUsingMPV {
                newFile.lastAudioTrack = currentAudioTrackID == -1 ? nil : currentAudioTrackID
                newFile.lastSubtitleTrack = currentSubtitleTrackID < 0 ? nil : currentSubtitleTrackID
            }
            newFile.date = Date()
            HistoryService.shared.addToHistory(newFile)
        }
    }
    
    private func serverSyncContext() -> (server: ServerConfig, serverType: ServerConfig.ServerType, itemId: String, token: String, userId: String)? {
        guard let file = currentFile, let itemId = file.jellyfinItemId else { return nil }
        
        let allServers = AppNetworkService.shared.servers
        var resolvedServer: ServerConfig?
        if let serverId = file.jellyfinServerId {
            resolvedServer = allServers.first(where: { $0.id.uuidString == serverId })
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
        
        guard let server = resolvedServer else { return nil }
        let serverType = file.serverType ?? server.type
        guard serverType == .jellyfin || serverType == .emby || serverType == .plex else { return nil }
        
        let token = URLComponents(url: file.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "api_key" || $0.name == "X-Plex-Token" })?
            .value
            ?? server.accessToken
        guard let token, !token.isEmpty else { return nil }
        
        return (server: server, serverType: serverType, itemId: itemId, token: token, userId: server.userId ?? "")
    }

    @discardableResult
    private func reportServerPlaying() -> Bool {
        guard let context = serverSyncContext() else { return false }
        
        let ticks = Int64(Double(currentTime) / 1000.0 * 10_000_000)
        let payload = MacServerPlaybackSyncPayload(
            serverType: context.serverType,
            serverId: context.server.id.uuidString,
            itemId: context.itemId,
            userId: context.userId,
            token: context.token,
            positionTicks: ticks,
            isPaused: false,
            eventName: "playing"
        )
        NotificationCenter.default.post(name: .macServerPlaybackSyncRequest, object: payload)
        return true
    }

    private func reportServerProgress(force: Bool = false, reason: String = "periodic") {
        guard let context = serverSyncContext() else { return }
        
        let timeInSeconds = Double(currentTime) / 1000.0
        let shouldReport = force || abs(timeInSeconds - lastJellyfinSyncTime) >= 10.0
        guard shouldReport else { return }
        
        lastJellyfinSyncTime = timeInSeconds
        let ticks = Int64(timeInSeconds * 10_000_000)
        let isPaused = !isPlaying
        
        let payload = MacServerPlaybackSyncPayload(
            serverType: context.serverType,
            serverId: context.server.id.uuidString,
            itemId: context.itemId,
            userId: context.userId,
            token: context.token,
            positionTicks: ticks,
            isPaused: isPaused,
            eventName: "progress_\(reason)"
        )
        NotificationCenter.default.post(name: .macServerPlaybackSyncRequest, object: payload)
    }

    public func seek(by milliseconds: Int32) {
        if isUsingMPV {
            setPosition(Float((Double(currentTime) + Double(milliseconds)) / Double(max(duration, 1))))
            return
        }
        audioSubtitles.seek(to: max(0, (Double(currentTime) + Double(milliseconds)) / 1000))
        prepareForSeek()
        if milliseconds < 0 {
            mediaPlayer?.jumpBackward(Int32(abs(milliseconds) / 1000))
        } else {
            mediaPlayer?.jumpForward(Int32(milliseconds / 1000))
        }
    }

    internal func prepareForSeek() {
        if mediaPlayer?.state == .paused || isPausedSeek {
            isPausedSeek = true
            isLoading = false
        }
    }

    private func reportServerStopped() {
        guard let context = serverSyncContext() else { return }
        
        let timeInSeconds = Double(currentTime) / 1000.0
        let ticks = Int64(timeInSeconds * 10_000_000)
        
        let payload = MacServerPlaybackSyncPayload(
            serverType: context.serverType,
            serverId: context.server.id.uuidString,
            itemId: context.itemId,
            userId: context.userId,
            token: context.token,
            positionTicks: ticks,
            isPaused: false,
            eventName: "stopped"
        )
        NotificationCenter.default.post(name: .macServerPlaybackSyncRequest, object: payload)
    }
}
#endif



#if os(macOS)
extension MacVLCPlaybackService {
        private func applyingServerTrackNames(
            _ tracks: [MediaTrack],
            type: String,
            external: Bool? = nil
        ) -> [MediaTrack] {
            let serverNames = serverTrackDisplayNames(type: type, external: external)
            let selectableIndices = tracks.indices.filter { tracks[$0].id != -1 && (external == nil || tracks[$0].isExternal == external) }
    
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
    
        private func serverTrackDisplayNames(type: String, external: Bool? = nil) -> [String] {
            guard let streams = currentFile?.serverMediaStreams, !streams.isEmpty else { return [] }
    
            return streams.compactMap { stream in
                guard ((stream["Type"] as? String) ?? "") == type else { return nil }
                if let external, serverTrackBooleanValue(stream["IsExternal"]) != external {
                    return nil
                }
    
                if type == "Subtitle" {
                    return formattedServerSubtitleTrackDisplayName(stream)
                }
    
                if let title = cleanedServerTrackMetadataValue(stream["DisplayTitle"] as? String), !title.isEmpty {
                    return title
                }
    
                let language = cleanedServerTrackMetadataValue(stream["Language"] as? String)
                let codec = cleanedServerTrackMetadataValue(stream["Codec"] as? String)
                let channels = stream["Channels"] as? Int
    
                var parts: [String] = []
                if let language, !language.isEmpty { parts.append(language.uppercased()) }
                if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
                if let channels, channels > 0, type == "Audio" { parts.append("\(channels)ch") }
                return parts.isEmpty ? nil : parts.joined(separator: " · ")
            }
        }
    
        private func formattedServerSubtitleTrackDisplayName(_ stream: [String: Any]) -> String? {
            let title = cleanedServerSubtitlePresentationMetadataValue(stream["DisplayTitle"] as? String)
            let alternateTitle = cleanedServerSubtitlePresentationMetadataValue(stream["Title"] as? String)
            let displayLanguage = cleanedServerSubtitleLanguageMetadataValue(stream["DisplayLanguage"] as? String)
            let language = cleanedServerSubtitleLanguageMetadataValue(stream["Language"] as? String)
            let codec = cleanedServerTrackMetadataValue(stream["Codec"] as? String)?.uppercased()
            let isDefault = serverTrackBooleanValue(stream["IsDefault"])
            let isForced = serverTrackBooleanValue(stream["IsForced"])
            let normalizedTitle = normalizedServerTrackMetadataValue(title)
    
            var parts: [String] = []
            if let title,
               !title.isEmpty,
               !isGenericServerSubtitleDisplayTitle(title, codec: codec) {
                parts.append(title)
            }
    
            if let alternateTitle,
               !alternateTitle.isEmpty,
               !normalizedTitle.contains(normalizedServerTrackMetadataValue(alternateTitle)),
               !parts.contains(where: { normalizedServerTrackMetadataValue($0) == normalizedServerTrackMetadataValue(alternateTitle) }),
               !isGenericServerSubtitleDisplayTitle(alternateTitle, codec: codec) {
                parts.append(alternateTitle)
            }
    
            if let displayLanguage,
               !displayLanguage.isEmpty,
               !normalizedTitle.contains(normalizedServerTrackMetadataValue(displayLanguage)),
               !parts.contains(where: { normalizedServerTrackMetadataValue($0) == normalizedServerTrackMetadataValue(displayLanguage) }) {
                parts.append(displayLanguage)
            }
    
            if let language,
               !language.isEmpty,
               !normalizedTitle.contains(normalizedServerTrackMetadataValue(language)),
               !parts.contains(where: { normalizedServerTrackMetadataValue($0) == normalizedServerTrackMetadataValue(language) }) {
                parts.append(language)
            }
    
            var flagParts: [String] = []
            if isDefault, !normalizedTitle.contains("default") {
                flagParts.append(platformShellString("Default"))
            }
            if isForced, !normalizedTitle.contains("forced") {
                flagParts.append(platformShellString("Forced"))
            }
            if !flagParts.isEmpty {
                parts.append(flagParts.joined(separator: " "))
            }
    
            if let codec,
               !codec.isEmpty,
               !normalizedTitle.contains(normalizedServerTrackMetadataValue(codec)),
               !parts.contains(where: { normalizedServerTrackMetadataValue($0) == normalizedServerTrackMetadataValue(codec) }) {
                parts.append(codec)
            }
    
            if parts.isEmpty {
                return title ?? alternateTitle ?? displayLanguage ?? language ?? codec
            }
            return parts.joined(separator: " · ")
        }
    
        private func serverTrackBooleanValue(_ value: Any?) -> Bool {
            if let value = value as? Bool {
                return value
            }
            if let value = value as? NSNumber {
                return value.boolValue
            }
            if let value = value as? String {
                let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized == "true" || normalized == "1" || normalized == "yes"
            }
            return false
        }
    
        private func cleanedServerTrackMetadataValue(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
                return nil
            }
            return value
        }
    
        private func cleanedServerSubtitleLanguageMetadataValue(_ value: String?) -> String? {
            guard let cleaned = cleanedServerSubtitlePresentationMetadataValue(value) else { return nil }
    
            return cleaned
        }
    
        private func cleanedServerSubtitlePresentationMetadataValue(_ value: String?) -> String? {
            guard let cleaned = cleanedServerTrackMetadataValue(value) else { return nil }
    
            let lowered = cleaned
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased()
            let placeholderValues: Set<String> = [
                "und", "undefined", "unknown", "undetermined", "n/a", "na", "none", "null",
                "未定义", "未指定", "未知", "不明", "未設定", "未設置"
            ]
    
            return placeholderValues.contains(lowered) ? nil : cleaned
        }
    
        private func isGenericServerSubtitleDisplayTitle(_ title: String, codec: String?) -> Bool {
            var normalized = normalizedServerTrackMetadataValue(title)
            if let codec, !codec.isEmpty {
                normalized = normalized.replacingOccurrences(of: normalizedServerTrackMetadataValue(codec), with: "")
            }
    
            let genericTokens = ["default", "forced", "subtitle", "captions", "caption", "external", "internal"]
            genericTokens.forEach { token in
                normalized = normalized.replacingOccurrences(of: token, with: "")
            }
            return normalized.isEmpty
        }
    
        private func normalizedServerTrackMetadataValue(_ value: String?) -> String {
            guard let value = value?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .lowercased() else {
                return ""
            }
            return String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
        }
    
        private func trackNameMatches(_ trackName: String, query: String) -> Bool {
            let normalizedTrack = normalizedTrackQuery(trackName)
            let normalizedQuery = normalizedTrackQuery(query)
            guard !normalizedTrack.isEmpty, !normalizedQuery.isEmpty else { return false }
            return normalizedTrack.contains(normalizedQuery) || normalizedQuery.contains(normalizedTrack)
        }

        private func normalizedTrackQuery(_ value: String) -> String {
            let lowered = value.lowercased()
            let allowed = CharacterSet.alphanumerics
            return String(lowered.unicodeScalars.filter { allowed.contains($0) })
        }

        internal func storedTrackQueryPreference(for file: VideoFile) -> (audioQuery: String?, subtitleQuery: String?, subtitlesDisabled: Bool?) {
            guard let provider = file.serverType?.rawValue,
                  let serverId = file.jellyfinServerId else {
                return (nil, nil, nil)
            }
            let scopeKey: String
            if let seriesId = file.seriesId, !seriesId.isEmpty {
                scopeKey = "series.\(seriesId)"
            } else if let itemId = file.jellyfinItemId, !itemId.isEmpty {
                scopeKey = "item.\(itemId)"
            } else {
                return (nil, nil, nil)
            }
            
            let prefix = "trackQuery.\(provider).\(serverId).\(scopeKey)"
            let audioKey = "\(prefix).audioQuery"
            let subtitleKey = "\(prefix).subtitleQuery"
            let disabledKey = "\(prefix).subtitlesDisabled"

            let audioQuery = UserDefaults.standard.string(forKey: audioKey)
            let subtitleQuery = UserDefaults.standard.string(forKey: subtitleKey)
            let subtitlesDisabled = UserDefaults.standard.object(forKey: disabledKey) as? Bool
            return (audioQuery, subtitleQuery, subtitlesDisabled)
        }

        private func saveTrackQueryPreferenceIfNeeded(for file: VideoFile) {
            guard let provider = file.serverType?.rawValue,
                  let serverId = file.jellyfinServerId else {
                return
            }
            let scopeKey: String
            if let seriesId = file.seriesId, !seriesId.isEmpty {
                scopeKey = "series.\(seriesId)"
            } else if let itemId = file.jellyfinItemId, !itemId.isEmpty {
                scopeKey = "item.\(itemId)"
            } else {
                return
            }
            
            let prefix = "trackQuery.\(provider).\(serverId).\(scopeKey)"
            let audioKey = "\(prefix).audioQuery"
            let subtitleKey = "\(prefix).subtitleQuery"
            let disabledKey = "\(prefix).subtitlesDisabled"

            let selectedAudioQuery = audioTracks.first(where: { $0.id == currentAudioTrackID })?.name
            let selectedSubtitleQuery = subtitleTracks.first(where: { $0.id == currentSubtitleTrackID })?.name
            let subtitlesDisabled = currentSubtitleTrackID == -1

            if let audioQuery = selectedAudioQuery, !audioQuery.isEmpty {
                UserDefaults.standard.set(audioQuery, forKey: audioKey)
            } else {
                UserDefaults.standard.removeObject(forKey: audioKey)
            }

            guard currentSubtitleTrackID != MacAudioSubtitlePlan.primaryID else { return }
            if let subtitleQuery = selectedSubtitleQuery, !subtitleQuery.isEmpty, !subtitlesDisabled {
                UserDefaults.standard.set(subtitleQuery, forKey: subtitleKey)
            } else {
                UserDefaults.standard.removeObject(forKey: subtitleKey)
            }

            UserDefaults.standard.set(subtitlesDisabled, forKey: disabledKey)
        }

        private func saveSeriesTrackPreferenceIfNeeded(for file: VideoFile) {
            saveTrackQueryPreferenceIfNeeded(for: file)

            guard let provider = file.serverType?.rawValue,
                  let serverId = file.jellyfinServerId,
                  let seriesId = file.seriesId,
                  !seriesId.isEmpty else {
                return
            }

            let prefix = "seriesTrack.\(provider).\(serverId).\(seriesId)"
            let audioKey = "\(prefix).audio"
            let subtitleKey = "\(prefix).subtitle"

            UserDefaults.standard.set(currentAudioTrackID, forKey: audioKey)
            if currentSubtitleTrackID != MacAudioSubtitlePlan.primaryID {
                UserDefaults.standard.set(currentSubtitleTrackID, forKey: subtitleKey)
            }
        }

        private func applyAutomaticSubtitleSelectionIfNeeded() -> Bool {
            guard !hasResolvedAutomaticSubtitleSelection,
                  currentSubtitleTrackID != MacAudioSubtitlePlan.primaryID,
                  pendingEngineTracks["sub"] == nil, pendingPrimarySource == nil else { return false }
            let mode = UserDefaults.standard.string(forKey: "subtitleAutoSelectionMode") ?? "followAppLanguage"
            guard mode != "off" else {
                hasResolvedAutomaticSubtitleSelection = true
                return false
            }
            let tracks = subtitleTracks.filter { $0.id != -1 }
            guard !tracks.isEmpty else { return false }
            hasResolvedAutomaticSubtitleSelection = true
            let stored = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
            let language = stored == "system" ? (Locale.preferredLanguages.first ?? Locale.current.identifier) : stored
            guard let index = PlaybackSubtitleAutoSelection.index(in: tracks.map(\.name), mode: mode, language: language) else { return false }
            setSubtitleTrack(tracks[index].id)
            return true
        }

        private func configureTextRenderer(for player: VLCMediaPlayer?) {
        guard let player else { return }
            var fallbackFontFamily = "HelveticaNeue"
            if let fontURL = Bundle.main.url(forResource: "SourceHanSansSC-Regular", withExtension: "otf") {
                var error: Unmanaged<CFError>?
                CTFontManagerRegisterFontsForURL(fontURL as CFURL, .process, &error)
                if error == nil {
                    fallbackFontFamily = "Source Han Sans SC"
                }
            }
            
            let fontSelector = NSSelectorFromString("setTextRendererFont:")
            if player.responds(to: fontSelector) {
                player.perform(fontSelector, with: fallbackFontFamily)
            }

            let fontSizeSelector = NSSelectorFromString("setTextRendererFontSize:")
            if player.responds(to: fontSizeSelector) {
                player.perform(fontSizeSelector, with: preferredSubtitleRendererFontSize())
            }
        }

        private func preferredSubtitleRendererFontSize() -> NSNumber {
            let shorterSide: CGFloat
            if let window = MacPlayerWindowManager.shared.currentPlayerWindowController?.window {
                shorterSide = min(window.frame.width, window.frame.height)
            } else {
                shorterSide = 760
            }
            let scaledSize = max(18.0, min(22.0, round(shorterSide * 0.025)))
            return NSNumber(value: Double(scaledSize))
        }
}

extension MacVLCPlaybackService {
    public var isPictureInPictureActiveOrStarting: Bool {
        return isVideoPiPActive || (videoPiPController?.isStartingOrActive == true)
    }

    public func attachVideoView(_ videoView: VLCVideoView, sessionID: UUID) {
        guard !isUsingMPV, sessionID == vlcVideoViewID else { return }
        self.activeVideoView = videoView
        if !MacEnvironmentDetector.isVirtualMachine && !isPictureInPictureActiveOrStarting {
            self.mediaPlayer?.drawable = videoView
        }
        _ = restoreDeferredDrawablePlaybackSessionAfterPictureInPictureIfNeeded()
    }

    func videoViewDidBecomeReady(_ videoView: VLCVideoView, sessionID: UUID) {
        guard !isUsingMPV, sessionID == vlcVideoViewID,
              pendingVLCVideoStart == mpvGeneration,
              videoView.window != nil, videoView.bounds.width > 0, videoView.bounds.height > 0 else { return }
        attachVideoView(videoView, sessionID: sessionID)
        guard pendingVLCVideoStart == mpvGeneration,
              let file = currentFile, let mediaPlayer, mediaPlayer.media != nil,
              mediaPlayer.drawable as? VLCVideoView === videoView else { return }
        pendingVLCVideoStart = nil
        startStartupWatchdog(for: file)
        mediaPlayer.play()
    }

    public func attachCoreAnimationVideoView(_ hostView: MacSampleBufferHostView) {
        self.activeSampleBufferHostView = hostView
        if MacEnvironmentDetector.isVirtualMachine && !isPictureInPictureActiveOrStarting {
            setupVMFrameBridgeIfNeeded()
        }
    }

    public func setupVMFrameBridgeIfNeeded() {
        guard MacEnvironmentDetector.isVirtualMachine else { return }
        if vmFrameBridge == nil {
            let bridge = GenPlayerVLCFrameBridge()
            bridge.maximumRenderWidth = 0
            bridge.minimumFrameInterval = 0
            bridge.callbackQueue = vmFrameRenderQueue
            bridge.frameHandler = { [weak self] pixelBuffer in
                self?.handleVMOutputPixelBuffer(pixelBuffer)
            }
            vmFrameBridge = bridge
        }
        if let bridge = vmFrameBridge, !bridge.isAttached {
            self.mediaPlayer?.drawable = nil
            if let mediaPlayer = self.mediaPlayer { try? bridge.attach(to: mediaPlayer) }
        }
    }

    private func handleVMOutputPixelBuffer(_ pixelBuffer: CVPixelBuffer) {
        guard let hostView = activeSampleBufferHostView else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        
        if vmCachedFormatDescription == nil || vmCachedFormatDescriptionDimensions != (width, height) {
            var desc: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescriptionOut: &desc
            )
            if status == noErr, let desc {
                vmCachedFormatDescription = desc
                vmCachedFormatDescriptionDimensions = (width, height)
            }
        }
        guard let formatDescription = vmCachedFormatDescription else { return }
        
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: .invalid,
            decodeTimeStamp: .invalid
        )
        
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { return }
        
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true
        ) as? [NSMutableDictionary], let dict = attachments.first {
            dict[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        
        let layer = hostView.bufferDisplayLayer
        if layer.status == .failed {
            layer.flush()
        }
        layer.enqueue(sampleBuffer)
    }

    @discardableResult
    public func startPictureInPicture(userInitiated: Bool = false) -> Bool {
        guard playbackCapabilities.supports(.pictureInPicture, isVideo: currentFile?.type == .video) else { return false }
        if isUsingMPV {
            guard UserDefaults.standard.object(forKey: "enableMacPiPBeta") as? Bool ?? true,
                  currentFile?.type == .video else { return false }
            if mpvPiPController != nil { return true }
            let controller = MacMPVPictureInPicture(service: self)
            let generation = mpvGeneration
            controller.onClose = { [weak self] restoring in
                guard let self, self.mpvGeneration == generation else { return }
                self.isVideoPiPActive = false
                let finishedController = self.mpvPiPController
                self.mpvPiPController = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = finishedController }
                if !restoring {
                    let fileID = self.currentFile?.id
                    self.stop()
                    if let fileID { MacPlayerWindowManager.shared.closePlayer(for: fileID) }
                }
            }
            guard controller.start() else { return false }
            mpvPiPController = controller
            isVideoPiPActive = true
            return true
        }
        guard UserDefaults.standard.object(forKey: "enableMacPiPBeta") as? Bool ?? true,
              let currentFile, currentFile.type == .video else {
            return false
        }

        if AVPictureInPictureController.isPictureInPictureSupported() {
            if videoPiPController == nil {
                let controller = MacVLCPlayerPictureInPictureController(playbackService: self)
                controller.onDidStart = { [weak self] in
                    self?.handlePictureInPictureDidStart()
                }
                controller.onDidStop = { [weak self] in
                    self?.handlePictureInPictureDidStop()
                }
                controller.onStartFailed = { [weak self] in
                    self?.handlePictureInPictureStartFailure()
                }
                videoPiPController = controller
            }

            guard videoPiPController?.start() == true else {
                isVideoPiPActive = false
                return false
            }

            isVideoPiPActive = true
            return true
        }
        return false
    }

    public func stopPictureInPicture() {
        if isUsingMPV { stopMPVPictureInPicture(); return }
        pendingDrawablePlaybackSessionRestoreAfterPictureInPicture = false
        let controllerToStop = videoPiPController
        controllerToStop?.stop()

        DispatchQueue.main.async {
            self.isVideoPiPActive = false
            self.isRestoringPlayerFromPictureInPicture = false
            self.pendingPictureInPictureRestoreFile = nil
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            if self?.videoPiPController === controllerToStop {
                self?.videoPiPController = nil
            }
        }
    }

    private func handlePictureInPictureDidStart() {
        DispatchQueue.main.async {
            self.isVideoPiPActive = true
            self.onDidStartPiP?()
        }
    }

    private func handlePictureInPictureDidStop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isVideoPiPActive = false
            if !self.isRestoringPlayerFromPictureInPicture {
                print("[MacPiP] PiP closed without restore, stopping playback")
                self.stop()
            }
            let controllerToClear = self.videoPiPController
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                if self?.videoPiPController === controllerToClear {
                    self?.videoPiPController = nil
                }
            }
        }
    }

    private func handlePictureInPictureStartFailure() {
        DispatchQueue.main.async {
            self.isVideoPiPActive = false
        }
    }

    var playbackEngineID: PlaybackEngineID { isUsingMPV ? .mpv : .vlc }

    var playbackCapabilities: PlaybackEngineCapabilities {
        .init(platform: .macOS, engine: isUsingMPV ? .mpv : .vlc)
    }

    var canSwitchPlaybackEngine: Bool { PlaybackEngineAvailability.current.vlc && PlaybackEngineAvailability.current.mpv && playbackEngineSwitchRestriction == nil }

    var playbackEngineSwitchRestriction: PlaybackEngineCapabilities.Unavailability? {
        guard let file = currentFile else { return .stopped }
        if let restriction = PlaybackEngineCapabilities(platform: .macOS, engine: .mpv)
            .routingRestriction(url: file.url, isVideo: file.type == .video, isAudio: file.type == .audio,
                isVirtualMachine: MacEnvironmentDetector.isVirtualMachine) { return restriction }
        return PlaybackEngineCapabilities.switchingRestriction(
            isPreparing: !hasStartedPlaybackForCurrentItem && isLoading,
            isStopped: isUserInitiatedStop, hasFailed: playbackErrorMessage != nil,
            isPictureInPicture: isPictureInPictureActiveOrStarting || isVideoPiPActive,
            isLive: file.isLiveStream || MacMPVPlaybackPolicy.isLiveProtocol(file.url),
            isSeekable: canSeek, duration: Double(duration))
    }

    var playbackEngineSwitchExplanation: String {
        let key: String
        switch playbackEngineSwitchRestriction {
        case nil: key = "MPV.SwitchReload"
        case .preparing: key = "MPV.SwitchPreparing"
        case .pictureInPicture: key = "MPV.SwitchPiP"
        case .live, .notSeekable: key = "MPV.SwitchVOD"
        case .stopped, .failed: key = "MPV.SwitchIdle"
        default: key = "MPV.SwitchUnsupported"
        }
        return platformShellString(key)
    }

    var canRecoverMPVWithVLC: Bool {
        PlaybackEngineAvailability.current.vlc && isUsingMPV && playbackErrorMessage != nil && currentFile != nil && !isUserInitiatedStop
            && !isPictureInPictureActiveOrStarting
    }

    func switchPlaybackEngine(to engine: PlaybackEngineID) {
        guard PlaybackEngineAvailability.current.allows(engine), engine != playbackEngineID,
              canSwitchPlaybackEngine || (engine == .vlc && canRecoverMPVWithVLC),
              let file = currentFile else { return }
        engineOverride = (MacMPVTrackChoice.mediaKey(url: file.url, serverID: file.jellyfinServerId,
            itemID: file.jellyfinItemId, path: file.serverPath), engine)
        reloadCurrentItemPreservingPlaybackState()
    }

    private var embeddedSubtitleIDsForHandoff: [Int] {
        subtitleTracks.filter { $0.id >= 0 && !$0.isExternal &&
            (isUsingMPV || ($0.id < 10000 && nativeToExternalTrackIDs[$0.id] == nil &&
                translationImportedSubtitleURLs[$0.id] == nil && !externalSubtitleResolvedTrackIDs.values.contains($0.id)))
        }.map(\.id)
    }

    private var primarySourceForHandoff: URL? {
        if isUsingMPV { return mpvTracks.first { $0.type == "sub" && $0.id == currentSubtitleTrackID }?.externalURL }
        return translationImportedSubtitleURLs[currentSubtitleTrackID] ?? remoteSecondarySubtitleURLs[currentSubtitleTrackID]
    }

    private func nativeSecondaryIDForHandoff(_ track: EmbeddedSubtitleTrack) -> Int? {
        if let id = track.primaryTrackID { return id }
        guard track.source == .localContainer, !track.isExternal else { return nil }
        let descriptors = secondarySubtitleTracks.filter { $0.source == .localContainer && !$0.isExternal }
        let nativeIDs = embeddedSubtitleIDsForHandoff
        guard descriptors.count == nativeIDs.count,
              let ordinal = descriptors.firstIndex(where: { $0.id == track.id }),
              nativeIDs.indices.contains(ordinal) else { return nil }
        return nativeIDs[ordinal]
    }

    private func captureSecondaryHandoff() -> IOSPlaybackSecondarySelection? {
        guard let id = currentSecondarySubtitleTrackID else {
            return .init(selection: .off, sourceURL: nil, descriptorID: nil)
        }
        // Generated/translated outputs belong to the retained application subtitle session.
        if id == MacAudioSubtitlePlan.secondaryID || id == MacSubtitleTranslation.trackID { return nil }
        guard let track = secondarySubtitleTracks.first(where: { $0.id == id }) else { return nil }
        return .init(selection: nativeSecondaryIDForHandoff(track).flatMap {
            IOSPlaybackTrackSelection.capture(id: $0, embeddedIDs: embeddedSubtitleIDsForHandoff)
        }, sourceURL: track.sourceURL, descriptorID: track.id)
    }

    private func restoreEngineHandoff() {
        guard rebuildingSession else { return }
        applyingEngineHandoff = true
        defer { applyingEngineHandoff = false }
        for slot in ["audio", "sub"] {
            guard let selection = pendingEngineTracks[slot] else { continue }
            let ids = slot == "audio" ? audioTracks.filter { $0.id >= 0 && !$0.isExternal }.map(\.id)
                : embeddedSubtitleIDsForHandoff
            guard let id = selection.resolve(embeddedIDs: ids) else { continue }
            pendingEngineTracks[slot] = nil
            if slot == "audio" { setAudioTrack(id) } else { setSubtitleTrack(id) }
        }
        if let source = pendingPrimarySource {
            let id: Int?
            if isUsingMPV {
                id = mpvTracks.first { $0.externalURL == source }?.id
            } else {
                id = subtitleTracks.first { remoteSecondarySubtitleURLs[$0.id] == source ||
                    translationImportedSubtitleURLs[$0.id] == source }?.id
            }
            if let id { pendingPrimarySource = nil; setSubtitleTrack(id) }
            else if isUsingMPV && mpvPendingImportedSubtitle != source {
                mpvPendingImportedSubtitle = source
                mpvEngine?.addSubtitle(source)
            } else if !isUsingMPV && subtitleImportQueue.active == nil {
                pendingPrimarySource = nil
                addExternalSubtitle(url: source)
            }
        }
        if let handoff = pendingSecondaryHandoff {
            if handoff.selection == .off {
                pendingSecondaryHandoff = nil
                setSecondarySubtitleTrack(nil, persistTranslationPreference: false)
            } else {
                let candidates = secondarySubtitleTracks.filter { isUsingMPV || $0.isSelectable }.map {
                    IOSPlaybackSecondarySelection.Candidate(id: $0.id, sourceURL: $0.isExternal ? $0.sourceURL : nil,
                        nativeID: nativeSecondaryIDForHandoff($0))
                }
                if let id = handoff.resolve(candidates: candidates, embeddedIDs: embeddedSubtitleIDsForHandoff) {
                    pendingSecondaryHandoff = nil
                    setSecondarySubtitleTrack(id, persistTranslationPreference: false)
                }
            }
        }
        if pendingAudioOutputRestore {
            pendingAudioOutputRestore = false
            audioSubtitles.onDisplayChanged?(audioSubtitles.display)
        }
    }

    public func reloadCurrentItemPreservingPlaybackState(
        preparePlayer: ((VLCMediaPlayer) throws -> Void)? = nil
    ) {
        guard var file = currentFile else { return }
        let wasTranslating = subtitleTranslation.enabled
        let audioSelection = IOSPlaybackTrackSelection.capture(id: currentAudioTrackID,
            embeddedIDs: audioTracks.filter { $0.id >= 0 && !$0.isExternal }.map(\.id))
        let nativeSubs = embeddedSubtitleIDsForHandoff
        let primarySelection = currentSubtitleTrackID == MacAudioSubtitlePlan.primaryID ? nil :
            IOSPlaybackTrackSelection.capture(id: currentSubtitleTrackID, embeddedIDs: nativeSubs)
        let primaryURL = primarySourceForHandoff
        let secondary = pendingSecondaryHandoff ?? captureSecondaryHandoff()
        var embedded: [String: PlaybackTrackSelection] = [:]
        embedded["audio"] = audioSelection; embedded["sub"] = primarySelection
        let snapshot = PlaybackSessionSnapshot(position: Double(currentTime) / 1000,
            duration: Double(duration) / 1000,
            paused: isUsingMPV ? mpvPauseRequested : mediaPlayer?.state == .paused, rate: targetRate,
            selections: .init(embedded: embedded, primarySourceURL: primaryURL, secondary: secondary))
        let secondURL = secondarySubtitleTracks.first { $0.id == currentSecondarySubtitleTrackID && $0.isExternal }?.sourceURL
        for url in [primaryURL, secondURL].compactMap({ $0 }) {
            if !file.externalSubtitleCandidates.contains(where: { $0.url == url }) {
                file.externalSubtitleCandidates.append(.init(url: url, displayName: url.lastPathComponent))
            }
        }
        file.lastPlayedPosition = snapshot.position
        file.shouldResetRemotePlayedStateOnPlaybackStart = false
        file.lastAudioTrack = nil
        file.lastSubtitleTrack = nil
        file.preferredAudioTrackQuery = nil
        file.preferredSubtitleTrackQuery = nil
        file.disableSubtitlesOnStart = primarySelection == .off || currentSubtitleTrackID == MacAudioSubtitlePlan.primaryID
        play(file: file, preparePlayer: preparePlayer, rebuilding: true, startPaused: snapshot.paused)
        pendingAudioTrackQuery = nil
        pendingSubtitleTrackQuery = nil
        pendingSecondarySubtitleTrackQuery = nil
        pendingSecondarySubtitleTrackOrdinal = nil
        mpvPendingTrackChoices.removeAll()
        hasResolvedAutomaticSubtitleSelection = true
        pendingEngineTracks = snapshot.selections.embedded
        pendingPrimarySource = snapshot.selections.primarySourceURL
        pendingSecondaryHandoff = snapshot.selections.secondary
        pendingPrimarySubtitleTranslationRestore = wasTranslating && !audioSubtitles.translatesAudio
        setPlaybackRate(snapshot.rate)
        if snapshot.duration > 0 { duration = MacMPVPlaybackPolicy.milliseconds(snapshot.duration) }
        pendingAudioOutputRestore = true
    }

    public func hasPendingPictureInPictureRestoreRequest() -> Bool {
        isRestoringPlayerFromPictureInPicture || pendingPictureInPictureRestoreFile != nil
    }

    public func markDeferredDrawablePlaybackSessionRestoreAfterPictureInPicture() {
        pendingDrawablePlaybackSessionRestoreAfterPictureInPicture = true
    }

    public func clearDeferredDrawablePlaybackSessionRestoreAfterPictureInPicture() {
        pendingDrawablePlaybackSessionRestoreAfterPictureInPicture = false
    }

    public func restoreDeferredDrawablePlaybackSessionAfterPictureInPictureIfNeeded() -> Bool {
        guard pendingDrawablePlaybackSessionRestoreAfterPictureInPicture,
              let activeVideoView else {
            return false
        }
        pendingDrawablePlaybackSessionRestoreAfterPictureInPicture = false
        mediaPlayer?.drawable = activeVideoView
        reloadCurrentItemPreservingPlaybackState()
        return true
    }

    public func requestVideoPlayerRestoreFromPictureInPicture(
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard let file = currentFile else { return false }
        isRestoringPlayerFromPictureInPicture = true
        pendingPictureInPictureRestoreFile = file
        
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let windowController = MacPlayerWindowManager.shared.currentPlayerWindowController,
               let window = windowController.window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            } else {
                MacPlayerWindowManager.shared.openPlayer(for: file)
            }
            if !self.isUsingMPV, let activeVideoView = self.activeVideoView {
                if self.mediaPlayer?.drawable as? VLCVideoView !== activeVideoView {
                    self.mediaPlayer?.drawable = activeVideoView
                    self.reloadCurrentItemPreservingPlaybackState()
                }
            }
            self.isRestoringPlayerFromPictureInPicture = false
            self.pendingPictureInPictureRestoreFile = nil
        }
        
        completion?(true)
        return true
    }
}
// This adapter keeps existing window/history behavior while the macOS backend is evaluated.
extension MacVLCPlaybackService {
    private func stopMPVPictureInPicture(restoringWindow: Bool = false) {
        guard let controller = mpvPiPController else { return }
        mpvPiPController = nil
        isVideoPiPActive = false
        controller.stop(restoringWindow: restoringWindow)
        // The native bridge restores its view after the close delegate unwinds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { _ = controller }
    }

    private func mpvStream(for file: VideoFile, url: URL, byteCache: MPVReadAheadByteCache? = nil) -> MacMPVStream? {
        if url.scheme?.lowercased() == "smb" {
            let reader = SMBAudioRangeReader(url: url)
            return MacMPVStream(metadata: { try await reader.metadata().size },
                read: { try await reader.read(offset: $0, count: $1) }, byteCache: byteCache)
        }
        guard ["ftp", "ftps", "sftp", "nfs"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let reader = FileAudioRangeReader(url: url, provider: file.serverType?.rawValue ?? (url.scheme == "ftps" ? "ftp" : url.scheme),
            serverID: file.jellyfinServerId ?? FilePlaybackCredentials.matchingServer(for: file, in: AppNetworkService.shared.servers)?.id.uuidString,
            path: file.serverPath, itemID: file.jellyfinItemId)
        return MacMPVStream(metadata: { try await reader.metadata().size },
            read: { try await reader.read(offset: $0, count: $1) }, byteCache: byteCache)
    }

    func makeMPVSeekPreviewProvider(for file: VideoFile) -> MPVPlaybackPreviewProvider? {
        guard isUsingMPV,
              let activeFile = mpvSeekPreviewFile,
              activeFile.id == file.id,
              let url = mpvSeekPreviewURL,
              duration > 0 else {
            return nil
        }

        let generation = mpvGeneration
        let sourceOptions = mpvSeekPreviewOptions
        guard let byteCache = mpvSeekPreviewReadCache else { return nil }
        let sourceSize = videoNaturalSize
        let sourceDuration = Double(duration) / 1000
        return MPVPlaybackPreviewProvider(duration: sourceDuration, sourceSize: sourceSize, maximumDimension: 360) { [weak self] targetTime in
            guard let self,
                  self.isUsingMPV,
                  self.mpvGeneration == generation,
                  self.currentFile?.id == activeFile.id else {
                return nil
            }

            let stream = self.mpvStream(for: activeFile, url: url, byteCache: byteCache)
            let sourceURL = stream == nil ? RuntimeNetworkAddressResolver.runtimeURL(from: url) : url
            return MPVPlaybackEngine.Configuration(
                url: sourceURL,
                start: targetTime,
                options: sourceOptions,
                subtitles: [],
                stream: stream
            )
        }
    }

    private func startMPV(file: VideoFile, url: URL, start: Double) {
        let previewReadCache = MPVReadAheadByteCache()
        mpvSeekPreviewReadCache = previewReadCache
        let defaults = UserDefaults.standard
        mpvPauseRequested = startsPaused
        mpvSubtitleSelectionRequest = nil
        mpvMirroredSecondaryID = nil
        mpvMirroredSecondaryText = ""
        mpvPendingImportedSubtitle = nil
        mpvHDRInfo = MPVHDRInfo()
        mpvTranslationSourceIsPartial = false
        mpvTranslationSourceKey = nil
        mpvTranslationUsesDecodedText = false
        mpvDecodedSubtitles = MacMPVDecodedSubtitles()
        mpvMetadata = [:]
        mpvLoaded = false
        mpvIPTVSnapshotScheduled = false
        mpvServerSubtitlesRegistered.removeAll()
        mpvArtworkTask?.cancel()
        mpvArtwork = nil
        mpvTracks = []
        nativeASSBounds = nil
        nativeASSHasContent = false
        mpvSeekable = false
        let preferenceKey = MacMPVTrackChoice.mediaKey(url: file.url, serverID: file.jellyfinServerId,
            itemID: file.jellyfinItemId, path: file.serverPath)
        mpvTrackPreferenceKey = preferenceKey
        mpvTrackChoices = defaults.data(forKey: preferenceKey).flatMap {
            try? JSONDecoder().decode([String: MacMPVTrackChoice].self, from: $0)
        } ?? [:]
        mpvPendingTrackChoices = mpvTrackChoices
        if pendingPrimarySubtitleTranslationRestore {
            mpvPendingTrackChoices["secondary"] = nil
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
        }
        // Explicit source requests take precedence over this item's saved choices.
        if file.preferredAudioTrackQuery != nil { mpvPendingTrackChoices["audio"] = nil }
        if file.preferredSubtitleTrackQuery != nil || file.disableSubtitlesOnStart { mpvPendingTrackChoices["primary"] = nil }
        if mpvPendingTrackChoices["audio"] != nil { pendingAudioTrackQuery = nil }
        if let primary = mpvPendingTrackChoices["primary"] {
            pendingSubtitleTrackQuery = nil
            disableSubtitlesOnStart = primary.signature == nil
        }
        if mpvPendingTrackChoices["secondary"] != nil { pendingSecondarySubtitleTrackQuery = nil; pendingSecondarySubtitleTrackOrdinal = nil }
        isPlaying = false
        hasReachedEnd = false
        hasReportedServerPlaying = false
        lastSavedHistoryTime = -100
        lastJellyfinSyncTime = -100
        currentTime = MacMPVPlaybackPolicy.milliseconds(start)
        duration = 0
        position = 0
        audioTracks = []
        subtitleTracks = []
        currentAudioTrackID = -1
        currentSubtitleTrackID = -1
        let speed = defaults.double(forKey: file.type == .audio ? "defaultAudioPlaybackSpeed" : "defaultPlaybackSpeed")
        targetRate = MPVPlaybackSpeed.clamped(Float(speed))
        var options = [
            "hwdec": defaults.string(forKey: "defaultVideoDecoder") == "hw" || defaults.string(forKey: "defaultVideoDecoder") == nil ? "videotoolbox" : "no",
            "volume": String(volume), "speed": String(targetRate), "pause": startsPaused ? "yes" : "no",
            "audio-delay": String(defaults.double(forKey: "audioDelaySeconds")),
            "sub-delay": String(defaults.double(forKey: "subtitleDelaySeconds")),
            "secondary-sid": "no", "sid": disableSubtitlesOnStart ? "no" : "auto",
            "slang": Locale.preferredLanguages.joined(separator: ",")
        ]
        if file.type == .audio { options["vid"] = "no" }
        let ratio = defaults.string(forKey: "defaultVideoAspectRatio") ?? ""
        if !ratio.isEmpty && ratio != "Default" { options["video-aspect-override"] = ratio }
        if file.serverType == .pan115 || file.url.host?.contains("115.com") == true {
            options["user-agent"] = Pan115Manager.defaultUserAgent
            options["referrer"] = "https://115.com"
            if let serverID = file.jellyfinServerId,
               let server = AppNetworkService.shared.savedServers.first(where: { $0.id.uuidString == serverID }),
               let cookie = server.passwordSecret ?? server.accessToken, !cookie.isEmpty {
                // mpv's list syntax escapes a single header by its UTF-8 byte length.
                let header = "Cookie: " + cookie.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                options["http-header-fields"] = "%\(header.utf8.count)%\(header)"
            }
        } else if file.serverType == .vod { options["user-agent"] = VODService.defaultUserAgent }
        mpvSeekPreviewURL = url
        mpvSeekPreviewFile = currentFile?.id == file.id ? currentFile : file
        mpvSeekPreviewOptions = options
        let generation = mpvGeneration
        let stream = mpvStream(for: file, url: url, byteCache: previewReadCache)
        audioSubtitles.setPlaybackReadAheadCache(stream == nil ? nil : previewReadCache)
        mpvEngine = MacMPVEngine(configuration: .init(url: url, start: file.isLiveStream || file.serverType == .iptv || MacMPVPlaybackPolicy.isLiveProtocol(url) ? 0 : start, options: options,
            subtitles: file.externalSubtitleCandidates.map(\.url).filter { $0.isFileURL || ["http", "https"].contains($0.scheme?.lowercased() ?? "") }, audioOnly: file.type == .audio,
            stream: stream, readAheadCache: !file.isLiveStream && file.serverType != .iptv), onState: { [weak self] state in
            guard let self, self.isUsingMPV, self.mpvGeneration == generation else { return }
            self.applyMPV(state)
        }, onError: { [weak self] _ in
            guard let self, self.isUsingMPV, self.mpvGeneration == generation else { return }
            self.saveProgress()
            self.reportServerStopped()
            self.mpvPiPController?.pipBridgeRequestRestore()
            self.stopMPVPictureInPicture()
            self.mpvGeneration = UUID()
            self.isLoading = false
            self.isPlaying = false
            self.playbackErrorMessage = platformShellString("Playback failed. This file may be unavailable or unsupported.")
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        })
        prepareMPVRemoteSidecars(for: file)
        if file.serverMediaStreams == nil { fetchServerMediaStreamsIfNeeded() }
        if file.type == .audio && (file.url.isFileURL || RemoteAudioArtworkReader.supports(url: file.url, provider: file.serverType?.rawValue)) {
            mpvArtworkTask = Task { @MainActor [weak self] in
                var artwork: NSImage?
                if file.url.isFileURL, let metadata = try? await AVURLAsset(url: file.url).load(.commonMetadata) {
                    for item in metadata where item.commonKey == .commonKeyArtwork {
                        guard !Task.isCancelled else { return }
                        guard let data = try? await item.load(.dataValue), data.count <= 20 * 1024 * 1024,
                              let image = NSImage(data: data) else { continue }
                        artwork = image
                        break
                    }
                }
                guard !Task.isCancelled else { return }
                if artwork == nil {
                    let data: Data?
                    if file.url.isFileURL {
                        data = try? await EmbeddedAudioArtworkReader.read(file.url)
                    } else {
                        data = try? await RemoteAudioArtworkReader.read(url: file.url, provider: file.serverType?.rawValue,
                            serverID: file.jellyfinServerId, path: file.serverPath, itemID: file.jellyfinItemId)
                    }
                    if let data { artwork = NSImage(data: data) }
                }
                guard !Task.isCancelled, let self, self.mpvGeneration == generation else { return }
                self.mpvArtwork = artwork
                self.updateNowPlayingInfo()
            }
        }
        if file.type == .audio { mpvEngine?.startAudio() }
        if file.type == .video && !rebuildingSession { bindAudioSubtitles(for: file) }
        updateMPVSecondaryStyle()
    }

    private func prepareMPVServerSubtitles() {
        guard isUsingMPV, mpvLoaded, let file = currentFile else { return }
        let tracks = embeddedServerSubtitleTracks(for: file)
        primaryServerSubtitleTracks.removeAll()
        for track in tracks {
            if let id = track.primaryTrackID {
                primaryServerSubtitleTracks[id] = track
            } else if track.isSelectable, let url = track.sourceURL,
                      track.isExternal || file.mediaSourceId?.isEmpty == false,
                      mpvServerSubtitlesRegistered.insert(track.id).inserted {
                let key = MacMPVTrackChoice.mediaKey(url: url)
                if !mpvTracks.contains(where: { $0.externalURL.map { MacMPVTrackChoice.mediaKey(url: $0) } == key }) {
                    mpvEngine?.addSubtitle(url, title: track.displayName, language: track.language ?? "")
                }
            }
        }

    }

    private func applyMPV(_ state: MacMPVEngine.State) {
        if bufferedRanges != state.bufferedRanges { bufferedRanges = state.bufferedRanges }
        if cacheInputBytesPerSecond != state.cacheInputBytesPerSecond { cacheInputBytesPerSecond = state.cacheInputBytesPerSecond }
        if cacheReadIdle != state.cacheReadIdle { cacheReadIdle = state.cacheReadIdle }
        if diskCacheMode != state.diskCacheMode { diskCacheMode = state.diskCacheMode }
        if diskCacheBytes != state.diskCacheBytes { diskCacheBytes = state.diskCacheBytes }
        if diskCacheReason != state.diskCacheReason { diskCacheReason = state.diskCacheReason }
        let becameLoaded = state.loaded && !mpvLoaded
        mpvLoaded = state.loaded
        isPlaying = state.loaded && !mpvPauseRequested && !state.paused && !state.ended
        isLoading = state.buffering && !mpvPauseRequested && !state.paused && !state.ended
        if state.loaded {
            currentTime = MacMPVPlaybackPolicy.milliseconds(state.time)
            duration = MacMPVPlaybackPolicy.milliseconds(state.duration)
            position = duration > 0 ? min(1, max(0, Float(currentTime) / Float(duration))) : 0
            hasStartedPlaybackForCurrentItem = true
        }
        if state.size.width > 1 && state.size.height > 1 && videoNaturalSize != state.size { videoNaturalSize = state.size }
        if mpvHDRInfo != state.hdrInfo { mpvHDRInfo = state.hdrInfo }
        mpvSeekable = state.seekable
        let tracksChanged = mpvTracks != state.tracks
        mpvTracks = state.tracks
        if mpvMetadata != state.metadata { mpvMetadata = state.metadata }
        func name(_ track: MacMPVEngine.Track) -> String {
            let parts = [track.title, track.language, track.codec].filter { !$0.isEmpty }
            return parts.isEmpty ? "\(platformShellString(track.type == "audio" ? "Audio Track" : "Subtitles")) \(track.id)" : parts.joined(separator: " · ")
        }
        let audio = state.tracks.filter { $0.type == "audio" }.map { MediaTrack(id: $0.id, name: name($0), isExternal: $0.external) }
        let subs = state.tracks.filter { $0.type == "sub" }
        let subtitles = subs.map { MediaTrack(id: $0.id, name: name($0), isExternal: $0.external) }
        let audioChanged = audioTracks != audio || currentAudioTrackID != state.audio
        if audioTracks != audio { audioTracks = audio }
        if subtitleTracks != subtitles { subtitleTracks = subtitles }
        if state.loaded && (tracksChanged || becameLoaded) { prepareMPVServerSubtitles() }
        let secondary = subs.map { track in
            EmbeddedSubtitleTrack(id: "mpv-\(track.id)", source: track.external ? .externalFile : .localContainer,
                primaryTrackID: track.id, codec: track.codec, language: track.language, title: track.title,
                displayName: name(track), sourceURL: track.externalURL, supportLevel: track.isBitmap ? .unsupportedBitmap : .textBestEffort,
                isExternal: track.external)
        }
        if secondarySubtitleTracks != secondary { secondarySubtitleTracks = secondary }
        currentAudioTrackID = state.audio
        if currentSubtitleTrackID != MacAudioSubtitlePlan.primaryID && mpvSubtitleSelectionRequest == nil {
            currentSubtitleTrackID = state.subtitle
        }
        let customSecondary = currentSecondarySubtitleTrackID == MacAudioSubtitlePlan.secondaryID
            || currentSecondarySubtitleTrackID == MacSubtitleTranslation.trackID
        if !customSecondary && mpvSubtitleSelectionRequest == nil && mpvMirroredSecondaryID == nil {
            currentSecondarySubtitleTrackID = state.secondary >= 0 ? "mpv-\(state.secondary)" : nil
            secondarySubtitleStatus = currentSecondarySubtitleTrackID == nil ? .idle : .ready
            let text = usesMPVTextSecondary ? state.secondaryText : ""
            if currentSecondarySubtitleParts.compactMap({ $0.text?.string }).joined(separator: "\n") != text {
                currentSecondarySubtitleParts = text.isEmpty ? [] : [SubtitlePart(start: 0, end: Double.greatestFiniteMagnitude, text: NSAttributedString(string: text))]
            }
        }
        let bounds = usesMPVNativeASSSecondary ? state.secondaryASSBounds : nil
        let hasContent = usesMPVNativeASSSecondary && state.secondaryASSHasContent
        if nativeASSBounds != bounds { nativeASSBounds = bounds }
        if nativeASSHasContent != hasContent { nativeASSHasContent = hasContent }
        updateMPVSecondaryStyle()
        if audioChanged { audioSubtitles.refreshDefaultAudioTrack() }
        if state.loaded {
            if isPlaying && state.size.width > 1 && !mpvIPTVSnapshotScheduled,
               currentFile?.isLiveStream == true || currentFile?.serverType == .iptv {
                mpvIPTVSnapshotScheduled = true
                let generation = mpvGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.mpvGeneration == generation else { return }
                    self.captureIPTVSnapshotIfNeeded()
                }
            }
            if let requested = mpvPendingImportedSubtitle,
               let selected = subs.first(where: { track in
                   track.externalURL.map { MacMPVTrackChoice.mediaKey(url: $0) } == MacMPVTrackChoice.mediaKey(url: requested)
               }) {
                // The common selector also releases a generated primary slot;
                // merely changing sid would leave that custom overlay selected.
                setSubtitleTrack(selected.id)
            }
            if !disableSubtitlesOnStart && pendingSubtitleTrackQuery == nil && mpvPendingTrackChoices["primary"] == nil && mpvPendingImportedSubtitle == nil {
                mpvApplyingAutomaticSelection = true
                _ = applyAutomaticSubtitleSelectionIfNeeded()
                mpvApplyingAutomaticSelection = false
            }
            for (slot, property) in [("audio", "aid"), ("primary", "sid"), ("secondary", "secondary-sid")] {
                if slot == "secondary" && !UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta") { continue }
                let tracks = state.tracks.filter { $0.type == (slot == "audio" ? "audio" : "sub") }
                if let choice = mpvPendingTrackChoices[slot], let id = choice.resolve(in: tracks) {
                    if slot == "secondary" { setSecondarySubtitleTrack(id < 0 ? nil : "mpv-\(id)") }
                    else if slot == "primary" { setSubtitleTrack(id) }
                    else { mpvEngine?.set(property, id < 0 ? "no" : String(id)) }
                    mpvPendingTrackChoices[slot] = nil
                    if slot == "primary" { hasResolvedAutomaticSubtitleSelection = true }
                }
            }
            // External subtitle loading is asynchronous; keep unresolved preferences until
            // their tracks arrive, or a manual selection explicitly releases them.
            if let query = pendingAudioTrackQuery, let track = audio.first(where: { trackNameMatches($0.name, query: query) }) {
                transport.selectAudioTrack(track.id)
                pendingAudioTrackQuery = nil
            }
            if !disableSubtitlesOnStart, let query = pendingSubtitleTrackQuery,
               let track = subtitles.first(where: { trackNameMatches($0.name, query: query) }) {
                setSubtitleTrack(track.id)
                pendingSubtitleTrackQuery = nil
                hasResolvedAutomaticSubtitleSelection = true
            }
            restorePendingSecondarySubtitleSelectionIfNeeded()
        }
        if state.loaded { restoreEngineHandoff() }
        if state.loaded && !hasReportedServerPlaying { hasReportedServerPlaying = reportServerPlaying() }
        if state.loaded {
            if abs(state.time - lastSavedHistoryTime) >= 5 { saveProgress(); lastSavedHistoryTime = state.time }
            reportServerProgress(force: false, reason: "time")
        }
        let decodedKey = "\(translationPlaybackGeneration)|mpv|\(currentSubtitleTrackID)"
        mpvDecodedSubtitles.select(decodedKey)
        if state.subtitle == currentSubtitleTrackID && currentSubtitleTrackID >= 0 {
            mpvDecodedSubtitles.append(text: state.primaryText, start: state.primaryStart, end: state.primaryEnd)
            mpvMirroredSecondaryText = state.primaryText
        }
        restorePendingPrimarySubtitleTranslationIfNeeded()
        refreshPrimarySubtitleTranslation()
        updateCurrentSecondarySubtitleParts(at: state.time)
        mpvPiPController?.update()
        updateNowPlayingInfo()
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        if state.ended && !hasReachedEnd { saveProgress(); reportServerStopped() }
        hasReachedEnd = state.ended
    }

    func clearMPVSecondarySelection(persistPreference: Bool) {
        guard isUsingMPV else { return }
        mpvPendingTrackChoices["secondary"] = nil
        pendingSecondarySubtitleTrackQuery = nil
        pendingSecondarySubtitleTrackOrdinal = nil
        applyMPVSubtitleSelection(secondaryOverride: -1)
        if persistPreference { saveMPVTrackChoice(slot: "secondary", id: -1) }
    }

    func canSelectMPVSubtitle(_ id: Int, secondary: Bool) -> Bool {
        guard isUsingMPV, id >= 0, mpvTracks.first(where: { $0.type == "sub" && $0.id == id })?.isBitmap == true else { return true }
        if secondary && !playbackCapabilities.supports(.secondaryBitmap, isVideo: currentFile?.type == .video) { return false }
        // A bitmap cannot be duplicated as app text; keep the current selection
        // and disable only the conflicting menu item, not the whole bitmap track.
        return secondary ? currentSubtitleTrackID != id : currentSecondarySubtitleTrackID != "mpv-\(id)"
    }

    private func applyMPVSubtitleSelection(secondaryOverride: Int? = nil) {
        guard let engine = mpvEngine else { return }
        let primary = max(-1, currentSubtitleTrackID)
        let secondary = secondaryOverride ?? mpvTracks.first(where: {
            $0.type == "sub" && currentSecondarySubtitleTrackID == "mpv-\($0.id)"
        })?.id ?? -1
        let mirrored = primary >= 0 && primary == secondary &&
            mpvTracks.first(where: { $0.type == "sub" && $0.id == primary })?.isBitmap == false
        let previousMirror = mpvMirroredSecondaryID
        let request = UUID(), generation = mpvGeneration
        mpvSubtitleSelectionRequest = request
        mpvDecodedSubtitles.select("\(translationPlaybackGeneration)|mpv|\(currentSubtitleTrackID)")
        mpvMirroredSecondaryID = mirrored ? primary : nil
        if previousMirror != mpvMirroredSecondaryID {
            secondarySubtitleLoadTask?.cancel()
            secondarySubtitleTimeline = nil
            mpvMirroredSecondaryText = ""
            currentSecondarySubtitleParts = []
        }
        engine.selectSubtitles(primary: primary, secondary: secondary) { [weak self] actualPrimary, actualSecondary in
            guard let self, self.mpvGeneration == generation,
                  self.mpvSubtitleSelectionRequest == request else { return }
            if self.currentSubtitleTrackID != MacAudioSubtitlePlan.primaryID {
                self.currentSubtitleTrackID = actualPrimary
            }
            // Changing the primary can synchronously disable its translation
            // and issue a newer secondary selection through the property observer.
            guard self.mpvSubtitleSelectionRequest == request else { return }
            self.mpvSubtitleSelectionRequest = nil
            let didMirror = mirrored && actualPrimary == primary
            self.mpvMirroredSecondaryID = didMirror ? primary : nil
            let selected = didMirror ? primary : actualSecondary
            let custom = self.currentSecondarySubtitleTrackID == MacAudioSubtitlePlan.secondaryID ||
                self.currentSecondarySubtitleTrackID == MacSubtitleTranslation.trackID
            if !custom {
                self.currentSecondarySubtitleTrackID = selected >= 0 ? "mpv-\(selected)" : nil
                self.secondarySubtitleStatus = selected >= 0 ? .ready : .idle
            }
            // A rejected command must never leave an optimistic checkmark or
            // an indefinitely pending request, including when a track disappears.
            if actualPrimary != primary { self.saveMPVTrackChoice(slot: "primary", id: actualPrimary) }
            if selected != secondary { self.saveMPVTrackChoice(slot: "secondary", id: selected) }
            if didMirror && !self.usesMPVNativeASSSecondary && (previousMirror != primary || self.secondarySubtitleTimeline == nil) {
                self.loadMPVMirroredSecondaryTimeline(trackID: primary)
            }
            self.updateMPVSecondaryStyle()
        }
    }

    private func saveMPVTrackChoice(slot: String, id: Int) {
        guard let key = mpvTrackPreferenceKey else { return }
        let tracks = mpvTracks.filter { $0.type == (slot == "audio" ? "audio" : "sub") }
        guard let choice = MacMPVTrackChoice.selected(id, in: tracks) else { return }
        mpvTrackChoices[slot] = choice
        if let data = try? JSONEncoder().encode(mpvTrackChoices) { UserDefaults.standard.set(data, forKey: key) }
    }

    var usesMPVTextSecondary: Bool {
        guard isUsingMPV, let selected = currentSecondarySubtitleTrackID else { return false }
        return !usesMPVNativeASSSecondary && mpvTracks.first { "mpv-\($0.id)" == selected && $0.type == "sub" }?.isBitmap != true
    }

    var usesMPVNativeASSSecondary: Bool {
        guard isUsingMPV, let selected = currentSecondarySubtitleTrackID,
              let track = mpvTracks.first(where: { "mpv-\($0.id)" == selected && $0.type == "sub" }),
              let rendering = MPVSecondarySubtitleRendering(trackID: track.id, tracks: mpvTracks) else { return false }
        return rendering.rendersASSNatively(primary: currentSubtitleTrackID)
    }

    func updateMPVSecondaryStyle() {
        mpvEngine?.set("secondary-sub-visibility", usesMPVTextSecondary ? "no" : "yes")
        let defaults = UserDefaults.standard
        let ratio = defaults.object(forKey: "secondarySubtitleVerticalPositionRatio.landscape") as? Double ?? -1
        let nativeASS = usesMPVNativeASSSecondary
        let nativeTrack = nativeASS ? mpvTracks.first(where: { currentSecondarySubtitleTrackID == "mpv-\($0.id)" })?.id : nil
        mpvEngine?.configureSecondaryASS(track: nativeTrack ?? -1,
            scale: defaults.object(forKey: "secondarySubtitleSizeScale") as? Double ?? 1,
            centerY: ratio >= 0 ? ratio : nil)
        mpvEngine?.set("secondary-sub-ass-override", nativeASS
            ? MPVSecondarySubtitleRendering.assOverride(hasCustomPosition: ratio >= 0)
            : (usesMPVTextSecondary ? "strip" : "yes"))
        let position = nativeASS ? 100
            : (defaults.object(forKey: "macMPVSecondarySubtitlePosition") as? Double ?? 10)
        mpvEngine?.set("secondary-sub-pos", String(min(100, max(0, position))))
        mpvEngine?.set("secondary-sub-delay", String(MPVSecondarySubtitleRendering.nativeDelay(
            primary: defaults.double(forKey: "subtitleDelaySeconds"),
            secondary: defaults.double(forKey: "secondarySubtitleDelaySeconds"))))
    }
}
#endif
