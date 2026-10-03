#if os(macOS) || os(iOS)
import Foundation

/// Credentials exist only in memory. Neither requests nor signed URLs enter the subtitle cache.
struct MacJellyfinAudioSubtitles: Sendable {
    let serverURL: URL
    let serverID: String
    let itemID: String
    let mediaSourceID: String?
    let token: String
    enum Provider: String, Sendable { case jellyfin, emby }
    var provider: Provider = .jellyfin
    var usesVideoRoute = false
    var makeSession: @Sendable (Double) -> URLSession = { Self.session(timeout: $0) }

    struct Info: Decodable {
        let MediaSources: [Media]
        struct Media: Decodable {
            let Id: String
            let RunTimeTicks: Int64?
            let Size: Int64?
            let ETag: String?
            let LiveStreamId: String?
            let IsInfiniteStream: Bool?
            let RequiresOpening: Bool?
            let MediaStreams: [Stream]?
        }
        struct Stream: Decodable {
            let Index: Int32?
            let `Type`: String
            let Language: String?
            let Codec: String?
            let BitRate: Int?
            let Channels: Int?
            let SampleRate: Int?
            let IsExternal: Bool?
            let Title: String?
            let DisplayTitle: String?
        }
    }

    func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard !token.isEmpty, ["http", "https"].contains(serverURL.scheme?.lowercased() ?? ""),
              serverURL.host != nil, serverURL.user == nil, serverURL.password == nil,
              serverURL.query == nil, serverURL.fragment == nil else { throw MacAudioSubtitleError.remoteFailed }
        var components = URLComponents(url: serverURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw MacAudioSubtitleError.remoteFailed }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        return request
    }

    func inspect() async throws -> MacAudioSubtitleSource {
        let session = makeSession(120)
        defer { session.invalidateAndCancel() }
        let request = try request("Items/\(itemID)/PlaybackInfo")
        let (bytes, response) = try await session.bytes(for: request)
        try Self.validate(response)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 4 * 1024 * 1024 else { throw MacAudioSubtitleError.remoteFailed }
            data.append(byte)
        }
        return try source(from: data)
    }

    func source(from data: Data) throws -> MacAudioSubtitleSource {
        let info = try JSONDecoder().decode(Info.self, from: data)
        let media: Info.Media
        if let id = mediaSourceID, !id.isEmpty, let match = info.MediaSources.first(where: { $0.Id == id }) {
            media = match
        } else if mediaSourceID == nil, info.MediaSources.count == 1, let only = info.MediaSources.first {
            media = only
        } else { throw MacAudioSubtitleError.remoteFailed }
        let duration = Double(media.RunTimeTicks ?? 0) / 10_000_000
        guard MacAudioSubtitlePlan.count(duration: duration) > 0, media.LiveStreamId?.isEmpty != false,
              media.IsInfiniteStream != true, media.RequiresOpening != true else { throw MacAudioSubtitleError.remoteFailed }
        let audio = (media.MediaStreams ?? []).filter { $0.Type.lowercased() == "audio" }
        guard !audio.isEmpty else { throw MacAudioSubtitleError.remoteFailed }
        let embedded = audio.filter { $0.IsExternal != true }
        guard !embedded.isEmpty, embedded.allSatisfy({ ($0.Index ?? -1) >= 0 }),
              Set(embedded.compactMap(\.Index)).count == embedded.count else { throw MacAudioSubtitleError.remoteTracks }
        let tracks = embedded.enumerated().map { ordinal, track in
            MacAudioSubtitleTrack(id: track.Index!, ordinal: ordinal + 1, language: track.Language,
                name: [track.DisplayTitle, track.Title].compactMap { $0 }
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
        // Preserve the existing single-track cache identity. Any additional audio stream
        // requires explicit mapping, including when some tracks are external.
        let mapped = provider == .emby || audio.count > 1
        let trackIdentity = embedded.flatMap { track in
            [String(track.Index!), track.Codec ?? "", track.Language ?? "", String(track.BitRate ?? 0),
             String(track.Channels ?? 0), String(track.SampleRate ?? 0)]
        }
        let identity = MacAudioSubtitlePlan.digest([mapped ? "\(provider.rawValue)-mapped-audio-v1" : "jellyfin-audio-v1",
            serverID, serverURL.absoluteString, itemID, media.Id, String(duration), String(media.Size ?? 0), media.ETag ?? ""] + trackIdentity)
        let resolved = Self(serverURL: serverURL, serverID: serverID, itemID: itemID, mediaSourceID: media.Id,
                            token: token, provider: provider, usesVideoRoute: mapped, makeSession: makeSession)
        return .init(url: serverURL, identity: identity, duration: duration, tracks: tracks, remote: resolved)
    }

    /// Jellyfin clamps progressive seeks to RunTimeTicks - 5 seconds. Request that
    /// origin explicitly so decoding can trim the prefix without losing the media tail.
    static func requestStart(start: Double, end: Double, duration: Double) throws -> Double {
        guard start.isFinite, end.isFinite, duration.isFinite, start >= 0, end > start,
              end <= duration, duration <= 7 * 86400, end - start <= 34.01 else {
            throw MacAudioSubtitleError.remoteFailed
        }
        return min(start, max(0, duration - 5))
    }

    /// Read only this chunk, with bounded buffers, then close our independent server encoding.
    func audio(start: Double, end: Double, track: Int32, to file: URL) async throws {
        guard start.isFinite, end.isFinite, start >= 0, end > start, end - start <= 34.01,
              end <= 7 * 24 * 3600, track >= 0 else { throw MacAudioSubtitleError.remoteFailed }
        let device = "GenPlayer-ASR-" + UUID().uuidString
        let playSession = UUID().uuidString
        let ids = [URLQueryItem(name: "DeviceId", value: device), URLQueryItem(name: "PlaySessionId", value: playSession)]
        var options = ["MediaSourceId": mediaSourceID ?? "", "Static": "false", "AudioCodec": "aac",
            "AudioSampleRate": "48000", "AudioBitRate": "96000", "AudioChannels": "1", "MaxAudioChannels": "1",
            "EnableAutoStreamCopy": "false", "AllowAudioStreamCopy": "false", "EnableAudioVbrEncoding": "false",
            "AudioStreamIndex": String(track), "StartTimeTicks": String(Int64((start * 10_000_000).rounded()))]
        if usesVideoRoute {
            options["VideoCodec"] = "copy"
            options["AllowVideoStreamCopy"] = "true"
            options["SubtitleStreamIndex"] = "-1"
        }
        let path = usesVideoRoute ? "Videos/\(itemID)/stream.ts" : "Audio/\(itemID)/stream.aac"
        let request = try request(path, query: ids + options.map { .init(name: $0.key, value: $0.value) })
        let session = makeSession(120)
        var failure: Error?
        do {
            let (bytes, response) = try await session.bytes(for: request)
            try Self.validate(response)
            FileManager.default.createFile(atPath: file.path, contents: nil)
            let writer = try FileHandle(forWritingTo: file)
            defer { try? writer.close() }
            var parser = MacSubtitleADTS()
            var transport = MacSubtitleTransportStream()
            var received = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                received += 1
                guard received <= (usesVideoRoute ? 256 : 2) * 1024 * 1024 else { throw MacAudioSubtitleError.remoteFailed }
                let audioBytes = usesVideoRoute ? try transport.append(byte) : Data([byte])
                for audioByte in audioBytes {
                    if let frame = try parser.append(audioByte) { try writer.write(contentsOf: frame) }
                }
                if parser.duration >= end - start { break }
            }
            // A final AAC frame can end just before the container duration. Large truncation is a failure,
            // not a silent chunk that may be permanently cached as recognized.
            guard parser.duration >= end - start - 0.15, parser.duration > 0 else { throw MacAudioSubtitleError.remoteFailed }
            try Task.checkCancellation()
        } catch { failure = error }
        session.invalidateAndCancel()
        // Do not inherit parent cancellation: cleanup must also run after a seek or window close.
        await Task.detached(priority: .utility) {
            let cleanup = self.makeSession(5)
            defer { cleanup.invalidateAndCancel() }
            if var stop = try? self.request("Videos/ActiveEncodings", query: ids) {
                stop.httpMethod = "DELETE"
                _ = try? await cleanup.data(for: stop)
            }
        }.value
        if let failure {
            try? FileManager.default.removeItem(at: file)
            try Task.checkCancellation()
            throw (failure as? MacAudioSubtitleError) ?? MacAudioSubtitleError.remoteFailed
        }
        try Task.checkCancellation()
    }

    private static func validate(_ response: URLResponse) throws {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw MacAudioSubtitleError.remoteFailed
        }
    }
    private static func session(timeout: Double = 120) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.timeoutIntervalForResource = timeout
        config.timeoutIntervalForRequest = min(30, timeout)
        return URLSession(configuration: config, delegate: MacSubtitleNoRedirect(), delegateQueue: nil)
    }
}

