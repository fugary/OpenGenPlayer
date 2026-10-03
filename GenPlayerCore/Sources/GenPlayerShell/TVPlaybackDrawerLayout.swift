import Foundation

/// The anchor depends on the viewport, never on the selected tab or its rows.
struct TVPlaybackDrawerLayout {
    let viewportHeight: CGFloat
    let isAudio: Bool

    var topInset: CGFloat { max(36, viewportHeight * 0.16) }
    var contentLimit: CGFloat {
        max(80, min(isAudio ? 420 : 500, viewportHeight - topInset - 210 - 64))
    }

    func contentHeight(measured: CGFloat) -> CGFloat {
        min(contentLimit, max(88, measured > 0 ? measured : 280))
    }
}
