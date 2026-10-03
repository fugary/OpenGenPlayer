import Foundation
import AVKit
import AVFoundation
#if os(iOS)
import UIKit
#endif
import VLCKitSPM
import MediaPlayer
import Combine
import UniformTypeIdentifiers
import GenPlayerShell

// Helper for System Volume Control
private class SystemVolumeManager {
    static let shared = SystemVolumeManager()
    private let volumeView = MPVolumeView(frame: .zero)
    
    var slider: UISlider? {
        return volumeView.subviews.first(where: { $0 is UISlider }) as? UISlider
    }
    
    func setVolume(_ value: Float) {
        // Clamp to 0.0 - 1.0 for system volume
        let clamped = max(0.0, min(1.0, value))
        DispatchQueue.main.async {
            // Using MPVolumeView's internal slider is the only reliable way to set system volume
            // without using private APIs like MPVolumeView.setVolume(clamped)
            self.slider?.value = clamped
        }
    }
    func getVolume() -> Float {
        // Read directly from the slider UI which is always 100% accurate,
        // unlike AVAudioSession which sleeps when paused.
        if let slider = self.slider {
            return slider.value
        }
        return AVAudioSession.sharedInstance().outputVolume
    }
}

enum PlaybackSequenceMode: String, CaseIterable {
    case sequential
    case shuffle
    case repeatOne

    var icon: String {
        switch self {
        case .sequential: return "repeat"
        case .shuffle: return "shuffle"
        case .repeatOne: return "repeat.1"
        }
    }

    var title: String {
        switch self {
        case .sequential: return NSLocalizedString("Sequential", comment: "")
        case .shuffle: return NSLocalizedString("Shuffle", comment: "")
        case .repeatOne: return NSLocalizedString("Repeat One", comment: "")
        }
    }
}

typealias AudioPlayMode = PlaybackSequenceMode

private struct LocalEmbeddedSubtitleDescriptor: Equatable {
    let trackIndex: Int
    let codec: String?
    let language: String?
    let title: String?
    let supportLevel: EmbeddedSubtitleSupportLevel
}

private enum LocalEmbeddedSubtitleExtractor {
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

        static func descriptors(for mediaURL: URL) -> [LocalEmbeddedSubtitleDescriptor] {
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
                LocalEmbeddedSubtitleDescriptor(
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

    static func descriptors(for mediaURL: URL) -> [LocalEmbeddedSubtitleDescriptor] {
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
            return LocalEmbeddedSubtitleDescriptor(
                trackIndex: offset,
                codec: codec,
                language: language,
                title: title,
                supportLevel: supportLevel(for: track, codec: codec)
            )
        }
    }

    static func extractSubtitle(
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
        NSError(domain: "LocalEmbeddedSubtitleExtractor", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

class VLCPlaybackService: NSObject, ObservableObject {
    static let shared = VLCPlaybackService()

    struct PlaybackFailure: Identifiable, Equatable {
        let id = UUID()
        let itemID: UUID
        let message: String
    }
    
    // MARK: - Published State
    @Published var showSubtitleBrowser = false
    let subtitleIntelligence = IOSSubtitleIntelligence()
    private var audioSubtitleMetadata: (itemID: UUID, data: Data)?
    private var subtitleIntelligenceSubscription: AnyCancellable?
    @Published var state: PlayerState = PlayerState()
    @Published var isScrubbing: Bool = false
    @Published var currentSubtitleParts: [SubtitlePart] = [] // Stub for now, needs parser re-integration
    @Published var showControlOverlay: Bool = false // Restore this state
    @Published var isMuted: Bool = false
    @Published var activePlaybackFailure: PlaybackFailure?
    @Published private(set) var loadingPhase: PlaybackLoadingMonitor.Phase = .loading
    @Published var isInteractiveVideoGestureActive: Bool = false
    
    // Published explicitly for hardware volume changes
    @Published private(set) var outputVolume: Float = 0.0
    
    @Published var currentDecoder: AppSettings.VideoDecoder = {
#if targetEnvironment(simulator)
        return .software
#else
        return AppSettings.shared.defaultVideoDecoder
#endif
    }()
    @Published var secondarySubtitlePlacement: AppSettings.SecondarySubtitlePlacement = AppSettings.shared.secondarySubtitlePlacement
    @Published var secondarySubtitlePortraitVerticalPositionRatio: Double? =
        AppSettings.shared.secondarySubtitleVerticalPositionRatio(for: .portrait)
    @Published var secondarySubtitleLandscapeVerticalPositionRatio: Double? =
        AppSettings.shared.secondarySubtitleVerticalPositionRatio(for: .landscape)
    @Published var canSkipToNextTrack: Bool = false
    @Published var canSkipToPreviousTrack: Bool = false
    
    // MARK: - Floating Video (PiP) State
    @Published public var isVideoPiPActive: Bool = false
    @Published public var floatingVideoFile: VideoFile? = nil
    @Published var shouldDismissPresentedPlayerAfterPiPStart: Bool = false
    @Published var requestedVideoPlayerRestoreFile: VideoFile? = nil
    
    @Published var isAudioFloatingVisible: Bool = false
    @Published var floatingAudioFile: VideoFile?
    @Published var floatingAudioPlaylist: [VideoFile] = []
    
    @Published var audioPlayMode: AudioPlayMode = .sequential

    var onRequestNextTrack: (() -> Bool)?
    var onRequestPreviousTrack: (() -> Bool)?
    var onRequestSeekToTime: ((Double) -> Bool)?
    private var interactiveVideoGestureActivitySources: Set<ObjectIdentifier> = []

    func setInteractiveVideoGestureActive(_ isActive: Bool, source: AnyObject) {
        setInteractiveVideoGestureActive(isActive, sourceID: ObjectIdentifier(source))
    }

    func setInteractiveVideoGestureActive(_ isActive: Bool, sourceID: ObjectIdentifier) {
        if isActive {
            interactiveVideoGestureActivitySources.insert(sourceID)
        } else {
            interactiveVideoGestureActivitySources.remove(sourceID)
        }
        syncInteractiveVideoGestureActivityFlag()
    }

    func clearInteractiveVideoGestureActivity(source: AnyObject, asynchronously: Bool = false) {
        clearInteractiveVideoGestureActivity(
            sourceID: ObjectIdentifier(source),
            asynchronously: asynchronously
        )
    }

    func clearInteractiveVideoGestureActivity(
        sourceID: ObjectIdentifier,
        asynchronously: Bool = false
    ) {
        let clearSource = { [weak self] in
            guard let self else { return }
            self.interactiveVideoGestureActivitySources.remove(sourceID)
            self.syncInteractiveVideoGestureActivityFlag()
        }
        if asynchronously {
            DispatchQueue.main.async(execute: clearSource)
        } else {
            clearSource()
        }
    }

    func clearAllInteractiveVideoGestureActivity() {
        interactiveVideoGestureActivitySources.removeAll()
        syncInteractiveVideoGestureActivityFlag()
    }

    private func syncInteractiveVideoGestureActivityFlag() {
        let isActive = !interactiveVideoGestureActivitySources.isEmpty
        if isInteractiveVideoGestureActive != isActive {
            isInteractiveVideoGestureActive = isActive
        }
    }

    // MARK: - Internal Watchdog State
    private var stallWatchdogTimer: Timer?
    private var playbackStallDetector = PlaybackStallDetector()
    private var loadingMonitor: PlaybackLoadingMonitor?
    private var pendingPlaybackFailureWorkItem: DispatchWorkItem?
    internal var metadataArtworkTask: Task<Void, Never>?
    internal var metadataReadID = UUID()
    internal private(set) var playbackAttemptID = UUID() {
        didSet {
            metadataArtworkTask?.cancel()
            metadataArtworkTask = nil
        }
    }
    internal private(set) var isPreparingPlayback = false
    internal private(set) var hasTerminalPlaybackFailure = false
    var lastTimeChangedPosition: Double = 0
    private var activePlaybackTimelineOffset: Double = 0

    func resetPlaybackStallDetection() {
        playbackStallDetector.reset()
    }

    var isAwaitingSeekPlayback: Bool { playbackStallDetector.isAwaitingSeekPlayback }

    private var playbackOutputSample: PlaybackStallDetector.Sample {
        if let mpvState {
            return .init(timeMilliseconds: Int32(min(max(mpvState.time * 1000, 0), Double(Int32.max))),
                         displayedPictures: 0, playedAudioBuffers: 0)
        }
        let stats = mediaPlayer?.media?.statistics
        return .init(
            timeMilliseconds: (mediaPlayer?.time.intValue ?? 0),
            displayedPictures: stats?.displayedPictures ?? 0,
            playedAudioBuffers: stats?.playedAudioBuffers ?? 0
        )
    }

    private func beginSeekBufferingObservation() {
        stopStartupWatchdog()
        guard state.status != .paused else {
            resetPlaybackStallDetection()
            return
        }
        playbackStallDetector.beginSeek(
            sample: playbackOutputSample,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    func shouldShowPlaybackBuffering() -> Bool {
        // Initial preparation has no playback output yet; retain its immediate loading UI.
        guard hasStartedPlaybackForCurrentItem, !isPreparingPlayback else { return true }
        return playbackStallDetector.isStalled(
            sample: playbackOutputSample,
            now: ProcessInfo.processInfo.systemUptime
        )
    }

    private var loadingProgressValue: Int64 {
        if let mpvState {
            let clock = Int64(min(max(mpvState.time * 1000, 0), Double(Int32.max)))
            return min(mpvState.bufferedBytes, Int64.max - clock) + clock
        }
        guard !isPreparingPlayback, let stats = mediaPlayer?.media?.statistics else { return 0 }
        return Int64(stats.readBytes) + Int64(stats.demuxReadBytes)
            + Int64(stats.decodedVideo) + Int64(stats.decodedAudio)
    }

    func startStartupWatchdog(for item: MediaItem) {
        loadingMonitor = PlaybackLoadingMonitor(
            isRemote: item.isRemote,
            now: ProcessInfo.processInfo.systemUptime,
            progressValue: loadingProgressValue
        )
        loadingPhase = .loading
    }

    func stopStartupWatchdog() {
        loadingMonitor = nil
        if loadingPhase != .loading { loadingPhase = .loading }
    }

    func continueWaitingForPlayback() {
        guard state.status == .buffering, activePlaybackFailure == nil else { return }
        loadingMonitor?.continueWaiting(now: ProcessInfo.processInfo.systemUptime)
        loadingPhase = .loading
    }

    func cancelPendingPlaybackFailure() {
        pendingPlaybackFailureWorkItem?.cancel()
        pendingPlaybackFailureWorkItem = nil
    }

    /// Give transient engine errors a brief chance to recover before presenting a modal alert.
    func schedulePlaybackFailureIfNeeded() {
        guard pendingPlaybackFailureWorkItem == nil, !hasTerminalPlaybackFailure,
              let item = state.currentItem else { return }
        state.status = .buffering
        let attemptID = playbackAttemptID
        let player = mediaPlayer
        let work = DispatchWorkItem { [weak self, weak player] in
            guard let self, let player,
                  self.playbackAttemptID == attemptID, self.mediaPlayer === player,
                  !self.isStopInProgress else { return }
            self.pendingPlaybackFailureWorkItem = nil
            guard player.state == .error || player.state == .stopped else { return }
            self.handlePlaybackFailureIfNeeded(for: item)
        }
        pendingPlaybackFailureWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (item.isRemote ? 2.0 : 0.0), execute: work)
    }

    // For floating player to check visibility easily
    var canPlayPreviousAudio: Bool {
        guard !floatingAudioPlaylist.isEmpty, let currentItem = state.currentItem else { return false }
        if let idx = floatingAudioPlaylist.firstIndex(where: { $0.url == currentItem.url }) {
            return idx > 0
        }
        return false
    }

    var canPlayNextAudio: Bool {
        guard !floatingAudioPlaylist.isEmpty, let currentItem = state.currentItem else { return false }
        if audioPlayMode == .repeatOne { return true }
        if audioPlayMode == .shuffle { return floatingAudioPlaylist.count > 1 }
        if let idx = floatingAudioPlaylist.firstIndex(where: { $0.url == currentItem.url }) {
            return idx < floatingAudioPlaylist.count - 1
        }
        return false
    }

    @discardableResult
    func playNextAudio(autoTriggered: Bool = false) -> Bool {
        guard !floatingAudioPlaylist.isEmpty else { return false }
        
        let currentItem = state.currentItem
        let currentIndex = floatingAudioPlaylist.firstIndex(where: { $0.url == currentItem?.url }) ?? -1
        
        if audioPlayMode == .repeatOne {
            playAudioItem(at: max(currentIndex, 0), fromBeginning: true)
            return true
        }

        if audioPlayMode == .shuffle {
            if floatingAudioPlaylist.count == 1 {
                playAudioItem(at: 0, fromBeginning: true)
                return true
            }
            let candidates = floatingAudioPlaylist.indices.filter { $0 != currentIndex }
            guard let next = candidates.randomElement() ?? floatingAudioPlaylist.indices.first else { return false }
            playAudioItem(at: next)
            return true
        }

        if currentIndex >= 0 && currentIndex < floatingAudioPlaylist.count - 1 {
            playAudioItem(at: currentIndex + 1)
            return true
        }

        if autoTriggered {
            markPlaybackEndedWithoutReset()
        }
        return false
    }

    private func markPlaybackEndedWithoutReset() {
        state.status = .ended
        if state.duration > 0 {
            state.currentTime = max(state.currentTime, state.duration)
            state.progress = 1.0
        } else {
            state.progress = max(state.progress, 0.999)
        }
        reportServerStopped()
        updateNowPlayingInfo()
    }

    @discardableResult
    func playPreviousAudio() -> Bool {
        guard !floatingAudioPlaylist.isEmpty else { return false }
        let currentItem = state.currentItem
        let currentIndex = floatingAudioPlaylist.firstIndex(where: { $0.url == currentItem?.url }) ?? -1
        
        if currentIndex > 0 {
            playAudioItem(at: currentIndex - 1)
            return true
        }
        return false
    }

    private var audioItemRequest = UUID()

    func playAudioItem(at index: Int, fromBeginning: Bool = false) {
        guard index >= 0, index < floatingAudioPlaylist.count else { return }
        let videoFile = floatingAudioPlaylist[index]
        let request = UUID()
        audioItemRequest = request

        if videoFile.isRemote,
           (videoFile.serverType?.requiresDynamicPlaybackURL == true),
           videoFile.url.isFileURL {
            state.status = .buffering
            let attemptID = playbackAttemptID
            Task { @MainActor in
                do {
                    let resolved = try await AppNetworkService.shared.resolvedPlaybackFile(videoFile)
                    guard self.playbackAttemptID == attemptID, self.audioItemRequest == request else { return }
                    if index < self.floatingAudioPlaylist.count {
                        self.floatingAudioPlaylist[index] = resolved
                    }
                    var item = resolved.asMediaItem
                    item.startPosition = fromBeginning ? 0 : nil
                    self.play(item: item)
                    self.floatingAudioFile = resolved
                } catch {
                    guard self.playbackAttemptID == attemptID, self.audioItemRequest == request else { return }
                    let targetUUID = UUID(uuidString: videoFile.id) ?? UUID()
                    self.activePlaybackFailure = PlaybackFailure(itemID: targetUUID, message: error.localizedDescription)
                }
            }
            return
        }

        var item = videoFile.asMediaItem
        item.startPosition = fromBeginning ? 0 : nil  // Explicit replay bypasses history.
        self.play(item: item)
        floatingAudioFile = videoFile
    }
    
    @Published var isMenuPresented: Bool = false
    
    func setDecoder(_ decoder: AppSettings.VideoDecoder) {
        currentDecoder = resolvedDecoderPreference(decoder)
        reloadCurrentItemPreservingPlaybackState()
    }
    
    // Session sticky playback rate
    private var sessionPlaybackRate: Float? = nil
    
    // Legacy support bindings (to minimize breakage in other views during transition)
    var isPlaying: Bool { state.isPlaying }
    var isBuffering: Bool { state.isBuffering }
    var duration: String { formatTime(Int(resolvedPlaybackDuration())) }
    var currentTime: String { formatTime(Int(state.currentTime)) }
    var progress: Float {
        get { state.progress }
        set { seek(to: Double(newValue) * resolvedPlaybackDuration()) }
    }
    
    // Computed Properties for PlayerView compatibility
    var maxDuration: Double { resolvedPlaybackDuration() }

    private func shouldUsePlaybackTimelineOffset(for item: MediaItem?) -> Bool {
        guard let item = item,
              item.isRemote,
              item.serverType == .emby,
              item.remotePlaybackMethod == .transcode else {
            return false
        }
        return item.url.lastPathComponent.hasPrefix("stream.")
    }

    private func resolvedPlaybackTimelineOffset(for item: MediaItem? = nil) -> Double {
        guard shouldUsePlaybackTimelineOffset(for: item ?? state.currentItem) else {
            return 0
        }
        return max(activePlaybackTimelineOffset, 0)
    }

    func logicalPlaybackTime(fromPlayerTime playerTime: Double, duration: Double? = nil) -> Double {
        let logicalTime = max(0, playerTime + resolvedPlaybackTimelineOffset())
        if let duration, duration > 0.5 {
            return min(logicalTime, duration)
        }
        return logicalTime
    }

    func playerLocalTime(fromLogicalTime logicalTime: Double) -> Double {
        max(0, logicalTime - resolvedPlaybackTimelineOffset())
    }

    func resolvedPlaybackDuration(vlcDuration: Double? = nil, for item: MediaItem? = nil) -> Double {
        if let vlcDuration, vlcDuration > 0.5 {
            return vlcDuration
        }
        if state.duration > 0.5 {
            return state.duration
        }
        if let fileDuration = (item ?? state.currentItem)?.videoFile?.duration, fileDuration > 0.5 {
            return fileDuration
        }
        return 0
    }

    func resolvedPlaybackProgress(currentTime: Double, duration: Double, fallbackPosition: Float) -> Float {
        guard duration > 0.5 else {
            return min(max(fallbackPosition, 0), 1)
        }
        return Float(max(0.0, min(1.0, currentTime / duration)))
    }


    var fileInfo: [(key: String, value: String)] {
        var info: [(key: String, value: String)] = []
        if let item = state.currentItem {
            info.append((key: "Title", value: item.title))
            info.append((key: "Artist", value: item.artist ?? "-"))
            info.append((key: "Resolution", value: state.videoResolution))
        }
        return info
    }
    
    /// Rich media info sections for the redesigned VideoInfoView
    struct MediaInfoSection: Identifiable {
        let id: String  // Stable ID based on title, prevents scroll reset on state updates
        let title: String
        let icon: String
        let items: [(key: String, value: String)]
        
        init(title: String, icon: String, items: [(key: String, value: String)]) {
            self.id = title
            self.title = title
            self.icon = icon
            self.items = items
        }
    }
    
    var mediaInfoSections: [MediaInfoSection] {
        var sections: [MediaInfoSection] = []
        let hasServerStreams = !(state.currentItem?.serverMediaStreams ?? []).isEmpty
        
        // 1. General Section - basic file info only (no stream-level details when server data available)
        var general: [(key: String, value: String)] = []
        if let item = state.currentItem {
            general.append((key: NSLocalizedString("Title", comment: ""), value: item.title))
            general.append((key: NSLocalizedString("MPV.Engine", comment: ""), value: isUsingMPV ? "mpv" : "VLC"))

            func normalized(_ value: String?) -> String? {
                guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !trimmed.isEmpty else {
                    return nil
                }
                return trimmed
            }

            func appendMetadataRow(_ key: String, value: String?) {
                guard let value = normalized(value) else { return }
                general.append((key: key, value: value))
            }

            let preferredArtist = normalized(item.artist) ??
                normalized(item.albumArtist) ??
                normalized(item.author) ??
                normalized(item.composer)

            appendMetadataRow(NSLocalizedString("Artist", comment: ""), value: preferredArtist)
            appendMetadataRow(NSLocalizedString("Album", comment: ""), value: item.album)
            appendMetadataRow(NSLocalizedString("Album Artist", comment: ""), value: item.albumArtist)
            appendMetadataRow(NSLocalizedString("Author", comment: ""), value: item.author)
            appendMetadataRow(NSLocalizedString("Composer", comment: ""), value: item.composer)
            
            let displayPath = item.serverPath ?? item.url.path
            general.append((key: NSLocalizedString("Path", comment: ""), value: displayPath))
            
            let container = item.serverContainer ?? item.url.pathExtension.uppercased()
            if !container.isEmpty {
                general.append((key: NSLocalizedString("Container", comment: ""), value: container.uppercased()))
            }
            if let qualityID = item.preferredPlaybackQualityID {
                general.append((
                    key: NSLocalizedString("Requested Quality", comment: ""),
                    value: RemotePlaybackQualityCatalog.currentOptionTitle(from: qualityID)
                ))
            }
            if let method = item.remotePlaybackMethod {
                general.append((
                    key: NSLocalizedString("Play Method", comment: ""),
                    value: localizedPlaybackMethod(method)
                ))
            }
            if let playbackResolution = currentPlaybackResolutionDisplay() {
                general.append((
                    key: hasServerStreams
                        ? NSLocalizedString("Playback Resolution", comment: "")
                        : NSLocalizedString("Resolution", comment: ""),
                    value: playbackResolution
                ))
            }
        }
        if state.duration > 0 {
            general.append((key: NSLocalizedString("Duration", comment: ""), value: formatTime(Int(state.duration))))
        }
        if let fileSize = state.currentItem?.serverSize, fileSize > 0 {
            general.append((key: NSLocalizedString("Size", comment: ""), value: formatFileSize(fileSize)))
        }
        if !hasServerStreams, let bitrate = state.currentItem?.serverBitrate, bitrate > 0 {
            general.append((key: NSLocalizedString("Bitrate", comment: ""), value: "\(bitrate / 1000) kbps"))
        }
        if !general.isEmpty {
            sections.append(MediaInfoSection(title: NSLocalizedString("General", comment: ""), icon: "info.circle.fill", items: general))
        }
        
        if let info = currentHDRInfo {
            sections.append(MediaInfoSection(title: NSLocalizedString("HDR.Info.Title", comment: ""), icon: "sun.max.fill",
                items: info.rows { NSLocalizedString($0, comment: "") }))
        }

        // 2. Server-provided rich media streams (Jellyfin/Emby)
        if let streams = state.currentItem?.serverMediaStreams, !streams.isEmpty {
            // Sort streams by type: Video → Audio → Subtitle → other
            let typeOrder: [String: Int] = ["Video": 0, "Audio": 1, "Subtitle": 2]
            let sortedStreams = streams.sorted { a, b in
                let typeA = (a["Type"] as? String) ?? ""
                let typeB = (b["Type"] as? String) ?? ""
                return (typeOrder[typeA] ?? 3) < (typeOrder[typeB] ?? 3)
            }
            
            var videoIndex = 0
            var audioIndex = 0
            var subtitleIndex = 0
            
            // Count totals for numbering
            let videoCount = sortedStreams.filter { ($0["Type"] as? String) == "Video" }.count
            let audioCount = sortedStreams.filter { ($0["Type"] as? String) == "Audio" }.count
            let subtitleCount = sortedStreams.filter { ($0["Type"] as? String) == "Subtitle" }.count
            
            for stream in sortedStreams {
                let streamType = (stream["Type"] as? String) ?? ""
                
                if streamType == "Video" {
                    videoIndex += 1
                    var items: [(key: String, value: String)] = []
                    if let title = stream["DisplayTitle"] as? String, !title.isEmpty {
                        items.append((key: NSLocalizedString("Title", comment: ""), value: title))
                    }
                    if let codec = stream["Codec"] as? String, !codec.isEmpty {
                        items.append((key: NSLocalizedString("Codec", comment: ""), value: codec.uppercased()))
                    }
                    if let w = stream["Width"] as? Int, let h = stream["Height"] as? Int, w > 0 {
                        items.append((key: NSLocalizedString("Resolution", comment: ""), value: "\(w)x\(h)"))
                    }
                    if let bitrate = stream["BitRate"] as? Int, bitrate > 0 {
                        items.append((key: NSLocalizedString("Bitrate", comment: ""), value: "\(bitrate / 1000) kbps"))
                    }
                    if let fps = stream["RealFrameRate"] as? Double, fps > 0 {
                        items.append((key: NSLocalizedString("Framerate", comment: ""), value: String(format: "%.3f fps", fps)))
                    } else if let fps = stream["AverageFrameRate"] as? Double, fps > 0 {
                        items.append((key: NSLocalizedString("Framerate", comment: ""), value: String(format: "%.3f fps", fps)))
                    }
                    if let profile = stream["Profile"] as? String, !profile.isEmpty {
                        items.append((key: NSLocalizedString("Profile", comment: ""), value: profile))
                    }
                    if let level = stream["Level"] as? Int {
                        items.append((key: NSLocalizedString("Level", comment: ""), value: "\(level)"))
                    }
                    if let aspect = stream["AspectRatio"] as? String, !aspect.isEmpty {
                        items.append((key: NSLocalizedString("Aspect Ratio", comment: ""), value: aspect))
                    }
                    if let bitDepth = stream["BitDepth"] as? Int {
                        items.append((key: NSLocalizedString("Bit Depth", comment: ""), value: "\(bitDepth) bit"))
                    }
                    if let pixFmt = stream["PixelFormat"] as? String, !pixFmt.isEmpty {
                        items.append((key: NSLocalizedString("Pixel Format", comment: ""), value: pixFmt))
                    }
                    if let videoRange = stream["VideoRange"] as? String, !videoRange.isEmpty {
                        items.append((key: NSLocalizedString("Video Range", comment: ""), value: videoRange))
                    }
                    let sectionTitle = videoCount > 1 ? "\(NSLocalizedString("Video", comment: "")) \(videoIndex)" : NSLocalizedString("Video", comment: "")
                    sections.append(MediaInfoSection(title: sectionTitle, icon: "film.fill", items: items))
                    
                } else if streamType == "Audio" {
                    audioIndex += 1
                    var items: [(key: String, value: String)] = []
                    if let title = stream["DisplayTitle"] as? String, !title.isEmpty {
                        items.append((key: NSLocalizedString("Title", comment: ""), value: title))
                    }
                    if let lang = stream["Language"] as? String, !lang.isEmpty {
                        items.append((key: NSLocalizedString("Language", comment: ""), value: lang))
                    }
                    if let codec = stream["Codec"] as? String, !codec.isEmpty {
                        items.append((key: NSLocalizedString("Codec", comment: ""), value: codec.uppercased()))
                    }
                    if let layout = stream["ChannelLayout"] as? String, !layout.isEmpty {
                        items.append((key: NSLocalizedString("Layout", comment: ""), value: layout))
                    }
                    if let channels = stream["Channels"] as? Int, channels > 0 {
                        items.append((key: NSLocalizedString("Channels", comment: ""), value: "\(channels) ch"))
                    }
                    if let rate = stream["SampleRate"] as? Int, rate > 0 {
                        items.append((key: NSLocalizedString("Sample Rate", comment: ""), value: "\(rate) Hz"))
                    }
                    if let bitrate = stream["BitRate"] as? Int, bitrate > 0 {
                        items.append((key: NSLocalizedString("Bitrate", comment: ""), value: "\(bitrate / 1000) kbps"))
                    }
                    if let isDefault = stream["IsDefault"] as? Bool {
                        items.append((key: NSLocalizedString("Default", comment: ""), value: isDefault ? NSLocalizedString("Yes", comment: "") : NSLocalizedString("No", comment: "")))
                    }
                    let sectionTitle = audioCount > 1 ? "\(NSLocalizedString("Audio", comment: "")) \(audioIndex)" : NSLocalizedString("Audio", comment: "")
                    sections.append(MediaInfoSection(title: sectionTitle, icon: "speaker.wave.2.fill", items: items))
                    
                } else if streamType == "Subtitle" {
                    subtitleIndex += 1
                    var items: [(key: String, value: String)] = []
                    if let title = stream["DisplayTitle"] as? String, !title.isEmpty {
                        items.append((key: NSLocalizedString("Title", comment: ""), value: title))
                    }
                    if let lang = stream["Language"] as? String, !lang.isEmpty {
                        items.append((key: NSLocalizedString("Language", comment: ""), value: lang))
                    }
                    if let codec = stream["Codec"] as? String, !codec.isEmpty {
                        items.append((key: NSLocalizedString("Codec", comment: ""), value: codec.uppercased()))
                    }
                    if let isDefault = stream["IsDefault"] as? Bool {
                        items.append((key: NSLocalizedString("Default", comment: ""), value: isDefault ? NSLocalizedString("Yes", comment: "") : NSLocalizedString("No", comment: "")))
                    }
                    if let isForced = stream["IsForced"] as? Bool, isForced {
                        items.append((key: NSLocalizedString("Forced", comment: ""), value: NSLocalizedString("Yes", comment: "")))
                    }
                    if let isExternal = stream["IsExternal"] as? Bool, isExternal {
                        items.append((key: NSLocalizedString("External", comment: ""), value: NSLocalizedString("Yes", comment: "")))
                    }
                    let sectionTitle = subtitleCount > 1 ? "\(NSLocalizedString("Subtitle", comment: "")) \(subtitleIndex)" : NSLocalizedString("Subtitle", comment: "")
                    sections.append(MediaInfoSection(title: sectionTitle, icon: "captions.bubble.fill", items: items))
                }
            }
        } else {
            // Fallback for local files: use VLC track names
            if !state.audioTracks.isEmpty {
                for (i, track) in state.audioTracks.enumerated() {
                    let items: [(key: String, value: String)] = [
                        (key: NSLocalizedString("Title", comment: ""), value: track.name)
                    ]
                    let title = state.audioTracks.count > 1 ? "\(NSLocalizedString("Audio", comment: "")) \(i + 1)" : NSLocalizedString("Audio", comment: "")
                    sections.append(MediaInfoSection(title: title, icon: "speaker.wave.2.fill", items: items))
                }
            }
            if !state.subtitleTracks.isEmpty {
                for (i, track) in state.subtitleTracks.enumerated() {
                    let items: [(key: String, value: String)] = [
                        (key: NSLocalizedString("Title", comment: ""), value: track.name)
                    ]
                    let title = state.subtitleTracks.count > 1 ? "\(NSLocalizedString("Subtitle", comment: "")) \(i + 1)" : NSLocalizedString("Subtitle", comment: "")
                    sections.append(MediaInfoSection(title: title, icon: "captions.bubble.fill", items: items))
                }
            }
        }
        
        return sections
    }

    private func currentPlaybackResolutionDisplay() -> String? {
        let videoSize = videoNaturalSize
        if videoSize.width > 0 && videoSize.height > 0 {
            return "\(Int(videoSize.width))x\(Int(videoSize.height))"
        }

        guard let streams = state.currentItem?.serverMediaStreams else { return nil }
        guard let videoStream = streams.first(where: { (($0["Type"] as? String) ?? "").caseInsensitiveCompare("Video") == .orderedSame }) else {
            return nil
        }

        let width = videoStream["Width"] as? Int ?? 0
        let height = videoStream["Height"] as? Int ?? 0
        guard width > 0 && height > 0 else { return nil }
        return "\(width)x\(height)"
    }

    private func localizedPlaybackMethod(_ method: RemotePlaybackMethod) -> String {
        switch method {
        case .directPlay:
            return NSLocalizedString("Direct Play", comment: "")
        case .directStream:
            return NSLocalizedString("Direct Stream", comment: "")
        case .transcode:
            return NSLocalizedString("Transcode", comment: "")
        }
    }
    
    private func formatFileSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }
        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
    
    // MARK: - Volume & Brightness
    
    private func setupVolumeObservation() {
        guard !hasConfiguredVolumeObservation else { return }
        hasConfiguredVolumeObservation = true
        outputVolume = AVAudioSession.sharedInstance().outputVolume
        
        // Skip `.initial` so entering the player does not emit a fake "volume changed" event.
        volumeObserver = AVAudioSession.sharedInstance().observe(\.outputVolume, options: [.new]) { [weak self] session, change in
            guard let self = self, let newVolume = change.newValue else { return }
            
            // Only update if there's a significant change to avoid feedback loops
            // when programmatically setting volume (which also triggers KVO)
            if abs(newVolume - self.outputVolume) > 0.01 {
                DispatchQueue.main.async {
                    self.outputVolume = newVolume
                    self.autoUnmuteIfNeeded(for: newVolume)
                }
            }
        }
    }
    
    var volume: Float {
        get { return SystemVolumeManager.shared.getVolume() }
        set {
            let clamped = max(0.0, min(1.0, newValue))
            SystemVolumeManager.shared.setVolume(clamped)
            // Manually update outputVolume to reflect programmatic changes immediately
            // KVO will still fire, but this ensures the @Published property is current
            // and helps prevent the KVO from triggering a UI update if the value is already set.
            DispatchQueue.main.async {
                self.outputVolume = clamped
                self.autoUnmuteIfNeeded(for: clamped)
            }
        }
    }
    private var playbackScreen: UIScreen {
        playerView?.window?.windowScene?.screen ?? UIScreen.main
    }
    var brightness: CGFloat { playbackScreen.brightness }
    var aspectRatio: String {
        get { state.aspectRatio }
        set { 
            state.aspectRatio = newValue 
            // Apply to VLC if needed, e.g. mediaPlayer?.videoAspectRatio = ...
        }
    }
    var videoDisplayMode: VideoDisplayMode {
        get { state.videoDisplayMode }
        set { state.videoDisplayMode = newValue }
    }
    var interactiveVideoZoomScale: CGFloat {
        get { state.interactiveVideoZoomScale }
        set { state.interactiveVideoZoomScale = VLCPlaybackService.clampedInteractiveVideoZoomScale(newValue) }
    }
    var interactiveVideoOffset: CGSize {
        get { state.interactiveVideoOffset }
        set { state.interactiveVideoOffset = newValue }
    }
    var hasInteractiveVideoTransform: Bool {
        state.interactiveVideoZoomScale > 1.0001 ||
        abs(state.interactiveVideoOffset.width) > 0.5 ||
        abs(state.interactiveVideoOffset.height) > 0.5
    }
    /// Current mpv video diagnostics only; server source tags are not output evidence.
    var currentHDRInfo: MPVHDRInfo? {
        guard isUsingMPV,
              state.currentItem.map({ resolvedPlaybackItemType(for: $0) == .video }) == true,
              let info = mpvState?.hdrInfo, info.isHDR else { return nil }
        return info
    }

    var videoNaturalSize: CGSize { mpvState?.size ?? (mediaPlayer?.videoSize ?? .zero) }
    var audioTracks: [MediaTrack] { state.audioTracks }
    var subtitleTracks: [MediaTrack] {
        state.subtitleTracks + (subtitleIntelligence.hasGeneratedSubtitles
            ? [MediaTrack(id: IOSSubtitleIntelligence.generatedPrimaryID, name: subtitleIntelligence.generatedName, isExternal: true)] : [])
    }
    var displayedPrimarySubtitleParts: [SubtitlePart] {
        subtitleIntelligence.isGeneratedPrimary
            ? subtitleIntelligence.primaryParts(at: state.currentTime - subtitleDelay) : currentSubtitleParts
    }
    private var canOfferSubtitleTranslation: Bool {
        playbackCapabilities.supports(.subtitleTranslation,
            isVideo: state.currentItem.map { resolvedPlaybackItemType(for: $0) == .video } ?? false)
            && (subtitleIntelligence.isGeneratedPrimary || effectiveCurrentSubtitleTrackID != -1 || subtitleIntelligence.isTranslatingAudio)
    }

    var secondarySubtitleTracks: [MediaTrack] {
        guard AppSettings.shared.enableSecondarySubtitlesBeta else { return [] }

        let tracks = state.secondarySubtitleTracks
            .enumerated()
            .map { offset, track in
                MediaTrack(
                    id: secondarySubtitleMenuID(track, index: offset),
                    name: secondarySubtitleDisplayName(for: track),
                    isExternal: track.isExternal
                )
            }
        var extra: [MediaTrack] = []
        if #available(iOS 18.0, *), canOfferSubtitleTranslation {
            extra.append(MediaTrack(id: IOSSubtitleIntelligence.translatedSecondaryID, name: NSLocalizedString(subtitleIntelligence.isTranslatingAudio ? "SI.TranslatedSecondary" : "Translation.Primary", comment: ""), isExternal: true))
        }
        if subtitleIntelligence.hasGeneratedSubtitles {
            extra.append(MediaTrack(id: IOSSubtitleIntelligence.generatedSecondaryID, name: subtitleIntelligence.generatedName, isExternal: true))
        }
        return [MediaTrack(id: -1, name: NSLocalizedString("Off", comment: ""), isExternal: false)] + extra + tracks
    }
    var shouldShowSecondarySubtitleControls: Bool {
        guard AppSettings.shared.enableSecondarySubtitlesBeta else { return false }
        if #available(iOS 18.0, *) { return true }
        return state.currentSecondarySubtitleTrackID != nil ||
            state.secondarySubtitleTracks.contains { canSelectSecondarySubtitle($0) }
    }
    var audioDelay: Double { AppSettings.shared.audioDelaySeconds }

    var subtitleDelay: Double { AppSettings.shared.subtitleDelaySeconds }
    var currentAudioTrack: Int { state.currentAudioTrackID }
    var currentSubtitleTrack: Int {
        subtitleIntelligence.isGeneratedPrimary ? IOSSubtitleIntelligence.generatedPrimaryID : effectiveCurrentSubtitleTrackID
    }
    private var effectiveCurrentSubtitleTrackID: Int {
        if isUsingMPV { return state.currentSubtitleTrackID }
        let actualTrackID = Int((mediaPlayer?.currentVideoSubTitleIndex ?? -1))
        if actualTrackID != -1,
           state.subtitleTracks.contains(where: { $0.id == actualTrackID }) {
            return actualTrackID
        }
        return state.currentSubtitleTrackID
    }
    var currentSecondarySubtitleTrackID: Int {
        guard AppSettings.shared.enableSecondarySubtitlesBeta else { return -1 }

        if subtitleIntelligence.secondaryID != -1 { return subtitleIntelligence.secondaryID }
        guard let selectedID = state.currentSecondarySubtitleTrackID,
              let index = state.secondarySubtitleTracks.firstIndex(where: { $0.id == selectedID }) else {
            return -1
        }
        return secondarySubtitleMenuID(state.secondarySubtitleTracks[index], index: index)
    }
    var currentSecondarySubtitleParts: [SubtitlePart] {
        guard AppSettings.shared.enableSecondarySubtitlesBeta else { return [] }
        if subtitleIntelligence.secondaryID != -1 {
            return subtitleIntelligence.secondaryParts(at: state.currentTime - subtitleDelay - state.secondarySubtitleDelay)
        }
        return state.secondarySubtitleParts
    }
    var secondarySubtitleStatus: SecondarySubtitleStatus {
        guard AppSettings.shared.enableSecondarySubtitlesBeta else { return .disabled }
        if subtitleIntelligence.secondaryID != -1 { return .ready }
        return state.secondarySubtitleStatus
    }
    var playbackRate: Float { isUsingMPV ? state.rate : (mediaPlayer?.rate ?? 1) }
    var availablePlaybackRates: [Float] { isUsingMPV ? MPVPlaybackSpeed.rates : Self.availablePlaybackRates }
    static let availablePlaybackRates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 2.5, 3.0, 4.0]
    static let availableVideoDisplayModes: [VideoDisplayMode] = [.fit, .fill]
    
    var currentPlaylistIndex: Int { 0 } // Stub, managed externally now
    var playlist: [URL] { [] } // Stub, managed externally now
    
    // MARK: - Internal Components
    @Published private(set) var mpvEngine: MPVPlaybackEngine?
    var isUsingMPV: Bool { mpvEngine != nil }
    var playbackCapabilities: PlaybackEngineCapabilities {
        .init(platform: .iOS, engine: isUsingMPV || isPreparingMPV ? .mpv : .vlc)
    }
    var canUseNativeMPVPictureInPicture: Bool {
        isUsingMPV && playbackCapabilities.supports(.pictureInPicture,
            isVideo: state.currentItem.map { resolvedPlaybackItemType(for: $0) == .video } ?? false)
    }
    private var transport: any PlaybackTransport {
        if let mpvEngine { return MPVPlaybackTransport(engine: mpvEngine) }
        return VLCPlaybackTransport(player: mediaPlayer)
    }
    // A/B comparison applies to this item only; Settings remains the default for new items.
    private var playbackEngineOverride: String?
    var canSwitchPlaybackEngine: Bool {
        guard PlaybackEngineAvailability.current.vlc && PlaybackEngineAvailability.current.mpv else { return false }
        guard let item = state.currentItem,
              PlaybackEngineCapabilities.switchingRestriction(
                isPreparing: isPreparingPlayback, isStopped: isStopInProgress,
                hasFailed: hasTerminalPlaybackFailure,
                isPictureInPicture: isVideoPiPActive || videoPiPController?.isPreparingOrActive == true,
                isLive: item.isLiveStream, isSeekable: isSeekable,
                duration: Double(state.duration)) == nil else { return false }
        return MPVUIKitPlaybackPolicy.supports(url: item.url,
            isVideo: resolvedPlaybackItemType(for: item) == .video, isAudio: resolvedPlaybackItemType(for: item) == .audio, requiresVLCBridge: false)
    }

    func switchPlaybackEngine(to engine: String) {
        guard ["vlc", "mpv"].contains(engine), canSwitchPlaybackEngine,
              (engine == "mpv") != isUsingMPV else { return }
        playbackEngineOverride = engine
        reloadCurrentItemPreservingPlaybackState(switchingEngine: true)
    }
    var isCurrentPlaybackEngineDefault: Bool {
        (UserDefaults.standard.string(forKey: "iosPlaybackEngine") ?? "mpv") == (isUsingMPV ? "mpv" : "vlc")
    }

    func saveCurrentPlaybackEngineAsDefault() {
        guard state.currentItem != nil, !hasTerminalPlaybackFailure, !isStopInProgress else { return }
        UserDefaults.standard.set(isUsingMPV ? "mpv" : "vlc", forKey: "iosPlaybackEngine")
    }

    var canRecoverMPVWithVLC: Bool {
        PlaybackEngineAvailability.current.vlc && isUsingMPV && hasTerminalPlaybackFailure && state.currentItem != nil && !isStopInProgress
    }

    func recoverMPVWithVLC() {
        guard canRecoverMPVWithVLC else { return }
        playbackEngineOverride = "vlc"
        reloadCurrentItemPreservingPlaybackState(switchingEngine: true)
    }

    var isSeekable: Bool { transport.state.seekable }
    @Published private(set) var bufferedRanges: [MPVBufferedRange] = []
    @Published private(set) var cacheInputBytesPerSecond: Int64?
    @Published private(set) var cacheReadIdle = true
    private var mpvState: MPVPlaybackEngine.State?
    @Published private(set) var nativeASSBounds: CGRect?
    @Published private(set) var nativeASSHasContent = false
    var nativeASSUsesVideoViewport: Bool { mpvEngine?.usesPixelBufferOutput == true }
    private var remoteMPVSubtitleLoader = IOSRemoteSubtitleLoader()
    private var mpvDecodedSecondary = MacMPVDecodedSubtitles(maximumTextBytes: 4 * 1024 * 1024)
    private var mpvDecodedSecondaryID: Int?
    private var mpvSecondaryRendering: MPVSecondarySubtitleRendering?
    private var mpvSecondaryRenderingProperties: [String: String] = [:]
    private var mpvSecondaryLayoutOrientation: AppSettings.SecondarySubtitleLayoutOrientation?
    private var mpvSubtitleSelectionRequest: UUID?
    private var mpvInterruptionResume: (attempt: UUID, control: UUID)?
    private var mpvPauseRequested = false
    private var mpvReadAheadByteCache: MPVReadAheadByteCache?
    private var isPreparingMPV = false
    private var mpvLoaded = false
    private var mpvPendingExternalSubtitle: URL?
    private var mpvAttachedSidecars = Set<URL>()
    private var mpvRemovedDuplicateSubtitles = Set<Int>()
    private var mpvSidecarTasks: [URL: Task<Void, Never>] = [:]
    private var mpvTrackPreferenceKey = ""
    private var mpvTrackChoices: [String: MacMPVTrackChoice] = [:]
    private var mpvPendingTrackChoices: [String: MacMPVTrackChoice] = [:]
    private var pendingSecondaryHandoff: IOSPlaybackSecondarySelection?
    internal var pendingEngineTracks: [String: IOSPlaybackTrackSelection] = [:]
    internal var preservesDisabledAudio = false
    private var mpvTrackScopeKey: String?
    internal var mediaPlayer: VLCMediaPlayer? = VLCPlaybackTransport.makePlayer()
    weak internal var playerView: UIView?
    internal var pipUsableViewController: UIViewController?
    internal var videoPiPController: VLCPlayerPictureInPictureController?
    internal var pipCancellable: AnyCancellable?
    
    private var mediaPlayerTimer: Timer?
    internal var lastUIUpdateTime: TimeInterval = 0
    internal var lastJellyfinSyncTime: TimeInterval = 0
    internal var lastSavedTime: TimeInterval = 0
    internal var lastTracksRefreshTime: TimeInterval = 0
    internal var lastNowPlayingRefreshTime: TimeInterval = 0
    internal var nowPlayingArtworkRequestKey: String?
    internal var nowPlayingArtworkDataTask: URLSessionDataTask?
    
    // State Flags
    internal var initialSeekPerformed = false
    internal var isRecoveringFromFalseEnded = false
    internal var hasReportedServerPlaying = false
    internal var isFetchingServerPlaybackContext = false
    internal var shouldBypassPlaybackContextFetch = false
    internal var playbackContextFetchFailureCount = 0
    internal var lastPlaybackContextFetchFailureTime: TimeInterval = 0
    internal var pendingSeekPosition: Double?
    internal var pendingAudioTrack: Int?
    internal var pendingSubtitleTrack: Int?
    internal var pendingAudioTrackQuery: String?
    internal var pendingSubtitleTrackQuery: String?
    internal var pendingAudioTrackOrdinal: Int?
    internal var pendingSubtitleTrackOrdinal: Int?
    internal var pendingSecondarySubtitleTrackQuery: String?
    internal var pendingSecondarySubtitleTrackOrdinal: Int?
    internal var hasResolvedAutomaticSubtitleSelection: Bool = false
    internal var isApplyingAutomaticSubtitleSelection = false
    internal var hasStartedPlaybackForCurrentItem = false
    internal var hasFittedMacWindowForCurrentItem = false
    internal var hasResetReplayProgressLocallyForCurrentItem = false
    internal let externalSubtitleTrackBaseID: Int = 10_000
    internal let secondarySubtitleTrackBaseID: Int = 20_000
    internal var externalSubtitleCandidates: [URL] = []
    internal var externalSubtitleMediaKey: String?
    internal var externalSubtitleDisplayNames: [String: String] = [:]
    internal var normalizedExternalSubtitleCache: [String: URL] = [:]
    internal var externalSubtitleResolvedTrackIDs: [String: Int] = [:]
    internal var remoteSubtitleSelectionTask: Task<Void, Never>?
    internal var secondarySubtitleLoadTask: Task<Void, Never>?
    internal var secondarySubtitleTimeline: SubtitleTimeline?
    private var secondarySubtitleTimelineCache: [String: SubtitleTimeline] = [:]
    private var secondarySubtitleTimelineCacheOrder: [String] = []
    private let secondarySubtitleTimelineCacheLimit = 24
    internal var lastExternalSubtitleReloadKey: String?
    internal var deferredTrackRefreshNeeded: Bool = false
    private var localEmbeddedSubtitleDescriptorCache: [String: [LocalEmbeddedSubtitleDescriptor]] = [:]
    private var seekPreviewRemoteTask: Task<Void, Never>?
    private var seekPreviewRequestToken: UUID?
    private var seekPreviewThumbnailGenerator: (any PlaybackPreviewProvider)?
    private var seekPreviewWarmupTask: Task<Void, Never>?
    private var seekPreviewWarmupItemID: UUID?
    private var seekPreviewWarmupTimeBucket: Int?
    private var seekPreviewWarmupMediaSourceID: String?
    private(set) var remoteSeekPreviewFrameIntervalSeconds: Double?
    private let seekPreviewThumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 96
        return cache
    }()
    
    // Debounce Work Item for Playing State
    internal var pendingPlayingWorkItem: DispatchWorkItem?
    
    // Debounce Work Item for Metadata
    internal var pendingMetadataWorkItem: DispatchWorkItem?
    
    // Observe hardware volume changes
    private var volumeObserver: NSKeyValueObservation?
    private var hasConfiguredVolumeObservation: Bool = false
    private let detachedPlayerTeardownQueue = DispatchQueue(
        label: "GenPlayer.VLCPlaybackService.detachedPlayerTeardown",
        qos: .utility
    )
    private var pendingStopWorkItem: DispatchWorkItem?
    private var pendingActivationReconciliationWorkItem: DispatchWorkItem?
    internal private(set) var isPlaybackSuspendedForBackground = false
    private var deferredBackgroundPlayback: (() -> Void)?
    internal private(set) var playbackControlID = UUID()
    private var pendingResumeControlID: UUID?
    private let audioSessionCoordinator = PlaybackAudioSessionCoordinator(activate: { knownActive in
        let session = AVAudioSession.sharedInstance()
        let configurationChanged = session.category != .playback || session.mode != .default
        if configurationChanged {
            try session.setCategory(.playback, mode: .default, options: [])
        }
        if !knownActive || configurationChanged { try session.setActive(true) }
    }, deactivate: {
        try AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    })
    internal var isStopInProgress: Bool = false
    private var shouldDismissPlayerWhenPiPStarts: Bool = false
    private var isRestoringPlayerFromPictureInPicture = false
    private var pendingPictureInPictureRestoreFile: VideoFile?
    private var pendingDrawablePlaybackSessionRestoreAfterPictureInPicture = false
    private var suppressAutomaticPictureInPictureUntil: TimeInterval = .zero
    private var suppressPictureInPictureRestoreAutoRotateUntil: TimeInterval = .zero
    private var suppressPlayerViewStopDuringPictureInPictureRestoreUntil: TimeInterval = .zero
    var pictureInPictureSeekResumeGraceDeadline: TimeInterval = .zero
    internal var pendingPlaybackResumeTimeGuard: Double?
    internal var pendingPlaybackResumeTimeGuardDeadline: TimeInterval = .zero
    
    // Services
    internal let historyService = HistoryService.shared
    
    override init() {
        super.init()
        MacMPVTrackChoice.sanitizeStoredPreferences()
        outputVolume = SystemVolumeManager.shared.getVolume()
        setupRemoteCommands()
        setupBackgroundHandling()
        configureSubtitleIntelligence()
        mediaPlayer?.delegate = self
        configureTextRenderer(for: mediaPlayer)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    private func setupBackgroundHandling() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleMPVAudioInterruption), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleMPVAudioRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleWillResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleDidBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
    }
    