private final class MacSubtitleNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Bounded MPEG-TS demuxer for Jellyfin's mapped AAC stream. Video packets are discarded.
struct MacSubtitleTransportStream {
    private var packet: [UInt8] = []
    private var pmtPID: Int?
    private var audioPID: Int?
    private var sections: [Int: [UInt8]] = [:]
    private var continuity: [Int: Int] = [:]
    private var pesHeader: [UInt8] = []
    private var needsPESHeader = false

    mutating func append(_ byte: UInt8) throws -> Data {
        packet.append(byte)
        guard packet.count == 188 else { return Data() }
        let bytes = packet
        packet.removeAll(keepingCapacity: true)
        guard bytes[0] == 0x47, bytes[1] & 0x80 == 0, bytes[3] & 0xc0 == 0 else { throw MacAudioSubtitleError.remoteFailed }
        let pid = (Int(bytes[1] & 0x1f) << 8) | Int(bytes[2])
        guard pid == 0 || pid == pmtPID || pid == audioPID else { return Data() }
        let mode = (bytes[3] >> 4) & 3
        guard mode != 0 else { throw MacAudioSubtitleError.remoteFailed }
        var offset = 4
        if mode & 2 != 0 { offset += 1 + Int(bytes[4]) }
        guard offset <= 188 else { throw MacAudioSubtitleError.remoteFailed }
        guard mode & 1 != 0, offset < 188 else { return Data() }
        let counter = Int(bytes[3] & 15)
        if let previous = continuity[pid] {
            if counter == previous { return Data() }
            guard counter == (previous + 1) % 16 else { throw MacAudioSubtitleError.remoteFailed }
        }
        continuity[pid] = counter
        let starts = bytes[1] & 0x40 != 0
        var payload = Array(bytes[offset...])
        if pid == 0 || pid == pmtPID {
            if starts {
                guard let pointer = payload.first, Int(pointer) + 1 <= payload.count else { throw MacAudioSubtitleError.remoteFailed }
                payload = Array(payload.dropFirst(Int(pointer) + 1))
                sections[pid] = []
            }
            guard sections[pid] != nil else { return Data() }
            sections[pid, default: []] += payload
            let section = sections[pid]!
            guard section.count >= 3 else { return Data() }
            let length = 3 + ((Int(section[1] & 15) << 8) | Int(section[2]))
            guard length <= 1024 else { throw MacAudioSubtitleError.remoteFailed }
            guard section.count >= length else { return Data() }
            sections[pid] = nil
            guard length >= 12, section[5] & 1 != 0 else { throw MacAudioSubtitleError.remoteFailed }
            if pid == 0 {
                guard section[0] == 0 else { throw MacAudioSubtitleError.remoteFailed }
                var programs: [Int] = []
                for i in stride(from: 8, to: length - 4, by: 4) {
                    guard i + 3 < length - 4 else { throw MacAudioSubtitleError.remoteFailed }
                    if section[i] != 0 || section[i + 1] != 0 {
                        programs.append((Int(section[i + 2] & 31) << 8) | Int(section[i + 3]))
                    }
                }
                guard programs.count == 1 else { throw MacAudioSubtitleError.remoteFailed }
                pmtPID = programs[0]
            } else {
                guard section[0] == 2, length >= 16 else { throw MacAudioSubtitleError.remoteFailed }
                var i = 12 + ((Int(section[10] & 15) << 8) | Int(section[11]))
                var candidates: [Int] = []
                while i < length - 4 {
                    guard i + 4 < length - 4 else { throw MacAudioSubtitleError.remoteFailed }
                    if section[i] == 0x0f { candidates.append((Int(section[i + 1] & 31) << 8) | Int(section[i + 2])) }
                    i += 5 + ((Int(section[i + 3] & 15) << 8) | Int(section[i + 4]))
                }
                guard i == length - 4, candidates.count == 1,
                      audioPID == nil || audioPID == candidates[0] else { throw MacAudioSubtitleError.remoteFailed }
                audioPID = candidates[0]
            }
            return Data()
        }
        if starts { pesHeader = []; needsPESHeader = true }
        if needsPESHeader {
            for (index, byte) in payload.enumerated() {
                pesHeader.append(byte)
                if pesHeader.count == 9 {
                    guard pesHeader[0...2].elementsEqual([0, 0, 1]), pesHeader[3] & 0xe0 == 0xc0 else {
                        throw MacAudioSubtitleError.remoteFailed
                    }
                }
                if pesHeader.count >= 9, pesHeader.count == 9 + Int(pesHeader[8]) {
                    needsPESHeader = false
                    return Data(payload.dropFirst(index + 1))
                }
            }
            return Data()
        }
        // Ignore continuations before the first PES header instead of treating headers as audio.
        return pesHeader.isEmpty ? Data() : Data(payload)
    }
}

