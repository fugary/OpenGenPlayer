import Foundation
public struct PlexLibrary: Identifiable {
    public let id: String
    public let title: String
    public let type: String
    public let thumb: String?
    public let art: String?
    public let updatedAt: Date?
    public var itemCount: Int?
    
    public init?(dictionary: [String: Any]) {
        self.init(dictionary: dictionary, itemCount: nil)
    }

    public init?(dictionary: [String: Any], itemCount: Int?) {
        guard let key = PlexValue.string(dictionary["key"]),
              let title = PlexValue.string(dictionary["title"]) else {
            return nil
        }
        self.id = key
        self.title = title
        self.type = PlexValue.string(dictionary["type"]) ?? "mixed"
        self.thumb = PlexValue.string(dictionary["thumb"])
        self.art = PlexValue.string(dictionary["art"])
        self.updatedAt = PlexValue.date(fromUnixTimestamp: dictionary["updatedAt"])
        self.itemCount = itemCount ?? PlexValue.int(dictionary["count"]) ?? PlexValue.int(dictionary["totalSize"])
    }
    
    public var iconName: String {
        switch type.lowercased() {
        case "movie": return "film"
        case "show": return "tv"
        case "artist", "music": return "music.note"
        case "photo": return "photo"
        default: return "folder"
        }
    }

    public var libraryType: JellyfinLibrary.LibraryType {
        switch type.lowercased() {
        case "movie": return .movies
        case "show": return .tvShows
        case "artist", "music": return .music
        case "photo": return .photos
        default: return .mixed
        }
    }
}
public struct PlexPerson: Identifiable {
    public let id: String
    public let name: String
    public let role: String?
    public let type: String?
    public let thumb: String?
    public let updatedAt: Date?

    public init(dictionary: [String: Any], fallbackType: String? = nil, role: String? = nil) {
        self.id = PlexValue.string(dictionary["id"])
            ?? PlexValue.string(dictionary["tagKey"])
            ?? PlexValue.string(dictionary["key"])
            ?? "\(fallbackType ?? "person")-\(PlexValue.string(dictionary["tag"]) ?? UUID().uuidString)"
        self.name = PlexValue.string(dictionary["tag"])
            ?? PlexValue.string(dictionary["name"])
            ?? "Unknown"
        self.role = role ?? PlexValue.string(dictionary["role"])
        self.type = PlexValue.string(dictionary["type"]) ?? fallbackType
        self.thumb = PlexValue.string(dictionary["thumb"])
        self.updatedAt = PlexValue.date(fromUnixTimestamp: dictionary["updatedAt"])
    }
}


public struct PlexMediaStream: Equatable {
    public let id: String
    public let streamType: Int
    public let title: String?
    public let displayTitle: String?
    public let extendedDisplayTitle: String?
    public let language: String?
    public let codec: String?
    public let channels: Int?
    public let width: Int?
    public let height: Int?
    public let selected: Bool
    public let defaultStream: Bool
    public let videoDynamicRange: String?
    public let videoRange: String?
    public let colorTransfer: String?
    public let dolbyVisionPresent: Bool
    public let frameRate: Double?
    public let bitDepth: Int?

    public init(dictionary: [String: Any]) {
        self.id = PlexValue.string(dictionary["id"])
            ?? PlexValue.string(dictionary["streamIdentifier"])
            ?? UUID().uuidString
        self.streamType = PlexValue.int(dictionary["streamType"]) ?? 0
        self.title = PlexValue.string(dictionary["title"])
        self.displayTitle = PlexValue.string(dictionary["displayTitle"])
        self.extendedDisplayTitle = PlexValue.string(dictionary["extendedDisplayTitle"])
        self.language = PlexValue.string(dictionary["language"])
        self.codec = PlexValue.string(dictionary["codec"])
        self.channels = PlexValue.int(dictionary["channels"])
        self.width = PlexValue.int(dictionary["width"])
        self.height = PlexValue.int(dictionary["height"])
        self.selected = PlexValue.bool(dictionary["selected"])
        self.defaultStream = PlexValue.bool(dictionary["default"])
        self.videoDynamicRange = PlexValue.string(dictionary["videoDynamicRange"])
        self.videoRange = PlexValue.string(dictionary["videoRange"])
        self.colorTransfer = PlexValue.string(dictionary["colorTrc"])
        self.dolbyVisionPresent = PlexValue.bool(dictionary["DOVIPresent"])
        self.frameRate = PlexValue.double(dictionary["frameRate"])
        self.bitDepth = PlexValue.int(dictionary["bitDepth"])
    }

