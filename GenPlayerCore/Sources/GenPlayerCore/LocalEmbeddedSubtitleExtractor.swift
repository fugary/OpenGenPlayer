import Foundation
import AVFoundation

public struct SharedLocalEmbeddedSubtitleDescriptor: Equatable {
    public let trackIndex: Int
    public let codec: String?
    public let language: String?
    public let title: String?
    public let supportLevel: EmbeddedSubtitleSupportLevel

    public init(
        trackIndex: Int,
        codec: String?,
        language: String?,
        title: String?,
        supportLevel: EmbeddedSubtitleSupportLevel
    ) {
        self.trackIndex = trackIndex
        self.codec = codec
        self.language = language
        self.title = title
        self.supportLevel = supportLevel
    }
}

public enum SharedLocalEmbeddedSubtitleExtractor {
    private struct Cue {
        let start: TimeInterval
        var end: TimeInterval?
        let text: String
    }

    private struct ResolvedCue {
        let start: TimeInterval
        let end: TimeInterval
        let text: String
    }

    private enum MatroskaTextSubtitleExtractor {
        private static let ebmlID: UInt64 = 0x1A45DFA3
        private static let segmentID: UInt64 = 0x18538067
        private static let infoID: UInt64 = 0x1549A966
        private static let timestampScaleID: UInt64 = 0x2AD7B1
        private static let tracksID: UInt64 = 0x1654AE6B
        private static let trackEntryID: UInt64 = 0xAE
        private static let trackNumberID: UInt64 = 0xD7
        private static let trackTypeID: UInt64 = 0x83
        private static let trackNameID: UInt64 = 0x536E
        private static let trackLanguageID: UInt64 = 0x22B59C
        private static let trackLanguageIETFID: UInt64 = 0x22B59D
        private static let codecIDElementID: UInt64 = 0x86
        private static let codecPrivateID: UInt64 = 0x63A2
        private static let clusterID: UInt64 = 0x1F43B675
        private static let clusterTimecodeID: UInt64 = 0xE7
        private static let simpleBlockID: UInt64 = 0xA3
        private static let blockGroupID: UInt64 = 0xA0
        private static let blockID: UInt64 = 0xA1
        private static let blockDurationID: UInt64 = 0x9B
        private static let subtitleTrackType: UInt64 = 0x11
        private static let defaultTimestampScale: UInt64 = 1_000_000
        private static let maxInlineElementSize: UInt64 = 16 * 1024 * 1024
        private static let maxSubtitlePayloadSize: UInt64 = 2 * 1024 * 1024

        private struct EBMLVInt {
            let value: UInt64
            let length: Int
            let isUnknown: Bool
        }

        private struct EBMLElement {
            let id: UInt64
            let dataOffset: UInt64
            let size: UInt64?
            let endOffset: UInt64
        }

        private struct SubtitleTrack {
            var ordinal: Int
            let number: UInt64
            let codecID: String
            let codec: String?
            let language: String?
            let title: String?
            let codecPrivate: Data?
            let supportLevel: EmbeddedSubtitleSupportLevel

            var outputFormat: String {
                switch codec?.lowercased() {
                case "ass":
                    return "ass"
                case "ssa":
                    return "ssa"
                case "webvtt", "vtt":
                    return "vtt"
                default:
                    return "srt"
                }
            }
        }

        private struct Header {
            let segmentStart: UInt64
            let segmentEnd: UInt64
            let timestampScale: UInt64
            let tracks: [SubtitleTrack]
        }

        private struct DataBlockReader {
            let data: Data
            var offset: Int = 0

            var consumed: UInt64 {
                UInt64(offset)
            }

            mutating func readByte() -> UInt8? {
                guard offset < data.count else { return nil }
                let value = data[offset]
                offset += 1
                return value
            }

