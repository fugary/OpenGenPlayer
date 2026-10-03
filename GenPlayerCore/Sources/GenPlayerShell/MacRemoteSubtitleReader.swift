#if os(macOS) || os(iOS)
import Foundation
import GenPlayerCore

/// Independent bounded Matroska text reader. Never reads video/audio packet payloads deliberately.
/// A reader belongs to one load task; all state is accessed sequentially by that task.
final class MacRemoteSubtitleReader {
    enum Failure: Error { case invalid, unsupported, bitmap, limit, trackMismatch }
    struct Result { let parts: [SubtitlePart]; let indexed: Bool }
    private struct Element { let id: UInt64; let start: UInt64; let end: UInt64 }
    private struct Track { let number: UInt64; let codec: String; let encoded: Bool }
    private struct Cue { let start: Double; let end: Double?; let text: String }
    private struct Reference { let cluster: UInt64; let relative: UInt64?; let duration: UInt64? }
    private let size: UInt64
    private let read: (UInt64, Int) async throws -> Data
    private let byteLimit: Int
    private let requestLimit: Int
    private var bytesRead = 0
    private var requests = 0
    private var pages: [UInt64: Data] = [:]
    private var pageOrder: [UInt64] = []
    private var elementCount = 0
    private var visitedBlocks = Set<UInt64>()

    init(size: UInt64, byteLimit: Int = 64 * 1024 * 1024, requestLimit: Int = 16384,
         read: @escaping (UInt64, Int) async throws -> Data) {
        self.size = size; self.byteLimit = byteLimit; self.requestLimit = requestLimit; self.read = read
    }

    func load(subtitleOrdinal: Int, expectedSubtitleCount: Int, expectedTrackNumbers: [UInt64]? = nil) async throws -> Result {
        var offset: UInt64 = 0
        var segment: Element?
        while offset < size {
            let item = try await element(offset, limit: size, allowUnknown: true)
            if item.id == 0x18538067 { segment = item; break }
            offset = item.end
        }
        guard let segment else { throw Failure.invalid }
        var tracks: [Track] = []
        var scale = 1_000_000.0
        var clusters: [Element] = []
        var cueElements: [Element] = []
        offset = segment.start
        while offset < segment.end {
            let item = try await element(offset, limit: segment.end)
            switch item.id {
            case 0x1549A966:
                for field in try await children(item) where field.id == 0x2AD7B1 { scale = Double(try await integer(field)) }
            case 0x1654AE6B:
                for entry in try await children(item) where entry.id == 0xAE {
                    var number: UInt64 = 0, type: UInt64 = 0, codec = "", encoded = false
                    for field in try await children(entry) {
                        switch field.id {
                        case 0xD7: number = try await integer(field)
                        case 0x83: type = try await integer(field)
                        case 0x86: codec = try await string(field)
                        case 0x6D80: encoded = true // Content compression/encryption requires another decoder.
                        case 0x23314F: encoded = true // Deprecated per-track timestamp scaling.
                        case 0x56AA: if try await integer(field) != 0 { encoded = true }
                        default: break
                        }
                    }
                    if type == 0x11 { tracks.append(Track(number: number, codec: codec, encoded: encoded)) }
                }
            case 0x1F43B675: clusters.append(item)
            case 0x1C53BB6B: cueElements.append(item)
            default: break
            }
            offset = item.end
        }
        guard tracks.count == expectedSubtitleCount, tracks.indices.contains(subtitleOrdinal),
              Set(tracks.map(\.number)).count == tracks.count else { throw Failure.trackMismatch }
        if let expectedTrackNumbers, tracks.map(\.number) != expectedTrackNumbers { throw Failure.trackMismatch }
        let track = tracks[subtitleOrdinal]
        guard track.number > 0, scale > 0, scale.isFinite else { throw Failure.invalid }
        if ["S_HDMV/PGS", "S_VOBSUB", "S_DVBSUB"].contains(track.codec) { throw Failure.bitmap }
        guard !track.encoded, ["S_TEXT/UTF8", "S_TEXT/ASS", "S_TEXT/SSA", "S_TEXT/WEBVTT"].contains(track.codec) else {
            throw Failure.unsupported
        }
        var references: [Reference] = []
        for cues in cueElements {
            for point in try await children(cues) where point.id == 0xBB {
                for position in try await children(point) where position.id == 0xB7 {
                    var number: UInt64 = 0, cluster: UInt64?, relative: UInt64?, duration: UInt64?
                    for field in try await children(position) {
                        switch field.id {
                        case 0xF7: number = try await integer(field)
                        case 0xF1: cluster = try await integer(field)
                        case 0xF0: relative = try await integer(field)
                        case 0xB2: duration = try await integer(field)
                        default: break
                        }
                    }
                    if number == track.number, let cluster {
                        guard cluster < segment.end - segment.start else { throw Failure.invalid }
                        references.append(Reference(cluster: segment.start + cluster, relative: relative, duration: duration))
                    }
                }
            }
        }
        var cues: [Cue] = []
        if references.isEmpty {
            for cluster in clusters { cues += try await scan(cluster: cluster, track: track, scale: scale) }
        } else {
            var scanned = Set<UInt64>()
            for reference in references {
                try Task.checkCancellation()
                let cluster = try await element(reference.cluster, limit: segment.end)
                guard cluster.id == 0x1F43B675 else { throw Failure.invalid }
                if let relative = reference.relative {
                    guard relative < cluster.end - cluster.start else { throw Failure.invalid }
                    let timestamp = try await clusterTimestamp(cluster)
                    let block = try await element(cluster.start + relative, limit: cluster.end)
                    if let cue = try await cue(block, timestamp: timestamp, duration: reference.duration, track: track, scale: scale) {
                        cues.append(cue)
                    }
                } else if scanned.insert(reference.cluster).inserted {
                    cues += try await scan(cluster: cluster, track: track, scale: scale)
                }
            }
        }
        let sorted = cues.sorted { $0.start < $1.start }
        let parts = sorted.enumerated().compactMap { index, cue -> SubtitlePart? in
            // Same fallback as local subtitle extraction when a file omits duration information.
            let nextStart = sorted.dropFirst(index + 1).first { $0.start > cue.start }?.start
            let end = cue.end ?? min(nextStart ?? (cue.start + 3), cue.start + 5)
            guard cue.start.isFinite, end.isFinite, end > cue.start else { return nil }
            return SubtitlePart(start: cue.start, end: end, text: NSAttributedString(string: cue.text))
        }
        return Result(parts: parts, indexed: !references.isEmpty)
    }

