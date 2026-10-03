#if os(macOS) || os(iOS)
import Foundation
import AVFoundation

/// Prepare selected audio independently with mpv PCM; preserve existing recognition cache identities without creating VLC readers.
/// Only the requested subtitle chunk is subsequently read into recognition memory.
actor MacAudioSubtitleRemux {
    static let shared = MacAudioSubtitleRemux()
    private var files: [(key: String, url: URL)] = []
    private let temporaryDirectory: URL

    init(temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.temporaryDirectory = temporaryDirectory
    }

    static func languageCode(_ value: String?) -> String? {
        let name = (value ?? "").lowercased()
        guard !["", "und", "zxx"].contains(name) else { return nil }
        let codes: [String], normalized: String?
        if #available(macOS 13.0, iOS 16.0, *) {
            codes = Locale.LanguageCode.isoLanguageCodes.map(\.identifier)
            normalized = Locale(identifier: name).language.languageCode?.identifier
        } else {
            codes = Locale.isoLanguageCodes
            normalized = Locale(identifier: name).languageCode
        }
        return codes.first {
            $0 == name || $0 == normalized || Locale(identifier: "en").localizedString(forLanguageCode: $0)?.lowercased() == name
        }
    }

    static func inspect(_ url: URL, identity: String) async throws -> MacAudioSubtitleSource {
        guard ["mkv", "mka"].contains(url.pathExtension.lowercased()) else { throw MacAudioSubtitleError.unreadable }
        let legacyIdentity = identity + "|vlc-remux-v1"
        do {
            let metadata = try await MPVAudioFileReader.inspect(url)
            let originTask = Task.detached(priority: .utility) {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return try MacMatroskaAudioOrigin.layout(url: url)
            }
            let layout = try await withTaskCancellationHandler { try await originTask.value } onCancel: { originTask.cancel() }
            try Task.checkCancellation()
            guard metadata.tracks.count == layout.origins.count,
                  MacAudioSubtitlePlan.count(duration: metadata.duration) > 0 else { throw MacAudioSubtitleError.unreadable }
            let legacy: LegacyMapping?
            if UserDefaults.standard.data(forKey: "macAudioSubtitle." + legacyIdentity) != nil {
                legacy = try await legacyMapping(identity: legacyIdentity, metadata: metadata, ids: layout.legacyIDs)
            } else { legacy = nil }
            let tracks = metadata.tracks.enumerated().map { index, track in
                MacAudioSubtitleTrack(id: legacy?.tracks[index].id ?? track.id, ordinal: track.ordinal,
                    language: languageCode(track.language), startTime: layout.origins[index], requiresPCM: true,
                    codec: track.codec, preparationTrackID: track.id)
            }
            return MacAudioSubtitleSource(url: url, identity: legacy == nil ? identity + "|mpv-pcm-v1" : legacyIdentity,
                duration: legacy?.duration ?? metadata.duration, tracks: tracks, decoder: .mpvPCM)
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }

    private struct LegacyMapping: Codable {
        struct Track: Codable { let id: Int32; let codec: String; let language: String? }
        let duration: Double
        let tracks: [Track]

        static func codecIdentity(_ codec: String) -> String? {
            guard !codec.isEmpty else { return nil }
            // Preserve v1 entries for previously supported recognition tracks.
            // Other tracks still occupy verified container IDs; identify them
            // without pretending they had a VLC recognition-cache codec.
            return ["aac": "mp4a", "ac3": "a52 ", "dts": "dts "][codec] ?? "mpv:" + codec
        }

        func matches(_ metadata: MPVAudioFileReader.Metadata) -> Bool {
            guard duration.isFinite, duration > 0, abs(duration - metadata.duration) < 0.1,
                  tracks.count == metadata.tracks.count, Set(tracks.map(\.id)).count == tracks.count else { return false }
            return zip(tracks, metadata.tracks).allSatisfy { old, native in
                guard old.id >= 0, Self.codecIdentity(native.codec) == old.codec else { return false }
                let language = MacAudioSubtitleRemux.languageCode(native.language)
                return old.language == nil || language == nil || old.language == language
            }
        }
    }

    private static func legacyMapping(identity: String, metadata: MPVAudioFileReader.Metadata,
                                      ids: [Int32]?) async throws -> LegacyMapping {
        // Identity includes original file size/mtime/resource identity. Preserve old
        // recognition IDs, but always decode with the independently inspected mpv ID.
        let key = "macAudioSubtitle." + identity + ".mpvTrackMap-v1"
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode(LegacyMapping.self, from: data), saved.matches(metadata), ids == nil || saved.tracks.map(\.id) == ids { return saved }
        guard let ids, ids.count == metadata.tracks.count else { throw MacAudioSubtitleError.unreadable }
        if let preferenceData = UserDefaults.standard.data(forKey: "macAudioSubtitle." + identity),
           let preference = try? JSONSerialization.jsonObject(with: preferenceData) as? [String: Any],
           let ordinal = preference["ordinal"] as? Int, let selected = preference["track"] as? Int32 {
            guard ordinal > 0, ids.indices.contains(ordinal - 1), ids[ordinal - 1] == selected else {
                throw MacAudioSubtitleError.unreadable
            }
        }
        let tracks = try zip(ids, metadata.tracks).map { id, track -> LegacyMapping.Track in
            guard let codec = LegacyMapping.codecIdentity(track.codec) else { throw MacAudioSubtitleError.unreadable }
            return .init(id: id, codec: codec, language: languageCode(track.language))
        }
        let mapping = LegacyMapping(duration: metadata.duration, tracks: tracks)
        guard mapping.matches(metadata) else { throw MacAudioSubtitleError.unreadable }
        try Task.checkCancellation()
        UserDefaults.standard.set(try JSONEncoder().encode(mapping), forKey: key)
        return mapping
    }

    func audioURL(source: MacAudioSubtitleSource, trackID: Int32) async throws -> URL {
        try Task.checkCancellation()
        guard let track = source.tracks.first(where: { $0.id == trackID }) else { throw MacAudioSubtitleError.unreadable }
        let preparationRevision = source.decoder == .mpvPCM ? "mpv-pcm-v1" : (track.requiresPCM ? "pcm-v1" : "copy")
        let key = MacAudioSubtitlePlan.digest([source.identity, String(trackID), preparationRevision])
        if let saved = files.first(where: { $0.key == key }), FileManager.default.fileExists(atPath: saved.url.path) {
            return saved.url
        }
        let directory = temporaryDirectory.appendingPathComponent("GenPlayerAudioRemux-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(track.requiresPCM ? "audio.wav" : "audio.m4a")
        let task = Task.detached(priority: .utility) {
            let access = source.url.startAccessingSecurityScopedResource()
            defer { if access { source.url.stopAccessingSecurityScopedResource() } }
            guard source.decoder == .mpvPCM else { throw MacAudioSubtitleError.unreadable }
            try await MPVAudioFileReader.decode(source.url, trackID: track.preparationTrackID ?? trackID, to: url)
            try Task.checkCancellation()
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration).seconds
            guard tracks.count == 1, duration.isFinite, duration > 0 else { throw MacAudioSubtitleError.unreadable }
            try Task.checkCancellation()
            files.append((key, url))
            while files.count > 2 { try? FileManager.default.removeItem(at: files.removeFirst().url.deletingLastPathComponent()) }
            return url
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
#endif
