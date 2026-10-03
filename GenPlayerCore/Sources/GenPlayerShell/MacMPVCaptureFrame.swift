#if os(macOS) || os(iOS) || os(tvOS)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Owns a copy of the reply pixels; libmpv invalidates its result on the next event.
struct MacMPVCaptureFrame {
    let width: Int
    let height: Int
    let stride: Int
    let pixels: Data

    init?(width: Int, height: Int, stride: Int, pixels: Data) {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              stride >= width * 4, stride <= 131072,
              height <= (256 * 1024 * 1024) / stride,
              pixels.count >= stride * height else { return nil }
        self.width = width; self.height = height; self.stride = stride; self.pixels = pixels
    }

    func writePNG(to url: URL) -> Bool {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let color = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: color,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}
#endif