    @objc private func handleMPVAudioInterruption(_ notification: Notification) {
        let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let attempt = playbackAttemptID
        DispatchQueue.main.async { [weak self] in
            guard let self, self.playbackAttemptID == attempt, self.isUsingMPV else { return }
            if rawType == AVAudioSession.InterruptionType.began.rawValue {
                let resume = !self.mpvPauseRequested && !self.hasTerminalPlaybackFailure
                self.pausePlaybackSmoothly(reportReason: "pause")
                self.audioSessionCoordinator.invalidateActivation()
                self.mpvInterruptionResume = resume ? (attempt, self.playbackControlID) : nil
            } else if rawType == AVAudioSession.InterruptionType.ended.rawValue {
                let resume = self.mpvInterruptionResume
                self.mpvInterruptionResume = nil
                if AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume),
                   resume?.attempt == self.playbackAttemptID, resume?.control == self.playbackControlID,
                   !self.isPlaybackSuspendedForBackground, !self.hasTerminalPlaybackFailure {
                    self.toggleMPVPlayback()
                }
            }
        }
    }

    @objc private func handleMPVAudioRouteChange(_ notification: Notification) {
        guard (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
        let attempt = playbackAttemptID
        DispatchQueue.main.async { [weak self] in
            guard let self, self.playbackAttemptID == attempt, self.isUsingMPV else { return }
            self.mpvInterruptionResume = nil
            self.pausePlaybackSmoothly(reportReason: "pause")
        }
    }

    private func updateMPVVideoForApplicationState(isActive: Bool) {
        // PiP's offscreen output must keep decoding while UIKit is inactive,
        // including its first-frame/start transition. It never needs a Metal drawable.
        guard let mpvEngine, !mpvEngine.usesPixelBufferOutput else { return }
        let audioOnly = state.currentItem.map { resolvedPlaybackItemType(for: $0) == .audio } == true
        mpvEngine.set("vid", isActive && !audioOnly ? "auto" : "no")
    }

    @objc private func handleWillResignActive() {
        // Stop ordinary Metal output before UIKit moves the app to the background.
        updateMPVVideoForApplicationState(isActive: false)
        clearAllInteractiveVideoGestureActivity()
    }

    @objc private func handleDidEnterBackground() {
        updateMPVVideoForApplicationState(isActive: false)
        subtitleIntelligence.setBackground(true)
        guard state.status != .idle else { return }

        // Also preserve mpv's first-frame/start transition before AVKit reports active.
        let isStartingMPVPiP = !hasTerminalPlaybackFailure && state.status != .ended
            && mpvEngine?.usesPixelBufferOutput == true && videoPiPController?.isPreparingOrActive == true
        if isVideoPiPActive || isStartingMPVPiP {
            return
        }

        let backgroundAppSettingEnablesBackground = AppSettings.shared.shouldPlayInBackground
        if backgroundAppSettingEnablesBackground {
            // Background Playback keeps the current playback session alive, but
            // PiP must remain an explicit user action via the player control.
            return
        }

        invalidatePendingPlaybackControls()
        pendingActivationReconciliationWorkItem?.cancel()
        pendingActivationReconciliationWorkItem = nil
        pendingMetadataWorkItem?.cancel()
        pendingMetadataWorkItem = nil
        pictureInPictureSeekResumeGraceDeadline = .zero
        if hasTerminalPlaybackFailure || state.status == .ended {
            deactivateAudioSessionIfPossible(reason: "background", force: true)
            return
        }
        isPlaybackSuspendedForBackground = true
        cancelPendingPlaybackFailure()
        stopStartupWatchdog()
        pausePlaybackSmoothly(
            clearNowPlayingImmediately: true,
            deactivateAudioSessionAfterPause: true
        )
    }

    @objc private func handleDidBecomeActive() {
        subtitleIntelligence.setBackground(false)
        clearAllInteractiveVideoGestureActivity()
        if mpvEngine != nil { updateMPVVideoForApplicationState(isActive: true) }
        else {
            reattachPlayerViewIfNeeded()
            schedulePlaybackReconciliationAfterActivation()
        }
        if let restoreFile = pendingPictureInPictureRestoreFile {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                guard self.pendingPictureInPictureRestoreFile?.id == restoreFile.id else { return }
                self.requestedVideoPlayerRestoreFile = restoreFile
                print("[PiP] re-emitting restore request for \(restoreFile.name)")
            }
        }
    }

    private func schedulePlaybackReconciliationAfterActivation() {
        pendingActivationReconciliationWorkItem?.cancel()

        let attemptID = playbackAttemptID
        let controlID = playbackControlID
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.playbackAttemptID == attemptID, self.playbackControlID == controlID,
                  UIApplication.shared.applicationState == .active else { return }
            self.reconcilePlaybackStateAfterActivation()
        }
        pendingActivationReconciliationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    private func reconcilePlaybackStateAfterActivation() {
        defer {
            pendingActivationReconciliationWorkItem = nil
        }

        guard state.currentItem != nil, !isPreparingPlayback else { return }
        if isPlaybackSuspendedForBackground {
            if activePlaybackFailure == nil { state.status = .paused }
            return
        }
        guard state.status == .buffering else { return }
        guard !(mediaPlayer?.isPlaying ?? false) else { return }

        // VLC can stay in a stale buffering state after long background suspends.
        // Treat that as paused so the user can resume/recover instead of being locked out.
        state.status = .paused
        updateNowPlayingInfo()
        print("[VLC] normalized stale buffering state after app activation")
    }
    // MARK: - Public API

    func updateRemoteSkipAvailability(canPrevious: Bool, canNext: Bool) {
        canSkipToPreviousTrack = canPrevious
        canSkipToNextTrack = canNext

        let center = MPRemoteCommandCenter.shared()
        center.previousTrackCommand.isEnabled = canPrevious
        center.nextTrackCommand.isEnabled = canNext
    }

    func shouldReuseCurrentPlaybackSession(for file: VideoFile) -> Bool {
        let isRestoreTransitionActive = isRestoringPlayerFromPictureInPicture ||
            pendingPictureInPictureRestoreFile != nil ||
            requestedVideoPlayerRestoreFile != nil ||
            Date().timeIntervalSinceReferenceDate < suppressPlayerViewStopDuringPictureInPictureRestoreUntil
        guard isRestoreTransitionActive,
              let currentItem = state.currentItem else {
            return false
        }
        return playbackSessionMatches(file: file, mediaItem: currentItem)
    }

    func restoredPictureInPictureMediaItem(for file: VideoFile) -> MediaItem? {
        guard shouldReuseCurrentPlaybackSession(for: file),
              var currentItem = state.currentItem else {
            return nil
        }

        if currentItem.videoFile == nil {
            currentItem.videoFile = file
        }
        if currentItem.serverMediaStreams == nil {
            currentItem.serverMediaStreams = file.serverMediaStreams
        }
        if currentItem.serverContainer == nil {
            currentItem.serverContainer = file.serverContainer
        }
        if currentItem.serverSize == nil,
           let fileServerSize = file.serverSize,
           fileServerSize > 0 {
            currentItem.serverSize = fileServerSize
        }
        if currentItem.serverBitrate == nil {
            currentItem.serverBitrate = file.serverBitrate
        }
        if currentItem.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            currentItem.serverPath = file.serverPath
        }
        if currentItem.remotePlaybackMethod == nil {
            currentItem.remotePlaybackMethod = file.remotePlaybackMethod
        }
        if currentItem.externalSubtitleCandidates.isEmpty && !file.externalSubtitleCandidates.isEmpty {
            currentItem.externalSubtitleCandidates = file.externalSubtitleCandidates
        }
        if currentItem.preferredAudioTrackQuery == nil {
            currentItem.preferredAudioTrackQuery = file.preferredAudioTrackQuery
        }
        if currentItem.preferredSubtitleTrackQuery == nil {
            currentItem.preferredSubtitleTrackQuery = file.preferredSubtitleTrackQuery
        }
        if currentItem.preferredAudioTrackOrdinal == nil {
            currentItem.preferredAudioTrackOrdinal = file.preferredAudioTrackOrdinal
        }
        if currentItem.preferredSubtitleTrackOrdinal == nil {
            currentItem.preferredSubtitleTrackOrdinal = file.preferredSubtitleTrackOrdinal
        }
        if currentItem.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            currentItem.seriesId = file.seriesId
        }
        if currentItem.seasonId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
            currentItem.seasonId = file.seasonId
        }
        let resumeTime = preferredResumeTime()
        let resolvedResumeTime = resumeTime > 0 ? resumeTime : state.currentTime
        if resolvedResumeTime > 0 {
            currentItem.startPosition = resolvedResumeTime
            if currentItem.videoFile != nil {
                currentItem.videoFile?.lastPlayedPosition = resolvedResumeTime
            }
        }

        return currentItem
    }

    func shouldDeferAutoRotateForRestoredPlayer(file: VideoFile) -> Bool {
        guard Date().timeIntervalSinceReferenceDate < suppressPictureInPictureRestoreAutoRotateUntil else {
            return false
        }
        return shouldReuseCurrentPlaybackSession(for: file)
    }

    func hasPendingPictureInPictureRestoreRequest() -> Bool {
        isRestoringPlayerFromPictureInPicture ||
            pendingPictureInPictureRestoreFile != nil ||
            requestedVideoPlayerRestoreFile != nil
    }

    private func extendPlayerViewStopSuppressionForPictureInPictureRestore(by duration: TimeInterval) {
        let deadline = Date().timeIntervalSinceReferenceDate + duration
        suppressPlayerViewStopDuringPictureInPictureRestoreUntil = max(
            suppressPlayerViewStopDuringPictureInPictureRestoreUntil,
            deadline
        )
    }

    func shouldSuppressStopForPlayerViewDisappearDuringRestore() -> Bool {
        guard Date().timeIntervalSinceReferenceDate < suppressPlayerViewStopDuringPictureInPictureRestoreUntil else {
            return false
        }
        print("[PiP] suppressing PlayerView onDisappear stop during restore transition")
        return true
    }

    func markDeferredDrawablePlaybackSessionRestoreAfterPictureInPicture() {
        pendingDrawablePlaybackSessionRestoreAfterPictureInPicture = true
    }

    func restoreDeferredDrawablePlaybackSessionAfterPictureInPictureIfNeeded() -> Bool {
        guard pendingDrawablePlaybackSessionRestoreAfterPictureInPicture,
              let playerView,
              state.currentItem != nil else {
            return false
        }
        pendingDrawablePlaybackSessionRestoreAfterPictureInPicture = false
        reloadCurrentItemPreservingPlaybackState(
            in: playerView,
            bindToExistingPlayerView: true
        )
        print("[PiP] rebuilt VLC playback session for deferred drawable restore")
        return true
    }

    func clearDeferredDrawablePlaybackSessionRestoreAfterPictureInPicture() {
        pendingDrawablePlaybackSessionRestoreAfterPictureInPicture = false
    }

    func reattachRetainedPlayerViewForPictureInPictureRestoreIfNeeded(
        to containerView: UIView
    ) -> Bool {
        let isRestoreTransitionActive =
            pendingPictureInPictureRestoreFile != nil ||
            requestedVideoPlayerRestoreFile != nil ||
            Date().timeIntervalSinceReferenceDate < suppressPlayerViewStopDuringPictureInPictureRestoreUntil
        guard isRestoreTransitionActive,
              state.currentItem != nil else {
            return false
        }

        if let retainedPlayerView = playerView,
           retainedPlayerView !== containerView {
            if let previousSuperview = retainedPlayerView.superview {
                let relatedConstraints = previousSuperview.constraints.filter { constraint in
                    (constraint.firstItem as AnyObject?) === retainedPlayerView ||
                    (constraint.secondItem as AnyObject?) === retainedPlayerView
                }
                NSLayoutConstraint.deactivate(relatedConstraints)
            }
            retainedPlayerView.removeFromSuperview()
        }

        playerView = containerView
        containerView.layoutIfNeeded()

        if isUsingMPV {
            // The system may restore the view before didStopPiP. Wait for that
            // callback to rebuild GPU output; never create another offscreen session.
            if videoPiPController?.usesMPVFrameOutput == true {
                markDeferredDrawablePlaybackSessionRestoreAfterPictureInPicture()
            } else {
                clearDeferredDrawablePlaybackSessionRestoreAfterPictureInPicture()
            }
            return true
        }

        if restoreDeferredDrawablePlaybackSessionAfterPictureInPictureIfNeeded() {
            print("[PiP] rebound restored container view and triggered drawable restore")
        } else {
            // Plain drawable reassignment is flaky after repeated PiP cycles:
            // VLC may keep audio/time updates while the video output stays black.
            // Rebuild the current playback session to force a fresh drawable bind.
            reloadCurrentItemPreservingPlaybackState(
                in: containerView,
                bindToExistingPlayerView: true
            )
            print("[PiP] rebound restored container view and forced drawable rebuild")
        }
        return true
    }

    private func playbackSessionMatches(file: VideoFile, mediaItem: MediaItem) -> Bool {
        if file.url == mediaItem.url || file.url.absoluteString == mediaItem.url.absoluteString {
            return true
        }

        let fileItemID = file.jellyfinItemId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mediaItemID = mediaItem.jellyfinItemId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fileItemID.isEmpty, fileItemID == mediaItemID {
            return true
        }

        let filePath = file.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let mediaPath = mediaItem.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !filePath.isEmpty, filePath == mediaPath {
            return true
        }

        return false
    }

    func showFloatingAudio(file: VideoFile, playlist: [VideoFile]) {
        floatingAudioFile = file
        floatingAudioPlaylist = playlist
        isAudioFloatingVisible = true
    }

    func hideFloatingAudio() {
        isAudioFloatingVisible = false
        floatingAudioFile = nil
        floatingAudioPlaylist = []
    }

    func clearPlaybackFailure() {
        cancelPendingPlaybackFailure()
        stopStartupWatchdog()
        activePlaybackFailure = nil
    }

    /// Cancel the old engine immediately, including while a refreshed URL is being resolved.
    func prepareForPlaybackRetry() {
        invalidatePendingPlaybackControls()
        isPlaybackSuspendedForBackground = false
        deferredBackgroundPlayback = nil
        resetPlaybackStallDetection()
        playbackAttemptID = UUID()
        isPreparingPlayback = true
        hasTerminalPlaybackFailure = false
        clearPlaybackFailure()
        let player = mediaPlayer
        player?.delegate = nil
        player?.audio?.isMuted = true
        detachedPlayerTeardownQueue.async { player?.stop() }
        if let item = state.currentItem {
            state.status = .buffering
            startStartupWatchdog(for: item)
        }
    }

    func retryCurrentItem() {
        guard let item = state.currentItem else { return }
        clearPlaybackFailure()
        if recoverCurrentItemFromLastKnownPosition() {
            return
        }
        play(item: item, in: playerView)
    }

    private func reattachPlayerViewIfNeeded() {
        guard !isUsingMPV else { return }
        guard !isVideoPiPActive, let playerView = playerView,
              (mediaPlayer?.drawable as AnyObject?) !== playerView else { return }
        mediaPlayer?.drawable = playerView
    }

    private func tearDownDetachedPlayerAsync(
        _ player: VLCMediaPlayer?,
        clearDrawable: Bool = true,
        reason: String
    ) {
        guard let player else { return }
        player.delegate = nil
        if clearDrawable {
            player.drawable = nil
        }
        player.audio?.isMuted = true
        player.audio?.volume = 0

        detachedPlayerTeardownQueue.async {
            if player.isPlaying {
                player.pause()
            }
            player.stop()
            player.media = nil
            print("[VLC] tore down detached player (\(reason))")
        }
    }

    private func preferredResumeTime() -> Double {
        let playerTimeSeconds = logicalPlaybackTime(
            fromPlayerTime: Double((mediaPlayer?.time.intValue ?? 0)) / 1000.0,
            duration: state.duration
        )
        let isUsingAdvancingPlaybackClock =
            (mediaPlayer?.isPlaying ?? false) ||
            state.status == .playing ||
            state.status == .buffering
        let logicalResumeTime: Double
        if isUsingAdvancingPlaybackClock {
            logicalResumeTime = max(state.currentTime, playerTimeSeconds)
        } else if state.currentTime > 0 {
            logicalResumeTime = state.currentTime
        } else {
            logicalResumeTime = playerTimeSeconds
        }

        if state.duration > 0 {
            return min(max(logicalResumeTime, 0), state.duration)
        }

        return max(logicalResumeTime, 0)
    }

    private func shouldSeekToResumePosition(_ targetLogicalTime: Double) -> Bool {
        let playerLogicalTime = logicalPlaybackTime(
            fromPlayerTime: Double((mediaPlayer?.time.intValue ?? 0)) / 1000.0,
            duration: state.duration
        )
        let tolerance = state.currentItem?.isRemote == true ? 0.35 : 0.12
        return abs(playerLogicalTime - targetLogicalTime) > tolerance
    }

    private func shouldRecoverCurrentItemOnPlay() -> Bool {
        guard state.currentItem != nil else { return false }

        let vlcState = mediaPlayer?.state
        let duration = state.duration
        let nearEnd = duration > 0 && state.currentTime >= max(duration - 1.0, duration * 0.98)

        if state.status == .ended || vlcState == .ended || nearEnd {
            return false
        }

        if state.status == .error || vlcState == .error {
            return true
        }

        if vlcState == .stopped && state.status != .idle {
            return true
        }

        if mediaPlayer?.media == nil && state.status != .idle {
            return true
        }

        return false
    }

    @discardableResult
    private func recoverCurrentItemFromLastKnownPosition() -> Bool {
        guard var item = state.currentItem else { return false }

        let resumeTime = preferredResumeTime()
        let preservedDuration = state.duration

        // Override stale history and let the current in-memory timeline win for in-place recovery.
        item.startPosition = resumeTime > 1.0 ? resumeTime : 0
        item.savedAudioTrackIndex = isUsingMPV || state.currentAudioTrackID == -1 ? nil : state.currentAudioTrackID
        item.savedSubtitleTrackIndex = isUsingMPV || state.currentSubtitleTrackID == -1 ? nil : state.currentSubtitleTrackID

        play(item: item, in: playerView)

        if preservedDuration > 0 {
            state.duration = preservedDuration
            state.currentTime = resumeTime
            state.progress = Float(max(0.0, min(1.0, resumeTime / preservedDuration)))
        }

        return true
    }

    func play(
        item: MediaItem,
        in view: UIView? = nil,
        bindToExistingPlayerView: Bool = true,
        startPaused: Bool = false,
        engineTracks: [String: IOSPlaybackTrackSelection] = [:],
        secondaryHandoff: IOSPlaybackSecondarySelection? = nil,
        preserveSubtitleIntelligence: Bool = false,
        preparePlayer: ((VLCMediaPlayer) throws -> Void)? = nil
    ) {
        videoPiPController?.invalidateFrameOutputForPlaybackChange()
        let retainsIntelligence = preserveSubtitleIntelligence && state.currentItem?.id == item.id &&
            state.currentItem?.url == item.url && state.currentItem?.mediaSourceId == item.mediaSourceId
        if isUsingMPV { saveProgress() }
        if state.currentItem?.id != item.id { playbackEngineOverride = nil }
        invalidatePendingPlaybackControls()
        pendingActivationReconciliationWorkItem?.cancel()
        pendingActivationReconciliationWorkItem = nil
        isPlaybackSuspendedForBackground = false
        deferredBackgroundPlayback = nil
        pendingDrawablePlaybackSessionRestoreAfterPictureInPicture = false
        resetPlaybackStallDetection()
        playbackAttemptID = UUID()
        let attemptID = playbackAttemptID
        pendingEngineTracks = engineTracks
        pendingSecondaryHandoff = secondaryHandoff
        preservesDisabledAudio = engineTracks["audio"] == .off
        isPreparingPlayback = true
        hasTerminalPlaybackFailure = false
        // Silence and disconnect the previous attempt before preparing a replacement.
        mediaPlayer?.delegate = nil
        mediaPlayer?.audio?.isMuted = true
        clearPlaybackFailure()
        remoteSubtitleSelectionTask?.cancel()
        remoteSubtitleSelectionTask = nil
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        pendingPlayingWorkItem?.cancel()
        pendingPlayingWorkItem = nil
        pendingMetadataWorkItem?.cancel()
        pendingMetadataWorkItem = nil
        secondarySubtitleLoadTask?.cancel()
        secondarySubtitleLoadTask = nil
        secondarySubtitleTimeline = nil
        isStopInProgress = false

        stallWatchdogTimer?.invalidate()
        let watchdog = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.checkPlaybackStall()
        }
        RunLoop.main.add(watchdog, forMode: .common)
        stallWatchdogTimer = watchdog

        // Switching to another media item should flush current server progress and stop state first.
        if let currentItem = state.currentItem,
           currentItem.id != item.id,
           state.currentTime > 1.0 {
            saveProgress()
            reportServerProgress(force: true, reason: "switch_item")
            reportServerStopped()
        }

        mpvSidecarTasks.values.forEach { $0.cancel() }
        mpvSidecarTasks.removeAll()
        mpvEngine?.stop()
        mpvEngine = nil
        mpvReadAheadByteCache = nil
        subtitleIntelligence.setPlaybackReadAheadCache(nil)
        mpvState = nil
        bufferedRanges = []
        cacheInputBytesPerSecond = nil
        cacheReadIdle = true
        // Native IDs belong to one engine attempt, including same-item rebuilds.
        // Keep source URLs/names, but never classify new VLC IDs using old mpv IDs.
        externalSubtitleResolvedTrackIDs.removeAll()
        nativeASSBounds = nil
        nativeASSHasContent = false
        remoteMPVSubtitleLoader = IOSRemoteSubtitleLoader()
        mpvDecodedSecondary = MacMPVDecodedSubtitles(maximumTextBytes: 4 * 1024 * 1024)
        mpvDecodedSecondaryID = nil
        mpvSecondaryRendering = nil
        mpvSecondaryRenderingProperties = [:]
        mpvSubtitleSelectionRequest = nil
        mpvPauseRequested = startPaused
        isPreparingMPV = false

        // 1. Update UI state immediately to show buffering/loading
        if state.currentItem?.url != item.url {
            self.currentDecoder = resolvedDecoderPreference(AppSettings.shared.defaultVideoDecoder)
        }
        
        state.currentItem = item
        if retainsIntelligence { subtitleIntelligence.prepareForPlaybackRebuild() }
        else { bindSubtitleIntelligence(item) }
        startStartupWatchdog(for: item)
        seekPreviewWarmupTask?.cancel()
        seekPreviewWarmupTask = nil
        seekPreviewWarmupItemID = nil
        seekPreviewWarmupTimeBucket = nil
        seekPreviewWarmupMediaSourceID = nil
        remoteSeekPreviewFrameIntervalSeconds = nil
        if VideoFile.FileType.determineType(from: item.url) == .video {
            isAudioFloatingVisible = false
        }
        let targetMediaKey = mediaKey(for: item.url)
        if externalSubtitleMediaKey != nil, externalSubtitleMediaKey != targetMediaKey {
            externalSubtitleCandidates = []
            externalSubtitleMediaKey = nil
            externalSubtitleDisplayNames = [:]
            externalSubtitleResolvedTrackIDs = [:]
            lastExternalSubtitleReloadKey = nil
        }
        state.status = .buffering
        hasReportedServerPlaying = false
        isFetchingServerPlaybackContext = false
        shouldBypassPlaybackContextFetch = false
        playbackContextFetchFailureCount = 0
        lastPlaybackContextFetchFailureTime = 0
        
        // Reset stale progress from previous playback
        state.duration = 0
        state.currentTime = 0
        state.progress = 0
        activePlaybackTimelineOffset = 0
        state.audioTracks = []
        state.subtitleTracks = []
        state.secondarySubtitleTracks = []
        state.currentSecondarySubtitleTrackID = nil
        state.secondarySubtitleStatus = .disabled
        state.secondarySubtitleParts = []
        pendingSecondarySubtitleTrackQuery = nil
        pendingSecondarySubtitleTrackOrdinal = nil
        state.videoResolution = ""
        state.aspectRatio = ""
        state.videoDisplayMode = .fit
        state.interactiveVideoZoomScale = 1.0
        state.interactiveVideoOffset = .zero
        clearAllInteractiveVideoGestureActivity()
        
        // Reset internal throttle timers
        lastUIUpdateTime = 0
        lastTracksRefreshTime = 0
        lastSavedTime = 0
        lastJellyfinSyncTime = 0
        lastNowPlayingRefreshTime = 0
        initialSeekPerformed = false
        isMenuPresented = false
        deferredTrackRefreshNeeded = false
        hasResolvedAutomaticSubtitleSelection = false
        hasStartedPlaybackForCurrentItem = false
        hasFittedMacWindowForCurrentItem = false
        hasResetReplayProgressLocallyForCurrentItem = false
        if shouldUsePlaybackTimelineOffset(for: item) {
            activePlaybackTimelineOffset = max(item.startPosition ?? 0, 0)
        }

        let seededDuration = resolvedPlaybackDuration(for: item)
        if seededDuration > 0.5 {
            state.duration = seededDuration
        }
        if let startPosition = item.startPosition, startPosition > 0 {
            let seededCurrentTime = state.duration > 0
                ? min(max(startPosition, 0), state.duration)
                : startPosition
            state.currentTime = seededCurrentTime
            state.progress = resolvedPlaybackProgress(
                currentTime: seededCurrentTime,
                duration: state.duration,
                fallbackPosition: 0
            )
            if startPosition > 1.0 {
                pendingPlaybackResumeTimeGuard = seededCurrentTime
                pendingPlaybackResumeTimeGuardDeadline = Date().timeIntervalSinceReferenceDate + 3.5
            }
        }
        prewarmSeekPreviewIfNeeded(for: item, targetTime: state.currentTime)
        
        let selectedEngine = PlaybackEngineAvailability.current.resolve(
            preferred: playbackEngineOverride ?? UserDefaults.standard.string(forKey: "iosPlaybackEngine"),
            supportsMPV: MPVUIKitPlaybackPolicy.supports(url: item.url,
                isVideo: resolvedPlaybackItemType(for: item) == .video,
                isAudio: resolvedPlaybackItemType(for: item) == .audio,
                requiresVLCBridge: preparePlayer != nil))
        guard let selectedEngine else {
            handlePlaybackFailureIfNeeded(for: item, customMessage: PlaybackEngineAvailability.unavailableMessage)
            return
        }
        if selectedEngine == .mpv {
            prepareMPV(item: item, attemptID: attemptID)
            return
        }

        // 2. Perform heavy setup on background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            // Create new player instance (Heavy operation)
            guard let newPlayer = VLCPlaybackTransport.makePlayer() else { return }
            self.configureTextRenderer(for: newPlayer)
            let runtimePlaybackURL = RuntimeNetworkAddressResolver.runtimeURL(from: item.url)
            
            // Configure Media
            let media = self.makeConfiguredMedia(for: item, runtimePlaybackURL: runtimePlaybackURL)
            // Let VLC pause the input before output starts, regardless of how long
            // remote preparation takes. A delayed pause can run before this player exists.
            if startPaused { media.addOption(":start-paused") }
            
            // Prepare restore state
            // Priority: Explicit item.startPosition (even 0.0) > History > nil
            
            // Determine type for history check
            let type = VideoFile.FileType.determineType(from: item.url)
            let historyEnabled = (type == .video && AppSettings.shared.enableVideoHistory) ||
                                 (type == .audio && AppSettings.shared.enableAudioHistory)
            
            let historyPos = historyEnabled ? (self.historyService.getLastPlayedPosition(for: item) ?? self.historyService.getLastPlayedPosition(for: item.url)) : nil
            let startPos = item.startPosition ?? historyPos
            
            // Prepare Track Restoration
            let savedTracks = self.historyService.getLastTrackSelection(for: item) ?? self.historyService.getLastTrackSelection(for: item.url)
            let seriesTracks = self.seriesTrackPreference(for: item)
            let storedTrackPreference = self.storedTrackQueryPreference(for: item)
            let savedAudio = item.savedAudioTrackIndex ?? savedTracks?.audio ?? seriesTracks?.audio
            let savedSubtitle = item.savedSubtitleTrackIndex ?? savedTracks?.subtitle ?? seriesTracks?.subtitle
            let preferredAudioQuery = item.preferredAudioTrackQuery ?? storedTrackPreference.audioQuery
            let preferredSubtitleQuery = item.preferredSubtitleTrackQuery ?? storedTrackPreference.subtitleQuery
            let preferredSecondarySubtitle = self.storedSecondarySubtitlePreference(for: item)
            let shouldDisableSubtitles = item.savedSubtitleTrackIndex == -1 ||
                (item.preferredSubtitleTrackQuery == nil && storedTrackPreference.subtitlesDisabled == true)
            
            DispatchQueue.main.async {
                // Verify we still want to play this item
                guard self.state.currentItem?.id == item.id,
                      self.playbackAttemptID == attemptID, !self.isStopInProgress,
                      !self.hasTerminalPlaybackFailure else {
                    newPlayer.delegate = nil
                    return
                }

                let retryPreparation: (Bool) -> Void = { [weak self, weak view] paused in
                    self?.play(item: item, in: view, bindToExistingPlayerView: bindToExistingPlayerView,
                               startPaused: paused,
                               engineTracks: engineTracks,
                               secondaryHandoff: secondaryHandoff, preserveSubtitleIntelligence: retainsIntelligence,
                               preparePlayer: preparePlayer)
                }
                // Deferred preparation is invoked by an explicit Play request;
                // an internal preparation retry must instead preserve the original intent.
                let resumePreparation = { retryPreparation(false) }
                if self.deferPreparedPlaybackForBackground(retry: resumePreparation) { return }
                let controlID = self.playbackControlID
                self.audioSessionCoordinator.activate { [weak self] audioReady in
                    guard let self, self.playbackAttemptID == attemptID,
                          self.state.currentItem?.id == item.id, !self.isStopInProgress,
                          !self.hasTerminalPlaybackFailure else { return }
                    if self.deferPreparedPlaybackForBackground(retry: resumePreparation) { return }
                    guard self.playbackControlID == controlID else {
                        // Background deactivation may have been queued after this
                        // activation. A new preparation activates after it in order.
                        retryPreparation(startPaused)
                        return
                    }
                    guard audioReady else {
                        self.isPreparingPlayback = false
                        self.state.status = .paused
                        self.stopStartupWatchdog()
                        self.deferredBackgroundPlayback = resumePreparation
                        return
                    }
                    self.finishAudioSessionActivation()

                    let previousPlayer = self.mediaPlayer
                
                    if #available(iOS 15.0, *) {
                        self.videoPiPController?.forceDetachFrameBridge()
                    }
                
                    // Swap player
                    self.mediaPlayer = newPlayer
                    self.setAspectRatio(self.state.aspectRatio)
                    newPlayer.delegate = self
                    self.isPreparingPlayback = false
                    self.tearDownDetachedPlayerAsync(previousPlayer, reason: "replace")

                    do {
                        try preparePlayer?(newPlayer)
                    } catch {
                        print("[VLC] Failed to prepare player before playback: \(error.localizedDescription)")
                        self.handlePlaybackFailureIfNeeded(for: item, customMessage: error.localizedDescription)
                        return
                    }
                
                    // Bind View
                    if #available(iOS 15.0, *),
                       self.videoPiPController?.isActiveSession == true {
                        self.mediaPlayer?.drawable = nil
                        self.videoPiPController?.attachFrameBridge(to: newPlayer)
                    } else {
                        let resolvedView = view ?? (bindToExistingPlayerView ? self.playerView : nil)
                        if let v = resolvedView {
                            self.playerView = v
                            self.mediaPlayer?.drawable = v
                        }
                    }
                
                    // Use :start-time for initial seek (avoids programmatic seek that triggers VLC .ended bug)
                    let initialPlayerStartTime = self.playerLocalTime(fromLogicalTime: startPos ?? 0)
                    if initialPlayerStartTime > 1.0 {
                        media.addOption(":start-time=\(Int(initialPlayerStartTime))")
                        self.state.currentTime = startPos ?? 0
                        self.initialSeekPerformed = true
                    }
                    self.pendingSeekPosition = nil
                    self.pendingAudioTrack = savedAudio
                    self.pendingSubtitleTrack = shouldDisableSubtitles ? -1 : savedSubtitle
                    self.pendingAudioTrackQuery = savedAudio == nil ? preferredAudioQuery : nil
                    self.pendingSubtitleTrackQuery = shouldDisableSubtitles ? nil : preferredSubtitleQuery
                    self.pendingAudioTrackOrdinal = savedAudio == nil ? item.preferredAudioTrackOrdinal : nil
                    self.pendingSubtitleTrackOrdinal = shouldDisableSubtitles ? nil : item.preferredSubtitleTrackOrdinal
                    self.pendingSecondarySubtitleTrackQuery = preferredSecondarySubtitle.query
                    self.pendingSecondarySubtitleTrackOrdinal = preferredSecondarySubtitle.ordinal
                    if engineTracks["audio"] != nil {
                        self.pendingAudioTrack = nil
                        self.pendingAudioTrackQuery = nil
                        self.pendingAudioTrackOrdinal = nil
                    }
                    if engineTracks["sub"] != nil {
                        self.pendingSubtitleTrack = nil
                        self.pendingSubtitleTrackQuery = nil
                        self.pendingSubtitleTrackOrdinal = nil
                        self.hasResolvedAutomaticSubtitleSelection = true
                    }
                
                    // Set media on player
                    let fileType = VideoFile.FileType.determineType(from: item.url)
                    newPlayer.media = media
                    // Kick metadata extraction before playback enters `.playing`,
                    // so opening Media Info immediately has a higher chance to show tags.
                    if fileType == .audio {
                        self.extractMetadata()
                    }
                
                    print("[VLC] Play \(item.title). Starting at: \(String(describing: startPos)). URL: \(item.url.absoluteString)")
                
                    // Start Playback
                    if startPaused { self.state.status = .paused }
                    self.mediaPlayer?.play()
                    if !engineTracks.isEmpty {
                        self.refreshEngineTracksAfterOpening(attemptID: attemptID)
                    }
                
                    // Apply Default Speed
                    let defaultSpeed = self.resolvedPlaybackItemType(for: item) == .audio
                        ? Float(AppSettings.shared.defaultAudioPlaybackSpeed)
                        : Float(AppSettings.shared.defaultPlaybackSpeed)
                
                    let targetSpeed = MPVPlaybackSpeed.clamped(self.sessionPlaybackRate ?? defaultSpeed, maximum: 4)
                    self.mediaPlayer?.rate = targetSpeed
                    self.state.rate = targetSpeed
                
                    // Restore Audio State
                    self.mediaPlayer?.audio?.volume = 100
                    self.mediaPlayer?.audio?.isMuted = self.isMuted
                
                    // Re-register remote commands (cleared on stop) and update Now Playing
                    self.setupRemoteCommands()
                    self.updateNowPlayingInfo()
                
                    // Async-fetch full MediaInfo from server if Jellyfin/Emby
                    self.fetchServerMediaInfo()
                }
            }
        }
    }

    private func seriesTrackPreference(for item: MediaItem) -> (audio: Int?, subtitle: Int?)? {
        guard let provider = item.serverType?.rawValue,
              let serverId = item.jellyfinServerId,
              let seriesId = item.seriesId,
              !seriesId.isEmpty else {
            return nil
        }

        return AppSettings.shared.seriesTrackPreference(
            provider: provider,
            serverId: serverId,
            seriesId: seriesId
        )
    }

    private func storedSecondarySubtitlePreference(for item: MediaItem) -> (query: String?, ordinal: Int?) {
        if let provider = item.serverType?.rawValue,
           let serverId = item.jellyfinServerId,
           let scopeKey = secondarySubtitlePreferenceScopeKey(for: item) {
            let preference = AppSettings.shared.secondarySubtitlePreference(
                provider: provider,
                serverId: serverId,
                scopeKey: scopeKey
            )
            if preference.query != nil || preference.ordinal != nil {
                return preference
            }
        }

        guard let key = mediaKey(for: item.url) else {
            return (nil, nil)
        }
        return AppSettings.shared.secondarySubtitlePreference(mediaKey: key)
    }

    private func saveStoredSecondarySubtitlePreference(for item: MediaItem, track: EmbeddedSubtitleTrack?) {
        let query = track.map { secondarySubtitleDisplayName(for: $0) }
        let ordinal = track.flatMap { selectedSecondarySubtitleOrdinal(for: $0) }

        if let provider = item.serverType?.rawValue,
           let serverId = item.jellyfinServerId,
           let scopeKey = secondarySubtitlePreferenceScopeKey(for: item) {
            AppSettings.shared.saveSecondarySubtitlePreference(
                provider: provider,
                serverId: serverId,
                scopeKey: scopeKey,
                query: query,
                ordinal: ordinal
            )
            return
        }

        if let key = mediaKey(for: item.url) {
            AppSettings.shared.saveSecondarySubtitlePreference(
                mediaKey: key,
                query: query,
                ordinal: ordinal
            )
        }
    }

    private func secondarySubtitlePreferenceScopeKey(for item: MediaItem) -> String? {
        if let seriesId = item.seriesId, !seriesId.isEmpty {
            return "series.\(seriesId)"
        }
        if let itemId = item.jellyfinItemId, !itemId.isEmpty {
            return "item.\(itemId)"
        }
        return nil
    }

    private func selectedSecondarySubtitleOrdinal(for track: EmbeddedSubtitleTrack) -> Int? {
        let selectableTracks = state.secondarySubtitleTracks.filter { $0.isSelectable }
        return selectableTracks.firstIndex(where: { $0.id == track.id })
    }
    
    /// Fetch complete MediaStreams from Jellyfin/Emby server
    /// Extracts server URL and api_key directly from the stream URL (most reliable approach)
    private func fetchServerMediaInfo() {
        guard let item = state.currentItem,
              let itemId = item.jellyfinItemId else {
            return // Not a server item
        }
        
        // Skip if already has data
        if let existing = item.serverMediaStreams, !existing.isEmpty {
            return
        }
        
        // Extract base URL and api_key from the stream URL
        // Stream URLs look like: http://host:8096/Videos/{id}/stream?Static=true&api_key=TOKEN
        let streamUrl = item.url
        guard let components = URLComponents(url: streamUrl, resolvingAgainstBaseURL: false),
              let host = streamUrl.host,
              let scheme = streamUrl.scheme else {
            print("[MediaInfo] Skip: cannot parse stream URL")
            return
        }
        
        // Extract api_key from query parameters
        let apiKey = components.queryItems?.first(where: { $0.name == "api_key" })?.value
        guard let token = apiKey, !token.isEmpty else {
            print("[MediaInfo] Skip: no api_key in stream URL")
            return
        }
        
        // Build base URL from stream URL (scheme://host:port)
        let port = streamUrl.port.map { ":\($0)" } ?? ""
        let baseURL = "\(scheme)://\(host)\(port)"
        
        // Find userId - try from server config or use /Users/Me
        let serverId = item.jellyfinServerId
        let allServers = AppNetworkService.shared.servers
        
        // First try: find matching server by URL host
        let matchingServer = allServers.first(where: { server in
            (server.type == .jellyfin || server.type == .emby) &&
            server.fullURL.contains(host)
        })
        
        // Second try: find by UUID (might have nil token but could have userId)
        let uuidServer = serverId.flatMap { sid in
            allServers.first(where: { $0.id.uuidString == sid })
        }
        
        let userId = matchingServer?.userId ?? uuidServer?.userId
        
        print("[MediaInfo] Fetching from \(baseURL), itemId=\(itemId), userId=\(userId ?? "nil"), hasToken=true")
        
        fetchServerMediaInfoDirect(baseURL: baseURL, itemId: itemId, token: token, userId: userId, originalItemId: item.id)
    }

    private func presentPlaybackFailure(message: String, for item: MediaItem) {
        activePlaybackFailure = PlaybackFailure(itemID: item.id, message: message)
    }

    func handlePlaybackFailureIfNeeded(for item: MediaItem?, customMessage: String? = nil) {
        guard let item, !hasTerminalPlaybackFailure else { return }
        invalidatePendingPlaybackControls()
        deferredBackgroundPlayback = nil
        cancelPendingPlaybackFailure()
        stopStartupWatchdog()
        hasTerminalPlaybackFailure = true
        videoPiPController?.cancelPendingStartForPlaybackFailure()
        secondarySubtitleLoadTask?.cancel()
        secondarySubtitleLoadTask = nil
        mpvSidecarTasks.values.forEach { $0.cancel() }
        mpvSidecarTasks.removeAll()
        isPreparingMPV = false
        state.status = .error
        mpvEngine?.stop()
        // A terminal failure must not keep playing behind its retry alert.
        mediaPlayer?.delegate = nil
        let failedPlayer = mediaPlayer
        failedPlayer?.audio?.isMuted = true
        detachedPlayerTeardownQueue.async { failedPlayer?.stop() }

        let message: String
        if let customMessage, !customMessage.isEmpty {
            message = customMessage
        } else if item.isRemote {
            message = NSLocalizedString(
                "Playback failed. Please check the server and network connection, then try again.",
                comment: ""
            )
        } else {
            message = NSLocalizedString(
                "Playback failed. This file may be unavailable or unsupported.",
                comment: ""
            )
        }

        presentPlaybackFailure(message: message, for: item)
    }
    
    /// Fetch item details directly using base URL and api_key
    private func fetchServerMediaInfoDirect(baseURL: String, itemId: String, token: String, userId: String?, originalItemId: UUID) {
        let requestedSourceID = state.currentItem.flatMap { item in
            item.id == originalItemId ? (item.mediaSourceId ?? embeddedSubtitleMediaSourceID(from: item.url)) : nil
        }
        Task {
            do {
                // Build URL: prefer /Users/{userId}/Items/{id} if userId available, else /Items/{id}
                let urlString: String
                if let uid = userId {
                    urlString = "\(baseURL)/Users/\(uid)/Items/\(itemId)?Fields=MediaSources&api_key=\(token)"
                } else {
                    urlString = "\(baseURL)/Items/\(itemId)?Fields=MediaSources&api_key=\(token)"
                }
                
                guard let url = URL(string: urlString) else {
                    print("[MediaInfo] ❌ Invalid URL: \(urlString)")
                    return
                }
                
                let request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
                let (data, response) = try await URLSession.shared.data(for: request)
                
                if let httpResponse = response as? HTTPURLResponse {
                    print("[MediaInfo] GET Items response: \(httpResponse.statusCode), bytes: \(data.count)")
                    if httpResponse.statusCode == 401, userId != nil {
                        print("[MediaInfo] User-scoped fetch unauthorized, retrying without userId")
                        self.fetchServerMediaInfoDirect(
                            baseURL: baseURL,
                            itemId: itemId,
                            token: token,
                            userId: nil,
                            originalItemId: originalItemId
                        )
                        return
                    }
                    if httpResponse.statusCode != 200 {
                        if let body = String(data: data, encoding: .utf8), !body.isEmpty {
                            print("[MediaInfo] Response body: \(body.prefix(200))")
                        }
                        return
                    }
                }
                
                // Parse the JSON response manually to extract MediaSources → MediaStreams
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    print("[MediaInfo] ❌ Response is not a JSON object")
                    return
                }
                
                var streams: [[String: Any]] = []
                var container: String?
                var size: Int64?
                var bitrate: Int?
                var path: String?
                var resolvedSourceID: String?
                
                // Try MediaSources first (has the most complete data)
                if let mediaSources = json["MediaSources"] as? [[String: Any]],
                   let source = requestedSourceID.flatMap({ id in mediaSources.first { $0["Id"] as? String == id } })
                    ?? (requestedSourceID == nil && mediaSources.count == 1 ? mediaSources.first : nil) {
                    resolvedSourceID = source["Id"] as? String
                    if let ms = source["MediaStreams"] as? [[String: Any]] {
                        streams = ms
                    }
                    container = source["Container"] as? String
                    if let s = source["Size"] as? Int64 {
                        size = s
                    } else if let s = source["Size"] as? Int {
                        size = Int64(s)
                    }
                    bitrate = source["Bitrate"] as? Int
                    path = source["Path"] as? String
                    print("[MediaInfo] From MediaSources: container=\(container ?? "nil"), streams=\(streams.count), size=\(size ?? 0)")
                }
                
                // Fallback: try top-level MediaStreams (some API versions put it here)
                if streams.isEmpty,
                   (resolvedSourceID != nil && (json["MediaSources"] as? [[String: Any]])?.count == 1)
                    || (requestedSourceID == nil && (json["MediaSources"] as? [[String: Any]] ?? []).isEmpty),
                   let topStreams = json["MediaStreams"] as? [[String: Any]] {
                    streams = topStreams
                    container = json["Container"] as? String
                    print("[MediaInfo] From top-level MediaStreams: \(streams.count) streams")
                }
                
                if !streams.isEmpty {
                    await MainActor.run {
                        guard self.state.currentItem?.id == originalItemId else { return }
                        
                        var updatedItem = self.state.currentItem!
                        updatedItem.serverMediaStreams = streams
                        self.audioSubtitleMetadata = (originalItemId, data)
                        if let c = container { updatedItem.serverContainer = c }
                        if let s = size { updatedItem.serverSize = s }
                        if let b = bitrate { updatedItem.serverBitrate = b }
                        if let p = path { updatedItem.serverPath = p }
                        self.state.currentItem = updatedItem
                        if self.isUsingMPV {
                            self.reconcileMPVSubtitleSources()
                            self.resolveMPVPendingExternalSubtitle()
                            self.refreshSecondarySubtitleTracks()
                        }
                        print("[MediaInfo] ✅ Updated state with \(streams.count) media streams")
                    }
                } else {
                    print("[MediaInfo] ⚠️ No MediaStreams found. Available keys: \(json.keys.sorted())")
                }
            } catch {
                print("[MediaInfo] ❌ Failed to fetch server media info: \(error)")
            }
        }
    }
    
    func pause() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.pause() }
            return
        }
        if isUsingMPV || isPreparingMPV || (mediaPlayer?.isPlaying ?? false) {
            pausePlaybackSmoothly(reportReason: "pause")
        }
    }
    
    func togglePlayPause() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.togglePlayPause() }
            return
        }
        guard pendingResumeControlID == nil else { return }
        pendingActivationReconciliationWorkItem?.cancel()
        pendingActivationReconciliationWorkItem = nil
        isPlaybackSuspendedForBackground = false
        if let deferredPlayback = deferredBackgroundPlayback {
            deferredBackgroundPlayback = nil
            deferredPlayback()
            return
        }
        if isPreparingPlayback {
            if isPreparingMPV { pausePlaybackSmoothly(reportReason: "pause"); return }
            state.status = .buffering
            return
        }
        if isUsingMPV { toggleMPVPlayback(); return }
        print("[VLC-DEBUG] togglePlayPause: isPlaying=\((mediaPlayer?.isPlaying ?? false)) vlcState=\((mediaPlayer?.state.rawValue ?? 0)) stateStatus=\(state.status) mediaSet=\(mediaPlayer?.media != nil)")
        if (mediaPlayer?.isPlaying ?? false) {
            pausePlaybackSmoothly(reportReason: "pause")
        } else {
            reattachPlayerViewIfNeeded()

            // If VLC dropped its internal pipeline while the player UI is still onscreen,
            // rebuild the current item from the latest in-memory position instead of replaying
            // against a dead instance.
            if shouldRecoverCurrentItemOnPlay() {
                if recoverCurrentItemFromLastKnownPosition() {
                    return
                }
            }

            // VLC cannot reliably resume from ended/stopped when resources have been released.
            // In that case we rebuild the current media item and restart from the beginning.
            if shouldRestartFromBeginningOnPlay() {
                if restartCurrentItemFromBeginning() {
                    return
                }
            }

            invalidatePendingPlaybackControls()
            let controlID = playbackControlID
            let attemptID = playbackAttemptID
            let player = mediaPlayer
            pendingResumeControlID = controlID
            audioSessionCoordinator.activate { [weak self, weak player] success in
                guard let self, let player, self.mediaPlayer === player,
                      self.isCurrentPlaybackControl(attemptID: attemptID, controlID: controlID) else { return }
                self.pendingResumeControlID = nil
                guard success else {
                    self.state.status = .paused
                    print("[AudioSession] resume activation failed")
                    return
                }
                self.finishAudioSessionActivation()
                self.resumeCurrentPlayerAfterAudioActivation()
            }
        }
    }

    private func resumeCurrentPlayerAfterAudioActivation() {
        resetPlaybackStallDetection()
        // Resume should honor the latest logical playback position (e.g. seek while paused from lock screen).
        let clampedResumeTime = preferredResumeTime()
        let shouldSeekOnResume = shouldSeekToResumePosition(clampedResumeTime)
        let resumeLocalTime = playerLocalTime(fromLogicalTime: clampedResumeTime)
        let resumeTick = Int32(resumeLocalTime * 1000)
        print("[VLC-DEBUG] togglePlayPause RESUME: playerTime=\((mediaPlayer?.time.intValue ?? 0))ms stateCurrentTime=\(state.currentTime) logicalTarget=\(clampedResumeTime)s localTarget=\(resumeLocalTime)s shouldSeek=\(shouldSeekOnResume)")

        // Resume playback first, then restore audio state, mirroring the
        // instant-effect pattern used by toggleMute / nudgePlaybackForImmediateTrackChange.
        // Calling play() with audio already restored can cause VLC to
        // reinitialize its audio output chain, producing a brief gap.
        mediaPlayer?.play()
        mediaPlayer?.audio?.volume = 100
        mediaPlayer?.audio?.isMuted = isMuted

        if shouldSeekOnResume {
            // Avoid forcing a no-op seek on resume. For remote playback that can
            // flush buffered data and briefly bounce the UI back to loading.
            mediaPlayer?.time = VLCTime(int: resumeTick)
        } else {
            // Nudge the pipeline so audio renders immediately, same trick
            // used by subtitle/speed/audio-track changes.
            if let player = mediaPlayer { player.time = player.time }
        }
        state.currentTime = clampedResumeTime
        if state.duration > 0 {
            state.progress = Float(clampedResumeTime / state.duration)
        }
        state.status = .playing
        reportServerProgress(force: true, reason: "resume")
        updateNowPlayingInfo()
    }

    private func shouldRestartFromBeginningOnPlay() -> Bool {
        guard state.currentItem != nil else { return false }

        let vlcState = mediaPlayer?.state
        let duration = state.duration
        let nearEnd = duration > 0 && state.currentTime >= max(duration - 1.0, duration * 0.98)

        if state.status == .ended || vlcState == .ended {
            return true
        }

        if mediaPlayer?.media == nil {
            return state.status != .paused
        }

        if vlcState == .stopped && (nearEnd || state.status == .idle) {
            return true
        }

        if nearEnd && !(mediaPlayer?.isPlaying ?? false) && state.status != .paused {
            return true
        }

        return false
    }

    @discardableResult
    func restartCurrentItemFromBeginning() -> Bool {
        guard var item = state.currentItem else { return false }
        item.startPosition = 0
        if item.serverType == .jellyfin || item.serverType == .emby || item.serverType == .plex {
            item.shouldResetRemotePlayedStateOnPlaybackStart = true
        }
        if var videoFile = item.videoFile {
            videoFile.lastPlayedPosition = 0
            videoFile.shouldResetRemotePlayedStateOnPlaybackStart = item.shouldResetRemotePlayedStateOnPlaybackStart
            item.videoFile = videoFile
        }
        play(item: item, in: playerView)
        return true
    }

    @objc private func checkPlaybackStall() {
        guard let item = state.currentItem, !isStopInProgress,
              activePlaybackFailure == nil, !hasTerminalPlaybackFailure else { return }
        if hasStartedPlaybackForCurrentItem, !isPreparingPlayback,
           state.status == .playing || state.status == .buffering,
           isUsingMPV || (mediaPlayer?.isPlaying ?? false) || mediaPlayer?.state == .playing || mediaPlayer?.state == .buffering || mediaPlayer?.state == .opening {
            // Poll the engine itself: delayed/coalesced callbacks are not a playback stall.
            // VLC's cached state can remain ESAdded while the engine is still playing.
            let isStalled = shouldShowPlaybackBuffering()
            if isStalled, state.status != .buffering {
                state.status = .buffering
            } else if !isStalled, state.status == .buffering {
                state.status = .playing
                clearPlaybackFailure()
            }
        } else if state.status == .paused {
            resetPlaybackStallDetection()
        }
        guard state.status == .buffering else {
            stopStartupWatchdog()
            return
        }
        if loadingMonitor == nil { startStartupWatchdog(for: item) }
        let phase = loadingMonitor?.update(
            now: ProcessInfo.processInfo.systemUptime,
            progressValue: loadingProgressValue
        ) ?? .loading
        if loadingPhase != phase { loadingPhase = phase }
    }

    func stop(clearRenderer: Bool = true) {
        let hasActivePlayback = isUsingMPV || mediaPlayer?.media != nil ||
            (mediaPlayer?.isPlaying ?? false) ||
            state.status != .idle ||
            playerView != nil ||
            state.currentItem != nil
        guard hasActivePlayback, !isStopInProgress else { return }
        showSubtitleBrowser = false
        subtitleIntelligence.reset()

        invalidatePendingPlaybackControls()
        pendingActivationReconciliationWorkItem?.cancel()
        pendingActivationReconciliationWorkItem = nil
        isPlaybackSuspendedForBackground = false
        deferredBackgroundPlayback = nil
        resetPlaybackStallDetection()
        playbackAttemptID = UUID()
        isPreparingPlayback = false
        pendingEngineTracks = [:]
        pendingSecondaryHandoff = nil
        isStopInProgress = true
        pendingDrawablePlaybackSessionRestoreAfterPictureInPicture = false
        suppressPlayerViewStopDuringPictureInPictureRestoreUntil = .zero
        if clearRenderer {
            stopPictureInPicture()
        }
        clearPlaybackFailure()
        pendingPlayingWorkItem?.cancel()
        pendingPlayingWorkItem = nil
        pendingMetadataWorkItem?.cancel()
        pendingMetadataWorkItem = nil
        remoteSubtitleSelectionTask?.cancel()
        remoteSubtitleSelectionTask = nil
        externalSubtitleResolvedTrackIDs = [:]
        lastExternalSubtitleReloadKey = nil

        stallWatchdogTimer?.invalidate()
        stallWatchdogTimer = nil

        let itemForRefresh = state.currentItem

        // Save progress before stopping
        if state.currentTime > 1.0 || hasReportedServerPlaying {
             saveProgress()
             reportServerProgress(force: true, reason: "stop")
             reportServerStopped()
             if let itemForRefresh {
                 let resolvedDuration = state.duration > 0
                    ? state.duration
                    : (itemForRefresh.videoFile?.duration ?? 0)
                 PlaybackRefreshCenter.recordPlaybackStop(
                    for: itemForRefresh,
                    currentTime: state.currentTime,
                    duration: resolvedDuration
                 )
             }
        }

        mpvSidecarTasks.values.forEach { $0.cancel() }
        mpvSidecarTasks.removeAll()
        mpvEngine?.stop()
        mpvEngine = nil
        mpvReadAheadByteCache = nil
        subtitleIntelligence.setPlaybackReadAheadCache(nil)
        mpvState = nil
        bufferedRanges = []
        cacheInputBytesPerSecond = nil
        cacheReadIdle = true
        // Native IDs belong to one engine attempt, including same-item rebuilds.
        // Keep source URLs/names, but never classify new VLC IDs using old mpv IDs.
        externalSubtitleResolvedTrackIDs.removeAll()
        nativeASSBounds = nil
        nativeASSHasContent = false
        remoteMPVSubtitleLoader = IOSRemoteSubtitleLoader()
        mpvDecodedSecondary = MacMPVDecodedSubtitles(maximumTextBytes: 4 * 1024 * 1024)
        mpvDecodedSecondaryID = nil
        mpvSecondaryRendering = nil
        mpvSecondaryRenderingProperties = [:]
        mpvSubtitleSelectionRequest = nil
        isPreparingMPV = false
        let playerToStop = mediaPlayer
        playerToStop?.audio?.isMuted = true
        playerToStop?.audio?.volume = 0
        state.currentItem = nil
        showControlOverlay = false

        var stopWorkItem: DispatchWorkItem?
        stopWorkItem = DispatchWorkItem { [weak self, weak playerToStop] in
            guard let self = self else { return }
            defer {
                if let stopWorkItem = stopWorkItem, self.pendingStopWorkItem === stopWorkItem {
                    self.pendingStopWorkItem = nil
                }
                self.isStopInProgress = false
            }

            guard let workItem = stopWorkItem, !workItem.isCancelled else {
                return
            }

            // Pause first so the audio unit drains before the final stop, reducing close-time pops.
            if playerToStop?.isPlaying == true {
                playerToStop?.pause()
            }
            playerToStop?.stop()

            let shouldResetSharedState = self.mediaPlayer === playerToStop
            guard shouldResetSharedState else { return }

            // Reset session sticky settings
            self.sessionPlaybackRate = nil

            self.mediaPlayer?.media = nil // Explicitly release media to cancel loading

            if clearRenderer {
                self.mediaPlayer?.drawable = nil
                self.playerView = nil
            }

            self.state.status = .idle
            self.state.duration = 0
            self.state.currentTime = 0
            self.state.progress = 0
            self.activePlaybackTimelineOffset = 0
            self.state.audioTracks = []
            self.state.subtitleTracks = []
            self.state.currentAudioTrackID = -1
            self.state.currentSubtitleTrackID = -1
            self.state.secondarySubtitleTracks = []
            self.state.currentSecondarySubtitleTrackID = nil
            self.state.secondarySubtitleStatus = .disabled
            self.state.secondarySubtitleParts = []
            self.secondarySubtitleTimeline = nil
            self.secondarySubtitleLoadTask?.cancel()
            self.secondarySubtitleLoadTask = nil
            self.pendingSecondarySubtitleTrackQuery = nil
            self.pendingSecondarySubtitleTrackOrdinal = nil
            self.state.videoResolution = ""
            self.state.aspectRatio = ""
            self.state.videoDisplayMode = .fit
            self.state.interactiveVideoZoomScale = 1.0
            self.state.interactiveVideoOffset = .zero
            self.clearAllInteractiveVideoGestureActivity()
            self.initialSeekPerformed = false
            self.isMenuPresented = false
            self.deferredTrackRefreshNeeded = false
            self.hasResolvedAutomaticSubtitleSelection = false
            self.hasStartedPlaybackForCurrentItem = false
            self.hasResetReplayProgressLocallyForCurrentItem = false
            self.lastNowPlayingRefreshTime = 0
            self.clearNowPlayingInfo()
            self.deactivateAudioSessionIfPossible(reason: "stop", force: true)
        }

        pendingStopWorkItem = stopWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: stopWorkItem!)
    }

    private func pausePlaybackSmoothly(
        reportReason: String? = nil,
        clearNowPlayingImmediately: Bool = false,
        deactivateAudioSessionAfterPause: Bool = false
    ) {
        guard !isStopInProgress else { return }

        let hasActivePlayback = isUsingMPV || mediaPlayer?.media != nil ||
            (mediaPlayer?.isPlaying ?? false) ||
            state.status == .buffering ||
            state.status == .playing
        guard hasActivePlayback else { return }

        let playerToPause = mediaPlayer

        invalidatePendingPlaybackControls()
        resetPlaybackStallDetection()
        if isUsingMPV || isPreparingMPV { mpvPauseRequested = true }
        state.status = .paused
        if let reportReason = reportReason {
            reportServerProgress(force: true, reason: reportReason)
        }
        if clearNowPlayingImmediately {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        } else {
            updateNowPlayingInfo()
        }

        if let mpvEngine {
            mpvPauseRequested = true
            MPVPlaybackTransport(engine: mpvEngine).pause()
            if deactivateAudioSessionAfterPause {
                deactivateAudioSessionIfPossible(reason: "pause", force: true)
            }
        } else if self.mediaPlayer === playerToPause {
            VLCPlaybackTransport(player: playerToPause).pause()
            if deactivateAudioSessionAfterPause {
                self.deactivateAudioSessionIfPossible(reason: "pause", force: true)
            }
        }
    }
    
    func seek(to time: Double) {
        guard time.isFinite else { return }
        if mpvEngine != nil {
            let target = max(0, state.duration > 0 ? min(time, state.duration) : time)
            guard isSeekable else { _ = onRequestSeekToTime?(target); return }
            subtitleIntelligence.seek(to: target)
            beginSeekBufferingObservation()
            transport.seek(to: playerLocalTime(fromLogicalTime: target))
            applyOptimisticSeekState(targetTime: target)
            reportServerProgress(force: true, reason: "seek")
            updateNowPlayingInfo()
            return
        }
        let resolvedDuration = resolvedPlaybackDuration(
            vlcDuration: Double(mediaPlayer?.media?.length.intValue ?? 0) / 1000.0
        )
        let clampedTime = resolvedDuration > 0
            ? max(0, min(time, resolvedDuration))
            : max(0, time)
        print("[VLC-DEBUG] seek(to: \(time)) isSeekable=\((mediaPlayer?.isSeekable ?? false)) isPlaying=\((mediaPlayer?.isPlaying ?? false)) vlcState=\((mediaPlayer?.state.rawValue ?? 0)) duration=\(resolvedDuration) stateStatus=\(state.status)")
        guard (mediaPlayer?.isSeekable ?? false) else {
            if onRequestSeekToTime?(clampedTime) == true {
                print("[VLC-DEBUG] seek HANDLED by remote restart path: clampedTime=\(clampedTime)")
                return
            }
            print("[VLC-DEBUG] seek REJECTED: not seekable!")
            return
        }
        subtitleIntelligence.seek(to: clampedTime)
        beginSeekBufferingObservation()
        transport.seek(to: clampedTime)
        applyOptimisticSeekState(targetTime: clampedTime, durationOverride: resolvedDuration)
        print("[VLC-DEBUG] seek DONE: vlcState=\((mediaPlayer?.state.rawValue ?? 0)) isPlaying=\((mediaPlayer?.isPlaying ?? false))")
        reportServerProgress(force: true, reason: "seek")
        updateNowPlayingInfo()
    }
    
    func seek(by seconds: Double) {
        if isUsingMPV { seek(to: state.currentTime + seconds); return }
        let resolvedDuration = resolvedPlaybackDuration(
            vlcDuration: Double(mediaPlayer?.media?.length.intValue ?? 0) / 1000.0
        )
        let unclampedTime = state.currentTime + seconds
        let newTime = resolvedDuration > 0
            ? max(0, min(unclampedTime, resolvedDuration))
            : max(0, unclampedTime)

        guard (mediaPlayer?.isSeekable ?? false) else {
            if onRequestSeekToTime?(newTime) == true {
                print("[VLC-DEBUG] relative seek HANDLED by remote restart path: seconds=\(seconds) target=\(newTime)")
                return
            }
            print("[VLC-DEBUG] relative seek REJECTED: not seekable!")
            return
        }

        let roundedSeconds = Int(abs(seconds).rounded())
        let signedRoundedSeconds = seconds >= 0 ? Double(roundedSeconds) : -Double(roundedSeconds)
        let canUseNativeJump =
            roundedSeconds > 0 &&
            abs(seconds - signedRoundedSeconds) < 0.001 &&
            ((mediaPlayer?.isPlaying ?? false) || state.status == .playing || state.status == .buffering)

        if canUseNativeJump {
            print("[VLC-DEBUG] relative jump EXECUTING: seconds=\(seconds) target=\(newTime)")
            subtitleIntelligence.seek(to: newTime)
            beginSeekBufferingObservation()
            if seconds >= 0 {
                mediaPlayer?.jumpForward(Int32(roundedSeconds))
            } else {
                mediaPlayer?.jumpBackward(Int32(roundedSeconds))
            }
            applyOptimisticSeekState(targetTime: newTime, durationOverride: resolvedDuration)
            reportServerProgress(force: true, reason: "seek")
            updateNowPlayingInfo()
            return
        }

        seek(to: newTime)
    }

    private func applyOptimisticSeekState(targetTime: Double, durationOverride: Double? = nil) {
        state.currentTime = targetTime
        let resolvedDuration = resolvedPlaybackDuration(vlcDuration: durationOverride)
        state.progress = resolvedPlaybackProgress(
            currentTime: targetTime,
            duration: resolvedDuration,
            fallbackPosition: state.progress
        )
        updateCurrentSecondarySubtitleParts(at: targetTime)
    }
    
    // MARK: - Legacy Helpers
    func setVolume(_ value: Float) {
        // Clamp 0.0 - 1.0
        let clamped = max(0.0, min(1.0, value))
        self.volume = clamped
    }
    
    func setBrightness(_ value: CGFloat) {
        playbackScreen.brightness = max(0.0, min(1.0, value))
    }
    
    func toggleMute() {
        isMuted.toggle()
        if isUsingMPV { transport.setMuted(isMuted); return }
        if (mediaPlayer?.isPlaying ?? false) {
            // Fast pause → apply mute → resume trick for instant effect
            let currentTime = mediaPlayer?.time
            mediaPlayer?.pause()
            transport.setMuted(isMuted)
            mediaPlayer?.play()
            if let currentTime { mediaPlayer?.time = currentTime }
        } else {
            transport.setMuted(isMuted)
        }
    }

    private func autoUnmuteIfNeeded(for volume: Float) {
        guard isMuted, volume > 0.01 else { return }
        isMuted = false
        if isUsingMPV { transport.setMuted(false); return }

        if (mediaPlayer?.isPlaying ?? false) {
            // Keep current behavior consistent with manual mute toggle for immediate effect.
            let currentTime = mediaPlayer?.time
            mediaPlayer?.pause()
            transport.setMuted(false)
            mediaPlayer?.play()
            if let currentTime { mediaPlayer?.time = currentTime }
        } else {
            transport.setMuted(false)
        }
    }
    
    func addExternalSubtitle(url: URL) {
        if isUsingMPV { addMPVSubtitle(url); return }
        guard let mediaURL = state.currentItem?.url else { return }
        var merged = externalSubtitleCandidates
        let key = subtitleURLKey(url)
        if !merged.contains(where: { subtitleURLKey($0) == key }) {
            merged.append(url)
        }
        setExternalSubtitleCandidates(for: mediaURL, urls: merged, autoSelectFirst: false)
        if let trackID = externalSubtitleTrackID(for: url) {
            setSubtitleTrack(trackID)
        }
    }
    
    func requestCurrentFrame(persist: Bool = false, completion: @escaping (UIImage?) -> Void) {
        guard let mpvEngine else {
            completion(persist ? takeSnapshot() : captureCurrentFramePreview())
            return
        }
        let attempt = playbackAttemptID
        mpvEngine.snapshot { [weak self] url in
            defer { if let url { try? FileManager.default.removeItem(at: url) } }
            guard let self, self.playbackAttemptID == attempt, self.isUsingMPV,
                  let url, let decoded = UIImage(contentsOfFile: url.path), let pixels = decoded.cgImage else { completion(nil); return }
            var imageScale = self.playbackScreen.scale
            #if targetEnvironment(simulator)
            // Software preview pixels are capped independently of the screen's Retina scale.
            let surfaceWidth = mpvEngine.videoSurfaceView.bounds.width
            if surfaceWidth > 1 { imageScale = CGFloat(pixels.width) / surfaceWidth }
            #endif
            let image = UIImage(cgImage: pixels, scale: imageScale, orientation: .up)
            let rect = Self.visibleVideoRect(containerSize: image.size, naturalVideoSize: self.videoNaturalSize,
                aspectRatioOverride: self.state.aspectRatio, displayMode: .fit)
            var composited = self.compositeSecondarySubtitlesIfNeeded(on: image, videoRect: rect)
            if self.subtitleIntelligence.isGeneratedPrimary {
                composited = self.compositeSecondarySubtitlesIfNeeded(on: composited, videoRect: rect,
                    partsOverride: self.displayedPrimarySubtitleParts, primary: true)
            }
            let result = self.cropImageToVideoRect(composited, videoRect: rect)
            completion(!persist || self.saveSnapshotImageToDisk(result) ? result : nil)
        }
    }

    func takeSnapshot() -> UIImage? {
        if Thread.isMainThread {
            return captureSnapshotImage(persistToDisk: true)
        }
        return DispatchQueue.main.sync { [weak self] in
            self?.captureSnapshotImage(persistToDisk: true)
        }
    }

    func persistSnapshotImage(_ image: UIImage) -> Bool {
        if Thread.isMainThread {
            return saveSnapshotImageToDisk(image)
        }
        return DispatchQueue.main.sync { [weak self] in
            self?.saveSnapshotImageToDisk(image) ?? false
        }
    }

    func captureCurrentFramePreview(allowOffscreenViewCapture: Bool = true) -> UIImage? {
        if Thread.isMainThread {
            return captureSnapshotImage(
                persistToDisk: false,
                allowOffscreenViewCapture: allowOffscreenViewCapture
            )
        }
        return DispatchQueue.main.sync { [weak self] in
            self?.captureSnapshotImage(
                persistToDisk: false,
                allowOffscreenViewCapture: allowOffscreenViewCapture
            )
        }
    }

    func requestSeekPreviewImage(at targetTime: Double, completion: @escaping (UIImage?) -> Void) {
        guard let currentItem = state.currentItem,
              resolvedPlaybackItemType(for: currentItem) == .video else {
            completion(nil)
            return
        }

        let requestToken = UUID()
        seekPreviewRequestToken = requestToken

        let duration = resolvedPlaybackDuration(for: currentItem)
        let clampedTargetTime = duration > 0.5
            ? max(0, min(targetTime, duration))
            : max(0, targetTime)
        let snapshotPosition: Float
        if duration > 0.5 {
            snapshotPosition = Float(min(max(clampedTargetTime / duration, 0), 0.999))
        } else {
            snapshotPosition = 0
        }

        let cacheKeys = seekPreviewCacheKeys(
            for: currentItem,
            targetTime: clampedTargetTime
        )
        if let cachedImage = cachedSeekPreviewThumbnail(forKeys: cacheKeys) {
            completion(cachedImage)
            return
        }

        seekPreviewRemoteTask?.cancel()
        seekPreviewRemoteTask = nil
        seekPreviewThumbnailGenerator?.cancel()
        seekPreviewThumbnailGenerator = nil

        let prefersServerSeekPreview =
            currentItem.isRemote &&
            (currentItem.serverType == .jellyfin ||
             currentItem.serverType == .emby ||
             currentItem.serverType == .plex)

        if prefersServerSeekPreview {
            seekPreviewRemoteTask = Task { [weak self] in
                guard let self else { return }

                let resolvedFrameIntervalSeconds: Double?
                if self.remoteSeekPreviewFrameIntervalSeconds == nil {
                    resolvedFrameIntervalSeconds = await ServerSeekPreviewService.shared.trickplayFrameIntervalSeconds(
                        for: currentItem
                    )
                    if let resolvedFrameIntervalSeconds {
                        await MainActor.run {
                            guard self.state.currentItem?.id == currentItem.id else { return }
                            self.remoteSeekPreviewFrameIntervalSeconds = resolvedFrameIntervalSeconds
                        }
                    }
                } else {
                    resolvedFrameIntervalSeconds = self.remoteSeekPreviewFrameIntervalSeconds
                }

                let resolvedCacheKeys = self.seekPreviewCacheKeys(
                    for: currentItem,
                    targetTime: clampedTargetTime,
                    explicitFrameIntervalSeconds: resolvedFrameIntervalSeconds
                )
                if let cachedImage = self.cachedSeekPreviewThumbnail(forKeys: resolvedCacheKeys) {
                    await MainActor.run {
                        guard self.seekPreviewRequestToken == requestToken else { return }
                        self.seekPreviewRemoteTask = nil
                        completion(cachedImage)
                    }
                    return
                }

                let serverImage = await ServerSeekPreviewService.shared.previewImage(
                    for: currentItem,
                    targetTime: clampedTargetTime
                )

                guard !Task.isCancelled else { return }

                if let serverImage {
                    await MainActor.run {
                        guard self.seekPreviewRequestToken == requestToken else { return }
                        self.seekPreviewRemoteTask = nil
                        self.cacheSeekPreviewThumbnail(
                            serverImage,
                            forKeys: resolvedCacheKeys
                        )
                        completion(serverImage)
                    }
                    return
                }

                await MainActor.run {
                    self.performLegacySeekPreviewRequest(
                        for: currentItem,
                        snapshotPosition: snapshotPosition,
                        cacheKeys: resolvedCacheKeys,
                        requestToken: requestToken,
                        completion: completion
                    )
                }
            }
            return
        }

        performLegacySeekPreviewRequest(
            for: currentItem,
            snapshotPosition: snapshotPosition,
            cacheKeys: cacheKeys,
            requestToken: requestToken,
            completion: completion
        )
    }

    private func performLegacySeekPreviewRequest(
        for item: MediaItem,
        snapshotPosition: Float,
        cacheKeys: [String],
        requestToken: UUID,
        completion: @escaping (UIImage?) -> Void
    ) {
        guard seekPreviewRequestToken == requestToken else { return }

        let legacy: () -> (any PlaybackPreviewProvider)? = { [weak self] in
            guard let self, PlaybackEngineAvailability.current.vlc else { return nil }
            return VLCPlaybackPreviewProvider(media: self.makeConfiguredMedia(for: item, purpose: .seekPreview), width: 480)
        }
        let generator: any PlaybackPreviewProvider
        if playbackCapabilities.previewBackend == .independent {
            let duration = resolvedPlaybackDuration(for: item)
            let size = videoNaturalSize
            generator = MPVPlaybackPreviewProvider(duration: duration, sourceSize: size) { [weak self] time in
                guard let self, self.seekPreviewRequestToken == requestToken else { return nil }
                let stream = self.mpvStream(for: item, byteCache: self.mpvReadAheadByteCache)
                return MPVPlaybackEngine.Configuration(
                    url: stream == nil ? RuntimeNetworkAddressResolver.runtimeURL(from: item.url) : item.url,
                    start: self.playerLocalTime(fromLogicalTime: time),
                    options: self.mpvNetworkOptions(for: item), subtitles: [], stream: stream)
            }
        } else {
            guard let provider = legacy() else { completion(nil); return }
            generator = provider
        }
        seekPreviewThumbnailGenerator?.cancel()
        seekPreviewThumbnailGenerator = generator

        generator.generate(snapshotPosition: snapshotPosition) { [weak self] frame in
            let image = frame.map { UIImage(cgImage: $0) }
            guard let self else { return }
            guard self.seekPreviewRequestToken == requestToken else { return }
            guard self.seekPreviewThumbnailGenerator === generator else { return }
            self.seekPreviewRemoteTask = nil
            self.seekPreviewThumbnailGenerator = nil
            if let image {
                self.cacheSeekPreviewThumbnail(image, forKeys: cacheKeys)
            }
            completion(image)
        }
    }

    func cancelSeekPreviewImageRequest() {
        seekPreviewRemoteTask?.cancel()
        seekPreviewRemoteTask = nil
        seekPreviewThumbnailGenerator?.cancel()
        seekPreviewThumbnailGenerator = nil
        seekPreviewRequestToken = nil
    }

    func prewarmSeekPreviewIfNeeded(for item: MediaItem, targetTime: Double? = nil) {
        guard item.isRemote,
              item.serverType == .jellyfin ||
              item.serverType == .emby ||
              item.serverType == .plex else {
            return
        }

        let duration = resolvedPlaybackDuration(for: item)
        let unclampedTargetTime = targetTime ?? state.currentTime
        let normalizedMediaSourceID = item.mediaSourceId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTargetTime: Double
        if duration > 0.5 {
            resolvedTargetTime = max(0, min(unclampedTargetTime, duration))
        } else {
            resolvedTargetTime = max(0, unclampedTargetTime)
        }
        let initialWarmupBucket = seekPreviewWarmupBucket(for: resolvedTargetTime)

        if seekPreviewWarmupItemID == item.id,
           seekPreviewWarmupTimeBucket == initialWarmupBucket,
           seekPreviewWarmupMediaSourceID == normalizedMediaSourceID {
            return
        }

        seekPreviewWarmupTask?.cancel()
        seekPreviewWarmupItemID = item.id
        seekPreviewWarmupTimeBucket = initialWarmupBucket
        seekPreviewWarmupMediaSourceID = normalizedMediaSourceID

        seekPreviewWarmupTask = Task(priority: .utility) { [weak self] in
            let frameIntervalSeconds = await ServerSeekPreviewService.shared.trickplayFrameIntervalSeconds(
                for: item
            )
            let resolvedWarmupBucket = self?.seekPreviewWarmupBucket(
                for: resolvedTargetTime,
                explicitFrameIntervalSeconds: frameIntervalSeconds
            ) ?? initialWarmupBucket
            _ = await ServerSeekPreviewService.shared.previewImage(
                for: item,
                targetTime: resolvedTargetTime
            )

            guard !Task.isCancelled else { return }

            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.seekPreviewWarmupItemID == item.id,
                      self.seekPreviewWarmupTimeBucket == initialWarmupBucket,
                      self.seekPreviewWarmupMediaSourceID == normalizedMediaSourceID else {
                    return
                }
                self.seekPreviewWarmupTimeBucket = resolvedWarmupBucket
                self.remoteSeekPreviewFrameIntervalSeconds = frameIntervalSeconds
                self.seekPreviewWarmupTask = nil
            }
        }
    }

    func captureFrameForPictureInPicture(maxWidth: CGFloat = 360) -> UIImage? {
        if Thread.isMainThread {
            return captureSnapshotImageForPiP(maxWidth: maxWidth)
        }
        return DispatchQueue.main.sync { [weak self] in
            self?.captureSnapshotImageForPiP(maxWidth: maxWidth)
        }
    }

    func captureStartupFrameForPictureInPicture(maxWidth: CGFloat = 360) -> UIImage? {
        if Thread.isMainThread {
            return captureVisibleSnapshotImageForPiPStartup(maxWidth: maxWidth)
        }
        return DispatchQueue.main.sync { [weak self] in
            self?.captureVisibleSnapshotImageForPiPStartup(maxWidth: maxWidth)
        }
    }

    func capturePreviewFrameForPictureInPicture(
        maxWidth: CGFloat = 360,
        allowOffscreenViewCapture: Bool = true
    ) -> UIImage? {
        if Thread.isMainThread {
            return captureSnapshotPreviewImageForPiP(
                maxWidth: maxWidth,
                allowOffscreenViewCapture: allowOffscreenViewCapture
            )
        }
        return DispatchQueue.main.sync { [weak self] in
            self?.captureSnapshotPreviewImageForPiP(
                maxWidth: maxWidth,
                allowOffscreenViewCapture: allowOffscreenViewCapture
            )
        }
    }

    func canRequestVLCSnapshotForPictureInPicture() -> Bool {
        guard let currentItem = state.currentItem,
              resolvedPlaybackItemType(for: currentItem) == .video else {
            return false
        }

        guard !isStopInProgress,
              mediaPlayer?.media != nil,
              state.status != .idle else {
            return false
        }

        switch mediaPlayer?.state {
        case .stopped, .ended, .error:
            return false
        default:
            break
        }

        return videoNaturalSize.width > 1 && videoNaturalSize.height > 1
    }
    
    func playPrevious() { /* No-op, handled by View */ }
    func playNext() { /* No-op, handled by View */ }
    
    static let availableAspectRatios: [String] = ["", "16:9", "4:3", "1:1", "16:10", "2.35:1"]

    static func parsedAspectRatioValue(from ratio: String) -> CGFloat? {
        let trimmed = ratio.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parts = trimmed.split(separator: ":").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let resolvedValue: Double?
        if parts.count == 2,
           let width = Double(parts[0]),
           let height = Double(parts[1]),
           height > 0 {
            resolvedValue = width / height
        } else if parts.count == 1 {
            resolvedValue = Double(parts[0])
        } else {
            resolvedValue = nil
        }

        guard let resolvedValue,
              resolvedValue.isFinite,
              resolvedValue > 0 else {
            return nil
        }

        return CGFloat(resolvedValue)
    }

    static func resolvedVideoAspectRatio(
        override aspectRatio: String,
        naturalSize: CGSize
    ) -> CGFloat? {
        if let forcedRatio = parsedAspectRatioValue(from: aspectRatio) {
            return forcedRatio
        }

        guard naturalSize.width > 0, naturalSize.height > 0 else {
            return nil
        }

        let naturalRatio = naturalSize.width / naturalSize.height
        guard naturalRatio.isFinite, naturalRatio > 0 else {
            return nil
        }

        return naturalRatio
    }

    func fitMacWindowToVideoAspectRatioIfNeeded() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.fitMacWindowToVideoAspectRatioIfNeeded()
            }
            return
        }
        #if targetEnvironment(macCatalyst)
        if #available(iOS 16.0, *) {
            let naturalSize = videoNaturalSize
            guard naturalSize.width > 1, naturalSize.height > 1 else { return }
            guard let aspect = VLCPlaybackService.resolvedVideoAspectRatio(
                override: state.aspectRatio,
                naturalSize: naturalSize
            ), aspect.isFinite, aspect > 0 else { return }

            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            guard let windowScene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }

            let currentBounds = windowScene.coordinateSpace.bounds
            guard currentBounds.width > 100, currentBounds.height > 100 else { return }

            var targetWidth = currentBounds.width
            var targetHeight = (targetWidth / aspect).rounded()

            let screenBounds = windowScene.screen.bounds
            let maxAvailableHeight = max(screenBounds.height * 0.85, 400)
            let maxAvailableWidth = max(screenBounds.width * 0.85, 600)

            if targetHeight > maxAvailableHeight {
                targetHeight = maxAvailableHeight.rounded()
                targetWidth = (targetHeight * aspect).rounded()
            }
            if targetWidth > maxAvailableWidth {
                targetWidth = maxAvailableWidth.rounded()
                targetHeight = (targetWidth / aspect).rounded()
            }

            let pref = UIWindowScene.GeometryPreferences.Mac(size: CGSize(width: targetWidth, height: targetHeight))
            windowScene.requestGeometryUpdate(pref) { error in
                print("[Mac] Window geometry update error: \(error.localizedDescription)")
            }
        }
        #endif
    }

    func toggleVideoDisplayMode() {
        let newMode: VideoDisplayMode = state.videoDisplayMode == .fit ? .fill : .fit
        setVideoDisplayMode(newMode)
    }

    static func visibleVideoRect(
        containerSize: CGSize,
        naturalVideoSize: CGSize,
        aspectRatioOverride: String,
        displayMode: VideoDisplayMode
    ) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        if displayMode == .fill {
            return CGRect(origin: .zero, size: containerSize)
        }

        guard let aspectRatio = resolvedVideoAspectRatio(
            override: aspectRatioOverride,
            naturalSize: naturalVideoSize
        ) else {
            return CGRect(origin: .zero, size: containerSize)
        }

        return scaledVideoRect(
            containerSize: containerSize,
            aspectRatio: aspectRatio,
            usesFillScale: false
        )
    }

    static func drawableVideoFrame(
        containerSize: CGSize,
        naturalVideoSize: CGSize,
        aspectRatioOverride: String,
        displayMode: VideoDisplayMode
    ) -> CGRect {
        guard containerSize.width > 0, containerSize.height > 0 else {
            return .zero
        }

        guard let aspectRatio = resolvedVideoAspectRatio(
            override: aspectRatioOverride,
            naturalSize: naturalVideoSize
        ) else {
            return CGRect(origin: .zero, size: containerSize)
        }

        return scaledVideoRect(
            containerSize: containerSize,
            aspectRatio: aspectRatio,
            usesFillScale: displayMode == .fill
        )
    }

    static func clampedInteractiveVideoZoomScale(_ scale: CGFloat) -> CGFloat {
        let resolvedScale = max(1.0, min(scale, 3.0))
        return resolvedScale.isFinite ? resolvedScale : 1.0
    }

    static func interactiveVideoBaseScale(
        containerSize: CGSize,
        naturalVideoSize: CGSize,
        aspectRatioOverride: String,
        displayMode: VideoDisplayMode
    ) -> CGFloat {
        guard displayMode == .fill else { return 1.0 }

        let fitRect = visibleVideoRect(
            containerSize: containerSize,
            naturalVideoSize: naturalVideoSize,
            aspectRatioOverride: aspectRatioOverride,
            displayMode: .fit
        )
        guard fitRect.width > 1, fitRect.height > 1 else { return 1.0 }

        let scaleX = containerSize.width / fitRect.width
        let scaleY = containerSize.height / fitRect.height
        let resolvedScale = max(scaleX, scaleY)
        guard resolvedScale.isFinite, resolvedScale > 1.0 else { return 1.0 }
        return resolvedScale
    }

    static func transformedVideoRect(
        baseVideoRect: CGRect,
        containerBounds: CGRect,
        totalScale: CGFloat,
        offset: CGSize
    ) -> CGRect {
        guard totalScale.isFinite, totalScale > 0 else {
            return baseVideoRect.offsetBy(dx: offset.width, dy: offset.height)
        }

        let center = CGPoint(x: containerBounds.midX, y: containerBounds.midY)
        let scaledOrigin = CGPoint(
            x: center.x + (baseVideoRect.minX - center.x) * totalScale + offset.width,
            y: center.y + (baseVideoRect.minY - center.y) * totalScale + offset.height
        )

        return CGRect(
            origin: scaledOrigin,
            size: CGSize(
                width: baseVideoRect.width * totalScale,
                height: baseVideoRect.height * totalScale
            )
        )
    }

    static func clampedInteractiveVideoOffset(
        containerBounds: CGRect,
        baseVideoRect: CGRect,
        totalScale: CGFloat,
        proposedOffset: CGSize
    ) -> CGSize {
        guard containerBounds.width > 1,
              containerBounds.height > 1,
              baseVideoRect.width > 1,
              baseVideoRect.height > 1,
              totalScale.isFinite,
              totalScale > 0 else {
            return .zero
        }

        let scaledRect = transformedVideoRect(
            baseVideoRect: baseVideoRect,
            containerBounds: containerBounds,
            totalScale: totalScale,
            offset: .zero
        )

        let minOffsetX = containerBounds.maxX - scaledRect.maxX
        let maxOffsetX = -scaledRect.minX
        let minOffsetY = containerBounds.maxY - scaledRect.maxY
        let maxOffsetY = -scaledRect.minY

        let resolvedX: CGFloat
        if minOffsetX <= maxOffsetX {
            resolvedX = min(max(proposedOffset.width, minOffsetX), maxOffsetX)
        } else {
            resolvedX = 0
        }

        let resolvedY: CGFloat
        if minOffsetY <= maxOffsetY {
            resolvedY = min(max(proposedOffset.height, minOffsetY), maxOffsetY)
        } else {
            resolvedY = 0
        }

        return CGSize(width: resolvedX, height: resolvedY)
    }

    private static func scaledVideoRect(
        containerSize: CGSize,
        aspectRatio: CGFloat,
        usesFillScale: Bool
    ) -> CGRect {
        guard containerSize.width > 0,
              containerSize.height > 0,
              aspectRatio.isFinite,
              aspectRatio > 0 else {
            return CGRect(origin: .zero, size: containerSize)
        }

        let containerAspect = containerSize.width / containerSize.height
        let shouldMatchWidth = usesFillScale ? (aspectRatio < containerAspect) : (aspectRatio > containerAspect)

        let videoWidth: CGFloat
        let videoHeight: CGFloat

        if shouldMatchWidth {
            videoWidth = containerSize.width
            videoHeight = videoWidth / aspectRatio
        } else {
            videoHeight = containerSize.height
            videoWidth = videoHeight * aspectRatio
        }

        let x = (containerSize.width - videoWidth) / 2
        let y = (containerSize.height - videoHeight) / 2
        return CGRect(x: x, y: y, width: videoWidth, height: videoHeight)
    }
    
    func setAspectRatio(_ ratio: String) {
        state.aspectRatio = ratio
        resetInteractiveVideoTransform()
        if let mpvEngine { mpvEngine.set("video-aspect-override", ratio.isEmpty ? "-1" : ratio); return }
        if ratio.isEmpty {
            mediaPlayer?.videoAspectRatio = nil
        } else {
            mediaPlayer?.videoAspectRatio = UnsafeMutablePointer<Int8>(mutating: (ratio as NSString).utf8String)
        }
    }

    func setVideoDisplayMode(_ mode: VideoDisplayMode) {
        state.videoDisplayMode = mode
        resetInteractiveVideoTransform()
    }

    func updateInteractiveVideoTransform(zoomScale: CGFloat, offset: CGSize) {
        state.interactiveVideoZoomScale = VLCPlaybackService.clampedInteractiveVideoZoomScale(zoomScale)
        if state.interactiveVideoZoomScale <= 1.0001 {
            state.interactiveVideoZoomScale = 1.0
        }
        state.interactiveVideoOffset = offset
    }

    func resetInteractiveVideoTransform() {
        state.interactiveVideoZoomScale = 1.0
        state.interactiveVideoOffset = .zero
        clearAllInteractiveVideoGestureActivity()
    }
    
    func cycleAspectRatio() {
        let ratios = VLCPlaybackService.availableAspectRatios
        let current = state.aspectRatio
        
        if let index = ratios.firstIndex(of: current) {
            let nextIndex = (index + 1) % ratios.count
            setAspectRatio(ratios[nextIndex])
        } else {
            setAspectRatio(ratios[0])
        }
    }
    
    func cyclePlaybackRate() {
        let rates = availablePlaybackRates
        let current = state.rate
        // Find next rate
        if let index = rates.firstIndex(where: { abs($0 - current) < 0.1 }) {
            let nextIndex = (index + 1) % rates.count
            applyPlaybackRate(rates[nextIndex], persistsInSession: true)
        } else {
             applyPlaybackRate(1.0, persistsInSession: true)
        }
    }
    
    func setPlaybackRate(_ rate: Float) {
        applyPlaybackRate(rate, persistsInSession: true)
    }

    func setTemporaryPlaybackRate(_ rate: Float) {
        applyPlaybackRate(rate, persistsInSession: false)
    }
    
    // MARK: - Picture in Picture (PiP)
    
    @discardableResult
    func startPictureInPicture(userInitiated: Bool = false) -> Bool {
        guard let currentItem = state.currentItem,
              resolvedPlaybackItemType(for: currentItem) == .video else {
            shouldDismissPlayerWhenPiPStarts = false
            return false
        }

        shouldDismissPlayerWhenPiPStarts = userInitiated

        if #available(iOS 15.0, *),
           AVPictureInPictureController.isPictureInPictureSupported() {
            if videoPiPController == nil {
                let controller = VLCPlayerPictureInPictureController(playbackService: self)
                controller.onDidStart = { [weak self] in
                    self?.handlePictureInPictureDidStart()
                }
                controller.onDidStop = { [weak self] in
                    self?.handlePictureInPictureDidStop()
                }
                controller.onStartFailed = { [weak self] in
                    self?.handlePictureInPictureStartFailure()
                }
                videoPiPController = controller
            }

            guard videoPiPController?.start() == true else {
                let shouldDismissOnFallback = shouldDismissPlayerWhenPiPStarts
                shouldDismissPlayerWhenPiPStarts = false
                if shouldDismissOnFallback {
                    return false
                }
                return activateFallbackFloatingPlayback(requestPlayerDismissal: shouldDismissOnFallback)
            }

            return true
        }

        let shouldDismissOnFallback = shouldDismissPlayerWhenPiPStarts
        shouldDismissPlayerWhenPiPStarts = false
        return activateFallbackFloatingPlayback(requestPlayerDismissal: shouldDismissOnFallback)
    }
    
    func stopPictureInPicture() {
        shouldDismissPlayerWhenPiPStarts = false
        pendingDrawablePlaybackSessionRestoreAfterPictureInPicture = false
        if #available(iOS 15.0, *) {
            videoPiPController?.stop()
            videoPiPController = nil
        }

        pipCancellable?.cancel()
        pipCancellable = nil

        DispatchQueue.main.async {
            self.isVideoPiPActive = false
            self.floatingVideoFile = nil
            self.shouldDismissPresentedPlayerAfterPiPStart = false
            self.requestedVideoPlayerRestoreFile = nil
            self.pipUsableViewController = nil
        }
    }

    func consumePresentedPlayerPiPDismissRequest() {
        shouldDismissPresentedPlayerAfterPiPStart = false
    }

    func requestVideoPlayerRestoreFromPictureInPicture(
        completion: ((Bool) -> Void)? = nil
    ) -> Bool {
        guard let restoreFile = minimizedPlaybackVideoFile() else { return false }
        isRestoringPlayerFromPictureInPicture = true
        pendingPictureInPictureRestoreFile = restoreFile
        suppressAutomaticPictureInPictureUntil = Date().timeIntervalSinceReferenceDate + 2.0
        suppressPictureInPictureRestoreAutoRotateUntil = Date().timeIntervalSinceReferenceDate + 1.0
        extendPlayerViewStopSuppressionForPictureInPictureRestore(by: 3.0)
        if Thread.isMainThread {
            requestedVideoPlayerRestoreFile = restoreFile
        } else {
            DispatchQueue.main.sync { [weak self] in
                self?.requestedVideoPlayerRestoreFile = restoreFile
            }
        }
        if let completion {
            print("[PiP] acknowledging restore request immediately")
            completion(true)
        }
        return true
    }

    func clearRequestedVideoPlayerRestoreFile() {
        requestedVideoPlayerRestoreFile = nil
    }

    func completeVideoPlayerRestoreFromPictureInPicture(success: Bool) {
        pendingPictureInPictureRestoreFile = nil
        suppressAutomaticPictureInPictureUntil = .zero
        suppressPictureInPictureRestoreAutoRotateUntil = .zero
        if success {
            extendPlayerViewStopSuppressionForPictureInPictureRestore(by: 1.2)
        } else {
            pendingDrawablePlaybackSessionRestoreAfterPictureInPicture = false
            suppressPlayerViewStopDuringPictureInPictureRestoreUntil = .zero
        }
        print("[PiP] finalized restore state success=\(success)")
    }
    
    func setAudioDelay(_ seconds: Double) {
        let clamped = min(max(seconds, -10.0), 10.0)
        guard abs(AppSettings.shared.audioDelaySeconds - clamped) > 0.001 else { return }
        AppSettings.shared.audioDelaySeconds = clamped
        if let mpvEngine { mpvEngine.set("audio-delay", String(clamped)); return }
        reloadCurrentItemPreservingPlaybackState()
    }
    
    func setAudioTrack(_ id: Int) {
        pendingEngineTracks["audio"] = nil
        preservesDisabledAudio = id == -1
        if isUsingMPV {
            pendingAudioTrackQuery = nil
            pendingAudioTrackOrdinal = nil
            transport.selectAudioTrack(id)
            state.currentAudioTrackID = id
            rememberMPVTrack(id, type: "audio")
            subtitleIntelligence.refreshDefaultAudioTrack()
            return
        }
        transport.selectAudioTrack(id)
        state.currentAudioTrackID = id
        subtitleIntelligence.refreshDefaultAudioTrack()
        nudgePlaybackForImmediateTrackChange()
    }
    
    func setSubtitleTrack(_ id: Int) {
        // Defer one run loop so Menu can dismiss before player state churn (prevents flicker/missed taps).
        if isMenuPresented {
            let attempt = playbackAttemptID
            hasResolvedAutomaticSubtitleSelection = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.playbackAttemptID == attempt else { return }
                self.applySubtitleTrackSelection(id)
            }
            return
        }
        applySubtitleTrackSelection(id)
    }

    private func applyPlaybackRate(_ rate: Float, persistsInSession: Bool) {
        let rate = MPVPlaybackSpeed.clamped(rate, maximum: isUsingMPV ? 8 : 4)
        transport.setRate(rate)
        state.rate = rate
        if persistsInSession {
            sessionPlaybackRate = rate
            // Only explicit speed changes update defaults; hold-to-speed and restoration stay temporary.
            if let item = state.currentItem {
                switch resolvedPlaybackItemType(for: item) {
                case .audio: AppSettings.shared.defaultAudioPlaybackSpeed = Double(rate)
                case .video: AppSettings.shared.defaultPlaybackSpeed = Double(rate)
                default: break
                }
            }
        }
        updateNowPlayingInfo()

        // The iOS VLC core preserves queued audio across rate changes.
        // Seeking here would flush that audio and the video decoder again.
    }

    private func applySubtitleTrackSelection(_ id: Int) {
        hasResolvedAutomaticSubtitleSelection = true
        pendingSubtitleTrack = nil
        pendingSubtitleTrackQuery = nil
        pendingSubtitleTrackOrdinal = nil
        pendingEngineTracks["sub"] = nil
        if id == IOSSubtitleIntelligence.generatedPrimaryID {
            subtitleIntelligence.selectGeneratedPrimary()
            return
        }
        subtitleIntelligence.selectedOrdinaryPrimary(isOff: id == -1)
        defer { refreshIntelligentPrimarySubtitle() }
        remoteSubtitleSelectionTask?.cancel()
        remoteSubtitleSelectionTask = nil

        if isUsingMPV {
            // A manual choice supersedes an external subtitle still being read.
            mpvPendingExternalSubtitle = nil
            mpvPendingTrackChoices["sub"] = nil
            pendingSubtitleTrackQuery = nil
            pendingSubtitleTrackOrdinal = nil
            if let externalURL = externalSubtitleURL(forTrackID: id),
               mpvState?.tracks.contains(where: { $0.type == "sub" && $0.id == id }) != true {
                addMPVSubtitle(externalURL)
                return
            }
            setMPVPrimarySubtitle(id)
            state.currentSubtitleTrackID = id
            state.currentItem?.externalSubtitleURL = mpvState?.tracks.first { $0.type == "sub" && $0.id == id }?.externalURL
            if !isApplyingAutomaticSubtitleSelection { rememberMPVTrack(id, type: "sub") }
            refreshSecondarySubtitleTracks()
            return
        }
        if let externalURL = externalSubtitleURL(forTrackID: id) {
            state.currentItem?.externalSubtitleURL = externalURL
            state.currentSubtitleTrackID = id
            lastExternalSubtitleReloadKey = nil

            let key = subtitleURLKey(externalURL)
            if let resolvedTrackID = externalSubtitleResolvedTrackIDs[key],
               state.subtitleTracks.contains(where: { $0.id == resolvedTrackID }) {
                mediaPlayer?.currentVideoSubTitleIndex = Int32(resolvedTrackID)
                state.currentSubtitleTrackID = resolvedTrackID
                refreshSecondarySubtitleTracks()
                nudgePlaybackForImmediateTrackChange()
                return
            }

            if state.currentItem?.isRemote == true, !externalURL.isFileURL {
                let currentItemID = state.currentItem?.id
                remoteSubtitleSelectionTask = Task { [weak self] in
                    guard let self else { return }
                    let cachedURL = await self.cacheRemoteSubtitleToLocalIfNeeded(externalURL)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        guard self.state.currentItem?.id == currentItemID else { return }
                        let playbackURL = cachedURL ?? self.normalizedExternalSubtitleURL(for: externalURL)
                        self.loadExternalSubtitleSlave(playbackURL: playbackURL, sourceURL: externalURL, fallbackTrackID: id)
                    }
                }
                return
            }

            let playbackURL = normalizedExternalSubtitleURL(for: externalURL)
            loadExternalSubtitleSlave(playbackURL: playbackURL, sourceURL: externalURL, fallbackTrackID: id)
            return
        }

        // For built-in/VLC-provided tracks, switch in-place to avoid playback reset jumps.
        mediaPlayer?.currentVideoSubTitleIndex = Int32(id)
        state.currentSubtitleTrackID = id
        state.currentItem?.externalSubtitleURL = nil
        refreshSecondarySubtitleTracks()
        nudgePlaybackForImmediateTrackChange()
    }

    private func loadExternalSubtitleSlave(playbackURL: URL, sourceURL: URL, fallbackTrackID: Int) {
        let result = mediaPlayer?.addPlaybackSlave(
            playbackURL,
            type: .subtitle,
            enforce: true
        )
        if let result, result < 0, playbackURL != sourceURL {
            _ = mediaPlayer?.addPlaybackSlave(
                sourceURL,
                type: .subtitle,
                enforce: true
            )
        }

        _ = refreshTracks(force: true)
        syncExternalSubtitleSelection(sourceURL: sourceURL, fallbackTrackID: fallbackTrackID)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self else { return }
            _ = self.refreshTracks(force: true)
            self.syncExternalSubtitleSelection(sourceURL: sourceURL, fallbackTrackID: fallbackTrackID)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            _ = self.refreshTracks(force: true)
            self.syncExternalSubtitleSelection(sourceURL: sourceURL, fallbackTrackID: fallbackTrackID)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self else { return }
            _ = self.refreshTracks(force: true)
            self.syncExternalSubtitleSelection(sourceURL: sourceURL, fallbackTrackID: fallbackTrackID)
            self.reloadCurrentItemForExternalSubtitleIfNeeded(sourceURL: sourceURL, fallbackTrackID: fallbackTrackID)
        }
    }

    private func syncExternalSubtitleSelection(sourceURL: URL, fallbackTrackID: Int) {
        guard !subtitleIntelligence.isGeneratedPrimary else { return }
        let key = subtitleURLKey(sourceURL)
        let actualTrackID = Int((mediaPlayer?.currentVideoSubTitleIndex ?? -1))
        if actualTrackID != -1,
           state.subtitleTracks.contains(where: { $0.id == actualTrackID }) {
            let newlySet = (state.currentSubtitleTrackID != actualTrackID)
            externalSubtitleResolvedTrackIDs[key] = actualTrackID
            state.currentSubtitleTrackID = actualTrackID
            if newlySet { nudgePlaybackForImmediateTrackChange() }
            return
        }

        if let mappedTrackID = externalSubtitleResolvedTrackIDs[key],
           state.subtitleTracks.contains(where: { $0.id == mappedTrackID }) {
            let newlySet = ((mediaPlayer?.currentVideoSubTitleIndex ?? -1) != Int32(mappedTrackID))
            if newlySet {
                mediaPlayer?.currentVideoSubTitleIndex = Int32(mappedTrackID)
            }
            state.currentSubtitleTrackID = mappedTrackID
            if newlySet { nudgePlaybackForImmediateTrackChange() }
            return
        }

        state.currentSubtitleTrackID = fallbackTrackID
    }

    private func reloadCurrentItemForExternalSubtitleIfNeeded(sourceURL: URL, fallbackTrackID: Int) {
        let key = subtitleURLKey(sourceURL)

        guard lastExternalSubtitleReloadKey != key else { return }
        guard externalSubtitleResolvedTrackIDs[key] == nil else { return }
        guard state.currentSubtitleTrackID == fallbackTrackID else { return }
        guard state.subtitleTracks.contains(where: { $0.id == fallbackTrackID && $0.isExternal }) else { return }
        guard var currentItem = state.currentItem else { return }
        guard currentItem.externalSubtitleURL.map(subtitleURLKey) == key else { return }

        lastExternalSubtitleReloadKey = key

        let wasPaused = state.status == .paused
        let preservedTime = preferredResumeTime()
        let preservedDuration = state.duration

        if preservedTime > 1.0 {
            currentItem.startPosition = preservedTime
        }
        currentItem.savedAudioTrackIndex = isUsingMPV || state.currentAudioTrackID == -1 ? nil : state.currentAudioTrackID
        currentItem.savedSubtitleTrackIndex = nil

        play(item: currentItem, in: playerView)

        if preservedDuration > 0 {
            state.duration = preservedDuration
            state.currentTime = preservedTime
            state.progress = Float(max(0.0, min(1.0, preservedTime / preservedDuration)))
        }

        if wasPaused {
            let attemptID = playbackAttemptID
            let controlID = playbackControlID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.isCurrentPlaybackControl(attemptID: attemptID, controlID: controlID) else { return }
                self.pausePlaybackSmoothly()
            }
        }
    }

    func restartCurrentItemForSelectedExternalSubtitle() {
        guard var currentItem = state.currentItem,
              currentItem.externalSubtitleURL != nil else { return }

        let wasPaused = state.status == .paused
        let preservedTime = preferredResumeTime()
        let preservedDuration = state.duration

        if preservedTime > 1.0 {
            currentItem.startPosition = preservedTime
        }
        currentItem.savedAudioTrackIndex = isUsingMPV || state.currentAudioTrackID == -1 ? nil : state.currentAudioTrackID
        currentItem.savedSubtitleTrackIndex = nil

        play(item: currentItem, in: playerView)

        if preservedDuration > 0 {
            state.duration = preservedDuration
            state.currentTime = preservedTime
            state.progress = Float(max(0.0, min(1.0, preservedTime / preservedDuration)))
        }

        if wasPaused {
            let attemptID = playbackAttemptID
            let controlID = playbackControlID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.isCurrentPlaybackControl(attemptID: attemptID, controlID: controlID) else { return }
                self.pausePlaybackSmoothly()
            }
        }
    }
    
    private func nudgePlaybackForImmediateTrackChange() {
        if (mediaPlayer?.isPlaying ?? false) {
            // Re-applying current time forces VLC's media pipeline to flush
            // and immediately render the selected subtitle/audio track
            if let player = mediaPlayer { player.time = player.time }
        }
    }

    func setSecondarySubtitleTrack(_ menuTrackID: Int) {
        pendingSecondaryHandoff = nil
        if menuTrackID == IOSSubtitleIntelligence.translatedSecondaryID, !canOfferSubtitleTranslation { return }
        if menuTrackID == IOSSubtitleIntelligence.translatedSecondaryID || menuTrackID == IOSSubtitleIntelligence.generatedSecondaryID {
            subtitleIntelligence.selectSecondary(menuTrackID)
            return
        }
        subtitleIntelligence.selectSecondary(-1)
        guard AppSettings.shared.enableSecondarySubtitlesBeta else {
            clearSecondarySubtitleTrack()
            return
        }

        guard menuTrackID != -1 else {
            clearSecondarySubtitleTrack(persistPreference: true)
            return
        }

        guard let track = secondarySubtitleTrack(for: menuTrackID) else { return }
        guard canSelectSecondarySubtitle(track) else {
            state.secondarySubtitleStatus = .unsupported
            state.secondarySubtitleParts = []
            secondarySubtitleTimeline = nil
            return
        }

        applySecondarySubtitleTrack(track, persistPreference: true)
    }

    func secondarySubtitleTrackIsCurrentPrimary(_ menuTrackID: Int) -> Bool {
        guard menuTrackID != -1 else { return false }
        guard let track = secondarySubtitleTrack(for: menuTrackID) else { return false }
        return isCurrentPrimarySubtitle(track)
    }

    func secondarySubtitleTrackIsEnabled(_ menuTrackID: Int) -> Bool {
        if menuTrackID == IOSSubtitleIntelligence.translatedSecondaryID {
            if #available(iOS 18.0, *) { return canOfferSubtitleTranslation }
            return false
        }
        if menuTrackID == IOSSubtitleIntelligence.generatedSecondaryID { return subtitleIntelligence.hasGeneratedSubtitles }
        guard AppSettings.shared.enableSecondarySubtitlesBeta else { return false }
        guard menuTrackID != -1 else { return true }
        guard let track = secondarySubtitleTrack(for: menuTrackID) else { return false }
        return canSelectSecondarySubtitle(track)
    }

    var isNativeBitmapSecondarySubtitle: Bool {
        isUsingMPV && mpvSecondaryRendering?.isBitmap == true
    }

    var isNativeASSSecondarySubtitle: Bool {
        isUsingMPV && mpvSecondaryRendering?.rendersASSNatively(primary: effectiveCurrentSubtitleTrackID) == true
    }

    var isNativeRenderedSecondarySubtitle: Bool {
        isNativeBitmapSecondarySubtitle || isNativeASSSecondarySubtitle
    }

    private func nativeSecondaryRendering(for track: EmbeddedSubtitleTrack) -> MPVSecondarySubtitleRendering? {
        guard playbackCapabilities.supports(.secondaryBitmap,
            isVideo: state.currentItem.map { resolvedPlaybackItemType(for: $0) == .video } ?? false),
              let id = track.primaryTrackID else { return nil }
        return MPVSecondarySubtitleRendering(trackID: id, tracks: mpvState?.tracks ?? [])
    }

    private func canSelectSecondarySubtitle(_ track: EmbeddedSubtitleTrack) -> Bool {
        if let rendering = nativeSecondaryRendering(for: track), rendering.isBitmap {
            return rendering.canSelect(primary: effectiveCurrentSubtitleTrackID)
        }
        return track.isSelectable
    }

    func secondarySubtitleTrackDetail(_ menuID: Int) -> String? {
        guard let track = secondarySubtitleTrack(for: menuID),
              let rendering = nativeSecondaryRendering(for: track), rendering.isBitmap else { return nil }
        return NSLocalizedString(rendering.canSelect(primary: effectiveCurrentSubtitleTrackID)
            ? "MPV.BitmapPositionHint" : "MPV.BitmapPrimaryConflict", comment: "")
    }

    func updateSecondarySubtitleLayout(for size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        mpvSecondaryLayoutOrientation = AppSettings.SecondarySubtitleLayoutOrientation.resolved(for: size)
        updateMPVSecondaryRendering()
    }

    private func secondarySubtitleMenuID(_ track: EmbeddedSubtitleTrack, index: Int) -> Int {
        if track.source == .remoteContainer, let nativeID = track.primaryTrackID,
           let id = IOSMPVRemoteSubtitleSelection.menuID(trackID: nativeID) { return id }
        return secondarySubtitleTrackBaseID + index
    }

    private func secondarySubtitleTrack(for menuID: Int) -> EmbeddedSubtitleTrack? {
        if let nativeID = IOSMPVRemoteSubtitleSelection.trackID(menuID: menuID) {
            return state.secondarySubtitleTracks.first { $0.source == .remoteContainer && $0.primaryTrackID == nativeID }
        }
        guard menuID >= secondarySubtitleTrackBaseID else { return nil }
        let index = menuID - secondarySubtitleTrackBaseID
        guard state.secondarySubtitleTracks.indices.contains(index),
              state.secondarySubtitleTracks[index].source != .remoteContainer else { return nil }
        return state.secondarySubtitleTracks[index]
    }

    private func secondarySubtitleDisplayName(for track: EmbeddedSubtitleTrack) -> String {
        if let primaryTrackID = track.primaryTrackID,
           let primaryTrack = state.subtitleTracks.first(where: { $0.id == primaryTrackID && $0.id != -1 }),
           (isUsingMPV || secondarySubtitleNamesLikelyMatch(track.displayName, primaryTrack.name)) {
            return primaryTrack.name
        }

        if track.isExternal,
           let sourceURL = track.sourceURL {
            let sourceKey = subtitleURLKey(sourceURL)
            if let primaryTrack = state.subtitleTracks.first(where: { primaryTrack in
                guard primaryTrack.id != -1,
                      primaryTrack.isExternal || isExternalSubtitleTrack(primaryTrack.id),
                      let primaryURL = externalSubtitleURL(forTrackID: primaryTrack.id) else {
                    return false
                }
                return subtitleURLKey(primaryURL) == sourceKey
            }) {
                return primaryTrack.name
            }
        }

        return track.displayName
    }

    private func applySecondarySubtitleTrack(
        _ track: EmbeddedSubtitleTrack,
        persistPreference: Bool
    ) {
        stopMPVDecodedSecondary()
        state.currentSecondarySubtitleTrackID = track.id
        state.secondarySubtitleStatus = .loading
        state.secondarySubtitleParts = []
        secondarySubtitleTimeline = nil

        if persistPreference,
           let item = state.currentItem {
            pendingSecondaryHandoff = nil
            if isUsingMPV {
                mpvPendingTrackChoices["secondary"] = nil
                if let nativeID = track.primaryTrackID, nativeSecondaryRendering(for: track) != nil {
                    mpvTrackChoices["secondary"] = MacMPVTrackChoice.selected(nativeID, in: mpvState?.tracks.filter { $0.type == "sub" } ?? [])
                } else {
                    mpvTrackChoices["secondary"] = nil
                }
                if let data = try? JSONEncoder().encode(mpvTrackChoices) {
                    UserDefaults.standard.set(data, forKey: mpvTrackPreferenceKey)
                }
            }
            // Remote mpv-only menu ordinals must not become VLC second-subtitle preferences.
            if track.source != .remoteContainer, nativeSecondaryRendering(for: track)?.isBitmap != true {
                saveStoredSecondarySubtitlePreference(for: item, track: track)
            }
        }

        loadSecondarySubtitleTimeline(for: track)
    }

    private func restorePendingSecondarySubtitleSelectionIfNeeded() {
        guard subtitleIntelligence.secondaryID == -1 else { return }
        guard AppSettings.shared.enableSecondarySubtitlesBeta else {
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            return
        }

        guard state.currentSecondarySubtitleTrackID == nil else {
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            return
        }

        if let handoff = pendingSecondaryHandoff {
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            mpvPendingTrackChoices["secondary"] = nil
            if handoff.selection == .off {
                pendingSecondaryHandoff = nil
                return
            }
            let ids = state.subtitleTracks.filter { $0.id >= 0 && !$0.isExternal && !isExternalSubtitleTrack($0.id) }.map(\.id)
            let selectedID = handoff.resolve(candidates: state.secondarySubtitleTracks.map {
                .init(id: $0.id, sourceURL: $0.sourceURL, nativeID: $0.primaryTrackID)
            }, embeddedIDs: ids)
            let selected = state.secondarySubtitleTracks.first { $0.id == selectedID }
            if let selected, nativeSecondaryRendering(for: selected)?.canSelect(primary: effectiveCurrentSubtitleTrackID) == false {
                pendingSecondaryHandoff = nil
                return
            }
            if let selected, canSelectSecondarySubtitle(selected) {
                pendingSecondaryHandoff = nil
                applySecondarySubtitleTrack(selected, persistPreference: false)
            }
            // Wait for metadata/sidecars. Never replace an explicit choice with another language.
            return
        }

        if isUsingMPV, let choice = mpvPendingTrackChoices["secondary"] {
            let native = mpvState?.tracks.filter { $0.type == "sub" && !mpvRemovedDuplicateSubtitles.contains($0.id) } ?? []
            guard let nativeID = choice.resolveExternalAlias(mpvNativeSubtitleAliases()) ?? choice.resolve(in: native) else {
                // Wait for the loaded track list, then leave ambiguous/removed tracks unselected.
                if mpvLoaded {
                    mpvPendingTrackChoices["secondary"] = nil
                    pendingSecondarySubtitleTrackQuery = nil
                    pendingSecondarySubtitleTrackOrdinal = nil
                }
                return
            }
            if nativeID < 0 {
                mpvPendingTrackChoices["secondary"] = nil
                pendingSecondarySubtitleTrackQuery = nil
                pendingSecondarySubtitleTrackOrdinal = nil
                return
            }
            guard let track = state.secondarySubtitleTracks.first(where: { $0.primaryTrackID == nativeID }) else { return }
            if nativeSecondaryRendering(for: track)?.canSelect(primary: effectiveCurrentSubtitleTrackID) == false {
                mpvPendingTrackChoices["secondary"] = nil
                pendingSecondarySubtitleTrackQuery = nil
                pendingSecondarySubtitleTrackOrdinal = nil
                return
            }
            guard canSelectSecondarySubtitle(track) else { return }
            mpvPendingTrackChoices["secondary"] = nil
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            applySecondarySubtitleTrack(track, persistPreference: false)
            return
        }

        let selectableTracks = state.secondarySubtitleTracks.filter { $0.isSelectable }
        guard !selectableTracks.isEmpty else { return }

        if let query = pendingSecondarySubtitleTrackQuery,
           let matched = selectableTracks.first(where: {
               secondarySubtitleNamesLikelyMatch(secondarySubtitleDisplayName(for: $0), query) ||
               secondarySubtitleNamesLikelyMatch($0.displayName, query)
           }) {
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            applySecondarySubtitleTrack(matched, persistPreference: false)
            return
        }

        if let ordinal = pendingSecondarySubtitleTrackOrdinal,
           ordinal >= 0,
           ordinal < selectableTracks.count {
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            applySecondarySubtitleTrack(selectableTracks[ordinal], persistPreference: false)
            return
        }

        if pendingSecondarySubtitleTrackQuery != nil || pendingSecondarySubtitleTrackOrdinal != nil {
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
        }
    }

    func clearSecondarySubtitleTrack(persistPreference: Bool = false) {
        secondarySubtitleLoadTask?.cancel()
        secondarySubtitleLoadTask = nil
        secondarySubtitleTimeline = nil
        stopMPVDecodedSecondary()
        state.currentSecondarySubtitleTrackID = nil
        state.secondarySubtitleStatus = .disabled
        state.secondarySubtitleParts = []

        if persistPreference,
           let item = state.currentItem {
            pendingSecondaryHandoff = nil
            if isUsingMPV {
                mpvPendingTrackChoices["secondary"] = nil
                mpvTrackChoices["secondary"] = MacMPVTrackChoice.selected(-1, in: [])
                if let data = try? JSONEncoder().encode(mpvTrackChoices) {
                    UserDefaults.standard.set(data, forKey: mpvTrackPreferenceKey)
                }
            }
            saveStoredSecondarySubtitlePreference(for: item, track: nil)
        }
    }

    func refreshSecondarySubtitleTracks() {
        defer { refreshIntelligentPrimarySubtitle() }
        guard let item = state.currentItem else {
            state.secondarySubtitleTracks = []
            clearSecondarySubtitleTrack()
            return
        }

        // History can supply downloaded subtitles before PlaybackInfo arrives.
        // Reconcile again when metadata is refreshed, even if mpv's track list did not change.
        if isUsingMPV, let snapshot = mpvState {
            reconcileMPVSubtitleSources()
            state.subtitleTracks = [MediaTrack(id: -1, name: NSLocalizedString("Off", comment: ""), isExternal: false)]
                + snapshot.tracks.filter { $0.type == "sub" && !mpvRemovedDuplicateSubtitles.contains($0.id) }.map {
                    MediaTrack(id: $0.id, name: mpvSubtitleDisplayName($0), isExternal: $0.external)
                }
            resolveMPVPendingExternalSubtitle()
        }
        let previousSelection = state.secondarySubtitleTracks.first { $0.id == state.currentSecondarySubtitleTrackID }
        let tracks = availableSecondarySubtitleTracks(for: item)
        let tracksChanged = state.secondarySubtitleTracks != tracks
        if tracksChanged {
            state.secondarySubtitleTracks = tracks
        }

        if let selectedID = state.currentSecondarySubtitleTrackID {
            if !tracks.contains(where: { $0.id == selectedID }) {
                // Late server metadata replaces a generic native candidate with a server candidate.
                if isUsingMPV, let nativeID = previousSelection?.primaryTrackID,
                   let replacement = tracks.first(where: { $0.primaryTrackID == nativeID }) {
                    applySecondarySubtitleTrack(replacement, persistPreference: false)
                } else {
                    clearSecondarySubtitleTrack()
                }
            } else if tracksChanged, let track = tracks.first(where: { $0.id == selectedID && $0.source == .remoteContainer }) {
                applySecondarySubtitleTrack(track, persistPreference: false)
            }
        }

        restorePendingSecondarySubtitleSelectionIfNeeded()
    }

    func setSecondarySubtitleDelay(_ seconds: Double) {
        let clamped = min(max(seconds, -10.0), 10.0)
        guard abs(state.secondarySubtitleDelay - clamped) > 0.001 else { return }
        state.secondarySubtitleDelay = clamped
        updateMPVSecondaryDelay()
        updateCurrentSecondarySubtitleParts(at: state.currentTime)
    }

    private func loadSecondarySubtitleTimeline(for track: EmbeddedSubtitleTrack) {
        secondarySubtitleLoadTask?.cancel()
        if let rendering = nativeSecondaryRendering(for: track), rendering.isBitmap || rendering.isASS {
            mpvDecodedSecondaryID = rendering.trackID
            mpvSecondaryRendering = rendering
            mpvDecodedSecondary.select("\(playbackAttemptID)|\(rendering.trackID)")
            secondarySubtitleTimeline = nil
            state.secondarySubtitleStatus = .loading
            configureMPVDecodedSecondary()
            return // Native output must survive text/index reads; browsing loads on demand.
        }
        // Decode immediately for playback. Prefer a readable full timeline when it finishes.
        let hasDecodedFallback = startMPVDecodedSecondary(for: track)

        if track.source == .remoteContainer {
            loadRemoteSecondarySubtitleTimeline(for: track)
            return
        }

        guard let sourceURL = track.sourceURL else {
            if hasDecodedFallback { return }
            state.secondarySubtitleStatus = .unsupported
            state.secondarySubtitleParts = []
            return
        }

        let cacheKey = secondarySubtitleTimelineCacheKey(for: track)
        if let cachedTimeline = cachedSecondarySubtitleTimeline(for: cacheKey) {
            stopMPVDecodedSecondary()
            secondarySubtitleTimeline = cachedTimeline
            state.secondarySubtitleStatus = .ready
            updateCurrentSecondarySubtitleParts(at: state.currentTime)
            return
        }

        let currentItem = state.currentItem
        let itemID = currentItem?.id
        let attemptID = playbackAttemptID
        secondarySubtitleLoadTask = Task { [weak self] in
            guard let self else { return }

            do {
                let readableURL: URL
                if track.source == .localContainer {
                    guard let currentItem,
                          let trackIndex = track.streamIndex else {
                        throw NSError(domain: "LocalEmbeddedSubtitleExtractor", code: -1)
                    }
                    readableURL = try await LocalEmbeddedSubtitleExtractor.extractSubtitle(
                        from: currentItem.url,
                        trackIndex: trackIndex,
                        outputURL: sourceURL
                    )
                } else if sourceURL.isFileURL {
                    readableURL = sourceURL
                } else if let cachedURL = await self.cacheRemoteSubtitleToLocalIfNeeded(sourceURL) {
                    readableURL = cachedURL
                } else {
                    throw NSError(domain: "VLCPlaybackService.SecondarySubtitle", code: -1)
                }

                let parts = try SubtitleModel.loadParts(
                    from: readableURL,
                    format: self.subtitleParserFormat(for: track)
                )
                let timeline = SubtitleTimeline(parts: parts)
                try Task.checkCancellation()
                await MainActor.run {
                    guard !Task.isCancelled, self.playbackAttemptID == attemptID,
                          self.state.currentItem?.id == itemID,
                          self.state.currentSecondarySubtitleTrackID == track.id else { return }
                    self.stopMPVDecodedSecondary()
                    self.storeSecondarySubtitleTimeline(timeline, for: cacheKey)
                    self.secondarySubtitleTimeline = timeline
                    self.state.secondarySubtitleStatus = .ready
                    self.updateCurrentSecondarySubtitleParts(at: self.state.currentTime)
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled, self.playbackAttemptID == attemptID,
                          self.state.currentItem?.id == itemID,
                          self.state.currentSecondarySubtitleTrackID == track.id else { return }
                    if self.mpvDecodedSecondaryID != nil { return }
                    self.state.secondarySubtitleStatus = .failed
                    self.state.secondarySubtitleParts = []
                    self.secondarySubtitleTimeline = nil
                    print("[Subtitle] Failed to parse secondary subtitle: \(error.localizedDescription)")
                }
            }
        }
    }

    private func loadRemoteSecondarySubtitleTimeline(for track: EmbeddedSubtitleTrack) {
        guard let item = state.currentItem, let nativeID = track.primaryTrackID,
              let source = remoteMPVSubtitleSource(item: item, selectedID: nativeID, secondaryTrackID: track.id, offset: 0) else {
            if mpvDecodedSecondaryID == nil { state.secondarySubtitleStatus = .unsupported }
            return
        }
        let attempt = playbackAttemptID
        secondarySubtitleLoadTask = Task { @MainActor [weak self] in
            do {
                let document = try await source.load()
                try Task.checkCancellation()
                guard let self, self.playbackAttemptID == attempt, self.isUsingMPV,
                      AppSettings.shared.enableSecondarySubtitlesBeta,
                      self.state.currentSecondarySubtitleTrackID == track.id else { return }
                // An index may omit cues: keep the native decoder available outside its coverage.
                if !document.isPartial { self.stopMPVDecodedSecondary() }
                self.secondarySubtitleTimeline = SubtitleTimeline(parts: document.entries.map {
                    SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text))
                })
                self.state.secondarySubtitleStatus = .ready
                self.updateCurrentSecondarySubtitleParts(at: self.state.currentTime)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError), let self,
                      self.playbackAttemptID == attempt, self.isUsingMPV,
                      self.state.currentSecondarySubtitleTrackID == track.id else { return }
                if self.mpvDecodedSecondaryID != nil { return }
                self.state.secondarySubtitleStatus = .failed
                self.state.secondarySubtitleParts = []
                self.secondarySubtitleTimeline = nil
            }
        }
    }

    private func secondarySubtitleTimelineCacheKey(for track: EmbeddedSubtitleTrack) -> String {
        [
            track.source.rawValue,
            track.id,
            track.sourceURL.map(subtitleURLKey) ?? "no-url",
            track.codec ?? "unknown"
        ].joined(separator: "|")
    }

    private func cachedSecondarySubtitleTimeline(for key: String) -> SubtitleTimeline? {
        guard let timeline = secondarySubtitleTimelineCache[key] else { return nil }
        secondarySubtitleTimelineCacheOrder.removeAll { $0 == key }
        secondarySubtitleTimelineCacheOrder.append(key)
        return timeline
    }

    private func storeSecondarySubtitleTimeline(_ timeline: SubtitleTimeline, for key: String) {
        secondarySubtitleTimelineCache[key] = timeline
        secondarySubtitleTimelineCacheOrder.removeAll { $0 == key }
        secondarySubtitleTimelineCacheOrder.append(key)

        while secondarySubtitleTimelineCacheOrder.count > secondarySubtitleTimelineCacheLimit {
            let evictedKey = secondarySubtitleTimelineCacheOrder.removeFirst()
            secondarySubtitleTimelineCache.removeValue(forKey: evictedKey)
        }
    }

    internal func updateCurrentSecondarySubtitleParts(at time: TimeInterval) {
        subtitleIntelligence.updateTime(time)
        if !AppSettings.shared.enableSecondarySubtitlesBeta, subtitleIntelligence.secondaryID != -1 {
            subtitleIntelligence.selectSecondary(-1)
        }
        guard AppSettings.shared.enableSecondarySubtitlesBeta else {
            if mpvDecodedSecondaryID != nil || state.secondarySubtitleTracks.contains(where: {
                $0.id == state.currentSecondarySubtitleTrackID && $0.source == .remoteContainer
            }) {
                clearSecondarySubtitleTrack()
            }
            if !state.secondarySubtitleParts.isEmpty {
                state.secondarySubtitleParts = []
            }
            return
        }

        if mpvDecodedSecondaryID != nil {
            syncMPVDecodedSecondary()
            return
        }

        guard let timeline = secondarySubtitleTimeline,
              state.secondarySubtitleStatus == .ready else {
            if !state.secondarySubtitleParts.isEmpty {
                state.secondarySubtitleParts = []
            }
            return
        }

        let effectiveTime = time
            + AppSettings.shared.subtitleDelaySeconds
            + state.secondarySubtitleDelay
        let parts = timeline.activeParts(at: effectiveTime)
        if state.secondarySubtitleParts != parts {
            state.secondarySubtitleParts = parts
        }
    }

    private func subtitleParserFormat(for track: EmbeddedSubtitleTrack) -> String {
        if let codec = track.codec?.lowercased() {
            if codec == "subrip" { return "srt" }
            if codec == "webvtt" { return "vtt" }
            if codec == "mov_text" || codec == "tx3g" { return "srt" }
            return codec
        }
        return track.sourceURL?.pathExtension.lowercased() ?? "srt"
    }

    private func isCurrentPrimarySubtitle(_ track: EmbeddedSubtitleTrack) -> Bool {
        if track.isExternal,
           let selectedExternalURL = state.currentItem?.externalSubtitleURL,
           let sourceURL = track.sourceURL,
           subtitleURLKey(selectedExternalURL) == subtitleURLKey(sourceURL) {
            return true
        }

        if let primaryTrackID = track.primaryTrackID,
           primaryTrackID == effectiveCurrentSubtitleTrackID {
            if isUsingMPV { return true }
            guard let primaryTrack = state.subtitleTracks.first(where: { $0.id == primaryTrackID && $0.id != -1 }) else {
                return true
            }
            return secondarySubtitleNamesLikelyMatch(track.displayName, primaryTrack.name)
        }

        return false
    }

    private func availableSecondarySubtitleTracks(for item: MediaItem) -> [EmbeddedSubtitleTrack] {
        let tracks = localContainerSecondarySubtitleTracks(for: item) +
            embeddedServerSubtitleTracks(for: item) +
            externalFileSecondarySubtitleTracks(for: item) +
            primaryExternalSecondarySubtitleTracks(for: item)
        var seenIDs = Set<String>()
        var seenURLKeys = Set<String>()
        var result: [EmbeddedSubtitleTrack] = []

        for track in tracks {
            if isUsingMPV, track.isExternal, let url = track.sourceURL,
               mpvEmbeddedServerSubtitle(for: url)?.primaryTrackID != nil {
                continue // The server's embedded candidate already represents this download URL.
            }
            guard seenIDs.insert(track.id).inserted else { continue }
            if let sourceURL = track.sourceURL {
                let key = subtitleURLKey(sourceURL)
                guard seenURLKeys.insert(key).inserted else { continue }
            }
            if let duplicateIndex = result.firstIndex(where: {
                secondarySubtitleTracksRepresentSameCandidate($0, track)
            }) {
                if shouldPreferSecondarySubtitleTrack(track, over: result[duplicateIndex]) {
                    result[duplicateIndex] = track
                }
                continue
            }
            result.append(track)
        }

        if isUsingMPV {
            for track in IOSMPVRemoteSubtitleSelection.playbackTracks(in: mpvState?.tracks ?? []) where !mpvRemovedDuplicateSubtitles.contains(track.id) {
                // Prefer existing local/server/sidecar sources when already mapped to this native ID.
                guard !result.contains(where: { $0.primaryTrackID == track.id }) else { continue }
                let name = mpvSubtitleDisplayName(track)
                result.append(EmbeddedSubtitleTrack(id: "ios.mpv.remote-subtitle.\(track.id).\(track.sourceID ?? 0)", source: .remoteContainer,
                    primaryTrackID: track.id, codec: track.codec, language: track.language, title: track.title,
                    displayName: name.isEmpty ? "\(NSLocalizedString("Subtitle", comment: "")) \(track.id)" : name,
                    supportLevel: track.isBitmap ? .unsupportedBitmap :
                        (IOSMPVRemoteSubtitleSelection.supportsText(codec: track.codec) ? .textBestEffort : .unsupportedUnknown)))
            }
        }
        return result
    }

    private func secondarySubtitleTracksLikelySame(_ lhs: EmbeddedSubtitleTrack, _ rhs: EmbeddedSubtitleTrack) -> Bool {
        if let leftURL = lhs.sourceURL,
           let rightURL = rhs.sourceURL,
           subtitleURLKey(leftURL) == subtitleURLKey(rightURL) {
            return true
        }

        return secondarySubtitleNamesLikelyMatch(lhs.displayName, rhs.displayName)
    }

    private func secondarySubtitleNamesLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedSecondarySubtitleName(lhs)
        let right = normalizedSecondarySubtitleName(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }

    private func normalizedSecondarySubtitleName(_ value: String) -> String {
        let lowered = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        return String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private func secondarySubtitleSupportRank(_ supportLevel: EmbeddedSubtitleSupportLevel) -> Int {
        switch supportLevel {
        case .textSupported:
            return 3
        case .textBestEffort:
            return 2
        case .unsupportedBitmap:
            return 1
        case .unsupportedUnknown:
            return 0
        }
    }

    private func shouldPreferSecondarySubtitleTrack(
        _ candidate: EmbeddedSubtitleTrack,
        over existing: EmbeddedSubtitleTrack
    ) -> Bool {
        let candidateRank = secondarySubtitleSupportRank(candidate.supportLevel)
        let existingRank = secondarySubtitleSupportRank(existing.supportLevel)
        if candidateRank != existingRank {
            return candidateRank > existingRank
        }
        if (candidate.sourceURL != nil) != (existing.sourceURL != nil) {
            return candidate.sourceURL != nil
        }
        if candidate.source == .externalFile && existing.source != .externalFile {
            return false
        }
        return false
    }

    private func secondarySubtitleTracksRepresentSameCandidate(
        _ lhs: EmbeddedSubtitleTrack,
        _ rhs: EmbeddedSubtitleTrack
    ) -> Bool {
        if let leftPrimary = lhs.primaryTrackID,
           let rightPrimary = rhs.primaryTrackID,
           leftPrimary != -1,
           rightPrimary != -1,
           leftPrimary == rightPrimary {
            return true
        }

        if secondarySubtitleTracksLikelySame(lhs, rhs) {
            if lhs.isExternal && rhs.isExternal {
                return true
            }
            if !lhs.isSelectable || !rhs.isSelectable {
                return true
            }
        }

        if let leftIndex = lhs.streamIndex,
           let rightIndex = rhs.streamIndex,
           leftIndex == rightIndex,
           lhs.source == rhs.source {
            return true
        }

        return false
    }

    private func localContainerSecondarySubtitleTracks(for item: MediaItem) -> [EmbeddedSubtitleTrack] {
        guard item.url.isFileURL else { return [] }

        let descriptors = localEmbeddedSubtitleDescriptors(for: item.url)
        guard !descriptors.isEmpty else { return [] }

        let nativeSubtitleTracks = state.subtitleTracks.filter { track in
            track.id != -1 &&
            !track.isExternal &&
            !isExternalSubtitleTrack(track.id)
        }
        let itemMediaKey = mediaKey(for: item.url) ?? item.url.standardizedFileURL.path

        return descriptors.map { descriptor in
            let primaryTrack: MediaTrack?
            if let mpvState {
                let mapped = mpvState.tracks.filter { $0.type == "sub" }.first { track in
                    MacMPVSubtitleMapping.ordinal(selectedID: track.id, tracks: mpvState.tracks,
                        descriptors: descriptors.map { ($0.codec, $0.language, $0.title) }) == descriptor.trackIndex
                }
                primaryTrack = mapped.flatMap { selected in nativeSubtitleTracks.first { $0.id == selected.id } }
            } else {
                primaryTrack = descriptor.trackIndex < nativeSubtitleTracks.count ? nativeSubtitleTracks[descriptor.trackIndex] : nil
            }
            let displayName = primaryTrack?.name ??
                localEmbeddedSubtitleDisplayName(for: descriptor, fallbackIndex: descriptor.trackIndex)
            let sourceURL = descriptor.supportLevel == .textSupported || descriptor.supportLevel == .textBestEffort
                ? localEmbeddedSubtitleOutputURL(
                    for: item.url,
                    trackIndex: descriptor.trackIndex,
                    codec: descriptor.codec
                )
                : nil
            let idParts = [
                EmbeddedSubtitleSource.localContainer.rawValue,
                itemMediaKey,
                "\(descriptor.trackIndex)",
                descriptor.codec ?? "unknown"
            ]

            return EmbeddedSubtitleTrack(
                id: idParts.joined(separator: "|"),
                source: .localContainer,
                streamIndex: descriptor.trackIndex,
                primaryTrackID: primaryTrack?.id,
                codec: descriptor.codec,
                language: descriptor.language,
                title: descriptor.title,
                displayName: displayName,
                sourceURL: sourceURL,
                supportLevel: descriptor.supportLevel,
                isExternal: false
            )
        }
    }

    private func localEmbeddedSubtitleDescriptors(for mediaURL: URL) -> [LocalEmbeddedSubtitleDescriptor] {
        let key = subtitleURLKey(mediaURL)
        if let cached = localEmbeddedSubtitleDescriptorCache[key] {
            return cached
        }

        let descriptors = LocalEmbeddedSubtitleExtractor.descriptors(for: mediaURL)
        localEmbeddedSubtitleDescriptorCache[key] = descriptors
        return descriptors
    }

    private func localEmbeddedSubtitleDisplayName(
        for descriptor: LocalEmbeddedSubtitleDescriptor,
        fallbackIndex: Int
    ) -> String {
        var parts: [String] = []
        if let title = descriptor.title, !title.isEmpty {
            parts.append(title)
        }
        if let language = descriptor.language, !language.isEmpty,
           !parts.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
            parts.append(language.uppercased())
        }
        if let codec = descriptor.codec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        if parts.isEmpty {
            return "\(NSLocalizedString("Subtitle", comment: "")) \(fallbackIndex + 1)"
        }
        return parts.joined(separator: " · ")
    }

    private func localEmbeddedSubtitleOutputURL(
        for mediaURL: URL,
        trackIndex: Int,
        codec: String?
    ) -> URL {
        let folder = subtitleCacheDirectory(named: "LocalEmbedded")
        let baseName = Self.sanitizedSnapshotMediaName(from: mediaURL.deletingPathExtension().lastPathComponent)
        let normalizedCodec = codec?.lowercased()
        let outputExtension: String
        switch normalizedCodec {
        case "ass":
            outputExtension = "ass"
        case "ssa":
            outputExtension = "ssa"
        case "webvtt", "vtt":
            outputExtension = "vtt"
        default:
            outputExtension = "srt"
        }
        let key = "\(subtitleURLKey(mediaURL))|\(trackIndex)|\(normalizedCodec ?? "unknown")"
        let hash = stableHashHex(for: key)
        return folder.appendingPathComponent("\(baseName)_track\(trackIndex + 1)_\(hash).\(outputExtension)")
    }

    private func primaryExternalSecondarySubtitleTracks(for item: MediaItem) -> [EmbeddedSubtitleTrack] {
        let itemMediaKey = mediaKey(for: item.url)

        return state.subtitleTracks.compactMap { track in
            guard track.id != -1,
                  track.isExternal || isExternalSubtitleTrack(track.id),
                  let url = externalSubtitleURL(forTrackID: track.id) else {
                return nil
            }

            if let externalSubtitleMediaKey,
               externalSubtitleMediaKey != itemMediaKey {
                return nil
            }

            let key = subtitleURLKey(url)
            let codec = cleanedEmbeddedSubtitleValue(url.pathExtension)
            let supportLevel = externalSubtitleSupportLevel(for: url, displayName: track.name)
            let idParts = [
                EmbeddedSubtitleSource.externalFile.rawValue,
                itemMediaKey ?? "unknown-media",
                "primary",
                key
            ]

            return EmbeddedSubtitleTrack(
                id: idParts.joined(separator: "|"),
                source: .externalFile,
                streamIndex: nil,
                primaryTrackID: track.id,
                codec: codec,
                language: nil,
                title: track.name,
                displayName: track.name,
                sourceURL: url,
                supportLevel: supportLevel,
                isExternal: true
            )
        }
    }

    private func embeddedServerSubtitleTracks(for item: MediaItem) -> [EmbeddedSubtitleTrack] {
        guard let streams = item.serverMediaStreams, !streams.isEmpty else { return [] }
        guard item.serverType == .jellyfin || item.serverType == .emby else { return [] }
        guard let server = embeddedSubtitleServer(for: item),
              let itemId = item.jellyfinItemId,
              !itemId.isEmpty else {
            return []
        }

        let token = embeddedSubtitleToken(for: item, server: server)
        let mediaSourceId = item.mediaSourceId ?? embeddedSubtitleMediaSourceID(from: item.url)
        let subtitleStreams = streams.filter { isSubtitleServerStream($0) }
        let nativeSubtitleTracks = state.subtitleTracks.filter { $0.id != -1 && !$0.isExternal }
        let source: EmbeddedSubtitleSource = item.serverType == .emby ? .embyMediaStream : .jellyfinMediaStream

        var nativeFallbackOffset = 0
        return subtitleStreams.enumerated().compactMap { offset, stream in
            guard let streamIndex = stream["Index"] as? Int else { return nil }

            let codec = cleanedEmbeddedSubtitleValue(stream["Codec"] as? String)
            let supportLevel = embeddedSubtitleSupportLevel(codec: codec, stream: stream)
            let sourceURL = embeddedSubtitleURL(
                server: server,
                itemId: itemId,
                mediaSourceId: mediaSourceId,
                streamIndex: streamIndex,
                codec: codec,
                deliveryURL: stream["DeliveryUrl"] as? String,
                token: token
            )
            let isExternal = embeddedSubtitleStreamIsExternal(stream)
            let nativeFallbackTrackID: Int?
            if isExternal {
                nativeFallbackTrackID = nil
            } else {
                nativeFallbackTrackID = nativeFallbackOffset < nativeSubtitleTracks.count
                    ? nativeSubtitleTracks[nativeFallbackOffset].id
                    : nil
                nativeFallbackOffset += 1
            }
            let exactPrimaryTrackID = !isUsingMPV && state.subtitleTracks.contains(where: { $0.id == streamIndex }) ? streamIndex : nil
            let urlPrimaryTrackID = isExternal ? sourceURL.flatMap(primaryExternalSubtitleTrackID(for:)) : nil
            let primaryTrackID: Int?
            if let mpvState, !isExternal {
                let descriptors = subtitleStreams.filter { !embeddedSubtitleStreamIsExternal($0) }
                primaryTrackID = mpvState.tracks.filter { $0.type == "sub" }.first { track in
                    MacMPVSubtitleMapping.ordinal(selectedID: track.id, tracks: mpvState.tracks,
                        descriptors: descriptors.map { ($0["Codec"] as? String, $0["Language"] as? String, $0["Title"] as? String) })
                        == descriptors.firstIndex { ($0["Index"] as? Int) == streamIndex }
                }?.id
            } else {
                primaryTrackID = isExternal ? (urlPrimaryTrackID ?? exactPrimaryTrackID) : (exactPrimaryTrackID ?? nativeFallbackTrackID)
            }
            let displayName = embeddedSubtitleDisplayName(stream: stream, fallbackIndex: offset)
            let idParts = [
                source.rawValue,
                itemId,
                mediaSourceId ?? "unknown-source",
                "\(streamIndex)",
                codec ?? "unknown"
            ]

            return EmbeddedSubtitleTrack(
                id: idParts.joined(separator: "|"),
                source: source,
                streamIndex: streamIndex,
                primaryTrackID: primaryTrackID,
                codec: codec,
                language: cleanedEmbeddedSubtitleValue(stream["Language"] as? String),
                title: cleanedEmbeddedSubtitleValue(stream["Title"] as? String),
                displayName: displayName,
                sourceURL: sourceURL,
                supportLevel: supportLevel,
                isExternal: isExternal
            )
        }
    }

    private func primaryExternalSubtitleTrackID(for sourceURL: URL) -> Int? {
        let key = subtitleURLKey(sourceURL)
        if let resolvedTrackID = externalSubtitleResolvedTrackIDs[key],
           state.subtitleTracks.contains(where: { $0.id == resolvedTrackID }) {
            return resolvedTrackID
        }

        if let syntheticTrackID = externalSubtitleTrackID(for: sourceURL),
           state.subtitleTracks.contains(where: { $0.id == syntheticTrackID }) {
            return syntheticTrackID
        }

        return nil
    }

    private func externalFileSecondarySubtitleTracks(for item: MediaItem) -> [EmbeddedSubtitleTrack] {
        guard externalSubtitleMediaKey == mediaKey(for: item.url),
              !externalSubtitleCandidates.isEmpty else {
            return []
        }

        return externalSubtitleCandidates.enumerated().map { offset, url in
            let key = subtitleURLKey(url)
            let resolvedTrackID = externalSubtitleResolvedTrackIDs[key]
            let primaryTrackID = resolvedTrackID ?? externalSubtitleTrackID(for: url)
            let codec = cleanedEmbeddedSubtitleValue(url.pathExtension)
            let displayName = externalSubtitleDisplayName(for: url, fallbackIndex: offset)
            let supportLevel = externalSubtitleSupportLevel(for: url, displayName: displayName)
            let idParts = [
                EmbeddedSubtitleSource.externalFile.rawValue,
                mediaKey(for: item.url) ?? "unknown-media",
                key
            ]

            return EmbeddedSubtitleTrack(
                id: idParts.joined(separator: "|"),
                source: .externalFile,
                streamIndex: nil,
                primaryTrackID: primaryTrackID,
                codec: codec,
                language: nil,
                title: displayName,
                displayName: displayName,
                sourceURL: url,
                supportLevel: supportLevel,
                isExternal: true
            )
        }
    }

    private func embeddedSubtitleServer(for item: MediaItem) -> ServerConfig? {
        let servers = AppNetworkService.shared.savedServers
        if let serverID = item.jellyfinServerId,
           let uuid = UUID(uuidString: serverID),
           let matched = servers.first(where: { $0.id == uuid }) {
            return matched
        }

        guard let host = item.url.host?.lowercased() else { return nil }
        return servers.first { server in
            guard server.type == item.serverType else { return false }
            return normalizeServerHost(server.fullURL) == host || normalizeServerHost(server.address) == host
        }
    }

    private func embeddedSubtitleToken(for item: MediaItem, server: ServerConfig) -> String {
        URLComponents(url: item.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("api_key") == .orderedSame })?
            .value
            ?? server.accessToken
            ?? ""
    }

    private func embeddedSubtitleMediaSourceID(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame })?
            .value
    }

    private func isSubtitleServerStream(_ stream: [String: Any]) -> Bool {
        let type = ((stream["Type"] as? String) ?? "").lowercased()
        return type == "subtitle" || type.contains("subtitle") || type.contains("caption")
    }

    private func embeddedSubtitleStreamIsExternal(_ stream: [String: Any]) -> Bool {
        if let value = stream["IsExternal"] as? Bool {
            return value
        }
        if let value = stream["IsExternal"] as? NSNumber {
            return value.boolValue
        }
        if let value = stream["IsExternal"] as? String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "true" || normalized == "1" || normalized == "yes"
        }
        return false
    }

    private func embeddedSubtitleSupportLevel(
        codec: String?,
        stream: [String: Any]
    ) -> EmbeddedSubtitleSupportLevel {
        if (stream["IsTextSubtitleStream"] as? Bool) == true {
            return .textSupported
        }

        switch codec?.lowercased() {
        case "srt", "subrip", "webvtt", "vtt", "mov_text", "tx3g":
            return .textSupported
        case "ass", "ssa":
            return .textBestEffort
        case "pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "vobsub", "dvbsub", "dvb_subtitle":
            return .unsupportedBitmap
        default:
            return .unsupportedUnknown
        }
    }

    private func externalSubtitleSupportLevel(for url: URL, displayName: String? = nil) -> EmbeddedSubtitleSupportLevel {
        var ext = url.pathExtension.lowercased()
        
        func isSupported(_ format: String) -> Bool {
            let f = format.lowercased()
            return ["srt", "vtt", "webvtt", "subrip", "ass", "ssa", "sub"].contains(f)
        }
        
        if !isSupported(ext) {
            if let path = url.path.components(separatedBy: "/").last?.lowercased() {
                if let dotRange = path.range(of: ".", options: .backwards) {
                    let pathExt = String(path[dotRange.upperBound...])
                    if isSupported(pathExt) {
                        ext = pathExt
                    }
                }
            }
        }
        
        if !isSupported(ext) {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                if let formatQuery = components.queryItems?.first(where: { $0.name.lowercased() == "format" || $0.name.lowercased() == "codec" })?.value?.lowercased() {
                    if isSupported(formatQuery) {
                        ext = formatQuery
                    }
                }
            }
        }
        
        if !isSupported(ext), let displayName = displayName?.lowercased() {
            if displayName.contains("ass") || displayName.contains("ssa") {
                ext = "ass"
            } else if displayName.contains("srt") || displayName.contains("subrip") {
                ext = "srt"
            } else if displayName.contains("vtt") || displayName.contains("webvtt") {
                ext = "vtt"
            } else if displayName.contains("sub") {
                ext = "sub"
            }
        }
        
        switch ext {
        case "srt", "vtt", "webvtt", "subrip":
            return .textSupported
        case "ass", "ssa", "sub":
            return .textBestEffort
        case "pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "vobsub", "dvbsub", "dvb_subtitle":
            return .unsupportedBitmap
        default:
            return .unsupportedUnknown
        }
    }

    private func embeddedSubtitleURL(
        server: ServerConfig,
        itemId: String,
        mediaSourceId: String?,
        streamIndex: Int,
        codec: String?,
        deliveryURL: String?,
        token: String
    ) -> URL? {
        if let deliveryURL = cleanedEmbeddedSubtitleValue(deliveryURL),
           let resolvedURL = resolvedEmbeddedSubtitleDeliveryURL(server: server, rawValue: deliveryURL, token: token) {
            return resolvedURL
        }

        guard let mediaSourceId, !mediaSourceId.isEmpty else { return nil }
        let ext = embeddedSubtitleExportExtension(codec: codec)
        let tokenQuery = token.isEmpty ? "" : "?api_key=\(token)"
        return URL(string: "\(server.fullURL)/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(streamIndex)/Stream.\(ext)\(tokenQuery)")
    }

    private func resolvedEmbeddedSubtitleDeliveryURL(
        server: ServerConfig,
        rawValue: String,
        token: String
    ) -> URL? {
        let absoluteString: String
        if rawValue.hasPrefix("http://") || rawValue.hasPrefix("https://") {
            absoluteString = rawValue
        } else if rawValue.hasPrefix("/") {
            absoluteString = "\(server.fullURL)\(rawValue)"
        } else {
            absoluteString = "\(server.fullURL)/\(rawValue)"
        }

        guard var components = URLComponents(string: absoluteString) else { return nil }
        if !token.isEmpty,
           components.queryItems?.contains(where: { $0.name.caseInsensitiveCompare("api_key") == .orderedSame }) != true {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "api_key", value: token))
            components.queryItems = items
        }
        return components.url
    }

    private func embeddedSubtitleExportExtension(codec: String?) -> String {
        switch codec?.lowercased() {
        case "srt", "subrip":
            return "srt"
        case "webvtt", "vtt":
            return "vtt"
        case "ass":
            return "ass"
        case "ssa":
            return "ssa"
        case "mov_text", "tx3g":
            return "srt"
        default:
            return "srt"
        }
    }

    private func embeddedSubtitleDisplayName(stream: [String: Any], fallbackIndex: Int) -> String {
        var parts: [String] = []
        [
            stream["DisplayTitle"] as? String,
            stream["Title"] as? String,
            stream["DisplayLanguage"] as? String,
            stream["Language"] as? String
        ].forEach { value in
            guard let cleaned = cleanedEmbeddedSubtitleValue(value) else { return }
            if !parts.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
                parts.append(cleaned)
            }
        }

        if (stream["IsDefault"] as? Bool) == true {
            parts.append(NSLocalizedString("Default", comment: ""))
        }
        if (stream["IsForced"] as? Bool) == true {
            parts.append(NSLocalizedString("Forced", comment: ""))
        }
        if let codec = cleanedEmbeddedSubtitleValue(stream["Codec"] as? String) {
            parts.append(codec.uppercased())
        }

        if parts.isEmpty {
            return "\(NSLocalizedString("Subtitle", comment: "")) \(fallbackIndex + 1)"
        }
        return parts.joined(separator: " · ")
    }

    private func cleanedEmbeddedSubtitleValue(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }
        let lowered = cleaned
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let placeholders: Set<String> = ["und", "undefined", "unknown", "undetermined", "n/a", "na", "none", "null"]
        return placeholders.contains(lowered) ? nil : cleaned
    }
    

    func setSubtitleDelay(_ seconds: Double) {
        let clamped = min(max(seconds, -10.0), 10.0)
        guard abs(AppSettings.shared.subtitleDelaySeconds - clamped) > 0.001 else { return }
        AppSettings.shared.subtitleDelaySeconds = clamped
        if let mpvEngine {
            mpvEngine.set("sub-delay", String(clamped))
            updateMPVSecondaryDelay()
            updateCurrentSecondarySubtitleParts(at: state.currentTime)
            return
        }
        reloadCurrentItemPreservingPlaybackState()
    }

    func setSecondarySubtitlePlacement(_ placement: AppSettings.SecondarySubtitlePlacement) {
        let hadCustomPosition =
            AppSettings.shared.secondarySubtitleVerticalPositionRatio(for: .portrait) != nil ||
            AppSettings.shared.secondarySubtitleVerticalPositionRatio(for: .landscape) != nil
        guard AppSettings.shared.secondarySubtitlePlacement != placement || hadCustomPosition else { return }
        AppSettings.shared.secondarySubtitlePlacement = placement
        AppSettings.shared.clearSecondarySubtitleVerticalPositionRatios()
        secondarySubtitlePlacement = placement
        secondarySubtitlePortraitVerticalPositionRatio = nil
        secondarySubtitleLandscapeVerticalPositionRatio = nil
        updateMPVSecondaryRendering()
    }

    func secondarySubtitleVerticalPositionRatio(
        for orientation: AppSettings.SecondarySubtitleLayoutOrientation
    ) -> Double? {
        switch orientation {
        case .portrait:
            return secondarySubtitlePortraitVerticalPositionRatio
        case .landscape:
            return secondarySubtitleLandscapeVerticalPositionRatio
        }
    }

    func setSecondarySubtitleSizeScale(_ scale: AppSettings.SecondarySubtitleSizeScale) {
        AppSettings.shared.secondarySubtitleSizeScale = scale
        updateMPVSecondaryRendering()
    }

    func setSecondarySubtitleVerticalPositionRatio(
        _ ratio: Double,
        for orientation: AppSettings.SecondarySubtitleLayoutOrientation
    ) {
        AppSettings.shared.setSecondarySubtitleVerticalPositionRatio(ratio, for: orientation)
        secondarySubtitlePortraitVerticalPositionRatio =
            AppSettings.shared.secondarySubtitleVerticalPositionRatio(for: .portrait)
        secondarySubtitleLandscapeVerticalPositionRatio =
            AppSettings.shared.secondarySubtitleVerticalPositionRatio(for: .landscape)
        updateMPVSecondaryRendering()
    }
    
    func setExternalSubtitleCandidates(for mediaURL: URL, urls: [URL], autoSelectFirst: Bool = true) {
        externalSubtitleMediaKey = mediaKey(for: mediaURL)
        externalSubtitleCandidates = uniqueSubtitleURLs(urls)
        let candidateKeys = Set(externalSubtitleCandidates.map { subtitleURLKey($0) })
        externalSubtitleDisplayNames = externalSubtitleDisplayNames.filter { candidateKeys.contains($0.key) }
        normalizedExternalSubtitleCache = normalizedExternalSubtitleCache.filter { candidateKeys.contains($0.key) }
        externalSubtitleResolvedTrackIDs = externalSubtitleResolvedTrackIDs.filter { candidateKeys.contains($0.key) }
        
        if externalSubtitleCandidates.isEmpty {
            if mediaKey(for: state.currentItem?.url) == externalSubtitleMediaKey {
                state.currentItem?.externalSubtitleURL = nil
                if isExternalSubtitleTrack(state.currentSubtitleTrackID) {
                    state.currentSubtitleTrackID = Int((mediaPlayer?.currentVideoSubTitleIndex ?? -1))
                }
            }
            refreshTracks()
            return
        }
        
        if autoSelectFirst, mediaKey(for: state.currentItem?.url) == externalSubtitleMediaKey {
            let currentURL = state.currentItem?.externalSubtitleURL
            let selectedURL: URL
            if let currentURL, externalSubtitleCandidates.contains(where: { subtitleURLKey($0) == subtitleURLKey(currentURL) }) {
                selectedURL = currentURL
            } else if let preferred = preferredExternalSubtitleURL(for: mediaURL) {
                selectedURL = preferred
            } else {
                selectedURL = externalSubtitleCandidates[0]
            }
            state.currentItem?.externalSubtitleURL = selectedURL
            if let trackID = externalSubtitleTrackID(for: selectedURL) {
                state.currentSubtitleTrackID = trackID
            }

            // VLC-iOS style: pre-cache remote sidecar subtitle to local file for stable loading.
            if state.currentItem?.isRemote == true, !selectedURL.isFileURL {
                Task { [weak self] in
                    guard let self else { return }
                    _ = await self.cacheRemoteSubtitleToLocalIfNeeded(selectedURL)
                }
            }
        }
        
        if isUsingMPV, mediaKey(for: state.currentItem?.url) == externalSubtitleMediaKey {
            for url in externalSubtitleCandidates { attachMPVSubtitle(url) }
            if autoSelectFirst { mpvPendingExternalSubtitle = state.currentItem?.externalSubtitleURL }
            resolveMPVPendingExternalSubtitle()
            return
        }
        refreshTracks()
    }

    func setExternalSubtitleCandidates(
        for mediaURL: URL,
        candidates: [ExternalSubtitleCandidate],
        autoSelectFirst: Bool = true
    ) {
        let uniqueCandidates = uniqueExternalSubtitleCandidates(candidates)
        externalSubtitleDisplayNames = Dictionary(
            uniqueKeysWithValues: uniqueCandidates.map { (subtitleURLKey($0.url), $0.displayName) }
        )
        setExternalSubtitleCandidates(
            for: mediaURL,
            urls: uniqueCandidates.map(\.url),
            autoSelectFirst: autoSelectFirst
        )
        if isUsingMPV, mediaKey(for: mediaURL) == mediaKey(for: state.currentItem?.url), let snapshot = mpvState {
            state.subtitleTracks = [MediaTrack(id: -1, name: NSLocalizedString("Off", comment: ""), isExternal: false)]
                + snapshot.tracks.filter { $0.type == "sub" && !mpvRemovedDuplicateSubtitles.contains($0.id) }.map {
                    MediaTrack(id: $0.id, name: mpvSubtitleDisplayName($0), isExternal: $0.external)
                }
        }
    }
    
    func preferredExternalSubtitleURL(for mediaURL: URL) -> URL? {
        guard mediaKey(for: mediaURL) == externalSubtitleMediaKey, !externalSubtitleCandidates.isEmpty else { return nil }
        if let currentURL = state.currentItem?.externalSubtitleURL,
           externalSubtitleCandidates.contains(where: { subtitleURLKey($0) == subtitleURLKey(currentURL) }) {
            return currentURL
        }
        return externalSubtitleCandidates[0]
    }
    
    // MARK: - Configuration

    enum MediaConfigurationPurpose: Equatable {
        case playback
        case seekPreview
    }

    private func resolvedDecoderPreference(_ requested: AppSettings.VideoDecoder) -> AppSettings.VideoDecoder {
#if targetEnvironment(simulator)
        if requested != .software {
            print("[VLC] Simulator detected, forcing software decoding for video playback.")
        }
        return .software
#else
        return requested
#endif
    }
    
    internal func configureMediaOptions(
        _ media: VLCMedia,
        for item: MediaItem,
        purpose: MediaConfigurationPurpose = .playback
    ) {
        // Keep subtitle rendering enabled; disable VLC auto sidecar detection when we already manage candidates.
        if purpose == .seekPreview {
            media.addOption(":no-audio")
            media.addOption(":sub-autodetect-file=0")
            media.addOption(":input-fast-seek")
        } else {
            let hasManagedExternalCandidates =
                externalSubtitleMediaKey == mediaKey(for: item.url) && !externalSubtitleCandidates.isEmpty
            media.addOption(":sub-autodetect-file=\(hasManagedExternalCandidates ? 0 : 1)")
            media.addOption(":subsdec-autodetect-utf8=1")

            let subtitleDelay = AppSettings.shared.subtitleDelaySeconds
            if abs(subtitleDelay) > 0.001 {
                media.addOption(":sub-delay=\(subtitleDelay)")
                media.addOption(":spu-delay=\(Int(subtitleDelay * 1_000_000))")
            }

            let audioDelayMs = Int(AppSettings.shared.audioDelaySeconds * 1000)
            if audioDelayMs != 0 {
                media.addOption(":audio-desync=\(audioDelayMs)")
            }

            let selectedExternalSubtitleURL = item.externalSubtitleURL ?? state.currentItem?.externalSubtitleURL
            var usesNormalizedExternalSubtitle = false
            if let externalSubtitleURL = selectedExternalSubtitleURL {
                let subtitleURLForPlayback = normalizedExternalSubtitleURL(for: externalSubtitleURL)
                usesNormalizedExternalSubtitle =
                    subtitleURLForPlayback.isFileURL &&
                    subtitleURLForPlayback.path.contains("/NormalizedSubtitles/")
                media.addOption(":sub-file=\(subtitleURLForPlayback.absoluteString)")

                // Keep SMB credential options for fallback (when subtitle URL is still remote SMB).
                if let scheme = externalSubtitleURL.scheme?.lowercased(),
                   scheme == "smb",
                   let components = URLComponents(url: externalSubtitleURL, resolvingAgainstBaseURL: false) {
                    if let user = components.user, !user.isEmpty {
                        media.addOption(":smb-user=\(user)")
                    }
                    if let pwd = components.password, !pwd.isEmpty {
                        media.addOption(":smb-pwd=\(pwd)")
                    }
                }
            }

            if usesNormalizedExternalSubtitle {
                // External sidecar was normalized to UTF-8 locally; force UTF-8 decoding in VLC.
                media.addOption(":subsdec-encoding=UTF-8")
                media.addOption(":subsdec-autodetect-utf8=1")
            } else {
                media.addOption(":subsdec-autodetect-utf8=1")
            }
        }
        
        // Remote seek previews should return quickly and do not need playback-grade buffering.
        if item.isRemote {
            let cachingMs: Int
            if purpose == .seekPreview {
                cachingMs = 900
            } else if item.serverType?.requiresDynamicPlaybackURL == true {
                cachingMs = item.videoFile?.type == .audio ? 750 : 1200
            } else {
                cachingMs = 3000
            }
            media.addOption(":network-caching=\(cachingMs)")
            media.addOption(":live-caching=\(cachingMs)")
            media.addOption(":file-caching=\(cachingMs)")
            
            if item.serverType == .pan115 || (item.url.host?.contains("115.com") == true) {
                media.addOption(":http-user-agent=\(Pan115Manager.defaultUserAgent)")
                media.addOption(":http-referrer=https://115.com")
                let server = (item.jellyfinServerId.flatMap { sid in AppNetworkService.shared.savedServers.first(where: { $0.id.uuidString == sid }) })
                    ?? item.videoFile?.resolvedServer
                    ?? AppNetworkService.shared.savedServers.first(where: { $0.type == .pan115 })
                if let cookie = server?.passwordSecret ?? server?.accessToken, !cookie.isEmpty {
                    media.addOption(":http-cookie=\(cookie)")
                    media.addOption(":http-cookies=\(cookie)")
                }
            } else if item.serverType == .vod {
                media.addOption(":http-user-agent=\(VODService.defaultUserAgent)")
            }
        }
        
        // Reduce audio sync delay on resume (does not affect cache size)
        media.addOption(":clock-jitter=0")
        media.addOption(":clock-synchro=0")
        
        // Hardware / Software decoding configuration
        switch resolvedDecoderPreference(currentDecoder) {
        case .hardware:
            media.addOption(":avcodec-hw=any")
        case .software:
            media.addOption(":avcodec-hw=none")
            media.addOption(":codec=avcodec")
        }
    }

    private func makeConfiguredMedia(
        for item: MediaItem,
        runtimePlaybackURL: URL? = nil,
        purpose: MediaConfigurationPurpose = .playback
    ) -> VLCMedia {
        let resolvedRuntimeURL = runtimePlaybackURL ?? RuntimeNetworkAddressResolver.runtimeURL(from: item.url)

        // For SMB: VLC's libdsm doesn't decode percent-encoded passwords (e.g. %40 for @),
        // so strip credentials from URL and pass them via :smb-user/:smb-pwd options instead.
        if item.url.scheme == "smb",
           var components = URLComponents(url: resolvedRuntimeURL, resolvingAgainstBaseURL: false),
           components.user != nil {
            let decodedUser = components.user
            let decodedPassword = components.password

            components.user = nil
            components.password = nil

            let cleanURL = components.url ?? resolvedRuntimeURL
            let media = VLCMedia(url: cleanURL)
            configureMediaOptions(media, for: item, purpose: purpose)

            if let user = decodedUser {
                media.addOption(":smb-user=\(user)")
            }
            if let password = decodedPassword {
                media.addOption(":smb-pwd=\(password)")
            }

            return media
        }

        let media = VLCMedia(url: resolvedRuntimeURL)
        configureMediaOptions(media, for: item, purpose: purpose)
        return media
    }

    private func seekPreviewCacheKeys(
        for item: MediaItem,
        targetTime: Double,
        explicitFrameIntervalSeconds: Double? = nil
    ) -> [String] {
        var cacheKeys: [String] = []
        if item.isRemote,
           let frameBucket = remoteSeekPreviewFrameBucket(
                for: targetTime,
                explicitFrameIntervalSeconds: explicitFrameIntervalSeconds
           ) {
            cacheKeys.append("seek-preview|\(item.id.uuidString)|remote|\(frameBucket)")
        }

        let roundedTimeBucket = Int((max(targetTime, 0) * 2).rounded())
        cacheKeys.append("seek-preview|\(item.id.uuidString)|\(roundedTimeBucket)")
        return cacheKeys
    }

    private func cachedSeekPreviewThumbnail(forKeys cacheKeys: [String]) -> UIImage? {
        for cacheKey in cacheKeys {
            if let cachedImage = seekPreviewThumbnailCache.object(forKey: cacheKey as NSString) {
                return cachedImage
            }
        }
        return nil
    }

    private func cacheSeekPreviewThumbnail(_ image: UIImage, forKeys cacheKeys: [String]) {
        for cacheKey in Set(cacheKeys) {
            seekPreviewThumbnailCache.setObject(image, forKey: cacheKey as NSString)
        }
    }

    private func remoteSeekPreviewFrameBucket(
        for targetTime: Double,
        explicitFrameIntervalSeconds: Double? = nil
    ) -> Int? {
        let frameIntervalSeconds = explicitFrameIntervalSeconds ?? remoteSeekPreviewFrameIntervalSeconds
        guard let frameIntervalSeconds,
              frameIntervalSeconds > 0.25 else {
            return nil
        }
        return Int(floor(max(targetTime, 0) / frameIntervalSeconds))
    }

    private func seekPreviewWarmupBucket(
        for targetTime: Double,
        explicitFrameIntervalSeconds: Double? = nil
    ) -> Int {
        if let frameBucket = remoteSeekPreviewFrameBucket(
            for: targetTime,
            explicitFrameIntervalSeconds: explicitFrameIntervalSeconds
        ) {
            return frameBucket
        }
        return Int((targetTime / 15.0).rounded(.down))
    }
    

    
    // Register once for both engines. Reopening a player must not switch fonts
    // just because CoreText reports that the bundled font is already registered.
    private static let subtitleTypography = IOSSubtitleTypography(
        fontURL: Bundle.main.url(forResource: "SourceHanSansSC-Regular", withExtension: "otf")
    )

    private func configureTextRenderer(for player: VLCMediaPlayer?) {
        guard let player else { return }
        let fontSelector = NSSelectorFromString("setTextRendererFont:")
        if player.responds(to: fontSelector) {
            player.perform(fontSelector, with: Self.subtitleTypography.fontFamily)
        }

        let fontSizeSelector = NSSelectorFromString("setTextRendererFontSize:")
        if player.responds(to: fontSizeSelector) {
            player.perform(fontSizeSelector, with: preferredSubtitleRendererFontSize())
        }
    }

    private func preferredSubtitleRendererFontSize() -> NSNumber {
        // This VLCKit property is a relative divisor, not a point size.
        if UIDevice.current.userInterfaceIdiom == .pad {
            return 22
        }

        let shorterSide = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let scaledSize = max(17.0, min(20.0, round(shorterSide * 0.048)))
        return NSNumber(value: Double(scaledSize))
    }
    
    private func finishAudioSessionActivation() {
        setupVolumeObservation()
        UIApplication.shared.beginReceivingRemoteControlEvents()
    }

    private func deactivateAudioSessionIfPossible(reason: String, force: Bool = false) {
        let shouldKeepSessionActive = !force && (
            (mediaPlayer?.isPlaying ?? false) || isVideoPiPActive || isAudioFloatingVisible ||
            state.status == .playing || state.status == .buffering
        )
        guard !shouldKeepSessionActive else { return }
        UIApplication.shared.endReceivingRemoteControlEvents()
        audioSessionCoordinator.deactivate { success in
            print("[AudioSession] deactivation reason=\(reason) success=\(success)")
        }
    }

    func prepareAudioSessionForPictureInPictureStart() {
        if audioSessionCoordinator.activateSynchronously() {
            finishAudioSessionActivation()
        } else {
            print("[AudioSession] PiP activation failed")
        }
    }

    func isCurrentPlaybackControl(attemptID: UUID, controlID: UUID) -> Bool {
        playbackAttemptID == attemptID && playbackControlID == controlID &&
            state.currentItem != nil && !isStopInProgress &&
            !hasTerminalPlaybackFailure && !isPlaybackSuspendedForBackground
    }

    private func invalidatePendingPlaybackControls() {
        playbackControlID = UUID()
        pendingResumeControlID = nil
        isRecoveringFromFalseEnded = false
        pendingMetadataWorkItem?.cancel()
        pendingMetadataWorkItem = nil
    }

    private func deferPreparedPlaybackForBackground(retry: @escaping () -> Void) -> Bool {
        guard isPlaybackSuspendedForBackground ||
            (UIApplication.shared.applicationState == .background &&
             !AppSettings.shared.shouldPlayInBackground && !isVideoPiPActive) else { return false }
        isPreparingPlayback = false
        isPlaybackSuspendedForBackground = true
        state.status = .paused
        stopStartupWatchdog()
        deferredBackgroundPlayback = retry
        return true
    }

    func reloadCurrentItemForMPVPictureInPicture() -> Bool {
        guard isUsingMPV, let item = state.currentItem,
              resolvedPlaybackItemType(for: item) == .video else { return false }
        playbackEngineOverride = "mpv" // Preserve this item's running engine, not the global default.
        reloadCurrentItemPreservingPlaybackState(in: nil, bindToExistingPlayerView: false)
        return true
    }

    func reloadCurrentItemPreservingPlaybackState(
        in view: UIView? = nil,
        bindToExistingPlayerView: Bool = true,
        preparePlayer: ((VLCMediaPlayer) throws -> Void)? = nil,
        switchingEngine: Bool = false
    ) {
        guard var currentItem = state.currentItem else { return }
        
        let returningToMPV = (playbackEngineOverride ?? UserDefaults.standard.string(forKey: "iosPlaybackEngine")) == "mpv" &&
            MPVUIKitPlaybackPolicy.supports(url: currentItem.url,
                isVideo: resolvedPlaybackItemType(for: currentItem) == .video, isAudio: resolvedPlaybackItemType(for: currentItem) == .audio, requiresVLCBridge: preparePlayer != nil)
        let preserveTracks = switchingEngine || isUsingMPV || preparePlayer != nil || returningToMPV
        let selections = PlaybackSelectionSnapshot(embedded: preserveTracks ? captureEngineTracks() : [:],
            primarySourceURL: preserveTracks && !subtitleIntelligence.isGeneratedPrimary
                ? externalSubtitleURL(forTrackID: effectiveCurrentSubtitleTrackID) : nil,
            secondary: preserveTracks ? captureSecondaryTrackHandoff() : nil)
        let snapshot = PlaybackSessionSnapshot(position: preferredResumeTime(), duration: state.duration,
            paused: state.status == .paused || (isUsingMPV && mpvPauseRequested), rate: state.rate, selections: selections)
        let wasPaused = snapshot.paused
        let preservedAspectRatio = state.aspectRatio
        let preservedDisplayMode = state.videoDisplayMode
        let preservedZoom = state.interactiveVideoZoomScale
        let preservedOffset = state.interactiveVideoOffset
        let preservedTime = snapshot.position
        let preservedDuration = snapshot.duration
        if switchingEngine || isUsingMPV { currentItem.startPosition = max(0, preservedTime) }
        let engineTracks = snapshot.selections.embedded
        let secondaryHandoff = snapshot.selections.secondary
        if engineTracks["sub"] != nil { currentItem.externalSubtitleURL = nil }
        if preserveTracks,
           !subtitleIntelligence.isGeneratedPrimary,
           let external = snapshot.selections.primarySourceURL {
            currentItem.externalSubtitleURL = external
            // A selected sidecar supersedes an older stored Off/language choice.
            currentItem.preferredSubtitleTrackQuery = external.lastPathComponent
            currentItem.preferredSubtitleTrackOrdinal = nil
        }
        if preservedTime > 1.0 {
            currentItem.startPosition = preservedTime
            pendingPlaybackResumeTimeGuard = preservedTime
            pendingPlaybackResumeTimeGuardDeadline = Date().timeIntervalSinceReferenceDate + 3.5
        }
        currentItem.savedAudioTrackIndex = isUsingMPV ? nil : state.currentAudioTrackID
        currentItem.savedSubtitleTrackIndex = isUsingMPV ? nil : state.currentSubtitleTrackID
        
        sessionPlaybackRate = snapshot.rate
        let resolvedView = view ?? (bindToExistingPlayerView ? playerView : nil)
        play(
            item: currentItem,
            in: resolvedView,
            bindToExistingPlayerView: bindToExistingPlayerView,
            startPaused: wasPaused,
            engineTracks: engineTracks,
            secondaryHandoff: secondaryHandoff,
            preserveSubtitleIntelligence: preserveTracks,
            preparePlayer: preparePlayer
        )
        // A decoder/core/PiP rebuild is still the same presentation and media session.
        setAspectRatio(preservedAspectRatio)
        state.videoDisplayMode = preservedDisplayMode
        state.interactiveVideoZoomScale = preservedZoom
        state.interactiveVideoOffset = preservedOffset
        if preservedDuration > 0 {
            state.duration = preservedDuration
            state.currentTime = preservedTime
            state.progress = Float(max(0.0, min(1.0, preservedTime / preservedDuration)))
        }
    }

    internal func isExternalSubtitleTrack(_ id: Int) -> Bool {
        id >= externalSubtitleTrackBaseID || externalSubtitleResolvedTrackIDs.values.contains(id)
    }

    private func captureSecondaryTrackHandoff() -> IOSPlaybackSecondarySelection {
        // A temporary VLC/PiP session may have no readable equivalent. Keep
        // the requested track for the return trip; explicit user choices clear it.
        if let pendingSecondaryHandoff { return pendingSecondaryHandoff }
        guard let id = state.currentSecondarySubtitleTrackID,
              let track = state.secondarySubtitleTracks.first(where: { $0.id == id }) else {
            return .init(selection: .off, sourceURL: nil, descriptorID: nil)
        }
        let ids = state.subtitleTracks.filter { $0.id >= 0 && !$0.isExternal && !isExternalSubtitleTrack($0.id) }.map(\.id)
        let selection = track.primaryTrackID.flatMap { IOSPlaybackTrackSelection.capture(id: $0, embeddedIDs: ids) }
        return .init(selection: selection, sourceURL: track.sourceURL, descriptorID: track.id)
    }

    private func captureEngineTracks() -> [String: IOSPlaybackTrackSelection] {
        var result = pendingEngineTracks
        if !state.audioTracks.isEmpty {
            result["audio"] = IOSPlaybackTrackSelection.capture(id: state.currentAudioTrackID,
                embeddedIDs: state.audioTracks.filter { $0.id >= 0 && !$0.isExternal }.map(\.id))
        }
        if !subtitleIntelligence.isGeneratedPrimary,
           !state.subtitleTracks.isEmpty || result["sub"] == nil {
            result["sub"] = IOSPlaybackTrackSelection.capture(id: effectiveCurrentSubtitleTrackID,
                embeddedIDs: state.subtitleTracks.filter {
                    $0.id >= 0 && !$0.isExternal && !isExternalSubtitleTrack($0.id)
                }.map(\.id))
        }
        return result
    }

    internal func restoreVLCEngineTracks() {
        for type in ["audio", "sub"] {
            guard let selection = pendingEngineTracks[type] else { continue }
            let tracks = type == "audio" ? state.audioTracks : state.subtitleTracks
            let ids = tracks.filter {
                $0.id >= 0 && !$0.isExternal && (type == "audio" || !isExternalSubtitleTrack($0.id))
            }.map(\.id)
            guard let id = selection.resolve(embeddedIDs: ids) else { continue }
            pendingEngineTracks[type] = nil
            if type == "audio" {
                pendingAudioTrack = id
            } else {
                pendingSubtitleTrack = id
                hasResolvedAutomaticSubtitleSelection = true
            }
        }
    }

    private func refreshEngineTracksAfterOpening(attemptID: UUID, remaining: Int = 20) {
        // Paused input may not emit advancing time callbacks. Bound retries and
        // bind each callback to its attempt so switching/closing cannot revive it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.playbackAttemptID == attemptID, !self.isUsingMPV,
                  !self.isStopInProgress, !self.hasTerminalPlaybackFailure,
                  !self.pendingEngineTracks.isEmpty else { return }
            self.refreshTracks()
            if !self.hasStartedPlaybackForCurrentItem && self.mediaPlayer?.state != .paused {
                // Network opening can outlast ten seconds; start the bounded
                // matching window only after the input is actually ready.
                self.refreshEngineTracksAfterOpening(attemptID: attemptID, remaining: remaining)
                return
            }
            if remaining > 1 {
                self.refreshEngineTracksAfterOpening(attemptID: attemptID, remaining: remaining - 1)
            } else {
                // A changed/incomplete container must not be guessed by numeric ID.
                self.pendingEngineTracks = [:]
            }
        }
    }
    
    internal func externalSubtitleURL(forTrackID id: Int) -> URL? {
        if id >= externalSubtitleTrackBaseID {
            let index = id - externalSubtitleTrackBaseID
            guard index >= 0, index < externalSubtitleCandidates.count else { return nil }
            return externalSubtitleCandidates[index]
        }

        if let url = mpvState?.tracks.first(where: { $0.type == "sub" && $0.id == id })?.externalURL { return url }
        guard let key = externalSubtitleResolvedTrackIDs.first(where: { $1 == id })?.key else {
            return nil
        }
        return externalSubtitleCandidates.first { subtitleURLKey($0) == key }
    }
    
    internal func externalSubtitleTrackID(for url: URL) -> Int? {
        let key = subtitleURLKey(url)
        guard let index = externalSubtitleCandidates.firstIndex(where: { subtitleURLKey($0) == key }) else { return nil }
        return externalSubtitleTrackBaseID + index
    }
    
    internal func mediaKey(for url: URL?) -> String? {
        guard let url else { return nil }
        return url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }
    
    internal func subtitleURLKey(_ url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    internal func externalSubtitleDisplayName(for url: URL, fallbackIndex: Int? = nil) -> String {
        let key = subtitleURLKey(url)
        if let displayName = externalSubtitleDisplayNames[key], !displayName.isEmpty {
            return displayName
        }

        let fileName = url.deletingPathExtension().lastPathComponent
        if !fileName.isEmpty {
            return fileName
        }

        if let fallbackIndex {
            return "\(NSLocalizedString("Subtitle", comment: "")) \(fallbackIndex + 1)"
        }
        return NSLocalizedString("Subtitle", comment: "")
    }

    private func cacheRemoteSubtitleToLocalIfNeeded(_ originalURL: URL) async -> URL? {
        // Bind credentials before suspension; a later media switch must not select another server.
        let sourceServer = await MainActor.run { resolveServerForSubtitle(originalURL) }
        let key = subtitleURLKey(originalURL)

        if let cached = await MainActor.run(body: { normalizedExternalSubtitleCache[key] }),
           cached.isFileURL,
           FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }

        let scheme = originalURL.scheme?.lowercased()
        guard scheme == "smb" || scheme == "http" || scheme == "https" else {
            return nil
        }

        let localURL = remoteSubtitleOutputURL(for: originalURL, key: key)
        if localURL.isFileURL,
           let fileSize = try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           fileSize > 0 {
            await MainActor.run {
                normalizedExternalSubtitleCache[key] = localURL
            }
            return localURL
        }

        do {
            let downloadedURL: URL
            if let server = sourceServer {
                let path: String
                if server.type == .jellyfin || server.type == .emby || server.type == .plex {
                    path = originalURL.absoluteString
                } else {
                    path = originalURL.path.removingPercentEncoding ?? originalURL.path
                }
                guard !path.isEmpty else { return nil }
                downloadedURL = try await AppNetworkService.shared.downloadFile(server: server, at: path)
            } else {
                let request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: originalURL))
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    return nil
                }
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(originalURL.pathExtension.isEmpty ? "sub" : originalURL.pathExtension)
                try data.write(to: tempURL, options: .atomic)
                downloadedURL = tempURL
            }

            let fm = FileManager.default
            try fm.createDirectory(at: localURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: localURL.path) {
                try fm.removeItem(at: localURL)
            }
            try fm.copyItem(at: downloadedURL, to: localURL)

            await MainActor.run {
                normalizedExternalSubtitleCache[key] = localURL
            }
            return localURL
        } catch {
            print("[Subtitle] Failed to cache remote subtitle: \(error)")
            return nil
        }
    }

    private func resolveServerForSubtitle(_ subtitleURL: URL) -> ServerConfig? {
        let servers = AppNetworkService.shared.savedServers
        if let serverID = state.currentItem?.jellyfinServerId,
           let uuid = UUID(uuidString: serverID),
           let matched = servers.first(where: { $0.id == uuid }) {
            return matched
        }

        guard let host = subtitleURL.host?.lowercased() else { return nil }
        return servers.first { server in
            normalizeServerHost(server.address) == host
        }
    }

    private func normalizeServerHost(_ rawAddress: String) -> String {
        var address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if address.hasPrefix("smb://") { address.removeFirst("smb://".count) }
        if address.hasPrefix("http://") { address.removeFirst("http://".count) }
        if address.hasPrefix("https://") { address.removeFirst("https://".count) }
        if let slashIndex = address.firstIndex(of: "/") {
            address = String(address[..<slashIndex])
        }
        if let colonIndex = address.firstIndex(of: ":") {
            address = String(address[..<colonIndex])
        }
        return address
    }

    private func remoteSubtitleOutputURL(for originalURL: URL, key: String) -> URL {
        let folder = subtitleCacheDirectory(named: "Remote")
        let baseName = Self.sanitizedSnapshotMediaName(from: originalURL.deletingPathExtension().lastPathComponent)
        let ext = originalURL.pathExtension.isEmpty ? "sub" : originalURL.pathExtension
        let hash = stableHashHex(for: key)
        return folder.appendingPathComponent("\(baseName)_\(hash).\(ext)")
    }

    private func subtitleCacheDirectory(named folderName: String) -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("Subtitles", isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }
    
    private func normalizedExternalSubtitleURL(for originalURL: URL) -> URL {
        let key = subtitleURLKey(originalURL)
        if let cached = normalizedExternalSubtitleCache[key] {
            if cached.isFileURL, !FileManager.default.fileExists(atPath: cached.path) {
                normalizedExternalSubtitleCache.removeValue(forKey: key)
            } else {
                return cached
            }
        }

        if let scheme = originalURL.scheme?.lowercased(),
           scheme == "smb",
           var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false),
           components.user != nil {
            components.user = nil
            components.password = nil
            let sanitizedURL = components.url ?? originalURL
            normalizedExternalSubtitleCache[key] = sanitizedURL
            return sanitizedURL
        }

        if let cached = normalizedExternalSubtitleCache[key] {
            return cached
        }
        
        guard originalURL.isFileURL else {
            normalizedExternalSubtitleCache[key] = originalURL
            return originalURL
        }
        
        guard let data = try? Data(contentsOf: originalURL), !data.isEmpty else {
            normalizedExternalSubtitleCache[key] = originalURL
            return originalURL
        }
        
        guard let decodedText = decodeExternalSubtitleText(data: data) else {
            normalizedExternalSubtitleCache[key] = originalURL
            return originalURL
        }
        
        var normalizedText = decodedText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalizedText.hasPrefix("\u{FEFF}") {
            normalizedText.removeFirst()
        }
        
        guard let normalizedData = normalizedText.data(using: .utf8) else {
            normalizedExternalSubtitleCache[key] = originalURL
            return originalURL
        }
        
        let outputURL = normalizedSubtitleOutputURL(for: originalURL, key: key)
        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try normalizedData.write(to: outputURL, options: .atomic)
            normalizedExternalSubtitleCache[key] = outputURL
            return outputURL
        } catch {
            print("[Subtitle] Failed to normalize subtitle encoding: \(error)")
            normalizedExternalSubtitleCache[key] = originalURL
            return originalURL
        }
    }
    
    private func decodeExternalSubtitleText(data: Data) -> String? {
        var candidates: [String.Encoding] = []
        if let bom = bomDetectedEncoding(in: data) {
            candidates.append(bom)
        }
        
        candidates.append(contentsOf: [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .unicode,
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))),
            String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.shiftJIS.rawValue))),
            .windowsCP1252
        ])
        
        var deduped: [String.Encoding] = []
        var seen = Set<UInt>()
        for encoding in candidates {
            if seen.insert(encoding.rawValue).inserted {
                deduped.append(encoding)
            }
        }
        
        var bestText: String?
        var bestScore = Int.min
        for encoding in deduped {
            guard let text = String(data: data, encoding: encoding), !text.isEmpty else { continue }
            let score = subtitleDecodeScore(for: text, using: encoding)
            if score > bestScore {
                bestScore = score
                bestText = text
            }
        }
        
        guard bestScore >= 0 else {
            return nil
        }
        
        return bestText
    }
    
    private func subtitleDecodeScore(
        for text: String,
        using encoding: String.Encoding
    ) -> Int {
        if text.isEmpty {
            return Int.min
        }
        
        var score = 0
        if text.contains("-->") { score += 30 }
        if text.localizedCaseInsensitiveContains("Dialogue:") { score += 30 }
        if text.localizedCaseInsensitiveContains("WEBVTT") { score += 20 }
        
        let lineCount = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
        if lineCount >= 3 { score += 10 }
        
        let replacementCount = text.filter { $0 == "\u{FFFD}" }.count
        score -= replacementCount * 40
        
        var controlCharCount = 0
        for scalar in text.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar),
               scalar != "\n",
               scalar != "\r",
               scalar != "\t" {
                controlCharCount += 1
            }
        }
        score -= controlCharCount * 8
        
        let totalScalars = max(text.unicodeScalars.count, 1)
        let printableScalars = text.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) || scalar == "\n" || scalar == "\r" || scalar == "\t"
        }.count
        let printableRatio = Double(printableScalars) / Double(totalScalars)
        if printableRatio > 0.97 {
            score += 15
        } else if printableRatio < 0.90 {
            score -= 15
        }
        
        return score
    }
    
    private func bomDetectedEncoding(in data: Data) -> String.Encoding? {
        if data.count >= 3,
           data[data.startIndex] == 0xEF,
           data[data.startIndex + 1] == 0xBB,
           data[data.startIndex + 2] == 0xBF {
            return .utf8
        }
        
        if data.count >= 2 {
            let first = data[data.startIndex]
            let second = data[data.startIndex + 1]
            if first == 0xFF && second == 0xFE {
                return .utf16LittleEndian
            }
            if first == 0xFE && second == 0xFF {
                return .utf16BigEndian
            }
        }
        
        return nil
    }
    
    private func normalizedSubtitleOutputURL(for originalURL: URL, key: String) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("NormalizedSubtitles", isDirectory: true)
        let baseName = Self.sanitizedSnapshotMediaName(from: originalURL.deletingPathExtension().lastPathComponent)
        let ext = originalURL.pathExtension.isEmpty ? "srt" : originalURL.pathExtension
        let hash = stableHashHex(for: key)
        return folder.appendingPathComponent("\(baseName)_\(hash).\(ext)")
    }
    
    private func stableHashHex(for input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(format: "%016llx", hash)
    }
    
    private func uniqueSubtitleURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls {
            let key = subtitleURLKey(url)
            if seen.insert(key).inserted {
                result.append(url)
            }
        }
        return result
    }

    private func uniqueExternalSubtitleCandidates(_ candidates: [ExternalSubtitleCandidate]) -> [ExternalSubtitleCandidate] {
        var seen = Set<String>()
        var result: [ExternalSubtitleCandidate] = []
        for candidate in candidates {
            let key = subtitleURLKey(candidate.url)
            if seen.insert(key).inserted {
                result.append(candidate)
            }
        }
        return result
    }
    
    private func captureSnapshotImage(
        persistToDisk: Bool,
        allowOffscreenViewCapture: Bool = true
    ) -> UIImage? {
        guard !isUsingMPV, let view = snapshotSourceView() else { return nil }
        let isViewVisibleForSnapshot = view.window != nil &&
            view.superview != nil &&
            !view.isHidden &&
            view.alpha > 0.01
        if !allowOffscreenViewCapture, !isViewVisibleForSnapshot {
            return nil
        }
        let bounds = view.bounds.integral
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = UIScreen.main.scale
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        let image = renderer.image { context in
            if isViewVisibleForSnapshot {
                if !view.drawHierarchy(in: bounds, afterScreenUpdates: false) {
                    view.layer.render(in: context.cgContext)
                }
            } else {
                view.layer.render(in: context.cgContext)
            }
        }
        
        let videoRect = Self.visibleVideoRect(
            containerSize: bounds.size,
            naturalVideoSize: videoNaturalSize,
            aspectRatioOverride: state.aspectRatio,
            displayMode: state.videoDisplayMode
        )
        
        let compositedImage = compositeSecondarySubtitlesIfNeeded(on: image, videoRect: videoRect)
        let croppedImage = cropImageToVideoRect(compositedImage, videoRect: videoRect)
        
        if persistToDisk, !saveSnapshotImageToDisk(croppedImage) {
            return nil
        }
        return croppedImage
    }

    private struct PiPSubtitleOverlayKey: Equatable {
        let size: CGSize
        let primary: [NSAttributedString]
        let secondary: [NSAttributedString]
        let scale: Double
        let position: Double?
    }
    private var pipSubtitleOverlayKey: PiPSubtitleOverlayKey?
    private var pipSubtitleOverlayImage: CGImage?

    func clearPictureInPictureSubtitleOverlay() {
        pipSubtitleOverlayKey = nil
        pipSubtitleOverlayImage = nil
    }

    /// Renders only existing application subtitle text, never captures a view/video
    /// or starts generation/translation. Native primary, ASS and bitmap subtitles are in the frame.
    func pictureInPictureSubtitleOverlay(size: CGSize) -> CGImage? {
        let primary = subtitleIntelligence.isGeneratedPrimary ? displayedPrimarySubtitleParts : []
        let secondary = isNativeRenderedSecondarySubtitle ? [] : currentSecondarySubtitleParts
        let orientation = AppSettings.SecondarySubtitleLayoutOrientation.resolved(for: size)
        let key = PiPSubtitleOverlayKey(size: size,
            primary: primary.compactMap(\.text).map { NSAttributedString(attributedString: $0) },
            secondary: secondary.compactMap(\.text).map { NSAttributedString(attributedString: $0) },
            scale: Double(AppSettings.shared.secondarySubtitleSizeScale.rawValue),
            position: secondarySubtitleVerticalPositionRatio(for: orientation))
        if pipSubtitleOverlayKey == key { return pipSubtitleOverlayImage }
        pipSubtitleOverlayKey = key
        guard !primary.isEmpty || !secondary.isEmpty else {
            pipSubtitleOverlayImage = nil
            return nil
        }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let rect = CGRect(origin: .zero, size: size)
        let blank = UIGraphicsImageRenderer(size: size, format: format).image { $0.cgContext.clear(rect) }
        var overlay = compositeSecondarySubtitlesIfNeeded(on: blank, videoRect: rect, partsOverride: secondary)
        if !primary.isEmpty {
            overlay = compositeSecondarySubtitlesIfNeeded(on: overlay, videoRect: rect, partsOverride: primary, primary: true)
        }
        pipSubtitleOverlayImage = overlay.cgImage
        return pipSubtitleOverlayImage
    }

    private func compositeSecondarySubtitlesIfNeeded(on image: UIImage, videoRect: CGRect,
                                                   partsOverride: [SubtitlePart]? = nil, primary: Bool = false) -> UIImage {
        guard primary || AppSettings.shared.enableSecondarySubtitlesBeta else { return image }
        let parts = partsOverride ?? currentSecondarySubtitleParts
        guard !parts.isEmpty else { return image }
        
        let size = image.size
        guard size.width > 0, size.height > 0 else { return image }
        
        let textParts = parts.compactMap { part -> NSAttributedString? in
            guard let attributedText = part.text else { return nil }
            let text = attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let isDrawingCommand = text.hasPrefix("m ") ||
                (text.contains(" m ") && text.range(of: #"[0-9\-\s]+$"#, options: .regularExpression) != nil)
            return isDrawingCommand ? nil : attributedText
        }
        guard !textParts.isEmpty else { return image }
        
        let effectiveVideoRect = (videoRect.width > 0 && videoRect.height > 0) ? videoRect : CGRect(origin: .zero, size: size)
        
        let orientation = AppSettings.SecondarySubtitleLayoutOrientation.resolved(for: size)
        let baseFontSize: CGFloat
        switch orientation {
        case .portrait:
            baseFontSize = min(max(effectiveVideoRect.width * 0.036, 13), 16)
        case .landscape:
            baseFontSize = min(max(effectiveVideoRect.height * 0.056, 18), 34)
        }
        let fontSize = baseFontSize * CGFloat(AppSettings.shared.secondarySubtitleSizeScale.rawValue)
        
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        
        return renderer.image { context in
            image.draw(in: CGRect(origin: .zero, size: size))
            let maxTextWidth = max(100, effectiveVideoRect.width - 32)
            
            let subY: CGFloat
            if let customRatio = secondarySubtitleVerticalPositionRatio(for: orientation) {
                subY = effectiveVideoRect.height * CGFloat(customRatio)
            } else {
                let reservedPrimarySubtitleHeight: CGFloat = 72
                let bottomBase: CGFloat = 20
                subY = effectiveVideoRect.height - max(bottomBase + reservedPrimarySubtitleHeight, 92)
            }
            let clampedY = min(max(subY, 32), max(32, effectiveVideoRect.height - 32))
            let centerY = effectiveVideoRect.minY + clampedY
            let centerX = effectiveVideoRect.midX
            let labels = textParts.map {
                SubtitleTextView.snapshotLabel(
                    attributedText: $0,
                    fontSize: fontSize,
                    maximumWidth: maxTextWidth
                )
            }
            let totalHeight = labels.reduce(CGFloat(0)) { $0 + $1.bounds.height } +
                CGFloat(max(0, labels.count - 1)) * 2
            var currentY = primary ? effectiveVideoRect.maxY - 20 - totalHeight : centerY - totalHeight / 2

            for label in labels {
                let drawRect = CGRect(
                    x: centerX - label.bounds.width / 2,
                    y: currentY,
                    width: label.bounds.width,
                    height: label.bounds.height
                )
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: drawRect.minX, y: drawRect.minY)
                label.drawText(in: label.bounds)
                context.cgContext.restoreGState()
                currentY += label.bounds.height + 2
            }
        }
    }

    private func captureSnapshotImageForPiP(maxWidth: CGFloat) -> UIImage? {
        guard let view = snapshotSourceView() else { return nil }
        guard view.window != nil, view.superview != nil, !view.isHidden, view.alpha > 0.01 else { return nil }
        let bounds = view.bounds.integral
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let aspect = bounds.height / bounds.width
        let targetWidth = min(maxWidth, bounds.width)
        let targetSize = CGSize(width: targetWidth, height: (targetWidth * aspect).rounded())
        let targetBounds = CGRect(origin: .zero, size: targetSize)
        let renderer = UIGraphicsImageRenderer(bounds: targetBounds, format: format)
        return renderer.image { context in
            let scaleX = targetSize.width / bounds.width
            let scaleY = targetSize.height / bounds.height
            context.cgContext.scaleBy(x: scaleX, y: scaleY)
            view.layer.render(in: context.cgContext)
        }
    }

    private func captureVisibleSnapshotImageForPiPStartup(maxWidth: CGFloat) -> UIImage? {
        guard let image = captureSnapshotImage(persistToDisk: false, allowOffscreenViewCapture: false) else { return nil }
        return scaledPictureInPictureImage(from: image, maxWidth: maxWidth)
    }

    private func captureSnapshotPreviewImageForPiP(
        maxWidth: CGFloat,
        allowOffscreenViewCapture: Bool
    ) -> UIImage? {
        guard let image = captureSnapshotImage(
            persistToDisk: false,
            allowOffscreenViewCapture: allowOffscreenViewCapture
        ) else {
            return nil
        }
        return scaledPictureInPictureImage(from: image, maxWidth: maxWidth)
    }

    fileprivate func hasVisiblePlayerViewForPictureInPictureCapture() -> Bool {
        guard let view = snapshotSourceView() else { return false }
        return view.window != nil &&
            view.superview != nil &&
            !view.isHidden &&
            view.alpha > 0.01
    }

    private func snapshotSourceView() -> UIView? {
        guard let playerView = playerView else { return nil }
        return playerView.superview ?? playerView
    }

    private func scaledPictureInPictureImage(from image: UIImage, maxWidth: CGFloat) -> UIImage? {
        let sourceSize = image.size
        guard sourceSize.width > 1, sourceSize.height > 1 else { return nil }

        let targetWidth = min(maxWidth, sourceSize.width)
        guard targetWidth > 1 else { return image }
        let aspect = sourceSize.height / sourceSize.width
        let targetSize = CGSize(width: targetWidth, height: max((targetWidth * aspect).rounded(), 1))

        guard abs(targetSize.width - sourceSize.width) > 0.5 || abs(targetSize.height - sourceSize.height) > 0.5 else {
            return image
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private func cropImageToVideoRect(_ image: UIImage, videoRect: CGRect) -> UIImage {
        let containerSize = image.size
        guard containerSize.width > 0, containerSize.height > 0,
              videoRect.width > 1, videoRect.height > 1 else {
            return image
        }
        let needsCrop = abs(videoRect.width - containerSize.width) > 2 || abs(videoRect.height - containerSize.height) > 2
        guard needsCrop else { return image }
        
        let scale = image.scale
        let cropRect = CGRect(
            x: max(0, videoRect.origin.x * scale),
            y: max(0, videoRect.origin.y * scale),
            width: min(containerSize.width * scale, videoRect.size.width * scale),
            height: min(containerSize.height * scale, videoRect.size.height * scale)
        ).integral
        
        guard let cgImage = image.cgImage?.cropping(to: cropRect) else {
            return image
        }
        return UIImage(cgImage: cgImage, scale: scale, orientation: image.imageOrientation)
    }

    private func saveSnapshotImageToDisk(_ image: UIImage) -> Bool {
        guard let data = image.pngData() else { return false }
        let outputURL = nextSnapshotURL()

        do {
            try data.write(to: outputURL, options: .atomic)
            return true
        } catch {
            print("Failed to save snapshot image: \(error)")
            return false
        }
    }
    
    private func nextSnapshotURL() -> URL {
        let baseDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let snapshotsDirectory = baseDirectory.appendingPathComponent("Snapshots", isDirectory: true)
        if !FileManager.default.fileExists(atPath: snapshotsDirectory.path) {
            try? FileManager.default.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        }
        
        let fileName = Self.snapshotFileName(mediaName: snapshotMediaName(), date: Date())
        return snapshotsDirectory.appendingPathComponent(fileName)
    }
    
    private func snapshotMediaName() -> String {
        let rawName = state.currentItem?.title
            ?? state.currentItem?.url.deletingPathExtension().lastPathComponent
            ?? "video"
        return Self.sanitizedSnapshotMediaName(from: rawName)
    }
    
    static func snapshotFileName(mediaName: String?, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        let safeMediaName = sanitizedSnapshotMediaName(from: mediaName)
        return "snapshot_\(safeMediaName)_\(formatter.string(from: date)).png"
    }
    
    static func sanitizedSnapshotMediaName(from rawName: String?) -> String {
        let input = (rawName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
        
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let sanitized = String(input.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "_"
        })
        .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        
        if sanitized.isEmpty {
            return "video"
        }
        return String(sanitized.prefix(64))
    }

    private func minimizedPlaybackVideoFile() -> VideoFile? {
        let resumePos = preferredResumeTime()
        let resolvedPosition = resumePos > 0 ? resumePos : (state.currentTime > 0 ? state.currentTime : nil)

        if var videoFile = state.currentItem?.videoFile {
            if let resolvedPosition {
                videoFile.lastPlayedPosition = resolvedPosition
            }
            return videoFile
        }

        guard let item = state.currentItem else { return nil }
        let itemType = resolvedPlaybackItemType(for: item)
        guard itemType == .video || itemType == .audio else { return nil }

        var videoFile = VideoFile(
            name: item.title,
            url: item.url,
            type: itemType,
            size: item.serverSize ?? 0,
            date: Date(),
            isRemote: item.isRemote,
            duration: state.duration > 0 ? state.duration : nil,
            lastPlayedPosition: resolvedPosition,
            lastAudioTrack: isUsingMPV || state.currentAudioTrackID == -1 ? nil : state.currentAudioTrackID,
            lastSubtitleTrack: isUsingMPV || state.currentSubtitleTrackID == -1 ? nil : state.currentSubtitleTrackID,
            jellyfinItemId: item.jellyfinItemId,
            jellyfinServerId: item.jellyfinServerId,
            serverType: item.serverType,
            seriesId: item.seriesId,
            seasonId: item.seasonId,
            preferredAudioTrackQuery: item.preferredAudioTrackQuery,
            preferredSubtitleTrackQuery: item.preferredSubtitleTrackQuery,
            externalSubtitleCandidates: item.externalSubtitleCandidates
        )
        videoFile.serverMediaStreams = item.serverMediaStreams
        videoFile.serverContainer = item.serverContainer
        videoFile.serverSize = item.serverSize
        videoFile.serverBitrate = item.serverBitrate
        videoFile.serverPath = item.serverPath
        videoFile.remotePlaybackMethod = item.remotePlaybackMethod
        videoFile.shouldResetRemotePlayedStateOnPlaybackStart = item.shouldResetRemotePlayedStateOnPlaybackStart
        return videoFile
    }

    func resolvedPlaybackItemType(for item: MediaItem) -> VideoFile.FileType {
        if let videoFileType = item.videoFile?.type, videoFileType != .unknown {
            return videoFileType
        }

        let detectedType = VideoFile.FileType.determineType(from: item.url)
        if detectedType != .unknown {
            return detectedType
        }

        let hasVideoTrackHint = (videoNaturalSize.width > 1 && videoNaturalSize.height > 1) || isVideoPiPActive
        return hasVideoTrackHint ? .video : .audio
    }

    private func activateFallbackFloatingPlayback(requestPlayerDismissal: Bool = false) -> Bool {
        guard let fallbackFile = minimizedPlaybackVideoFile() else { return false }

        floatingAudioFile = fallbackFile
        floatingAudioPlaylist = [fallbackFile]
        isAudioFloatingVisible = true
        isVideoPiPActive = false
        floatingVideoFile = nil
        if requestPlayerDismissal {
            shouldDismissPresentedPlayerAfterPiPStart = true
        }
        return true
    }

    @available(iOS 15.0, *)
    private func handlePictureInPictureStartFailure() {
        videoPiPController = nil
        let shouldDismissOnFallback = shouldDismissPlayerWhenPiPStarts
        shouldDismissPlayerWhenPiPStarts = false
        if shouldDismissOnFallback || hasTerminalPlaybackFailure {
            // Keep explicit PiP failures and terminal playback failures in the
            // player; neither should downgrade into audio-only playback.
            shouldDismissPresentedPlayerAfterPiPStart = false
            isVideoPiPActive = false
            floatingVideoFile = nil
            return
        }
        if activateFallbackFloatingPlayback(requestPlayerDismissal: shouldDismissOnFallback) {
            return
        }

        isVideoPiPActive = false
        floatingVideoFile = nil
    }

    @available(iOS 15.0, *)
    private func handlePictureInPictureDidStart() {
        isVideoPiPActive = true
        floatingVideoFile = minimizedPlaybackVideoFile()
        isAudioFloatingVisible = false

        if shouldDismissPlayerWhenPiPStarts {
            shouldDismissPresentedPlayerAfterPiPStart = true
            shouldDismissPlayerWhenPiPStarts = false
        }
    }

    @available(iOS 15.0, *)
    private func handlePictureInPictureDidStop() {
        let shouldRestorePlayer = isRestoringPlayerFromPictureInPicture
        let shouldStopPlayback = !shouldRestorePlayer && !isStopInProgress && state.status != .idle

        shouldDismissPlayerWhenPiPStarts = false
        isRestoringPlayerFromPictureInPicture = false
        videoPiPController = nil
        isVideoPiPActive = false
        floatingVideoFile = nil
        shouldDismissPresentedPlayerAfterPiPStart = false

        if shouldRestorePlayer {
            // Keep playerView, drawable, and pipUsableViewController intact
            // so the restored PlayerView can reattach to the existing playback session.
            return
        }

        pipUsableViewController = nil
        playerView = nil
        mediaPlayer?.drawable = nil

        if shouldStopPlayback {
            stop()
        }
    }
    
    // MARK: - Helpers
    func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        return h > 0 ? String(format: "%02d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
}

// MARK: - iOS subtitle intelligence adapter
extension VLCPlaybackService {
    private func configureSubtitleIntelligence() {
        subtitleIntelligenceSubscription = subtitleIntelligence.objectWillChange
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.objectWillChange.send() }
        subtitleIntelligence.onResultsChanged = { [weak self] in self?.objectWillChange.send() }
        subtitleIntelligence.onGeneratedPrimarySelected = { [weak self] in
            guard let self else { return }
            self.remoteSubtitleSelectionTask?.cancel()
            self.remoteSubtitleSelectionTask = nil
            self.setMPVPrimarySubtitle(-1)
            self.mpvPendingExternalSubtitle = nil
            self.pendingEngineTracks["sub"] = nil
            self.mediaPlayer?.currentVideoSubTitleIndex = -1
            self.state.currentSubtitleTrackID = -1
            self.state.currentItem?.externalSubtitleURL = nil
            self.pendingSubtitleTrack = nil
            self.pendingSubtitleTrackQuery = nil
            self.pendingSubtitleTrackOrdinal = nil
            self.hasResolvedAutomaticSubtitleSelection = true
        }
        subtitleIntelligence.onIntelligentSecondarySelected = { [weak self] in
            guard let self else { return }
            AppSettings.shared.enableSecondarySubtitlesBeta = true
            self.pendingSecondaryHandoff = nil
            self.clearSecondarySubtitleTrack()
        }
        subtitleIntelligence.onPrimarySourceNeeded = { [weak self] in self?.refreshIntelligentPrimarySubtitle() }
        subtitleIntelligence.onAudioSourceNeeded = { [weak self] in self?.refreshAudioSubtitleSource() }
        subtitleIntelligence.usesIndependentPlaybackTrackIDs = { [weak self] in self?.isUsingMPV == true }
        subtitleIntelligence.onPlaybackAudioSelection = { [weak self] in
            guard let self else { return nil }
            return (self.state.currentAudioTrackID, self.state.audioTracks.map(\.id))
        }
    }

    private func refreshAudioSubtitleSource() {
        guard let item = state.currentItem,
              let server = embeddedSubtitleServer(for: item), server.type == item.serverType else { return }
        let sourceID = item.mediaSourceId ?? embeddedSubtitleMediaSourceID(from: item.url)
        subtitleIntelligence.retryAudioInspection(url: item.url, provider: item.serverType?.rawValue,
            serverID: item.jellyfinServerId, itemID: item.jellyfinItemId,
            serverURL: URL(string: server.fullURL), token: embeddedSubtitleToken(for: item, server: server),
            mediaSourceID: sourceID,
            playbackMetadata: audioSubtitleMetadata.flatMap { $0.itemID == item.id ? $0.data : nil })
    }

    private func bindSubtitleIntelligence(_ item: MediaItem) {
        audioSubtitleMetadata = nil
        let file = item.videoFile
        guard playbackCapabilities.supports(.audioSubtitleGeneration,
            isVideo: (file?.type ?? VideoFile.FileType.determineType(from: item.url)) == .video) else {
            subtitleIntelligence.reset()
            subtitleIntelligence.showingSettings = false
            return
        }
        let server = item.jellyfinServerId.flatMap { id in
            AppNetworkService.shared.servers.first { $0.id == UUID(uuidString: id) && $0.type == item.serverType }
        }
        let sourceID = item.mediaSourceId ?? file?.mediaSourceId ?? URLComponents(url: item.url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame }?.value
        subtitleIntelligence.bind(url: item.url, live: file?.isLiveStream == true || item.serverType == .iptv,
            provider: item.serverType?.rawValue, serverID: item.jellyfinServerId, itemID: item.jellyfinItemId,
            serverURL: server.flatMap { URL(string: $0.fullURL) },
            token: server.map { embeddedSubtitleToken(for: item, server: $0) }, mediaSourceID: sourceID, seriesID: file?.seriesId, filePath: file?.serverPath ?? item.serverPath)
        subtitleIntelligence.setBackground(UIApplication.shared.applicationState == .background)
    }

    private func refreshIntelligentPrimarySubtitle() {
        syncMPVDecodedPrimary()
        subtitleIntelligence.hasSelectedPrimarySubtitle = effectiveCurrentSubtitleTrackID != -1
        subtitleIntelligence.updateAudioNames(audioTracks.map { ($0.id, $0.name) })
        guard subtitleIntelligence.isTranslating, !subtitleIntelligence.isGeneratedPrimary, !subtitleIntelligence.isTranslatingAudio,
              let item = state.currentItem else { return }
        let candidate = availableSecondarySubtitleTracks(for: item).first(where: isCurrentPrimarySubtitle)
        if candidate?.isSelectable != true || candidate?.sourceURL == nil,
           let source = remoteMPVPrimarySubtitleSource(item: item, offset: subtitleDelay) {
            let native = mpvState?.tracks.first { $0.type == "sub" && $0.id == effectiveCurrentSubtitleTrackID }
            if native?.isBitmap == true { subtitleIntelligence.unavailablePrimary(bitmap: true); return }
            subtitleIntelligence.followPrimaryDocument(key: source.id + "|" + source.revision,
                language: native?.language, decodedFallbackKey: mpvDecodedPrimaryKey, load: source.load)
            return
        }
        if candidate?.isSelectable != true || candidate?.sourceURL == nil, let key = mpvDecodedPrimaryKey {
            subtitleIntelligence.followDecodedPrimary(key: key)
            return
        }
        guard effectiveCurrentSubtitleTrackID != -1, let track = candidate else {
            subtitleIntelligence.unavailablePrimary(bitmap: false)
            return
        }
        guard track.isSelectable, let sourceURL = track.sourceURL else {
            subtitleIntelligence.unavailablePrimary(bitmap: track.supportLevel == .unsupportedBitmap)
            return
        }
        let key = "\(effectiveCurrentSubtitleTrackID)|\(secondarySubtitleTimelineCacheKey(for: track))"
        let format = subtitleParserFormat(for: track)
        let load: () async throws -> SubtitleTimeline = { [weak self] in
            guard let self else { throw CancellationError() }
            let readable: URL
            if track.source == .localContainer {
                guard let index = track.streamIndex else { throw CocoaError(.fileReadCorruptFile) }
                readable = try await LocalEmbeddedSubtitleExtractor.extractSubtitle(from: item.url, trackIndex: index, outputURL: sourceURL)
            } else if sourceURL.isFileURL { readable = sourceURL }
            else if let local = await self.cacheRemoteSubtitleToLocalIfNeeded(sourceURL) { readable = local }
            else { throw CocoaError(.fileReadUnknown) }
            try Task.checkCancellation()
            let access = readable.startAccessingSecurityScopedResource()
            defer { if access { readable.stopAccessingSecurityScopedResource() } }
            return SubtitleTimeline(parts: try SubtitleModel.loadParts(from: readable, format: format))
        }
        if let decodedKey = mpvDecodedPrimaryKey {
            subtitleIntelligence.followPrimaryDocument(key: key, language: track.language, decodedFallbackKey: decodedKey) {
                SubtitleBrowserDocument(parts: try await load().parts)
            }
        } else {
            subtitleIntelligence.followPrimary(key: key, language: track.language, load: load)
        }
    }

    private var mpvDecodedPrimaryKey: String? {
        guard isUsingMPV, !subtitleIntelligence.isGeneratedPrimary,
              let track = mpvState?.tracks.first(where: { $0.type == "sub" && $0.id == effectiveCurrentSubtitleTrackID }),
              !track.isBitmap else { return nil }
        return "\(playbackAttemptID)|mpv|\(track.id)"
    }

    private func syncMPVDecodedPrimary() {
        let key = mpvDecodedPrimaryKey
        let snapshot = mpvState
        let matches = key != nil && snapshot?.subtitle == effectiveCurrentSubtitleTrackID
        subtitleIntelligence.updateDecodedPrimary(key: key,
            language: snapshot?.tracks.first(where: { $0.type == "sub" && $0.id == effectiveCurrentSubtitleTrackID })?.language,
            text: matches ? (snapshot?.primaryText ?? "") : "",
            start: matches ? snapshot?.primaryStart.map { $0 + resolvedPlaybackTimelineOffset() } : nil,
            end: matches ? snapshot?.primaryEnd.map { $0 + resolvedPlaybackTimelineOffset() } : nil)
    }
}

// MARK: - Read-only subtitle browser adapter
extension VLCPlaybackService {
    var canBrowseSubtitles: Bool {
        guard let item = state.currentItem else { return false }
        return playbackCapabilities.supports(.subtitleBrowser,
            isVideo: (item.videoFile?.type ?? VideoFile.FileType.determineType(from: item.url)) == .video)
    }

    var subtitleBrowserSources: [SubtitleBrowserSource] {
        guard let item = state.currentItem else { return [] }
        let session = playbackAttemptID.uuidString
        var sources: [SubtitleBrowserSource] = []
        if let generated = subtitleIntelligence.browserSource(primary: true, sessionID: session, offset: subtitleDelay) {
            sources.append(generated)
        } else if currentSubtitleTrack != -1 {
            let track = state.secondarySubtitleTracks.first(where: isCurrentPrimarySubtitle)
            let remote = track?.isSelectable != true || track?.sourceURL == nil
                ? remoteMPVPrimarySubtitleSource(item: item, offset: subtitleDelay) : nil
            let title = NSLocalizedString("Primary", comment: "")
            let full = remote ?? browserSource(track: track, item: item, id: "\(session)|primary|\(currentSubtitleTrack)",
                title: title, offset: subtitleDelay)
            let source = mpvDecodedPrimaryKey.flatMap {
                subtitleIntelligence.decodedPrimaryBrowserSource(key: $0, title: title, offset: subtitleDelay, fullSource: full)
            }
            sources.append(source ?? full)
        }
        if AppSettings.shared.enableSecondarySubtitlesBeta {
            let delay = subtitleDelay + state.secondarySubtitleDelay
            if let generated = subtitleIntelligence.browserSource(primary: false, sessionID: session, offset: delay) {
                sources.append(generated)
            } else if let id = state.currentSecondarySubtitleTrackID {
                let track = state.secondarySubtitleTracks.first { $0.id == id }
                if mpvDecodedSecondaryID != nil, !isNativeBitmapSecondarySubtitle {
                    let decoded = mpvDecodedSecondary
                    let indexedParts = secondarySubtitleTimeline?.parts
                    let nativeASS = mpvSecondaryRendering?.isASS == true
                    let fullSource = browserSource(track: track, item: item, id: "\(session)|secondary|\(id)",
                        title: NSLocalizedString("Secondary", comment: ""), offset: -delay)
                    sources.append(SubtitleBrowserSource(id: "\(session)|secondary|\(id)|decoded",
                        title: NSLocalizedString("Secondary", comment: ""),
                        revision: nativeASS ? "ass|\(fullSource.revision)" : "\(decoded.revision)|\(indexedParts?.count ?? 0)", offset: -delay) { [weak self] in
                        try Task.checkCancellation()
                        guard let self, self.playbackAttemptID.uuidString == session,
                              self.state.currentSecondarySubtitleTrackID == id else { throw CancellationError() }
                        if nativeASS {
                            do {
                                let document = try await fullSource.load()
                                try Task.checkCancellation()
                                guard self.playbackAttemptID.uuidString == session,
                                      self.state.currentSecondarySubtitleTrackID == id else { throw CancellationError() }
                                return document
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                try Task.checkCancellation()
                                guard self.playbackAttemptID.uuidString == session,
                                      self.state.currentSecondarySubtitleTrackID == id else { throw CancellationError() }
                            }
                        }
                        let observed = decoded.cues.map {
                            SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text))
                        }
                        var parts = indexedParts ?? []
                        for part in observed where !parts.contains(part) { parts.append(part) }
                        return SubtitleBrowserDocument(parts: parts, isPartial: true,
                            partialStatusKey: indexedParts == nil ? "SB.Decoded" : "SB.Indexed")
                    })
                } else {
                    // Ordinary secondary subtitles currently query time + delay; preserve that display path.
                    sources.append(browserSource(track: track, item: item, id: "\(session)|secondary|\(id)",
                        title: NSLocalizedString("Secondary", comment: ""), offset: -delay))
                }
            }
        }
        return sources
    }

    private func supportsRemoteMPVSubtitles(_ item: MediaItem) -> Bool {
        isUsingMPV && !item.isLiveStream &&
            (item.url.scheme?.lowercased() == "smb" ||
                FileAudioRangeReader.supports(provider: item.serverType?.rawValue ?? (item.url.scheme?.lowercased() == "ftps" ? "ftp" : item.url.scheme?.lowercased()), url: item.url) ||
                (item.serverType == nil && FileAudioRangeReader.supports(provider: nil, url: item.url))) &&
            (item.serverContainer?.lowercased() == "mkv" ||
                [item.url.path, item.serverPath ?? "", item.title].contains {
                    URL(fileURLWithPath: $0).pathExtension.lowercased() == "mkv"
                })
    }

    private func remoteMPVPrimarySubtitleSource(item: MediaItem, offset: Double) -> SubtitleBrowserSource? {
        remoteMPVSubtitleSource(item: item, selectedID: effectiveCurrentSubtitleTrackID,
            secondaryTrackID: nil, offset: offset)
    }

    private func remoteMPVSubtitleSource(item: MediaItem, selectedID: Int,
                                         secondaryTrackID: String?, offset: Double) -> SubtitleBrowserSource? {
        guard supportsRemoteMPVSubtitles(item), let snapshot = mpvState,
              let selection = IOSMPVRemoteSubtitleSelection(selectedID: selectedID, tracks: snapshot.tracks),
              let track = snapshot.tracks.first(where: { $0.type == "sub" && $0.id == selectedID }) else { return nil }
        let attempt = playbackAttemptID
        let loader = remoteMPVSubtitleLoader
        let slot = secondaryTrackID == nil ? "primary" : "secondary"
        let id = "\(attempt)|\(slot)|\(selectedID)|remote-mkv"
        return SubtitleBrowserSource(id: id, title: NSLocalizedString(secondaryTrackID == nil ? "Primary" : "Secondary", comment: ""),
            revision: selection.trackNumbers.map(String.init).joined(separator: ","), offset: offset) { [weak self] in
            guard let self else { throw CancellationError() }
            func isCurrent() -> Bool {
                guard self.playbackAttemptID == attempt, self.isUsingMPV,
                      IOSMPVRemoteSubtitleSelection(selectedID: selectedID, tracks: self.mpvState?.tracks ?? []) == selection else { return false }
                if let secondaryTrackID {
                    return AppSettings.shared.enableSecondarySubtitlesBeta &&
                        self.state.currentSecondarySubtitleTrackID == secondaryTrackID
                }
                return self.effectiveCurrentSubtitleTrackID == selectedID
            }
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            if track.isBitmap { throw SubtitleBrowserError.bitmap }
            let metadata: @Sendable () async throws -> IOSRemoteSubtitleLoader.Version
            let read: @Sendable (UInt64, Int) async throws -> Data
            if item.url.scheme?.lowercased() == "smb" {
                let reader = SMBAudioRangeReader(url: item.url)
                metadata = {
                    let value = try await reader.metadata()
                    return .init(size: value.size, stamp: value.version)
                }
                read = { try await reader.read(offset: $0, count: $1) }
            } else {
                let scheme = item.url.scheme?.lowercased()
                let reader = FileAudioRangeReader(url: item.url,
                    provider: item.serverType?.rawValue ?? (["ftp", "ftps", "sftp", "nfs"].contains(scheme ?? "") ? (scheme == "ftps" ? "ftp" : scheme) : nil),
                    serverID: item.jellyfinServerId, path: item.serverPath, itemID: item.jellyfinItemId)
                metadata = {
                    let value = try await reader.metadata()
                    return .init(size: value.size, stamp: value.stamp)
                }
                read = { try await reader.read(offset: $0, count: $1) }
            }
            // Separate connections, shared versioned cache for completed main/secondary documents.
            let document = try await loader.load(identity: "\(attempt)|remote-mkv", ordinal: selection.ordinal,
                count: selection.count, trackNumbers: selection.trackNumbers, metadata: metadata, read: read)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            return document
        }
    }

    private func browserSource(track: EmbeddedSubtitleTrack?, item: MediaItem, id: String,
                               title: String, offset: Double) -> SubtitleBrowserSource {
        if let track, nativeSecondaryRendering(for: track)?.isBitmap == true {
            return SubtitleBrowserSource(id: id, title: title, revision: track.id, offset: offset) {
                throw SubtitleBrowserError.bitmap
            }
        }
        if let track, track.source == .remoteContainer, let nativeID = track.primaryTrackID,
           let source = remoteMPVSubtitleSource(item: item, selectedID: nativeID, secondaryTrackID: track.id, offset: offset) {
            return source
        }
        return SubtitleBrowserSource(id: id, title: title, revision: track?.id ?? "unresolved", offset: offset) { [weak self] in
            guard let self else { throw CancellationError() }
            guard let track else { throw SubtitleBrowserError.unreadable }
            if track.supportLevel == .unsupportedBitmap { throw SubtitleBrowserError.bitmap }
            guard track.isSelectable, let sourceURL = track.sourceURL else { throw SubtitleBrowserError.unreadable }
            let format = self.subtitleParserFormat(for: track)
            let readable: URL
            if track.source == .localContainer {
                guard let index = track.streamIndex else { throw SubtitleBrowserError.unreadable }
                readable = try await LocalEmbeddedSubtitleExtractor.extractSubtitle(from: item.url, trackIndex: index, outputURL: sourceURL)
            } else if sourceURL.isFileURL { readable = sourceURL }
            else if let local = await self.cacheRemoteSubtitleToLocalIfNeeded(sourceURL) { readable = local }
            else { throw CocoaError(.fileReadUnknown) }
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                let access = readable.startAccessingSecurityScopedResource()
                defer { if access { readable.stopAccessingSecurityScopedResource() } }
                return SubtitleBrowserDocument(parts: try SubtitleModel.loadParts(from: readable, format: format))
            }.value
        }
    }
}

