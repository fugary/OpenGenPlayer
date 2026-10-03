import SwiftUI

/// Keep the existing grid and card metrics except when a vertical system bar
/// leaves adaptive columns wider than their fixed-width artwork.
struct MediaLibraryCardGrid<Content: View>: View {
    let columns: [GridItem]
    let spacing: CGFloat
    let legacyCardWidth: CGFloat
    @ViewBuilder let content: (CGFloat) -> Content

    var body: some View {
        // iOS 27.1 SDK ships SwiftUI 8.0.85.27. Xcode 27.0 uses the same Swift
        // compiler, so gate these SDK-only APIs by module version as well as runtime OS.
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85.27)
        if #available(iOS 27.1, *) {
            DuoMediaLibraryCardGrid(columns: columns, spacing: spacing,
                                    legacyCardWidth: legacyCardWidth, content: content)
        } else {
            LazyVGrid(columns: columns, spacing: spacing) { content(legacyCardWidth) }
        }
        #else
        LazyVGrid(columns: columns, spacing: spacing) { content(legacyCardWidth) }
        #endif
    }
}

#if os(iOS) && canImport(SwiftUI, _version: 8.0.85.27)
@available(iOS 27.1, *)
private struct DuoMediaLibraryCardGrid<Content: View>: View {
    let columns: [GridItem]
    let spacing: CGFloat
    let legacyCardWidth: CGFloat
    let content: (CGFloat) -> Content
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @State private var availableWidth: CGFloat = 0

    private var cardWidth: CGFloat {
        guard verticalEdge != nil, columns.count == 1,
              case let .adaptive(minimum, maximum) = columns[0].size else {
            return legacyCardWidth
        }
        return AdaptiveMediaLayout.adaptiveCardWidth(
            availableWidth: availableWidth, minimum: minimum, maximum: maximum,
            spacing: columns[0].spacing ?? spacing
        )
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: spacing) { content(cardWidth) }
            .onWidthChange { availableWidth = $0 }
    }
}
#endif