    /// Normalized source fields for library details; colorRange is not HDR evidence.
    public var technicalMetadata: [String: Any] {
        guard streamType == 1 else { return [:] }
        var values: [String: Any] = [:]
        if let codec { values["Codec"] = codec }
        if let videoDynamicRange { values["VideoRangeType"] = videoDynamicRange }
        if let videoRange { values["VideoRange"] = videoRange }
        if let colorTransfer { values["ColorTransfer"] = colorTransfer }
        if dolbyVisionPresent, videoDynamicRange?.lowercased() != "doviinvalid" {
            values["VideoRangeType"] = "DolbyVision"
        }
        if let frameRate { values["RealFrameRate"] = frameRate }
        if let bitDepth { values["BitDepth"] = bitDepth }
        return values
    }

    public var isAudio: Bool { streamType == 2 }
    public var isSubtitle: Bool { streamType == 3 }
    public var isVideo: Bool { !isAudio && !isSubtitle }

    public var preferredQuery: String {
        if let displayTitle, !displayTitle.isEmpty { return displayTitle }
        if let extendedDisplayTitle, !extendedDisplayTitle.isEmpty { return extendedDisplayTitle }
        if let title, !title.isEmpty { return title }

        var parts: [String] = []
        if let language, !language.isEmpty {
            parts.append(language.uppercased())
        }
        if let codec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        if let channels, channels > 0 {
            parts.append("\(channels)ch")
        }
        return parts.joined(separator: " · ")
    }

    public func toDictionary() -> [String: Any] {
        var result: [String: Any] = [
            "Type": isAudio ? "Audio" : (isSubtitle ? "Subtitle" : "Unknown")
        ]
        if let language, !language.isEmpty {
            result["Language"] = language
        }
        if let codec, !codec.isEmpty {
            result["Codec"] = codec
        }
        if let channels {
            result["Channels"] = channels
        }
        let display = preferredQuery
        if !display.isEmpty {
            result["DisplayTitle"] = display
            result["Title"] = display
        }
        if selected {
            result["IsDefault"] = true
        }
        return result
    }
}
public struct PlexItem: Identifiable {
    public let id: String
    public let type: String
    public let guid: String?
    public let librarySectionID: Int?
    public let librarySectionTitle: String?
    public let librarySectionKey: String?
    public let title: String
    public let summary: String?
    public let year: Int?
    public let updatedAt: Date?
    public let addedAt: Date?
    public let originallyAvailableAt: Date?
    public let durationMillis: Int64?
    public let lastViewedAt: Date?
    public let viewOffsetMillis: Int64?
    public let viewCount: Int?
    public let index: Int?
    public let parentIndex: Int?
    public let parentRatingKey: String?
    public let grandparentRatingKey: String?
    public let parentTitle: String?
    public let grandparentTitle: String?
    public let parentThumb: String?
    public let grandparentThumb: String?
    public let thumb: String?
    public let art: String?
    public let contentRating: String?
    public let studio: String?
    public let childCount: Int?
    public let leafCount: Int?
    public let rating: Double?
    public let audienceRating: Double?
    public let genres: [String]
    public let people: [PlexPerson]
    public let providerIds: [String: String]
    public let mediaPartKey: String?
    public let mediaFilePath: String?
    public let mediaSize: Int64?
    public let mediaContainer: String?
    public let mediaBitrate: Int?
    public let mediaVideoWidth: Int?
    public let mediaVideoHeight: Int?
    public let mediaStreams: [PlexMediaStream]
    
