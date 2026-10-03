import Foundation
import CoreGraphics
import CoreVideo

// Replace only the native decode engine. Exercise the production provider,
// frame channel, image conversion and cancellation without opening media.
public final class MacMPVStream {
    var cancelled = false
}
public final class MPVPlaybackEngine {
    public struct Configuration {
        public let url: URL
        public let start: Double
        public var startPercentage: Double? = nil
        public let options: [String: String]
        public let subtitles: [URL]
        public var audioOnly: Bool
        public var stream: MacMPVStream?
        public var pixelBufferOutput: MPVPixelBufferOutput?
        public init(url: URL, start: Double, options: [String: String], subtitles: [URL],
                    audioOnly: Bool = false, stream: MacMPVStream? = nil) {
            self.url = url; self.start = start; self.options = options; self.subtitles = subtitles
            self.audioOnly = audioOnly; self.stream = stream
        }
    }
    static var instances: [MPVPlaybackEngine] = []
    let configuration: Configuration
    let error: (Int) -> Void
    var starts = 0
    var stops = 0
    init(configuration: Configuration, onState: @escaping (Int) -> Void, onError: @escaping (Int) -> Void) {
        self.configuration = configuration; error = onError
        Self.instances.append(self)
    }
    func startPixelBufferOutput() { starts += 1 }
    func stop() { stops += 1; configuration.stream?.cancelled = true }
}

@main enum MPVPreviewChecks {
    @MainActor static func main() async {
        var count = 0
        func check(_ value: Bool, line: Int = #line) { precondition(value, "MPV preview check failed at \(line)"); count += 1 }
        let source = URL(fileURLWithPath: "/not-opened/preview.mp4")
        var streams: [MacMPVStream] = []
        let provider = MPVPlaybackPreviewProvider(duration: 100, sourceSize: CGSize(width: 1920, height: 1080), maximumDimension: 540) { time in
            let stream = MacMPVStream(); streams.append(stream)
            return .init(url: source, start: time,
                options: ["pause": "no", "aid": "2", "sid": "3", "speed": "2", "http-header-fields": "test-auth"],
                subtitles: [URL(fileURLWithPath: "/not-opened/sub.srt")], stream: stream)
        }
        if !PlaybackEngineAvailability.current.mpv {
            var completions = 0
            provider.generate(snapshotPosition: 0.25) { image in check(image == nil); completions += 1 }
            provider.cancel()
            check(completions == 1 && streams.isEmpty && MPVPlaybackEngine.instances.isEmpty)
            print("Passed disabled mpv preview checks: no source or engine created")
            return
        }
        var frames = 0
        provider.generate(snapshotPosition: 0.25) { image in
            check(image?.width == 540); frames += 1
        }
        let first = MPVPlaybackEngine.instances.last!
        check(first.starts == 1 && first.configuration.start == 25)
        check(first.configuration.url == source && first.configuration.subtitles.isEmpty)
        check(first.configuration.options["aid"] == "no" && first.configuration.options["sid"] == "no")
        check(first.configuration.options["pause"] == "yes" && first.configuration.options["speed"] == "1")
        check(first.configuration.options["http-header-fields"] == "test-auth")
        let pool = MPVPixelBufferPool(maximumDimension: 540)
        check(pool.configure(sourceSize: CGSize(width: 1920, height: 1080)))
        first.configuration.pixelBufferOutput?.submit(pool.acquire()!)
        for _ in 0..<100 where frames == 0 { try? await Task.sleep(nanoseconds: 10_000_000) }
        check(frames == 1 && first.stops == 1 && streams[0].cancelled)
        first.error(-1)
        check(frames == 1)
        provider.generate(snapshotPosition: 0.5) { _ in frames += 1 }
        let canceled = MPVPlaybackEngine.instances.last!
        provider.cancel()
        canceled.error(-1)
        canceled.configuration.pixelBufferOutput?.submit(pool.acquire()!)
        try? await Task.sleep(nanoseconds: 20_000_000)
        check(frames == 1 && canceled.stops == 1 && streams[1].cancelled)
        provider.generate(snapshotPosition: 0.75) { image in check(image == nil); frames += 1 }
        let failed = MPVPlaybackEngine.instances.last!
        failed.error(-1); failed.error(-1)
        check(frames == 2 && failed.stops == 1)
        let artwork = MPVPlaybackPreviewProvider(duration: 1, sourceSize: .zero) { _ in
            var config = MPVPlaybackEngine.Configuration(url: source, start: 0, options: [:], subtitles: [])
            config.startPercentage = 5
            return config
        }
        artwork.generate(snapshotPosition: 0) { _ in }
        check(MPVPlaybackEngine.instances.last?.configuration.startPercentage == 5)
        artwork.cancel()
        let before = MPVPlaybackEngine.instances.count
        provider.generate(snapshotPosition: .nan) { image in check(image == nil); frames += 1 }
        check(MPVPlaybackEngine.instances.count == before && frames == 3)
        provider.generate(snapshotPosition: 0.1) { image in check(image == nil); frames += 1 }
        let timedOut = MPVPlaybackEngine.instances.last!
        try? await Task.sleep(nanoseconds: 6_200_000_000)
        check(frames == 4 && timedOut.stops == 1 && streams.last!.cancelled)
        print("PASS: \(count) production mpv preview lifecycle/image checks with a fake decode engine")
    }
}
