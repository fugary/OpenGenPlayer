import SwiftUI

#if os(tvOS)
public struct TVFocusableRowGrid<Data: RandomAccessCollection, ID: Hashable, Content: View>: View {
    let data: [Data.Element]
    let id: KeyPath<Data.Element, ID>
    let minimumItemWidth: CGFloat
    let spacing: CGFloat
    let content: (Data.Element) -> Content
    
    public init(
        data: Data,
        id: KeyPath<Data.Element, ID>,
        minimumItemWidth: CGFloat,
        spacing: CGFloat = 16,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.data = Array(data)
        self.id = id
        self.minimumItemWidth = minimumItemWidth
        self.spacing = spacing
        self.content = content
    }
    
    public var body: some View {
        GeometryReader { geometry in
            let availableWidth = geometry.size.width
            let columnCount = max(1, Int((availableWidth + spacing) / (minimumItemWidth + spacing)))
            
            // To ensure equal width distribution like LazyVGrid, we can calculate precise item width
            let totalSpacing = spacing * CGFloat(columnCount - 1)
            let itemWidth = max(minimumItemWidth, (availableWidth - totalSpacing) / CGFloat(columnCount))
            
            let rows = stride(from: 0, to: data.count, by: columnCount).map { i -> [Data.Element] in
                let end = min(i + columnCount, data.count)
                return Array(data[i..<end])
            }
            
            LazyVStack(alignment: .leading, spacing: spacing) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, rowItems in
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(rowItems, id: id) { item in
                            content(item)
                                .frame(width: itemWidth)
                        }
                        
                        // Fill remaining space in the row so the focus section is full width
                        // This prevents focus loss when moving up/down from an incomplete last row
                        if rowItems.count < columnCount {
                            Spacer(minLength: 0)
                        }
                    }
                    .focusSection()
                }
            }
        }
    }
}

public extension TVFocusableRowGrid where Data.Element: Identifiable, ID == Data.Element.ID {
    init(
        data: Data,
        minimumItemWidth: CGFloat,
        spacing: CGFloat = 16,
        @ViewBuilder content: @escaping (Data.Element) -> Content
    ) {
        self.init(data: data, id: \.id, minimumItemWidth: minimumItemWidth, spacing: spacing, content: content)
    }
}
#endif
