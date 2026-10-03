#if os(iOS) || os(macOS) || os(tvOS)
import Foundation
import CoreVideo

/// One continuous frame channel for one mpv playback attempt.
/// SDR BGRA auxiliary frames (HDR sources are tone-mapped) serve PiP and previews.
public final class MPVPixelBufferOutput {
    private let delivery: PlaybackFrameDelivery<CVPixelBuffer>
    let initialSize: CGSize
    let maximumDimension: Int

    public init(sourceSize: CGSize, maximumDimension: Int = 480, queue: DispatchQueue, receive: @escaping (CVPixelBuffer) -> Void) {
        self.maximumDimension = min(max(maximumDimension, 2), 540)
        initialSize = MPVPixelBufferPool.outputSize(for: sourceSize, maximumDimension: self.maximumDimension)
            ?? CGSize(width: 480, height: 270)
        delivery = PlaybackFrameDelivery(queue: queue, receiver: receive)
    }

    public func invalidate() { delivery.cancel() }
    func submit(_ buffer: CVPixelBuffer) { delivery.submit(buffer) }
    deinit { invalidate() }
}

/// Bounded allocation: a slow display layer drops frames instead of growing memory.
final class MPVPixelBufferPool {
    private var pool: CVPixelBufferPool?
    private let maximumDimension: Int

    init(maximumDimension: Int = 480) { self.maximumDimension = min(max(maximumDimension, 2), 540) }
    private(set) var size: CGSize = .zero

    static func outputSize(for source: CGSize, maximumDimension: Int = 480) -> CGSize? {
        guard source.width.isFinite, source.height.isFinite,
              source.width > 1, source.height > 1 else { return nil }
        let scale = min(1, CGFloat(min(max(maximumDimension, 2), 540)) / max(source.width, source.height))
        return CGSize(width: max(2, (source.width * scale).rounded(.down)),
                      height: max(2, (source.height * scale).rounded(.down)))
    }

    func configure(sourceSize: CGSize) -> Bool {
        guard let target = Self.outputSize(for: sourceSize, maximumDimension: maximumDimension) else { return false }
        if target == size, pool != nil { return true }
        var candidate: CVPixelBufferPool?
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(target.width),
            kCVPixelBufferHeightKey as String: Int(target.height),
            kCVPixelBufferBytesPerRowAlignmentKey as String: 64,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &candidate) == kCVReturnSuccess else {
            return false
        }
        pool = candidate
        size = target
        return true
    }

    func acquire() -> CVPixelBuffer? {
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        let limits = [kCVPixelBufferPoolAllocationThresholdKey as String: 5] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limits, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }
}
#endif
