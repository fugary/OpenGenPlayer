#if os(macOS) || os(iOS)
import Foundation

/// A bounded ISO-BMFF audio index. No media payload is read while inspecting the movie.
/// Deliberately excludes fragments, encryption, external references and complex edit lists.
struct MP4AudioIndex: Sendable {
    enum Failure: Error { case unsupported, invalid, limit }
    typealias Read = @Sendable (UInt64, Int) async throws -> Data
    struct Sample: Sendable {
        let offset: UInt64
        let size: UInt32
        let time: UInt64
        let ticks: UInt32
        let chunk: Int
    }
    struct Track: Sendable {
        let id: Int32
        let ordinal: Int
        let language: String?
        let scale: UInt32
        let languageBits: UInt16
        let description: Data
        let samples: [Sample]
        let presentationStart: Double
        let presentationEnd: Double
        /// movie seconds = media seconds + offset
        let offset: Double
    }
    struct Segment: Sendable {
        let bytes: Data
        let payloadBytes: Int
        let transferredBytes: Int
        let readCount: Int
    }
    let duration: Double
    let tracks: [Track]
    let metadata: Data

    private struct Box {
        let type: String
        let body: Range<Int>
        let full: Range<Int>
    }
    private struct Blob {
        let data: Data
        func number(_ at: Int, _ count: Int) throws -> UInt64 {
            guard count > 0, count <= 8, at >= 0, at <= data.count - count else { throw Failure.invalid }
            return data[at..<(at + count)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        func boxes(_ range: Range<Int>) throws -> [Box] {
            guard range.lowerBound >= 0, range.upperBound <= data.count else { throw Failure.invalid }
            var result: [Box] = [], p = range.lowerBound
            while p < range.upperBound {
                guard result.count < 10000, range.upperBound - p >= 8 else { throw Failure.limit }
                let short = try number(p, 4)
                let header = short == 1 ? 16 : 8
                let size = short == 1 ? try number(p + 8, 8) : (short == 0 ? UInt64(range.upperBound - p) : short)
                guard size >= header, size <= UInt64(range.upperBound - p) else { throw Failure.invalid }
                let end = p + Int(size)
                result.append(Box(type: String(decoding: data[(p + 4)..<(p + 8)], as: UTF8.self),
                                  body: (p + header)..<end, full: p..<end))
                p = end
            }
            return result
        }
        func one(_ boxes: [Box], _ type: String) throws -> Box {
            let found = boxes.filter { $0.type == type }
            guard found.count == 1, let box = found.first else { throw Failure.invalid }
            return box
        }
        func n(_ box: Box, _ offset: Int, _ count: Int = 4) throws -> UInt64 {
            guard offset >= 0, offset + count <= box.body.count else { throw Failure.invalid }
            return try number(box.body.lowerBound + offset, count)
        }
        func table(_ box: Box, width: Int, prefix: Int = 8) throws -> Int {
            guard try n(box, 0) == 0 else { throw Failure.unsupported }
            let count = try n(box, prefix - 4)
            guard count <= 2_000_000, prefix + Int(count) * width == box.body.count else { throw Failure.invalid }
            return Int(count)
        }
        func clock(_ box: Box) throws -> (UInt32, UInt64, Int) {
            let version = try n(box, 0, 1)
            guard version <= 1 else { throw Failure.unsupported }
            let shift = version == 1 ? 8 : 0
            let scale = UInt32(try n(box, 12 + shift))
            let duration = try n(box, 16 + shift, version == 1 ? 8 : 4)
            guard scale > 0, duration > 0 else { throw Failure.invalid }
            return (scale, duration, version == 1 ? 32 : 20)
        }
    }

    static func inspect(size: UInt64, read: Read) async throws -> Self {
        guard size >= 24, size <= UInt64(Int64.max) else { throw Failure.invalid }
        var offset: UInt64 = 0, atoms = 0, moov: Data?, media: [Range<UInt64>] = []
        let deadline = Date().addingTimeInterval(120)
        while offset < size {
            try Task.checkCancellation()
            guard Date() < deadline else { throw Failure.limit }
            atoms += 1
            guard atoms <= 1024, size - offset >= 8 else { throw Failure.limit }
            let head = Blob(data: try await exact(offset, 8, read: read))
            let short = try head.number(0, 4)
            let type = String(decoding: head.data[4..<8], as: UTF8.self)
            let header: UInt64 = short == 1 ? 16 : 8
            let length: UInt64
            if short == 1 {
                guard size - offset >= 16 else { throw Failure.invalid }
                length = try Blob(data: await exact(offset + 8, 8, read: read)).number(0, 8)
            } else { length = short == 0 ? size - offset : short }
            guard length >= header, length <= size - offset else { throw Failure.invalid }
            if type == "moof" { throw Failure.unsupported }
            if type == "mdat" { media.append((offset + header)..<(offset + length)) }
            if type == "moov" {
                guard moov == nil, length <= 16 * 1024 * 1024 else { throw Failure.limit }
                moov = try await exact(offset + header, Int(length - header), read: read)
            }
            offset += length
        }
        guard let moov, !media.isEmpty else { throw Failure.invalid }
        let blob = Blob(data: moov), children = try Blob(data: moov).boxes(0..<moov.count)
        guard !children.contains(where: { $0.type == "mvex" }) else { throw Failure.unsupported }
        let (movieScale, movieTicks, _) = try blob.clock(blob.one(children, "mvhd"))
        let duration = Double(movieTicks) / Double(movieScale)
        guard duration.isFinite, duration > 0, duration <= 7 * 86400 else { throw Failure.limit }
        var tracks: [Track] = [], indexedSamples = 0, audioOrdinal = 0
        for box in children where box.type == "trak" {
            try Task.checkCancellation()
            let parts = try blob.boxes(box.body)
            let mdia = try blob.boxes(blob.one(parts, "mdia").body)
            let handler = try blob.one(mdia, "hdlr")
            guard try blob.n(handler, 8) == 0x736f756e else { continue } // soun
            audioOrdinal += 1
            guard audioOrdinal <= 16 else { throw Failure.limit }
            do {
                let track = try parseTrack(blob, parts: parts, mdia: mdia, movieScale: movieScale,
                                           media: media, ordinal: audioOrdinal, remainingSamples: 2_000_000 - indexedSamples)
                indexedSamples += track.samples.count
                tracks.append(track)
            } catch Failure.unsupported {
                // One unsupported audio track must not hide other usable AAC tracks.
                // Preserve the container ordinal for VLC names and episode preferences.
                continue
            }
        }
        guard !tracks.isEmpty else { throw Failure.unsupported }
        guard Set(tracks.map(\.id)).count == tracks.count else { throw Failure.invalid }
        return Self(duration: duration, tracks: tracks, metadata: moov)
    }

    private static func parseTrack(_ b: Blob, parts: [Box], mdia: [Box], movieScale: UInt32,
                                   media: [Range<UInt64>], ordinal: Int, remainingSamples: Int) throws -> Track {
        let tkhd = try b.one(parts, "tkhd"), version = try b.n(tkhd, 0, 1)
        guard version <= 1 else { throw Failure.unsupported }
        let id = try b.n(tkhd, version == 1 ? 20 : 12)
        guard id > 0, id <= Int32.max else { throw Failure.invalid }
        let mdhd = try b.one(mdia, "mdhd")
        let (scale, mediaTicks, languageAt) = try b.clock(mdhd)
        let languageBits = UInt16(try b.n(mdhd, languageAt, 2))
        let codes = [10, 5, 0].map { UInt8((languageBits >> $0) & 31) + 96 }
        let language = codes.allSatisfy { (97...122).contains($0) } ? String(bytes: codes, encoding: .ascii) : nil
        let minf = try b.boxes(b.one(mdia, "minf").body)
        let dinf = try b.boxes(b.one(minf, "dinf").body), dref = try b.one(dinf, "dref")
        guard try b.n(dref, 0) == 0, try b.n(dref, 4) == 1 else { throw Failure.unsupported }
        let references = try b.boxes((dref.body.lowerBound + 8)..<dref.body.upperBound)
        guard references.count == 1, references[0].type == "url ", try b.n(references[0], 0) == 1,
              references[0].body.count == 4 else { throw Failure.unsupported }
        let stbl = try b.boxes(b.one(minf, "stbl").body)
        guard !stbl.contains(where: { ["ctts", "stz2", "senc", "saiz", "saio"].contains($0.type) }) else { throw Failure.unsupported }
        let stsd = try b.one(stbl, "stsd")
        guard try b.n(stsd, 0) == 0, try b.n(stsd, 4) == 1 else { throw Failure.unsupported }
        let entries = try b.boxes((stsd.body.lowerBound + 8)..<stsd.body.upperBound)
        guard entries.count == 1, let entry = entries.first, entry.type == "mp4a", entry.body.count >= 28,
              try b.n(entry, 6, 2) == 1, try b.n(entry, 8, 2) == 0 else { throw Failure.unsupported }
        let sampleChildren = try b.boxes((entry.body.lowerBound + 28)..<entry.body.upperBound)
        guard !sampleChildren.contains(where: { $0.type == "sinf" }), sampleChildren.contains(where: { $0.type == "esds" }) else {
            throw Failure.unsupported
        }
        let stsz = try b.one(stbl, "stsz")
        guard try b.n(stsz, 0) == 0 else { throw Failure.unsupported }
        let fixedSize = UInt32(try b.n(stsz, 4)), sampleCount = Int(try b.n(stsz, 8))
        guard sampleCount > 0, sampleCount <= remainingSamples,
              stsz.body.count == 12 + (fixedSize == 0 ? sampleCount * 4 : 0) else { throw Failure.limit }
        var sizes: [UInt32] = []
        for i in 0..<sampleCount {
            let size = fixedSize == 0 ? UInt32(try b.n(stsz, 12 + i * 4)) : fixedSize
            guard size > 0, size <= 1024 * 1024 else { throw Failure.limit }
            sizes.append(size)
        }
        let stts = try b.one(stbl, "stts"), timesCount = try b.table(stts, width: 8)
        var ticks: [UInt32] = []
        for i in 0..<timesCount {
            let count = Int(try b.n(stts, 8 + i * 8)), delta = UInt32(try b.n(stts, 12 + i * 8))
            guard count > 0, delta > 0, count <= sampleCount - ticks.count else { throw Failure.invalid }
            ticks.append(contentsOf: repeatElement(delta, count: count))
        }
        guard ticks.count == sampleCount else { throw Failure.invalid }
        // Roll groups are optional in source MP4s. The sample tables and edit list
        // define their presentation timeline; do not invent an Apple-specific 2112-frame
        // trim when the source omits these groups. Our generated segment declares its
        // own pre-roll explicitly so AVFoundation preserves that indexed timeline.
        let descriptions = try stbl.filter { try $0.type == "sgpd" && b.n($0, 4) == 0x726f6c6c }
        let groups = try stbl.filter { try $0.type == "sbgp" && b.n($0, 4) == 0x726f6c6c }
        if !descriptions.isEmpty || !groups.isEmpty {
            guard descriptions.count == 1, groups.count == 1 else { throw Failure.unsupported }
            let description = descriptions[0], group = groups[0]
            guard description.body.count == 18, try b.n(description, 0) == 0x01000000,
                  try b.n(description, 8) == 2, try b.n(description, 12) == 1,
                  try b.n(description, 16, 2) == 0xffff,
                  group.body.count == 20, try b.n(group, 0) == 0, try b.n(group, 8) == 1,
                  try b.n(group, 12) == UInt64(sampleCount), try b.n(group, 16) == 1 else { throw Failure.unsupported }
        }
        let offsetBoxes = stbl.filter { ["stco", "co64"].contains($0.type) }
        guard offsetBoxes.count == 1, let offsets = offsetBoxes.first else { throw Failure.invalid }
        let width = offsets.type == "co64" ? 8 : 4, chunkCount = try b.table(offsets, width: width)
        let stsc = try b.one(stbl, "stsc"), mappingCount = try b.table(stsc, width: 12)
        var mappings: [(first: Int, count: Int)] = []
        for i in 0..<mappingCount {
            let first = Int(try b.n(stsc, 8 + i * 12)), count = Int(try b.n(stsc, 12 + i * 12))
            guard first > (mappings.last?.first ?? 0), first <= chunkCount, count > 0,
                  count <= sampleCount, try b.n(stsc, 16 + i * 12) == 1 else { throw Failure.invalid }
            mappings.append((first, count))
        }
        guard mappings.first?.first == 1 else { throw Failure.invalid }
        var samples: [Sample] = [], time: UInt64 = 0, mapping = 0
        for chunk in 1...max(1, chunkCount) {
            while mapping + 1 < mappings.count && mappings[mapping + 1].first <= chunk { mapping += 1 }
            var offset = try b.n(offsets, 8 + (chunk - 1) * width, width)
            guard mappings[mapping].count <= sampleCount - samples.count else { throw Failure.invalid }
            for _ in 0..<mappings[mapping].count {
                let i = samples.count, size = sizes[i]
                guard let area = media.first(where: { $0.contains(offset) }), UInt64(size) <= area.upperBound - offset else {
                    throw Failure.invalid
                }
                samples.append(.init(offset: offset, size: size, time: time, ticks: ticks[i], chunk: chunk))
                offset += UInt64(size); time += UInt64(ticks[i])
            }
        }
        guard samples.count == sampleCount, time == mediaTicks else { throw Failure.invalid }
        var leading = 0.0, mediaStart = 0.0, span = Double(time) / Double(scale)
        if let edts = parts.first(where: { $0.type == "edts" }) {
            let elst = try b.one(b.boxes(edts.body), "elst"), v = try b.n(elst, 0, 1)
            guard v <= 1 else { throw Failure.unsupported }
            let count = Int(try b.n(elst, 4)), stride = v == 1 ? 20 : 12
            guard (1...2).contains(count), elst.body.count == 8 + count * stride else { throw Failure.unsupported }
            var hasMedia = false
            for i in 0..<count {
                let p = 8 + i * stride, width = v == 1 ? 8 : 4
                let length = try b.n(elst, p, width), rawStart = try b.n(elst, p + width, width)
                guard try b.n(elst, p + 2 * width) == 0x00010000, length > 0 else { throw Failure.unsupported }
                if rawStart == (v == 1 ? UInt64.max : UInt64(UInt32.max)) {
                    guard i == 0, count == 2 else { throw Failure.unsupported }
                    leading = Double(length) / Double(movieScale)
                } else {
                    guard !hasMedia, rawStart <= time else { throw Failure.unsupported }
                    hasMedia = true; mediaStart = Double(rawStart) / Double(scale)
                    span = Double(length) / Double(movieScale)
                    guard mediaStart + span <= Double(time) / Double(scale) + 0.002 else { throw Failure.invalid }
                }
            }
            guard hasMedia else { throw Failure.unsupported }
        }
        return Track(id: Int32(id), ordinal: ordinal, language: language == "und" ? nil : language, scale: scale,
                     languageBits: languageBits, description: b.data.subdata(in: stsd.full), samples: samples,
                     presentationStart: leading, presentationEnd: leading + span, offset: leading - mediaStart)
    }

    /// Returns an audio-only M4A. Tiny gaps may be coalesced (at most twice the audio bytes);
    /// large video payloads are skipped. Padding never enters the output audio.
    func segment(trackID: Int32, start: Double, end: Double, read: Read) async throws -> Segment? {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end <= duration + 0.000001,
              end - start <= 34.01, let track = tracks.first(where: { $0.id == trackID }) else { throw Failure.invalid }
        let from = max(start, track.presentationStart), to = min(end, track.presentationEnd)
        guard to > from else { return nil }
        let firstTime = (from - track.offset) * Double(track.scale), lastTime = (to - track.offset) * Double(track.scale)
        guard let first = track.samples.firstIndex(where: { Double($0.time + UInt64($0.ticks)) > firstTime }),
              let last = track.samples.lastIndex(where: { Double($0.time) < lastTime }), last >= first else { throw Failure.invalid }
        // Decode two previous AAC packets for overlap/priming, then trim via the edit list.
        let selected = Array(track.samples[max(0, first - 2)...last])
        var payload = Data(), calls = 0, transferred = 0, i = 0
        let deadline = Date().addingTimeInterval(120)
        while i < selected.count {
            try Task.checkCancellation()
            guard Date() < deadline else { throw Failure.limit }
            let offset = selected[i].offset
            var length = Int(selected[i].size), useful = length, next = i + 1
            while next < selected.count, selected[next].offset >= offset + UInt64(length) {
                let gap = selected[next].offset - offset - UInt64(length)
                let newUseful = useful + Int(selected[next].size)
                guard gap <= 4096, UInt64(length) + gap + UInt64(selected[next].size) <= 256 * 1024 else { break }
                let newLength = length + Int(gap) + Int(selected[next].size)
                guard newLength <= newUseful * 2 else { break }
                length = newLength; useful = newUseful; next += 1
            }
            guard transferred + length <= 32 * 1024 * 1024, calls < 8192 else { throw Failure.limit }
            let data = try await Self.exact(offset, length, read: read)
            for sample in selected[i..<next] {
                let position = Int(sample.offset - offset)
                payload += data.subdata(in: position..<(position + Int(sample.size)))
            }
            transferred += length
            calls += 1; i = next
        }
        try Task.checkCancellation()
        let bytes = Self.movie(track: track, samples: selected, payload: payload, duration: end - start,
                               leading: from - start, mediaStart: max(0, firstTime - Double(selected[0].time)),
                               audibleDuration: to - from)
        return Segment(bytes: bytes, payloadBytes: payload.count, transferredBytes: transferred, readCount: calls)
    }

    private static func exact(_ offset: UInt64, _ count: Int, read: Read) async throws -> Data {
        var result = Data()
        while result.count < count {
            try Task.checkCancellation()
            let length = min(1024 * 1024, count - result.count)
            let part = try await read(offset + UInt64(result.count), length)
            guard part.count == length else { throw Failure.invalid }
            result += part
        }
        return result
    }
    private static func u(_ value: UInt64, _ width: Int = 4) -> Data {
        Data((0..<width).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
    }
    private static func atom(_ type: String, _ body: Data) -> Data { u(UInt64(body.count + 8)) + Data(type.utf8) + body }
    private static func full(_ type: String, _ body: Data, flags: UInt64 = 0) -> Data { atom(type, u(flags) + body) }
    private static func movie(track: Track, samples: [Sample], payload: Data, duration: Double,
                              leading: Double, mediaStart: Double, audibleDuration: Double) -> Data {
        let movieScale: UInt64 = 1_000_000, movieTicks = UInt64((duration * Double(movieScale)).rounded())
        let matrix = [UInt64(0x10000),0,0,0,0x10000,0,0,0,0x40000000].reduce(Data()) { $0 + u($1) }
        let mvhd = full("mvhd", Data(repeating: 0, count: 16) + u(movieScale) + u(movieTicks, 8)
            + u(0x10000) + u(0x100, 2) + Data(repeating: 0, count: 10) + matrix
            + Data(repeating: 0, count: 24) + u(2), flags: 0x01000000)
        let tkhd = full("tkhd", Data(repeating: 0, count: 16) + u(1) + u(0) + u(movieTicks, 8)
            + Data(repeating: 0, count: 12) + u(0x100, 2) + u(0, 2) + matrix + u(0) + u(0), flags: 0x01000007)
        var edits = Data(), editCount: UInt64 = 1
        if leading > 0 {
            edits += u(UInt64((leading * Double(movieScale)).rounded()), 8) + u(UInt64.max, 8) + u(0x10000)
            editCount += 1
        }
        edits += u(UInt64((audibleDuration * Double(movieScale)).rounded()), 8)
            + u(UInt64(mediaStart.rounded()), 8) + u(0x10000)
        let edts = atom("edts", full("elst", u(editCount) + edits, flags: 0x01000000))
        let audioTicks = samples.reduce(UInt64(0)) { $0 + UInt64($1.ticks) }
        let mdhd = full("mdhd", Data(repeating: 0, count: 16) + u(UInt64(track.scale)) + u(audioTicks, 8)
            + u(UInt64(track.languageBits), 2) + u(0, 2), flags: 0x01000000)
        let hdlr = full("hdlr", u(0) + Data("soun".utf8) + Data(repeating: 0, count: 12) + Data("Audio\0".utf8))
        let dinf = atom("dinf", full("dref", u(1) + full("url ", Data(), flags: 1)))
        var runs: [(count: UInt64, ticks: UInt32)] = []
        for sample in samples {
            if runs.last?.ticks == sample.ticks { runs[runs.count - 1].count += 1 }
            else { runs.append((1, sample.ticks)) }
        }
        let stts = full("stts", u(UInt64(runs.count)) + runs.reduce(Data()) { $0 + u($1.count) + u(UInt64($1.ticks)) })
        // Preserve audio chunk boundaries as well as packets. AudioMixOutput's resampler
        // is sensitive to its leading buffer layout when converting 44.1 kHz sources.
        var chunks: [(id: Int, count: UInt64, offset: UInt64)] = [], payloadOffset: UInt64 = 0
        for sample in samples {
            if chunks.last?.id == sample.chunk { chunks[chunks.count - 1].count += 1 }
            else { chunks.append((sample.chunk, 1, payloadOffset)) }
            payloadOffset += UInt64(sample.size)
        }
        var mappings = Data(), mappingCount: UInt64 = 0, previousCount: UInt64 = 0
        for (index, chunk) in chunks.enumerated() where chunk.count != previousCount {
            mappings += u(UInt64(index + 1)) + u(chunk.count) + u(1)
            mappingCount += 1; previousCount = chunk.count
        }
        let stsc = full("stsc", u(mappingCount) + mappings)
        let stsz = full("stsz", u(0) + u(UInt64(samples.count)) + samples.reduce(Data()) { $0 + u(UInt64($1.size)) })
        let sgpd = full("sgpd", Data("roll".utf8) + u(2) + u(1) + u(0xffff, 2), flags: 0x01000000)
        let sbgp = full("sbgp", Data("roll".utf8) + u(1) + u(UInt64(samples.count)) + u(1))
        func moov(_ offset: UInt64) -> Data {
            let offsets = chunks.reduce(Data()) { $0 + u(offset + $1.offset) }
            let stco = full("stco", u(UInt64(chunks.count)) + offsets)
            let stbl = atom("stbl", track.description + stts + stsc + stsz + stco + sgpd + sbgp)
            let minf = atom("minf", full("smhd", u(0)) + dinf + stbl)
            return atom("moov", mvhd + atom("trak", tkhd + edts + atom("mdia", mdhd + hdlr + minf)))
        }
        let ftyp = atom("ftyp", Data("M4A ".utf8) + u(0) + Data("M4A isommp42".utf8))
        let header = moov(0), offset = UInt64(ftyp.count + header.count + 8)
        return ftyp + moov(offset) + atom("mdat", payload)
    }
}
#endif
