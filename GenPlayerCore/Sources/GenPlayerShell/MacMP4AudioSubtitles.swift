#if os(macOS) || os(iOS)
import Foundation
import AVFoundation

struct MP4AudioAccess: Sendable {
    struct Version: Sendable, Equatable { let size: UInt64; let stamp: String }
    /// Hashed source identity; known server paths exclude transient signed URLs.
    let identity: String
    let metadata: @Sendable () async throws -> Version
    private let sourceRead: MP4AudioIndex.Read
    private(set) var sharedReadAheadCache: MPVReadAheadByteCache?
    var kind: String = "smb"

    var read: MP4AudioIndex.Read {
        guard let cache = sharedReadAheadCache else { return sourceRead }
        let fallback = sourceRead
        return { offset, count in
            try await cache.readForAudioSubtitle(at: offset, count: count, fallback: fallback)
        }
    }

    init(identity: String, metadata: @escaping @Sendable () async throws -> Version,
         read: @escaping MP4AudioIndex.Read, kind: String = "smb",
         sharedReadAheadCache: MPVReadAheadByteCache? = nil) {
        self.identity = identity
        self.metadata = metadata
        self.sourceRead = read
        self.kind = kind
        self.sharedReadAheadCache = sharedReadAheadCache
    }

    func usingReadAheadCache(_ cache: MPVReadAheadByteCache?) -> Self {
        var copy = self
        copy.sharedReadAheadCache = cache
        return copy
    }

    static func fileIdentity(url: URL, provider: String?, serverID: String?, path: String?) -> (identity: String, scope: String)? {
        let kind = provider ?? "http"
        if provider != nil, let serverID, !serverID.isEmpty, let path, !path.isEmpty {
            return (MacAudioSubtitlePlan.digest([kind, serverID, path]),
                    MacAudioSubtitlePlan.digest([kind, serverID, (path as NSString).deletingLastPathComponent]))
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil; components.password = nil; components.fragment = nil
        guard let resource = components.url else { return nil }
        // Unknown HTTP endpoints can select the file via any query field. Hash the
        // complete resource locator rather than guessing which fields are signatures.
        let identity = MacAudioSubtitlePlan.digest([kind, serverID ?? "", resource.absoluteString])
        components.query = nil
        guard let directory = components.url?.deletingLastPathComponent() else { return nil }
        return (identity, MacAudioSubtitlePlan.digest([kind, serverID ?? "", directory.absoluteString]))
    }
}

struct MacMP4AudioSubtitles: Sendable {
    let access: MP4AudioAccess
    let version: MP4AudioAccess.Version
    let index: MP4AudioIndex

    func usingReadAheadCache(_ cache: MPVReadAheadByteCache?) -> Self {
        Self(access: access.usingReadAheadCache(cache), version: version, index: index)
    }

    static func inspect(_ access: MP4AudioAccess, url: URL) async throws -> MacAudioSubtitleSource {
        let version = try await access.metadata()
        let index: MP4AudioIndex
        do { index = try await MP4AudioIndex.inspect(size: version.size, read: access.read) }
        catch is MP4AudioIndex.Failure { throw access.kind == "smb" ? MacAudioSubtitleError.smbUnsupported : MacAudioSubtitleError.fileUnsupported }
        guard try await access.metadata() == version else { throw MacAudioSubtitleError.unreadable }
        let identity = MacAudioSubtitlePlan.digest(["\(access.kind)-mp4-audio-v1", access.identity,
            String(version.size), version.stamp, MacAudioSubtitlePlan.digest([index.metadata.base64EncodedString()])])
        let tracks = index.tracks.map {
            MacAudioSubtitleTrack(id: $0.id, ordinal: $0.ordinal,
                                  language: MacAudioSubtitleRemux.languageCode($0.language))
        }
        return MacAudioSubtitleSource(url: url, identity: identity, duration: index.duration, tracks: tracks,
                                      fileAudio: Self(access: access, version: version, index: index))
    }

