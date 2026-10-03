#if os(macOS)
import Foundation
import AppKit
import GenPlayerCore

class MacSeekPreviewThumbnailGenerator: ObservableObject {
    @Published var previewImage: NSImage? = nil
    @Published var isLoading: Bool = false

    private var activeTask: Task<Void, Never>?
    private var activeMPVProvider: MPVPlaybackPreviewProvider?
    private var requestID = UUID()
    private let mpvFrameCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 48
        return cache
    }()

    func generateThumbnail(
        for file: VideoFile,
        at time: Double,
        duration: Double,
        mpvFallback: (() -> MPVPlaybackPreviewProvider?)? = nil
    ) {
        cancelActiveTask()
        let requestID = self.requestID
        let frameCacheKey = mpvFrameCacheKey(for: file, time: time)
        let cachedMPVFrame = mpvFrameCache.object(forKey: frameCacheKey as NSString)
        previewImage = cachedMPVFrame
        isLoading = cachedMPVFrame == nil

        activeTask = Task { [weak self] in
            // Debounce thumbnail requests to avoid saturation during scrubbing/clicking
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }

            if let image = await MacRemoteSeekPreviewService.shared.previewImage(for: file, targetTime: time, duration: duration) {
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.finish(image, requestID: requestID)
                }
                return
            }

            guard !Task.isCancelled else { return }
            guard let mpvFallback else {
                await MainActor.run { [weak self] in self?.finish(cachedMPVFrame, requestID: requestID) }
                return
            }
            guard let self else { return }

            if let cachedImage = self.mpvFrameCache.object(forKey: frameCacheKey as NSString) {
                await MainActor.run { [weak self] in self?.finish(cachedImage, requestID: requestID) }
                return
            }

            let provider = await MainActor.run { mpvFallback() }
            guard !Task.isCancelled, let provider else {
                await MainActor.run { [weak self] in self?.finish(nil, requestID: requestID) }
                return
            }
            let providerInstalled = await MainActor.run { [weak self] in
                guard let self, self.requestID == requestID else { return false }
                self.activeMPVProvider = provider
                return true
            }
            guard providerInstalled, !Task.isCancelled else {
                provider.cancel()
                return
            }
            let snapshotPosition = Float(min(max(time / max(duration, 1), 0), 0.999))
            provider.generate(snapshotPosition: snapshotPosition) { [weak self, weak provider] image in
                let result = image.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) }
                Task { @MainActor [weak self, weak provider] in
                    guard let self, self.requestID == requestID else { return }
                    if self.activeMPVProvider === provider { self.activeMPVProvider = nil }
                    if let result { self.mpvFrameCache.setObject(result, forKey: frameCacheKey as NSString) }
                    self.finish(result, requestID: requestID)
                }
            }
        }
    }

    func cancel() {
        cancelActiveTask()
        previewImage = nil
        isLoading = false
    }

    private func cancelActiveTask() {
        requestID = UUID()
        activeTask?.cancel()
        activeTask = nil
        activeMPVProvider?.cancel()
        activeMPVProvider = nil
    }

    private func finish(_ image: NSImage?, requestID: UUID) {
        guard self.requestID == requestID else { return }
        previewImage = image
        isLoading = false
        activeTask = nil
    }

    private func mpvFrameCacheKey(for file: VideoFile, time: Double) -> String {
        let sourceHash = String(file.url.absoluteString.hashValue, radix: 16)
        // macOS playback time is milliseconds; normalize to half-second buckets.
        let halfSecondBucket = Int(floor(max(time, 0) / 500))
        return "mpv-frame|\(file.id)|\(sourceHash)|\(halfSecondBucket)"
    }
}
#endif
