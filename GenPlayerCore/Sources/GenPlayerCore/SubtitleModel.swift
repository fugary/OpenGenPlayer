import Foundation


// MARK: - Subtitle Data Sources

protocol SubtitleDataSouce {
    func searchSubtitles(completion: @escaping ([SubtitleInfo]) -> Void)
}
public struct URLSubtitleDataSouce: SubtitleDataSouce {
    public let urls: [URL]
    
    public init(urls: [URL]) {
        self.urls = urls
    }
    
    func searchSubtitles(completion: @escaping ([SubtitleInfo]) -> Void) {
        let infos = urls.map { url -> SubtitleInfo in
            let name = url.lastPathComponent
            return SubtitleInfo(url: url, name: name, format: url.pathExtension.lowercased())
        }
        completion(infos)
    }
}
public struct DirectorySubtitleDataSouce: SubtitleDataSouce {
    func searchSubtitles(completion: @escaping ([SubtitleInfo]) -> Void) {
        // This would normally scan the directory, but for now we might leave it empty
        // or implement if needed. The main use case is sidecar loading which we handle explicitly.
        completion([])
    }
}

// MARK: - Subtitle Info
public struct SubtitleInfo: Equatable {
    public let url: URL
    public let name: String
    public let format: String
    
    public init(url: URL, name: String, format: String) {
        self.url = url
        self.name = name
        self.format = format
    }
    
    public static func == (lhs: SubtitleInfo, rhs: SubtitleInfo) -> Bool {
        return lhs.url == rhs.url
    }
}

// MARK: - Subtitle Model
public class SubtitleModel: ObservableObject {
    @Published var subtitleInfos: [SubtitleInfo] = []
    @Published var selectedSubtitleInfo: SubtitleInfo? {
        didSet {
            if let info = selectedSubtitleInfo {
                loadSubtitle(info)
            } else {
                parts = []
            }
        }
    }
    
    @Published var parts: [SubtitlePart] = []
    
    private var dataSources: [SubtitleDataSouce] = []
    
    // Cached content to avoid re-reading
    private var loadedContent: String?

    public static func loadParts(from url: URL, format: String? = nil) throws -> [SubtitlePart] {
        let model = SubtitleModel()
        let content = try model.loadContent(url: url)
        return model.parseParts(content: content, format: format ?? url.pathExtension.lowercased())
    }

    public static func parseParts(from content: String, format: String) -> [SubtitlePart] {
        SubtitleModel().parseParts(content: content, format: format)
    }
    
    func addSubtitle(dataSouce: SubtitleDataSouce) {
        dataSources.append(dataSouce)
        dataSouce.searchSubtitles { [weak self] infos in
            guard let self = self else { return }
            DispatchQueue.main.async {
                // Avoid duplicates
                for info in infos {
                    if !self.subtitleInfos.contains(info) {
                        self.subtitleInfos.append(info)
                    }
                }
            }
        }
    }
    
    func clear() {
        dataSources = []
        subtitleInfos = []
        selectedSubtitleInfo = nil
        parts = []
    }
    
    func subtitle(currentTime: TimeInterval) -> Bool {
        // Optimization: In a real implementation we might optimize search,
        // but for now the View layer does the filtering based on 'parts'.
        // This function returns true if parts were updated, or simply provides access.
        // Since 'parts' is @Published, SwiftUI views will react.
        return true
    }
    
    private func loadSubtitle(_ info: SubtitleInfo) {
        do {
            let content = try loadContent(url: info.url)
            self.loadedContent = content
            parse(content: content, format: info.format)
            print("[GenPlayer] SubtitleModel loaded: \(info.name)")
        } catch {
            print("[GenPlayer] Failed to load subtitle: \(error)")
            self.parts = []
        }
    }
    
