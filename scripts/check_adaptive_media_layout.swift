import Foundation

@main
enum AdaptiveMediaLayoutChecks {
    static func main() {
        // Synthetic viewports: do not encode a specific device's screen dimensions.
        let outer = CGSize(width: 390, height: 844)
        let inner = CGSize(width: 800, height: 720)
        let split = CGSize(width: 350, height: 720)
        let landscape = CGSize(width: 844, height: 390)

        precondition(AdaptiveMediaLayout.detailPlaybackMaxWidth(isPhone: true, regularWidth: false) == .infinity,
                     "Compact iPhone details fill their safe content width")
        precondition(AdaptiveMediaLayout.detailPlaybackMaxWidth(isPhone: true, regularWidth: true) == 360,
                     "Wide phone details keep a bounded playback button")
        precondition(AdaptiveMediaLayout.detailPlaybackMaxWidth(isPhone: false, regularWidth: false) == 360,
                     "Compact iPad split views must not switch to the full-width phone button")
        precondition(AdaptiveMediaLayout.detailPlaybackMaxWidth(isPhone: false, regularWidth: true) == 360)

        func hero(_ size: CGSize, regular: Bool, compactHeight: Bool = false) -> CGFloat {
            AdaptiveMediaLayout.carouselHeight(
                width: size.width, windowSize: size, regularWidth: regular,
                compactHeight: compactHeight, immersive: true
            )
        }

        let outerHeight = hero(outer, regular: false)
        let innerHeight = hero(inner, regular: true)
        let splitHeight = hero(split, regular: false)
        precondition(outerHeight >= outer.height * 0.52 && outerHeight <= outer.height * 0.60)
        precondition(innerHeight >= 360 && innerHeight <= 450)
        precondition(splitHeight <= split.height * 0.60)
        precondition(hero(outer, regular: false) == outerHeight, "Closing restores outer-screen geometry")
        precondition(hero(landscape, regular: false, compactHeight: true) <= landscape.height * 0.80)
        precondition(!AdaptiveMediaLayout.showsExtendedTransportControls(availableWidth: 350, regularWidth: false))
        precondition(AdaptiveMediaLayout.showsExtendedTransportControls(availableWidth: 720, regularWidth: true))
        precondition(!AdaptiveMediaLayout.showsExtendedTransportControls(availableWidth: 500, regularWidth: true), "Regular traits alone do not guarantee enough room")
        precondition(!AdaptiveMediaLayout.showsExtendedTransportControls(availableWidth: 599, regularWidth: false))
        precondition(AdaptiveMediaLayout.showsExtendedTransportControls(availableWidth: 600, regularWidth: false))
        precondition(!AdaptiveMediaLayout.showsExtendedTransportControls(availableWidth: 679, regularWidth: true))
        precondition(AdaptiveMediaLayout.showsExtendedTransportControls(availableWidth: 680, regularWidth: true))

        precondition(AdaptiveMediaLayout.usesStackedTransportControls(availableWidth: 350, regularWidth: false))
        precondition(AdaptiveMediaLayout.usesStackedTransportControls(availableWidth: 400, regularWidth: true))
        precondition(!AdaptiveMediaLayout.usesStackedTransportControls(availableWidth: 500, regularWidth: true))
        precondition(!AdaptiveMediaLayout.usesStackedTransportControls(availableWidth: 0, regularWidth: false))

        // Preserve Follow Video Aspect for ordinary large iPhones in landscape.
        precondition(!AdaptiveMediaLayout.defersPhoneAutoRotation(regularWidth: true, regularHeight: false))
        precondition(!AdaptiveMediaLayout.defersPhoneAutoRotation(regularWidth: false, regularHeight: true))
        precondition(!AdaptiveMediaLayout.defersPhoneAutoRotation(regularWidth: false, regularHeight: false))
        precondition(AdaptiveMediaLayout.defersPhoneAutoRotation(regularWidth: true, regularHeight: true))

        // A short side status region must not reserve the same width below it.
        let statusRegion = CGRect(x: 430, y: 0, width: 90, height: 180)
        let lowerControls = CGRect(x: 0, y: 550, width: 520, height: 210)
        func controlInsets(_ frame: CGRect, sidebarOnLeft: Bool? = false, division: Bool = false,
                           obstructions: [CGRect] = [statusRegion]) -> (left: CGFloat, right: CGFloat) {
            AdaptiveMediaLayout.controlHorizontalInsets(
                controlFrame: frame, left: 12, right: 96, sidebarOnLeft: sidebarOnLeft,
                obstructions: obstructions, hasActiveDivision: division
            )
        }
        let expanded = controlInsets(lowerControls)
        precondition(expanded.left == 12 && expanded.right == 0)
        let top = controlInsets(CGRect(x: 0, y: 70, width: 520, height: 50))
        precondition(top.left == 12 && top.right == 96, "Overlapping status UI retains the safe area")
        let ordinary = controlInsets(lowerControls, sidebarOnLeft: nil)
        precondition(ordinary.left == 12 && ordinary.right == 96, "Ordinary devices keep both insets")
        let leftBar = controlInsets(lowerControls, sidebarOnLeft: true)
        precondition(leftBar.left == 0 && leftBar.right == 96, "Only the actual sidebar side is released")
        let folded = controlInsets(lowerControls, division: true)
        precondition(folded.left == 12 && folded.right == 96, "Active fold keeps conservative layout")
        let camera = controlInsets(lowerControls, obstructions: [CGRect(x: 430, y: 600, width: 50, height: 50)])
        precondition(camera.right == 96, "Camera margins still reserve space inside a control group")
        let unavailable = controlInsets(.zero)
        precondition(unavailable.left == 12 && unavailable.right == 96, "Unknown geometry must not release an inset")

        func column(_ width: CGFloat, maximum: CGFloat = .infinity) -> CGFloat {
            AdaptiveMediaLayout.adaptiveCardWidth(availableWidth: width, minimum: 112, maximum: maximum, spacing: 12)
        }
        precondition(column(320) == 154, "Two poster columns fill the safe content width")
        precondition(column(360) == 112, "A third column fits exactly at the density boundary")
        precondition(column(359) == 173.5, "Below the boundary, preserve two columns")
        precondition(column(320, maximum: 132) == 132, "Person grids retain their maximum artwork width")
        precondition(column(80) == 80, "A single column must fit even an unusually narrow container")
        precondition(column(0) == 112 && column(.infinity) == 112, "Unavailable geometry keeps the legacy width")
        for width in stride(from: 112.0, through: 1200.0, by: 1.0) {
            let cell = column(width)
            let columns = ((width + 12) / (cell + 12)).rounded()
            precondition(cell >= 112 && cell < 236)
            precondition(abs(columns * cell + (columns - 1) * 12 - width) < 0.001,
                         "Posters and inter-column gaps must exactly fill the measured grid")
        }

        for width in stride(from: 280.0, through: 1200.0, by: 40.0) {
            for height in stride(from: 300.0, through: 1000.0, by: 50.0) {
                let size = CGSize(width: width, height: height)
                let result = hero(size, regular: width >= 600, compactHeight: height < 450)
                precondition(result.isFinite && result > 0 && result <= height)
            }
        }
        let initialHeight = AdaptiveMediaLayout.carouselHeight(
            width: 0, windowSize: CGSize(width: 0, height: 0), regularWidth: false, compactHeight: false, immersive: true
        )
        precondition(initialHeight.isFinite && initialHeight > 0)
        print("Adaptive media layout checks passed (360 viewport sizes, 4 rotation trait combinations, 7 control-region cases, 1089 grid widths and grid boundaries).")
    }
}
