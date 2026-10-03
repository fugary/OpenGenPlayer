import Foundation

public struct M3UParseResult {
    public var channels: [IPTVChannel]
    public var groups: [String]
    public var epgURL: URL?
    
    public init(channels: [IPTVChannel], groups: [String], epgURL: URL? = nil) {
        self.channels = channels
        self.groups = groups
        self.epgURL = epgURL
    }
}

public enum M3UParser {
    
    /// Parses an M3U or M3U8 string content into an `M3UParseResult`.
    public static func parse(content: String, defaultGroupName: String = "Other") -> M3UParseResult {
        var channels: [IPTVChannel] = []
        var groupsSet = Set<String>()
        var globalEPGURL: URL? = nil
        
        let lines = content.components(separatedBy: .newlines)
        
        var currentTvgId: String? = nil
        var currentTvgName: String? = nil
        var currentLogoURL: URL? = nil
        var currentGroup: String? = nil
        var currentTitle: String? = nil
        var currentCatchup: String? = nil
        var currentCatchupSource: String? = nil
        var currentUserAgent: String? = nil
        var currentReferrer: String? = nil
        
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            
            if line.hasPrefix("#EXTM3U") {
                // Parse global attributes like x-tvg-url or url-tvg
                if globalEPGURL == nil {
                    if let epgString = extractAttribute(named: "x-tvg-url", from: line) ?? extractAttribute(named: "url-tvg", from: line) {
                        let candidate = epgString.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? epgString
                        globalEPGURL = URL(string: candidate)
                    }
                }
                continue
            }
            
            if line.hasPrefix("#EXTINF:") {
                // Reset per-channel temp attributes
                currentTvgId = extractAttribute(named: "tvg-id", from: line)
                currentTvgName = extractAttribute(named: "tvg-name", from: line)
                if let logoStr = extractAttribute(named: "tvg-logo", from: line), let logoURL = URL(string: logoStr) {
                    currentLogoURL = logoURL
                } else {
                    currentLogoURL = nil
                }
                currentGroup = extractAttribute(named: "group-title", from: line)
                currentCatchup = extractAttribute(named: "catchup", from: line)
                currentCatchupSource = extractAttribute(named: "catchup-source", from: line)
                currentUserAgent = extractAttribute(named: "user-agent", from: line)
                currentReferrer = extractAttribute(named: "http-referrer", from: line)
                
                // Extract channel name after the last comma
                if let commaIndex = line.range(of: ",", options: .backwards) {
                    let titlePart = String(line[commaIndex.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !titlePart.isEmpty {
                        currentTitle = titlePart
                    } else {
                        currentTitle = currentTvgName ?? "Channel"
                    }
                } else {
                    currentTitle = currentTvgName ?? "Channel"
                }
                continue
            }
            
            if line.hasPrefix("#EXTVLCOPT:") {
                let opt = String(line.dropFirst("#EXTVLCOPT:".count)).trimmingCharacters(in: .whitespaces)
                if opt.lowercased().hasPrefix("http-user-agent=") {
                    currentUserAgent = String(opt.dropFirst("http-user-agent=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                } else if opt.lowercased().hasPrefix("http-referrer=") {
                    currentReferrer = String(opt.dropFirst("http-referrer=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                }
                continue
            }
            
            if line.hasPrefix("#EXTGRP:") {
                let grp = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !grp.isEmpty {
                    currentGroup = grp
                }
                continue
            }
            
            if line.hasPrefix("#") {
                // Other comment/directive lines, skip
                continue
            }
            
            // This is a stream URL line
            if let streamURL = URL(string: line) {
                let channelName = currentTitle ?? currentTvgName ?? streamURL.lastPathComponent
                let rawGroup = (currentGroup?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) ? currentGroup! : defaultGroupName
                
                // Split multi-group strings (e.g. "Animation;Classic;Entertainment") into distinct clean group tags
                let parsedGroups = rawGroup.components(separatedBy: CharacterSet(charactersIn: ";,")).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                let primaryGroup = parsedGroups.first ?? defaultGroupName
                let groupList = parsedGroups.isEmpty ? [defaultGroupName] : parsedGroups
                
                // Generate a stable ID for the channel
                let stableID = "\(primaryGroup)|\(channelName)|\(streamURL.absoluteString)"
                
                let channel = IPTVChannel(
                    id: stableID,
                    name: channelName,
                    group: primaryGroup,
                    groups: groupList,
                    logoURL: currentLogoURL,
                    tvgId: currentTvgId,
                    tvgName: currentTvgName,
                    url: streamURL,
                    backupURLs: [],
                    httpUserAgent: currentUserAgent,
                    httpReferrer: currentReferrer,
                    catchup: currentCatchup,
                    catchupSource: currentCatchupSource,
                    isFavorite: false
                )
                
                channels.append(channel)
                for g in groupList {
                    groupsSet.insert(g)
                }
            }
            
            // Reset temporary channel properties
            currentTvgId = nil
            currentTvgName = nil
            currentLogoURL = nil
            currentGroup = nil
            currentTitle = nil
            currentCatchup = nil
            currentCatchupSource = nil
            currentUserAgent = nil
            currentReferrer = nil
        }
        
        // Order groups with common groups first if present, then alphabetical
        let sortedGroups = sortGroups(Array(groupsSet))
        return M3UParseResult(channels: channels, groups: sortedGroups, epgURL: globalEPGURL)
    }
    
    private static func extractAttribute(named name: String, from line: String) -> String? {
        let pattern = "\(name)=\"([^\"]*)\"|\(name)=([^\\s,]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }
        let nsLine = line as NSString
        let matches = regex.matches(in: line, options: [], range: NSRange(location: 0, length: nsLine.length))
        guard let match = matches.first else { return nil }
        
        if match.numberOfRanges > 1 && match.range(at: 1).location != NSNotFound {
            return nsLine.substring(with: match.range(at: 1))
        } else if match.numberOfRanges > 2 && match.range(at: 2).location != NSNotFound {
            return nsLine.substring(with: match.range(at: 2))
        }
        return nil
    }
    
    private static func sortGroups(_ groups: [String]) -> [String] {
        return groups.sorted { g1, g2 in
            g1.localizedStandardCompare(g2) == .orderedAscending
        }
    }
}
