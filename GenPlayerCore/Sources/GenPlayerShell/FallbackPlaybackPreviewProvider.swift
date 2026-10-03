import Foundation
import CoreGraphics

/// Main-queue coordinator. Failure falls back once; cancellation never starts a fallback.
public final class FallbackPlaybackPreviewProvider: PlaybackPreviewProvider {
    private let primary: () -> (any PlaybackPreviewProvider)?
    private let fallback: () -> (any PlaybackPreviewProvider)?
    private var active: (any PlaybackPreviewProvider)?
    private var request = UUID()
    private var completion: ((CGImage?) -> Void)?

    public init(primary: @escaping () -> (any PlaybackPreviewProvider)?,
                fallback: @escaping () -> (any PlaybackPreviewProvider)?) {
        self.primary = primary; self.fallback = fallback
    }

    public func generate(snapshotPosition: Float, completion: @escaping (CGImage?) -> Void) {
        cancel()
        self.completion = completion
        run(primary(), position: snapshotPosition, token: request, mayFallback: true)
    }

    public func cancel() {
        request = UUID()
        completion = nil
        let previous = active
        active = nil
        previous?.cancel()
    }

    private func run(_ provider: (any PlaybackPreviewProvider)?, position: Float, token: UUID, mayFallback: Bool) {
        guard request == token else { return }
        guard let provider else {
            if mayFallback { run(fallback(), position: position, token: token, mayFallback: false) }
            else { finish(nil, token: token) }
            return
        }
        active = provider
        provider.generate(snapshotPosition: position) { [weak self, weak provider] image in
            guard let self, let provider, self.request == token, self.active === provider else { return }
            self.active = nil
            provider.cancel()
            if image == nil && mayFallback {
                self.run(self.fallback(), position: position, token: token, mayFallback: false)
            } else { self.finish(image, token: token) }
        }
    }

    private func finish(_ image: CGImage?, token: UUID) {
        guard request == token, let callback = completion else { return }
        cancel()
        callback(image)
    }

    deinit { cancel() }
}
