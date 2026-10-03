import Foundation
import CoreVideo
import Libmpv

@main struct HDRCheck {
    static func main() async throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let transfer = CommandLine.arguments[2]
        let handle = mpv_create()!
        for (key, value) in ["config":"no", "vo":"libmpv", "ao":"null", "aid":"no", "sid":"no",
                             "pause":"yes", "hwdec":"no", "keep-open":"yes", "terminal":"no"] {
            precondition(mpv_set_option_string(handle, key, value) >= 0)
        }
        precondition(mpv_initialize(handle) >= 0)
        let lock = NSLock()
        nonisolated(unsafe) var samples: [UInt8] = []
        let channel = MPVPixelBufferOutput(sourceSize: CGSize(width: 128, height: 32), queue: .global()) { buffer in
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let pixels = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
            let y = CVPixelBufferGetHeight(buffer) / 2, w = CVPixelBufferGetWidth(buffer)
            let values = (0..<4).map { pixels[y * CVPixelBufferGetBytesPerRow(buffer) + (w * (2*$0+1) / 8) * 4] }
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            lock.lock(); samples = values; lock.unlock()
        }
        let renderer = MPVSampleBufferRenderer(output: channel)
        precondition(renderer.initialize(handle: handle) { code in fatalError("Render error \(code)") } >= 0)
        renderer.configure(sourceSize: CGSize(width: 128, height: 32))
        let strings = ["loadfile", input.path].map { strdup($0) }
        var args: [UnsafePointer<CChar>?] = strings.map { UnsafePointer($0) } + [nil]
        precondition(mpv_command(handle, &args) >= 0)
        strings.forEach { free($0) }
        for _ in 0..<200 {
            _ = mpv_wait_event(handle, 0)
            if let gamma = mpv_get_property_string(handle, "video-params/gamma"),
               let primaries = mpv_get_property_string(handle, "video-params/primaries") {
                renderer.confirmSourceTransfer(String(cString: gamma), primaries: String(cString: primaries))
                mpv_free(gamma); mpv_free(primaries)
            }
            let complete = lock.withLock { !samples.isEmpty }
            if complete { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let values = lock.withLock { samples }
        renderer.shutdown()
        mpv_terminate_destroy(handle)
        precondition(values.count == 4, "No HDR output")
        precondition(values[0] <= 2 && values[1] > 80 && values[1] < 200 && values[2] > values[1] + 15 && values[3] > values[2], "Invalid tone map: \(values)")
        print("PASS: real libmpv \(transfer) 16-bit render -> SDR bars \(values), CPU only")
    }
}
