#if os(macOS)
import Foundation
import GenPlayerCore
import VLCKit

/// Inspect the original file without creating a player or loading its sidecar/slave subtitles.
/// A playing VLCMediaPlayer's menu can contain more subtitles than the original container.
enum MacSubtitleBrowserLocalTracks {
    static func readDescriptors(from url: URL) async throws -> [SharedLocalEmbeddedSubtitleDescriptor] {
        guard url.isFileURL else { throw SubtitleBrowserError.unreadable }
        try Task.checkCancellation()
        let task = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let descriptors = SharedLocalEmbeddedSubtitleExtractor.descriptors(for: url)
            try Task.checkCancellation()
            return descriptors
        }
        return try await withTaskCancellationHandler {
            let descriptors = try await task.value
            try Task.checkCancellation()
            return descriptors
        } onCancel: {
            task.cancel()
        }
    }

    @MainActor static func read(from url: URL) async throws -> [Int] {
        guard PlaybackEngineAvailability.current.vlc else { throw SubtitleBrowserError.unreadable }
        guard url.isFileURL else { throw SubtitleBrowserError.unreadable }
        try Task.checkCancellation()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let media = VLCMedia(url: url)
        media.addOptions(["sub-autodetect-file": false])
        guard media.parse(options: [], timeout: 5000) == 0 else { throw SubtitleBrowserError.unreadable }
        defer { media.parseStop() }
        // Parsing is asynchronous. Polling is cancellable and does not block the main thread.
        for _ in 0..<110 {
            try Task.checkCancellation()
            switch media.parsedStatus {
            case .done:
                return (media.tracksInformation as? [[String: Any]] ?? []).compactMap { track in
                    guard track[VLCMediaTracksInformationType] as? String == VLCMediaTracksInformationTypeText else { return nil }
                    return (track[VLCMediaTracksInformationId] as? NSNumber)?.intValue
                }
            case .failed, .skipped, .timeout: throw SubtitleBrowserError.unreadable
            default: try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        throw SubtitleBrowserError.unreadable
    }

    static func ordinal(for selectedID: Int, originalTrackIDs: [Int], containerCount: Int) -> Int? {
        guard selectedID != -1, originalTrackIDs.count == containerCount,
              Set(originalTrackIDs).count == originalTrackIDs.count else { return nil }
        return originalTrackIDs.firstIndex(of: selectedID)
    }
}
#endif