    private func scan(cluster: Element, track: Track, scale: Double) async throws -> [Cue] {
        let timestamp = try await clusterTimestamp(cluster)
        var result: [Cue] = [], offset = cluster.start
        while offset < cluster.end {
            let item = try await element(offset, limit: cluster.end)
            if [0xA3, 0xA0].contains(item.id),
               let value = try await cue(item, timestamp: timestamp, duration: nil, track: track, scale: scale) { result.append(value) }
            offset = item.end
        }
        return result
    }

    private func clusterTimestamp(_ cluster: Element) async throws -> UInt64 {
        var offset = cluster.start
        while offset < cluster.end {
            let item = try await element(offset, limit: cluster.end)
            if item.id == 0xE7 { return try await integer(item) }
            offset = item.end
        }
        throw Failure.invalid
    }

    private func cue(_ item: Element, timestamp: UInt64, duration: UInt64?, track: Track, scale: Double) async throws -> Cue? {
        var block = item
        var duration = duration
        if item.id == 0xA0 {
            let fields = try await children(item)
            guard let member = fields.first(where: { $0.id == 0xA1 }) else { throw Failure.invalid }
            block = member
            if let field = fields.first(where: { $0.id == 0x9B }) { duration = try await integer(field) }
        } else if item.id != 0xA3 { throw Failure.invalid }
        guard visitedBlocks.insert(block.start).inserted else { return nil }
        let header = try await data(block.start, count: Int(min(12, block.end - block.start)))
        let (number, length, unknown) = try Self.vint(header, at: 0, marker: false)
        guard !unknown, header.count >= length + 3 else { throw Failure.invalid }
        guard number == track.number else { return nil }
        guard header[length + 2] & 0x06 == 0 else { throw Failure.unsupported } // No lacing for text.
        let bodyStart = block.start + UInt64(length + 3)
        guard block.end > bodyStart, block.end - bodyStart <= 2 * 1024 * 1024 else { throw Failure.limit }
        let payload = try await data(bodyStart, count: Int(block.end - bodyStart))
        guard var text = String(data: payload, encoding: .utf8) else { throw Failure.invalid }
        if track.codec == "S_TEXT/ASS" || track.codec == "S_TEXT/SSA" {
            let fields = text.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9 else { throw Failure.invalid }
            text = String(fields[8])
        }
        text = SubtitleModel.cleanSubtitleText(text.replacingOccurrences(of: "\0", with: ""))
        guard !text.isEmpty else { return nil }
        let relative = Int16(bitPattern: UInt16(header[length]) << 8 | UInt16(header[length + 1]))
        let start = max(0, (Double(timestamp) + Double(relative)) * scale / 1_000_000_000)
        return Cue(start: start, end: duration.map { start + Double($0) * scale / 1_000_000_000 }, text: text)
    }

