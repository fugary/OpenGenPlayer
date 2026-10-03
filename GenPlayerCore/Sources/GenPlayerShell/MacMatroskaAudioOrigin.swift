#if os(macOS) || os(iOS)
import Foundation

/// Reads only EBML headers and the first audio block timestamp. Compressed packets remain untouched.
/// Track ordinals are taken from Matroska TrackEntry order, never from VLC's numeric ID space.
enum MacMatroskaAudioOrigin {
    private struct Element { let id: UInt64; let start: UInt64; let end: UInt64 }
    struct Layout { let origins: [Double]; let legacyIDs: [Int32]? }
    static func origins(url: URL) throws -> [Double] { try layout(url: url).origins }
    static func layout(url: URL) throws -> Layout {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        func data(_ offset: UInt64, _ length: Int) throws -> Data {
            guard offset <= size, UInt64(length) <= size - offset else { throw MacAudioSubtitleError.unreadable }
            try file.seek(toOffset: offset)
            guard let value = try file.read(upToCount: length), value.count == length else { throw MacAudioSubtitleError.unreadable }
            return value
        }
        func vint(_ offset: UInt64, keepMarker: Bool) throws -> (UInt64, Int, Bool) {
            let first = try data(offset, 1)[0]
            var length = 1, mask: UInt8 = 0x80
            while mask > 0 && first & mask == 0 { length += 1; mask >>= 1 }
            guard mask != 0, length <= (keepMarker ? 4 : 8) else { throw MacAudioSubtitleError.unreadable }
            let bytes = try data(offset, length)
            var value = UInt64(keepMarker ? first : first & ~mask)
            for byte in bytes.dropFirst() { value = value << 8 | UInt64(byte) }
            return (value, length, !keepMarker && value == (UInt64(1) << (7 * length)) - 1)
        }
        func element(_ offset: UInt64, _ limit: UInt64) throws -> Element {
            let (id, a, _) = try vint(offset, keepMarker: true)
            let (length, b, unknown) = try vint(offset + UInt64(a), keepMarker: false)
            let start = offset + UInt64(a + b)
            guard start <= limit, unknown || length <= limit - start else { throw MacAudioSubtitleError.unreadable }
            return Element(id: id, start: start, end: unknown ? limit : start + length)
        }
        func integer(_ value: Element) throws -> UInt64 {
            guard value.end - value.start <= 8 else { throw MacAudioSubtitleError.unreadable }
            return try data(value.start, Int(value.end - value.start)).reduce(0) { $0 << 8 | UInt64($1) }
        }
        var segment: Element?
        var offset: UInt64 = 0
        while offset < size {
            let item = try element(offset, size)
            if item.id == 0x18538067 { segment = item; break }
            offset = item.end
        }
        guard let segment else { throw MacAudioSubtitleError.unreadable }
        var scale = 1_000_000.0
        var audio: [UInt64] = []
        var numberedTracks: [UInt64] = []
        var legacyLayoutKnown = true
        var clusterStarts: [UInt64] = []
        offset = segment.start
        while offset < segment.end {
            try Task.checkCancellation()
            let item = try element(offset, segment.end)
            if item.id == 0x1549A966 {
                var position = item.start
                while position < item.end {
                    let child = try element(position, item.end)
                    if child.id == 0x2AD7B1 { scale = Double(try integer(child)) }
                    position = child.end
                }
            } else if item.id == 0x1654AE6B {
                var position = item.start
                while position < item.end {
                    let entry = try element(position, item.end)
                    if entry.id == 0xAE {
                        var field = entry.start, number: UInt64 = 0, type: UInt64 = 0, delay: UInt64 = 0
                        var codec = ""
                        while field < entry.end {
                            let child = try element(field, entry.end)
                            if child.id == 0xD7 { number = try integer(child) }
                            if child.id == 0x6D80 {
                                // VLC supports one zlib/header-removal encoding. Do not
                                // let unsupported/encrypted entries shift following IDs.
                                var encodingOffset = child.start, encodingCount = 0
                                while encodingOffset < child.end {
                                    let encoding = try element(encodingOffset, child.end)
                                    if encoding.id == 0x6240 {
                                        encodingCount += 1
                                        var settingOffset = encoding.start
                                        while settingOffset < encoding.end {
                                            let setting = try element(settingOffset, encoding.end)
                                            if setting.id == 0x5033, try integer(setting) != 0 { legacyLayoutKnown = false }
                                            if setting.id == 0x5035 { legacyLayoutKnown = false }
                                            if setting.id == 0x5034 {
                                                var compressionOffset = setting.start
                                                while compressionOffset < setting.end {
                                                    let compression = try element(compressionOffset, setting.end)
                                                    if compression.id == 0x4254, ![UInt64(0), 3].contains(try integer(compression)) {
                                                        legacyLayoutKnown = false
                                                    }
                                                    compressionOffset = compression.end
                                                }
                                            }
                                            settingOffset = setting.end
                                        }
                                    }
                                    encodingOffset = encoding.end
                                }
                                if encodingCount != 1 { legacyLayoutKnown = false }
                            }
                            if child.id == 0x83 { type = try integer(child) }
                            if child.id == 0x86, child.end - child.start <= 256 {
                                codec = String(data: try data(child.start, Int(child.end - child.start)), encoding: .utf8) ?? ""
                            }
                            if child.id == 0x56AA { delay = try integer(child) }
                            field = child.end
                        }
                        // VLC 3 registers supported ES in ascending TrackNumber order.
                        // Only infer old IDs when every preceding entry is understood.
                        let supportedCodecs: Set<String> = [
                            "V_MPEG4/ISO/AVC", "V_MPEGH/ISO/HEVC", "V_AV1", "V_VP8", "V_VP9",
                            "V_MS/VFW/FOURCC", "V_MPEG1", "V_MPEG2", "V_MPEG4/ISO/SP", "V_MPEG4/ISO/ASP", "V_FFV1",
                            "A_AAC", "A_AC3", "A_EAC3", "A_DTS", "A_FLAC", "A_OPUS", "A_VORBIS",
                            "A_MPEG/L3", "A_MPEG/L2", "A_PCM/INT/LIT", "A_PCM/INT/BIG", "A_PCM/FLOAT/IEEE",
                            "S_TEXT/UTF8", "S_TEXT/ASS", "S_TEXT/SSA", "S_HDMV/PGS", "S_VOBSUB"]
                        if ![1, 2, 17].contains(type) || !(supportedCodecs.contains(codec) || codec.hasPrefix("A_AAC/")) { legacyLayoutKnown = false }
                        guard number > 0, numberedTracks.count < 1024, !numberedTracks.contains(number) else { throw MacAudioSubtitleError.unreadable }
                        numberedTracks.append(number)
                        if type == 2 {
                            // Delay-bearing codecs need a separate timing contract before being supported.
                            guard delay == 0, number > 0 else { throw MacAudioSubtitleError.unreadable }
                            audio.append(number)
                        }
                    }
                    position = entry.end
                }
            } else if item.id == 0x1F43B675 {
                clusterStarts.append(offset)
            }
            guard item.end > offset else { throw MacAudioSubtitleError.unreadable }
            offset = item.end
        }
        guard !audio.isEmpty, scale.isFinite, scale > 0 else { throw MacAudioSubtitleError.unreadable }
        var starts: [UInt64: Double] = [:]
        for clusterStart in clusterStarts {
            try Task.checkCancellation()
            let cluster = try element(clusterStart, segment.end)
            var position = cluster.start, time: UInt64 = 0
            while position < cluster.end {
                let child = try element(position, cluster.end)
                var block: Element?
                if child.id == 0xE7 { time = try integer(child) }
                if child.id == 0xA3 { block = child }
                if child.id == 0xA0 {
                    var groupPosition = child.start
                    while groupPosition < child.end {
                        let member = try element(groupPosition, child.end)
                        if member.id == 0xA1 { block = member }
                        groupPosition = member.end
                    }
                }
                if let block {
                    let (track, length, _) = try vint(block.start, keepMarker: false)
                    if audio.contains(track), starts[track] == nil {
                        guard block.end - block.start >= UInt64(length + 3) else { throw MacAudioSubtitleError.unreadable }
                        let bytes = try data(block.start + UInt64(length), 2)
                        let relative = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
                        let pts = (Double(time) + Double(relative)) * scale / 1_000_000_000
                        guard pts.isFinite, pts >= 0 else { throw MacAudioSubtitleError.unreadable }
                        starts[track] = pts
                    }
                }
                position = child.end
                if starts.count == audio.count {
                    let ordered = numberedTracks.sorted()
                    return Layout(origins: audio.compactMap { starts[$0] },
                                  legacyIDs: legacyLayoutKnown ? audio.map { Int32(ordered.firstIndex(of: $0)!) } : nil)
                }
            }
        }
        throw MacAudioSubtitleError.unreadable
    }
}
#endif
