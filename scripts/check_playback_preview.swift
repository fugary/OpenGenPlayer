import Foundation
import CoreGraphics
import VLCKitSPM

private final class PreviewSpy: PlaybackPreviewProvider {
    var callback: ((CGImage?) -> Void)?
    var calls = 0
    var cancels = 0
    func generate(snapshotPosition: Float, completion: @escaping (CGImage?) -> Void) {
        calls += 1; callback = completion
    }
    func cancel() { cancels += 1 }
}

@main enum PreviewChecks {
    @MainActor static func main() async throws {
        var count = 0
        func check(_ condition: Bool, line: Int = #line) {
            precondition(condition, "Preview check failed at \(line)"); count += 1
        }
        func drain() async { try? await Task.sleep(nanoseconds: 10_000_000) }
        let image = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let provider: any PlaybackPreviewProvider = VLCPlaybackPreviewProvider(media: makePreviewTestMedia(), width: 480)
        var firstResults = 0
        var secondResults = 0
        provider.generate(snapshotPosition: -1) { _ in firstResults += 1 }
        let first = VLCMediaThumbnailer.requests.last!
        check(first.thumbnailWidth == 480 && first.snapshotPosition == 0)
        provider.generate(snapshotPosition: 2) { frame in
            check(frame != nil)
            secondResults += 1
        }
        let second = VLCMediaThumbnailer.requests.last!
        check(first.cancelled && second.snapshotPosition == 0.999)
        first.delegate?.mediaThumbnailer(first, didFinishThumbnail: image)
        await drain()
        check(firstResults == 0 && secondResults == 0)
        second.delegate?.mediaThumbnailer(second, didFinishThumbnail: image)
        second.delegate?.mediaThumbnailerDidTimeOut(second)
        await drain()
        check(secondResults == 1)
        var canceledResults = 0
        provider.generate(snapshotPosition: 0.2) { _ in canceledResults += 1 }
        let canceled = VLCMediaThumbnailer.requests.last!
        provider.cancel()
        canceled.delegate?.mediaThumbnailer(canceled, didFinishThumbnail: image)
        await drain()
        check(canceled.cancelled && canceledResults == 0)
        var invalidResults = 0
        let beforeInvalid = VLCMediaThumbnailer.requests.count
        provider.generate(snapshotPosition: .nan) { frame in
            check(frame == nil); invalidResults += 1
        }
        check(invalidResults == 1 && VLCMediaThumbnailer.requests.count == beforeInvalid)
        var timeoutResults = 0
        provider.generate(snapshotPosition: 0.3) { frame in
            check(frame == nil); timeoutResults += 1
        }
        let timeout = VLCMediaThumbnailer.requests.last!
        timeout.delegate?.mediaThumbnailerDidTimeOut(timeout)
        timeout.delegate?.mediaThumbnailerDidTimeOut(timeout)
        await drain()
        check(timeoutResults == 1)
        var reentrantResults = 0
        provider.generate(snapshotPosition: 0.4) { _ in
            provider.generate(snapshotPosition: 0.5) { _ in reentrantResults += 1 }
        }
        let reentrant = VLCMediaThumbnailer.requests.last!
        reentrant.delegate?.mediaThumbnailer(reentrant, didFinishThumbnail: image)
        await drain()
        let followup = VLCMediaThumbnailer.requests.last!
        check(followup !== reentrant)
        reentrant.delegate?.mediaThumbnailerDidTimeOut(reentrant)
        followup.delegate?.mediaThumbnailer(followup, didFinishThumbnail: image)
        await drain()
        check(reentrantResults == 1)
        let primarySpy = PreviewSpy(), backup = PreviewSpy()
        var fallbackCreations = 0
        let chain = FallbackPlaybackPreviewProvider(primary: { primarySpy }, fallback: {
            fallbackCreations += 1; return backup
        })
        var delivered = 0
        chain.generate(snapshotPosition: 0.3) { _ in delivered += 1 }
        primarySpy.callback?(image)
        check(delivered == 1 && fallbackCreations == 0)
        primarySpy.callback?(nil)
        check(delivered == 1 && fallbackCreations == 0)
        chain.generate(snapshotPosition: 0.4) { _ in delivered += 1 }
        let oldFirst = primarySpy.callback
        primarySpy.callback?(nil)
        check(fallbackCreations == 1 && backup.calls == 1)
        oldFirst?(image)
        check(delivered == 1)
        backup.callback?(image)
        check(delivered == 2)
        chain.generate(snapshotPosition: 0.5) { _ in delivered += 1 }
        let canceledFirst = primarySpy.callback
        chain.cancel()
        canceledFirst?(nil)
        check(delivered == 2 && fallbackCreations == 1)
        chain.generate(snapshotPosition: 0.6) { _ in delivered += 1 }
        primarySpy.callback?(nil)
        let canceledBackup = backup.callback
        chain.cancel()
        canceledBackup?(image)
        check(delivered == 2 && fallbackCreations == 2)
        chain.generate(snapshotPosition: 0.7) { _ in
            delivered += 1
            chain.generate(snapshotPosition: 0.8) { _ in delivered += 1 }
        }
        primarySpy.callback?(image)
        primarySpy.callback?(image)
        check(delivered == 4)
        let empty = FallbackPlaybackPreviewProvider(primary: { nil }, fallback: { nil })
        empty.generate(snapshotPosition: 0.1) { frame in check(frame == nil); delivered += 1 }
        check(delivered == 5)
        let media = makePreviewTestMedia()
        let metadata: any PlaybackMetadataProvider = VLCPlaybackMetadataProvider(media: media)
        check(media.parseCount == 0)
        metadata.beginParsing()
        check(media.parseCount == 1 && metadata.metadata.artist == nil)
        media.metaData.artist = "Artist"
        media.metaData.album = "Album"
        let early = metadata.metadata
        media.metaData.artist = "Updated"
        check(early.artist == "Artist" && metadata.metadata.artist == "Updated")
        check(metadata.metadata.album == "Album" && media.parseCount == 1)
        print("PASS: \(count) production preview/metadata provider checks with fake native providers")
    }
}
