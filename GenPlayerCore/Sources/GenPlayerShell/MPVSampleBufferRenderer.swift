#if os(iOS) || os(tvOS) || os(macOS)
import Foundation
import CoreVideo
import CoreImage
import ImageIO
import Libmpv

/// Offscreen libmpv output for PiP or independent previews. No window or drawable.
/// The client queue may wait for this queue during teardown, never the reverse.
final class MPVSampleBufferRenderer {
    private let queue = DispatchQueue(label: "com.genplayer.mpv.pip-render", qos: .userInitiated)
    private let output: MPVPixelBufferOutput
    private let buffers: MPVPixelBufferPool
    private var context: OpaquePointer?
    private var timer: DispatchSourceTimer?
    private var latestFrame: CVPixelBuffer?
    private var needsResize = true
    private var closed = false
    private var canRenderSource = false
    private var colorIdentity = ""
    private var toneMapper: MPVHDRToneMapper?
    private var hdrPixels: [UInt16] = []
    private var onFailure: ((Int32) -> Void)?

    init(output: MPVPixelBufferOutput) {
        self.output = output
        buffers = MPVPixelBufferPool(maximumDimension: output.maximumDimension)
    }

    func confirmSourceTransfer(_ transfer: String, primaries: String) {
        queue.async { [self] in
            guard !closed else { return }
            let identity = transfer + "|" + primaries
            guard colorIdentity != identity else { return }
            colorIdentity = identity
            toneMapper = MPVHDRToneMapper(transfer: transfer, primaries: primaries)
            canRenderSource = MPVPixelBufferColorPolicy.supports(transfer: transfer)
                && (!["pq", "hlg"].contains(transfer) || toneMapper != nil)
            needsResize = true
        }
    }

    func configure(sourceSize: CGSize) {
        queue.async { [self] in
            guard !closed else { return }
            let previous = buffers.size
            if buffers.configure(sourceSize: sourceSize), previous != buffers.size { needsResize = true }
        }
    }

    /// Called before loadfile. Poll only libmpv render updates, never screenshot commands.
    func initialize(handle: OpaquePointer, onFailure: @escaping (Int32) -> Void) -> Int32 {
        queue.sync {
            guard !closed else { return MPV_ERROR_UNINITIALIZED.rawValue }
            self.onFailure = onFailure
            guard buffers.configure(sourceSize: output.initialSize) else { return MPV_ERROR_NOMEM.rawValue }
            let result = "sw".withCString { api -> Int32 in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: api)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                return mpv_render_context_create(&context, handle, &params)
            }
            guard result >= 0 else { return result }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(33), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.renderIfNeeded() }
            self.timer = timer
            timer.resume()
            return result
        }
    }

    private func renderIfNeeded() {
        guard !closed, let context else { return }
        // Always service libmpv's render dispatch, even while waiting for color
        // metadata: VO reconfiguration may be waiting on this queue.
        let flags = mpv_render_context_update(context)
        guard canRenderSource else { return }
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 || needsResize else { return }
        if latestFrame == nil {
            var info = mpv_render_frame_info()
            let result = withUnsafeMutablePointer(to: &info) {
                mpv_render_context_get_info(context, mpv_render_param(type: MPV_RENDER_PARAM_NEXT_FRAME_INFO, data: $0))
            }
            guard result >= 0, info.flags & UInt64(MPV_RENDER_FRAME_INFO_PRESENT.rawValue) != 0 else { return }
        }
        guard let buffer = buffers.acquire() else {
            needsResize = true // Retry the latest frame after the display releases a buffer.
            return
        }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return }
        let result: Int32
        if let pixels = CVPixelBufferGetBaseAddress(buffer) {
            var dimensions = [Int32(CVPixelBufferGetWidth(buffer)), Int32(CVPixelBufferGetHeight(buffer))]
            var stride = CVPixelBufferGetBytesPerRow(buffer)
            let render: (UnsafeMutableRawPointer, String, Int) -> Int32 = { target, format, rowBytes in
                stride = rowBytes
                return dimensions.withUnsafeMutableBufferPointer { dimensions in
                    withUnsafeMutablePointer(to: &stride) { stride in
                        format.withCString { format in
                            var params = [
                                mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: dimensions.baseAddress),
                                mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: format)),
                                mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: stride),
                                mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: target),
                                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                            ]
                            return mpv_render_context_render(context, &params)
                        }
                    }
                }
            }
            if let toneMapper {
                let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
                let count = width * height * 4
                if hdrPixels.count != count { hdrPixels = [UInt16](repeating: 0, count: count) }
                result = hdrPixels.withUnsafeMutableBufferPointer { raw in
                    let status = render(UnsafeMutableRawPointer(raw.baseAddress!), "rgba64le", width * 8)
                    if status >= 0 {
                        toneMapper.convert(source: raw.baseAddress!, sourceStride: width * 8,
                            destination: pixels.assumingMemoryBound(to: UInt8.self),
                            destinationStride: CVPixelBufferGetBytesPerRow(buffer), width: width, height: height)
                    }
                    return status
                }
                CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, CGColorSpace(name: CGColorSpace.sRGB)!, .shouldPropagate)
            } else { result = render(pixels, "bgra", stride) }
        } else { result = MPV_ERROR_NOMEM.rawValue }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard result >= 0 else {
            timer?.cancel(); timer = nil
            onFailure?(result)
            return
        }
        needsResize = false
        latestFrame = buffer
        output.submit(buffer)
    }

    /// User-requested capture of the last rendered frame, not the frame delivery mechanism.
    func snapshot(to url: URL, completion: @escaping (Bool) -> Void) {
        queue.async { [self] in
            guard !closed, let frame = latestFrame,
                  let image = CIContext(options: [.useSoftwareRenderer: true]).createCGImage(CIImage(cvPixelBuffer: frame),
                    from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(frame), height: CVPixelBufferGetHeight(frame))),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
                completion(false); return
            }
            CGImageDestinationAddImage(destination, image, nil)
            completion(CGImageDestinationFinalize(destination))
        }
    }

    func shutdown() {
        output.invalidate()
        queue.sync {
            closed = true
            timer?.cancel(); timer = nil
            if let context { mpv_render_context_free(context) }
            context = nil; latestFrame = nil; onFailure = nil
        }
    }
}
#endif
