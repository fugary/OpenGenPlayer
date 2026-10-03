import SwiftUI
import GenPlayerCore

struct RecentSearchesSection: View {
    let serverId: String
    let onSelectQuery: (String) -> Void

    init(serverId: String, onSelectQuery: @escaping (String) -> Void) {
        self.serverId = serverId
        self.onSelectQuery = onSelectQuery
    }

    init(serverId: UUID, onSelectQuery: @escaping (String) -> Void) {
        self.init(serverId: serverId.uuidString, onSelectQuery: onSelectQuery)
    }

    @ObservedObject private var historyService = SearchHistoryService.shared

    private var queries: [String] {
        historyService.historyByServer[serverId] ?? []
    }

    var body: some View {
        VStack(spacing: 0) { historyContent }
            .onAppear {
                // Loading publishes the cache; keep that mutation out of body evaluation.
                _ = historyService.getHistory(for: serverId)
            }
    }

    @ViewBuilder
    private var historyContent: some View {
        if !queries.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                // Header row: Title + Clear All button
                HStack {
                    Text(NSLocalizedString("Recent Searches", comment: ""))
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Spacer()

                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            historyService.clearHistory(for: serverId)
                        }
                    }) {
                        Text(NSLocalizedString("Clear All", comment: ""))
                            .font(.subheadline)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(BorderlessButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)

                // List of recent query rows
                VStack(spacing: 0) {
                    ForEach(queries, id: \.self) { query in
                        HStack(spacing: 12) {
                            Image(systemName: "clock")
                                .font(.system(size: 15))
                                .foregroundColor(.secondary)
                                .frame(width: 20)

                            Text(query)
                                .font(.body)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    historyService.removeHistory(query, for: serverId)
                                }
                            }) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color(UIColor.tertiaryLabel))
                                    .padding(6)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            onSelectQuery(query)
                        }

                        Divider()
                            .padding(.leading, 48)
                            .padding(.trailing, 16)
                    }
                }
            }
        }
    }
}
