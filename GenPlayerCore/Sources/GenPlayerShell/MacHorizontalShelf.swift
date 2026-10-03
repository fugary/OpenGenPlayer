#if os(macOS)
import SwiftUI
import AppKit
import GenPlayerCore

/// macOS-only horizontal media shelf.
///
/// Wraps a plain `ScrollView(.horizontal)` (keeping the existing `HStack` layout and
/// performance profile) and adds hover-revealed paging chevrons so mouse users can
/// browse the row without relying on a trackpad horizontal swipe. Trackpad horizontal
/// scrolling and the outer vertical page scroll are untouched — this component never
/// remaps the scroll wheel.
struct MacHorizontalShelf<Item: Identifiable, Card: View>: View {
    let items: [Item]
    var spacing: CGFloat = 16
    var horizontalPadding: CGFloat = 24
    var verticalPadding: CGFloat = 16
    var alignment: VerticalAlignment = .top
    var pageFraction: CGFloat = 0.9

    /// Height of the artwork at the top of each item. Media cards are artwork + title
    /// text, so centering the chevrons on the whole row makes them sit below the
    /// poster center; pass the artwork height to center them on the artwork instead.
    /// `nil` keeps the plain whole-row centering.
    var artworkHeight: CGFloat? = nil

    /// Extra space between the row's top padding and the artwork, for cards that add
    /// their own inner padding above the artwork. Only used with `artworkHeight`.
    var artworkTopInset: CGFloat = 0

    let card: (Item) -> Card

    init(
        items: [Item],
        spacing: CGFloat = 16,
        horizontalPadding: CGFloat = 24,
        verticalPadding: CGFloat = 16,
        alignment: VerticalAlignment = .top,
        pageFraction: CGFloat = 0.9,
        artworkHeight: CGFloat? = nil,
        artworkTopInset: CGFloat = 0,
        @ViewBuilder card: @escaping (Item) -> Card
    ) {
        self.items = items
        self.spacing = spacing
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.alignment = alignment
        self.pageFraction = pageFraction
        self.artworkHeight = artworkHeight
        self.artworkTopInset = artworkTopInset
        self.card = card
    }

    @State private var isHovered = false
    @State private var contentOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var viewportWidth: CGFloat = 0
    @State private var itemMinX: [Int: CGFloat] = [:]

    private var hasOverflow: Bool { contentWidth > viewportWidth + 1 }

    /// Distance from the top of the row content to the chevron center.
    private var chevronCenterY: CGFloat? {
        guard let artworkHeight else { return nil }
        return verticalPadding + artworkTopInset + artworkHeight / 2
    }

    private var leadingChevronAlignment: Alignment {
        chevronCenterY == nil ? .leading : .topLeading
    }

    private var trailingChevronAlignment: Alignment {
        chevronCenterY == nil ? .trailing : .topTrailing
    }

    private var chevronTopPadding: CGFloat {
        guard let chevronCenterY else { return 0 }
        return max(0, chevronCenterY - MacShelfChevron.diameter / 2)
    }

    private var showsLeadingChevron: Bool {
        isHovered && hasOverflow && contentOffset > 0.5
    }

