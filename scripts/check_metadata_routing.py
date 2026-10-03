#!/usr/bin/env python3
"""Exercise production iOS metadata routing with parser/state doubles, no App or media."""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'GenPlayer/Source/Services/VLCPlaybackService+Extensions.swift').read_text()
start = source.index('    func extractMetadata() {')
end = source.index('    /// Helper to read VLC metadata', start)
routing = source[start:end]
harness = r'''
import Foundation
enum Provider: String { case webdav, jellyfin }
enum RemoteAudioArtworkReader { static func supports(url: URL, provider: String?) -> Bool { provider == "webdav" } }
struct Item { var serverType: Provider?; var url: URL; var artwork: Int?; var artist: String?; var album: String? }
struct State { var currentItem: Item? }
enum Kind { case audio, video }
final class VLCMedia { init(url: URL) {} }
final class Player { var media: VLCMedia? }
enum RuntimeNetworkAddressResolver { static func runtimeURL(from url: URL) -> URL { url } }
protocol PlaybackMetadataProvider { func beginParsing() }
final class VLCPlaybackMetadataProvider: PlaybackMetadataProvider {
    static var count = 0
    init(media: VLCMedia) {}
    func beginParsing() { Self.count += 1 }
}
final class Service {
    var state = State(currentItem: Item(url: URL(fileURLWithPath: "/fixture.m4a")))
    var mediaPlayer = Player()
    var playbackAttemptID = UUID()
    var metadataReadID = UUID()
    var metadataArtworkTask: Task<Void, Never>?
    var playbackCapabilities: PlaybackEngineCapabilities { .init(platform: .iOS, engine: isUsingMPV || isPreparingMPV ? .mpv : .vlc) }
    var isPreparingMPV = false
    var isUsingMPV = true
    var kind = Kind.audio
    var nativeReads = 0
    var nativeCompletion: (() -> Void)?
    var independentReads = 0
    var independentComplete = false
    func completeNativeAudioMetadata(targetURL: URL, attempt: UUID, completion: @escaping (Bool) -> Void) {
        guard playbackAttemptID == attempt, isMetadataTargetCurrent(targetURL: targetURL) else { return }
        independentReads += 1
        if targetURL.isFileURL { completion(independentComplete) }
        else { nativeCompletion = { completion(self.independentComplete) } }
    }
    func resolvedPlaybackItemType(for item: Item) -> Kind { kind }
    func hasMeaningfulMetadataText(_ text: String?) -> Bool { !(text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
    func isMetadataTargetCurrent(targetURL: URL) -> Bool { state.currentItem?.url == targetURL }
    func configureMediaOptions(_ media: VLCMedia, for item: Item) {}
    func checkPlaybackMetadata(provider: any PlaybackMetadataProvider, targetURL: URL, attempt: UUID) {}
    func extractMetadataViaAVFoundation(targetURL: URL, attempt: UUID, completion: (() -> Void)? = nil) {
        DispatchQueue.main.async { self.nativeReads += 1; self.nativeCompletion = completion }
    }
__ROUTING__
}
@main struct Check {
    @MainActor static func main() async throws {
        func check(_ value: Bool, _ message: String) { precondition(value, message) }
        func drain() async throws { try await Task.sleep(nanoseconds: 100_000_000) }
        let complete = Service()
        complete.extractMetadata()
        check(VLCPlaybackMetadataProvider.count == 0, "native first does not construct VLC parser")
        try await drain()
        check(complete.nativeReads == 1, "native read dispatched")
        complete.state.currentItem?.artwork = 1
        complete.state.currentItem?.artist = "Artist"
        complete.state.currentItem?.album = "Album"
        complete.nativeCompletion?()
        check(VLCPlaybackMetadataProvider.count == 0, "complete native metadata avoids VLC")
        let missing = Service()
        missing.extractMetadata()
        try await drain()
        missing.nativeCompletion?()
        missing.nativeCompletion?()
        check(VLCPlaybackMetadataProvider.count == 0, "incomplete independent result never constructs VLC")
        let stale = Service()
        stale.extractMetadata()
        try await drain()
        stale.playbackAttemptID = UUID() // Same URL reopened in a different session.
        stale.nativeCompletion?()
        check(VLCPlaybackMetadataProvider.count == 0, "old native completion cannot start parser for new session")
        let stalled = Service()
        stalled.extractMetadata()
        try await Task.sleep(nanoseconds: 2_100_000_000)
        check(VLCPlaybackMetadataProvider.count == 0, "slow AVFoundation starts independent reading without VLC")
        stalled.nativeCompletion?()
        check(VLCPlaybackMetadataProvider.count == 0, "late native completion cannot duplicate fallback")
        let remote = Service()
        remote.state.currentItem?.url = URL(string: "https://example.invalid/audio")!
        remote.extractMetadata()
        check(VLCPlaybackMetadataProvider.count == 0, "unsupported mpv source retains native tags without VLC")
        let preparing = Service()
        preparing.isUsingMPV = false
        preparing.isPreparingMPV = true
        preparing.mediaPlayer.media = VLCMedia(url: preparing.state.currentItem!.url)
        preparing.extractMetadata()
        try await drain()
        preparing.nativeCompletion?()
        check(VLCPlaybackMetadataProvider.count == 0, "preparing mpv never parses a retained VLC media object")
        let vlc = Service()
        vlc.isUsingMPV = false
        vlc.mediaPlayer.media = VLCMedia(url: vlc.state.currentItem!.url)
        vlc.extractMetadata()
        check(VLCPlaybackMetadataProvider.count == 1, "VLC playback retains immediate parsing")
        let webdav = Service()
        webdav.state.currentItem?.url = URL(string: "https://example.invalid/track.flac")!
        webdav.state.currentItem?.serverType = .webdav
        webdav.extractMetadata()
        check(webdav.independentReads == 1 && VLCPlaybackMetadataProvider.count == 1, "supported remote starts independent reader")
        try await drain()
        check(webdav.nativeReads == 0, "remote does not start local AVFoundation parser")
        webdav.state.currentItem?.artist = "Artist"
        webdav.state.currentItem?.album = "Album"
        webdav.state.currentItem?.artwork = 1
        webdav.nativeCompletion?()
        check(VLCPlaybackMetadataProvider.count == 1, "remote complete metadata avoids VLC")
        let absent = Service()
        absent.independentComplete = true
        absent.extractMetadata()
        try await drain()
        absent.nativeCompletion?()
        check(absent.independentReads == 1 && VLCPlaybackMetadataProvider.count == 1,
              "a complete file without tags or artwork does not construct a VLC parser")
        let delayedNative = Service()
        delayedNative.independentComplete = true
        delayedNative.extractMetadata()
        try await Task.sleep(nanoseconds: 2_100_000_000)
        check(delayedNative.independentReads == 1 && VLCPlaybackMetadataProvider.count == 1,
              "AVFoundation timeout triggers bounded independent reading, not VLC")
        delayedNative.nativeCompletion?()
        check(delayedNative.independentReads == 1, "late AVFoundation callback does not repeat reading")
        let superseded = Service()
        superseded.extractMetadata()
        try await drain()
        let oldCompletion = superseded.nativeCompletion
        superseded.extractMetadata()
        try await drain()
        oldCompletion?()
        check(superseded.independentReads == 0, "replaced metadata request cannot begin old file reading")
        superseded.independentComplete = true
        superseded.nativeCompletion?()
        check(superseded.independentReads == 1 && VLCPlaybackMetadataProvider.count == 1, "latest request alone can complete")
        print("PASS: 18 production metadata routing checks (parser doubles; no media or GUI)")
    }
}
'''.replace('__ROUTING__', routing)
with tempfile.TemporaryDirectory(prefix='genplayer-metadata-routing-') as folder:
    path = pathlib.Path(folder)
    (path / 'check.swift').write_text(harness)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(path / 'cache'), str(root / 'GenPlayerCore/Sources/GenPlayerShell/PlaybackEngineCapabilities.swift'), str(path / 'check.swift'), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
