import Foundation
import CoreGraphics

enum AdaptiveMediaLayout {
    static func detailPlaybackMaxWidth(isPhone: Bool, regularWidth: Bool) -> CGFloat {
        isPhone && !regularWidth ? .infinity : 360
    }

    /// Width assigned to each cell in a single adaptive grid track. The caller
    /// measures the grid after page padding and safe-area exclusion.
    static func adaptiveCardWidth(availableWidth: CGFloat, minimum: CGFloat, maximum: CGFloat, spacing: CGFloat) -> CGFloat {
        guard availableWidth.isFinite, availableWidth > 0 else { return minimum }
        let count = max(1, floor((availableWidth + spacing) / (minimum + spacing)))
        return min(maximum, (availableWidth - (count - 1) * spacing) / count)
    }

    /// Only release a sidebar inset when this control group's entire vertical
    /// band is clear. All rectangles use the hosting window's coordinate space.
    static func controlHorizontalInsets(
        controlFrame: CGRect,
        left: CGFloat,
        right: CGFloat,
        sidebarOnLeft: Bool?,
        obstructions: [CGRect],
        hasActiveDivision: Bool
    ) -> (left: CGFloat, right: CGFloat) {
        guard let sidebarOnLeft, !hasActiveDivision,
              !controlFrame.isEmpty, !controlFrame.isInfinite,
              !obstructions.contains(where: { !$0.intersection(controlFrame).isEmpty }) else {
            return (left, right)
        }
        return sidebarOnLeft ? (0, right) : (left, 0)
    }

    static func defersPhoneAutoRotation(regularWidth: Bool, regularHeight: Bool) -> Bool {
        // A large conventional iPhone can have regular width in landscape, but
        // compact height. Only a roomy layout in both axes keeps its current pose.
        regularWidth && regularHeight
    }

    static func showsExtendedTransportControls(availableWidth: CGFloat, regularWidth: Bool) -> Bool {
        // Seven transport buttons plus the audio/subtitle and speed/more groups.
        availableWidth >= (regularWidth ? 680 : 600)
    }

    static func usesStackedTransportControls(availableWidth: CGFloat, regularWidth: Bool) -> Bool {
        availableWidth > 0 && availableWidth < (regularWidth ? 460 : 380)
    }

    static func carouselHeight(
        width: CGFloat,
        windowSize: CGSize,
        regularWidth: Bool,
        compactHeight: Bool,
        immersive: Bool
    ) -> CGFloat {
        let width = width > 0 ? width : max(windowSize.width, 320)
        guard immersive else {
            return regularWidth
                ? min(max(width * 0.42, 320), 460)
                : min(max(width * 0.62, 250), 340)
        }

        let height = windowSize.height > 0 ? windowSize.height : max(width, 640)
        if compactHeight {
            let shortSide = min(windowSize.width > 0 ? windowSize.width : width, height)
            return min(max(shortSide * 0.68, 200), shortSide * 0.80)
        }
        if regularWidth {
            if windowSize.width > height {
                return min(max(height * 0.48, 360), 450)
            }
            return min(max(width * 0.46, height * 0.36), height * 0.48)
        }
        return min(max(width * 1.16, height * 0.52), height * 0.60)
    }
}