// MARK: - Optional iOS MPV backend
extension VLCPlaybackService {
    private func prepareMPV(item: MediaItem, attemptID: UUID) {
        isPreparingMPV = true
        // Deferred playback runs only after the user explicitly presses Play.
        let engineTracks = pendingEngineTracks
        let secondaryHandoff = pendingSecondaryHandoff
        let retry: () -> Void = { [weak self] in
            self?.play(item: item, in: self?.playerView, engineTracks: engineTracks,
                       secondaryHandoff: secondaryHandoff, preserveSubtitleIntelligence: true)
        }
        if deferPreparedPlaybackForBackground(retry: retry) { return }
        let controlID = playbackControlID
        audioSessionCoordinator.activate { [weak self] ready in
            guard let self, self.playbackAttemptID == attemptID, !self.isStopInProgress,
                  !self.hasTerminalPlaybackFailure else { return }
            if self.deferPreparedPlaybackForBackground(retry: retry) { return }
            guard self.playbackControlID == controlID else {
                // A pause/background request invalidated this activation. Do not
                // replay the original autoplay request from its late callback.
                self.isPreparingPlayback = false
                self.state.status = .paused
                self.stopStartupWatchdog()
                self.deferredBackgroundPlayback = retry
                return
            }
            guard ready else {
                self.isPreparingPlayback = false
                self.state.status = .paused
                self.stopStartupWatchdog()
                self.deferredBackgroundPlayback = retry
                return
            }
            self.finishAudioSessionActivation()
            self.startMPV(item: item, attemptID: attemptID)
        }
    }

