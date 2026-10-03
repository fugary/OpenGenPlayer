import Foundation

// MARK: - Authentication
public struct EmbyAuthRequest: Codable {
    public init(username: String, pw: String) {
        self.username = username
        self.pw = pw
    }
    public let username: String
    public let pw: String
    
public enum CodingKeys: String, CodingKey {
        case username = "Username"
        case pw = "Pw"
    }
}
public struct EmbyAuthResult: Codable {
    public let user: EmbyUser
    public let accessToken: String
    public let serverId: String
    
public enum CodingKeys: String, CodingKey {
        case user = "User"
        case accessToken = "AccessToken"
        case serverId = "ServerId"
    }
}
public struct EmbyUser: Codable {
    public let id: String
    public let name: String
    public let serverId: String?
    public let primaryImageTag: String?
    
public enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case serverId = "ServerId"
        case primaryImageTag = "PrimaryImageTag"
    }
}

// MARK: - Libraries/Views
public struct EmbyViewsResponse: Codable {
    public let items: [EmbyLibrary]
    public let totalRecordCount: Int?
    
public enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}
public struct EmbyLibrary: Codable, Identifiable {
    public let id: String
    public let name: String
    public let collectionType: String?
    public let imageTags: [String: String]?
    public let primaryImageItemId: String?
    public let childCount: Int?
    public let recursiveItemCount: Int?
    
    public enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case collectionType = "CollectionType"
        case imageTags = "ImageTags"
        case primaryImageItemId = "PrimaryImageItemId"
        case childCount = "ChildCount"
        case recursiveItemCount = "RecursiveItemCount"
    }

    public var totalItemCount: Int? {
        if let recursive = recursiveItemCount, recursive > 0 {
            return recursive
        }
        if let child = childCount, child > 0 {
            return child
        }
        return nil
    }
    
    public var primaryImageTag: String? {
        return imageTags?["Primary"]
    }
    
    public var libraryType: LibraryType {
        switch collectionType?.lowercased() {
        case "movies": return .movies
        case "tvshows": return .tvShows
        case "music": return .music
        case "homevideos", "photos": return .photos
        case "boxsets": return .collections
        case "playlists": return .playlists
        default:
            if name.lowercased().contains("playlist") {
                return .playlists
            }
            return .mixed
        }
    }
    
public enum LibraryType {
        case movies, tvShows, music, photos, collections, playlists, mixed
        
        public var icon: String {
            switch self {
            case .movies: return "film"
            case .tvShows: return "tv"
            case .music: return "music.note"
            case .photos: return "photo"
            case .collections: return "square.stack"
            case .playlists: return "music.note.list"
            case .mixed: return "folder"
            }
        }

        var usesSpecialShelfCard: Bool {
            self == .collections || self == .playlists
        }

        public var showsHomeShelfSection: Bool {
            !usesSpecialShelfCard
        }

        public var browseIncludeTypes: [String]? {
            switch self {
            case .movies:
                return ["Movie"]
            case .tvShows:
                return ["Series"]
            case .music:
                return ["MusicAlbum"]
            case .collections:
                return ["BoxSet"]
            case .playlists:
                return ["Playlist"]
            case .photos, .mixed:
                return nil
            }
        }
    }
}

