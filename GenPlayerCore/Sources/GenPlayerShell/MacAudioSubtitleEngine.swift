#if os(macOS) || os(iOS)
import Foundation
import AVFoundation
import Speech

struct MacAudioSubtitleTrack: Identifiable, Sendable {
    let id: Int32
    let ordinal: Int
    let language: String?
    var startTime: Double = 0
    var name: String? = nil
    var requiresPCM = false
    var codec: String? = nil
    // Recognition/cache identity can retain a legacy ID while preparation uses mpv.
    var preparationTrackID: Int32? = nil
}
struct MacAudioSubtitleSource: Sendable {
    enum Decoder: Sendable { case native, vlcRemux, mpvPCM }
    let url: URL
    let identity: String
    let duration: Double
    let tracks: [MacAudioSubtitleTrack]
    var decoder: Decoder = .native
    var remote: MacJellyfinAudioSubtitles? = nil
    var fileAudio: MacMP4AudioSubtitles? = nil
    var timelineOffset: Double = 0

    /// VLC IDs and MP4/AVFoundation/server IDs are different namespaces. Preserve
    /// the original audio ordinal, including unsupported tracks omitted by the reader.
    func playingTrack(id: Int, trackIDs: [Int]) -> MacAudioSubtitleTrack? {
        let playable = trackIDs.filter { $0 != -1 }
        guard id != -1, Set(playable).count == playable.count,
              let index = playable.firstIndex(of: id) else { return nil }
        if decoder == .vlcRemux { return tracks.first { Int($0.id) == id } }
        // A transcoded playback stream may expose fewer tracks than its source.
        guard fileAudio != nil || playable.count == tracks.count else { return nil }
        return tracks.first { $0.ordinal == index + 1 }
    }

    static func inspect(_ url: URL) async throws -> Self {
        guard url.isFileURL else { throw MacAudioSubtitleError.localOnly }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .fileResourceIdentifierKey])
        guard let size = values.fileSize, let modified = values.contentModificationDate else {
            throw MacAudioSubtitleError.unreadable
        }
        let identity = MacAudioSubtitlePlan.digest([url.standardizedFileURL.path, String(size),
            String(modified.timeIntervalSince1970), String(describing: values.fileResourceIdentifier)])
        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard MacAudioSubtitlePlan.count(duration: duration) > 0 else { throw MacAudioSubtitleError.unreadable }
            let audio = try await asset.loadTracks(withMediaType: .audio)
            guard !audio.isEmpty else { throw MacAudioSubtitleError.unreadable }
            var tracks: [MacAudioSubtitleTrack] = []
            for (ordinal, track) in audio.enumerated() {
                let extended = try await track.load(.extendedLanguageTag)
                let code = try await track.load(.languageCode)
                let language = extended ?? code
                tracks.append(.init(id: track.trackID, ordinal: ordinal + 1, language: language))
            }
            return Self(url: url, identity: identity, duration: duration, tracks: tracks)
        } catch {
            try Task.checkCancellation()
            return try await MacAudioSubtitleRemux.inspect(url, identity: identity)
        }
    }
}

enum MacAudioSubtitleError: String, Error {
    case unavailable = "AS.Unavailable"
    case localOnly = "AS.LocalOnly"
    case unreadable = "AS.Unreadable"
    case language = "AS.ChooseLanguage"
    case busy = "AS.Busy"
    case failed = "AS.Failed"
    case storage = "AS.StorageFailed"
    case remoteFailed = "AS.RemoteFailed"
    case remoteTracks = "AS.RemoteTracks"
    case smbUnsupported = "AS.SMBUnsupported"
    case fileUnsupported = "AS.FileUnsupported"
}

@available(macOS 26.0, iOS 26.0, *)
enum MacAudioSubtitleEngine {

    static func prepare(language: String) async throws {
        guard SpeechTranscriber.isAvailable else { throw MacAudioSubtitleError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
            throw MacAudioSubtitleError.language
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .timeIndexedTranscriptionWithAlternatives)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        try Task.checkCancellation()
    }

