import Foundation
import AVFoundation

/// No external server or credentials: URLProtocol intercepts every test request, including cleanup.
final class SubtitleHTTPFixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var payload = Data()
    static var status = 200
    static var hold = false
    static func configure(_ data: Data, status: Int = 200, hold: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        requests = []; payload = data; Self.status = status; Self.hold = hold
    }
    static func snapshot() -> [URLRequest] {
        lock.lock(); defer { lock.unlock() }; return requests
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let data = Self.payload, status = Self.status, hold = Self.hold
        Self.lock.unlock()
        let cleanup = request.httpMethod == "DELETE"
        if hold && !cleanup { return }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: cleanup ? 204 : status,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        if !cleanup { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func session(_ timeout: Double) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SubtitleHTTPFixture.self]
        config.timeoutIntervalForResource = timeout
        return URLSession(configuration: config)
    }
}

extension AudioSubtitleChecks {
    static func remoteFixture() -> MacJellyfinAudioSubtitles {
        .init(serverURL: URL(string: "https://fixture.invalid/jellyfin")!, serverID: "server", itemID: "item",
              mediaSourceID: "version", token: "fixture-token", makeSession: { SubtitleHTTPFixture.session($0) })
    }
    static func adtsFrame(_ payload: Data, sampleRate: Int = 48000) -> Data {
        let length = payload.count + 7
        return Data([0xff,0xf1,sampleRate == 44100 ? 0x50 : 0x4c,UInt8(0x40 | (length >> 11)), UInt8((length >> 3) & 0xff),
                     UInt8(((length & 7) << 5) | 0x1f),0xfc]) + payload
    }
    @MainActor static func remoteChecks(root: URL) async throws {
        let remote = remoteFixture()
        let metadata = Data(#"{"MediaSources":[{"Id":"version","RunTimeTicks":1200000000,"Size":200000000,"MediaStreams":[{"Index":3,"Type":"Audio","Codec":"aac","DisplayTitle":"日本語 AAC","BitRate":128000,"Channels":2,"SampleRate":48000}]}]}"#.utf8)
        let source = try remote.source(from: metadata)
        for (start, end, duration, expected) in [
            (58.0, 61.0, 61.0, 56.0), (58, 61.25, 61.25, 56.25),
            (58, 63, 63, 58), (28, 60, 60, 28), (0, 4, 4, 0), (2, 4, 4, 0),
            (28, 62, 120, 28)
        ] {
            check(try MacJellyfinAudioSubtitles.requestStart(start: start, end: end, duration: duration) == expected,
                  "remote seek origin for \(start)-\(end) of \(duration) seconds")
        }
        for (start, end, duration) in [(Double.nan, 61.0, 61.0), (58, 62, 61), (58, 61, .infinity), (0, 35, 120)] {
            do { _ = try MacJellyfinAudioSubtitles.requestStart(start: start, end: end, duration: duration); fatalError("invalid range accepted") }
            catch { check(true, "reject invalid remote request range") }
        }
        check(source.tracks[0].id == 3 && source.tracks[0].name == "日本語 AAC", "remote stream index and original name")
        var renewed = remoteFixture()
        renewed = .init(serverURL: renewed.serverURL, serverID: renewed.serverID, itemID: renewed.itemID,
                        mediaSourceID: renewed.mediaSourceID, token: "new-token")
        check(try renewed.source(from: metadata).identity == source.identity, "token refresh preserves subtitle cache identity")
        let updated = Data(String(decoding: metadata, as: UTF8.self).replacingOccurrences(of: "200000000", with: "200000001").utf8)
        check(try remote.source(from: updated).identity != source.identity, "media replacement invalidates subtitle cache")
        for (data, reason) in [
            (Data(String(decoding: metadata, as: UTF8.self).replacingOccurrences(of: "\"version\"", with: "\"other\"").utf8), "reject wrong media version"),
            (Data(#"{"MediaSources":[{"Id":"version","RunTimeTicks":1200000000,"MediaStreams":[{"Index":1,"Type":"Audio"},{"Index":1,"Type":"Audio"}]}]}"#.utf8), "reject duplicate audio indices"),
            (Data(#"{"MediaSources":[{"Id":"version","RunTimeTicks":1200000000,"IsInfiniteStream":true,"MediaStreams":[{"Index":1,"Type":"Audio"}]}]}"#.utf8), "reject live metadata")
        ] {
            do { _ = try remote.source(from: data); fatalError(reason) }
            catch { check(true, reason) }
        }
        let multiple = try remote.source(from: Data(#"{"MediaSources":[{"Id":"version","RunTimeTicks":1200000000,"MediaStreams":[{"Index":0,"Type":"Video"},{"Index":2,"Type":"Audio","Language":"ja","DisplayTitle":"Japanese"},{"Index":7,"Type":"Audio","Language":"en","DisplayTitle":"English"},{"Index":9,"Type":"Audio","IsExternal":true}]}]}"#.utf8))
        check(multiple.tracks.map(\.id) == [2,7] && multiple.tracks.map(\.name) == ["Japanese","English"],
              "multiple remote audio tracks preserve source IDs and names and exclude external tracks")
        check(multiple.remote?.usesVideoRoute == true && source.remote?.usesVideoRoute == false,
              "only multiple audio sources require the explicitly mapped video route")
        check(MacAudioSubtitlePlan.key(source: multiple.identity, track: 2, language: "en", engine: "test") !=
              MacAudioSubtitlePlan.key(source: multiple.identity, track: 7, language: "en", engine: "test"),
              "selected remote tracks have isolated subtitle caches")
        var parser = MacSubtitleADTS()
        let frame = adtsFrame(Data(repeating: 1, count: 100))
        var decoded = Data()
        for byte in frame + frame { if let complete = try parser.append(byte) { decoded += complete } }
        check(decoded == frame + frame && abs(parser.duration - 2048.0 / 48000) < 0.000001, "ADTS packet boundaries and sample duration")
        do {
            var invalid = MacSubtitleADTS()
            for byte in Data("<html>error".utf8) { _ = try invalid.append(byte) }
            fatalError("invalid audio accepted")
        } catch { check(true, "reject HTML or unexpected audio headers") }
        SubtitleHTTPFixture.configure(Data(repeating: 0, count: 0))
        let output = root.appendingPathComponent("remote-test.aac")
        func packet(pid: Int, start: Bool, counter: Int, payload: Data) -> Data {
            precondition(payload.count <= 183)
            let adaptation = 183 - payload.count
            var bytes = Data([0x47, UInt8((pid >> 8) | (start ? 0x40 : 0)), UInt8(pid & 255), UInt8(0x30 | counter), UInt8(adaptation)])
            if adaptation > 0 { bytes.append(0); bytes.append(Data(repeating: 0xff, count: adaptation - 1)) }
            return bytes + payload
        }
        let pat = packet(pid: 0, start: true, counter: 0, payload: Data([0,0,0xb0,13,0,1,0xc1,0,0,0,1,0xf0,0,0,0,0,0]))
        let pmt = packet(pid: 4096, start: true, counter: 0,
            payload: Data([0,2,0xb0,18,0,1,0xc1,0,0,0xe1,0,0xf0,0,0x0f,0xe1,1,0xf0,0,0,0,0,0]))
        var transportBody = pat + pmt
        for i in 0..<100 {
            transportBody += packet(pid: 256, start: true, counter: i % 16, payload: Data(repeating: 0xaa, count: 150))
            transportBody += packet(pid: 257, start: true, counter: i % 16, payload: Data([0,0,1,0xc0,0,0,0x80,0,0]) + frame)
        }
        var split = MacSubtitleTransportStream()
        var splitOutput = Data()
        let pes = Data([0,0,1,0xc0,0,0,0x80,0x80,5,0x21,0,1,0,1]) + frame + frame + frame + frame
        var splitBody = pat + pmt
        // Deliberately split the PES header, then split AAC frames across TS packets.
        splitBody += packet(pid: 257, start: true, counter: 0, payload: Data(pes.prefix(6)))
        var cursor = 6, counter = 1
        while cursor < pes.count {
            let end = min(cursor + 183, pes.count)
            splitBody += packet(pid: 257, start: false, counter: counter % 16, payload: pes.subdata(in: cursor..<end))
            cursor = end; counter += 1
        }
        for byte in splitBody { splitOutput += try split.append(byte) }
        check(splitOutput == frame + frame + frame + frame, "PES headers and AAC frames may cross transport packets without loss")
        SubtitleHTTPFixture.configure(transportBody)
        try await multiple.remote!.audio(start: 30, end: 31, track: 7, to: output)
        check(try Data(contentsOf: output) == (0..<47).reduce(Data()) { value, _ in value + frame },
              "mapped TS discards video and saves only the requested AAC duration")
        let mappedRequest = SubtitleHTTPFixture.snapshot().first!
        let mappedQuery = URLComponents(url: mappedRequest.url!, resolvingAgainstBaseURL: false)!.queryItems!
        check(mappedRequest.url!.path == "/jellyfin/Videos/item/stream.ts" &&
              mappedQuery.contains { $0.name == "AudioStreamIndex" && $0.value == "7" } &&
              mappedQuery.contains { $0.name == "VideoCodec" && $0.value == "copy" },
              "multi-track request maps the selected server audio index without video re-encoding")
        var emby = remoteFixture()
        emby.provider = .emby
        let embySource = try emby.source(from: metadata)
        check(embySource.remote?.provider == .emby && embySource.remote?.usesVideoRoute == true,
              "Emby preserves provider and explicitly maps even a single audio track")
        check(embySource.identity != source.identity, "Emby and Jellyfin cache identities are isolated")
        SubtitleHTTPFixture.configure(transportBody)
        try await embySource.remote!.audio(start: 30, end: 31, track: 3, to: output)
        let embyRequests = SubtitleHTTPFixture.snapshot()
        let embyRequest = embyRequests.first!
        let embyQuery = URLComponents(url: embyRequest.url!, resolvingAgainstBaseURL: false)!.queryItems!
        check(embyRequest.url!.path.hasSuffix("/Videos/item/stream.ts") &&
              embyQuery.contains { $0.name == "AudioStreamIndex" && $0.value == "3" } &&
              embyRequest.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token",
              "Emby request carries selected track and authenticated video extraction")
        check(embyRequests.last?.httpMethod == "DELETE" &&
              embyRequests.last?.url?.path.hasSuffix("/Videos/ActiveEncodings") == true,
              "Emby extraction cleans up its independent encoding")
        check(MacJellyfinAudioSubtitles.Provider(rawValue: "plex") == nil &&
              MacJellyfinAudioSubtitles.Provider(rawValue: "smb") == nil,
              "unimplemented providers do not enter Jellyfin or Emby routes")
        var frame441 = frame
        frame441[2] = (frame441[2] & 0xc3) | (4 << 2)
        var parser441 = MacSubtitleADTS()
        for byte in frame441 + frame441 { _ = try parser441.append(byte) }
        check(abs(parser441.duration - 2048.0 / 44100) < 0.000001,
              "Emby 44.1 kHz AAC uses its actual sample duration")
        do {
            for byte in frame { _ = try parser441.append(byte) }
            fatalError("mid-chunk sample rate change accepted")
        } catch { check(true, "reject AAC sample rate changes within a chunk") }
        var emby441Body = pat + pmt
        for i in 0..<100 {
            emby441Body += packet(pid: 257, start: true, counter: i % 16,
                payload: Data([0,0,1,0xc0,0,0,0x80,0,0]) + frame441)
        }
        SubtitleHTTPFixture.configure(emby441Body)
        try await embySource.remote!.audio(start: 2368, end: 2369, track: 3, to: output)
        check(try Data(contentsOf: output) == (0..<44).reduce(Data()) { value, _ in value + frame441 },
              "Emby 44.1 kHz stream stops after sufficient audio without 48 kHz truncation")
        var broken = MacSubtitleTransportStream()
        do {
            for byte in pat + pmt + packet(pid: 257, start: true, counter: 0, payload: Data([0,0,1,0xc0,0,0,0x80,0,0]) + frame) +
                packet(pid: 257, start: true, counter: 2, payload: frame) { _ = try broken.append(byte) }
            fatalError("TS packet loss accepted")
        } catch { check(true, "missing audio transport packet fails instead of shifting subtitles") }
        var body = Data()
        for _ in 0..<200 { body += frame }
        SubtitleHTTPFixture.configure(body)
        try await remote.audio(start: 123, end: 124, track: 3, to: output)
        let saved = try Data(contentsOf: output)
        check(saved.count == frame.count * 47 && saved.count < body.count, "read only complete frames needed for this chunk")
        let requests = SubtitleHTTPFixture.snapshot()
        let read = requests.first!, stop = requests.last!
        let query = URLComponents(url: read.url!, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ key: String, in request: URLRequest) -> String? {
            URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == key }?.value
        }
        check(read.url!.path == "/jellyfin/Audio/item/stream.aac" && value("StartTimeTicks", in: read) == "1230000000", "remote chunk uses media time and server base path")
        check(query.contains { $0.name == "Static" && $0.value == "false" } && value("AudioChannels", in: read) == "1", "force audio-only mono transcode")
        check(read.value(forHTTPHeaderField: "X-Emby-Token") == "fixture-token" && !read.url!.absoluteString.contains("fixture-token"), "authorization stays in request headers")
        check(stop.httpMethod == "DELETE" && value("DeviceId", in: read) == value("DeviceId", in: stop)
              && value("PlaySessionId", in: read) == value("PlaySessionId", in: stop), "success stops only its independent encoding")
        for (body, status) in [(frame, 200), (Data(), 401)] {
            SubtitleHTTPFixture.configure(body, status: status)
            do { try await remote.audio(start: 0, end: 30, track: 3, to: output); fatalError("bad response accepted") }
            catch { check(!FileManager.default.fileExists(atPath: output.path), "failed or truncated audio leaves no partial file") }
            check(SubtitleHTTPFixture.snapshot().last?.httpMethod == "DELETE", "failed response still stops encoding")
        }
        SubtitleHTTPFixture.configure(Data(), hold: true)
        let pending = Task { try await remote.audio(start: 0, end: 30, track: 3, to: output) }
        try await until { !SubtitleHTTPFixture.snapshot().isEmpty }
        pending.cancel()
        do { try await pending.value; fatalError("cancelled read completed") }
        catch { check(SubtitleHTTPFixture.snapshot().last?.httpMethod == "DELETE", "cancelled read drains independent cleanup") }
        if #available(macOS 26.0, *) {
            SubtitleHTTPFixture.configure(metadata)
            let probe = AudioSubtitleProbe()
            let backend = MacAudioSubtitleBackend(inspect: { _ in fatalError("remote source used local inspector") },
                languages: { ["en-US"] }, available: { true }, prepare: { _ in },
                transcribe: { source, _, _, chunk in try await probe.recognize(chunk: chunk, duration: source.duration) },
                revision: "remote-fixture")
            let suite = "GenPlayerRemoteCheck-" + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = MacAudioSubtitleStore(root: root.appendingPathComponent("remote-cache"))
            let legacyKey = MacAudioSubtitlePlan.key(source: source.identity, track: 3, language: "en-US", engine: backend.revision)
            var legacy = MacAudioSubtitleCache(key: legacyKey, duration: source.duration)
            for chunk in 0..<4 { legacy.chunks[chunk] = [] }
            try await store.save(legacy)
            let job = MacAudioSubtitleJob(backend: backend, store: store, defaults: defaults)
            job.bind(url: remote.serverURL, live: false, remote: remote)
            try await until { !job.inspecting }
            check(job.source?.remote != nil && job.selectedTrack == 3, "player job binds remote metadata through saved credentials")
            job.language = "en-US"
            job.playbackTime = 65
            job.start()
            try await until { job.cache?.isComplete == true && !job.running }
            let calls = await probe.snapshot()
            check(calls.first == 2 && calls.count == 4, "remote job starts near playback then fills missing ranges")
            check(job.cache?.key != legacyKey, "old remote results regenerate with corrected seek revision")
            job.reset()
            job.bind(url: remote.serverURL, live: false, remote: remote)
            try await until { job.cache?.isComplete == true && !job.running }
            check(await probe.snapshot() == calls && job.display == .primary, "remote cache reopens without another audio generation")
            job.reset()
        }
    }

    @available(macOS 26.0, *)
    @MainActor static func encodedADTS(root: URL, seconds: Int, silentPrefix: Int = 0, sampleRate: Int = 48000) async throws -> Data {
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: 1)!
        let input = root.appendingPathComponent("remote-encoded.m4a")
        do {
            let writer = try AVAudioFile(forWriting: input, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000],
                commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * seconds))!
            buffer.frameLength = buffer.frameCapacity
            for i in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![0][i] = i < silentPrefix * sampleRate ? 0 : Float(sin(Double(i) * 440 * 2 * .pi / Double(sampleRate))) * 0.3
            }
            try writer.write(from: buffer)
        }
        let asset = AVURLAsset(url: input)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[0], outputSettings: nil)
        reader.add(output)
        check(reader.startReading(), "read encoded AAC fixture")
        var adts = Data()
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample), CMBlockBufferGetDataLength(block) > 0 else { continue }
            var packet = Data(count: CMBlockBufferGetDataLength(block))
            let status = packet.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            precondition(status == noErr)
            let count = CMSampleBufferGetNumSamples(sample)
            var offset = 0
            for index in 0..<count {
                let size = CMSampleBufferGetSampleSize(sample, at: index)
                adts += adtsFrame(packet.subdata(in: offset..<(offset + size)), sampleRate: sampleRate)
                offset += size
            }
        }
        check(reader.status == .completed && !adts.isEmpty, "AAC fixture contains complete packets")
        return adts
    }

    @available(macOS 26.0, *)
    @MainActor static func remoteDecodeChecks(root: URL) async throws {
        let adts = try await encodedADTS(root: root, seconds: 3)
        SubtitleHTTPFixture.configure(adts)
        let source = MacAudioSubtitleSource(url: URL(string: "https://fixture.invalid")!, identity: "remote", duration: 120,
            tracks: [.init(id: 3, ordinal: 1, language: nil)], remote: remoteFixture())
        let result = root.appendingPathComponent("remote-pcm.caf")
        let pcm = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        try await MacAudioSubtitleEngine.writeAudio(source: source, trackID: 3, start: 100, end: 102, format: pcm, to: result)
        let file = try AVAudioFile(forReading: result)
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        let energy = (8000..<24000).reduce(0.0) { $0 + pow(Double(buffer.floatChannelData![0][$1]), 2) } / 16000
        check(file.length == 32000 && energy > 0.02, "remote AAC decodes at a nonzero media offset without leading silence")
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("remote.aac").path), "temporary remote audio is removed after decoding")

        let actual441 = try await encodedADTS(root: root, seconds: 3, sampleRate: 44100)
        SubtitleHTTPFixture.configure(actual441)
        let result441 = root.appendingPathComponent("remote-441-pcm.caf")
        try await MacAudioSubtitleEngine.writeAudio(source: source, trackID: 3, start: 100, end: 102, format: pcm, to: result441)
        let file441 = try AVAudioFile(forReading: result441)
        let buffer441 = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(file441.length))!
        try file441.read(into: buffer441)
        let energy441 = (8000..<24000).reduce(0.0) { $0 + pow(Double(buffer441.floatChannelData![0][$1]), 2) } / 16000
        check(file441.length == 32000 && energy441 > 0.02,
              "real 44.1 kHz AAC resamples to two seconds of recognition PCM at a nonzero offset")

        // A 61-second media seek is clamped to 56s: 56-58s silence, then tone to 61s.
        // Reading only 3s or treating that silence as 58-60s loses the actual tail.
        let tailAudio = try await encodedADTS(root: root, seconds: 5, silentPrefix: 2)
        SubtitleHTTPFixture.configure(tailAudio)
        let tailSource = MacAudioSubtitleSource(url: source.url, identity: "remote-tail", duration: 61,
            tracks: source.tracks, remote: remoteFixture())
        let tailResult = root.appendingPathComponent("remote-tail.caf")
        try await MacAudioSubtitleEngine.writeAudio(source: tailSource, trackID: 3, start: 58, end: 61, format: pcm, to: tailResult)
        let read = SubtitleHTTPFixture.snapshot().first!
        let seek = URLComponents(url: read.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "StartTimeTicks" }?.value
        check(seek == "560000000", "tail request explicitly starts at Jellyfin's safe origin")
        let tailFile = try AVAudioFile(forReading: tailResult)
        let tailBuffer = AVAudioPCMBuffer(pcmFormat: pcm, frameCapacity: AVAudioFrameCount(tailFile.length))!
        try tailFile.read(into: tailBuffer)
        check(tailFile.length == 48000, "tail output contains exactly the requested three seconds")
        for range in [8000..<16000, 40000..<47200] {
            let energy = range.reduce(0.0) { $0 + pow(Double(tailBuffer.floatChannelData![0][$1]), 2) } / Double(range.count)
            check(energy > 0.02, "tail prefix is cropped and the final audio remains present at \(range)")
        }
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("remote.aac").path), "tail temporary audio is removed")
    }
}
