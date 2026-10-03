#!/usr/bin/env python3
"""Production iOS artwork completion with controllable reader; no files, GUI or media."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'GenPlayer/Source/Services/VLCPlaybackService+Extensions.swift').read_text()
start = source.index('    private func completeNativeAudioMetadata(')
end = source.index('    /// Fallback: Use AVFoundation', start)
method = source[start:end].replace('private func', 'func', 1)
service = (root / 'GenPlayer/Source/Services/VLCPlaybackService.swift').read_text()
start = service.index('    internal var metadataArtworkTask:')
end = service.index('    internal private(set) var isPreparingPlayback', start)
properties = service[start:end]
start = source.index('    private struct ExtractedAudioMetadata')
end = source.index('    func applyMPVAudioMetadata', start)
metadata_struct = source[start:end]
start = source.index('    private func applyExtractedMetadata(')
end = source.index('    private func cacheArtworkIfNeeded', start)
apply_metadata = source[start:end]
swift = r'''
import Foundation
struct UIImage {
    init?(data: Data) { if data.isEmpty { return nil } }
}
enum Provider: String { case webdav }
struct Item {
    var artwork: UIImage?
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var author: String?
    var composer: String?
    var serverType: Provider? = .webdav
    var jellyfinServerId: String? = "server"
    var serverPath: String? = "/folder/track.flac"
    var jellyfinItemId: String? = "item"
}
struct State { var currentItem: Item? = Item() }
@MainActor enum EmbeddedAudioArtworkReader {
    struct Metadata: Sendable {
        let tags: [String: String]
        let artwork: Data?
        let isComplete: Bool
    }
    static var pending: [CheckedContinuation<Metadata?, Error>] = []
    static func readMetadata(_ url: URL) async throws -> Metadata? {
        try await withCheckedThrowingContinuation { pending.append($0) }
    }
}
@MainActor enum RemoteAudioArtworkReader {
    static var arguments: [String?] = []
    static func readMetadata(url: URL, provider: String?, serverID: String?, path: String?, itemID: String?) async throws -> EmbeddedAudioArtworkReader.Metadata? {
        arguments = [url.absoluteString, provider, serverID, path, itemID]
        return try await EmbeddedAudioArtworkReader.readMetadata(url)
    }
}
final class Service {
__PROPERTIES__
__METADATA_STRUCT__
__APPLY_METADATA__
    func hasMeaningfulMetadataText(_ text: String?) -> Bool { !(text?.isEmpty ?? true) }
    var state = State()
    var writes = 0
    var updates = 0
    func nextAttempt() { playbackAttemptID = UUID() }
    func isMetadataTargetCurrent(targetURL: URL) -> Bool { true }
    func cacheArtworkIfNeeded(_ image: UIImage, targetURL: URL) { writes += 1 }
    func updateNowPlayingInfo() { updates += 1 }
__METHOD__
}
@main struct Check {
    @MainActor static func main() async throws {
        let url = URL(fileURLWithPath: "/test.flac")
        let bytes = Data([1])
        let metadata = EmbeddedAudioArtworkReader.Metadata(tags: ["title": "Title", "artist": "Artist", "album": "Album", "albumArtist": "Album Artist", "composer": "Composer", "author": "Author"], artwork: bytes, isComplete: true)
        func drain() async throws { try await Task.sleep(nanoseconds: 50_000_000) }
        var completions = 0
        let existing = Service()
        existing.state.currentItem?.artwork = UIImage(data: bytes)
        existing.state.currentItem?.artist = "Artist"
        existing.state.currentItem?.album = "Album"
        existing.completeNativeAudioMetadata(targetURL: url, attempt: existing.playbackAttemptID) { _ in completions += 1 }
        precondition(completions == 1 && EmbeddedAudioArtworkReader.pending.isEmpty)
        let valid = Service()
        valid.completeNativeAudioMetadata(targetURL: url, attempt: valid.playbackAttemptID) { _ in completions += 1 }
        try await drain()
        precondition(completions == 1)
        EmbeddedAudioArtworkReader.pending.removeFirst().resume(returning: metadata)
        try await drain()
        precondition(valid.writes == 1 && valid.updates == 1 && completions == 2)
        precondition(valid.metadataArtworkTask == nil && valid.state.currentItem?.artwork != nil)
        precondition(valid.state.currentItem?.artist == "Artist" && valid.state.currentItem?.albumArtist == "Album Artist")
        precondition(valid.state.currentItem?.author == "Author" && valid.state.currentItem?.composer == "Composer")
        let stale = Service()
        stale.completeNativeAudioMetadata(targetURL: url, attempt: stale.playbackAttemptID) { _ in completions += 1 }
        try await drain()
        stale.nextAttempt()
        precondition(stale.metadataArtworkTask == nil)
        EmbeddedAudioArtworkReader.pending.removeFirst().resume(returning: metadata)
        try await drain()
        precondition(stale.writes == 0 && stale.state.currentItem?.artwork == nil && completions == 2)
        for data: Data? in [nil, Data()] {
            let missing = Service()
            missing.completeNativeAudioMetadata(targetURL: url, attempt: missing.playbackAttemptID) { _ in completions += 1 }
            try await drain()
            EmbeddedAudioArtworkReader.pending.removeFirst().resume(returning: data.map { .init(tags: [:], artwork: $0, isComplete: true) })
            try await drain()
            precondition(missing.writes == 0 && missing.state.currentItem?.artwork == nil)
        }
        precondition(completions == 4)
        let replaced = Service()
        replaced.completeNativeAudioMetadata(targetURL: url, attempt: replaced.playbackAttemptID) { _ in completions += 1 }
        try await drain()
        replaced.completeNativeAudioMetadata(targetURL: url, attempt: replaced.playbackAttemptID) { _ in completions += 1 }
        try await drain()
        EmbeddedAudioArtworkReader.pending.removeFirst().resume(returning: metadata)
        try await drain()
        precondition(replaced.writes == 0 && completions == 4)
        EmbeddedAudioArtworkReader.pending.removeFirst().resume(returning: metadata)
        try await drain()
        precondition(replaced.writes == 1 && completions == 5)
        let remote = Service()
        let remoteURL = URL(string: "https://example.invalid/track")!
        remote.completeNativeAudioMetadata(targetURL: remoteURL, attempt: remote.playbackAttemptID) { _ in completions += 1 }
        try await drain()
        precondition(RemoteAudioArtworkReader.arguments == [remoteURL.absoluteString, "webdav", "server", "/folder/track.flac", "item"])
        EmbeddedAudioArtworkReader.pending.removeFirst().resume(returning: metadata)
        try await drain()
        precondition(remote.writes == 1 && completions == 6)
        for (result, expected) in [
            (EmbeddedAudioArtworkReader.Metadata(tags: [:], artwork: nil, isComplete: true), true),
            (.init(tags: [:], artwork: nil, isComplete: false), false),
            (.init(tags: [:], artwork: Data(), isComplete: true), false)
        ] {
            let sample = Service()
            var complete: Bool?
            sample.completeNativeAudioMetadata(targetURL: url, attempt: sample.playbackAttemptID) { complete = $0 }
            try await drain()
            EmbeddedAudioArtworkReader.pending.removeFirst().resume(returning: result)
            try await drain()
            precondition(complete == expected, "Parsed absence, incomplete IO and unreadable artwork must differ")
        }
        let tagsOnly = Service()
        tagsOnly.state.currentItem?.artwork = UIImage(data: bytes)
        tagsOnly.completeNativeAudioMetadata(targetURL: url, attempt: tagsOnly.playbackAttemptID) { precondition($0) }
        try await drain()
        EmbeddedAudioArtworkReader.pending.removeFirst().resume(returning: metadata)
        try await drain()
        precondition(tagsOnly.state.currentItem?.albumArtist == "Album Artist" && tagsOnly.writes == 0)
        print("PASS: production metadata/cover completion: existing/missing/invalid, session cancellation, replaced task and remote source identity")
    }
}
'''.replace('__PROPERTIES__', properties).replace('__METHOD__', method).replace('__METADATA_STRUCT__', metadata_struct).replace('__APPLY_METADATA__', apply_metadata)
with tempfile.TemporaryDirectory(prefix='GenPlayerArtworkCompletion-') as folder:
    tmp = Path(folder)
    (tmp / 'check.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(tmp / 'cache'), str(tmp / 'check.swift'), '-o', str(tmp / 'check')], check=True)
    subprocess.run([str(tmp / 'check')], check=True)