    private func loadContent(url: URL) throws -> String {
        // Try UTF-8 first
        if let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        
        // Fallback encodings for CJK
        let encodings: [String.Encoding] = [
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .windowsCP1252
        ]
        
        for encoding in encodings {
            if let content = try? String(contentsOf: url, encoding: encoding) {
                return content
            }
        }
        
        throw NSError(domain: "SubtitleModel", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unknown encoding"])
    }
    
    private func parse(content: String, format: String) {
        let newParts = parseParts(content: content, format: format)

        DispatchQueue.main.async {
            self.parts = newParts
        }
    }

    private func parseParts(content: String, format: String) -> [SubtitlePart] {
        let normalizedContent = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        switch format.lowercased() {
        case "srt":
            return parseSRT(normalizedContent)
        case "vtt":
            return parseVTT(normalizedContent)
        case "ass", "ssa":
            return parseASS(normalizedContent)
        default:
            return parseSRT(normalizedContent) // Try SRT as fallback
        }
    }
    
    // MARK: - Subtitle Text Sanitization

    private static let assTagRegex = try? NSRegularExpression(pattern: "\\{[^}]*\\}", options: [])
    private static let htmlTagRegex = try? NSRegularExpression(pattern: "<[^>]+>", options: [])
    private static let decimalEntityRegex = try? NSRegularExpression(pattern: "&#([0-9]+);", options: [])
    private static let hexEntityRegex = try? NSRegularExpression(pattern: "&#x([0-9a-fA-F]+);", options: [.caseInsensitive])
    private static let assColorRegex = try? NSRegularExpression(pattern: "\\\\[1-4]?c&H([0-9A-Fa-f]{6})&?", options: [])
    private static let assDrawingRegex = try? NSRegularExpression(pattern: "^[mlnbspc0-9\\s\\-\\.]+$", options: [])

    public static func cleanSubtitleText(_ text: String) -> String {
        var cleaned = text

        // 1. Remove ASS override tags like {\an8}, {\pos(10,20)}, {\c&HFFFFFF&}, {\fad(100,100)} etc.
        if cleaned.contains("{"), let assRegex = assTagRegex {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = assRegex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        // 2. Normalize ASS escape sequences
        if cleaned.contains("\\") {
            cleaned = cleaned
                .replacingOccurrences(of: "\\N", with: "\n")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: " ")
        }

        // 3. Remove HTML / XML tags like <b>, </i>, <font color="...">, <v Speaker>, <c.yellow>, <00:19.000>
        if cleaned.contains("<"), let htmlRegex = htmlTagRegex {
            let range = NSRange(cleaned.startIndex..., in: cleaned)
            cleaned = htmlRegex.stringByReplacingMatches(in: cleaned, options: [], range: range, withTemplate: "")
        }

        // 4. Decode HTML entities
        if cleaned.contains("&") {
            cleaned = decodeHTMLEntities(cleaned)
        }

        // 5. Clean up whitespace per line while preserving multi-line dialogue
        let lines = cleaned
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return lines.joined(separator: "\n")
    }

    private static func decodeHTMLEntities(_ string: String) -> String {
        var result = string
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")

        // Decimal entities: &#123;
        if let decRegex = decimalEntityRegex {
            let matches = decRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                if let numRange = Range(match.range(at: 1), in: result),
                   let fullRange = Range(match.range, in: result),
                   let codePoint = UInt32(result[numRange]),
                   let scalar = UnicodeScalar(codePoint) {
                    result.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }
        }

        // Hex entities: &#x1f600;
        if let hexRegex = hexEntityRegex {
            let matches = hexRegex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                if let numRange = Range(match.range(at: 1), in: result),
                   let fullRange = Range(match.range, in: result),
                   let codePoint = UInt32(result[numRange], radix: 16),
                   let scalar = UnicodeScalar(codePoint) {
                    result.replaceSubrange(fullRange, with: String(Character(scalar)))
                }
            }
        }

        return result
    }

    // MARK: - Parsing Logic (Moved from VLCPlaybackService)
    
    private func parseSRT(_ content: String) -> [SubtitlePart] {
        var result: [SubtitlePart] = []
        let blocks = content.components(separatedBy: "\n\n")
        
        for block in blocks {
            let rawLines = block.components(separatedBy: "\n")
            let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            
            guard let timeLineIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timeLine = lines[timeLineIndex]
            guard let (start, end) = parseTimestamp(timeLine) else { continue }
            
            let textLines = lines[(timeLineIndex + 1)...]
            guard !textLines.isEmpty else { continue }
            
            let rawText = textLines.joined(separator: "\n")
            let cleanText = Self.cleanSubtitleText(rawText)
            guard !cleanText.isEmpty else { continue }
            
            let attrString = NSAttributedString(string: cleanText)
            result.append(SubtitlePart(start: start, end: end, text: attrString))
        }
        return result
    }
    
