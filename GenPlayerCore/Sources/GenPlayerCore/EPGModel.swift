import Foundation

public struct EPGProgramme: Identifiable, Codable, Equatable, Hashable {
    public var id: String
    public var channelId: String
    public var title: String
    public var desc: String?
    public var start: Date
    public var stop: Date
    
    public init(
        id: String = UUID().uuidString,
        channelId: String,
        title: String,
        desc: String? = nil,
        start: Date,
        stop: Date
    ) {
        self.id = id
        self.channelId = channelId
        self.title = title
        self.desc = desc
        self.start = start
        self.stop = stop
    }
    
    public func isLive(at date: Date = Date()) -> Bool {
        return date >= start && date < stop
    }
    
    public func isUpcoming(at date: Date = Date()) -> Bool {
        return date < start
    }
    
    public func isPast(at date: Date = Date()) -> Bool {
        return date >= stop
    }
    
    public func progress(at date: Date = Date()) -> Double {
        guard stop > start else { return 0 }
        let total = stop.timeIntervalSince(start)
        let elapsed = date.timeIntervalSince(start)
        let ratio = elapsed / total
        return min(max(ratio, 0.0), 1.0)
    }
    
    public var formattedStartTime: String {
        EPGDateFormatter.timeFormatter.string(from: start)
    }
    
    public var formattedEndTime: String {
        EPGDateFormatter.timeFormatter.string(from: stop)
    }
    
    public var formattedTimeSpan: String {
        "\(formattedStartTime) - \(formattedEndTime)"
    }
    
    public var formattedDateText: String {
        EPGDateFormatter.dateFormatter.string(from: start)
    }
}

public struct EPGChannelInfo: Identifiable, Codable, Equatable {
    public var id: String
    public var displayName: String?
    public var iconURL: URL?
    
    public init(id: String, displayName: String? = nil, iconURL: URL? = nil) {
        self.id = id
        self.displayName = displayName
        self.iconURL = iconURL
    }
}

public struct EPGTable: Codable, Equatable {
    public var serverId: UUID
    public var epgURL: URL?
    public var lastUpdated: Date
    public var channelsById: [String: EPGChannelInfo]
    public var programmesByChannel: [String: [EPGProgramme]]
    
    // In-memory fast normalized index
    private var normalizedIndex: [String: String]? = nil
    
    public init(
        serverId: UUID,
        epgURL: URL? = nil,
        lastUpdated: Date = Date(),
        channelsById: [String: EPGChannelInfo] = [:],
        programmesByChannel: [String: [EPGProgramme]] = [:]
    ) {
        self.serverId = serverId
        self.epgURL = epgURL
        self.lastUpdated = lastUpdated
        self.channelsById = channelsById
        self.programmesByChannel = programmesByChannel
        buildNormalizedIndex()
    }
    
    private enum CodingKeys: String, CodingKey {
        case serverId, epgURL, lastUpdated, channelsById, programmesByChannel
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.serverId = try container.decode(UUID.self, forKey: .serverId)
        self.epgURL = try container.decodeIfPresent(URL.self, forKey: .epgURL)
        self.lastUpdated = try container.decodeIfPresent(Date.self, forKey: .lastUpdated) ?? Date()
        self.channelsById = try container.decodeIfPresent([String: EPGChannelInfo].self, forKey: .channelsById) ?? [:]
        self.programmesByChannel = try container.decodeIfPresent([String: [EPGProgramme]].self, forKey: .programmesByChannel) ?? [:]
        buildNormalizedIndex()
    }
    
    private mutating func buildNormalizedIndex() {
        var index: [String: String] = [:]
        for key in programmesByChannel.keys {
            let normKey = EPGTable.normalizeIdentifier(key)
            if !normKey.isEmpty {
                index[normKey] = key
            }
        }
        for (id, ch) in channelsById {
            if let name = ch.displayName {
                let normName = EPGTable.normalizeIdentifier(name)
                if !normName.isEmpty && index[normName] == nil {
                    index[normName] = id
                }
            }
        }
        self.normalizedIndex = index
    }
    
