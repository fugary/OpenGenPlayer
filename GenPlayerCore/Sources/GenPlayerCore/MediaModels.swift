import Foundation
import CoreGraphics


public struct MediaItem: Identifiable, Equatable {
    public let id: UUID = UUID()
    public let url: URL
    public var title: String
    public var artist: String?
    public var album: String?
    public var albumArtist: String? = nil
    public var author: String? = nil
    public var composer: String? = nil
    public var artwork: AppImage?
    public var isRemote: Bool
    
    // Metadata for specific integrations
    public var jellyfinItemId: String?
    public var jellyfinServerId: String?
    public var serverType: ServerConfig.ServerType?
    public var playSessionId: String? = nil
    public var mediaSourceId: String? = nil
    public var remotePlaybackMethod: RemotePlaybackMethod? = nil
    public var shouldResetRemotePlayedStateOnPlaybackStart: Bool = false
    public var preferredPlaybackQualityID: String? = nil
    public var availablePlaybackQualityOptions: [RemotePlaybackQualityOption] = []
    public var seriesId: String?
    public var seasonId: String?
    
    // Rich media info from server (Jellyfin/Emby) for MediaInfo display
    public var serverMediaStreams: [[String: Any]]?
    public var serverContainer: String?
    public var serverSize: Int64?
    public var serverBitrate: Int?
    public var serverPath: String?
    
    // Subtitles
    public var externalSubtitleURL: URL?
    public var externalSubtitleCandidates: [ExternalSubtitleCandidate] = []
    
    // Initial State
    public var startPosition: Double? = nil
    public var savedAudioTrackIndex: Int?
    public var savedSubtitleTrackIndex: Int?
    public var preferredAudioTrackQuery: String? = nil
    public var preferredSubtitleTrackQuery: String? = nil
    public var preferredAudioTrackOrdinal: Int? = nil
    public var preferredSubtitleTrackOrdinal: Int? = nil
    
    // The original video file this item was created from, used for fallback PiP audio overlays
    public var videoFile: VideoFile? = nil
    
    public var isLiveStream: Bool {
        serverType == .iptv || (videoFile?.serverType == .iptv)
    }
    
    public init(
        url: URL,
        title: String,
        artist: String? = nil,
        album: String? = nil,
        albumArtist: String? = nil,
        author: String? = nil,
        composer: String? = nil,
        artwork: AppImage? = nil,
        isRemote: Bool = false,
        jellyfinItemId: String? = nil,
        jellyfinServerId: String? = nil,
        serverType: ServerConfig.ServerType? = nil,
        playSessionId: String? = nil,
        mediaSourceId: String? = nil,
        remotePlaybackMethod: RemotePlaybackMethod? = nil,
        shouldResetRemotePlayedStateOnPlaybackStart: Bool = false,
        preferredPlaybackQualityID: String? = nil,
        availablePlaybackQualityOptions: [RemotePlaybackQualityOption] = [],
        seriesId: String? = nil,
        seasonId: String? = nil,
        serverMediaStreams: [[String: Any]]? = nil,
        serverContainer: String? = nil,
        serverSize: Int64? = nil,
        serverBitrate: Int? = nil,
        serverPath: String? = nil,
        externalSubtitleURL: URL? = nil,
        externalSubtitleCandidates: [ExternalSubtitleCandidate] = [],
        startPosition: Double? = nil,
        savedAudioTrackIndex: Int? = nil,
        savedSubtitleTrackIndex: Int? = nil,
        preferredAudioTrackQuery: String? = nil,
        preferredSubtitleTrackQuery: String? = nil,
        preferredAudioTrackOrdinal: Int? = nil,
        preferredSubtitleTrackOrdinal: Int? = nil,
        videoFile: VideoFile? = nil
    ) {
        self.url = url
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.author = author
        self.composer = composer
        self.artwork = artwork
        self.isRemote = isRemote
        self.jellyfinItemId = jellyfinItemId
        self.jellyfinServerId = jellyfinServerId
        self.serverType = serverType
        self.playSessionId = playSessionId
        self.mediaSourceId = mediaSourceId
        self.remotePlaybackMethod = remotePlaybackMethod
        self.shouldResetRemotePlayedStateOnPlaybackStart = shouldResetRemotePlayedStateOnPlaybackStart
        self.preferredPlaybackQualityID = preferredPlaybackQualityID
        self.availablePlaybackQualityOptions = availablePlaybackQualityOptions
        self.seriesId = seriesId
        self.seasonId = seasonId
        self.serverMediaStreams = serverMediaStreams
        self.serverContainer = serverContainer
        self.serverSize = serverSize
        self.serverBitrate = serverBitrate
        self.serverPath = serverPath
        self.externalSubtitleURL = externalSubtitleURL
        self.externalSubtitleCandidates = externalSubtitleCandidates
        self.startPosition = startPosition
        self.savedAudioTrackIndex = savedAudioTrackIndex
        self.savedSubtitleTrackIndex = savedSubtitleTrackIndex
        self.preferredAudioTrackQuery = preferredAudioTrackQuery
        self.preferredSubtitleTrackQuery = preferredSubtitleTrackQuery
        self.preferredAudioTrackOrdinal = preferredAudioTrackOrdinal
        self.preferredSubtitleTrackOrdinal = preferredSubtitleTrackOrdinal
        self.videoFile = videoFile
    }
    