    @discardableResult
    private func startMPVDecodedSecondary(for track: EmbeddedSubtitleTrack) -> Bool {
        guard isUsingMPV, let id = track.primaryTrackID,
              let native = mpvState?.tracks.first(where: { $0.type == "sub" && $0.id == id }),
              !native.isBitmap, IOSMPVRemoteSubtitleSelection.supportsText(codec: native.codec) else { return false }
        mpvDecodedSecondaryID = id
        mpvSecondaryRendering = MPVSecondarySubtitleRendering(trackID: id, tracks: mpvState?.tracks ?? [])
        mpvDecodedSecondary.select("\(playbackAttemptID)|\(id)")
        state.secondarySubtitleStatus = .loading
        configureMPVDecodedSecondary()
        return true
    }

    private func stopMPVDecodedSecondary() {
        guard mpvDecodedSecondaryID != nil else { return }
        mpvDecodedSecondaryID = nil
        mpvSecondaryRendering = nil
        mpvSecondaryRenderingProperties = [:]
        mpvSubtitleSelectionRequest = nil
        mpvDecodedSecondary.select("")
        mpvEngine?.set("secondary-sid", "no")
        mpvEngine?.set("secondary-sub-visibility", "no")
        mpvEngine?.configureSecondaryASS(track: -1, scale: 1, centerY: nil)
        nativeASSBounds = nil
        nativeASSHasContent = false
    }

