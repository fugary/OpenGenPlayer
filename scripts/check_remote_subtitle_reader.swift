import Foundation
import GenPlayerCore

extension SubtitleBrowserChecks {
    private static func uint(_ number: UInt64) -> Data {
        Data((0..<8).reversed().map { UInt8(truncatingIfNeeded: number >> ($0 * 8)) })
    }
    private static func ebml(_ id: UInt64, _ content: Data) -> Data {
        var idBytes = Array(uint(id))
        while idBytes.first == 0 { idBytes.removeFirst() }
        var length = 1
        while content.count >= (1 << (7 * length)) - 1 { length += 1 }
        let size = UInt64(content.count) | (UInt64(1) << (7 * length))
        return Data(idBytes) + uint(size).suffix(length) + content
    }
    private static func value(_ id: UInt64, _ number: UInt64) -> Data { ebml(id, uint(number)) }
    private static func track(_ number: UInt64, _ codec: String, encoded: Bool = false) -> Data {
        ebml(0xAE, value(0xD7, number) + value(0x83, 17) + ebml(0x86, Data(codec.utf8))
             + (encoded ? ebml(0x6D80, Data()) : Data()))
    }
    private static func packet(_ track: UInt8, _ time: Int16, _ text: String, flags: UInt8 = 0) -> Data {
        let time = UInt16(bitPattern: time)
        return Data([0x80 | track, UInt8(truncatingIfNeeded: time >> 8), UInt8(truncatingIfNeeded: time), flags]) + Data(text.utf8)
    }
    private static func fixture(indexed: Bool = false, relative: Bool = true, codec: String = "S_TEXT/ASS",
                                encoded: Bool = false, flags: UInt8 = 0, unknownSegment: Bool = false) -> Data {
        let info = ebml(0x1549A966, value(0x2AD7B1, 1_000_000))
        let tracks = ebml(0x1654AE6B, track(2, "S_TEXT/UTF8") + track(3, codec, encoded: encoded))
        let stamp = value(0xE7, 10_000)
        let first = ebml(0xA0, ebml(0xA1, packet(2, -1000, "other track")) + value(0x9B, 2000))
        // A large video packet must be skipped by its size, not downloaded to find subtitle packets.
        let video = ebml(0xA3, Data([0x81, 0, 0, 0]) + Data(repeating: 0x7F, count: 512 * 1024))
        let second = ebml(0xA0, ebml(0xA1, packet(3, 500, "0,0,Default,,0,0,0,,{\\i1}Hello\\N世界", flags: flags)) + value(0x9B, 2500))
        let cluster = ebml(0x1F43B675, stamp + first + video + second)
        let position = value(0xF7, 3) + value(0xF1, UInt64(info.count + tracks.count))
            + (relative ? value(0xF0, UInt64(stamp.count + first.count + video.count)) : Data()) + value(0xB2, 2500)
        let cues = indexed ? ebml(0x1C53BB6B, ebml(0xBB, value(0xB3, 10_500) + ebml(0xB7, position))) : Data()
        let content = info + tracks + cluster + cues
        return unknownSegment ? Data([0x18, 0x53, 0x80, 0x67, 0xFF]) + content : ebml(0x18538067, content)
    }
    @MainActor static func checkRemoteReader() async throws {
        for indexed in [false, true] {
            for relative in [false, true] {
                let bytes = fixture(indexed: indexed, relative: relative, unknownSegment: relative)
                var readBytes = 0
                let reader = MacRemoteSubtitleReader(size: UInt64(bytes.count)) { offset, count in
                    readBytes += count
                    return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
                }
                let result = try await reader.load(subtitleOrdinal: 1, expectedSubtitleCount: 2)
                expect(result.parts.count == 1, "Selected subtitle only, indexed=\(indexed), relative=\(relative)")
                expect(result.parts[0].text?.string == "Hello\n世界", "ASS packet fields and styles removed")
                expect(result.parts[0].start == 10.5 && result.parts[0].end == 13, "Timestamp scale, block offset and duration")
                expect(result.indexed == indexed, "Index coverage is reported separately from full scan")
                expect(readBytes < 32 * 1024, "Large video payload skipped")
            }
        }
        let bytes = fixture()
        let loader = IOSRemoteSubtitleLoader()
        var networkReads = 0
        var stamp = "v1"
        let metadata: () async throws -> IOSRemoteSubtitleLoader.Version = {
            .init(size: UInt64(bytes.count), stamp: stamp)
        }
        let read: (UInt64, Int) async throws -> Data = { offset, count in
            networkReads += 1
            return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        }
        let loaded = try await loader.load(identity: "attempt-A", ordinal: 1, count: 2, trackNumbers: [2, 3], metadata: metadata, read: read)
        expect(loaded.entries.first?.text == "Hello\n世界" && !loaded.isPartial, "iOS adapter exposes exact selected subtitle and full-scan coverage")
        let initialReads = networkReads
        _ = try await loader.load(identity: "attempt-A", ordinal: 1, count: 2, trackNumbers: [2, 3], metadata: metadata, read: read)
        expect(networkReads == initialReads, "Browser and translation reuse validated in-memory subtitle data")
        stamp = "v2"
        _ = try await loader.load(identity: "attempt-A", ordinal: 1, count: 2, trackNumbers: [2, 3], metadata: metadata, read: read)
        expect(networkReads > initialReads, "Changed file version cannot reuse cached subtitle data")
        let otherTrack = try await loader.load(identity: "attempt-A", ordinal: 0, count: 2, trackNumbers: [2, 3], metadata: metadata, read: read)
        expect(otherTrack.entries.first?.text == "other track", "Cache isolates selected tracks")
        let secondaryTimeline = SubtitleTimeline(parts: otherTrack.entries.map {
            SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text))
        })
        expect(secondaryTimeline.activeParts(at: 9).first?.text?.string == "other track",
               "Remote secondary uses selected document on the ordinary display timeline")
        expect(secondaryTimeline.activeParts(at: 11).isEmpty, "Remote secondary clears at the cue end")
        expect(otherTrack.activeIDs(at: 8, offset: -1) == [otherTrack.entries[0].id],
               "Remote secondary browser offset matches the existing time-plus-delay renderer")
        let readsBeforeSecondSlot = networkReads
        _ = try await loader.load(identity: "attempt-A", ordinal: 0, count: 2, trackNumbers: [2, 3], metadata: metadata, read: read)
        expect(networkReads == readsBeforeSecondSlot, "Both subtitle slots can reuse the same completed container track")
        let previousReads = networkReads
        _ = try await loader.load(identity: "attempt-B", ordinal: 1, count: 2, trackNumbers: [2, 3], metadata: metadata, read: read)
        expect(networkReads > previousReads, "Cache isolates playback attempts")
        for numbers: [UInt64] in [[], [2], [2, 2], [0, 3], [3, 2]] {
            do {
                _ = try await loader.load(identity: "attempt-A", ordinal: 1, count: 2, trackNumbers: numbers, metadata: metadata, read: read)
                preconditionFailure("Ambiguous or reordered track IDs must fail")
            } catch SubtitleBrowserError.unreadable { expect(true, "iOS adapter rejects ambiguous or reordered container identities") }
        }
        var metadataRequests = 0
        do {
            _ = try await loader.load(identity: "changed-during-read", ordinal: 1, count: 2, trackNumbers: [2, 3], metadata: {
                metadataRequests += 1
                return .init(size: UInt64(bytes.count), stamp: String(metadataRequests))
            }, read: read)
            preconditionFailure("Changing files must not publish subtitle text")
        } catch let error as URLError { expect(error.code == .resourceUnavailable, "iOS adapter checks version again after reading") }
        for codec in ["S_TEXT/ASS", "S_HDMV/PGS"] {
            let indexedBytes = fixture(indexed: true, codec: codec)
            do {
                let result = try await loader.load(identity: codec, ordinal: 1, count: 2, trackNumbers: [2, 3], metadata: {
                    .init(size: UInt64(indexedBytes.count), stamp: "indexed")
                }, read: { offset, count in indexedBytes.subdata(in: Int(offset)..<(Int(offset) + count)) })
                expect(result.isPartial && result.partialStatusKey == "SB.Indexed", "Indexed remote subtitle coverage remains explicitly partial")
            } catch SubtitleBrowserError.bitmap { expect(codec == "S_HDMV/PGS", "Bitmap subtitles retain actionable browser error") }
        }
        let cancelledCacheHit = Task {
            try await loader.load(identity: "attempt-A", ordinal: 1, count: 2, trackNumbers: [2, 3], metadata: metadata, read: read)
        }
        cancelledCacheHit.cancel()
        do { _ = try await cancelledCacheHit.value; preconditionFailure("Cancelled cache loads must fail") }
        catch is CancellationError { expect(true, "Even cached iOS subtitle loads honor cancellation") }
        let localURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mkv")
        try bytes.write(to: localURL)
        defer { try? FileManager.default.removeItem(at: localURL) }
        let descriptors = try await MacSubtitleBrowserLocalTracks.readDescriptors(from: localURL)
        expect(descriptors.map(\.codec) == ["srt", "ass"] && descriptors.map(\.trackIndex) == [0, 1],
               "Background local metadata read preserves subtitle formats and ordering")
        let cancelledMetadata = Task { try await MacSubtitleBrowserLocalTracks.readDescriptors(from: localURL) }
        cancelledMetadata.cancel()
        do { _ = try await cancelledMetadata.value; preconditionFailure("Cancelled metadata must not be returned") }
        catch is CancellationError { expect(true, "Cancelled browser metadata load cannot publish a result") }
        let first = try await MacRemoteSubtitleReader(size: UInt64(bytes.count)) { offset, count in
            bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        }.load(subtitleOrdinal: 0, expectedSubtitleCount: 2)
        expect(first.parts.count == 1 && first.parts[0].text?.string == "other track", "Ordinal maps exact subtitle stream")
        expect(first.parts[0].start == 9 && first.parts[0].end == 11, "Signed negative block timestamp")

        let exact = try await MacRemoteSubtitleReader(size: UInt64(bytes.count)) { offset, count in
            bytes.subdata(in: Int(offset)..<(Int(offset) + count))
        }.load(subtitleOrdinal: 1, expectedSubtitleCount: 2, expectedTrackNumbers: [2,3])
        expect(exact.parts.first?.text?.string == "Hello\n世界", "mpv source IDs match exact Matroska track order")
        do {
            _ = try await MacRemoteSubtitleReader(size: UInt64(bytes.count)) { offset, count in
                bytes.subdata(in: Int(offset)..<(Int(offset) + count))
            }.load(subtitleOrdinal: 1, expectedSubtitleCount: 2, expectedTrackNumbers: [3,2])
            preconditionFailure("Reordered source IDs must not silently read another subtitle")
        } catch MacRemoteSubtitleReader.Failure.trackMismatch {
            expect(true, "mpv mismatched source IDs fail without switching tracks")
        }

        let plain = ebml(0x18538067, ebml(0x1549A966, value(0x2AD7B1, 2_000_000))
            + ebml(0x1654AE6B, track(1, "S_TEXT/UTF8"))
            + ebml(0x1F43B675, value(0xE7, 1000)
                + ebml(0xA3, packet(1, -100, "first")) + ebml(0xA3, packet(1, 200, "second"))))
        let simple = try await MacRemoteSubtitleReader(size: UInt64(plain.count)) { offset, count in
            plain.subdata(in: Int(offset)..<(Int(offset) + count))
        }.load(subtitleOrdinal: 0, expectedSubtitleCount: 1)
        expect(simple.parts.count == 2, "UTF8 SimpleBlock text is supported")
        expect(simple.parts[0].start == 1.8 && simple.parts[1].start == 2.4, "Non-default timestamp scale")
        expect(simple.parts[0].end == 2.4 && simple.parts[1].end == 5.4, "Missing duration uses bounded next-cue fallback")

        let failures: [(Data, Int, Int, Int, Int, MacRemoteSubtitleReader.Failure)] = [
            (bytes, 1, 1, 1_000_000, 100, .trackMismatch),
            (bytes, 2, 2, 1_000_000, 100, .trackMismatch),
            (fixture(codec: "S_HDMV/PGS"), 1, 2, 1_000_000, 100, .bitmap),
            (fixture(encoded: true), 1, 2, 1_000_000, 100, .unsupported),
            (fixture(flags: 2), 1, 2, 1_000_000, 100, .unsupported),
            (bytes, 1, 2, 10, 100, .limit),
            (bytes, 1, 2, 1_000_000, 1, .limit),
            (Data([0, 0, 0]), 0, 1, 1_000_000, 100, .invalid),
            (Data(bytes.prefix(30)), 0, 1, 1_000_000, 100, .invalid)
        ]
        for (data, ordinal, count, budget, requests, expected) in failures {
            do {
                _ = try await MacRemoteSubtitleReader(size: UInt64(data.count), byteLimit: budget, requestLimit: requests) { offset, count in
                    data.subdata(in: Int(offset)..<(Int(offset) + count))
                }.load(subtitleOrdinal: ordinal, expectedSubtitleCount: count)
                preconditionFailure("Expected \(expected)")
            } catch let actual as MacRemoteSubtitleReader.Failure {
                expect(actual == expected, "Reject unsafe or ambiguous input: \(expected)")
            }
        }
        do {
            _ = try await MacRemoteSubtitleReader(size: UInt64(bytes.count)) { _, _ in Data() }
                .load(subtitleOrdinal: 0, expectedSubtitleCount: 2)
            preconditionFailure("Expected short read to fail")
        } catch MacRemoteSubtitleReader.Failure.invalid { expect(true, "Short transport reads rejected") }

        var pending: CheckedContinuation<Data, Never>?
        let task = Task {
            try await MacRemoteSubtitleReader(size: UInt64(bytes.count)) { _, count in
                await withCheckedContinuation { pending = $0 }
            }.load(subtitleOrdinal: 0, expectedSubtitleCount: 2)
        }
        while pending == nil { await Task.yield() }
        task.cancel()
        pending?.resume(returning: Data(bytes.prefix(4096)))
        do { _ = try await task.value; preconditionFailure("Cancelled load must not return cues") }
        catch is CancellationError { expect(true, "Cancellation checked after late network response") }
    }
}
