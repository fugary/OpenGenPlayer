import Foundation

public final class XMLTVParser: NSObject, XMLParserDelegate {
    
    private var channelsById: [String: EPGChannelInfo] = [:]
    private var programmesByChannel: [String: [EPGProgramme]] = [:]
    
    // Parser temp state
    private var currentElement: String = ""
    private var currentText: String = ""
    
    // Channel parsing
    private var currentChannelId: String?
    private var currentChannelDisplayName: String?
    private var currentChannelIconURL: URL?
    
    // Programme parsing
    private var currentProgChannel: String?
    private var currentProgStart: Date?
    private var currentProgStop: Date?
    private var currentProgTitle: String?
    private var currentProgDesc: String?
    
    // Prune cutoff: discard programs older than 24h
    private let cutoffDate: Date?
    private let futureCutoffDate: Date?
    
    public init(
        pruneOlderThan: Date? = Date().addingTimeInterval(-24 * 3600),
        pruneNewerThan: Date? = Date().addingTimeInterval(7 * 24 * 3600)
    ) {
        self.cutoffDate = pruneOlderThan
        self.futureCutoffDate = pruneNewerThan
    }
    
    public static func parse(
        data: Data,
        pruneOlderThan: Date? = Date().addingTimeInterval(-24 * 3600),
        pruneNewerThan: Date? = Date().addingTimeInterval(7 * 24 * 3600)
    ) -> (channels: [String: EPGChannelInfo], programmes: [String: [EPGProgramme]]) {
        let parser = XMLTVParser(pruneOlderThan: pruneOlderThan, pruneNewerThan: pruneNewerThan)
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        xmlParser.shouldProcessNamespaces = false
        xmlParser.shouldReportNamespacePrefixes = false
        xmlParser.shouldResolveExternalEntities = false
        
        let success = xmlParser.parse()
        if !success, let error = xmlParser.parserError {
            NSLog("[XMLTVParser] Parse error: %@", error.localizedDescription)
        }
        
        // Sort programmes for each channel by start time
        var sortedProgrammes: [String: [EPGProgramme]] = [:]
        for (channelId, progs) in parser.programmesByChannel {
            sortedProgrammes[channelId] = progs.sorted { $0.start < $1.start }
        }
        
        return (parser.channelsById, sortedProgrammes)
    }
    
    // MARK: - XMLParserDelegate
    
    public func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName.lowercased()
        currentText = ""
        
        if currentElement == "channel" {
            currentChannelId = attributeDict["id"]
            currentChannelDisplayName = nil
            currentChannelIconURL = nil
        } else if currentElement == "icon" {
            if let src = attributeDict["src"], let url = URL(string: src) {
                if currentChannelId != nil {
                    currentChannelIconURL = url
                }
            }
        } else if currentElement == "programme" {
            currentProgChannel = attributeDict["channel"]
            if let startStr = attributeDict["start"] {
                currentProgStart = XMLTVDateParser.parse(startStr)
            }
            if let stopStr = attributeDict["stop"] {
                currentProgStop = XMLTVDateParser.parse(stopStr)
            }
            currentProgTitle = nil
            currentProgDesc = nil
        }
    }
    
    public func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }
    
    public func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let tag = elementName.lowercased()
        let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if tag == "display-name" {
            if !trimmed.isEmpty && currentChannelDisplayName == nil {
                currentChannelDisplayName = trimmed
            }
        } else if tag == "title" {
            if !trimmed.isEmpty && currentProgTitle == nil {
                currentProgTitle = trimmed
            }
        } else if tag == "desc" {
            if !trimmed.isEmpty && currentProgDesc == nil {
                currentProgDesc = trimmed
            }
        } else if tag == "channel" {
            if let channelId = currentChannelId {
                let info = EPGChannelInfo(
                    id: channelId,
                    displayName: currentChannelDisplayName,
                    iconURL: currentChannelIconURL
                )
                channelsById[channelId] = info
            }
            currentChannelId = nil
            currentChannelDisplayName = nil
            currentChannelIconURL = nil
        } else if tag == "programme" {
            if let channel = currentProgChannel,
               let start = currentProgStart,
               let stop = currentProgStop,
               let title = currentProgTitle {
                // Filter programmes within practical timeframe
                let isAfterCutoff = cutoffDate.map { stop > $0 } ?? true
                let isBeforeFutureCutoff = futureCutoffDate.map { start < $0 } ?? true
                if isAfterCutoff && isBeforeFutureCutoff {
                    let prog = EPGProgramme(
                        channelId: channel,
                        title: title,
                        desc: currentProgDesc,
                        start: start,
                        stop: stop
                    )
                    if programmesByChannel[channel] == nil {
                        programmesByChannel[channel] = []
                    }
                    programmesByChannel[channel]?.append(prog)
                }
            }
            currentProgChannel = nil
            currentProgStart = nil
            currentProgStop = nil
            currentProgTitle = nil
            currentProgDesc = nil
        }
        
        currentElement = ""
        currentText = ""
    }
}

