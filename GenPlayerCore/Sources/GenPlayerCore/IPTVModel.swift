import Foundation

public struct IPTVChannel: Identifiable, Codable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var group: String
    public var groups: [String]
    public var logoURL: URL?
    public var tvgId: String?
    public var tvgName: String?
    public var url: URL
    public var backupURLs: [URL]
    public var httpUserAgent: String?
    public var httpReferrer: String?
    public var catchup: String?
    public var catchupSource: String?
    public var isFavorite: Bool
    
    public init(
        id: String,
        name: String,
        group: String = "Other",
        groups: [String] = [],
        logoURL: URL? = nil,
        tvgId: String? = nil,
        tvgName: String? = nil,
        url: URL,
        backupURLs: [URL] = [],
        httpUserAgent: String? = nil,
        httpReferrer: String? = nil,
        catchup: String? = nil,
        catchupSource: String? = nil,
        isFavorite: Bool = false
    ) {
        self.id = id
        self.name = name
        let cleanGroup = group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Other" : group
        self.group = cleanGroup
        self.groups = groups.isEmpty ? [cleanGroup] : groups
        self.logoURL = logoURL
        self.tvgId = tvgId
        self.tvgName = tvgName
        self.url = url
        self.backupURLs = backupURLs
        self.httpUserAgent = httpUserAgent
        self.httpReferrer = httpReferrer
        self.catchup = catchup
        self.catchupSource = catchupSource
        self.isFavorite = isFavorite
    }
    
    public func matches(group: String) -> Bool {
        if group == "ALL" { return true }
        if self.group.caseInsensitiveCompare(group) == .orderedSame { return true }
        return groups.contains { $0.caseInsensitiveCompare(group) == .orderedSame }
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, name, group, groups, logoURL, tvgId, tvgName, url, backupURLs, httpUserAgent, httpReferrer, catchup, catchupSource, isFavorite
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        let decodedGroup = try container.decodeIfPresent(String.self, forKey: .group) ?? "Other"
        self.group = decodedGroup
        let decodedGroups = try container.decodeIfPresent([String].self, forKey: .groups)
        self.groups = (decodedGroups != nil && !decodedGroups!.isEmpty) ? decodedGroups! : [decodedGroup]
        self.logoURL = try container.decodeIfPresent(URL.self, forKey: .logoURL)
        self.tvgId = try container.decodeIfPresent(String.self, forKey: .tvgId)
        self.tvgName = try container.decodeIfPresent(String.self, forKey: .tvgName)
        self.url = try container.decode(URL.self, forKey: .url)
        self.backupURLs = try container.decodeIfPresent([URL].self, forKey: .backupURLs) ?? []
        self.httpUserAgent = try container.decodeIfPresent(String.self, forKey: .httpUserAgent)
        self.httpReferrer = try container.decodeIfPresent(String.self, forKey: .httpReferrer)
        self.catchup = try container.decodeIfPresent(String.self, forKey: .catchup)
        self.catchupSource = try container.decodeIfPresent(String.self, forKey: .catchupSource)
        self.isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
    }
}

public struct IPTVPlaylist: Identifiable, Codable, Equatable {
    public var id: UUID
    public var serverId: UUID
    public var name: String
    public var sourceURL: URL?
    public var epgURL: URL?
    public var channels: [IPTVChannel]
    public var groups: [String]
    public var groupCounts: [String: Int]
    public var lastUpdated: Date?
    
    // In-memory fast index tables (not encoded to JSON)
    public var channelsByGroup: [String: [IPTVChannel]] = [:]
    public var favoriteChannels: [IPTVChannel] = []
    
    public init(
        id: UUID = UUID(),
        serverId: UUID,
        name: String,
        sourceURL: URL? = nil,
        epgURL: URL? = nil,
        channels: [IPTVChannel] = [],
        groups: [String] = [],
        groupCounts: [String: Int] = [:],
        lastUpdated: Date? = nil
    ) {
        self.id = id
        self.serverId = serverId
        self.name = name
        self.sourceURL = sourceURL
        self.epgURL = epgURL
        self.channels = channels
        self.groups = groups
        self.lastUpdated = lastUpdated
        
        var counts: [String: Int] = [:]
        var byGroup: [String: [IPTVChannel]] = [:]
        var favorites: [IPTVChannel] = []
        for channel in channels {
            if channel.isFavorite {
                favorites.append(channel)
            }
            for g in channel.groups {
                counts[g, default: 0] += 1
                byGroup[g, default: []].append(channel)
            }
        }
        self.groupCounts = groupCounts.isEmpty ? counts : groupCounts
        self.channelsByGroup = byGroup
        self.favoriteChannels = favorites
    }
    
