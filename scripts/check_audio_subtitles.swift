// Pure file/logic verification; does not launch GenPlayer, play audio, or use a speech model.
// Build and run with check_audio_subtitles.sh (macOS 26+); --media optionally checks a local MKV/MKA.
import Foundation
import AVFoundation
import GenPlayerVLCBridge

actor AudioSubtitleProbe {
    var calls: [Int] = []
    func recognize(chunk: Int, duration: Double) async throws -> [MacAudioSubtitleCue] {
        calls.append(chunk)
        try await Task.sleep(nanoseconds: 150_000_000)
        let start = Double(chunk) * 30
        return [.init(id: chunk * 10000, start: start, end: min(start + 1, duration), text: "Test")]
    }
    func snapshot() -> [Int] { calls }
}

@main struct AudioSubtitleChecks {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
        fputs("PASS: \(message)\n", stderr)
    }
    @MainActor static func until(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Timed out waiting for state")
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("GenPlayerAudioChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if let i = CommandLine.arguments.firstIndex(of: "--mp4-fixtures"), CommandLine.arguments.indices.contains(i + 1) {
            guard #available(macOS 26.0, *) else { throw MacAudioSubtitleError.unavailable }
            try await mp4Checks(fixtures: URL(fileURLWithPath: CommandLine.arguments[i + 1]), root: root)
            print("Passed \(checks) MP4 audio range checks")
            return
        }
        try await remoteChecks(root: root)
        check(MacAudioSubtitlePlan.count(duration: .nan) == 0, "invalid duration")
        check(MacAudioSubtitlePlan.count(duration: 95) == 4, "partial last chunk")
        check(MacAudioSubtitlePlan.next(at: 65, duration: 95, completed: []) == 2, "seek priority")
        check(MacAudioSubtitlePlan.next(at: 65, duration: 95, completed: [2,3]) == 0, "backfill")
        check(MacAudioSubtitlePlan.next(at: 200, duration: 95, completed: [0,1,2,3]) == nil, "complete")
        let words = [(start: 28.0, end: 29.0, text: "Hello "), (start: 29.8, end: 30.4, text: "world."),
                     (start: 31.0, end: 32.0, text: "Next."), (start: Double.nan, end: 32.0, text: "bad")]
        let left = MacAudioSubtitlePlan.cues(words: words, chunk: 0, duration: 95)
        let right = MacAudioSubtitlePlan.cues(words: words, chunk: 1, duration: 95)
        check(left.map(\.text) == ["Hello"], "chunk ownership left")
        check(right.map(\.text) == ["world.","Next."], "chunk ownership right")
        check(left.last!.end <= right.first!.start, "no overlap")
        let key = MacAudioSubtitlePlan.key(source: "source", track: 1, language: "en-US", engine: "test")
        check(key != MacAudioSubtitlePlan.key(source: "source", track: 2, language: "en-US", engine: "test"), "track isolation")
        check(key != MacAudioSubtitlePlan.key(source: "source", track: 1, language: "zh-CN", engine: "test"), "language isolation")
        check(key != MacAudioSubtitlePlan.key(source: "source", track: 1, language: "en-US", engine: "new"), "engine isolation")
        let store = MacAudioSubtitleStore(root: root.appendingPathComponent("cache"))
        var cache = MacAudioSubtitleCache(key: key, duration: 95)
        cache.chunks[0] = left; cache.chunks[1] = right; cache.chunks[2] = []; cache.chunks[3] = []
        try await store.save(cache)
        let loaded = await store.load(key: key, duration: 95)
        check(loaded.isComplete && loaded.completedDuration == 95, "silent chunks persist as completed")
        check(loaded.cues == left + right, "cache roundtrip")
        check(MacAudioSubtitlePlan.srt(right).contains("00:00:30,000 --> 00:00:30,400"), "SRT media timestamps")
        let mismatch = await store.load(key: key, duration: 96)
        check(mismatch.chunks.isEmpty, "source version mismatch")
        try Data("{corrupt".utf8).write(to: root.appendingPathComponent("cache/\(key).json"))
        let corrupt = await store.load(key: key, duration: 95)
        check(corrupt.chunks.isEmpty, "corruption recovery")
        cache.chunks[4] = []
        check(!cache.isValid, "reject out of range chunk")
        cache.chunks.removeValue(forKey: 4)
        cache.chunks[0] = [.init(id: 0, start: -1, end: 1, text: "bad")]
        check(!cache.isValid, "reject invalid cue")

        try matroskaChecks(root: root)
        if #available(macOS 26.0, *) {
            if let flag = CommandLine.arguments.firstIndex(of: "--media"), flag + 1 < CommandLine.arguments.count {
                try await mediaChecks(root: root, url: URL(fileURLWithPath: CommandLine.arguments[flag + 1]))
            }
            if !CommandLine.arguments.contains("--logic-only") { try await decodeChecks(root: root) }
            try await defaultTrackChecks(root: root)
            try await lifecycleChecks(root: root)
        }
        print("PASS: \(checks) audio subtitle file/logic checks")
    }

    static func matroskaChecks(root: URL) throws {
        check(MacAudioSubtitleRemux.languageCode("English") == "en" && MacAudioSubtitleRemux.languageCode("eng") == "en",
              "VLC display names and ISO language metadata normalize")
        check(MacAudioSubtitleRemux.languageCode("fra") == "fr" && MacAudioSubtitleRemux.languageCode("und") == nil,
              "unknown language requires manual selection")
        func element(_ id: [UInt8], _ data: Data) -> Data {
            var size = (UInt32(data.count) | 0x10000000).bigEndian
            return Data(id) + withUnsafeBytes(of: &size) { Data($0) } + data
        }
        func entry(_ number: UInt8, _ type: UInt8, extra: Data = Data()) -> Data {
            element([0xAE], element([0xD7], Data([number])) + element([0x83], Data([type]))
                + element([0x86], Data((type == 1 ? "V_MPEG4/ISO/AVC" : "A_AAC").utf8)) + extra)
        }
        let tracks = element([0x16,0x54,0xAE,0x6B], entry(3, 1) + entry(7, 2) + entry(42, 2))
        let info = element([0x15,0x49,0xA9,0x66], element([0x2A,0xD7,0xB1], Data([0x0F,0x42,0x40])))
        // BlockGroup and SimpleBlock use unrelated track numbers and a negative relative timestamp.
        let cluster = element([0x1F,0x43,0xB6,0x75], element([0xE7], Data([0x07,0xD0]))
            + element([0xA3], Data([0xAA,0x00,0x64,0]))
            + element([0xA0], element([0xA1], Data([0x87,0xFF,0x9C,0]))))
        let url = root.appendingPathComponent("headers.mkv")
        try element([0x18,0x53,0x80,0x67], info + tracks + cluster).write(to: url)
        let origins = try MacMatroskaAudioOrigin.origins(url: url)
        check(origins == [1.9, 2.1], "Matroska ordinals, block groups and signed media timestamps")
        check(try MacMatroskaAudioOrigin.layout(url: url).legacyIDs == [1, 2], "video ES occupies legacy ID before audio")
        for algorithm: UInt8 in [0, 3, 5] {
            let compression = element([0x6D,0x80], element([0x62,0x40],
                element([0x50,0x34], element([0x42,0x54], Data([algorithm])))))
            let encodedTracks = element([0x16,0x54,0xAE,0x6B], entry(3, 1, extra: compression) + entry(7, 2) + entry(42, 2))
            try element([0x18,0x53,0x80,0x67], info + encodedTracks + cluster).write(to: url)
            let layout = try MacMatroskaAudioOrigin.layout(url: url)
            check(algorithm == 5 ? layout.legacyIDs == nil : layout.legacyIDs == [1, 2],
                  "legacy layout supports zlib/header removal and refuses unsupported encoding")
        }
        try Data([0x18,0x53,0x80,0x67,0xFF,0]).write(to: url)
        do { _ = try MacMatroskaAudioOrigin.origins(url: url); fatalError("corrupt EBML accepted") }
        catch { check(true, "reject truncated Matroska headers") }
        let cancelled = GenPlayerVLCAudioReader()
        cancelled.cancel()
        do { _ = try cancelled.inspectURL(url); fatalError("cancelled inspection accepted") }
        catch { check((error as NSError).code == NSUserCancelledError, "cancelled VLC inspection stops") }
        let output = root.appendingPathComponent("cancelled.m4a")
        do { try cancelled.remuxURL(url, trackID: 7, to: output); fatalError("cancelled remux accepted") }
        catch { check(!FileManager.default.fileExists(atPath: output.path), "cancelled remux creates no output") }
    }

    @available(macOS 26.0, *)
    static func mediaChecks(root: URL, url: URL) async throws {
        let source = try await MacAudioSubtitleSource.inspect(url)
        check(source.decoder == .mpvPCM && !source.tracks.isEmpty, "production MKV uses independent mpv preparation")
        let comparison = try GenPlayerVLCAudioReader().inspectURL(url)
        let originalTracks = comparison["tracks"] as! [[String: Any]]
        let layout = try MacMatroskaAudioOrigin.layout(url: url)
        check(layout.legacyIDs == originalTracks.map { $0["id"] as! Int32 }, "independent legacy IDs match actual VLC inspection: \(String(describing: layout.legacyIDs)) vs \(originalTracks)")
        let legacyKey = "macAudioSubtitle." + source.identity.replacingOccurrences(of: "|mpv-pcm-v1", with: "|vlc-remux-v1")
        let previousLegacyPreference = UserDefaults.standard.data(forKey: legacyKey)
        let mappingKey = legacyKey + ".mpvTrackMap-v1"
        let previousMapping = UserDefaults.standard.data(forKey: mappingKey)
        let oldSupportedTrack = originalTracks.enumerated().first { ["mp4a", "a52 ", "dts "].contains($0.element["codec"] as? String ?? "") }!
        let oldPreference: [String: Any] = ["track": oldSupportedTrack.element["id"]!, "ordinal": oldSupportedTrack.offset + 1]
        UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: oldPreference), forKey: legacyKey)
        do {
            defer {
                if let previousLegacyPreference { UserDefaults.standard.set(previousLegacyPreference, forKey: legacyKey) }
                else { UserDefaults.standard.removeObject(forKey: legacyKey) }
                if let previousMapping { UserDefaults.standard.set(previousMapping, forKey: mappingKey) }
                else { UserDefaults.standard.removeObject(forKey: mappingKey) }
            }
            let legacy = try await MacAudioSubtitleSource.inspect(url)
            check(legacy.decoder == .mpvPCM, "legacy recognition preferences can use independent mpv preparation")
            check(legacy.identity.hasSuffix("|vlc-remux-v1"), "existing recognition cache identity is preserved")
            check(legacy.tracks.map(\.id) == originalTracks.map { $0["id"] as! Int32 }, "mixed codecs retain every container ID without shifting cached tracks")
            check(legacy.tracks[oldSupportedTrack.offset].ordinal == oldSupportedTrack.offset + 1,
                  "legacy selected track retains its ordinal among all audio tracks")
            check(UserDefaults.standard.data(forKey: mappingKey) != nil, "verified legacy track map is persisted")
            check(legacy.tracks.map(\.preparationTrackID) == source.tracks.map { Optional($0.id) }, "recognition IDs are separate from native preparation IDs")
            let restored = try await MacAudioSubtitleSource.inspect(url)
            check(restored.decoder == .mpvPCM && restored.tracks.map(\.id) == legacy.tracks.map(\.id), "saved legacy mapping restores stable recognition IDs")
            let savedMapping = UserDefaults.standard.data(forKey: mappingKey)!
            var malformed = try JSONSerialization.jsonObject(with: savedMapping) as! [String: Any]
            malformed["tracks"] = []
            UserDefaults.standard.set(try JSONSerialization.data(withJSONObject: malformed), forKey: mappingKey)
            let repaired = try await MacAudioSubtitleSource.inspect(url)
            check(repaired.decoder == .mpvPCM && repaired.tracks.map(\.id) == legacy.tracks.map(\.id),
                  "incomplete saved mappings are revalidated instead of reusing wrong track IDs")
            let preparedLegacy = try await MacAudioSubtitleRemux.shared.audioURL(source: legacy, trackID: legacy.tracks[0].id)
            check(FileManager.default.fileExists(atPath: preparedLegacy.path), "legacy ID prepares its mapped mpv audio")
            try await migrationCacheChecks(source: legacy, root: root, cachedDuration: comparison["duration"] as! Double)

        }
        if source.duration > 60 {
            let cancellationRoot = root.appendingPathComponent("remux-cancellation")
            try FileManager.default.createDirectory(at: cancellationRoot, withIntermediateDirectories: true)
            let remuxer = MacAudioSubtitleRemux(temporaryDirectory: cancellationRoot)
            let pending = Task { try await remuxer.audioURL(source: source, trackID: source.tracks[0].id) }
            try await Task.sleep(nanoseconds: 1_000_000)
            pending.cancel()
            do { _ = try await pending.value; fatalError("cancelled remux returned an audio file") }
            catch {
                check(try FileManager.default.contentsOfDirectory(atPath: cancellationRoot.path).isEmpty,
                      "cancelled audio preparation removes unfinished files")
            }
        }
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        for track in source.tracks {
            let remux = try await MacAudioSubtitleRemux.shared.audioURL(source: source, trackID: track.id)
            let again = try await MacAudioSubtitleRemux.shared.audioURL(source: source, trackID: track.id)
            check(remux == again, "prepared audio file reused")
            let native = try await MacAudioSubtitleSource.inspect(remux)
            check(native.tracks.count == 1 && native.duration <= source.duration + 0.1, "selected audio remux has one track")
            // This test intentionally decodes a short reference clip in full; production uses bounded chunks.
            guard native.duration < 600 else { throw MacAudioSubtitleError.unreadable }
            let fullURL = root.appendingPathComponent("reference.caf")
            try await MacAudioSubtitleEngine.writeAudio(source: native, trackID: native.tracks[0].id,
                start: 0, end: native.duration, format: pcm, to: fullURL)
            let file = try AVAudioFile(forReading: fullURL)
            let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let reference = buffer.floatChannelData![0]
            if track.requiresPCM {
                let prepared = try AVAudioFile(forReading: remux)
                check(remux.pathExtension == "wav" && prepared.fileFormat.channelCount == 1,
                      "DTS preparation produces mono WAV")
                check(abs(Double(prepared.length) / prepared.processingFormat.sampleRate + track.startTime - source.duration) < 0.15,
                      "DTS preparation preserves the complete audio duration")
                let energy = (0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(reference[$1]) * Double(reference[$1]) }
                check(energy / Double(buffer.frameLength) > 0.00001, "DTS preparation contains decoded audio, not silence")
            }
            for start in [0, source.duration / 2, max(0, source.duration - 4)] {
                let end = min(start + 4, source.duration)
                let out = root.appendingPathComponent("range.caf")
                try await MacAudioSubtitleEngine.writeAudio(source: source, trackID: track.id,
                    start: start, end: end, format: pcm, to: out)
                let f = try AVAudioFile(forReading: out)
                check(f.length == Int64(((end - start) * 16000).rounded()), "MKV range has media-time length")
                let b = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(f.length))!
                try f.read(into: b)
                var energy = 0.0, error = 0.0, peak = 0.0
                for i in 1600..<max(1600, Int(f.length) - 1600) {
                    let index = Int(((start - track.startTime) * 16000).rounded()) + i
                    let expected = index >= 0 && index < Int(file.length) ? Double(reference[index]) : 0
                    let actual = Double(b.floatChannelData![0][i])
                    energy += expected * expected; error += (actual - expected) * (actual - expected)
                    peak = max(peak, abs(actual - expected))
                }
                check(error / max(energy, 0.00001) < 0.02 || peak < 0.0001, "MKV slice matches continuous media timeline")
            }
        }
    }

    @available(macOS 26.0, *)
    @MainActor static func decodeChecks(root: URL) async throws {
        try await remoteDecodeChecks(root: root)
        let inputURL = root.appendingPathComponent("source.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: inputURL, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000 * 4)!
            buffer.frameLength = buffer.frameCapacity
            for index in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][index] = 0.25 }
            try file.write(from: buffer)
        }
        let source = try await MacAudioSubtitleSource.inspect(inputURL)
        check(source.tracks.count == 1 && abs(source.duration - 4) < 0.01, "inspect source")
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let outputURL = root.appendingPathComponent("slice.caf")
        try await MacAudioSubtitleEngine.writeAudio(source: source, trackID: source.tracks[0].id,
            start: 1, end: 3, format: pcm, to: outputURL)
        let output = try AVAudioFile(forReading: outputURL)
        check(output.length == 32000, "resampled range duration")
        let data = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 32000)!
        try output.read(into: data)
        check(abs(data.floatChannelData![0][16000] - 0.25) < 0.01, "decoded sample value")
        do {
            try await MacAudioSubtitleEngine.writeAudio(source: source, trackID: -100, start: 0, end: 1,
                                                        format: pcm, to: root.appendingPathComponent("invalid.caf"))
            fatalError("wrong track accepted")
        } catch { check(error as? MacAudioSubtitleError == .unreadable, "reject nonexistent track") }
        let composition = AVMutableComposition()
        let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let asset = AVURLAsset(url: inputURL)
        let original = try await asset.loadTracks(withMediaType: .audio)[0]
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 48000)),
                                  of: original, at: CMTime(seconds: 2, preferredTimescale: 48000))
        let movieURL = root.appendingPathComponent("offset.mov")
        let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)!
        try await export.export(to: movieURL, as: .mov)
        let offset = try await MacAudioSubtitleSource.inspect(movieURL)
        let offsetOutput = root.appendingPathComponent("offset.caf")
        try await MacAudioSubtitleEngine.writeAudio(source: offset, trackID: offset.tracks[0].id,
            start: 0, end: 4, format: pcm, to: offsetOutput)
        let read = try AVAudioFile(forReading: offsetOutput)
        let offsetData = AVAudioPCMBuffer(pcmFormat: read.processingFormat, frameCapacity: AVAudioFrameCount(read.length))!
        try read.read(into: offsetData)
        check(read.length == 64000, "nonzero PTS duration")
        check(abs(offsetData.floatChannelData![0][16000]) < 0.001, "nonzero PTS leading silence")
        check(abs(offsetData.floatChannelData![0][48000] - 0.25) < 0.01, "nonzero PTS signal alignment")
        // Exercise the PCM preparation used for DTS against a known delayed signal.
        let reader = GenPlayerVLCAudioReader()
        let delayedURL = root.appendingPathComponent("delayed.mka")
        try delayedPCMFixture().write(to: delayedURL)
        let origins = try MacMatroskaAudioOrigin.origins(url: delayedURL)
        check(origins == [2], "delayed PCM fixture uses a real Matroska timestamp")
        let info = try reader.inspectURL(delayedURL)
        let vlcTrack = (info["tracks"] as! [[String: Any]])[0]["id"] as! Int32
        let preparedURL = root.appendingPathComponent("delayed.wav")
        try reader.decodePCMURL(delayedURL, trackID: vlcTrack, to: preparedURL)
        let prepared = try AVAudioFile(forReading: preparedURL)
        check(abs(Double(prepared.length) / prepared.processingFormat.sampleRate - 4) < 0.05,
              "PCM preparation starts at the first audio timestamp: duration=\(Double(prepared.length) / prepared.processingFormat.sampleRate)")
        let delayed = MacAudioSubtitleSource(url: delayedURL, identity: "delayed-pcm", duration: 6,
            tracks: [.init(id: vlcTrack, ordinal: 1, language: nil, startTime: 2, requiresPCM: true, preparationTrackID: 1)], decoder: .mpvPCM)
        try await MacAudioSubtitleEngine.writeAudio(source: delayed, trackID: vlcTrack,
            start: 0, end: 4, format: pcm, to: offsetOutput)
        let delayedFile = try AVAudioFile(forReading: offsetOutput)
        let delayedData = AVAudioPCMBuffer(pcmFormat: delayedFile.processingFormat, frameCapacity: AVAudioFrameCount(delayedFile.length))!
        try delayedFile.read(into: delayedData)
        check(delayedFile.length == 64000 && abs(delayedData.floatChannelData![0][16000]) < 0.001,
              "PCM preparation preserves media-time leading silence")
        check(abs(delayedData.floatChannelData![0][48000] - 0.25) < 0.01,
              "PCM preparation aligns decoded signal to the original audio timestamp")
    }

    /// Four seconds of known PCM beginning at media time 2, without MOV edit-list silence.
    static func delayedPCMFixture() -> Data {
        func element(_ id: [UInt8], _ payload: Data) -> Data {
            var size = (UInt32(payload.count) | 0x10000000).bigEndian
            return Data(id) + withUnsafeBytes(of: &size) { Data($0) } + payload
        }
        func integer(_ id: [UInt8], _ value: UInt32) -> Data {
            var value = value.bigEndian
            return element(id, withUnsafeBytes(of: &value) { Data($0) })
        }
        func float(_ id: [UInt8], _ value: Double) -> Data {
            var value = value.bitPattern.bigEndian
            return element(id, withUnsafeBytes(of: &value) { Data($0) })
        }
        let header = element([0x1A,0x45,0xDF,0xA3], element([0x42,0x82], Data("matroska".utf8))
            + integer([0x42,0x87], 4) + integer([0x42,0x85], 2))
        let info = element([0x15,0x49,0xA9,0x66], integer([0x2A,0xD7,0xB1], 1000000) + float([0x44,0x89], 6000))
        let audio = element([0xE1], float([0xB5], 48000) + integer([0x9F], 1) + integer([0x62,0x64], 16))
        let entry = element([0xAE], integer([0xD7], 1) + integer([0x73,0xC5], 1) + integer([0x83], 2)
            + element([0x86], Data("A_PCM/INT/LIT".utf8)) + audio)
        var blocks = integer([0xE7], 2000)
        let samples = Data((0..<960).map { $0 % 2 == 0 ? UInt8(0) : UInt8(0x20) })
        for index in 0..<400 {
            let time = index * 10
            blocks += element([0xA3], Data([0x81, UInt8(time >> 8), UInt8(time & 255), 0x80]) + samples)
        }
        return header + element([0x18,0x53,0x80,0x67], info + element([0x16,0x54,0xAE,0x6B], entry)
            + element([0x1F,0x43,0xB6,0x75], blocks))
    }

    @available(macOS 26.0, *)
    @MainActor static func defaultTrackChecks(root: URL) async throws {
        let source = MacAudioSubtitleSource(url: root.appendingPathComponent("defaults.mp4"), identity: "default-track", duration: 3,
            tracks: [.init(id: 7, ordinal: 1, language: nil), .init(id: 9, ordinal: 2, language: nil)])
        check(source.playingTrack(id: 7, trackIDs: [-1, 3, 7])?.id == 9, "native source maps playback ordinal instead of colliding track ID")
        check(source.playingTrack(id: -1, trackIDs: [-1, 3, 7]) == nil, "disabled playback audio has no default recognition track")
        check(source.playingTrack(id: 3, trackIDs: [3]) == nil, "incomplete or transcoded playback track lists cannot guess source mapping")
        check(source.playingTrack(id: 3, trackIDs: [3, 3]) == nil, "ambiguous playback IDs cannot select a default")
        var mpvSource = source; mpvSource.decoder = .mpvPCM
        check(mpvSource.playingTrack(id: 7, trackIDs: [-1, 3, 7])?.id == 9, "mpv preparation maps playback ordinal, never VLC IDs")
        check(mpvSource.playingTrack(id: 3, trackIDs: [3]) == nil, "mpv preparation rejects mismatched track counts")
        var remux = source; remux.decoder = .vlcRemux
        check(remux.playingTrack(id: 9, trackIDs: [-1, 9, 7])?.id == 9, "VLC remux matches native VLC IDs directly")
        let backend = MacAudioSubtitleBackend(inspect: { _ in source }, languages: { ["en-US"] }, available: { true },
            prepare: { _ in }, transcribe: { _, _, _, _ in fatalError("default selection must not start recognition") }, revision: "default-track")
        let suite = "DefaultAudioTrackChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MacAudioSubtitleJob(backend: backend, store: MacAudioSubtitleStore(root: root.appendingPathComponent("defaults")), defaults: defaults)
        var playing: (id: Int, trackIDs: [Int]) = (7, [-1, 3, 7])
        model.playbackAudioSelection = { playing }
        model.bind(url: source.url, live: false)
        try await until { !model.inspecting }
        check(model.selectedTrack == 9 && !model.running, "first multi-track configuration defaults to currently playing audio without starting")
        playing = (3, [-1, 3, 7]); model.refreshDefaultAudioTrack()
        check(model.selectedTrack == 7, "changing playback before configuring recognition refreshes its default track")
        model.language = "ja-JP"
        playing = (7, [-1, 3, 7]); model.refreshDefaultAudioTrack()
        check(model.selectedTrack == 9 && model.language == "ja-JP", "playback default changes preserve a manually chosen dialogue language")
        model.selectedTrack = 7
        model.refreshDefaultAudioTrack()
        check(model.selectedTrack == 7, "manual recognition track beats playback default")
        model.selectedTrack = -1
        model.refreshDefaultAudioTrack()
        check(model.selectedTrack == -1, "manual clear is not overwritten by late playback refresh")
        playing = (-1, [])
        model.bind(url: source.url, live: false)
        try await until { !model.inspecting }
        check(model.selectedTrack == -1, "missing playback metadata leaves multi-track source unselected")
        playing = (7, [-1, 3, 7]); model.refreshDefaultAudioTrack()
        check(model.selectedTrack == 9, "late playback metadata fills the first default selection")
        model.bind(url: source.url, live: false)
        model.selectedTrack = 7
        try await until { !model.inspecting }
        check(model.selectedTrack == 7, "late source inspection preserves an explicit track selection")
        defaults.set(Data(#"{"track":7,"language":"en-US","display":"off"}"#.utf8), forKey: "macAudioSubtitle." + source.identity)
        model.bind(url: source.url, live: false)
        try await until { !model.inspecting && !model.running && model.cache != nil }
        model.refreshDefaultAudioTrack()
        check(model.selectedTrack == 7 && model.language == "en-US", "saved generation preference takes priority over current playback audio")
        model.reset()
        let singleSource = MacAudioSubtitleSource(url: source.url, identity: "single-default", duration: 3, tracks: [source.tracks[0]])
        let singleBackend = MacAudioSubtitleBackend(inspect: { _ in singleSource }, languages: { ["en-US"] }, available: { true },
            prepare: { _ in }, transcribe: { _, _, _, _ in fatalError("default selection must not start recognition") }, revision: "single-default")
        let singleModel = MacAudioSubtitleJob(backend: singleBackend,
            store: MacAudioSubtitleStore(root: root.appendingPathComponent("single-default")), defaults: defaults)
        playing = (-1, []); singleModel.playbackAudioSelection = { playing }
        singleModel.bind(url: source.url, live: false)
        try await until { !singleModel.inspecting }
        check(singleModel.selectedTrack == -1, "a player without track metadata cannot guess even a sole readable track")
        playing = (42, [-1, 42]); singleModel.refreshDefaultAudioTrack()
        check(singleModel.selectedTrack == 7, "late single-track playback metadata fills its matching default")
        singleModel.reset()
    }

    @available(macOS 26.0, *)
    @MainActor static func migrationCacheChecks(source: MacAudioSubtitleSource, root: URL, cachedDuration: Double) async throws {
        let track = source.tracks.first { ["aac", "ac3", "dts"].contains($0.codec ?? "") } ?? source.tracks[0]
        let suite = "GenPlayerLegacyAudioCache-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "enableSecondarySubtitlesBeta")
        let preference: [String: Any] = ["track": track.id, "language": "en-US", "display": "configured",
            "ordinal": track.ordinal, "originalDestination": "secondary", "translationDestination": "primary",
            "automaticallyTranslate": true]
        defaults.set(try JSONSerialization.data(withJSONObject: preference), forKey: "macAudioSubtitle." + source.identity)
        let store = MacAudioSubtitleStore(root: root.appendingPathComponent("legacy-cache"))
        let key = MacAudioSubtitlePlan.key(source: source.identity, track: track.id, language: "en-US", engine: "migration-check")
        var cached = MacAudioSubtitleCache(key: key, duration: cachedDuration)
        for chunk in 0..<MacAudioSubtitlePlan.count(duration: source.duration) { cached.chunks[chunk] = [] }
        cached.chunks[0] = [.init(id: 0, start: 0, end: min(1, source.duration), text: "Existing result")]
        try await store.save(cached)
        let backend = MacAudioSubtitleBackend(inspect: { _ in source }, languages: { ["en-US"] }, available: { false },
            prepare: { _ in fatalError("Completed cache must not prepare recognition") },
            transcribe: { _, _, _, _ in fatalError("Completed cache must not transcribe") }, revision: "migration-check")
        let job = MacAudioSubtitleJob(backend: backend, store: store, defaults: defaults)
        job.bind(url: source.url, live: false)
        try await until { job.status == "AS.Completed" }
        check(job.cache?.cues == cached.cues, "legacy completed cues survive mpv preparation migration")
        check(job.selectedTrack == track.id && job.language == "en-US", "legacy recognition track and language survive")
        check(job.activeOriginalDestination == .secondary && job.activeTranslationDestination == .primary,
              "legacy original/translation display destinations survive")
        job.reset()
    }

    @available(macOS 26.0, *)
    @MainActor static func lifecycleChecks(root: URL) async throws {
        let probe = AudioSubtitleProbe()
        let source = MacAudioSubtitleSource(url: root.appendingPathComponent("fake.caf"), identity: "fixture", duration: 95,
            tracks: [.init(id: 1, ordinal: 1, language: nil)])
        let backend = MacAudioSubtitleBackend(inspect: { _ in source }, languages: { ["en-US"] }, available: { true },
            prepare: { _ in }, transcribe: { source, _, _, chunk in try await probe.recognize(chunk: chunk, duration: source.duration) }, revision: "fixture")
        let name = "GenPlayerAudioSubtitleChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = MacAudioSubtitleStore(root: root.appendingPathComponent("jobs"))
        let job = MacAudioSubtitleJob(backend: backend, store: store, defaults: defaults)
        job.bind(url: source.url, live: false)
        try await until { !job.inspecting }
        job.language = "en-US"
        job.start()
        try await until { job.status == "AS.Generating" }
        job.seek(to: 65)
        try await until { job.cache?.chunks[2] != nil }
        check(job.cache?.chunks[0] == nil, "seek cancels old segment")
        job.cancel()
        let key = job.cache!.key
        try await Task.sleep(nanoseconds: 200_000_000)
        let cached = await store.load(key: key, duration: 95)
        check(cached.chunks[2] != nil && cached.chunks[0] == nil, "cancel preserves completed segments only")
        let callsBefore = await probe.snapshot()
        job.select(.off)
        job.reset()
        job.bind(url: source.url, live: false)
        try await until { !job.inspecting && job.cache != nil && !job.running }
        let callsAfter = await probe.snapshot()
        check(callsAfter == callsBefore, "disabled preference loads cache without recognition")
        check(job.cache?.chunks[2] != nil && job.display == .off, "cache available on reopen")
        job.start()
        try await until { job.status == "AS.Generating" }
        let other = MacAudioSubtitleJob(backend: backend, store: store, defaults: defaults)
        other.bind(url: source.url, live: false)
        try await until { other.status == "AS.Busy" }
        check(other.cache?.chunks[2] != nil, "busy player still loads cached subtitles")
        other.deleteCache()
        try await until { !other.inspecting }
        check(other.status == "AS.Busy", "cannot delete a cache another player is writing")
        try await until { !job.running }
        check(job.cache?.isComplete == true, "resume fills missing chunks")
        let calls = await probe.snapshot()
        check(calls.filter { $0 == 2 }.count == 1, "cached chunk not recognized again")
        job.reset()
        job.bind(url: source.url, live: false)
        try await until { !job.inspecting && job.cache != nil && !job.running }
        let reopenedCalls = await probe.snapshot()
        check(reopenedCalls == calls, "complete cache reopens without recognition")
        job.select(.primary)
        job.reset()
        job.bind(url: source.url, live: false)
        job.noteManualSubtitleSelection()
        try await until { !job.inspecting && job.cache != nil && !job.running }
        check(job.display == .off, "manual selection wins over late cache restoration")
        check(job.text(at: -1).isEmpty && job.text(at: .nan).isEmpty, "invalid playback times")
        check(job.text(at: 60.5) == "Test", "direct cached media-time lookup")
        job.deleteCache()
        try await until { !job.inspecting }
        check(job.cache == nil, "delete clears visible cache")
        let deleted = await store.load(key: key, duration: 95)
        check(deleted.chunks.isEmpty, "delete removes persisted cache")
        job.bind(url: source.url, live: false)
        job.reset()
        try await Task.sleep(nanoseconds: 30_000_000)
        check(job.source == nil && job.cache == nil, "late inspect cannot repopulate closed player")

        defaults.set(true, forKey: "enableSecondarySubtitlesBeta")
        var inspections = 0
        var nextID: Int32 = 7
        var nextIdentity = "episode-one"
        var recognitionCalls = 0
        let continuationBackend = MacAudioSubtitleBackend(inspect: { url in
            inspections += 1
            if inspections == 1 { throw MacAudioSubtitleError.unreadable }
            return MacAudioSubtitleSource(url: url, identity: nextIdentity, duration: 1,
                tracks: [.init(id: nextID, ordinal: 1, language: nil)])
        }, languages: { ["en-US"] }, available: { true }, prepare: { _ in },
            transcribe: { _, _, _, _ in
                recognitionCalls += 1
                return [.init(id: 0, start: 0, end: 1, text: "Episode")]
            }, revision: "continuation")
        let continuous = MacAudioSubtitleJob(backend: continuationBackend, store: store, defaults: defaults)
        continuous.bind(url: source.url, live: false, continuationScope: "series-one")
        try await until { !continuous.inspecting }
        check(inspections == 2 && continuous.selectedTrack == 7, "first unreadable inspection retries and publishes tracks")
        continuous.language = "en-US"
        continuous.start()
        try await until { !continuous.running }
        check(continuous.display == .secondary, "new generation defaults to secondary when enabled")
        nextID = 19; nextIdentity = "episode-two"
        continuous.bind(url: source.url, live: false, continuationScope: "series-one")
        try await until { !continuous.inspecting && continuous.cache != nil && !continuous.running }
        check(continuous.activeTrack == 19 && continuous.language == "en-US" && continuous.display == .secondary,
              "next episode remaps audio ID and continues language and display")
        check(continuous.cache?.key != key, "continued episode uses its own cache")
        let enabledContinuation = defaults.data(forKey: "audioSubtitleContinuation.series-one")
        defaults.set(Data(#"{"track":19,"language":"en-US","display":"off"}"#.utf8),
                     forKey: "macAudioSubtitle.older-off")
        nextIdentity = "older-off"
        continuous.bind(url: source.url, live: false, continuationScope: "series-one")
        try await until { !continuous.inspecting && continuous.cache != nil && !continuous.running }
        check(continuous.display == .off && defaults.data(forKey: "audioSubtitleContinuation.series-one") == enabledContinuation,
              "restoring a disabled episode preserves the series preference")
        nextIdentity = "new-after-old"
        continuous.bind(url: source.url, live: false, continuationScope: "series-one")
        try await until { !continuous.inspecting && continuous.cache != nil && !continuous.running }
        check(continuous.display == .secondary, "new episode still generates after restoring an older disabled episode")
        nextIdentity = "unrelated"
        continuous.bind(url: source.url, live: false, continuationScope: "another-series")
        try await until { !continuous.inspecting }
        check(continuous.cache == nil && !continuous.running, "unrelated series does not start recognition")
        nextIdentity = "manual-episode"
        continuous.bind(url: source.url, live: false, continuationScope: "series-one")
        continuous.noteManualSubtitleSelection()
        try await until { !continuous.inspecting }
        check(continuous.cache == nil && continuous.display == .off, "manual subtitle selection prevents late series inheritance")
        nextIdentity = "episode-two"
        continuous.bind(url: source.url, live: false, continuationScope: "series-one")
        try await until { !continuous.inspecting && continuous.cache != nil && !continuous.running }
        defaults.set(false, forKey: "enableSecondarySubtitlesBeta")
        continuous.bind(url: source.url, live: false, continuationScope: "series-one")
        try await until { !continuous.inspecting && continuous.cache != nil && !continuous.running }
        check(continuous.display == .primary, "restoring secondary with Beta disabled falls back to primary")
        defaults.set(true, forKey: "enableSecondarySubtitlesBeta")
        continuous.setAutomaticallyTranslate(true)
        check(continuous.display == .configured && continuous.automaticallyTranslate, "automatic translation explicitly selects the independent secondary source")
        continuous.bind(url: source.url, live: false, continuationScope: "series-one")
        try await until { !continuous.inspecting && continuous.cache != nil && !continuous.running }
        check(continuous.display == .configured && continuous.automaticallyTranslate, "reopening restores automatic translation without changing audio cache")
        nextID = 23; nextIdentity = "translated-next"
        continuous.bind(url: source.url, live: false, continuationScope: "series-one")
        try await until { !continuous.inspecting && continuous.cache != nil && !continuous.running }
        check(continuous.activeTrack == 23 && continuous.display == .configured, "next episode rematches track and inherits automatic translation")
        defaults.set(false, forKey: "enableSecondarySubtitlesBeta")
        continuous.bind(url: source.url, live: false, continuationScope: "series-one")
        try await until { !continuous.inspecting && continuous.cache != nil && !continuous.running }
        check(continuous.display == .off && continuous.automaticallyTranslate && continuous.translationDestination == .secondary,
              "disabled secondary Beta preserves configured destinations without silently moving them")
        continuous.select(.off)
        nextIdentity = "episode-three"
        continuous.bind(url: source.url, live: false, continuationScope: "series-one")
        try await until { !continuous.inspecting }
        check(continuous.cache == nil && continuous.display == .off, "turning generation off stops continuation for new episodes")
        nextIdentity = "preconfigured-primary"
        continuous.bind(url: source.url, live: false)
        try await until { !continuous.inspecting }
        continuous.language = "en-US"
        continuous.setOriginalDestination(.none)
        continuous.setTranslationDestination(.primary)
        continuous.setAutomaticallyTranslate(true)
        check(continuous.cache == nil && continuous.display == .off && continuous.outputAvailable,
              "destinations can be chosen before generation; translated primary does not require secondary Beta")
        continuous.useOrGenerate()
        try await until { !continuous.running && continuous.cache != nil }
        check(continuous.uses(.primary) && !continuous.uses(.secondary) && continuous.activeOriginalDestination == .none,
              "first generation applies the preselected translation-only primary route")
        let completedRecognitionCalls = recognitionCalls
        continuous.useOrGenerate()
        continuous.setOriginalDestination(.primary)
        check(recognitionCalls == completedRecognitionCalls && !continuous.running && continuous.uses(.primary),
              "completed cache and output changes do not invoke recognition again")
        continuous.setOriginalDestination(.secondary)
        check(!continuous.outputAvailable && continuous.display == .off && continuous.originalDestination == .secondary,
              "selecting disabled secondary requires explicit enablement rather than moving output")
        defaults.set(true, forKey: "enableSecondarySubtitlesBeta")
        continuous.applyOutputConfiguration()
        check(continuous.uses(.primary) && continuous.uses(.secondary), "explicit enablement applies the chosen split layout")
        continuous.bind(url: source.url, live: false)
        try await until { !continuous.inspecting && continuous.cache != nil && !continuous.running }
        check(continuous.originalDestination == .secondary && continuous.translationDestination == .primary && continuous.translatesAudio,
              "reopen restores both original and translation destinations")
        continuous.reset()
        inspections = 0
        continuous.bind(url: source.url, live: false)
        try await until { inspections == 1 }
        continuous.reset()
        try await Task.sleep(nanoseconds: 400_000_000)
        check(inspections == 1 && continuous.source == nil, "closing during inspection retry prevents late work")

    }
}