    public init(dictionary: [String: Any]) {
        self.id = PlexValue.string(dictionary["ratingKey"])
            ?? PlexValue.string(dictionary["key"])
            ?? UUID().uuidString
        self.type = PlexValue.string(dictionary["type"]) ?? "unknown"
        self.guid = PlexValue.string(dictionary["guid"])
        self.librarySectionID = PlexValue.int(dictionary["librarySectionID"])
        self.librarySectionTitle = PlexValue.string(dictionary["librarySectionTitle"])
        self.librarySectionKey = PlexValue.string(dictionary["librarySectionKey"])
        self.title = PlexValue.string(dictionary["title"])
            ?? PlexValue.string(dictionary["grandparentTitle"])
            ?? "Unknown"
        self.summary = PlexValue.string(dictionary["summary"])
        self.year = PlexValue.int(dictionary["year"])
        self.updatedAt = PlexValue.date(fromUnixTimestamp: dictionary["updatedAt"])
        self.addedAt = PlexValue.date(fromUnixTimestamp: dictionary["addedAt"])
        self.originallyAvailableAt = PlexValue.date(
            fromString: PlexValue.string(dictionary["originallyAvailableAt"])
        )
        self.durationMillis = PlexValue.int64(dictionary["duration"])
        self.lastViewedAt = PlexValue.date(fromUnixTimestamp: dictionary["lastViewedAt"])
        self.viewOffsetMillis = PlexValue.int64(dictionary["viewOffset"])
        self.viewCount = PlexValue.int(dictionary["viewCount"])
        self.index = PlexValue.int(dictionary["index"])
        self.parentIndex = PlexValue.int(dictionary["parentIndex"])
        self.parentRatingKey = PlexValue.string(dictionary["parentRatingKey"])
        self.grandparentRatingKey = PlexValue.string(dictionary["grandparentRatingKey"])
        self.parentTitle = PlexValue.string(dictionary["parentTitle"])
        self.grandparentTitle = PlexValue.string(dictionary["grandparentTitle"])
        self.parentThumb = PlexValue.string(dictionary["parentThumb"])
        self.grandparentThumb = PlexValue.string(dictionary["grandparentThumb"])
        self.thumb = PlexValue.string(dictionary["thumb"])
        self.art = PlexValue.string(dictionary["art"])
        self.contentRating = PlexValue.string(dictionary["contentRating"])
        self.studio = PlexValue.string(dictionary["studio"])
        self.childCount = PlexValue.int(dictionary["childCount"])
        self.leafCount = PlexValue.int(dictionary["leafCount"])
        self.rating = PlexValue.double(dictionary["rating"])
        self.audienceRating = PlexValue.double(dictionary["audienceRating"])
        self.genres = (dictionary["Genre"] as? [[String: Any]] ?? [])
            .compactMap { PlexValue.string($0["tag"]) }

        var mergedPeople: [PlexPerson] = []
        var seenPeople = Set<String>()
        for (key, fallbackType) in [("Role", "Actor"), ("Director", "Director"), ("Writer", "Writer")] {
            let entries = dictionary[key] as? [[String: Any]] ?? []
            for entry in entries {
                let role = key == "Role" ? PlexValue.string(entry["role"]) : nil
                let person = PlexPerson(dictionary: entry, fallbackType: fallbackType, role: role)
                if seenPeople.insert("\(person.type ?? "person"):\(person.name)").inserted {
                    mergedPeople.append(person)
                }
            }
        }
        self.people = mergedPeople

        let guidEntries = dictionary["Guid"] as? [[String: Any]] ?? []
        var providerMap: [String: String] = [:]
        for entry in guidEntries {
            guard let rawId = PlexValue.string(entry["id"]) else { continue }
            let pieces = rawId.components(separatedBy: "://")
            let providerKey = (pieces.first ?? rawId).uppercased()
            let value = pieces.count > 1 ? pieces[1] : rawId
            if !providerKey.isEmpty, !value.isEmpty {
                providerMap[providerKey] = value
            }
        }
        self.providerIds = providerMap
        
        let firstMedia = (dictionary["Media"] as? [[String: Any]])?.first
        self.mediaContainer = PlexValue.string(firstMedia?["container"])
        self.mediaBitrate = PlexValue.int(firstMedia?["bitrate"])
        self.mediaVideoWidth = PlexValue.int(firstMedia?["width"])
        self.mediaVideoHeight = PlexValue.int(firstMedia?["height"])
        let firstPart = (firstMedia?["Part"] as? [[String: Any]])?.first
        self.mediaPartKey = PlexValue.string(firstPart?["key"])
        self.mediaFilePath = PlexValue.string(firstPart?["file"])
        self.mediaSize = PlexValue.int64(firstPart?["size"])
        self.mediaStreams = ((firstPart?["Stream"] as? [[String: Any]]) ?? []).map(PlexMediaStream.init(dictionary:))
    }
    
    public var isPlayable: Bool {
        switch type.lowercased() {
        case "movie", "episode", "clip":
            return true
        default:
            return false
        }
    }
    
    public var displayTitle: String {
        if type.lowercased() == "episode" {
            var prefix = ""
            if let show = grandparentTitle, !show.isEmpty {
                prefix += "\(show) - "
            }
            if let season = parentIndex, let episode = index {
                prefix += "S\(String(format: "%02d", season))E\(String(format: "%02d", episode)) - "
            }
            return prefix + title
        }
        return title
    }

    public var secondaryTitle: String? {
        switch type.lowercased() {
        case "episode":
            return parentTitle
        case "season":
            return grandparentTitle
        default:
            return nil
        }
    }

