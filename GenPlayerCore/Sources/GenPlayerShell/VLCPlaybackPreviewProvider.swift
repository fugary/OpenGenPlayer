import Foundation
import CoreGraphics
import VLCKitSPM

/// Source authentication/options are resolved by the owning platform before construction.
public final class VLCPlaybackPreviewProvider: NSObject, PlaybackPreviewProvider, VLCMediaThumbnailerDelegate {
    private let media: VLCMedia
    private let width: CGFloat
    private var thumbnailer: VLCMediaThumbnailer?
    private var completion: ((CGImage?) -> Void)?

    public init(media: VLCMedia, width: CGFloat) {
        self.media = media
        self.width = width
        super.init()
    }

    public func generate(snapshotPosition: Float, completion: @escaping (CGImage?) -> Void) {
        cancel()
        guard PlaybackEngineAvailability.current.vlc, snapshotPosition.isFinite, width.isFinite, width > 0 else {
            completion(nil)
            return
        }
        let request = VLCMediaThumbnailer(media: media, andDelegate: self)
        thumbnailer = request
        self.completion = completion
        request.thumbnailWidth = width
        request.snapshotPosition = min(max(snapshotPosition, 0), 0.999)
        request.fetchThumbnail()
    }

    public func cancel() {
        // Clear ownership before cancellation, which may deliver a synchronous native callback.
        let previous = thumbnailer
        thumbnailer = nil
        completion = nil
        let selector = NSSelectorFromString("cancelThumbnail")
        if let previous, previous.responds(to: selector) { _ = previous.perform(selector) }
    }

    public func mediaThumbnailerDidTimeOut(_ request: VLCMediaThumbnailer) {
        DispatchQueue.main.async { [weak self] in self?.finish(request, image: nil) }
    }

    public func mediaThumbnailer(_ request: VLCMediaThumbnailer, didFinishThumbnail image: CGImage) {
        DispatchQueue.main.async { [weak self] in self?.finish(request, image: image) }
    }

    private func finish(_ request: VLCMediaThumbnailer, image: CGImage?) {
        guard thumbnailer === request else { return }
        let callback = completion
        completion = nil
        thumbnailer = nil
        callback?(image)
    }
}