    private func children(_ parent: Element) async throws -> [Element] {
        var offset = parent.start, result: [Element] = []
        while offset < parent.end {
            let child = try await element(offset, limit: parent.end)
            result.append(child); offset = child.end
        }
        return result
    }

    private func element(_ offset: UInt64, limit: UInt64, allowUnknown: Bool = false) async throws -> Element {
        try Task.checkCancellation()
        elementCount += 1
        guard elementCount <= 1_000_000 else { throw Failure.limit }
        guard offset < limit, limit <= size else { throw Failure.invalid }
        let header = try await data(offset, count: Int(min(12, limit - offset)))
        let (id, a, _) = try Self.vint(header, at: 0, marker: true)
        let (length, b, unknown) = try Self.vint(header, at: a, marker: false)
        let start = offset + UInt64(a + b)
        guard start <= limit, !unknown || allowUnknown,
              unknown || length <= limit - start else { throw Failure.invalid }
        return Element(id: id, start: start, end: unknown ? limit : start + length)
    }

    private static func vint(_ bytes: Data, at offset: Int, marker: Bool) throws -> (UInt64, Int, Bool) {
        guard offset < bytes.count, bytes[offset] != 0 else { throw Failure.invalid }
        var mask: UInt8 = 0x80, length = 1
        while bytes[offset] & mask == 0 { mask >>= 1; length += 1 }
        guard length <= (marker ? 4 : 8), offset + length <= bytes.count else { throw Failure.invalid }
        var value = UInt64(marker ? bytes[offset] : bytes[offset] & ~mask)
        for byte in bytes[(offset + 1)..<(offset + length)] { value = value << 8 | UInt64(byte) }
        return (value, length, !marker && value == (UInt64(1) << (7 * length)) - 1)
    }

    private func integer(_ item: Element) async throws -> UInt64 {
        guard item.end > item.start, item.end - item.start <= 8 else { throw Failure.invalid }
        return try await data(item.start, count: Int(item.end - item.start)).reduce(0) { $0 << 8 | UInt64($1) }
    }
    private func string(_ item: Element) async throws -> String {
        guard item.end - item.start <= 1024 else { throw Failure.invalid }
        guard let value = String(data: try await data(item.start, count: Int(item.end - item.start)), encoding: .utf8) else {
            throw Failure.invalid
        }
        return value
    }
    private func data(_ offset: UInt64, count: Int) async throws -> Data {
        try Task.checkCancellation()
        guard count > 0, offset < size, UInt64(count) <= size - offset else { throw Failure.invalid }
        var result = Data(), position = offset
        while result.count < count {
            let base = position / 4096 * 4096
            let page: Data
            if let cached = pages[base] { page = cached }
            else {
                let length = Int(min(4096, size - base))
                guard length <= byteLimit - bytesRead, requests < requestLimit else { throw Failure.limit }
                bytesRead += length; requests += 1
                page = try await read(base, length)
                try Task.checkCancellation()
                guard page.count == length else { throw Failure.invalid }
                pages[base] = page; pageOrder.append(base)
                if pageOrder.count > 32 { pages.removeValue(forKey: pageOrder.removeFirst()) }
            }
            let from = Int(position - base), length = min(count - result.count, page.count - from)
            result.append(page[from..<(from + length)])
            position += UInt64(length)
        }
        return result
    }
}
#endif