    private func setMPVTrackProperty(_ property: String, id: Int) {
        if property == "sid" { setMPVPrimarySubtitle(id) }
        else { mpvEngine?.set(property, id < 0 ? "no" : String(id)) }
    }

    private func setMPVPrimarySubtitle(_ id: Int) {
        guard let engine = mpvEngine else { return }
        hasResolvedAutomaticSubtitleSelection = true
        state.currentSubtitleTrackID = id
        if isNativeBitmapSecondarySubtitle, mpvDecodedSecondaryID == id {
            clearSecondarySubtitleTrack(persistPreference: true)
        }
        if mpvDecodedSecondaryID != nil {
            configureMPVDecodedSecondary()
        } else {
            // Protect an explicit selection from an older queued playback snapshot.
            let request = UUID(), attempt = playbackAttemptID
            mpvSubtitleSelectionRequest = request
            engine.selectSubtitles(primary: id, secondary: -1) { [weak self] primary, _ in
                guard let self, self.playbackAttemptID == attempt, !self.hasTerminalPlaybackFailure,
                      self.mpvSubtitleSelectionRequest == request else { return }
                self.mpvSubtitleSelectionRequest = nil
                self.state.currentSubtitleTrackID = self.subtitleIntelligence.isGeneratedPrimary ? -1 : primary
            }
        }
    }

