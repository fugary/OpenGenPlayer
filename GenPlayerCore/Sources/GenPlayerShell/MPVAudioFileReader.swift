#if os(macOS) || os(iOS)
import Foundation
import Libmpv

/// Independent local-file preparation for recognition. Never opens an audio device
/// or video surface. Track IDs belong to this reader, not the playback service.
enum MPVAudioFileReader {
    struct Track: Sendable {
        let id: Int32
        let ordinal: Int
        let codec: String
        let language: String
    }
    struct Metadata: Sendable {
        let duration: Double
        let tracks: [Track]
    }
    enum Failure: LocalizedError {
        case disabled, invalidInput, native(Int32), timeout, invalidOutput
        var errorDescription: String? {
            if case .disabled = self { return PlaybackEngineAvailability.unavailableMessage }
            return nil
        }
    }

    static func inspect(_ url: URL) async throws -> Metadata {
        try await run {
            guard url.isFileURL else { throw Failure.invalidInput }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let handle = try create(options: ["ao": "null", "aid": "auto", "pause": "yes"])
            defer { mpv_terminate_destroy(handle) }
            try command(handle, ["loadfile", url.path])
            let deadline = ProcessInfo.processInfo.systemUptime + 6
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                guard let event = mpv_wait_event(handle, 0.05) else { continue }
                if event.pointee.event_id == MPV_EVENT_FILE_LOADED {
                    guard let duration = Double(string(handle, "duration")), duration.isFinite, duration > 0,
                          let count = Int(string(handle, "track-list/count")), count > 0, count <= 1024 else {
                        throw Failure.invalidOutput
                    }
                    var tracks: [Track] = []
                    for index in 0..<count where string(handle, "track-list/\(index)/type") == "audio" {
                        guard let id = Int32(string(handle, "track-list/\(index)/id")), id > 0 else { throw Failure.invalidOutput }
                        tracks.append(.init(id: id, ordinal: tracks.count + 1,
                            codec: string(handle, "track-list/\(index)/codec"),
                            language: string(handle, "track-list/\(index)/lang")))
                    }
                    guard !tracks.isEmpty, Set(tracks.map(\.id)).count == tracks.count else { throw Failure.invalidOutput }
                    return Metadata(duration: duration, tracks: tracks)
                }
                if event.pointee.event_id == MPV_EVENT_END_FILE { throw Failure.invalidOutput }
            }
            throw Failure.timeout
        }
    }

    /// Output is bounded mono 16 kHz PCM. The caller owns temporary-file cleanup.
    static func decode(_ url: URL, trackID: Int32, to output: URL) async throws {
        try await run {
            guard url.isFileURL, output.isFileURL, trackID > 0,
                  url.standardizedFileURL != output.standardizedFileURL,
                  !FileManager.default.fileExists(atPath: output.path) else { throw Failure.invalidInput }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            var completed = false
            defer { if !completed { try? FileManager.default.removeItem(at: output) } }
            let handle = try create(options: ["ao": "pcm", "ao-pcm-file": output.path,
                "ao-pcm-waveheader": "yes", "aid": String(trackID), "pause": "no",
                "audio-samplerate": "16000", "audio-channels": "mono", "audio-format": "s16",
                "audio-pitch-correction": "no"])
            var isOpen = true
            defer {
                // Join before inspecting/deleting the muxer's output.
                if isOpen { mpv_terminate_destroy(handle) }
            }
            try command(handle, ["loadfile", url.path])
            let deadline = ProcessInfo.processInfo.systemUptime + 120
            while ProcessInfo.processInfo.systemUptime < deadline {
                try Task.checkCancellation()
                let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.uint64Value ?? 0
                guard size <= 512 * 1024 * 1024 else { throw Failure.invalidOutput }
                guard let event = mpv_wait_event(handle, 0.05) else { continue }
                if event.pointee.event_id == MPV_EVENT_FILE_LOADED {
                    guard string(handle, "aid") == String(trackID) else { throw Failure.invalidOutput }
                }
                if event.pointee.event_id == MPV_EVENT_END_FILE {
                    guard let data = event.pointee.data else { throw Failure.invalidOutput }
                    let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                    guard end.reason == MPV_END_FILE_REASON_EOF, end.error >= 0 else { throw Failure.invalidOutput }
                    mpv_terminate_destroy(handle)
                    isOpen = false
                    try Task.checkCancellation()
                    let finalSize = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.uint64Value ?? 0
                    guard finalSize > 44, finalSize <= 512 * 1024 * 1024 else { throw Failure.invalidOutput }
                    completed = true
                    return
                }
            }
            throw Failure.timeout
        }
    }

    private static func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility) { try Task.checkCancellation(); return try operation() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private static func create(options: [String: String]) throws -> OpaquePointer {
        guard PlaybackEngineAvailability.current.mpv else { throw Failure.disabled }
        guard let handle = mpv_create() else { throw Failure.invalidOutput }
        do {
            let values = ["config": "no", "terminal": "no", "msg-level": "all=no", "vo": "null",
                "vid": "no", "sid": "no", "secondary-sid": "no", "sub-auto": "no", "audio-file-auto": "no",
                "input-default-bindings": "no", "input-media-keys": "no", "idle": "yes", "keep-open": "no"]
                .merging(MPVStartupOptionPolicy.disabledScripts) { _, new in new }
                .merging(options) { _, new in new }
            for (name, value) in values {
                let result = mpv_set_option_string(handle, name, value)
                if result == MPV_ERROR_OPTION_NOT_FOUND.rawValue,
                   MPVStartupOptionPolicy.acceptsMissingOption(name: name, value: value) { continue }
                guard result >= 0 else { throw Failure.native(result) }
            }
            let result = mpv_initialize(handle)
            guard result >= 0 else { throw Failure.native(result) }
            return handle
        } catch { mpv_terminate_destroy(handle); throw error }
    }

    private static func command(_ handle: OpaquePointer, _ values: [String]) throws {
        let strings = values.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        var args = strings.map { UnsafePointer<CChar>($0) } + [nil]
        let result = mpv_command(handle, &args)
        guard result >= 0 else { throw Failure.native(result) }
    }

    private static func string(_ handle: OpaquePointer, _ property: String) -> String {
        guard let value = mpv_get_property_string(handle, property) else { return "" }
        defer { mpv_free(value) }
        return String(cString: value)
    }
}
#endif