// MARK: - Media Items
public struct EmbyItemsResponse: Codable {
    public let items: [EmbyItem]
    public let totalRecordCount: Int?
    
public enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}
public struct EmbyItem: Codable, Identifiable {
    public let id: String
    public let name: String
    public let type: String
    public let serverId: String?
    public let seriesId: String?
    public let seriesName: String?
    public let seasonId: String?
    public let seasonName: String?
    public let indexNumber: Int?
    public let parentIndexNumber: Int?
    public let productionYear: Int?
    public let communityRating: Double?
    public let officialRating: String?
    public let overview: String?
    public let premiereDate: String?
    public let endDate: String?
    public let runTimeTicks: Int64?
    public let primaryImageTag: String?
    public let backdropImageTags: [String]?
    public let parentBackdropItemId: String?
    public let parentBackdropImageTags: [String]?
    public let parentLogoItemId: String?
    public let parentLogoImageTag: String?
    public let imageTags: [String: String]?
    public let userData: EmbyUserData?
    public let mediaSources: [EmbyMediaSource]?
    public let childCount: Int?
    public let recursiveItemCount: Int?
    public let people: [EmbyPerson]?
    public let providerIds: [String: String]?
    public let genres: [String]?
    public let productionLocations: [String]?
    public let homePageUrl: String?
    
public enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case type = "Type"
        case serverId = "ServerId"
        case seriesId = "SeriesId"
        case seriesName = "SeriesName"
        case seasonId = "SeasonId"
        case seasonName = "SeasonName"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case productionYear = "ProductionYear"
        case communityRating = "CommunityRating"
        case officialRating = "OfficialRating"
        case overview = "Overview"
        case premiereDate = "PremiereDate"
        case endDate = "EndDate"
        case runTimeTicks = "RunTimeTicks"
        case primaryImageTag = "PrimaryImageTag"
        case backdropImageTags = "BackdropImageTags"
        case parentBackdropItemId = "ParentBackdropItemId"
        case parentBackdropImageTags = "ParentBackdropImageTags"
        case parentLogoItemId = "ParentLogoItemId"
        case parentLogoImageTag = "ParentLogoImageTag"
        case imageTags = "ImageTags"
        case userData = "UserData"
        case mediaSources = "MediaSources"
        case childCount = "ChildCount"
        case recursiveItemCount = "RecursiveItemCount"
        case people = "People"
        case providerIds = "ProviderIds"
        case genres = "Genres"
        case productionLocations = "ProductionLocations"
        case homePageUrl = "HomePageUrl"
    }
    
    public var runtimeMinutes: Int? {
        guard let ticks = runTimeTicks else { return nil }
        return Int(ticks / 10_000_000 / 60)
    }
    
    public var displayTitle: String {
        switch type {
        case "Episode":
            var title = ""
            if let series = seriesName {
                title += "\(series) - "
            }
            if let season = parentIndexNumber, let episode = indexNumber {
                title += "S\(String(format: "%02d", season))E\(String(format: "%02d", episode)) - "
            }
            title += name
            return title
        case "Season":
            return seasonName ?? name
        default:
            return name
        }
    }
    

    
    public var subtitle: String? {
        switch type {
        case "Episode":
            return seriesName
        case "Series":
            var parts: [String] = []
            if let year = productionYear { parts.append("\(year)") }
            return parts.joined(separator: " • ")
        case "Season":
            return seriesName
        case "Movie":
            if let year = productionYear { return "\(year)" }
            return nil
        case "Playlist":
            return NSLocalizedString("Playlist", comment: "")
        case "BoxSet":
            return NSLocalizedString("Collection", comment: "")
        case "Folder":
            return NSLocalizedString("Folder", comment: "")
        default:
            if let year = productionYear { return "\(year)" }
            return nil
        }
    }

    public var metadataLine: String? {
        var pieces: [String] = []

        if let subtitle = subtitle, !subtitle.isEmpty {
            pieces.append(subtitle)
        }
        if let officialRating, !officialRating.isEmpty {
            pieces.append(officialRating)
        }

        return pieces.isEmpty ? nil : pieces.joined(separator: " • ")
    }
    
    public var isPlayable: Bool {
        return type == "Movie" || type == "Episode" || type == "Audio" || type == "MusicVideo"
    }
    
    public var isContainer: Bool {
        return type == "Series" || type == "Season" || type == "Playlist" || type == "MusicAlbum" || type == "BoxSet" || type == "Folder"
    }
}
public struct EmbyUserData: Codable {
    public let playbackPositionTicks: Int64?
    public let playCount: Int?
    public let isFavorite: Bool?
    public let played: Bool?
    public let playedPercentage: Double?
    public var lastPlayedDate: String? = nil
    
public enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks"
        case playCount = "PlayCount"
        case isFavorite = "IsFavorite"
        case played = "Played"
        case playedPercentage = "PlayedPercentage"
        case lastPlayedDate = "LastPlayedDate"
    }
    
    public var progressPercentage: Double {
        return playedPercentage ?? 0
    }

    public func resumeDecision(
        runtimeTicks: Int64?,
        playedOverride: Bool? = nil
    ) -> RemotePlaybackResumeDecision {
        RemotePlaybackResumeDecision.fromServerPlaybackState(
            playbackTicks: playbackPositionTicks,
            runtimeTicks: runtimeTicks,
            playedPercentage: playedPercentage,
            played: playedOverride ?? (played ?? false)
        )
    }
}
public struct EmbyMediaSource: Codable {
    public let id: String
    public let path: String?
    public let container: String?
    public let size: Int64?
    public let bitrate: Int?
    public let directStreamUrl: String?
    public let transcodingUrl: String?
    public let supportsDirectPlay: Bool?
    public let supportsDirectStream: Bool?
    public let supportsTranscoding: Bool?
    public let mediaStreams: [EmbyMediaStream]?
    
public enum CodingKeys: String, CodingKey {
        case id = "Id"
        case path = "Path"
        case container = "Container"
        case size = "Size"
        case bitrate = "Bitrate"
        case directStreamUrl = "DirectStreamUrl"
        case transcodingUrl = "TranscodingUrl"
        case supportsDirectPlay = "SupportsDirectPlay"
        case supportsDirectStream = "SupportsDirectStream"
        case supportsTranscoding = "SupportsTranscoding"
        case mediaStreams = "MediaStreams"
    }
    