    private func updateMPVSecondaryDelay() {
        // Existing iOS second-subtitle timeline queries time + delay.
        // mpv's native property instead delays presentation, hence the inverted sign.
        mpvEngine?.set("secondary-sub-delay", String(MPVSecondarySubtitleRendering.nativeDelay(primary: subtitleDelay, secondary: state.secondarySubtitleDelay)))
    }

    private func configureMPVDecodedSecondary() {
        guard let id = mpvDecodedSecondaryID, let engine = mpvEngine else { return }
        let primary = subtitleIntelligence.isGeneratedPrimary ? -1 : state.currentSubtitleTrackID
        guard mpvSecondaryRendering?.canSelect(primary: primary) != false else {
            clearSecondarySubtitleTrack(persistPreference: true)
            setMPVPrimarySubtitle(primary)
            return
        }
        let request = UUID(), attempt = playbackAttemptID
        mpvSubtitleSelectionRequest = request
        state.secondarySubtitleParts = []
        updateMPVSecondaryDelay()
        updateMPVSecondaryRendering()
        engine.selectSubtitles(primary: primary, secondary: id) { [weak self] actualPrimary, actualSecondary in
            guard let self, self.playbackAttemptID == attempt, !self.hasTerminalPlaybackFailure,
                  self.mpvSubtitleSelectionRequest == request, self.mpvDecodedSecondaryID == id else { return }
            self.mpvSubtitleSelectionRequest = nil
            let available = self.mpvSecondaryRendering?.isSelected(primary: actualPrimary, secondary: actualSecondary) == true
            self.state.secondarySubtitleStatus = available ? .ready : .failed
            self.updateMPVSecondaryRendering()
        }
    }

