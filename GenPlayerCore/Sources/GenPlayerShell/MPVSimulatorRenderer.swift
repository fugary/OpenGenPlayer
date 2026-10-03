#if (os(iOS) || os(tvOS)) && targetEnvironment(simulator)
import Foundation
import CoreGraphics
import ImageIO
import Libmpv

/// Simulator-only libmpv SW output. Never creates a Metal device or Vulkan swapchain.
/// Render APIs have their own queue, which must NEVER wait for the client/UI queue.
final class MPVSimulatorRenderer {
    private let queue = DispatchQueue(label: "com.genplayer.mpv.simulator-render", qos: .userInitiated)
    private var context: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var size = CGSize(width: 2, height: 2)
    private var needsResize = true
    private var lastFrame: CGImage?
    private var pixels: UnsafeMutableRawPointer?
    private var byteCount = 0
    private var onFailure: ((Int32) -> Void)?

    // One replaceable frame plus at most one queued main-thread delivery.
    private let deliveryLock = NSLock()
    private var active = true
    private var pendingFrame: CGImage?
    private var deliveryScheduled = false
    private var display: ((CGImage) -> Void)?

    func configure(size: CGSize, display: @escaping (CGImage) -> Void) {
        #if os(tvOS)
        // ASS is composited into this frame. A 720p preview enlarged to the TV
        // viewport also enlarges glyph pixels; keep a bounded 1080p TV output.
        guard let bounded = MPVSoftwareRenderSize.fit(size, maximumDimension: 1920) else { return }
        #else
        guard let bounded = MPVSoftwareRenderSize.fit(size) else { return }
        #endif
        deliveryLock.lock()
        self.display = display
        deliveryLock.unlock()
        queue.async { [self] in
            if self.size != bounded { self.size = bounded; needsResize = true }
        }
    }

    /// Called on the client queue before loadfile; no video output exists yet.
    func initialize(handle: OpaquePointer, onFailure: @escaping (Int32) -> Void) -> Int32 {
        queue.sync {
            self.onFailure = onFailure
            let result = "sw".withCString { api -> Int32 in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                return mpv_render_context_create(&context, handle, &params)
            }
            guard result >= 0 else { return result }
            // Advanced control is intentionally disabled: polling needs no C
            // callback pointer, and the decoder cannot wait for texture allocation.
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(16), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.renderIfNeeded() }
            self.timer = timer
            timer.resume()
            return result
        }
    }

    private func renderIfNeeded() {
        guard let context else { return }
        let flags = mpv_render_context_update(context)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 || needsResize else { return }
        needsResize = false
        let width = Int(size.width), height = Int(size.height)
        var stride = (width * 4 + 63) & ~63
        let required = stride * height
        if byteCount != required {
            pixels?.deallocate()
            pixels = .allocate(byteCount: required, alignment: 64)
            byteCount = required
        }
        guard let pixels else { return }
        var dimensions = [Int32(width), Int32(height)]
        let result = dimensions.withUnsafeMutableBufferPointer { dimensions in
            withUnsafeMutablePointer(to: &stride) { stride in
                "rgb0".withCString { format in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: dimensions.baseAddress),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: format)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: stride),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: pixels),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    return mpv_render_context_render(context, &params)
                }
            }
        }
        guard result >= 0 else {
            timer?.cancel(); timer = nil
            onFailure?(result)
            return
        }
        // Copy: Core Animation may retain an image while the next frame overwrites pixels.
        guard let provider = CGDataProvider(data: Data(bytes: pixels, count: required) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return }
        lastFrame = image
        deliveryLock.lock()
        pendingFrame = active ? image : nil
        let schedule = active && !deliveryScheduled
        if schedule { deliveryScheduled = true }
        deliveryLock.unlock()
        if schedule {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.deliveryLock.lock()
                let frame = self.active ? self.pendingFrame : nil
                let display = self.display
                self.pendingFrame = nil
                self.deliveryScheduled = false
                self.deliveryLock.unlock()
                if let frame { display?(frame) }
            }
        }
    }

    func snapshot(to url: URL, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard context != nil, let image = lastFrame,
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                completion(false); return
            }
            CGImageDestinationAddImage(destination, image, nil)
            completion(CGImageDestinationFinalize(destination))
        }
    }

    /// Client queue only, before mpv_terminate_destroy. Render queue never calls client APIs.
    func shutdown() {
        deliveryLock.lock()
        active = false; pendingFrame = nil; display = nil
        deliveryLock.unlock()
        queue.sync {
            timer?.cancel(); timer = nil
            if let context { mpv_render_context_free(context) }
            context = nil; lastFrame = nil; onFailure = nil
            pixels?.deallocate(); pixels = nil; byteCount = 0
        }
    }
}
#endif