    public var videoStream: EmbyMediaStream? {
        return mediaStreams?.first(where: { $0.type == "Video" })
    }
}
public struct EmbyMediaStream: Codable {
    public let index: Int?
    public let type: String
    public let codec: String?
    public let width: Int?
    public let height: Int?
    public let title: String?
    public let displayTitle: String?
    public let displayLanguage: String?
    public let isDefault: Bool?
    public let bitRate: Int?
    public let channels: Int?
    public let sampleRate: Int?
    public let channelLayout: String?
    public let language: String?
    public let profile: String?
    public let level: Int?
    public let aspectRatio: String?
    public let bitDepth: Int?
    public let pixelFormat: String?
    public let videoRange: String?
    public let videoRangeType: String?
    public let colorTransfer: String?
    public let dvProfile: Int?
    public let realFrameRate: Double?
    public let averageFrameRate: Double?
    public let isForced: Bool?
    public let isExternal: Bool?
    public let deliveryMethod: String?
    public let deliveryUrl: String?
    public let isTextSubtitleStream: Bool?
    
public enum CodingKeys: String, CodingKey {
        case index = "Index"
        case type = "Type"
        case codec = "Codec"
        case width = "Width"
        case height = "Height"
        case title = "Title"
        case displayTitle = "DisplayTitle"
        case displayLanguage = "DisplayLanguage"
        case isDefault = "IsDefault"
        case bitRate = "BitRate"
        case channels = "Channels"
        case sampleRate = "SampleRate"
        case channelLayout = "ChannelLayout"
        case language = "Language"
        case profile = "Profile"
        case level = "Level"
        case aspectRatio = "AspectRatio"
        case bitDepth = "BitDepth"
        case pixelFormat = "PixelFormat"
        case videoRange = "VideoRange"
        case videoRangeType = "VideoRangeType"
        case colorTransfer = "ColorTransfer"
        case dvProfile = "DvProfile"
        case realFrameRate = "RealFrameRate"
        case averageFrameRate = "AverageFrameRate"
        case isForced = "IsForced"
        case isExternal = "IsExternal"
        case deliveryMethod = "DeliveryMethod"
        case deliveryUrl = "DeliveryUrl"
        case isTextSubtitleStream = "IsTextSubtitleStream"
    }
    
