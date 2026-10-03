#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import CoreGraphics
import CoreImage

/// Independent, silent decode session. Never seeks the user's playback engine.
/// The caller supplies a fresh authenticated stream for each request.
public final class MPVPlaybackPreviewProvider: PlaybackPreviewProvider {
    private let duration: Double
    private let sourceSize: CGSize
    private let maximumDimension: Int
    private let configuration: (Double) -> MPVPlaybackEngine.Configuration?
    private let renderQueue = DispatchQueue(label: "com.genplayer.mpv.preview-image", qos: .userInitiated)
    private var engine: MPVPlaybackEngine?
    private var output: MPVPixelBufferOutput?
    private var timeout: DispatchWorkItem?
    private var request = UUID()
    private var completion: ((CGImage?) -> Void)?

    public init(duration: Double, sourceSize: CGSize, maximumDimension: Int = 480,
                configuration: @escaping (Double) -> MPVPlaybackEngine.Configuration?) {
        self.duration = duration
        self.sourceSize = sourceSize
        self.maximumDimension = maximumDimension
        self.configuration = configuration
    }

    public func generate(snapshotPosition: Float, completion: @escaping (CGImage?) -> Void) {
        cancel()
        guard PlaybackEngineAvailability.current.mpv, snapshotPosition.isFinite, duration.isFinite, duration > 0,
              let source = configuration(Double(min(max(snapshotPosition, 0), 0.999)) * duration) else {
            completion(nil)
            return
        }
        let token = request
        self.completion = completion
        // Do not decode audio, discover subtitles, or emit sound for an auxiliary frame.
        let options = source.options.merging(["pause": "yes", "aid": "no", "mute": "yes",
                              "sid": "no", "secondary-sid": "no", "sub-auto": "no",
                              "vid": "auto", "speed": "1"]) { _, preview in preview }
        var config = MPVPlaybackEngine.Configuration(url: source.url, start: source.start,
            options: options, subtitles: [], stream: source.stream)
        config.startPercentage = source.startPercentage
        let channel = MPVPixelBufferOutput(sourceSize: sourceSize, maximumDimension: maximumDimension, queue: renderQueue) { [weak self] buffer in
            let frame = CIImage(cvPixelBuffer: buffer)
            let image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(frame, from: frame.extent)
            DispatchQueue.main.async { [weak self] in self?.finish(image, token: token) }
        }
        output = channel
        config.pixelBufferOutput = channel
        engine = MPVPlaybackEngine(configuration: config, onState: { _ in }, onError: { [weak self] _ in
            self?.finish(nil, token: token)
        })
        let deadline = DispatchWorkItem { [weak self] in self?.finish(nil, token: token) }
        timeout = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: deadline)
        engine?.startPixelBufferOutput()
    }

    public func cancel() {
        request = UUID()
        completion = nil
        timeout?.cancel(); timeout = nil
        output?.invalidate(); output = nil
        engine?.stop(); engine = nil
    }

    private func finish(_ image: CGImage?, token: UUID) {
        guard request == token, let callback = completion else { return }
        cancel()
        callback(image)
    }

    deinit { cancel() }
}
#endif
