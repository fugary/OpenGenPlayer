import SwiftUI

/// Fixed-spacing action rows can force the entire detail stack beyond its safe
/// width. Wrap the same actions when the phone or split view is too narrow.
struct MediaDetailActionGrid<Content: View>: View {
    var alignment: HorizontalAlignment = .center
    @ViewBuilder let content: () -> Content

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 44, maximum: 44), spacing: 8)],
            alignment: alignment,
            spacing: 8,
            content: content
        )
        .frame(maxWidth: 360)
    }
}