    /// Convert to dictionary for MediaItem.serverMediaStreams
    public func toDictionary() -> [String: Any] {
        var dict: [String: Any] = ["Type": type]
        if let v = index { dict["Index"] = v }
        if let v = codec { dict["Codec"] = v }
        if let v = width { dict["Width"] = v }
        if let v = height { dict["Height"] = v }
        if let v = title { dict["Title"] = v }
        if let v = displayTitle { dict["DisplayTitle"] = v }
        if let v = displayLanguage { dict["DisplayLanguage"] = v }
        if let v = isDefault { dict["IsDefault"] = v }
        if let v = bitRate { dict["BitRate"] = v }
        if let v = channels { dict["Channels"] = v }
        if let v = sampleRate { dict["SampleRate"] = v }
        if let v = channelLayout { dict["ChannelLayout"] = v }
        if let v = language { dict["Language"] = v }
        if let v = profile { dict["Profile"] = v }
        if let v = level { dict["Level"] = v }
        if let v = aspectRatio { dict["AspectRatio"] = v }
        if let v = bitDepth { dict["BitDepth"] = v }
        if let v = pixelFormat { dict["PixelFormat"] = v }
        if let v = videoRange { dict["VideoRange"] = v }
        if let v = videoRangeType { dict["VideoRangeType"] = v }
        if let v = colorTransfer { dict["ColorTransfer"] = v }
        if let v = dvProfile { dict["DvProfile"] = v }
        if let v = realFrameRate { dict["RealFrameRate"] = v }
        if let v = averageFrameRate { dict["AverageFrameRate"] = v }
        if let v = isForced { dict["IsForced"] = v }
        if let v = isExternal { dict["IsExternal"] = v }
        if let v = deliveryMethod { dict["DeliveryMethod"] = v }
        if let v = deliveryUrl { dict["DeliveryUrl"] = v }
        if let v = isTextSubtitleStream { dict["IsTextSubtitleStream"] = v }
        return dict
    }
}

// MARK: - Playback Info
public struct EmbyPlaybackInfo: Codable {
    public init(mediaSources: [EmbyMediaSource] = [], playSessionId: String? = nil) {
        self.mediaSources = mediaSources
        self.playSessionId = playSessionId
    }
    public let mediaSources: [EmbyMediaSource]
    public let playSessionId: String?
    
public enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"
        case playSessionId = "PlaySessionId"
    }
}
// MARK: - People

// MARK: - People
public struct EmbyPerson: Codable, Identifiable {
    public let id: String
    public let name: String
    public let role: String?
    public let type: String?
    public let primaryImageTag: String?
    
public enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case role = "Role"
        case type = "Type"
        case primaryImageTag = "PrimaryImageTag"
        case imageTags = "ImageTags"
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        // Robust ID decoding
        if let idVal = try? container.decode(String.self, forKey: .id), !idVal.isEmpty {
            self.id = idVal
        } else if let nameVal = try? container.decode(String.self, forKey: .name), !nameVal.isEmpty {
            self.id = nameVal
        } else {
            self.id = UUID().uuidString
        }
        
        self.name = (try? container.decode(String.self, forKey: .name)) ?? "Unknown"
        self.role = try? container.decode(String.self, forKey: .role)
        self.type = try? container.decode(String.self, forKey: .type)
        
        // Try PrimaryImageTag, then look inside ImageTags dictionary
        if let tag = try? container.decode(String.self, forKey: .primaryImageTag) {
            self.primaryImageTag = tag
        } else if let tags = try? container.decode([String: String].self, forKey: .imageTags),
                  let primary = tags["Primary"] {
            self.primaryImageTag = primary
        } else {
            self.primaryImageTag = nil
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(type, forKey: .type)
        try container.encodeIfPresent(primaryImageTag, forKey: .primaryImageTag)
    }
}