    public func resolveChannelKey(for channel: IPTVChannel) -> String? {
        // 1. Direct tvgId match
        if let tvgId = channel.tvgId?.trimmingCharacters(in: .whitespacesAndNewlines), !tvgId.isEmpty {
            if programmesByChannel[tvgId] != nil {
                return tvgId
            }
            let normTvgId = EPGTable.normalizeIdentifier(tvgId)
            if let matched = normalizedIndex?[normTvgId] ?? programmesByChannel.keys.first(where: { EPGTable.normalizeIdentifier($0) == normTvgId }) {
                return matched
            }
        }
        
        // 2. Direct tvgName match
        if let tvgName = channel.tvgName?.trimmingCharacters(in: .whitespacesAndNewlines), !tvgName.isEmpty {
            if programmesByChannel[tvgName] != nil {
                return tvgName
            }
            let normTvgName = EPGTable.normalizeIdentifier(tvgName)
            if let matched = normalizedIndex?[normTvgName] ?? programmesByChannel.keys.first(where: { EPGTable.normalizeIdentifier($0) == normTvgName }) {
                return matched
            }
        }
        
        // 3. Direct Channel Name match
        let channelName = channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !channelName.isEmpty {
            if programmesByChannel[channelName] != nil {
                return channelName
            }
            let normName = EPGTable.normalizeIdentifier(channelName)
            if let matched = normalizedIndex?[normName] ?? programmesByChannel.keys.first(where: { EPGTable.normalizeIdentifier($0) == normName }) {
                return matched
            }
        }
        
        return nil
    }
    
    public func channelInfo(for channel: IPTVChannel) -> EPGChannelInfo? {
        guard let key = resolveChannelKey(for: channel) else { return nil }
        return channelsById[key]
    }
    
    public func iconURL(for channel: IPTVChannel) -> URL? {
        channelInfo(for: channel)?.iconURL
    }
    
    public func currentProgramme(for channel: IPTVChannel, at date: Date = Date()) -> EPGProgramme? {
        guard let key = resolveChannelKey(for: channel),
              let list = programmesByChannel[key] else {
            return nil
        }
        return list.first { $0.isLive(at: date) }
    }
    
    public func nextProgramme(for channel: IPTVChannel, at date: Date = Date()) -> EPGProgramme? {
        guard let key = resolveChannelKey(for: channel),
              let list = programmesByChannel[key] else {
            return nil
        }
        return list.first { $0.start >= date }
    }
    
    public func allProgrammes(for channel: IPTVChannel) -> [EPGProgramme] {
        guard let key = resolveChannelKey(for: channel),
              let list = programmesByChannel[key] else {
            return []
        }
        return list
    }
    
    public func programmes(for channel: IPTVChannel, on date: Date = Date()) -> [EPGProgramme] {
        let calendar = Calendar.current
        let targetDay = calendar.startOfDay(for: date)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: targetDay) else {
            return allProgrammes(for: channel)
        }
        
        return allProgrammes(for: channel).filter { prog in
            // Programme falls within or overlaps target day
            prog.stop > targetDay && prog.start < nextDay
        }
    }
    
    public static func normalizeIdentifier(_ raw: String) -> String {
        var clean = raw.lowercased()
        
        // Remove bracket tags (e.g. [4K], [HEVC], [IPv6])
        if let bracketRegex = try? NSRegularExpression(pattern: "\\[.*?\\]", options: .caseInsensitive) {
            clean = bracketRegex.stringByReplacingMatches(in: clean, options: [], range: NSRange(location: 0, length: clean.utf16.count), withTemplate: "")
        }
        
        // Remove common resolution / codec / tag patterns
        let removePatterns = [
            "4k", "8k", "fhd", "uhd", "hd", "sd", "1080p", "720p", "hevc", "h264", "h265", "60fps", "50fps",
            "cctv-", "cctv "
        ]
        for pat in removePatterns {
            if let regex = try? NSRegularExpression(pattern: pat, options: .caseInsensitive) {
                clean = regex.stringByReplacingMatches(in: clean, options: [], range: NSRange(location: 0, length: clean.utf16.count), withTemplate: pat.hasPrefix("cctv") ? "cctv" : "")
            }
        }
        
        // Strip punctuation and whitespace (including parens, dots, dashes)
        clean = clean.components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
        return clean
    }
}

public enum EPGDateFormatter {
    public static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.locale = Locale.autoupdatingCurrent
        return formatter
    }()
    
    public static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.locale = Locale.autoupdatingCurrent
        return formatter
    }()
    
    public static let dayOfWeekFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        formatter.locale = Locale.autoupdatingCurrent
        return formatter
    }()
}