// MARK: - Ultra-fast XMLTV Timestamp Parser

public enum XMLTVDateParser {
    
    /// Parses XMLTV timestamps:
    /// Format 1: `YYYYMMDDHHMMSS +HHMM` or `YYYYMMDDHHMMSS -HHMM`
    /// Format 2: `YYYYMMDDHHMMSS`
    /// Format 3: ISO8601 fallback
    public static func parse(_ rawString: String) -> Date? {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        let chars = Array(trimmed)
        
        if trimmed.count == 8,
           let year = parse4Digits(chars, offset: 0),
           let month = parse2Digits(chars, offset: 4),
           let day = parse2Digits(chars, offset: 6) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            return calendar.date(from: components)
        }
        
        guard trimmed.count >= 14 else {
            return fallbackISO8601(trimmed)
        }
        
        guard let year = parse4Digits(chars, offset: 0),
              let month = parse2Digits(chars, offset: 4),
              let day = parse2Digits(chars, offset: 6),
              let hour = parse2Digits(chars, offset: 8),
              let minute = parse2Digits(chars, offset: 10),
              let second = parse2Digits(chars, offset: 12) else {
            return fallbackISO8601(trimmed)
        }
        
        var timeZone: TimeZone = TimeZone(secondsFromGMT: 0) ?? .current
        
        // Check for timezone offset e.g. " +0800", "-0500"
        if trimmed.count >= 19 {
            // Find sign '+' or '-'
            var signIndex = -1
            for i in 14..<trimmed.count {
                if chars[i] == "+" || chars[i] == "-" {
                    signIndex = i
                    break
                }
            }
            if signIndex != -1 && signIndex + 4 < trimmed.count {
                let sign: Int = chars[signIndex] == "-" ? -1 : 1
                if let tzHours = parse2Digits(chars, offset: signIndex + 1),
                   let tzMins = parse2Digits(chars, offset: signIndex + 3) {
                    let totalSeconds = sign * (tzHours * 3600 + tzMins * 60)
                    if let tz = TimeZone(secondsFromGMT: totalSeconds) {
                        timeZone = tz
                    }
                }
            }
        }
        
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        
        return calendar.date(from: components)
    }
    
    @inline(__always)
    private static func parse4Digits(_ chars: [Character], offset: Int) -> Int? {
        guard offset + 3 < chars.count,
              let d1 = chars[offset].wholeNumberValue,
              let d2 = chars[offset + 1].wholeNumberValue,
              let d3 = chars[offset + 2].wholeNumberValue,
              let d4 = chars[offset + 3].wholeNumberValue else {
            return nil
        }
        return d1 * 1000 + d2 * 100 + d3 * 10 + d4
    }
    
    @inline(__always)
    private static func parse2Digits(_ chars: [Character], offset: Int) -> Int? {
        guard offset + 1 < chars.count,
              let d1 = chars[offset].wholeNumberValue,
              let d2 = chars[offset + 1].wholeNumberValue else {
            return nil
        }
        return d1 * 10 + d2
    }
    
    private static func fallbackISO8601(_ string: String) -> Date? {
        if #available(iOS 10.0, tvOS 10.0, macOS 10.12, *) {
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: string)
        }
        return nil
    }
}
