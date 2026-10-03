import Foundation

// MARK: - Flexible Types for Resilient JSON Decoding

public struct VODFlexibleString: Codable, Equatable, Hashable {
    public let value: String

    public init(_ value: String = "") {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self.value = str
        } else if let intVal = try? container.decode(Int.self) {
            self.value = String(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self.value = String(doubleVal)
        } else {
            self.value = ""
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct VODFlexibleInt: Codable, Equatable, Hashable {
    public let value: Int

    public init(_ value: Int = 0) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self.value = intVal
        } else if let str = try? container.decode(String.self),
                  let intVal = Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) {
            self.value = intVal
        } else if let doubleVal = try? container.decode(Double.self) {
            self.value = Int(doubleVal)
        } else {
            self.value = 0
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

// MARK: - Category Model

public struct VODCategory: Identifiable, Codable, Equatable, Hashable {
    public var id: String { typeId.value }
    public let typeId: VODFlexibleString
    public let typeName: String
    public let typePid: VODFlexibleInt?

    enum CodingKeys: String, CodingKey {
        case typeId = "type_id"
        case typeName = "type_name"
        case typePid = "type_pid"
    }

    public init(typeId: String, typeName: String, typePid: Int? = 0) {
        self.typeId = VODFlexibleString(typeId)
        self.typeName = typeName
        self.typePid = typePid.map { VODFlexibleInt($0) }
    }
}

// MARK: - Video Item Model

public struct VODItem: Identifiable, Codable, Equatable, Hashable {
    public var id: String { vodId.value }

    public let vodId: VODFlexibleString
    public let vodName: String
    public let typeId: VODFlexibleString?
    public let typeName: String?
    public let vodPic: String?
    public let vodRemarks: String?
    public let vodYear: String?
    public let vodArea: String?
    public let vodActor: String?
    public let vodDirector: String?
    public let vodContent: String?
    public let vodPlayFrom: String?
    public let vodPlayUrl: String?
    public let vodTime: String?
    public let vodLanguage: VODFlexibleString?
    public let vodDuration: VODFlexibleString?
    public let vodDoubanID: VODFlexibleString?

    enum CodingKeys: String, CodingKey {
        case vodId = "vod_id"
        case vodName = "vod_name"
        case typeId = "type_id"
        case typeName = "type_name"
        case vodPic = "vod_pic"
        case vodRemarks = "vod_remarks"
        case vodYear = "vod_year"
        case vodArea = "vod_area"
        case vodActor = "vod_actor"
        case vodDirector = "vod_director"
        case vodContent = "vod_content"
        case vodPlayFrom = "vod_play_from"
        case vodPlayUrl = "vod_play_url"
        case vodTime = "vod_time"
        case vodLanguage = "vod_lang"
        case vodDuration = "vod_duration"
        case vodDoubanID = "vod_douban_id"
    }

    public init(
        vodId: String,
        vodName: String,
        typeId: String? = nil,
        typeName: String? = nil,
        vodPic: String? = nil,
        vodRemarks: String? = nil,
        vodYear: String? = nil,
        vodArea: String? = nil,
        vodActor: String? = nil,
        vodDirector: String? = nil,
        vodContent: String? = nil,
        vodPlayFrom: String? = nil,
        vodPlayUrl: String? = nil,
        vodTime: String? = nil
    ) {
        self.vodId = VODFlexibleString(vodId)
        self.vodName = vodName
        self.typeId = typeId.map { VODFlexibleString($0) }
        self.typeName = typeName
        self.vodPic = vodPic
        self.vodRemarks = vodRemarks
        self.vodYear = vodYear
        self.vodArea = vodArea
        self.vodActor = vodActor
        self.vodDirector = vodDirector
        self.vodContent = vodContent
        self.vodPlayFrom = vodPlayFrom
        self.vodPlayUrl = vodPlayUrl
        self.vodTime = vodTime
        self.vodLanguage = nil
        self.vodDuration = nil
        self.vodDoubanID = nil
    }

    /// Returns clean synopsis with stripped HTML tags
    public var cleanSynopsis: String {
        guard let content = vodContent, !content.isEmpty else { return "" }
        return content
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression, range: nil)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses the play sources and episodes from `vodPlayFrom` and `vodPlayUrl`
    public var playSources: [VODPlaySource] {
        VODParser.parsePlaySources(from: vodPlayFrom, urlString: vodPlayUrl)
    }
}

// MARK: - Play Source & Episode

public struct VODPlaySource: Identifiable, Equatable, Hashable {
    public var id: String { name + "_\(index)" }
    public let index: Int
    public let name: String
    public let episodes: [VODEpisode]

    public init(index: Int, name: String, episodes: [VODEpisode]) {
        self.index = index
        self.name = name
        self.episodes = episodes
    }
}

public struct VODEpisode: Identifiable, Equatable, Hashable {
    public var id: String { "\(index)_\(url.absoluteString)" }
    public let index: Int
    public let name: String
    public let url: URL

    public init(index: Int, name: String, url: URL) {
        self.index = index
        self.name = name
        self.url = url
    }
}

// MARK: - API Response Model

public struct VODResponse: Codable {
    public let code: VODFlexibleInt?
    public let msg: String?
    public let page: VODFlexibleInt?
    public let pagecount: VODFlexibleInt?
    public let limit: VODFlexibleString?
    public let total: VODFlexibleInt?
    public let list: [VODItem]?
    public let categories: [VODCategory]?

    enum CodingKeys: String, CodingKey {
        case code
        case msg
        case page
        case pagecount
        case limit
        case total
        case list
        case categories = "class"
    }
}

// MARK: - Parser Helper

public enum VODParser {
    /// Parses `vod_play_from` and `vod_play_url` into structured `[VODPlaySource]`
    public static func parsePlaySources(from playFrom: String?, urlString: String?) -> [VODPlaySource] {
        guard let urlString = urlString, !urlString.isEmpty else { return [] }

        let sourceNames: [String] = {
            if let playFrom = playFrom, !playFrom.isEmpty {
                return playFrom.components(separatedBy: "$$$").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            return []
        }()

        let urlGroups = urlString.components(separatedBy: "$$$")
        var result: [VODPlaySource] = []

        for (idx, group) in urlGroups.enumerated() {
            let defaultName = idx < sourceNames.count ? sourceNames[idx] : "Source \(idx + 1)"
            let sourceName = defaultName.isEmpty ? "Source \(idx + 1)" : defaultName

            // Episodes in a group are separated by '#' or '\n' / '\r\n'
            let rawEpisodes = group.components(separatedBy: CharacterSet(charactersIn: "#\r\n"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            var episodes: [VODEpisode] = []
            for (epIdx, epRaw) in rawEpisodes.enumerated() {
                let epName: String
                let urlStr: String

                if let separatorIndex = epRaw.firstIndex(of: "$") {
                    epName = String(epRaw[..<separatorIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                    urlStr = String(epRaw[epRaw.index(after: separatorIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    epName = "EP \(epIdx + 1)"
                    urlStr = epRaw
                }

                if let url = URL(string: urlStr), url.scheme != nil {
                    episodes.append(VODEpisode(index: epIdx + 1, name: epName, url: url))
                }
            }

            if !episodes.isEmpty {
                result.append(VODPlaySource(index: idx, name: sourceName, episodes: episodes))
            }
        }

        return result
    }
}
