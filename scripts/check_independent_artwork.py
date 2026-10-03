#!/usr/bin/env python3
"""Production artwork orchestration with IO/engine spies; no App, media, or network."""
from pathlib import Path
import subprocess, tempfile
repo = Path(__file__).resolve().parents[1]
shell = repo / "GenPlayerCore/Sources/GenPlayerShell"
with tempfile.TemporaryDirectory(prefix="GenPlayerArtworkBoundary-") as work:
    root = Path(work)
    core = root / "Core.swift"
    core.write_text(r'''import Foundation
public struct VideoFile {
 public enum FileType { case audio, video
  public static func determineType(from url: URL) -> Self { url.pathExtension == "mka" ? .audio : .video }
 }
}
public struct Server { public var id = UUID(); public var username: String? = "fixture"; public var passwordSecret: String? = "test-cookie"; public var accessToken: String? = nil }
public final class AppNetworkService { public static let shared = AppNetworkService(); public var savedServers = [Server()] }
public enum RuntimeNetworkAddressResolver { public static func runtimeURL(from url: URL) -> URL { url } }
public enum VODService { public static let defaultUserAgent = "vod-fixture" }
public enum Pan115Manager { public static let defaultUserAgent = "pan-fixture" }
public class SMBAudioRangeReader {
 public init(url: URL) {}
 public func metadata() async throws -> (size: UInt64, dummy: Bool) { (100, false) }
 public func read(offset: UInt64, count: Int) async throws -> Data { Data() }
}
public class FileAudioRangeReader: SMBAudioRangeReader {
 public init(url: URL, provider: String?, serverID: String?, path: String?, itemID: String?) { super.init(url: url) }
}
''')
    subprocess.run(["xcrun","swiftc","-emit-library","-emit-module","-module-name","GenPlayerCore",
        "-module-cache-path",str(root/"cache"),str(core),"-o",str(root/"libGenPlayerCore.dylib"),
        "-emit-module-path",str(root/"GenPlayerCore.swiftmodule")],check=True)
    fake = (repo/"scripts/check_mpv_preview.swift").read_text().split("@main enum")[0]
    fake = fake.replace("var cancelled = false", "var cancelled = false\n    public init(metadata: @escaping @Sendable () async throws -> UInt64, read: @escaping @Sendable (UInt64, Int) async throws -> Data) {}")
    fake += r'''
import GenPlayerCore
public enum EmbeddedAudioArtworkReader {
 static var reads = 0
 public static func read(_ url: URL) async throws -> Data? { reads += 1; try await Task.sleep(nanoseconds: 20_000_000); return nil }
}
public enum RemoteAudioArtworkReader {
 static var reads = 0
 public static func read(url: URL, provider: String?, serverID: String?, path: String?, itemID: String?) async throws -> Data? { reads += 1; try await Task.sleep(nanoseconds: 20_000_000); return nil }
}
#if canImport(VLCKitSPM) || canImport(VLCKit) || canImport(GenPlayerVLCBridge)
#error("VLC leaked into the artwork test")
#endif
@main enum Checks {
 @MainActor static func main() async throws {
  var count = 0
  func check(_ value: Bool, line: Int = #line) { precondition(value, "Failure at \(line)"); count += 1 }
  let generator = IndependentMediaThumbnailGenerator()
  var completions = 0
  let server = AppNetworkService.shared.savedServers[0]
  let video = URL(string: "https://example.invalid/movie.mkv")!
  generator.generateThumbnail(for: video, provider: "pan115", serverID: server.id.uuidString) { _ in completions += 1 }
  let first = MPVPlaybackEngine.instances.last!
  check(first.configuration.startPercentage == 5)
  check(first.configuration.options["aid"] == "no" && first.configuration.options["pause"] == "yes")
  check(first.configuration.options["http-header-fields"]?.contains("test-cookie") == true)
  generator.cancel(); first.error(-1)
  check(completions == 0 && first.stops == 1)
  generator.generateThumbnail(for: video, provider: "webdav", serverID: server.id.uuidString) { _ in completions += 1 }
  let second = MPVPlaybackEngine.instances.last!
  check(second.configuration.url.user == "fixture")
  check(second.configuration.url.password == "test-cookie")
  first.error(-1); check(completions == 0)
  second.error(-1); second.error(-1); check(completions == 1)
  let before = MPVPlaybackEngine.instances.count
  generator.generateThumbnail(for: URL(fileURLWithPath: "/not-opened/file.mka")) { _ in completions += 1 }
  try await Task.sleep(nanoseconds: 60_000_000)
  check(EmbeddedAudioArtworkReader.reads == 1 && MPVPlaybackEngine.instances.count == before && completions == 2)
  generator.generateThumbnail(for: video, isAudio: true) { _ in completions += 1 }
  try await Task.sleep(nanoseconds: 5_000_000)
  generator.cancel()
  try await Task.sleep(nanoseconds: 40_000_000)
  check(RemoteAudioArtworkReader.reads == 1 && MPVPlaybackEngine.instances.count == before && completions == 2)
  let awaiting = IndependentMediaThumbnailGenerator(completesOnCancel: true)
  awaiting.generateThumbnail(for: video) { _ in completions += 1 }
  awaiting.cancel(); awaiting.cancel()
  check(completions == 3)
  print("PASS: \(count) production independent artwork routing/authentication/cancellation checks")
 }
}
'''
    (root/"Checks.swift").write_text(fake)
    command = ["xcrun","swiftc","-parse-as-library","-module-cache-path",str(root/"cache"),
        "-I",str(root),"-L",str(root),"-lGenPlayerCore","-Xlinker","-rpath","-Xlinker",str(root)]
    for name in ["PlaybackEngineCapabilities.swift","PlaybackPreviewProvider.swift","PlaybackFrameDelivery.swift","MPVPixelBufferOutput.swift",
                 "MPVPlaybackPreviewProvider.swift","IndependentMediaThumbnailGenerator.swift"]:
        command.append(str(shell/name))
    command += [str(root/"Checks.swift"),"-o",str(root/"check")]
    subprocess.run(command,check=True)
    subprocess.run([str(root/"check")],check=True,timeout=20)
