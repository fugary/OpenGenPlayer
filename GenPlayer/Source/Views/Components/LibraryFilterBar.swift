import SwiftUI

struct LibraryFilterBar: View {
    let availableGenres: [String]
    let availableYears: [String]
    
    @Binding var selectedGenre: String?
    @Binding var selectedYear: String?
    
    // Using a horizontal scroll view for the chips to save vertical space on iPhones.
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !availableGenres.isEmpty {
                FilterSection(
                    label: NSLocalizedString("Genre", comment: "Filter label"),
                    allTitle: NSLocalizedString("All", comment: "Filter all option"),
                    items: availableGenres,
                    selectedItem: $selectedGenre,
                    displayName: { NSLocalizedString($0, comment: "Genre translation") }
                )
            }
            if !availableYears.isEmpty {
                FilterSection(
                    label: NSLocalizedString("Year", comment: "Filter label"),
                    allTitle: NSLocalizedString("All", comment: "Filter all option"),
                    items: availableYears,
                    selectedItem: $selectedYear,
                    displayName: { $0 }
                )
            }
        }
        .padding(.vertical, 8)
    }
}

private struct FilterSection: View {
    let label: String
    let allTitle: String
    let items: [String]
    @Binding var selectedItem: String?
    let displayName: (String) -> String
    
    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.leading, 16)
            
            FilterChip(
                title: allTitle,
                isSelected: selectedItem == nil,
                action: { selectedItem = nil }
            )
            
            Divider()
                .frame(height: 16)
                .padding(.horizontal, 2)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.self) { item in
                        FilterChip(
                            title: displayName(item),
                            isSelected: selectedItem == item,
                            action: { selectedItem = item }
                        )
                    }
                }
                .padding(.trailing, 16)
            }
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.primary : Color(UIColor.secondarySystemFill))
                )
                .foregroundColor(isSelected ? Color(UIColor.systemBackground) : .primary)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
}