    private func parseVTT(_ content: String) -> [SubtitlePart] {
        var result: [SubtitlePart] = []
        let lines = content.components(separatedBy: "\n")
        var i = 0
        
        // Skip header
        while i < lines.count && !lines[i].contains("-->") {
            i += 1
        }
        
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.contains("-->") {
                if let (start, end) = parseTimestamp(line) {
                    i += 1
                    var textLines: [String] = []
                    while i < lines.count {
                        let textLine = lines[i].trimmingCharacters(in: .whitespaces)
                        if textLine.isEmpty || textLine.contains("-->") {
                            break
                        }
                        textLines.append(lines[i])
                        i += 1
                    }
                    
                    let rawText = textLines.joined(separator: "\n")
                    let cleanText = Self.cleanSubtitleText(rawText)
                    if !cleanText.isEmpty {
                        let attrString = NSAttributedString(string: cleanText)
                        result.append(SubtitlePart(start: start, end: end, text: attrString))
                    }
                    continue
                }
            }
            i += 1
        }
        return result
    }
    
    private func parseASS(_ content: String) -> [SubtitlePart] {
        var result: [SubtitlePart] = []
        let lines = content.components(separatedBy: "\n")
        
        for line in lines {
            guard line.hasPrefix("Dialogue:") else { continue }
            
            let parts = line.dropFirst(10).components(separatedBy: ",")
            guard parts.count >= 10 else { continue }
            
            guard let start = parseASSTime(parts[1]),
                  let end = parseASSTime(parts[2]) else { continue }
            
            let text = parts[9...].joined(separator: ",")
            let color = extractASSColor(text)
            let cleanText = Self.cleanSubtitleText(text)
            
            let trimmed = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("m ") || trimmed.isEmpty {
                continue
            }
            
            // Skip drawing commands
            if trimmed.count > 10,
               let drawingRegex = Self.assDrawingRegex,
               let match = drawingRegex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
               match.range.length == trimmed.utf16.count {
                continue
            }
            
            let attrString = NSMutableAttributedString(string: cleanText)
            
            // Apply extract color if found
            if let color = color {
                attrString.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: attrString.length))
            }
            
            result.append(SubtitlePart(start: start, end: end, text: attrString))
        }
        return result
    }
    
    // Parse ASS color: &HBBGGRR& (BGR format) or &HBBGGRR (no trailing &)
    // Common tags: {\c&HFFFFFF&} {\1c&HFFFFFF&}
    private func extractASSColor(_ text: String) -> AppColor? {
        guard text.contains("c&H"), let regex = Self.assColorRegex else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range),
           let hexRange = Range(match.range(at: 1), in: text) {
            let hexString = String(text[hexRange])
            return colorFromASSHeader(hexString)
        }
        return nil
    }
    
    // Convert ASS BGR hex string to UIColor
    private func colorFromASSHeader(_ hex: String) -> AppColor? {
        var rgbValue: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&rgbValue)
        
        // ASS is BGR, not RGB
        let blue = CGFloat((rgbValue & 0xFF0000) >> 16) / 255.0
        let green = CGFloat((rgbValue & 0x00FF00) >> 8) / 255.0
        let red = CGFloat(rgbValue & 0x0000FF) / 255.0
        
        return AppColor(red: red, green: green, blue: blue, alpha: 1.0)
    }
    
    private func parseTimestamp(_ line: String) -> (start: TimeInterval, end: TimeInterval)? {
        let parts = line.components(separatedBy: " --> ")
        guard parts.count >= 2 else { return nil }
        
        guard let start = timeToSeconds(parts[0].trimmingCharacters(in: .whitespaces)),
              let end = timeToSeconds(parts[1].components(separatedBy: " ").first ?? parts[1]) else {
            return nil
        }
        return (start, end)
    }
    
    private func timeToSeconds(_ timeStr: String) -> TimeInterval? {
        let normalized = timeStr.replacingOccurrences(of: ",", with: ".")
        let parts = normalized.components(separatedBy: ":")
        
        if parts.count == 3 {
            guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
            return h * 3600 + m * 60 + s
        } else if parts.count == 2 {
            guard let m = Double(parts[0]), let s = Double(parts[1]) else { return nil }
            return m * 60 + s
        }
        return nil
    }
    
    private func parseASSTime(_ str: String) -> TimeInterval? {
        let parts = str.trimmingCharacters(in: .whitespaces).components(separatedBy: ":")
        guard parts.count == 3 else { return nil }
        guard let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }
}

public struct SubtitlePart: Equatable, Identifiable {
    public let id = UUID()
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: NSAttributedString?
    public var image: AppImage?
    
    public init(start: TimeInterval, end: TimeInterval, text: NSAttributedString?) {
        self.start = start
        self.end = end
        self.text = text
        self.image = nil
    }
    
    public static func == (lhs: SubtitlePart, rhs: SubtitlePart) -> Bool {
        return lhs.start == rhs.start && lhs.end == rhs.end && lhs.text?.string == rhs.text?.string
    }
}

public struct SubtitleTimeline: Equatable {
    public let parts: [SubtitlePart]

    public init(parts: [SubtitlePart]) {
        self.parts = parts.sorted {
            if $0.start == $1.start {
                return $0.end < $1.end
            }
            return $0.start < $1.start
        }
    }

    public func activeParts(at time: TimeInterval) -> [SubtitlePart] {
        parts.filter { $0.start <= time && time < $0.end }
    }
}