    public var posterPath: String? {
        thumb ?? parentThumb ?? grandparentThumb
    }

    public var backdropPath: String? {
        art ?? thumb ?? grandparentThumb ?? parentThumb
    }

    public var isContainer: Bool {
        switch type.lowercased() {
        case "show", "season", "artist", "album", "photoalbum":
            return true
        default:
            return false
        }
    }

    public var metadataLine: String? {
        var pieces: [String] = []

        if let year {
            pieces.append(String(year))
        }
        if let durationMillis, durationMillis > 0 {
            let minutes = Int((Double(durationMillis) / 60000.0).rounded())
            let hours = minutes / 60
            let mins = minutes % 60
            let runtimeStr = hours > 0 ? "\(hours)h \(mins)m" : "\(mins)m"
            pieces.append(runtimeStr)
        }
        if let size = mediaSize, size > 0 {
            let gb = Double(size) / 1_073_741_824.0
            if gb >= 1.0 {
                pieces.append("\(Int(gb.rounded())) GB")
            } else {
                let mb = Double(size) / 1_048_576.0
                if mb >= 1.0 {
                    pieces.append("\(Int(mb.rounded())) MB")
                } else {
                    let kb = Double(size) / 1024.0
                    pieces.append("\(Int(kb.rounded())) KB")
                }
            }
        }

        if pieces.isEmpty, let subtitle = secondaryTitle, !subtitle.isEmpty {
            pieces.append(subtitle)
        }

        return pieces.isEmpty ? nil : pieces.prefix(3).joined(separator: " • ")
    }

    public var librarySectionIdString: String? {
        if let librarySectionID {
            return String(librarySectionID)
        }
        guard let librarySectionKey, !librarySectionKey.isEmpty else {
            return nil
        }
        return librarySectionKey.split(separator: "/").last.map(String.init)
    }
    
    public var playbackPositionSeconds: TimeInterval {
        guard let viewOffsetMillis else { return 0 }
        return TimeInterval(viewOffsetMillis) / 1000.0
    }
    
    public var durationSeconds: TimeInterval? {
        guard let durationMillis else { return nil }
        return TimeInterval(durationMillis) / 1000.0
    }

    public var playbackProgress: Double? {
        guard let durationMillis, durationMillis > 0,
              let viewOffsetMillis, viewOffsetMillis > 0 else {
            return nil
        }
        let ratio = Double(viewOffsetMillis) / Double(durationMillis)
        return min(max(ratio, 0), 1)
    }

    public var maxVideoWidth: Int? {
        mediaVideoWidth ?? mediaStreams.first(where: \.isVideo)?.width
    }

    public var maxVideoHeight: Int? {
        mediaVideoHeight ?? mediaStreams.first(where: \.isVideo)?.height
    }

    public var isPlayed: Bool {
        (viewCount ?? 0) > 0
    }

    public var resumeDecision: RemotePlaybackResumeDecision {
        RemotePlaybackResumeDecision.fromPlaybackPosition(
            positionSeconds: playbackPositionSeconds,
            progressFraction: playbackProgress,
            played: isPlayed
        )
    }
}
public struct PlexValue {
    public static func string(_ value: Any?) -> String? {
        if let s = value as? String {
            return s
        }
        if let n = value as? NSNumber {
            return n.stringValue
        }
        return nil
    }
    
    public static func int(_ value: Any?) -> Int? {
        if let i = value as? Int {
            return i
        }
        if let n = value as? NSNumber {
            return n.intValue
        }
        if let s = value as? String {
            return Int(s)
        }
        return nil
    }

    public static func bool(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "1", "true", "yes":
                return true
            default:
                return false
            }
        }
        return false
    }
    
    public static func int64(_ value: Any?) -> Int64? {
        if let i = value as? Int64 {
            return i
        }
        if let i = value as? Int {
            return Int64(i)
        }
        if let n = value as? NSNumber {
            return n.int64Value
        }
        if let s = value as? String {
            return Int64(s)
        }
        return nil
    }

    public static func double(_ value: Any?) -> Double? {
        if let d = value as? Double {
            return d
        }
        if let n = value as? NSNumber {
            return n.doubleValue
        }
        if let s = value as? String {
            return Double(s)
        }
        return nil
    }

    public static func date(fromUnixTimestamp value: Any?) -> Date? {
        guard let timestamp = int64(value) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    public static func date(fromString value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) {
            return date
        }

        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.dateFormat = "yyyy-MM-dd"
        return fallback.date(from: value)
    }
}