    static func transcribe(source: MacAudioSubtitleSource, trackID: Int32, language: String,
                           chunk: Int) async throws -> [MacAudioSubtitleCue] {
        try Task.checkCancellation()
        let transcriber = SpeechTranscriber(locale: Locale(identifier: language),
            transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw MacAudioSubtitleError.unavailable
        }
        let ownRange = MacAudioSubtitlePlan.range(chunk: chunk, duration: source.duration)
        let start = max(0, ownRange.lowerBound - MacAudioSubtitlePlan.contextSeconds)
        let end = min(source.duration, ownRange.upperBound + MacAudioSubtitlePlan.contextSeconds)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GenPlayerAudioSubtitles-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("chunk.caf")
        // Decoding is pull-based and bounded by a 34-second chunk; no player callbacks are replaced.
        try await writeAudio(source: source, trackID: trackID, start: start, end: end, format: format, to: fileURL)
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () throws -> [MacAudioSubtitleCue] in
            var words: [(start: Double, end: Double, text: String)] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                var timed = false
                for run in result.text.runs {
                    let text = String(result.text[run.range].characters)
                    guard let range = run.audioTimeRange else {
                        // Whitespace/punctuation may have their own untimed runs.
                        if timed, !words.isEmpty { words[words.count - 1].text += text }
                        continue
                    }
                    timed = true
                    words.append((start + range.start.seconds, start + range.end.seconds, text))
                }
                if !timed {
                    words.append((start + result.range.start.seconds, start + result.range.end.seconds,
                                  String(result.text.characters)))
                }
            }
            return MacAudioSubtitlePlan.cues(words: words, chunk: chunk, duration: source.duration)
        }
        return try await withTaskCancellationHandler {
            do {
                let file = try AVAudioFile(forReading: fileURL)
                if let lastTime = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: lastTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                let result = try await collector.value
                try Task.checkCancellation()
                return result
            } catch {
                collector.cancel()
                await analyzer.cancelAndFinishNow()
                _ = try? await collector.value
                throw error
            }
        } onCancel: {
            collector.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    static func writeAudio(source: MacAudioSubtitleSource, trackID: Int32, start: Double, end: Double,
                                   format: AVAudioFormat, to url: URL) async throws {
        if let fileAudio = source.fileAudio {
            try await fileAudio.writeAudio(trackID: trackID, start: start, end: end, format: format, to: url)
            return
        }
        if let remote = source.remote {
            let requestStart = try MacJellyfinAudioSubtitles.requestStart(start: start, end: end, duration: source.duration)
            let audio = url.deletingLastPathComponent().appendingPathComponent("remote.aac")
            defer { try? FileManager.default.removeItem(at: audio) }
            try await remote.audio(start: requestStart, end: end, track: trackID, to: audio)
            let asset = AVURLAsset(url: audio)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard tracks.count == 1, let track = tracks.first else { throw MacAudioSubtitleError.remoteFailed }
            let local = MacAudioSubtitleSource(url: audio, identity: source.identity, duration: source.duration,
                tracks: [.init(id: track.trackID, ordinal: 1, language: nil)], timelineOffset: requestStart)
            try await writeAudio(source: local, trackID: track.trackID, start: start, end: end, format: format, to: url)
            return
        }
        let access = source.url.startAccessingSecurityScopedResource()
        defer { if access { source.url.stopAccessingSecurityScopedResource() } }
        guard let selected = source.tracks.first(where: { $0.id == trackID }),
              start.isFinite, end.isFinite, start >= 0, end > start else {
            throw MacAudioSubtitleError.unreadable
        }
        let audioURL: URL
        let timelineOffset: Double
        switch source.decoder {
        case .native: audioURL = source.url; timelineOffset = source.timelineOffset
        case .vlcRemux, .mpvPCM:
            audioURL = try await MacAudioSubtitleRemux.shared.audioURL(source: source, trackID: trackID)
            timelineOffset = selected.startTime
        }
        let asset = AVURLAsset(url: audioURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first(where: { source.decoder != .native || $0.trackID == trackID }) else {
            throw MacAudioSubtitleError.unreadable
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: [track], audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        guard reader.canAdd(output) else { throw MacAudioSubtitleError.unreadable }
        reader.add(output)
        reader.timeRange = CMTimeRange(start: CMTime(seconds: max(0, start - timelineOffset), preferredTimescale: 600000),
                                      end: CMTime(seconds: max(0, end - timelineOffset), preferredTimescale: 600000))
        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: format.sampleRate,
                                           channels: format.channelCount, interleaved: true),
              let converter = AVAudioConverter(from: pcmFormat, to: format) else { throw MacAudioSubtitleError.unreadable }
        let writer = try AVAudioFile(forWriting: url, settings: format.settings,
                                     commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        let total = Int64(((end - start) * format.sampleRate).rounded())
        var written: Int64 = 0
        func silence(_ frames: Int64) throws {
            var left = frames
            while left > 0 {
                try Task.checkCancellation()
                let size = AVAudioFrameCount(min(left, 4096))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: size) else { throw MacAudioSubtitleError.unreadable }
                buffer.frameLength = size
                for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                    if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
                }
                try writer.write(from: buffer)
                left -= Int64(size)
                written += Int64(size)
            }
        }
        if end <= timelineOffset { try silence(total); return }
        guard reader.startReading() else { throw MacAudioSubtitleError.unreadable }
        defer { reader.cancelReading() }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard pts.isFinite else { throw MacAudioSubtitleError.unreadable }
            let position = Int64(((pts + timelineOffset - start) * format.sampleRate).rounded())
            let samples = CMSampleBufferGetNumSamples(sample)
            let skip = max(0, written - position)
            let available = min(Int64(samples) - skip, total - max(written, position))
            guard available > 0 else { continue }
            if position > written { try silence(min(position - written, total - written)) }
            let count = AVAudioFrameCount(available)
            guard let input = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: count),
                  let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count) else { throw MacAudioSubtitleError.unreadable }
            input.frameLength = count
            guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(skip), frameCount: Int32(count), into: input.mutableAudioBufferList) == noErr else {
                throw MacAudioSubtitleError.unreadable
            }
            try converter.convert(to: converted, from: input)
            try writer.write(from: converted)
            written += Int64(converted.frameLength)
        }
        guard reader.status == .completed else { throw MacAudioSubtitleError.unreadable }
        // Preserve gaps and nonzero track start times in the media timeline.
        if written < total { try silence(total - written) }
    }
}
#endif
