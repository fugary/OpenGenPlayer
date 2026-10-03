#if os(iOS) || os(macOS)
import CoreVideo
import CoreGraphics
import Foundation

/// CPU-only composition for the bounded SDR mpv PiP output. Call on one queue.
/// Never modify the producer's buffer: it may also back a snapshot or queued frame.
public final class PlaybackPixelBufferCompositor {
    private let pool = MPVPixelBufferPool()
    public init() {}

    public func compose(_ source: CVPixelBuffer, overlay: CGImage?) -> CVPixelBuffer? {
        guard let overlay else { return source }
        let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
        let size = CGSize(width: width, height: height)
        guard CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_32BGRA,
              MPVPixelBufferPool.outputSize(for: size) == size,
              overlay.width == width, overlay.height == height,
              pool.configure(sourceSize: size), let result = pool.acquire(),
              CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(result, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        guard let input = CVPixelBufferGetBaseAddress(source), let output = CVPixelBufferGetBaseAddress(result),
              let context = CGContext(data: output, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(result),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        for row in 0..<height {
            memcpy(output.advanced(by: row * CVPixelBufferGetBytesPerRow(result)),
                   input.advanced(by: row * CVPixelBufferGetBytesPerRow(source)), width * 4)
        }
        context.draw(overlay, in: CGRect(origin: .zero, size: size))
        CVBufferPropagateAttachments(source, result)
        return result
    }
}
#endif