    public static func == (lhs: MediaItem, rhs: MediaItem) -> Bool {
        return lhs.id == rhs.id
    }
}
public enum PlayerStatus: String {
    case idle
    case buffering
    case playing
    case paused
    case error
    case ended
}
public enum VideoDisplayMode: String, CaseIterable {
    case fit
    case fill
}
public struct MediaTrack: Identifiable, Equatable {
    public let id: Int
    public let name: String
    public let isExternal: Bool
    
    public init(id: Int, name: String, isExternal: Bool) {
        self.id = id
        self.name = name
        self.isExternal = isExternal
    }
}
public struct ExternalSubtitleCandidate: Codable, Equatable {
    public let url: URL
    public let displayName: String
    
    public init(url: URL, displayName: String) {
        self.url = url
        self.displayName = displayName
    }
}

public enum EmbeddedSubtitleSource: String, Codable {
    case localContainer
    #if os(iOS) || os(tvOS)
    case remoteContainer
    #endif
    case jellyfinMediaStream
    case embyMediaStream
    case externalFile
}

public enum EmbeddedSubtitleSupportLevel: String, Codable {
    case textSupported
    case textBestEffort
    case unsupportedBitmap
    case unsupportedUnknown
}

public enum SecondarySubtitleStatus: String, Codable {
    case disabled
    case loading
    case ready
    case unsupported
    case failed
}

public struct EmbeddedSubtitleTrack: Identifiable, Equatable, Codable {
    public let id: String
    public let source: EmbeddedSubtitleSource
    public let streamIndex: Int?
    public let primaryTrackID: Int?
    public let codec: String?
    public let language: String?
    public let title: String?
    public let displayName: String
    public let sourceURL: URL?
    public let supportLevel: EmbeddedSubtitleSupportLevel
    public let isExternal: Bool

    public var isSelectable: Bool {
        supportLevel == .textSupported || supportLevel == .textBestEffort
    }

    public init(
        id: String,
        source: EmbeddedSubtitleSource,
        streamIndex: Int? = nil,
        primaryTrackID: Int? = nil,
        codec: String? = nil,
        language: String? = nil,
        title: String? = nil,
        displayName: String,
        sourceURL: URL? = nil,
        supportLevel: EmbeddedSubtitleSupportLevel,
        isExternal: Bool = false
    ) {
        self.id = id
        self.source = source
        self.streamIndex = streamIndex
        self.primaryTrackID = primaryTrackID
        self.codec = codec
        self.language = language
        self.title = title
        self.displayName = displayName
        self.sourceURL = sourceURL
        self.supportLevel = supportLevel
        self.isExternal = isExternal
    }
}

public struct PlayerState {
    public var status: PlayerStatus = .idle
    public var currentItem: MediaItem?
    
    // Playback Progress
    public var currentTime: Double = 0.0
    public var duration: Double = 0.0
    public var progress: Float = 0.0 // 0.0 - 1.0
    
    // Tracks
    public var audioTracks: [MediaTrack] = []
    public var subtitleTracks: [MediaTrack] = []
    public var currentAudioTrackID: Int = -1
    public var currentSubtitleTrackID: Int = -1
    public var secondarySubtitleTracks: [EmbeddedSubtitleTrack] = []
    public var currentSecondarySubtitleTrackID: String? = nil
    public var secondarySubtitleStatus: SecondarySubtitleStatus = .disabled
    public var secondarySubtitleParts: [SubtitlePart] = []
    public var secondarySubtitleDelay: TimeInterval = 0.0
    
    // Options
    public var rate: Float = 1.0
    public var volume: Float = 1.0
    public var aspectRatio: String = ""
    public var videoDisplayMode: VideoDisplayMode = .fit
    public var interactiveVideoZoomScale: CGFloat = 1.0
    public var interactiveVideoOffset: CGSize = .zero
    
    // Video Info
    public var videoResolution: String = ""
    public var isBuffering: Bool {
        return status == .buffering
    }
    public var isPlaying: Bool {
        return status == .playing
    }
    
    public init() {}
}