    private enum CodingKeys: String, CodingKey {
        case id, serverId, name, sourceURL, epgURL, channels, groups, groupCounts, lastUpdated
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.serverId = try container.decode(UUID.self, forKey: .serverId)
        self.name = try container.decode(String.self, forKey: .name)
        self.sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        self.epgURL = try container.decodeIfPresent(URL.self, forKey: .epgURL)
        let decodedChannels = try container.decodeIfPresent([IPTVChannel].self, forKey: .channels) ?? []
        self.channels = decodedChannels
        self.groups = try container.decodeIfPresent([String].self, forKey: .groups) ?? []
        self.lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated)
        
        var counts: [String: Int] = [:]
        var byGroup: [String: [IPTVChannel]] = [:]
        var favorites: [IPTVChannel] = []
        for channel in decodedChannels {
            if channel.isFavorite {
                favorites.append(channel)
            }
            for g in channel.groups {
                counts[g, default: 0] += 1
                byGroup[g, default: []].append(channel)
            }
        }
        
        if let decodedCounts = try container.decodeIfPresent([String: Int].self, forKey: .groupCounts), !decodedCounts.isEmpty {
            self.groupCounts = decodedCounts
        } else {
            self.groupCounts = counts
        }
        self.channelsByGroup = byGroup
        self.favoriteChannels = favorites
    }
}

public struct IPTVPlaylistSummary: Codable, Equatable, Hashable {
    public let serverId: UUID
    public let channelCount: Int
    public let groupCount: Int
    public let lastUpdated: Date
    
    public init(serverId: UUID, channelCount: Int, groupCount: Int, lastUpdated: Date) {
        self.serverId = serverId
        self.channelCount = channelCount
        self.groupCount = groupCount
        self.lastUpdated = lastUpdated
    }
}

// MARK: - IPTV Sorting

public enum IPTVSortField: String, CaseIterable, Identifiable, Codable {
    case `default` = "Default"
    case name = "Name"
    case group = "Group"
    case favoritesFirst = "FavoritesFirst"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .default:
            return NSLocalizedString("Default", comment: "")
        case .name:
            return NSLocalizedString("Name", comment: "")
        case .group:
            return NSLocalizedString("Group", comment: "")
        case .favoritesFirst:
            return NSLocalizedString("Favorites First", comment: "")
        }
    }
}

public enum IPTVSortOrder: String, CaseIterable, Identifiable, Codable {
    case ascending = "Ascending"
    case descending = "Descending"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ascending:
            return NSLocalizedString("Ascending", comment: "")
        case .descending:
            return NSLocalizedString("Descending", comment: "")
        }
    }
}

public extension Array where Element == IPTVChannel {
    func sorted(by field: IPTVSortField, order: IPTVSortOrder) -> [IPTVChannel] {
        let isAscending = order == .ascending
        switch field {
        case .default:
            return isAscending ? self : self.reversed()
        case .name:
            return sorted { ch1, ch2 in
                let comp = ch1.name.localizedStandardCompare(ch2.name)
                if comp == .orderedSame {
                    return ch1.id < ch2.id
                }
                return isAscending ? (comp == .orderedAscending) : (comp == .orderedDescending)
            }
        case .group:
            return sorted { ch1, ch2 in
                let comp = ch1.group.localizedStandardCompare(ch2.group)
                if comp == .orderedSame {
                    let nameComp = ch1.name.localizedStandardCompare(ch2.name)
                    return nameComp == .orderedAscending
                }
                return isAscending ? (comp == .orderedAscending) : (comp == .orderedDescending)
            }
        case .favoritesFirst:
            return sorted { ch1, ch2 in
                if ch1.isFavorite != ch2.isFavorite {
                    return isAscending ? (ch1.isFavorite && !ch2.isFavorite) : (!ch1.isFavorite && ch2.isFavorite)
                }
                return ch1.name.localizedStandardCompare(ch2.name) == .orderedAscending
            }
        }
    }
}