/// Jellyfin/FFmpeg emits ADTS without ID3. Never retain more than one 13-bit-length AAC frame.
struct MacSubtitleADTS {
    private var pending = Data()
    private var length = 0
    private var sampleRate: Double?
    private(set) var duration = 0.0
    mutating func append(_ byte: UInt8) throws -> Data? {
        pending.append(byte)
        if pending.count == 7 {
            let b = Array(pending)
            // Emby may output 44.1 kHz despite a 48 kHz request. Count the actual AAC samples.
            // Keep AAC-LC, mono and one raw block, and reject format changes within a chunk.
            let frequencyIndex = (b[2] >> 2) & 15
            let rate: Double = frequencyIndex == 3 ? 48000 : 44100
            guard b[0] == 0xff, b[1] & 0xf6 == 0xf0, b[2] >> 6 == 1,
                  [3, 4].contains(frequencyIndex),
                  sampleRate == nil || sampleRate == rate, ((Int(b[2] & 1) << 2) | Int(b[3] >> 6)) == 1,
                  b[6] & 3 == 0 else { throw MacAudioSubtitleError.remoteFailed }
            sampleRate = rate
            length = (Int(b[3] & 3) << 11) | (Int(b[4]) << 3) | Int(b[5] >> 5)
            guard length > (b[1] & 1 == 1 ? 7 : 9) else { throw MacAudioSubtitleError.remoteFailed }
        }
        if length > 0, pending.count == length {
            let frame = pending
            pending = Data(); length = 0
            duration += 1024.0 / sampleRate!
            return frame
        }
        return nil
    }
}
#endif
