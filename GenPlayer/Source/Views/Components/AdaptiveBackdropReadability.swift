import SwiftUI
#if os(iOS)
import UIKit
#endif

struct AdaptiveBackdropReadabilityStyle: Equatable {
    let baseOverlayOpacity: Double
    let heroTopOpacity: Double
    let heroUpperMidOpacity: Double
    let heroLowerMidOpacity: Double
    let heroBottomOpacity: Double

    static let `default` = AdaptiveBackdropReadabilityStyle(
        baseOverlayOpacity: 0.52,
        heroTopOpacity: 0.08,
        heroUpperMidOpacity: 0.16,
        heroLowerMidOpacity: 0.34,
        heroBottomOpacity: 0.56
    )
}

final class AdaptiveBackdropReadabilityModel: ObservableObject {
    @Published private(set) var style: AdaptiveBackdropReadabilityStyle = .default

    func reset() {
        apply(.default)
    }

    func update(from image: UIImage) {
        guard let cgImage = image.cgImage else {
            reset()
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let nextStyle = Self.extractStyle(from: cgImage)
            DispatchQueue.main.async {
                self?.apply(nextStyle)
            }
        }
    }

    private func apply(_ nextStyle: AdaptiveBackdropReadabilityStyle) {
        guard style != nextStyle else { return }
        withAnimation(.easeInOut(duration: 0.25)) {
            style = nextStyle
        }
    }

    private static func extractStyle(from cgImage: CGImage) -> AdaptiveBackdropReadabilityStyle {
        let size = 40
        let width = size
        let height = size
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8

        var rawData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &rawData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .default
        }

        context.interpolationQuality = .low
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var totalR: Double = 0
        var totalG: Double = 0
        var totalB: Double = 0
        let pixelCount = width * height

        for index in 0..<pixelCount {
            let offset = index * bytesPerPixel
            totalR += Double(rawData[offset])
            totalG += Double(rawData[offset + 1])
            totalB += Double(rawData[offset + 2])
        }

        let avgR = totalR / Double(pixelCount) / 255.0
        let avgG = totalG / Double(pixelCount) / 255.0
        let avgB = totalB / Double(pixelCount) / 255.0

        let brightness = max(avgR, max(avgG, avgB))
        let minChannel = min(avgR, min(avgG, avgB))
        let saturation = brightness > 0 ? (brightness - minChannel) / brightness : 0
        let luminance = (0.2126 * avgR) + (0.7152 * avgG) + (0.0722 * avgB)

        let lightBias = normalized(luminance, min: 0.20, max: 0.78)
        let brightBias = normalized(brightness, min: 0.26, max: 0.92)
        let saturationBias = normalized(saturation, min: 0.18, max: 0.82)
        let readabilityBias = clamp((lightBias * 0.62) + (brightBias * 0.42) - (saturationBias * 0.08))

        return AdaptiveBackdropReadabilityStyle(
            baseOverlayOpacity: interpolate(from: 0.44, to: 0.60, progress: readabilityBias),
            heroTopOpacity: interpolate(from: 0.04, to: 0.11, progress: readabilityBias),
            heroUpperMidOpacity: interpolate(from: 0.12, to: 0.20, progress: readabilityBias),
            heroLowerMidOpacity: interpolate(from: 0.28, to: 0.39, progress: readabilityBias),
            heroBottomOpacity: interpolate(from: 0.48, to: 0.64, progress: readabilityBias)
        )
    }

    private static func normalized(_ value: Double, min: Double, max: Double) -> Double {
        guard max > min else { return 0 }
        return clamp((value - min) / (max - min))
    }

    private static func interpolate(from start: Double, to end: Double, progress: Double) -> Double {
        start + ((end - start) * clamp(progress))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
