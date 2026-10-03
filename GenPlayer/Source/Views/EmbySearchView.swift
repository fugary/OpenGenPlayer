import SwiftUI

struct EmbySearchView: View {
    let server: ServerConfig
    let library: EmbyLibrary?
    var onExit: (() -> Void)? = nil
    var onPlay: ((EmbyItem) -> Void)? = nil
    let initialQuery: String
    @State private var searchQuery: String
    @State private var searchResults: [EmbyItem] = []
    @State private var isLoading = false
    @Environment(\.presentationMode) private var presentationMode
    
    // Rich Suggestions State
    @State private var searchTask: Task<Void, Never>? = nil
    
    private let embyService = EmbyService.shared

    private var supportsNativeSearchBar: Bool {
        if #available(iOS 15.0, *) {
            return true
        }
        return false
    }

    private var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var displayedSearchResults: [EmbyItem] {
        searchResults.stableUniqued()
    }
    
    init(
        server: ServerConfig,
        library: EmbyLibrary? = nil,
        initialQuery: String = "",
        onExit: (() -> Void)? = nil,
        onPlay: ((EmbyItem) -> Void)? = nil
    ) {
        self.server = server
        self.library = library
        self.initialQuery = initialQuery
        self.onExit = onExit
        self.onPlay = onPlay
        self._searchQuery = State(initialValue: initialQuery)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if !supportsNativeSearchBar {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.system(size: 15))
                    
                    TextField(NSLocalizedString("Search Emby library...", comment: ""), text: $searchQuery)
                        .font(.body)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                
                    if !searchQuery.isEmpty {
                        Button(action: { searchQuery = ""; searchResults = [] }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                                .font(.system(size: 15))
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Color(UIColor.systemGray5))
                .cornerRadius(12)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            
            // Content
            if isLoading {
                Spacer()
                ProgressView()
                    .scaleEffect(1.2)
                Spacer()
            } else if searchResults.isEmpty && !trimmedSearchQuery.isEmpty {
                Spacer()
                VStack(spacing: 16) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary.opacity(0.4))
                    Text(NSLocalizedString("No results found", comment: ""))
                        .font(.headline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            } else if !displayedSearchResults.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Top Suggestions (Rich Inline Suggestions)
                        let topHits = Array(displayedSearchResults.prefix(5))
                        if !topHits.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(NSLocalizedString("Top Suggestions", comment: ""))
                                    .font(.headline)
                                    .padding(.horizontal, 16)
                                    .padding(.top, 8)
                                
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(alignment: .top, spacing: 12) {
                                        ForEach(topHits) { item in
                                            NavigationLink(destination: NavigationLazyView {
                                                embyNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)
                                            }) {
                                                EmbyPosterCard(item: item, server: server, showProgress: false, onPlay: { onPlay?(item) })
                                            }
                                            .buttonStyle(PlainButtonStyle())
                                        }
                                    }
                                    .padding(.horizontal, 16)
                                }
                            }
                            
                            Divider()
                                .padding(.horizontal, 16)
                        }
                        
                        // All Results
                        Text(NSLocalizedString("All Results", comment: ""))
                            .font(.headline)
                            .padding(.horizontal, 16)
                        
                        LazyVStack(spacing: 12) {
                            ForEach(displayedSearchResults) { item in
                                NavigationLink(destination: NavigationLazyView {
                                    embyNavigationDestination(server: server, item: item, onExit: onExit)
                                }) {
                                    EmbyLibraryListRow(item: item, server: server, onPlay: { onPlay?(item) })
                                }
                                .buttonStyle(PlainButtonStyle())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 24)
                }
            } else {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.system(size: 50))
                        .foregroundColor(.secondary.opacity(0.2))
                    Text(NSLocalizedString("Type to search", comment: ""))
                        .foregroundColor(.secondary.opacity(0.5))
                }
                Spacer()
            }
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle(NSLocalizedString("Search", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    AppToolbarIcon(systemName: "chevron.left")
                }
                Button(action: { NavigationUtil.popToRootView() }) {
                    AppToolbarIcon(systemName: "house")
                }
            }
        }
        .customBackButton()
        .compatSearchable(
            text: $searchQuery,
            prompt: NSLocalizedString("Search Emby library...", comment: "")
        )
        .onChange(of: searchQuery) { newValue in
            scheduleSearch(for: newValue)
        }
        .onChange(of: initialQuery) { newValue in
            if searchQuery != newValue {
                searchQuery = newValue
            } else if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && searchResults.isEmpty {
                scheduleSearch(for: newValue, immediate: true)
            }
        }
        .onAppear {
            if !trimmedSearchQuery.isEmpty && searchResults.isEmpty {
                scheduleSearch(for: searchQuery, immediate: true)
            }
        }
        .onDisappear {
            searchTask?.cancel()
        }
    }

    private func scheduleSearch(for rawQuery: String, immediate: Bool = false) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()

        guard !query.isEmpty else {
            isLoading = false
            searchResults = []
            return
        }

        if searchResults.isEmpty || immediate {
            isLoading = true
        }

        searchTask = Task {
            if !immediate {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !Task.isCancelled else { return }
            await performSearch(query: query)
        }
    }

    private func performSearch(query: String) async {
        guard let token = server.accessToken, let userId = server.userId else {
            await MainActor.run {
                isLoading = false
                searchResults = []
            }
            return
        }

        await MainActor.run { isLoading = true }

        do {
            let results: [EmbyItem]
            if let library {
                results = try await embyService.getItems(
                    server: server,
                    userId: userId,
                    token: token,
                    libraryId: library.id,
                    searchTerm: query,
                    sortBy: "SortName",
                    sortOrder: "Ascending",
                    startIndex: 0,
                    limit: 50,
                    recursive: true
                ).items
            } else {
                results = try await embyService.searchItems(server: server, userId: userId, token: token, query: query)
            }
            guard !Task.isCancelled else { return }
            let shouldApplyResults = await MainActor.run {
                searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
            }
            guard shouldApplyResults else { return }
            await MainActor.run {
                searchResults = results
                isLoading = false
            }
        } catch {
            guard !Task.isCancelled else { return }
            let shouldApplyResults = await MainActor.run {
                searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) == query
            }
            guard shouldApplyResults else { return }
            print("Search error: \(error)")
            await MainActor.run { isLoading = false }
        }
    }
}
