import Foundation
import CoreVideo
import CoreGraphics

@main enum FrameChecks {
    static func main() {
        var count = 0
        func check(_ condition: Bool, line: Int = #line) {
            precondition(condition, "Frame check failed at line \(line)")
            count += 1
        }
        let queue = DispatchQueue(label: "frame-checks")
        var received: [Int] = []
        let channel = PlaybackFrameDelivery<Int>(queue: queue) { received.append($0) }
        queue.suspend()
        for value in 0..<10_000 { channel.submit(value) }
        queue.resume()
        queue.sync {}
        check(received == [9_999]) // Backpressure drops intermediate frames.
        queue.suspend()
        channel.submit(10_000)
        channel.cancel()
        channel.submit(10_001)
        queue.resume()
        queue.sync {}
        check(received == [9_999])

        var reentrant: PlaybackFrameDelivery<Int>!
        reentrant = PlaybackFrameDelivery(queue: queue) { value in
            received.append(value)
            if value == 1 { reentrant.submit(2) }
        }
        reentrant.submit(1)
        queue.sync {}
        queue.sync {}
        check(received.suffix(2) == [1, 2])
        reentrant.cancel()
        reentrant = nil

        check(MPVPixelBufferPool.outputSize(for: CGSize(width: 3840, height: 2160)) == CGSize(width: 480, height: 270))
        check(MPVPixelBufferPool.outputSize(for: CGSize(width: 1080, height: 1920)) == CGSize(width: 270, height: 480))
        check(MPVPixelBufferPool.outputSize(for: CGSize(width: 120, height: 80)) == CGSize(width: 120, height: 80))
        check(MPVPixelBufferPool.outputSize(for: CGSize(width: 1920, height: 1080), maximumDimension: 540) == CGSize(width: 540, height: 303))
        check(MPVPixelBufferPool.outputSize(for: CGSize(width: 1920, height: 1080), maximumDimension: Int.max) == CGSize(width: 540, height: 303))
        check(MPVPixelBufferPool.outputSize(for: CGSize(width: 1920, height: 1080), maximumDimension: -1) == CGSize(width: 2, height: 2))
        let tvPool = MPVPixelBufferPool(maximumDimension: 540)
        check(tvPool.configure(sourceSize: CGSize(width: 1920, height: 1080)))
        let tvBuffer = tvPool.acquire()!
        check(CVPixelBufferGetWidth(tvBuffer) == 540 && CVPixelBufferGetHeight(tvBuffer) == 303)
        check(MPVPixelBufferPool.outputSize(for: .zero) == nil)
        check(MPVPixelBufferPool.outputSize(for: CGSize(width: CGFloat.nan, height: 100)) == nil)

        let pool = MPVPixelBufferPool()
        check(pool.acquire() == nil)
        check(pool.configure(sourceSize: CGSize(width: 1920, height: 1080)))
        var held: [CVPixelBuffer] = []
        for _ in 0..<5 {
            guard let frame = pool.acquire() else {
                fatalError("System video-buffer allocation failed. This headless test requires IOSurface access.")
            }
            held.append(frame)
        }
        check(pool.acquire() == nil) // No unbounded allocation behind a stalled display.
        check(CVPixelBufferGetWidth(held[0]) == 480 && CVPixelBufferGetHeight(held[0]) == 270)
        check(CVPixelBufferGetPixelFormatType(held[0]) == kCVPixelFormatType_32BGRA)
        check(CVPixelBufferGetBytesPerRow(held[0]) >= 480 * 4)
        held.removeLast()
        check(pool.acquire() != nil)
        check(!pool.configure(sourceSize: .zero) && pool.size == CGSize(width: 480, height: 270))

        var deliveredWidth = 0
        let output = MPVPixelBufferOutput(sourceSize: .zero, queue: queue) { deliveredWidth = CVPixelBufferGetWidth($0) }
        check(output.initialSize == CGSize(width: 480, height: 270))
        output.submit(held[0])
        queue.sync {}
        check(deliveredWidth == 480)
        deliveredWidth = 0
        queue.suspend()
        output.submit(held[0])
        output.invalidate()
        queue.resume()
        queue.sync {}
        check(deliveredWidth == 0)

        let ordinary = ["vo": "gpu-next", "gpu-api": "vulkan", "gpu-context": "moltenvk", "hwdec": "auto-safe",
                        "pause": "yes", "start": "12.35", "secondary-sid": "7", "target-colorspace-hint": "yes"]
        let pip = MPVStartupOptionPolicy.pixelBufferOptions(ordinary)
        check(pip["vo"] == "libmpv" && pip["hwdec"] == "videotoolbox-copy")
        check(pip["gpu-api"] == nil && pip["gpu-context"] == nil && pip["target-colorspace-hint"] == nil)
        check(pip["pause"] == "yes" && pip["start"] == "12.35" && pip["secondary-sid"] == "7")
        check(MPVStartupOptionPolicy.pixelBufferOptions(["hwdec": "no"])["hwdec"] == "no")
        check(ordinary["vo"] == "gpu-next" && ordinary["hwdec"] == "auto-safe")
        for transfer in ["pq", "hlg", "bt.1886", "srgb", "gamma2.2", " BT.1886 "] {
            check(MPVPixelBufferColorPolicy.supports(transfer: transfer))
        }
        for transfer in ["linear", "v-log", "s-log2", "", "auto", "unknown"] {
            check(!MPVPixelBufferColorPolicy.supports(transfer: transfer))
        }
        let compositionPool = MPVPixelBufferPool()
        check(compositionPool.configure(sourceSize: CGSize(width: 4, height: 4)))
        let source = compositionPool.acquire()!
        CVPixelBufferLockBaseAddress(source, [])
        for y in 0..<4 {
            let row = CVPixelBufferGetBaseAddress(source)!.advanced(by: y * CVPixelBufferGetBytesPerRow(source)).assumingMemoryBound(to: UInt8.self)
            for x in 0..<4 { row[x * 4] = 255; row[x * 4 + 1] = 0; row[x * 4 + 2] = 0; row[x * 4 + 3] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> [UInt8] {
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let base = CVPixelBufferGetBaseAddress(buffer)!.advanced(by: y * CVPixelBufferGetBytesPerRow(buffer) + x * 4).assumingMemoryBound(to: UInt8.self)
            return Array(UnsafeBufferPointer(start: base, count: 4))
        }
        var overlayBytes = [UInt8](repeating: 0, count: 4 * 4 * 4)
        overlayBytes[2] = 255; overlayBytes[3] = 255 // Opaque red at upper left only.
        overlayBytes[6] = 128; overlayBytes[7] = 128 // Premultiplied half red next to it.
        let overlay = CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 16, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)],
            provider: CGDataProvider(data: Data(overlayBytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent)!
        let compositor = PlaybackPixelBufferCompositor()
        check(compositor.compose(source, overlay: nil) === source)
        var composited: [CVPixelBuffer] = []
        for _ in 0..<5 { composited.append(compositor.compose(source, overlay: overlay)!) }
        check(composited[0] !== source)
        check(pixel(source, x: 0, y: 0) == [255, 0, 0, 255]) // Producer remains untouched.
        check(pixel(composited[0], x: 0, y: 0) == [0, 0, 255, 255])
        check(pixel(composited[0], x: 0, y: 3) == [255, 0, 0, 255]) // No vertical flip.
        check(pixel(composited[0], x: 3, y: 0) == [255, 0, 0, 255]) // Transparent area preserved.
        let blended = pixel(composited[0], x: 1, y: 0)
        check(abs(Int(blended[0]) - 127) <= 1 && abs(Int(blended[2]) - 128) <= 1 && blended[3] == 255)
        check(compositor.compose(source, overlay: overlay) == nil) // Backpressure stays bounded.
        composited.removeLast()
        check(compositor.compose(source, overlay: overlay) != nil)
        check(compositor.compose(held[0], overlay: overlay) == nil) // Reject mismatched overlay size.
        print("Passed \(count) continuous-frame buffer, composition and delivery checks (no player or media opened)")
    }
}