    func writeAudio(trackID: Int32, start: Double, end: Double, format: AVAudioFormat, to url: URL) async throws {
        guard try await access.metadata() == version else { throw MacAudioSubtitleError.unreadable }
        let segment = try await index.segment(trackID: trackID, start: start, end: end, read: access.read)
        guard try await access.metadata() == version else { throw MacAudioSubtitleError.unreadable }
        try Task.checkCancellation()
        guard let segment else {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings,
                                         commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            var left = Int(((end - start) * format.sampleRate).rounded())
            while left > 0 {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(left, 4096))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw MacAudioSubtitleError.unreadable }
                buffer.frameLength = count
                for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                    if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
                }
                try writer.write(from: buffer); left -= Int(count)
            }
            return
        }
        let file = url.deletingLastPathComponent().appendingPathComponent("smb-audio-" + UUID().uuidString + ".m4a")
        defer { try? FileManager.default.removeItem(at: file) }
        try segment.bytes.write(to: file, options: .atomic)
        let asset = AVURLAsset(url: file), tracks = try await asset.loadTracks(withMediaType: .audio)
        guard tracks.count == 1, let track = tracks.first else { throw MacAudioSubtitleError.unreadable }
        let source = MacAudioSubtitleSource(url: file, identity: "temporary-smb-segment", duration: index.duration,
            tracks: [.init(id: track.trackID, ordinal: 1, language: nil)], timelineOffset: start)
        if #available(macOS 26.0, iOS 26.0, *) {
            let descriptions = try await track.load(.formatDescriptions)
            guard let description = descriptions.first, let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  basic.pointee.mSampleRate > 0 else { throw MacAudioSubtitleError.unreadable }
            let rate = basic.pointee.mSampleRate
            if rate == format.sampleRate {
                try await MacAudioSubtitleEngine.writeAudio(source: source, trackID: track.trackID,
                                                           start: start, end: end, format: format, to: url)
            } else {
                // Keep AudioMixOutput at the encoded rate. Its sample-rate conversion can
                // drift with different demux buffer boundaries; one continuous converter
                // owns the complete PCM segment instead.
                guard let nativeFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else {
                    throw MacAudioSubtitleError.unreadable
                }
                let native = file.deletingPathExtension().appendingPathExtension("caf")
                defer { try? FileManager.default.removeItem(at: native) }
                try await MacAudioSubtitleEngine.writeAudio(source: source, trackID: track.trackID,
                                                           start: start, end: end, format: nativeFormat, to: native)
                try Self.resample(native, to: url, format: format, duration: end - start)
            }
        } else { throw MacAudioSubtitleError.unavailable }
    }

    private static func resample(_ inputURL: URL, to outputURL: URL, format: AVAudioFormat, duration: Double) throws {
        let input = try AVAudioFile(forReading: inputURL)
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format) else { throw MacAudioSubtitleError.unreadable }
        let output = try AVAudioFile(forWriting: outputURL, settings: format.settings,
                                    commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let target = Int64((duration * format.sampleRate).rounded())
        var written: Int64 = 0, stalled = 0
        var failure: Error?, retainedInput: AVAudioPCMBuffer?
        while written < target {
            try Task.checkCancellation()
            let capacity = AVAudioFrameCount(min(4096, target - written))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw MacAudioSubtitleError.unreadable }
            var error: NSError?
            let status = converter.convert(to: buffer, error: &error) { requested, state in
                do {
                    try Task.checkCancellation()
                    guard input.framePosition < input.length else { state.pointee = .endOfStream; return nil }
                    let count = AVAudioFrameCount(min(Int64(requested), input.length - input.framePosition))
                    guard requested > 0, requested <= 1_000_000,
                          let data = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count) else {
                        throw MacAudioSubtitleError.unreadable
                    }
                    try input.read(into: data, frameCount: count)
                    retainedInput = data
                    state.pointee = data.frameLength == 0 ? .endOfStream : .haveData
                    return data.frameLength == 0 ? nil : data
                } catch {
                    failure = error; state.pointee = .endOfStream; return nil
                }
            }
            if let failure { throw failure }
            if let error { throw error }
            guard status != .error else { throw MacAudioSubtitleError.unreadable }
            if buffer.frameLength > 0 {
                try output.write(from: buffer); written += Int64(buffer.frameLength); stalled = 0
            } else { stalled += 1 }
            if status == .endOfStream { break }
            guard stalled < 4 else { throw MacAudioSubtitleError.unreadable }
        }
        withExtendedLifetime(retainedInput) {}
        // Rounding between sample rates may leave the last fractional frame unfilled.
        guard target - written <= 2 else { throw MacAudioSubtitleError.unreadable }
        if written < target {
            let count = AVAudioFrameCount(target - written)
            guard let zero = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw MacAudioSubtitleError.unreadable }
            zero.frameLength = count
            for audio in UnsafeMutableAudioBufferListPointer(zero.mutableAudioBufferList) {
                if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
            }
            try output.write(from: zero)
        }
        try Task.checkCancellation()
    }
}
#endif
