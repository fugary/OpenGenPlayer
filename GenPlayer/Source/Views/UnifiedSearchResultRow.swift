import SwiftUI

struct UnifiedSearchResultRow: View {
    let title: String
    let overview: String?
    let year: Int?
    let type: String?
    let imageUrl: URL?
    
    var body: some View {
        HStack(spacing: 12) {
            // Poster
            RemoteImage(url: imageUrl)
                .aspectRatio(2/3, contentMode: .fill)
                .frame(width: 60, height: 90)
                .cornerRadius(6)
                .clipped()
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
            
            VStack(alignment: .leading, spacing: 4) {
                // Title - Uses primary color for visibility in all modes
                Text(title)
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundColor(.primary)
                    .lineLimit(2)
                
                // Metadata Line
                HStack(spacing: 8) {
                    if let year = year {
                        Text("\(year)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    
                    if let type = type {
                        Text(type)
                            .font(.caption)
                            .fontWeight(.medium)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.05))
                            .foregroundColor(.secondary)
                            .cornerRadius(4)
                    }
                }
                
                // Overview
                if let overview = overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            
            Spacer()
            
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.secondary.opacity(0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
