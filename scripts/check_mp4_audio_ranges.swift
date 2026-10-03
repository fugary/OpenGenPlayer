import Foundation
import AVFoundation

actor MP4FileProbe {
    let handle: FileHandle
    let size: UInt64
    var transferred = 0
    var calls = 0
    var revision = "fixture-v1"
    init(_ url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }
    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        transferred += data.count; calls += 1
        return data
    }
    func metadata() -> MP4AudioAccess.Version { .init(size: size, stamp: revision) }
    func stats() -> (Int, Int) { (transferred, calls) }
    func replace() { revision = "fixture-v2" }
}

extension AudioSubtitleChecks {
    @available(macOS 26.0, *)
    @MainActor static func mp4Checks(fixtures: URL, root: URL) async throws {
        let logins: [(String?, String, String, String)] = [
            (nil, "guest", "", ""), ("gary", "gary", "", ""),
            ("CORP;gary", "gary", "CORP", ""), ("MAC\\gary", "gary", "", "MAC"),
            ("CORP;MAC\\gary", "gary", "CORP", "MAC"),
            ("gary@example.com", "gary@example.com", "", ""),
            ("研发;工作站\\用户", "用户", "研发", "工作站"), ("", "", "", ""),
            (";gary", "gary", "", ""), ("a;b;c", "a;b;c", "", ""),
            ("a\\b\\c", "guest", "", "")
        ]
        for (number, example) in logins.enumerated() {
            let login = SMBAudioLogin(user: example.0)
            check(login.user == example.1 && login.domain == example.2 && login.workstation == example.3,
                  "SMB account syntax matches browsing case \(number + 1)")
        }
        let credentials = URLComponents(string: "smb://CORP%3BMAC%5Cgary:test%3B%5C%40@fixture.invalid/share/movie.mp4")!
        let login = SMBAudioLogin(user: credentials.user)
        check(login.user == "gary" && login.domain == "CORP" && login.workstation == "MAC" && credentials.password == "test;\\@",
              "SMB percent-encoded account is decoded without interpreting password separators")
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        func samples(_ url: URL) throws -> [Float] {
            let file = try AVAudioFile(forReading: url)
            var result: [Float] = []
            while file.framePosition < file.length {
                let count = AVAudioFrameCount(min(8192, file.length - file.framePosition))
                let data = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
                try file.read(into: data, frameCount: count)
                guard data.frameLength > 0 else { break }
                result.append(contentsOf: UnsafeBufferPointer(start: data.floatChannelData![0], count: Int(data.frameLength)))
            }
            return result
        }
        for name in ["tail", "head", "co64", "rate44100"] {
            let decodeFormat = AVAudioFormat(standardFormatWithSampleRate: name == "rate44100" ? 44100 : 48000, channels: 1)!
            let file = fixtures.appendingPathComponent(name + ".mp4"), probe = try MP4FileProbe(file)
            let access = MP4AudioAccess(identity: "fixture/" + name,
                metadata: { await probe.metadata() }, read: { try await probe.read($0, $1) })
            let source = try await MacMP4AudioSubtitles.inspect(access, url: URL(string: "smb://fixture.invalid/\(name).mp4")!)
            let before = await probe.stats(), size = probe.size
            check(Double(before.0) < Double(size) * 0.02, "\(name): inspection skips media payload")
            let native = try await MacAudioSubtitleSource.inspect(file)
            check(source.tracks.map(\.id) == native.tracks.map(\.id), "\(name): original audio IDs")
            check(source.tracks.count == (name == "rate44100" ? 1 : 2), "\(name): audio track count")
            check(abs(source.duration - native.duration) < 0.002, "\(name): movie duration")
            for track in source.tracks {
                let ranges = [(0.0, 32.0), (28.0, 62.0), (58.0, source.duration), (28.1234, 31.9876), (0, 1)]
                for (start, end) in ranges {
                    let reference = root.appendingPathComponent(UUID().uuidString + "-reference.caf"), output = root.appendingPathComponent(UUID().uuidString + "-range.caf")
                    try await MacAudioSubtitleEngine.writeAudio(source: native, trackID: track.id,
                        start: start, end: end, format: decodeFormat, to: reference)
                    let old = await probe.stats()
                    try await MacAudioSubtitleEngine.writeAudio(source: source, trackID: track.id,
                        start: start, end: end, format: decodeFormat, to: output)
                    let stats = await probe.stats()
                    let a = try samples(reference), b = try samples(output)
                    check(a.count == b.count && !a.isEmpty, "\(name): PCM length matches original \(start)-\(end), reference=\(a.count), actual=\(b.count)")
                    // Both paths use the production decoder; allow rounding of a media-timescale tick.
                    var energy = 0.0, error = 0.0
                    for (a, b) in zip(a, b) { energy += Double(a * a); error += Double((a - b) * (a - b)) }
                    let normalized = error / max(energy, 0.000001)
                    check(normalized < 0.0001, "\(name): selected track \(track.id) aligned \(start)-\(end), error=\(normalized)")
                    if name == "tail", track.ordinal == 1, start == 28 {
                        let durationBytes = Double(size) * (end - start) / source.duration
                        check(Double(stats.0 - old.0) < durationBytes * 0.1, "audio ranges transfer less than 10% of equivalent mixed media in fixture")
                        print("MP4_RANGE_RESULT file_bytes=\(size) metadata_bytes=\(before.0) seconds=34 audio_range_bytes=\(stats.0 - old.0) requests=\(stats.1 - old.1)")
                    }
                }
            }
            if name == "rate44100" || name == "tail" {
                let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                let output = root.appendingPathComponent("resample-range.caf")
                try await MacAudioSubtitleEngine.writeAudio(source: source, trackID: source.tracks[0].id,
                    start: 28, end: 62, format: format, to: output)
                let bytes = try Data(contentsOf: fixtures.appendingPathComponent("reference-\(name)-16000.f32"))
                let a: [Float] = bytes.withUnsafeBytes { raw in
                    stride(from: 0, to: raw.count, by: 4).map { raw.loadUnaligned(fromByteOffset: $0, as: Float.self) }
                }
                let b = try samples(output)
                check(abs(a.count - b.count) < 1024, "\(name): resampling keeps reference duration")
                // Independent FFmpeg reference, allowing at most 1 ms for different SRC filters.
                var best = Double.infinity
                for lag in -16...16 {
                    var error = 0.0, energy = 0.0
                    for i in stride(from: 1600, to: min(a.count, b.count) - 1600, by: 3) {
                        let x = Double(a[i]), y = Double(b[i + lag])
                        energy += x * x; error += (x - y) * (x - y)
                    }
                    best = min(best, error / max(energy, 0.000001))
                }
                check(best < 0.005, "\(name): 16 kHz output stays within 1 ms of FFmpeg reference, error=\(best)")
            }
            await probe.replace()
            do {
                try await source.fileAudio!.writeAudio(trackID: source.tracks[0].id, start: 0, end: 1, format: pcm,
                                                       to: root.appendingPathComponent("stale.caf"))
                fatalError("changed file accepted")
            } catch { check(error as? MacAudioSubtitleError == .unreadable, "\(name): changed source fails without stale output") }
        }
        for (name, ordinal) in [("ac3-first", 2), ("ac3-last", 1)] {
            let file = fixtures.appendingPathComponent(name + ".mp4"), probe = try MP4FileProbe(file)
            let access = MP4AudioAccess(identity: "mixed/" + name,
                metadata: { await probe.metadata() }, read: { try await probe.read($0, $1) })
            let source = try await MacMP4AudioSubtitles.inspect(access, url: URL(string: "smb://fixture.invalid/\(name).mp4")!)
            let native = try await MacAudioSubtitleSource.inspect(file)
            let expected = native.tracks[ordinal - 1]
            let stats = await probe.stats()
            check(stats.0 < Int(probe.size) / 50, "\(name): mixed codecs inspected without reading video")
            check(source.tracks.count == 1 && source.tracks[0].id == expected.id && source.tracks[0].ordinal == ordinal,
                  "\(name): supported AAC keeps its original ID and ordinal")
            check(source.tracks[0].language == (ordinal == 1 ? "en" : "ja"), "\(name): supported AAC keeps its language")
            for (start, end) in [(0.0, 1.0), (28.0, 62.0), (58.0, source.duration)] {
                let reference = root.appendingPathComponent("mixed-reference.caf"), output = root.appendingPathComponent("mixed-range.caf")
                try await MacAudioSubtitleEngine.writeAudio(source: native, trackID: expected.id,
                    start: start, end: end, format: pcm, to: reference)
                try await MacAudioSubtitleEngine.writeAudio(source: source, trackID: expected.id,
                    start: start, end: end, format: pcm, to: output)
                let a = try samples(reference), b = try samples(output)
                check(a.count == b.count && !a.isEmpty, "\(name): selected AAC duration \(start)-\(end)")
                var energy = 0.0, error = 0.0
                for (x, y) in zip(a, b) { energy += Double(x * x); error += Double((x - y) * (x - y)) }
                check(error / max(energy, 0.000001) < 0.0001, "\(name): selected AAC content stays aligned \(start)-\(end)")
            }
            let excluded = native.tracks.first { $0.id != expected.id }!
            let before = await probe.stats()
            do {
                _ = try await source.fileAudio!.index.segment(trackID: excluded.id, start: 0, end: 1, read: access.read)
                fatalError("unsupported track silently replaced")
            } catch { check(error as? MP4AudioIndex.Failure == .invalid, "\(name): excluded track request is rejected") }
            let after = await probe.stats()
            check(after.1 == before.1, "\(name): excluded track never reads a different track")
        }
        for name in ["implicit-delay", "no-edits", "zero-edit", "delayed"] {
            let file = fixtures.appendingPathComponent(name + ".mp4"), probe = try MP4FileProbe(file)
            let access = MP4AudioAccess(identity: "compatibility/" + name,
                metadata: { await probe.metadata() }, read: { try await probe.read($0, $1) })
            let source = try await MacMP4AudioSubtitles.inspect(access, url: URL(string: "smb://fixture.invalid/\(name).mp4")!)
            let stats = await probe.stats()
            check(stats.0 < Int(probe.size) / 50, "\(name): compatible timeline inspected without reading video")
            let bytes = try Data(contentsOf: fixtures.appendingPathComponent("reference-\(name).f32"))
            let reference: [Float] = bytes.withUnsafeBytes { raw in
                stride(from: 0, to: raw.count, by: 4).map { raw.loadUnaligned(fromByteOffset: $0, as: Float.self) }
            }
            for (start, end) in [(0.0, 1.0), (0.0, 32.0), (1.5, 2.5), (28.1234, 31.9876), (28.0, 62.0), (58.0, source.duration)] {
                let output = root.appendingPathComponent("compatibility-range.caf")
                try await MacAudioSubtitleEngine.writeAudio(source: source, trackID: source.tracks[0].id,
                    start: start, end: end, format: pcm, to: output)
                let actual = try samples(output), offset = Int((start * pcm.sampleRate).rounded())
                check(actual.count == Int(((end - start) * pcm.sampleRate).rounded()), "\(name): exact output duration \(start)-\(end)")
                var energy = 0.0, error = 0.0
                for (i, sample) in actual.enumerated() {
                    let target = Double(reference[offset + i]), value = Double(sample)
                    energy += target * target; error += (target - value) * (target - value)
                }
                let normalized = error / max(energy, 0.000001)
                check(normalized < 0.0001, "\(name): independent waveform aligned \(start)-\(end), error=\(normalized)")
            }
        }
        for name in ["fragmented", "bad-offset", "encrypted", "bad-count", "truncated", "bad-roll", "ac3-only"] {
            let file = fixtures.appendingPathComponent(name + ".mp4"), probe = try MP4FileProbe(file)
            do {
                _ = try await MP4AudioIndex.inspect(size: probe.size, read: { try await probe.read($0, $1) })
                fatalError("accepted \(name)")
            } catch { check(error is MP4AudioIndex.Failure, "reject \(name) without decoding or downloading") }
        }
        let file = fixtures.appendingPathComponent("tail.mp4"), probe = try MP4FileProbe(file)
        do {
            _ = try await MP4AudioIndex.inspect(size: probe.size, read: { _, count in Data(count: max(0, count - 1)) })
            fatalError("short read accepted")
        } catch { check(error is MP4AudioIndex.Failure, "reject short range reads") }
        let task = Task {
            return try await MP4AudioIndex.inspect(size: probe.size, read: { try await probe.read($0, $1) })
        }
        task.cancel()
        do { _ = try await task.value; fatalError("cancelled inspection continued") }
        catch { check(error is CancellationError, "cancelled inspection produces no index") }
        let lazyProbe = try MP4FileProbe(file)
        let access = MP4AudioAccess(identity: "lazy-fixture", metadata: { await lazyProbe.metadata() },
                                    read: { try await lazyProbe.read($0, $1) })
        let suite = "GenPlayerSMBAudioChecks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backend = MacAudioSubtitleBackend(inspect: { _ in throw MacAudioSubtitleError.unreadable },
            languages: { ["en"] }, available: { true }, prepare: { _ in }, transcribe: { _, _, _, _ in [] }, revision: "fixture")
        let job = MacAudioSubtitleJob(backend: backend, store: MacAudioSubtitleStore(root: root.appendingPathComponent("store")), defaults: defaults)
        job.bind(url: URL(string: "smb://fixture.invalid/share/movie.mp4")!, live: false, fileAudio: access)
        try await Task.sleep(nanoseconds: 20_000_000)
        let untouched = await lazyProbe.stats()
        check(untouched.1 == 0 && !job.inspecting, "ordinary SMB playback does not start indexing")
        job.retryInspectionIfNeeded()
        try await until { !job.inspecting }
        check(job.source?.tracks.count == 2, "opening the audio panel inspects the SMB source")
        job.reset()
        check(job.source == nil, "reset releases the SMB source")
    }
}