            mutating func readVIntRemovingMarker(maxLength: Int = 8) -> UInt64? {
                guard let first = readByte(), first != 0 else { return nil }

                var mask: UInt8 = 0x80
                var length = 1
                while length <= maxLength, (first & mask) == 0 {
                    mask >>= 1
                    length += 1
                }
                guard length <= maxLength, mask != 0 else { return nil }

                var value = UInt64(first & ~mask)
                guard data.count - offset >= length - 1 else { return nil }
                for _ in 1..<length {
                    guard let byte = readByte() else { return nil }
                    value = (value << 8) | UInt64(byte)
                }
                return value
            }
        }

        static func descriptors(for mediaURL: URL) -> [SharedLocalEmbeddedSubtitleDescriptor] {
            guard isMatroskaURL(mediaURL) else {
                return []
            }

            let didStartAccessing = mediaURL.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    mediaURL.stopAccessingSecurityScopedResource()
                }
            }

            guard let header = parseHeader(for: mediaURL) else { return [] }
            return header.tracks.map { track in
                SharedLocalEmbeddedSubtitleDescriptor(
                    trackIndex: track.ordinal,
                    codec: track.codec,
                    language: track.language,
                    title: track.title,
                    supportLevel: track.supportLevel
                )
            }
        }

        static func extractSubtitle(
            from mediaURL: URL,
            trackIndex: Int,
            outputURL: URL
        ) throws -> URL {
            guard let header = parseHeader(for: mediaURL) else {
                throw error("Matroska subtitle header was not found.")
            }
            guard let track = header.tracks.first(where: { $0.ordinal == trackIndex }) else {
                throw error("Matroska subtitle track was not found.")
            }
            guard isTextSupported(track.supportLevel) else {
                throw error("Matroska subtitle codec is not supported.")
            }

            let handle = try FileHandle(forReadingFrom: mediaURL)
            defer { handle.closeFile() }

            let cues = extractCues(
                from: handle,
                header: header,
                track: track
            )
            guard !cues.isEmpty else {
                throw error("Matroska subtitle track did not contain readable cues.")
            }

            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )

            let content: String
            switch track.outputFormat {
            case "ass", "ssa":
                content = assContent(from: cues, track: track)
            case "vtt":
                content = vttContent(from: cues)
            default:
                content = srtContent(from: cues)
            }
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
            return outputURL
        }

        private static func parseHeader(for mediaURL: URL) -> Header? {
            guard isMatroskaURL(mediaURL) else { return nil }

            let handle: FileHandle
            do {
                handle = try FileHandle(forReadingFrom: mediaURL)
            } catch {
                return nil
            }
            defer { handle.closeFile() }

            let fileSize = handle.seekToEndOfFile()
            handle.seek(toFileOffset: 0)
            guard let segment = findSegment(in: handle, fileSize: fileSize) else { return nil }

            var timestampScale = defaultTimestampScale
            var tracks: [SubtitleTrack] = []
            var offset = segment.dataOffset
            while offset < segment.endOffset {
                guard let element = readElement(in: handle, at: offset, limit: segment.endOffset) else { break }
                switch element.id {
                case infoID:
                    timestampScale = parseTimestampScale(in: handle, element: element) ?? timestampScale
                case tracksID:
                    tracks = parseTracks(in: handle, element: element)
                case clusterID where !tracks.isEmpty:
                    return Header(
                        segmentStart: segment.dataOffset,
                        segmentEnd: segment.endOffset,
                        timestampScale: timestampScale,
                        tracks: tracks
                    )
                default:
                    break
                }
                offset = nextOffset(after: element, fallback: offset)
            }

            guard !tracks.isEmpty else { return nil }
            return Header(
                segmentStart: segment.dataOffset,
                segmentEnd: segment.endOffset,
                timestampScale: timestampScale,
                tracks: tracks
            )
        }

        private static func findSegment(in handle: FileHandle, fileSize: UInt64) -> EBMLElement? {
            var offset: UInt64 = 0
            while offset < fileSize {
                guard let element = readElement(in: handle, at: offset, limit: fileSize) else { break }
                if element.id == segmentID {
                    return element
                }
                if element.id != ebmlID, element.id != segmentID, offset > 16 * 1024 * 1024 {
                    return nil
                }
                offset = nextOffset(after: element, fallback: offset)
            }
            return nil
        }

        private static func parseTimestampScale(in handle: FileHandle, element: EBMLElement) -> UInt64? {
            var offset = element.dataOffset
            while offset < element.endOffset {
                guard let child = readElement(in: handle, at: offset, limit: element.endOffset) else { break }
                if child.id == timestampScaleID,
                   let size = child.size,
                   let value = readUnsignedInteger(in: handle, offset: child.dataOffset, length: size),
                   value > 0 {
                    return value
                }
                offset = nextOffset(after: child, fallback: offset)
            }
            return nil
        }

        private static func parseTracks(in handle: FileHandle, element: EBMLElement) -> [SubtitleTrack] {
            var tracks: [SubtitleTrack] = []
            var offset = element.dataOffset
            while offset < element.endOffset {
                guard let child = readElement(in: handle, at: offset, limit: element.endOffset) else { break }
                if child.id == trackEntryID,
                   var track = parseTrackEntry(in: handle, element: child) {
                    track.ordinal = tracks.count
                    tracks.append(track)
                }
                offset = nextOffset(after: child, fallback: offset)
            }
            return tracks
        }

        private static func parseTrackEntry(in handle: FileHandle, element: EBMLElement) -> SubtitleTrack? {
            var trackNumber: UInt64?
            var trackType: UInt64?
            var codecID: String?
            var name: String?
            var language: String?
            var languageIETF: String?
            var codecPrivate: Data?

            var offset = element.dataOffset
            while offset < element.endOffset {
                guard let child = readElement(in: handle, at: offset, limit: element.endOffset) else { break }
                switch child.id {
                case trackNumberID:
                    if let size = child.size {
                        trackNumber = readUnsignedInteger(in: handle, offset: child.dataOffset, length: size)
                    }
                case trackTypeID:
                    if let size = child.size {
                        trackType = readUnsignedInteger(in: handle, offset: child.dataOffset, length: size)
                    }
                case codecIDElementID:
                    if let size = child.size {
                        codecID = readString(in: handle, offset: child.dataOffset, length: size)
                    }
                case trackNameID:
                    if let size = child.size {
                        name = readString(in: handle, offset: child.dataOffset, length: size)
                    }
                case trackLanguageID:
                    if let size = child.size {
                        language = readString(in: handle, offset: child.dataOffset, length: size)
                    }
                case trackLanguageIETFID:
                    if let size = child.size {
                        languageIETF = readString(in: handle, offset: child.dataOffset, length: size)
                    }
                case codecPrivateID:
                    if let size = child.size, size <= maxInlineElementSize {
                        codecPrivate = readData(in: handle, offset: child.dataOffset, length: size)
                    }
                default:
                    break
                }
                offset = nextOffset(after: child, fallback: offset)
            }

            guard trackType == subtitleTrackType,
                  let number = trackNumber,
                  let rawCodecID = codecID else {
                return nil
            }

            let codec = codecName(for: rawCodecID)
            return SubtitleTrack(
                ordinal: 0,
                number: number,
                codecID: rawCodecID,
                codec: codec,
                language: cleanedValue(languageIETF) ?? cleanedValue(language),
                title: cleanedValue(name),
                codecPrivate: codecPrivate,
                supportLevel: supportLevel(forCodecID: rawCodecID)
            )
        }

        private static func extractCues(
            from handle: FileHandle,
            header: Header,
            track: SubtitleTrack
        ) -> [Cue] {
            var cues: [Cue] = []
            var offset = header.segmentStart
            while offset < header.segmentEnd {
                guard let element = readElement(in: handle, at: offset, limit: header.segmentEnd) else { break }
                if element.id == clusterID {
                    cues.append(contentsOf: parseCluster(
                        in: handle,
                        element: element,
                        timestampScale: header.timestampScale,
                        track: track
                    ))
                }
                offset = nextOffset(after: element, fallback: offset)
            }
            return cues.sorted { lhs, rhs in
                if abs(lhs.start - rhs.start) > 0.0001 {
                    return lhs.start < rhs.start
                }
                return lhs.text < rhs.text
            }
        }

        private static func parseCluster(
            in handle: FileHandle,
            element: EBMLElement,
            timestampScale: UInt64,
            track: SubtitleTrack
        ) -> [Cue] {
            var cues: [Cue] = []
            var clusterTimecode: Int64 = 0
            var offset = element.dataOffset
            while offset < element.endOffset {
                guard let child = readElement(in: handle, at: offset, limit: element.endOffset) else { break }
                switch child.id {
                case clusterTimecodeID:
                    if let size = child.size,
                       let value = readUnsignedInteger(in: handle, offset: child.dataOffset, length: size) {
                        clusterTimecode = Int64(value)
                    }
                case simpleBlockID:
                    if let cue = parseBlock(
                        in: handle,
                        element: child,
                        clusterTimecode: clusterTimecode,
                        blockDuration: nil,
                        timestampScale: timestampScale,
                        track: track
                    ) {
                        cues.append(cue)
                    }
                case blockGroupID:
                    if let cue = parseBlockGroup(
                        in: handle,
                        element: child,
                        clusterTimecode: clusterTimecode,
                        timestampScale: timestampScale,
                        track: track
                    ) {
                        cues.append(cue)
                    }
                default:
                    break
                }
                offset = nextOffset(after: child, fallback: offset)
            }
            return cues
        }

        private static func parseBlockGroup(
            in handle: FileHandle,
            element: EBMLElement,
            clusterTimecode: Int64,
            timestampScale: UInt64,
            track: SubtitleTrack
        ) -> Cue? {
            var blockElement: EBMLElement?
            var blockDuration: UInt64?
            var offset = element.dataOffset
            while offset < element.endOffset {
                guard let child = readElement(in: handle, at: offset, limit: element.endOffset) else { break }
                switch child.id {
                case blockID:
                    blockElement = child
                case blockDurationID:
                    if let size = child.size {
                        blockDuration = readUnsignedInteger(in: handle, offset: child.dataOffset, length: size)
                    }
                default:
                    break
                }
                offset = nextOffset(after: child, fallback: offset)
            }

            guard let blockElement else { return nil }
            return parseBlock(
                in: handle,
                element: blockElement,
                clusterTimecode: clusterTimecode,
                blockDuration: blockDuration,
                timestampScale: timestampScale,
                track: track
            )
        }

        private static func parseBlock(
            in handle: FileHandle,
            element: EBMLElement,
            clusterTimecode: Int64,
            blockDuration: UInt64?,
            timestampScale: UInt64,
            track: SubtitleTrack
        ) -> Cue? {
            guard let size = element.size, size >= 4 else { return nil }
            let headerLength = min(size, 16)
            guard let headerData = readData(in: handle, offset: element.dataOffset, length: headerLength) else { return nil }

            var reader = DataBlockReader(data: headerData)
            guard let trackNumber = reader.readVIntRemovingMarker(),
                  let timecodeHigh = reader.readByte(),
                  let timecodeLow = reader.readByte(),
                  let flags = reader.readByte() else {
                return nil
            }
            guard trackNumber == track.number else { return nil }
            guard (flags & 0x06) == 0 else { return nil }
            guard size >= reader.consumed else { return nil }

            let payloadOffset = element.dataOffset + reader.consumed
            let payloadSize = size - reader.consumed
            guard payloadSize > 0, payloadSize <= maxSubtitlePayloadSize else { return nil }
            guard let payload = readData(in: handle, offset: payloadOffset, length: payloadSize),
                  let text = decodeMatroskaPayload(payload, track: track),
                  !text.isEmpty else {
                return nil
            }

            let rawTimecode = (UInt16(timecodeHigh) << 8) | UInt16(timecodeLow)
            let relativeTimecode = Int64(Int16(bitPattern: rawTimecode))
            let startUnits = max(clusterTimecode + relativeTimecode, 0)
            let start = seconds(fromMatroskaTimecode: startUnits, scale: timestampScale)
            let end = blockDuration.map {
                start + seconds(fromMatroskaTimecode: Int64($0), scale: timestampScale)
            }
            return Cue(start: start, end: end, text: text)
        }

        private static func decodeMatroskaPayload(_ data: Data, track: SubtitleTrack) -> String? {
            let text = decodeText(data)?
                .replacingOccurrences(of: "\u{0000}", with: "")
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let text, !text.isEmpty else { return nil }
            return text
        }

        private static func readElement(in handle: FileHandle, at offset: UInt64, limit: UInt64) -> EBMLElement? {
            guard offset < limit,
                  let id = readVInt(in: handle, at: offset, maxLength: 4, removeMarker: false),
                  let size = readVInt(
                    in: handle,
                    at: offset + UInt64(id.length),
                    maxLength: 8,
                    removeMarker: true
                  ) else {
                return nil
            }

            let dataOffset = offset + UInt64(id.length + size.length)
            guard dataOffset <= limit else { return nil }
            let endOffset: UInt64
            if size.isUnknown {
                endOffset = limit
            } else if size.value > limit - dataOffset {
                endOffset = limit
            } else {
                endOffset = dataOffset + size.value
            }

            return EBMLElement(
                id: id.value,
                dataOffset: dataOffset,
                size: size.isUnknown ? nil : size.value,
                endOffset: endOffset
            )
        }

        private static func readVInt(
            in handle: FileHandle,
            at offset: UInt64,
            maxLength: Int,
            removeMarker: Bool
        ) -> EBMLVInt? {
            guard let first = readData(in: handle, offset: offset, length: 1)?.first,
                  first != 0 else {
                return nil
            }

            var mask: UInt8 = 0x80
            var length = 1
            while length <= maxLength, (first & mask) == 0 {
                mask >>= 1
                length += 1
            }
            guard length <= maxLength, mask != 0 else { return nil }

            var value = UInt64(removeMarker ? first & ~mask : first)
            if length > 1 {
                guard let remaining = readData(
                    in: handle,
                    offset: offset + 1,
                    length: UInt64(length - 1)
                ),
                remaining.count == length - 1 else {
                    return nil
                }
                for byte in remaining {
                    value = (value << 8) | UInt64(byte)
                }
            }

            let valueBits = length * 7
            let unknownValue = valueBits >= 64 ? UInt64.max : (UInt64(1) << UInt64(valueBits)) - 1
            return EBMLVInt(
                value: value,
                length: length,
                isUnknown: removeMarker && value == unknownValue
            )
        }

        private static func readUnsignedInteger(
            in handle: FileHandle,
            offset: UInt64,
            length: UInt64
        ) -> UInt64? {
            guard length > 0, length <= 8,
                  let data = readData(in: handle, offset: offset, length: length),
                  UInt64(data.count) == length else {
                return nil
            }

            return data.reduce(UInt64(0)) { value, byte in
                (value << 8) | UInt64(byte)
            }
        }

        private static func readString(
            in handle: FileHandle,
            offset: UInt64,
            length: UInt64
        ) -> String? {
            guard length > 0, length <= maxInlineElementSize,
                  let data = readData(in: handle, offset: offset, length: length) else {
                return nil
            }
            return decodeText(data)?
                .replacingOccurrences(of: "\u{0000}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private static func readData(in handle: FileHandle, offset: UInt64, length: UInt64) -> Data? {
            guard length <= UInt64(Int.max) else { return nil }
            handle.seek(toFileOffset: offset)
            let data = handle.readData(ofLength: Int(length))
            guard UInt64(data.count) == length else { return nil }
            return data
        }

        private static func nextOffset(after element: EBMLElement, fallback: UInt64) -> UInt64 {
            element.endOffset > fallback ? element.endOffset : fallback + 1
        }

        private static func seconds(fromMatroskaTimecode value: Int64, scale: UInt64) -> TimeInterval {
            (Double(value) * Double(scale)) / 1_000_000_000.0
        }

        private static func supportLevel(forCodecID codecID: String) -> EmbeddedSubtitleSupportLevel {
            switch codecID.uppercased() {
            case "S_TEXT/UTF8", "S_TEXT/WEBVTT":
                return .textSupported
            case "S_TEXT/ASS", "S_TEXT/SSA":
                return .textBestEffort
            case "S_HDMV/PGS", "S_VOBSUB":
                return .unsupportedBitmap
            default:
                return .unsupportedUnknown
            }
        }

        private static func codecName(for codecID: String) -> String? {
            switch codecID.uppercased() {
            case "S_TEXT/UTF8":
                return "srt"
            case "S_TEXT/ASS":
                return "ass"
            case "S_TEXT/SSA":
                return "ssa"
            case "S_TEXT/WEBVTT":
                return "webvtt"
            case "S_HDMV/PGS":
                return "pgs"
            case "S_VOBSUB":
                return "vobsub"
            default:
                return cleanedValue(codecID)
            }
        }

        private static func assContent(from cues: [Cue], track: SubtitleTrack) -> String {
            let header = track.codecPrivate.flatMap { decodeText($0) } ?? defaultASSHeader()
            var lines = header
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
                .components(separatedBy: "\n")
            if !lines.contains(where: { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("[Events]") == .orderedSame }) {
                lines.append("[Events]")
                lines.append("Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text")
            }

            for cue in resolvedCues(from: cues) {
                lines.append(assDialogueLine(for: cue))
            }
            return lines.joined(separator: "\n")
        }

        private static func assDialogueLine(for cue: ResolvedCue) -> String {
            let fields = cue.text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            if fields.count >= 9 {
                let layer = String(fields[1])
                let style = String(fields[2])
                let name = String(fields[3])
                let marginL = String(fields[4])
                let marginR = String(fields[5])
                let marginV = String(fields[6])
                let effect = String(fields[7])
                let text = String(fields[8])
                return "Dialogue: \(layer),\(assTimestamp(cue.start)),\(assTimestamp(cue.end)),\(style),\(name),\(marginL),\(marginR),\(marginV),\(effect),\(text)"
            }

            let cleanText: String
            if cue.text.hasPrefix("Dialogue:") {
                cleanText = cue.text
                    .dropFirst("Dialogue:".count)
                    .trimmingCharacters(in: .whitespaces)
            } else {
                cleanText = cue.text
            }
            return "Dialogue: 0,\(assTimestamp(cue.start)),\(assTimestamp(cue.end)),Default,,0,0,0,,\(cleanText)"
        }

        private static func defaultASSHeader() -> String {
            """
            [Script Info]
            ScriptType: v4.00+

            [V4+ Styles]
            Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
            Style: Default,Arial,36,&H00FFFFFF,&H000000FF,&H00000000,&H80000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,10,1

            [Events]
            Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            """
        }

        private static func assTimestamp(_ seconds: TimeInterval) -> String {
            let totalCentiseconds = Int((max(seconds, 0) * 100).rounded())
            let centiseconds = totalCentiseconds % 100
            let totalSeconds = totalCentiseconds / 100
            let second = totalSeconds % 60
            let totalMinutes = totalSeconds / 60
            let minute = totalMinutes % 60
            let hour = totalMinutes / 60
            return String(format: "%d:%02d:%02d.%02d", hour, minute, second, centiseconds)
        }

        private static func vttContent(from cues: [Cue]) -> String {
            var lines = ["WEBVTT", ""]
            for cue in resolvedCues(from: cues) {
                lines.append("\(vttTimestamp(cue.start)) --> \(vttTimestamp(cue.end))")
                lines.append(cue.text)
                lines.append("")
            }
            return lines.joined(separator: "\n")
        }

        private static func vttTimestamp(_ seconds: TimeInterval) -> String {
            timestamp(seconds).replacingOccurrences(of: ",", with: ".")
        }

        private static func isMatroskaURL(_ url: URL) -> Bool {
            switch url.pathExtension.lowercased() {
            case "mkv", "mk3d", "mks", "webm":
                return true
            default:
                return false
            }
        }
    }

    public static func descriptors(for mediaURL: URL) -> [SharedLocalEmbeddedSubtitleDescriptor] {
        guard mediaURL.isFileURL else { return [] }

        let matroskaDescriptors = MatroskaTextSubtitleExtractor.descriptors(for: mediaURL)
        if !matroskaDescriptors.isEmpty {
            return matroskaDescriptors
        }

        let asset = AVURLAsset(url: mediaURL)
        return legibleTracks(in: asset).enumerated().map { offset, track in
            let codec = codecName(for: track)
            let language = cleanedValue(track.extendedLanguageTag)
            let title = cleanedValue(track.languageCode)
            return SharedLocalEmbeddedSubtitleDescriptor(
                trackIndex: offset,
                codec: codec,
                language: language,
                title: title,
                supportLevel: supportLevel(for: track, codec: codec)
            )
        }
    }

    public static func extractSubtitle(
        from mediaURL: URL,
        trackIndex: Int,
        outputURL: URL
    ) async throws -> URL {
        if let existingSize = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           existingSize > 0 {
            return outputURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let extracted = try extractSubtitleSynchronously(
                        from: mediaURL,
                        trackIndex: trackIndex,
                        outputURL: outputURL
                    )
                    continuation.resume(returning: extracted)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func extractSubtitleSynchronously(
        from mediaURL: URL,
        trackIndex: Int,
        outputURL: URL
    ) throws -> URL {
        let didStartAccessing = mediaURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                mediaURL.stopAccessingSecurityScopedResource()
            }
        }

        let matroskaDescriptors = MatroskaTextSubtitleExtractor.descriptors(for: mediaURL)
        if !matroskaDescriptors.isEmpty {
            return try MatroskaTextSubtitleExtractor.extractSubtitle(
                from: mediaURL,
                trackIndex: trackIndex,
                outputURL: outputURL
            )
        }

        let asset = AVURLAsset(url: mediaURL)
        let tracks = legibleTracks(in: asset)
        guard trackIndex >= 0, trackIndex < tracks.count else {
            throw error("Local embedded subtitle track was not found.")
        }

        let track = tracks[trackIndex]
        let codec = codecName(for: track)
        guard isTextSupported(supportLevel(for: track, codec: codec)) else {
            throw error("Local embedded subtitle codec is not supported.")
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw error("Local embedded subtitle track cannot be read.")
        }

        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? error("Local embedded subtitle reader failed to start.")
        }

        var cues: [Cue] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let text = textPayload(from: sampleBuffer), !text.isEmpty else { continue }
            guard let start = seconds(from: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) else { continue }
            let duration = seconds(from: CMSampleBufferGetDuration(sampleBuffer))
            let end = duration.flatMap { $0 > 0 ? start + $0 : nil }
            cues.append(Cue(start: start, end: end, text: text))
        }

        if reader.status == .failed {
            throw reader.error ?? error("Local embedded subtitle extraction failed.")
        }

        guard !cues.isEmpty else {
            throw error("Local embedded subtitle track did not contain readable cues.")
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try srtContent(from: cues).write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

    private static func legibleTracks(in asset: AVAsset) -> [AVAssetTrack] {
        var result: [AVAssetTrack] = []
        var seenIDs = Set<CMPersistentTrackID>()

        func append(_ tracks: [AVAssetTrack]) {
            for track in tracks {
                guard seenIDs.insert(track.trackID).inserted else { continue }
                result.append(track)
            }
        }

        append(asset.tracks(withMediaType: .subtitle))
        append(asset.tracks(withMediaType: .text))
        append(asset.tracks(withMediaType: .closedCaption))
        append(asset.tracks.filter { $0.hasMediaCharacteristic(.legible) })
        return result
    }

    private static func supportLevel(
        for track: AVAssetTrack,
        codec: String?
    ) -> EmbeddedSubtitleSupportLevel {
        let normalizedCodec = codec?.lowercased()
        if normalizedCodec == "tx3g" || normalizedCodec == "text" {
            return .textSupported
        }

        if normalizedCodec == nil, track.mediaType == .text {
            return .textBestEffort
        }

        return .unsupportedUnknown
    }

    private static func isTextSupported(_ supportLevel: EmbeddedSubtitleSupportLevel) -> Bool {
        supportLevel == .textSupported || supportLevel == .textBestEffort
    }

    private static func codecName(for track: AVAssetTrack) -> String? {
        guard let description = track.formatDescriptions.first else { return nil }
        let formatDescription = description as! CMFormatDescription
        let subtype = CMFormatDescriptionGetMediaSubType(formatDescription)
        return fourCCString(from: subtype)
    }

    private static func fourCCString(from value: FourCharCode) -> String? {
        let scalars = [
            UnicodeScalar((value >> 24) & 0xff),
            UnicodeScalar((value >> 16) & 0xff),
            UnicodeScalar((value >> 8) & 0xff),
            UnicodeScalar(value & 0xff)
        ]
        let characters = scalars.compactMap { scalar -> Character? in
            guard let scalar, scalar.value >= 32, scalar.value <= 126 else { return nil }
            return Character(scalar)
        }
        guard characters.count == 4 else { return nil }
        return String(characters)
    }

    private static func textPayload(from sampleBuffer: CMSampleBuffer) -> String? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let length = CMBlockBufferGetDataLength(blockBuffer)
        guard length > 0 else { return nil }

        var data = Data(count: length)
        let status = data.withUnsafeMutableBytes { rawBuffer -> OSStatus in
            guard let baseAddress = rawBuffer.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: baseAddress
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        let payload: Data
        if data.count >= 2 {
            let declaredLength = (Int(data[data.startIndex]) << 8) + Int(data[data.startIndex + 1])
            if declaredLength == 0 {
                return nil
            } else if declaredLength <= data.count - 2 {
                payload = data.subdata(in: (data.startIndex + 2)..<(data.startIndex + 2 + declaredLength))
            } else {
                payload = data
            }
        } else {
            payload = data
        }

        return decodeText(payload)?
            .replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeText(_ data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16BigEndian,
            .utf16LittleEndian,
            .unicode,
            .windowsCP1252
        ]

        for encoding in encodings {
            if let text = String(data: data, encoding: encoding), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func seconds(from time: CMTime) -> TimeInterval? {
        let value = CMTimeGetSeconds(time)
        guard value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func srtContent(from cues: [Cue]) -> String {
        var lines: [String] = []
        for (index, cue) in resolvedCues(from: cues).enumerated() {
            lines.append("\(index + 1)")
            lines.append("\(timestamp(cue.start)) --> \(timestamp(cue.end))")
            lines.append(cue.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func resolvedCues(from cues: [Cue]) -> [ResolvedCue] {
        let sorted = cues.sorted { lhs, rhs in
            if abs(lhs.start - rhs.start) > 0.0001 {
                return lhs.start < rhs.start
            }
            return lhs.text < rhs.text
        }

        return sorted.enumerated().map { index, cue in
            let fallbackEnd: TimeInterval
            if index + 1 < sorted.count {
                fallbackEnd = max(cue.start + 0.1, sorted[index + 1].start - 0.001)
            } else {
                fallbackEnd = cue.start + 2.0
            }
            let end = max(cue.start + 0.1, cue.end ?? fallbackEnd)
            return ResolvedCue(start: cue.start, end: end, text: cue.text)
        }
    }

    private static func timestamp(_ seconds: TimeInterval) -> String {
        let totalMilliseconds = Int((max(seconds, 0) * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let second = totalSeconds % 60
        let totalMinutes = totalSeconds / 60
        let minute = totalMinutes % 60
        let hour = totalMinutes / 60
        return String(format: "%02d:%02d:%02d,%03d", hour, minute, second, milliseconds)
    }

    private static func cleanedValue(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }
        return cleaned
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "SharedLocalEmbeddedSubtitleExtractor", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

