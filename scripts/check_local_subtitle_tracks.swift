import Foundation
import GenPlayerCore

extension SubtitleBrowserChecks {
    @MainActor static func checkLocalTracks() async throws {
        let original = [2]
        let playerMenu = [2, 3] // Original ASS plus a subtitle discovered/attached by VLC.
        expect(playerMenu.count != original.count, "Reproduces old count mismatch with one embedded track")
        expect(MacSubtitleBrowserLocalTracks.ordinal(for: 2, originalTrackIDs: original, containerCount: 1) == 0,
               "Original track remains readable when playback menu has an extra subtitle")
        expect(MacSubtitleBrowserLocalTracks.ordinal(for: 3, originalTrackIDs: original, containerCount: 1) == nil,
               "Extra subtitle is not mapped to the only embedded track")
        expect(MacSubtitleBrowserLocalTracks.ordinal(for: 7, originalTrackIDs: [2, 7], containerCount: 2) == 1,
               "Sparse native IDs map to subtitle ordinal")
        expect(MacSubtitleBrowserLocalTracks.ordinal(for: 2, originalTrackIDs: [2, 2], containerCount: 2) == nil,
               "Duplicate original IDs remain ambiguous")
        expect(MacSubtitleBrowserLocalTracks.ordinal(for: 2, originalTrackIDs: [2], containerCount: 2) == nil,
               "Different original and extractor track counts are rejected")
        expect(MacSubtitleBrowserLocalTracks.ordinal(for: -1, originalTrackIDs: [-1], containerCount: 1) == nil,
               "Disabled subtitles never map to a container track")
        do {
            _ = try await MacSubtitleBrowserLocalTracks.read(from: URL(string: "https://example.invalid/video.mkv")!)
            preconditionFailure("Local preparse must not fetch remote media")
        } catch SubtitleBrowserError.unreadable { expect(true, "Local preparse rejects remote input") }

        // Optional real-file regression: metadata/text only. No VLCMediaPlayer or UI is created.
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--local-media-file"), index + 1 < args.count,
           let selectedIndex = args.firstIndex(of: "--selected-subtitle-id"), selectedIndex + 1 < args.count,
           let selected = Int(args[selectedIndex + 1]) {
            let url = URL(fileURLWithPath: args[index + 1])
            let ids = try await MacSubtitleBrowserLocalTracks.read(from: url)
            let descriptors = try await MacSubtitleBrowserLocalTracks.readDescriptors(from: url)
            guard let ordinal = MacSubtitleBrowserLocalTracks.ordinal(for: selected, originalTrackIDs: ids, containerCount: descriptors.count)
            else { preconditionFailure("Original file cannot resolve selected subtitle") }
            let descriptor = descriptors[ordinal]
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let output = folder.appendingPathComponent("subtitle").appendingPathExtension(descriptor.codec ?? "srt")
            let extracted = try await SharedLocalEmbeddedSubtitleExtractor.extractSubtitle(from: url,
                trackIndex: descriptor.trackIndex, outputURL: output)
            let document = SubtitleBrowserDocument(parts: try SubtitleModel.loadParts(from: extracted, format: descriptor.codec ?? "srt"))
            expect(!document.entries.isEmpty, "Real selected primary subtitle produces a readable browser document")
            print("Real-file check: original subtitle IDs = \(ids), selected = \(selected), browser lines = \(document.entries.count)")
        }
    }
}