    private func updateMPVSecondaryRendering() {
        guard let engine = mpvEngine, mpvDecodedSecondaryID != nil else { return }
        let size = playerView?.bounds.size ?? engine.videoSurfaceView.bounds.size
        let orientation = mpvSecondaryLayoutOrientation ?? AppSettings.SecondarySubtitleLayoutOrientation.resolved(for: size)
        let defaultRatio: Double
        switch secondarySubtitlePlacement {
        case .nearBottom: defaultRatio = 1
        case .middle: defaultRatio = 0.6
        case .top: defaultRatio = 0.2
        }
        let customRatio = secondarySubtitleVerticalPositionRatio(for: orientation)
        let nativeASS = isNativeASSSecondarySubtitle
        // Keep script placement until the user explicitly adjusts it. Preset
        // middle/top count as adjustments; nearBottom is the original default.
        let hasCustomPosition = customRatio != nil || secondarySubtitlePlacement != .nearBottom
        let ratio = customRatio ?? defaultRatio
        var centerY: Double? = hasCustomPosition ? ratio : nil
        if nativeASS, !nativeASSUsesVideoViewport, let requested = centerY, size.height > 0 {
            let rect = Self.visibleVideoRect(containerSize: size, naturalVideoSize: videoNaturalSize,
                aspectRatioOverride: state.aspectRatio, displayMode: state.videoDisplayMode)
            centerY = (rect.minY + requested * rect.height) / size.height
        }
        engine.configureSecondaryASS(track: nativeASS ? (mpvDecodedSecondaryID ?? -1) : -1,
            scale: AppSettings.shared.secondarySubtitleSizeScale.rawValue, centerY: centerY)
        let properties = [
            "secondary-sub-visibility": isNativeRenderedSecondarySubtitle && state.secondarySubtitleStatus == .ready ? "yes" : "no",
            "secondary-sub-ass-override": nativeASS ? MPVSecondarySubtitleRendering.assOverride(hasCustomPosition: hasCustomPosition) : (isNativeBitmapSecondarySubtitle ? "yes" : "strip"),
            "secondary-sub-pos": nativeASS ? "100" : String(MPVSecondarySubtitleRendering.nativePosition(ratio: ratio))
        ]
        for (key, value) in properties where mpvSecondaryRenderingProperties[key] != value {
            engine.set(key, value)
        }
        mpvSecondaryRenderingProperties = properties
    }