    private var showsTrailingChevron: Bool {
        isHovered && hasOverflow && contentOffset < contentWidth - viewportWidth - 0.5
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: alignment, spacing: spacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        card(item)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: MacShelfItemMinXKey.self,
                                        value: [index: geo.frame(in: .named(MacShelfSpaces.content)).minX]
                                    )
                                }
                            )
                            .id(item.id)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: MacShelfMetricsKey.self,
                            value: MacShelfMetrics(
                                offset: -geo.frame(in: .named(MacShelfSpaces.viewport)).minX,
                                contentWidth: geo.size.width,
                                viewportWidth: nil
                            )
                        )
                    }
                )
                .coordinateSpace(name: MacShelfSpaces.content)
                .id(MacShelfScrollTarget.contentStart)
            }
            .coordinateSpace(name: MacShelfSpaces.viewport)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: MacShelfMetricsKey.self,
                        value: MacShelfMetrics(
                            offset: nil,
                            contentWidth: nil,
                            viewportWidth: geo.size.width
                        )
                    )
                }
            )
            .overlay(alignment: leadingChevronAlignment) {
                if showsLeadingChevron {
                    MacShelfChevron(direction: -1) { page(-1, proxy: proxy) }
                        .padding(.leading, 8)
                        .padding(.top, chevronTopPadding)
                        .transition(.opacity)
                }
            }
            .overlay(alignment: trailingChevronAlignment) {
                if showsTrailingChevron {
                    MacShelfChevron(direction: 1) { page(1, proxy: proxy) }
                        .padding(.trailing, 8)
                        .padding(.top, chevronTopPadding)
                        .transition(.opacity)
                }
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
            .onPreferenceChange(MacShelfItemMinXKey.self) { newValue in
                itemMinX = newValue
            }
            .onPreferenceChange(MacShelfMetricsKey.self) { metrics in
                if let offset = metrics.offset { contentOffset = offset }
                if let width = metrics.contentWidth { contentWidth = width }
                if let width = metrics.viewportWidth { viewportWidth = width }
            }
            .onChange(of: items.count) { _ in
                itemMinX = [:]
            }
        }
    }

    // MARK: - Paging

    private var sortedPositions: [(index: Int, minX: CGFloat)] {
        itemMinX.sorted { $0.key < $1.key }.map { (index: $0.key, minX: $0.value) }
    }

    /// Index of the item whose leading edge is at or just past the current offset.
    private func currentLeadingIndex() -> Int {
        if let first = sortedPositions.first(where: { $0.minX >= contentOffset - 0.5 }) {
            return first.index
        }
        return max(0, items.count - 1)
    }

    private func page(_ direction: Int, proxy: ScrollViewProxy) {
        guard !items.isEmpty, viewportWidth > 0 else { return }
        guard sortedPositions.count >= items.count else { return }

        let step = max(viewportWidth * pageFraction, 200)
        let current = currentLeadingIndex()
        var index = current

        if direction > 0 {
            let target = contentOffset + step
            let match = sortedPositions.last(where: { $0.minX <= target })?.index
            index = match ?? max(0, items.count - 1)
            if index <= current && current < items.count - 1 {
                index = current + 1
            }
        } else {
            let target = max(0, contentOffset - step)
            let match = sortedPositions.first(where: { $0.minX >= target })?.index
            index = match ?? 0
            if index >= current && current > 0 {
                index = current - 1
            }
        }

        index = max(0, min(index, items.count - 1))
        withAnimation(.easeInOut(duration: 0.28)) {
            if direction < 0 && index == 0 {
                // Include the row's padding when returning to the true scroll origin.
                proxy.scrollTo(MacShelfScrollTarget.contentStart, anchor: .leading)
            } else {
                proxy.scrollTo(items[index].id, anchor: .leading)
            }
        }
    }
}

// MARK: - Chevron

private struct MacShelfChevron: View {
    static let diameter: CGFloat = 32

    let direction: Int
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: direction > 0 ? "chevron.right" : "chevron.left")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.white)
                .frame(width: Self.diameter, height: Self.diameter)
                .background(
                    Circle().fill(isHovered ? Color.black.opacity(0.72) : Color.black.opacity(0.52))
                )
                .overlay(
                    Circle().stroke(Color.white.opacity(isHovered ? 0.7 : 0.3), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(platformShellString(direction > 0 ? "Scroll Right" : "Scroll Left")))
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .macPointerHover()
    }
}

// MARK: - Preferences

private enum MacShelfSpaces {
    static let content = "macShelf.content"
    static let viewport = "macShelf.viewport"
}

private enum MacShelfScrollTarget: Hashable {
    case contentStart
}

private struct MacShelfMetrics: Equatable {
    var offset: CGFloat?
    var contentWidth: CGFloat?
    var viewportWidth: CGFloat?
}

private struct MacShelfMetricsKey: PreferenceKey {
    static let defaultValue = MacShelfMetrics()

    static func reduce(value: inout MacShelfMetrics, nextValue: () -> MacShelfMetrics) {
        let next = nextValue()
        value.offset = next.offset ?? value.offset
        value.contentWidth = next.contentWidth ?? value.contentWidth
        value.viewportWidth = next.viewportWidth ?? value.viewportWidth
    }
}

private struct MacShelfItemMinXKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
#endif
