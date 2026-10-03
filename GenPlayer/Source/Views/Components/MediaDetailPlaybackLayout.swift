import SwiftUI
import UIKit

private struct MediaDetailPlaybackLayout: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        // An iPad in a compact split view still uses the bounded detail CTA.
        content.frame(maxWidth: AdaptiveMediaLayout.detailPlaybackMaxWidth(
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            regularWidth: horizontalSizeClass == .regular
        ))
    }
}

extension View {
    func mediaDetailPlaybackButtonFrame() -> some View {
        modifier(MediaDetailPlaybackLayout())
    }
}