    private func syncMPVDecodedSecondary() {
        updateMPVSecondaryRendering()
        let bounds = isNativeASSSecondarySubtitle ? mpvState?.secondaryASSBounds : nil
        if nativeASSBounds != bounds { nativeASSBounds = bounds }
        let hasContent = isNativeASSSecondarySubtitle && mpvState?.secondaryASSHasContent == true
        if nativeASSHasContent != hasContent { nativeASSHasContent = hasContent }
        if isNativeBitmapSecondarySubtitle {
            if !state.secondarySubtitleParts.isEmpty { state.secondarySubtitleParts = [] }
            return
        }
        guard let id = mpvDecodedSecondaryID, let snapshot = mpvState,
              mpvSubtitleSelectionRequest == nil, state.secondarySubtitleStatus == .ready else {
            if !state.secondarySubtitleParts.isEmpty { state.secondarySubtitleParts = [] }
            return
        }
        let mirror = snapshot.subtitle == id
        let matches = mirror || snapshot.secondary == id
        if matches {
            let offset = resolvedPlaybackTimelineOffset()
            mpvDecodedSecondary.append(text: mirror ? snapshot.primaryText : snapshot.secondaryText,
                start: (mirror ? snapshot.primaryStart : snapshot.secondaryStart).map { $0 + offset },
                end: (mirror ? snapshot.primaryEnd : snapshot.secondaryEnd).map { $0 + offset })
        }
        if isNativeASSSecondarySubtitle {
            if !state.secondarySubtitleParts.isEmpty { state.secondarySubtitleParts = [] }
            return // Native ASS is already in video/PiP/snapshot pixels.
        }
        let time = state.currentTime + subtitleDelay + state.secondarySubtitleDelay
        let indexed = secondarySubtitleTimeline?.activeParts(at: time) ?? []
        let parts = indexed.isEmpty ? mpvDecodedSecondary.activeCues(at: time).map {
            SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text))
        } : indexed
        if state.secondarySubtitleParts != parts { state.secondarySubtitleParts = parts }
    }

    private func mpvNetworkOptions(for item: MediaItem) -> [String: String] {
        var options: [String: String] = [:]
        if item.serverType == .vod { options["user-agent"] = VODService.defaultUserAgent }
        if item.serverType == .pan115 || item.url.host?.contains("115.com") == true {
            options["user-agent"] = Pan115Manager.defaultUserAgent
            options["referrer"] = "https://115.com"
            let server = item.jellyfinServerId.flatMap { id in AppNetworkService.shared.savedServers.first { $0.id.uuidString == id } }
                ?? item.videoFile?.resolvedServer
            if let cookie = server?.passwordSecret ?? server?.accessToken, !cookie.isEmpty {
                let header = "Cookie: " + cookie.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: "")
                options["http-header-fields"] = "%\(header.utf8.count)%\(header)"
            }
        }
        return options
    }

    private func mpvStream(for item: MediaItem, byteCache: MPVReadAheadByteCache? = nil) -> MacMPVStream? {
        let scheme = item.url.scheme?.lowercased() ?? ""
        if scheme == "smb" {
            // This is a dedicated read-only connection; browser/download handles are never borrowed.
            let reader = SMBAudioRangeReader(url: item.url)
            return MacMPVStream(metadata: { try await reader.metadata().size },
                read: { try await reader.read(offset: $0, count: $1) }, byteCache: byteCache)
        }
        guard ["ftp", "ftps", "sftp", "nfs"].contains(scheme) else { return nil }
        let reader = FileAudioRangeReader(url: item.url,
            provider: item.serverType?.rawValue ?? (scheme == "ftps" ? "ftp" : scheme),
            serverID: item.jellyfinServerId, path: item.serverPath, itemID: item.jellyfinItemId)
        return MacMPVStream(metadata: { try await reader.metadata().size },
            read: { try await reader.read(offset: $0, count: $1) }, byteCache: byteCache)
    }

    private func startMPV(item: MediaItem, attemptID: UUID) {
        isPreparingMPV = false
        let oldPlayer = mediaPlayer
        mediaPlayer = nil
        tearDownDetachedPlayerAsync(oldPlayer, reason: "MPV")
        let audioOnly = resolvedPlaybackItemType(for: item) == .audio
        let historyEnabled = audioOnly ? AppSettings.shared.enableAudioHistory : AppSettings.shared.enableVideoHistory
        let history = historyEnabled
            ? (historyService.getLastPlayedPosition(for: item) ?? historyService.getLastPlayedPosition(for: item.url)) : nil
        let start = item.startPosition ?? history ?? 0
        let preference = storedTrackQueryPreference(for: item)
        mpvLoaded = false
        mpvTrackPreferenceKey = "ios." + MacMPVTrackChoice.mediaKey(url: item.url,
            serverID: item.jellyfinServerId, itemID: item.jellyfinItemId, path: item.serverPath)
        mpvTrackChoices = UserDefaults.standard.data(forKey: mpvTrackPreferenceKey).flatMap {
            try? JSONDecoder().decode([String: MacMPVTrackChoice].self, from: $0)
        } ?? [:]
        mpvTrackScopeKey = IOSPlaybackTrackSelection.scopeKey(url: item.url,
            provider: item.serverType?.rawValue, serverID: item.jellyfinServerId,
            seriesID: item.seriesId, filePath: item.serverPath, libraryItemID: item.jellyfinItemId)
        let inherited = mpvTrackScopeKey.flatMap { UserDefaults.standard.data(forKey: $0) }.flatMap {
            try? JSONDecoder().decode([String: MacMPVTrackChoice].self, from: $0)
        } ?? [:]
        mpvPendingTrackChoices = inherited.merging(mpvTrackChoices) { _, itemChoice in itemChoice }
        let explicitSubtitle = pendingEngineTracks["sub"] != nil || item.externalSubtitleURL != nil ||
            item.preferredSubtitleTrackQuery != nil || item.preferredSubtitleTrackOrdinal != nil
        let shouldDisableSubtitles = pendingEngineTracks["sub"] == .off ||
            (pendingEngineTracks["sub"] == nil && item.savedSubtitleTrackIndex == -1) ||
            (!explicitSubtitle && mpvPendingTrackChoices["sub"] == nil && preference.subtitlesDisabled == true)
        mpvPendingExternalSubtitle = shouldDisableSubtitles ? nil : item.externalSubtitleURL
        if shouldDisableSubtitles { hasResolvedAutomaticSubtitleSelection = true }
        if item.preferredAudioTrackQuery != nil || item.preferredAudioTrackOrdinal != nil { mpvPendingTrackChoices["audio"] = nil }
        if shouldDisableSubtitles || item.preferredSubtitleTrackQuery != nil || item.preferredSubtitleTrackOrdinal != nil {
            mpvPendingTrackChoices["sub"] = nil
        }
        pendingAudioTrackQuery = item.preferredAudioTrackQuery ?? preference.audioQuery
        pendingSubtitleTrackQuery = shouldDisableSubtitles ? nil : (item.preferredSubtitleTrackQuery ?? preference.subtitleQuery)
        pendingAudioTrackOrdinal = item.preferredAudioTrackOrdinal
        pendingSubtitleTrackOrdinal = shouldDisableSubtitles ? nil : item.preferredSubtitleTrackOrdinal
        for type in pendingEngineTracks.keys {
            mpvPendingTrackChoices[type] = nil
            if type == "audio" { pendingAudioTrackQuery = nil; pendingAudioTrackOrdinal = nil }
            else { pendingSubtitleTrackQuery = nil; pendingSubtitleTrackOrdinal = nil; mpvPendingExternalSubtitle = nil }
        }
        let secondary = storedSecondarySubtitlePreference(for: item)
        pendingSecondarySubtitleTrackQuery = secondary.query
        pendingSecondarySubtitleTrackOrdinal = secondary.ordinal
        let speed = sessionPlaybackRate ?? Float(audioOnly ? AppSettings.shared.defaultAudioPlaybackSpeed : AppSettings.shared.defaultPlaybackSpeed)
        state.rate = MPVPlaybackSpeed.clamped(speed)
        let pixelOutput = audioOnly ? nil : videoPiPController?.makeMPVFrameOutput(sourceSize: videoNaturalSize)
        var options = ["pause": mpvPauseRequested ? "yes" : "no",
                       "vid": !audioOnly && (UIApplication.shared.applicationState == .active || pixelOutput != nil) ? "auto" : "no",
                       "hwdec": currentDecoder == .hardware ? "videotoolbox" : "no",
                       "speed": String(state.rate), "mute": isMuted ? "yes" : "no",
                       "audio-delay": String(AppSettings.shared.audioDelaySeconds),
                       "sub-delay": String(subtitleDelay), "secondary-sid": "no", "secondary-sub-visibility": "no",
                       // Plain text follows the video, not the portrait window/black bars.
                       // Keep authored ASS typesetting and bitmap subtitle coordinates intact.
                       "sub-use-margins": "no", "sub-scale-with-window": "no",
                       "sub-ass-force-margins": "no", "sub-ass-scale-with-window": "no",
                       "sub-font": Self.subtitleTypography.fontFamily,
                       "sub-font-size": String(Self.subtitleTypography.mpvFontSize(
                            vlcRelativeDivisor: preferredSubtitleRendererFontSize().doubleValue)),
                       "sub-margin-y": "20",
                       "video-aspect-override": state.aspectRatio.isEmpty ? "-1" : state.aspectRatio,
                       "slang": Locale.preferredLanguages.joined(separator: ","),
                       "sid": shouldDisableSubtitles ? "no" : "auto"]
        switch AppSettings.shared.subtitleAutoSelectionMode {
        case .chinese: options["slang"] = "zh,zho,chi,zh-Hans,zh-Hant"
        case .english: options["slang"] = "en,eng"
        case .followAppLanguage:
            let language = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
            if language != "system" { options["slang"] = language }
        case .off: break
        }
        if subtitleIntelligence.isGeneratedPrimary {
            options["sid"] = "no"
            mpvPendingExternalSubtitle = nil
        }
        options.merge(mpvNetworkOptions(for: item)) { _, network in network }
        var subtitles = externalSubtitleCandidates.filter { $0.isFileURL || ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        if let external = item.externalSubtitleURL,
           external.isFileURL || ["http", "https"].contains(external.scheme?.lowercased() ?? ""),
           !subtitles.contains(external) { subtitles.append(external) }
        if audioOnly { subtitles = []; options["sid"] = "no"; mpvPendingExternalSubtitle = nil }
        // A server can offer a download URL for an embedded subtitle. Wait for
        // the native track list before deciding whether that download is needed.
        subtitles.removeAll { mpvEmbeddedServerSubtitle(for: $0) != nil }
        mpvRemovedDuplicateSubtitles.removeAll()
        mpvAttachedSidecars = Set(subtitles)
        let previewReadCache = MPVReadAheadByteCache()
        mpvReadAheadByteCache = previewReadCache
        let stream = mpvStream(for: item, byteCache: previewReadCache)
        subtitleIntelligence.setPlaybackReadAheadCache(stream == nil ? nil : previewReadCache)
        var configuration = MPVPlaybackEngine.Configuration(
            url: stream == nil ? RuntimeNetworkAddressResolver.runtimeURL(from: item.url) : item.url,
            start: item.videoFile?.isLiveStream == true || item.serverType == .iptv ? 0 : playerLocalTime(fromLogicalTime: start),
            options: options, subtitles: subtitles, audioOnly: audioOnly, stream: stream,
            readAheadCache: !item.isLiveStream && item.serverType != .iptv)
        configuration.pixelBufferOutput = pixelOutput
        mpvEngine = MPVPlaybackEngine(configuration: configuration, onState: { [weak self] snapshot in
                guard let self, self.playbackAttemptID == attemptID, self.isUsingMPV,
                      !self.isStopInProgress, !self.hasTerminalPlaybackFailure else { return }
                self.applyMPV(snapshot)
            }, onError: { [weak self] failure in
                guard let self, self.playbackAttemptID == attemptID, self.isUsingMPV,
                      !self.isStopInProgress else { return }
                if pixelOutput != nil, failure.isInitialization || failure.stage == .frameOutput,
                   self.videoPiPController?.handleMPVFrameOutputFailure() == true { return }
                self.handlePlaybackFailureIfNeeded(for: item, customMessage: NSLocalizedString(
                    failure.isInitialization ? "MPV.InitializationFailed" : "MPV.PlaybackFailed", comment: ""))
            })
        if pixelOutput != nil { mpvEngine?.startPixelBufferOutput() }
        if audioOnly {
            mpvEngine?.startAudio()
            extractMetadata()
        } else {
            for url in externalSubtitleCandidates { attachMPVSubtitle(url) }
            if let url = item.externalSubtitleURL { attachMPVSubtitle(url) }
        }
        isPreparingPlayback = false
        state.currentTime = start
        setupRemoteCommands()
        updateNowPlayingInfo()
        fetchServerMediaInfo()
    }

    private func applyMPV(_ snapshot: MPVPlaybackEngine.State) {
        let old = mpvState
        guard old != snapshot else { return }
        if old?.hdrInfo != snapshot.hdrInfo { objectWillChange.send() }
        mpvState = snapshot
        cacheInputBytesPerSecond = snapshot.cacheInputBytesPerSecond
        cacheReadIdle = snapshot.cacheReadIdle
        let ranges = snapshot.bufferedRanges.map { MPVBufferedRange(
            start: logicalPlaybackTime(fromPlayerTime: $0.start),
            end: logicalPlaybackTime(fromPlayerTime: $0.end)) }
        if bufferedRanges != ranges { bufferedRanges = ranges }
        if old?.size != snapshot.size {
            mpvEngine?.set("sub-font-size", String(Self.subtitleTypography.mpvFontSize(
                vlcRelativeDivisor: preferredSubtitleRendererFontSize().doubleValue,
                videoSize: snapshot.size)))
        }
        let firstLoaded = snapshot.loaded && !mpvLoaded
        mpvLoaded = snapshot.loaded
        let changedTracks = old?.tracks != snapshot.tracks
        if snapshot.loaded {
            state.duration = resolvedPlaybackDuration(vlcDuration: snapshot.duration)
            state.currentTime = logicalPlaybackTime(fromPlayerTime: snapshot.time, duration: state.duration)
            state.progress = resolvedPlaybackProgress(currentTime: state.currentTime, duration: state.duration, fallbackPosition: 0)
            if abs(snapshot.time - (old?.time ?? snapshot.time)) > 0.01 { hasStartedPlaybackForCurrentItem = true }
        }
        if snapshot.ended {
            if state.status != .ended { saveProgress(); reportServerStopped() }
            state.status = .ended
        } else if mpvPauseRequested || isPlaybackSuspendedForBackground {
            state.status = .paused
        } else {
            state.status = shouldShowPlaybackBuffering() ? .buffering : .playing
            if state.status == .playing { clearPlaybackFailure() }
        }
        let selectionChanged = state.currentSubtitleTrackID != snapshot.subtitle || state.currentAudioTrackID != snapshot.audio
        state.currentAudioTrackID = snapshot.audio
        if mpvSubtitleSelectionRequest == nil {
            state.currentSubtitleTrackID = subtitleIntelligence.isGeneratedPrimary ? -1 : snapshot.subtitle
        }
        if changedTracks || firstLoaded {
            reconcileMPVSubtitleSources()
            func name(_ track: MacMPVTrack) -> String {
                let text = [track.title, track.language, track.codec].filter { !$0.isEmpty }.joined(separator: " · ")
                return text.isEmpty ? String(track.id) : text
            }
            state.audioTracks = snapshot.tracks.filter { $0.type == "audio" }.map {
                MediaTrack(id: $0.id, name: name($0), isExternal: $0.external)
            }
            state.subtitleTracks = [MediaTrack(id: -1, name: NSLocalizedString("Off", comment: ""), isExternal: false)]
                + snapshot.tracks.filter { $0.type == "sub" && !mpvRemovedDuplicateSubtitles.contains($0.id) }.map { MediaTrack(id: $0.id, name: mpvSubtitleDisplayName($0), isExternal: $0.external) }
            for track in snapshot.tracks where track.type == "sub" && !mpvRemovedDuplicateSubtitles.contains(track.id) {
                if let url = track.externalURL { externalSubtitleResolvedTrackIDs[subtitleURLKey(url)] = track.id }
            }
            for (type, property) in [("audio", "aid"), ("sub", "sid")] {
                if type == "sub", subtitleIntelligence.isGeneratedPrimary { continue }
                let tracks = snapshot.tracks.filter { $0.type == type && (type != "sub" || !mpvRemovedDuplicateSubtitles.contains($0.id)) }
                if let selection = pendingEngineTracks[type] {
                    if let id = selection.resolve(embeddedIDs: tracks.filter { !$0.external }.map(\.id)) {
                        pendingEngineTracks[type] = nil
                        setMPVTrackProperty(property, id: id)
                        rememberMPVTrack(id, type: type)
                    }
                    continue
                }
                if let choice = mpvPendingTrackChoices[type],
                   let id = (type == "sub" ? choice.resolveExternalAlias(mpvNativeSubtitleAliases()) : nil) ?? choice.resolve(in: tracks) {
                    setMPVTrackProperty(property, id: id)
                    mpvPendingTrackChoices[type] = nil
                    if type == "sub", choice.resolveExternalAlias(mpvNativeSubtitleAliases()) != nil {
                        rememberMPVTrack(id, type: "sub")
                    }
                    // Track-list can arrive before FILE_LOADED. Do not let its
                    // later query fallback overwrite this successfully restored choice.
                    if type == "audio" { pendingAudioTrackQuery = nil; pendingAudioTrackOrdinal = nil }
                    else { pendingSubtitleTrackQuery = nil; pendingSubtitleTrackOrdinal = nil }
                } else if snapshot.loaded, mpvPendingTrackChoices[type] == nil {
                    let query = type == "audio" ? pendingAudioTrackQuery : pendingSubtitleTrackQuery
                    let ordinal = type == "audio" ? pendingAudioTrackOrdinal : pendingSubtitleTrackOrdinal
                    if let id = IOSMPVTrackPreference.resolve(query: query, ordinal: ordinal, tracks: tracks) {
                        setMPVTrackProperty(property, id: id)
                        if type == "audio" { pendingAudioTrackQuery = nil; pendingAudioTrackOrdinal = nil }
                        else { pendingSubtitleTrackQuery = nil; pendingSubtitleTrackOrdinal = nil }
                    }
                }
            }
            resolveMPVPendingExternalSubtitle()
            if snapshot.loaded {
                for url in externalSubtitleCandidates { attachMPVSubtitle(url) }
                if let url = state.currentItem?.externalSubtitleURL { attachMPVSubtitle(url) }
            }
            if state.currentItem.map({ resolvedPlaybackItemType(for: $0) == .video }) == true { refreshSecondarySubtitleTracks() }
            else { state.subtitleTracks = []; state.currentSubtitleTrackID = -1 }
        }
        if mpvDecodedSecondaryID != nil, old?.subtitle != snapshot.subtitle, mpvSubtitleSelectionRequest == nil {
            configureMPVDecodedSecondary()
        }
        if snapshot.loaded, state.currentItem.map({ resolvedPlaybackItemType(for: $0) == .video }) == true,
           pendingEngineTracks["sub"] == nil, mpvPendingTrackChoices["sub"] == nil,
           pendingSubtitleTrackQuery == nil, pendingSubtitleTrackOrdinal == nil,
           mpvPendingExternalSubtitle == nil, mpvSubtitleSelectionRequest == nil {
            _ = applyAutomaticSubtitleSelectionIfNeeded()
        }
        syncMPVDecodedPrimary()
        if selectionChanged || firstLoaded {
            refreshIntelligentPrimarySubtitle()
            subtitleIntelligence.refreshDefaultAudioTrack()
        }
        updateCurrentSecondarySubtitleParts(at: state.currentTime)
        if snapshot.size.width > 0 { state.videoResolution = "\(Int(snapshot.size.width))×\(Int(snapshot.size.height))" }
        if old?.metadata != snapshot.metadata { applyMPVAudioMetadata(snapshot.metadata) }
        if firstLoaded { setupRemoteCommands() }
        if firstLoaded, !hasReportedServerPlaying { _ = reportServerPlaying() }
        if abs(state.currentTime - lastSavedTime) >= 5 {
            if !hasReportedServerPlaying { _ = reportServerPlaying() }
            lastSavedTime = state.currentTime
            saveProgress()
            reportServerProgress(force: false, reason: "periodic")
        }
        if snapshot.ended && old?.ended != true,
           state.currentItem.map({ resolvedPlaybackItemType(for: $0) == .audio }) == true {
            let attempt = playbackAttemptID
            DispatchQueue.main.async { [weak self] in
                guard let self, self.playbackAttemptID == attempt, self.state.status == .ended else { return }
                _ = self.playNextAudio(autoTriggered: true)
            }
        }
        if abs(state.currentTime - lastNowPlayingRefreshTime) >= 1 || old?.paused != snapshot.paused || old?.ended != snapshot.ended {
            lastNowPlayingRefreshTime = state.currentTime
            updateNowPlayingInfo()
        }
    }

    private func rememberMPVTrack(_ id: Int, type: String) {
        guard let tracks = mpvState?.tracks.filter({ $0.type == type }),
              let choice = MacMPVTrackChoice.selected(id, in: tracks) else { return }
        mpvPendingTrackChoices[type] = nil
        mpvTrackChoices[type] = choice
        if let data = try? JSONEncoder().encode(mpvTrackChoices) { UserDefaults.standard.set(data, forKey: mpvTrackPreferenceKey) }
        // A sidecar belongs to this movie, never inherit its path into another episode.
        if let scope = mpvTrackScopeKey, id < 0 || tracks.first(where: { $0.id == id })?.external == false {
            var inherited = UserDefaults.standard.data(forKey: scope).flatMap {
                try? JSONDecoder().decode([String: MacMPVTrackChoice].self, from: $0)
            } ?? [:]
            inherited[type] = choice
            if let data = try? JSONEncoder().encode(inherited) { UserDefaults.standard.set(data, forKey: scope) }
        }
    }

    private func toggleMPVPlayback() {
        guard let mpvEngine else { return }
        if state.status == .ended { _ = restartCurrentItemFromBeginning(); return }
        if !mpvPauseRequested { pausePlaybackSmoothly(reportReason: "pause"); return }
        invalidatePendingPlaybackControls()
        let attempt = playbackAttemptID
        let control = playbackControlID
        pendingResumeControlID = control
        audioSessionCoordinator.activate { [weak self, weak mpvEngine] ready in
            guard let self, let mpvEngine, self.mpvEngine === mpvEngine,
                  self.isCurrentPlaybackControl(attemptID: attempt, controlID: control) else { return }
            self.pendingResumeControlID = nil
            guard ready else { return }
            self.finishAudioSessionActivation()
            self.resetPlaybackStallDetection()
            self.mpvPauseRequested = false
            MPVPlaybackTransport(engine: mpvEngine).resume()
            self.state.status = .playing
            self.updateNowPlayingInfo()
        }
    }

    private func mpvSubtitleDisplayName(_ track: MacMPVTrack) -> String {
        let preferred = track.externalURL.flatMap { url in
            externalSubtitleDisplayNames[subtitleURLKey(url)] ?? state.secondarySubtitleTracks.first(where: {
                $0.sourceURL.map { subtitleURLKey($0) == subtitleURLKey(url) } == true
            })?.displayName
        }
        return track.subtitleDisplayName(preferredTitle: preferred,
            fallback: "\(NSLocalizedString("Subtitle", comment: "")) \(track.id)")
    }

    private func mpvNativeSubtitleAliases() -> [URL: Int] {
        guard let item = state.currentItem else { return [:] }
        var aliases: [URL: Int] = [:]
        for track in embeddedServerSubtitleTracks(for: item) where !track.isExternal {
            if let url = track.sourceURL, let id = track.primaryTrackID { aliases[url] = id }
        }
        return aliases
    }

    /// Jellyfin/Emby history may retain DeliveryUrl while refreshed metadata uses
    /// the constructed export URL. Compare the same server/item/version/stream,
    /// accounting for UUID spelling, the optional zero start offset and ApiKey.
    private func mpvServerSubtitleIdentity(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return MacMPVTrackChoice.mediaKey(url: url)
        }
        var parts = components.path.split(separator: "/").map(String.init)
        if let videos = parts.lastIndex(where: { $0.lowercased() == "videos" }),
           parts.count == videos + 6 || parts.count == videos + 7,
           parts[videos + 3].lowercased() == "subtitles",
           Int(parts[videos + 4]) != nil,
           parts.last?.lowercased().hasPrefix("stream.") == true,
           parts.count == videos + 6 || parts[videos + 5] == "0" {
            func normalizedID(_ id: String) -> String {
                let compact = id.replacingOccurrences(of: "-", with: "")
                return compact.count == 32 && compact.allSatisfy(\.isHexDigit) ? compact.lowercased() : id
            }
            parts[videos] = "Videos"
            parts[videos + 1] = normalizedID(parts[videos + 1])
            parts[videos + 2] = normalizedID(parts[videos + 2])
            parts[videos + 3] = "Subtitles"
            if parts.count == videos + 7 { parts.remove(at: videos + 5) }
            components.path = "/" + parts.joined(separator: "/")
            components.queryItems = components.queryItems?.filter { $0.name.lowercased() != "apikey" }
        }
        return MacMPVTrackChoice.mediaKey(url: components.url ?? url)
    }

    private func mpvEmbeddedServerSubtitle(for url: URL) -> EmbeddedSubtitleTrack? {
        guard let item = state.currentItem else { return nil }
        let matches = embeddedServerSubtitleTracks(for: item).filter {
            !$0.isExternal && $0.sourceURL.map { mpvServerSubtitleIdentity($0) == mpvServerSubtitleIdentity(url) } == true
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func resolveMPVPendingExternalSubtitle() {
        guard let url = mpvPendingExternalSubtitle, let snapshot = mpvState else { return }
        let native = mpvEmbeddedServerSubtitle(for: url)?.primaryTrackID
        guard let id = native ?? snapshot.tracks.first(where: {
            $0.type == "sub" && $0.externalURL == url && !mpvRemovedDuplicateSubtitles.contains($0.id)
        })?.id else { return }
        mpvPendingExternalSubtitle = nil
        setMPVPrimarySubtitle(id)
        rememberMPVTrack(id, type: "sub")
    }

    private func reconcileMPVSubtitleSources() {
        guard let snapshot = mpvState, let engine = mpvEngine else { return }
        for duplicate in snapshot.tracks where duplicate.type == "sub" && duplicate.external {
            guard let url = duplicate.externalURL,
                  let original = mpvEmbeddedServerSubtitle(for: url), let nativeID = original.primaryTrackID,
                  nativeID != duplicate.id, mpvRemovedDuplicateSubtitles.insert(duplicate.id).inserted else { continue }
            if state.currentSubtitleTrackID == duplicate.id || snapshot.subtitle == duplicate.id {
                setMPVPrimarySubtitle(nativeID)
                rememberMPVTrack(nativeID, type: "sub")
            }
            if mpvDecodedSecondaryID == duplicate.id {
                applySecondarySubtitleTrack(original, persistPreference: true)
            }
            externalSubtitleResolvedTrackIDs.removeValue(forKey: subtitleURLKey(url))
            engine.removeSubtitle(id: duplicate.id)
        }
    }

    private func attachMPVSubtitle(_ url: URL) {
        if let original = mpvEmbeddedServerSubtitle(for: url) {
            // Preserve downloadable fallback for transcoded/unknown track layouts.
            guard mpvState?.loaded == true else { return }
            if original.primaryTrackID != nil {
                resolveMPVPendingExternalSubtitle()
                return
            }
        }
        guard let engine = mpvEngine, mpvAttachedSidecars.insert(url).inserted else { return }
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["smb", "ftp", "ftps", "sftp", "nfs"].contains(scheme), let item = state.currentItem else {
            engine.addSubtitle(url)
            return
        }
        let attempt = playbackAttemptID
        mpvSidecarTasks[url] = Task { @MainActor [weak self, weak engine] in
            var temporary: URL?
            defer {
                if let temporary { try? FileManager.default.removeItem(at: temporary) }
                if self?.playbackAttemptID == attempt { self?.mpvSidecarTasks[url] = nil }
            }
            do {
                let size: UInt64
                let read: (UInt64, Int) async throws -> Data
                if scheme == "smb" {
                    let reader = SMBAudioRangeReader(url: url)
                    size = try await reader.metadata().size
                    read = { try await reader.read(offset: $0, count: $1) }
                } else {
                    let reader = FileAudioRangeReader(url: url, provider: scheme == "ftps" ? "ftp" : scheme,
                        serverID: item.jellyfinServerId, path: url.path, itemID: nil)
                    size = try await reader.metadata().size
                    read = { try await reader.read(offset: $0, count: $1) }
                }
                guard size > 0, size <= 8 * 1024 * 1024 else { throw SubtitleBrowserError.remoteLimit }
                var data = Data()
                while UInt64(data.count) < size {
                    try Task.checkCancellation()
                    data.append(try await read(UInt64(data.count), Int(min(1024 * 1024, size - UInt64(data.count)))))
                }
                try Task.checkCancellation()
                guard let self, self.playbackAttemptID == attempt, let engine, self.mpvEngine === engine else { return }
                let local = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension(url.pathExtension.isEmpty ? "srt" : url.pathExtension)
                temporary = local
                try data.write(to: local, options: .atomic)
                engine.addCachedSubtitle(local, source: url) // engine owns and removes its temporary copy
                temporary = nil
            } catch {
                guard !Task.isCancelled, self?.playbackAttemptID == attempt else { return }
                self?.mpvAttachedSidecars.remove(url) // allow an explicit retry
            }
        }
    }

    private func addMPVSubtitle(_ url: URL) {
        pendingEngineTracks["sub"] = nil
        mpvPendingTrackChoices["sub"] = nil
        pendingSubtitleTrackQuery = nil
        pendingSubtitleTrackOrdinal = nil
        if !externalSubtitleCandidates.contains(url) { externalSubtitleCandidates.append(url) }
        externalSubtitleMediaKey = mediaKey(for: state.currentItem?.url)
        mpvPendingExternalSubtitle = url
        state.currentItem?.externalSubtitleURL = url
        resolveMPVPendingExternalSubtitle()
        if mpvPendingExternalSubtitle != nil { attachMPVSubtitle(url) }
    }
}
