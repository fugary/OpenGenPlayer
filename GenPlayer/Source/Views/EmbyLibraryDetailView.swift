import SwiftUI

struct EmbyLibraryDetailView: View {
    let server: ServerConfig
    let library: EmbyLibrary
    var onExit: (() -> Void)? = nil
    var onPlay: ((EmbyItem) -> Void)? = nil
    
    @State private var items: [EmbyItem] = []
    @State private var isLoading = true
    @State private var totalCount = 0
    @State private var errorMessage: String?
    @State private var sortBy = "DateCreated"
    @State private var sortOrder = "Descending"
    @State private var displayMode: LibraryDisplayMode = .poster
    
    @State private var availableGenres: [String] = []
    @State private var availableYears: [String] = []
    @State private var selectedGenre: String? = nil
    @State private var selectedYear: String? = nil
    @ObservedObject private var settings = AppSettings.shared
    @State private var isShowingSearch = false
    @State private var nativeSearchText = ""
    @State private var searchLaunchQuery = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.presentationMode) private var presentationMode
    
    private let embyService = EmbyService.shared
    #if os(iOS)
    @State private var isSearchOverlayActive = false
    @State private var overlaySearchQuery = ""
    @State private var overlaySearchResults: [EmbyItem] = []
    @State private var isOverlaySearching = false
    @State private var overlaySearchTask: Task<Void, Never>? = nil
    #endif
    
    private let sortOptions = [
        ("SortName", NSLocalizedString("Name", comment: "")),
        ("DateCreated", NSLocalizedString("Date Added", comment: "")),
        ("PremiereDate", NSLocalizedString("Release Date", comment: "")),
        ("ProductionYear", NSLocalizedString("Release Year", comment: "")),
        ("CommunityRating", NSLocalizedString("Rating", comment: "")),
        ("Resolution", NSLocalizedString("Resolution", comment: "")),
        ("Runtime", NSLocalizedString("Runtime", comment: ""))
    ]
    
    private var columns: [GridItem] {
        switch displayMode {
        case .poster:
            return MediaCardMetrics.libraryPosterColumns(horizontalSizeClass: horizontalSizeClass)
        case .thumb:
            return MediaCardMetrics.libraryThumbColumns(horizontalSizeClass: horizontalSizeClass)
        case .list:
            return []
        }
    }
    private var gridSpacing: CGFloat { MediaCardMetrics.libraryGridSpacing(horizontalSizeClass: horizontalSizeClass) }
    private var gridPadding: CGFloat { MediaCardMetrics.libraryGridPadding(horizontalSizeClass: horizontalSizeClass) }
    private var posterCardWidth: CGFloat { MediaCardMetrics.libraryPosterWidth(horizontalSizeClass: horizontalSizeClass) }
    private var thumbCardWidth: CGFloat { MediaCardMetrics.libraryThumbWidth(horizontalSizeClass: horizontalSizeClass) }
    
    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                if !availableGenres.isEmpty || !availableYears.isEmpty {
                    LibraryFilterBar(
                        availableGenres: availableGenres,
                        availableYears: availableYears,
                        selectedGenre: Binding(
                            get: { selectedGenre },
                            set: { newValue in
                                if selectedGenre != newValue {
                                    selectedGenre = newValue
                                    Task { await loadLibraryItems() }
                                }
                            }
                        ),
                        selectedYear: Binding(
                            get: { selectedYear },
                            set: { newValue in
                                if selectedYear != newValue {
                                    selectedYear = newValue
                                    Task { await loadLibraryItems() }
                                }
                            }
                        )
                    )
                    .background(Color(UIColor.systemBackground))
                    Divider()
                }
                
                ScrollView {
                    switch displayMode {
                    case .poster:
                        MediaLibraryCardGrid(columns: columns, spacing: gridSpacing, legacyCardWidth: posterCardWidth) { columnWidth in
                            ForEach(items) { item in
                                NavigationLink(destination: embyNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                                    EmbyPosterCard(item: item, server: server, showProgress: true, cardWidth: columnWidth, onPlay: { onPlay?(item) })
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, gridPadding)
                        .padding(.vertical, gridPadding)
                    case .thumb:
                        LazyVGrid(columns: columns, spacing: gridSpacing) {
                            ForEach(items) { item in
                                NavigationLink(destination: embyNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                                    EmbyThumbCard(item: item, server: server, showProgress: true, cardWidth: nil, onPlay: { onPlay?(item) })
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                        .padding(.horizontal, gridPadding)
                        .padding(.vertical, gridPadding)
                    case .list:
                        LazyVStack(spacing: 12) {
                            ForEach(items) { item in
                                NavigationLink(destination: embyNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)) {
                                    EmbyLibraryListRow(item: item, server: server, onPlay: { onPlay?(item) })
                                }
                                .buttonStyle(PlainButtonStyle())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                        }
                        .padding()
                    }

                    if !isLoading && !items.isEmpty && totalCount > 0 {
                        Text(MediaCountFormatter.formatTotal(count: totalCount, libraryType: library.libraryType))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 20)
                    }

                } // close ScrollView
            } // close VStack
            
            if isLoading {
                ProgressView()
                    .scaleEffect(1.2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(library.name)
        .navigationBarTitleDisplayMode(.inline)
        .libraryChildNavigationBarCompat()
        #if os(iOS)
        .modifier(inlineSearch)
        .onChange(of: overlaySearchQuery) { newQuery in
            scheduleOverlaySearch(for: newQuery)
        }
        .onDisappear {
            overlaySearchTask?.cancel()
        }
        #endif
        .background(
            NavigationLink(
                destination: NavigationLazyView {
                    EmbySearchView(server: server, library: library, initialQuery: searchLaunchQuery, onExit: onExit, onPlay: onPlay)
                },
                isActive: $isShowingSearch,
                label: { EmptyView() }
            )
        )
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    AppToolbarIcon(systemName: "chevron.left")
                }
                Button(action: {
                    NavigationUtil.popToRootView()
                }) {
                    AppToolbarIcon(systemName: "house")
                }
            }
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                #if os(iOS)
                searchToolbarControl
                #else
                Button(action: {
                    isShowingSearch = true
                }) {
                    AppToolbarIcon(systemName: "magnifyingglass")
                }
                #endif
                    
                Menu {
                    ForEach(LibraryDisplayMode.allCases) { mode in
                        Button(action: { setDisplayMode(mode) }) {
                            sortMenuRow(title: mode.localizedTitle, isSelected: displayMode == mode)
                        }
                    }
                } label: {
                    AppToolbarIcon(systemName: displayMode.iconName)
                }

                Menu {
                    Section(header: Text(NSLocalizedString("Sort By", comment: ""))) {
                        ForEach(sortOptions, id: \.0) { option in
                            Button(action: {
                                updateSortField(option.0)
                            }) {
                                sortMenuRow(title: option.1, isSelected: sortBy == option.0)
                            }
                        }
                    }

                    Section(header: Text(NSLocalizedString("Sort Order", comment: ""))) {
                        Button(action: {
                            updateSortOrder("Ascending")
                        }) {
                            sortMenuRow(
                                title: NSLocalizedString("Ascending", comment: ""),
                                isSelected: sortOrder == "Ascending"
                            )
                        }
                        Button(action: {
                            updateSortOrder("Descending")
                        }) {
                            sortMenuRow(
                                title: NSLocalizedString("Descending", comment: ""),
                                isSelected: sortOrder == "Descending"
                            )
                        }
                    }
                } label: {
                    AppToolbarIcon(systemName: "line.3.horizontal.decrease.circle")
                }

                if PlatformHelper.isRunningOnMac {
                    Button(action: {
                        Task { await loadLibraryItems() }
                    }) {
                        AppToolbarIcon(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .hideNavigationBarBackground()
        .customBackButton()
        .onAppear {
            loadSavedSortPreference()
            loadSavedDisplayMode()
            Task { await loadFilterOptions() }
            if items.isEmpty {
                Task { await loadLibraryItems() }
            }
        }
    }
    
    @ViewBuilder
    private func sortMenuRow(title: String, isSelected: Bool) -> some View {
        HStack {
            Text(title)
            if isSelected {
                Image(systemName: "checkmark")
            }
        }
    }

    private func updateSortField(_ newSortBy: String) {
        guard sortBy != newSortBy else { return }
        sortBy = newSortBy
        if newSortBy == "SortName" && sortOrder != "Ascending" {
            sortOrder = "Ascending"
        }
        if newSortBy != "SortName" && sortOrder != "Descending" {
            sortOrder = "Descending"
        }
        persistSortPreferenceAndReload()
    }

    private func updateSortOrder(_ newSortOrder: String) {
        guard sortOrder != newSortOrder else { return }
        sortOrder = newSortOrder
        persistSortPreferenceAndReload()
    }

    private func persistSortPreferenceAndReload() {
        settings.saveLibrarySortPreference(
            provider: "emby",
            serverId: server.id.uuidString,
            libraryId: library.id,
            sortBy: sortBy,
            sortOrder: sortOrder
        )
        Task { await loadLibraryItems() }
    }

    private func loadSavedSortPreference() {
        let saved = settings.librarySortPreference(
            provider: "emby",
            serverId: server.id.uuidString,
            libraryId: library.id,
            defaultSortBy: sortBy,
            defaultSortOrder: sortOrder
        )
        sortBy = saved.sortBy
        sortOrder = saved.sortOrder
    }

    private func loadSavedDisplayMode() {
        displayMode = settings.libraryDisplayModeEnum(
            provider: "emby",
            serverId: server.id.uuidString,
            libraryId: library.id,
            defaultMode: .poster
        )
    }

    private func setDisplayMode(_ mode: LibraryDisplayMode) {
        displayMode = mode
        settings.saveLibraryDisplayMode(
            provider: "emby",
            serverId: server.id.uuidString,
            libraryId: library.id,
            mode: mode
        )
    }

    private func loadLibraryItems() async {
        guard let token = server.accessToken, let userId = server.userId else { return }
        
        do {
            let itemsResponse = try await embyService.getItems(
                server: server,
                userId: userId,
                token: token,
                libraryId: library.id,
                includeTypes: library.libraryType.browseIncludeTypes,
                sortBy: serverSortBy,
                sortOrder: sortOrder,
                genres: selectedGenre,
                years: selectedYear,
                startIndex: 0,
                limit: 1000
            )
            
            await MainActor.run {
                self.items = sortedItems(itemsResponse.items)
                self.totalCount = itemsResponse.totalRecordCount ?? self.items.count
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }
    
    private func loadFilterOptions() async {
        guard let token = server.accessToken else { return }
        do {
            let (genres, years) = try await embyService.getLibraryFilterOptions(
                server: server,
                token: token,
                parentId: library.id
            )
            await MainActor.run {
                self.availableGenres = genres
                self.availableYears = years
            }
        } catch {
            print("Error loading Emby filter options: \(error)")
        }
    }

    private var usesLocalSort: Bool {
        sortBy == "Resolution" || sortBy == "PremiereDate" || sortBy == "ProductionYear"
    }

    private var serverSortBy: String {
        sortBy == "Resolution" ? "SortName" : sortBy
    }

    private func sortedItems(_ loadedItems: [EmbyItem]) -> [EmbyItem] {
        switch sortBy {
        case "Resolution":
            return sortedItems(loadedItems) { item in
                let pixels = item.bestVideoPixelCount
                return pixels > 0 ? pixels : nil
            }
        case "PremiereDate":
            return sortedItems(loadedItems) { $0.premiereDateSortValue }
        case "ProductionYear":
            return sortedItems(loadedItems) { $0.productionYearSortValue }
        default:
            return loadedItems
        }
    }

    private func sortedItems(
        _ loadedItems: [EmbyItem],
        value: (EmbyItem) -> Int?
    ) -> [EmbyItem] {
        let isAscending = sortOrder == "Ascending"
        return loadedItems.sorted { lhs, rhs in
            let lhsValue = value(lhs)
            let rhsValue = value(rhs)
            if let lhsValue, let rhsValue, lhsValue != rhsValue {
                return isAscending ? lhsValue < rhsValue : lhsValue > rhsValue
            }
            if lhsValue != nil && rhsValue == nil {
                return true
            }
            if lhsValue == nil && rhsValue != nil {
                return false
            }
            return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
        }
    }

    #if os(iOS)
    @ViewBuilder
    private var searchToolbarControl: some View {
        if #unavailable(iOS 26.0) {
            Button { isSearchOverlayActive = true } label: {
                AppToolbarIcon(systemName: "magnifyingglass")
            }
            .accessibilityLabel(NSLocalizedString("Search", comment: ""))
        }
    }

    private func submitInlineSearch(_ submitted: String) {
        let key = "\(server.id.uuidString)_\(library.id)"
        SearchHistoryService.shared.addHistory(submitted, for: key)
        scheduleOverlaySearch(for: submitted, immediate: true)
    }

    private var inlineSearch: some ViewModifier {
        LibraryInlineSearchModifier(
            isPresented: $isSearchOverlayActive,
            query: $overlaySearchQuery,
            placeholder: NSLocalizedString("Search in library...", comment: ""),
            serverId: "\(server.id.uuidString)_\(library.id)",
            onSubmit: submitInlineSearch
        ) {
            embySearchOverlayResults
        }
    }

    @ViewBuilder
    private var embySearchOverlayResults: some View {
        if isOverlaySearching {
            VStack(spacing: 16) {
                Spacer(minLength: 40)
                ProgressView()
                    .scaleEffect(1.2)
                Text(NSLocalizedString("Searching...", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        } else if overlaySearchResults.isEmpty && !overlaySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(spacing: 12) {
                Spacer(minLength: 40)
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 36))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                Text(NSLocalizedString("No Results Found", comment: ""))
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer(minLength: 40)
            }
            .frame(maxWidth: .infinity)
        } else {
            let topHits = Array(overlaySearchResults.prefix(10))
            VStack(alignment: .leading, spacing: 20) {
                if !topHits.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(NSLocalizedString("Top Hits", comment: ""))
                            .font(.headline)
                            .padding(.horizontal, 16)

                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 12) {
                                ForEach(topHits) { item in
                                    NavigationLink(destination: NavigationLazyView {
                                        embyNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)
                                    }) {
                                        EmbyPosterCard(item: item, server: server, showProgress: true, cardWidth: posterCardWidth, onPlay: { onPlay?(item) })
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

                if !overlaySearchResults.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(NSLocalizedString("All Results", comment: ""))
                            .font(.headline)
                            .padding(.horizontal, 16)

                        LazyVStack(spacing: 12) {
                            ForEach(overlaySearchResults) { item in
                                NavigationLink(destination: NavigationLazyView {
                                    embyNavigationDestination(server: server, item: item, onExit: onExit, onPlay: onPlay)
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
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 24)
        }
    }

    private func scheduleOverlaySearch(for rawQuery: String, immediate: Bool = false) {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        overlaySearchTask?.cancel()

        guard !query.isEmpty else {
            overlaySearchResults = []
            isOverlaySearching = false
            return
        }

        let delay: UInt64 = immediate ? 0 : 300_000_000
        isOverlaySearching = true

        overlaySearchTask = Task {
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }

            do {
                guard let token = server.accessToken,
                      let userId = server.userId else {
                    await MainActor.run {
                        self.isOverlaySearching = false
                    }
                    return
                }

                let response = try await embyService.getItems(
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
                )

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.overlaySearchResults = response.items.stableUniqued()
                    self.isOverlaySearching = false
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isOverlaySearching = false
                }
            }
        }
    }
    #endif
}

struct EmbyLibraryListRow: View {
    let item: EmbyItem
    let server: ServerConfig
    @ObservedObject private var offlineIndex = OfflineMediaIndexStore.shared
    var onPlay: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: item.primaryImageURL(server: server, maxWidth: 240))
                .aspectRatio(2/3, contentMode: .fill)
                .frame(width: 72, height: 108)
                .cornerRadius(8)
                .clipped()

            VStack(alignment: .leading, spacing: 7) {
                Text(item.displayTitle)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundColor(.primary)

                if let subtitle = displaySubtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if hasMetadata {
                    HStack(spacing: 8) {
                        if isDownloaded {
                            Image(systemName: "arrow.down.circle.fill")
                                .foregroundColor(.green)
                        }

                        if let year = item.productionYear {
                            Text(String(year))
                        }

                        if let runtime = runtimeText {
                            Text(runtime)
                        }

                        if let rating = item.communityRating, rating > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.caption2)
                                    .foregroundColor(.yellow)
                                Text(String(format: "%.1f", rating))
                            }
                        }

                        if let resolution = resolutionText {
                            Text(resolution)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15))
                                .cornerRadius(3)
                        }

                        if let fileSize = fileSizeText {
                            Text(fileSize)
                        }

                        if let officialRating = item.officialRating, !officialRating.isEmpty {
                            Text(officialRating)
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(Color.secondary.opacity(0.45), lineWidth: 0.6)
                                )
                        }

                        if let episodeCode = episodeCodeText {
                            Text(episodeCode)
                        }

                        if let countText = childCountText {
                            Text(countText)
                        }
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }

                if let summary = summaryText {
                    Text(summary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                if let progress = item.userData?.playedPercentage, progress > 0 {
                    ProgressView(value: progress / 100.0)
                        .progressViewStyle(LinearProgressViewStyle(tint: .accentColor))
                        .frame(maxWidth: 180)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .foregroundColor(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
        .contentShape(Rectangle())
        .modifier(EmbyMediaContextMenuModifier(item: item, server: server, onPlay: onPlay))
    }

    private var cleanedOverview: String? {
        guard let text = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private var summaryText: String? {
        if let overview = cleanedOverview {
            return overview
        }

        if let genres = item.genres, !genres.isEmpty {
            return genres.joined(separator: " / ")
        }

        return nil
    }

    private var displaySubtitle: String? {
        guard let subtitle = item.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !subtitle.isEmpty else {
            return nil
        }
        if let year = item.productionYear, subtitle == String(year) {
            return nil
        }
        return subtitle
    }

    private var hasMetadata: Bool {
        item.productionYear != nil ||
        runtimeText != nil ||
        ((item.communityRating ?? 0) > 0) ||
        resolutionText != nil ||
        fileSizeText != nil ||
        (item.officialRating?.isEmpty == false) ||
        episodeCodeText != nil ||
        childCountText != nil
    }

    private var runtimeText: String? {
        guard let ticks = item.runTimeTicks, ticks > 0 else { return nil }
        let totalMinutes = Int(ticks / 10_000_000 / 60)
        guard totalMinutes > 0 else { return nil }

        if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            if minutes == 0 {
                return "\(hours)h"
            }
            return "\(hours)h \(minutes)m"
        }
        return "\(totalMinutes)m"
    }

    private var resolutionText: String? {
        item.videoResolutionLabel
    }

    private var fileSizeText: String? {
        guard let size = item.mediaSources?.first?.size, size > 0 else { return nil }
        return formatBytes(size)
    }

    private var episodeCodeText: String? {
        guard item.type == "Episode",
              let season = item.parentIndexNumber,
              let episode = item.indexNumber else {
            return nil
        }
        return "S\(String(format: "%02d", season))E\(String(format: "%02d", episode))"
    }

    private var childCountText: String? {
        if item.type == "Series" {
            if let seasons = item.childCount, seasons > 0 {
                return seasons == 1 ? "1 \(NSLocalizedString("Season", comment: ""))" : "\(seasons) \(NSLocalizedString("Seasons", comment: ""))"
            }
            if let episodes = item.recursiveItemCount, episodes > 0 {
                return episodes == 1 ? String(format: NSLocalizedString("%d Episode", comment: ""), 1) : String(format: NSLocalizedString("%d Episodes", comment: ""), episodes)
            }
        }
        if item.type == "Season", let episodes = item.childCount, episodes > 0 {
            return episodes == 1 ? String(format: NSLocalizedString("%d Episode", comment: ""), 1) : String(format: NSLocalizedString("%d Episodes", comment: ""), episodes)
        }
        if (item.type == "Playlist" || item.type == "BoxSet" || item.type == "Folder" || item.type == "MusicAlbum"),
           let count = item.childCount ?? item.recursiveItemCount,
           count > 0 {
            return count == 1 ? "1 \(NSLocalizedString("Item", comment: ""))" : "\(count) \(NSLocalizedString("Items", comment: ""))"
        }
        return nil
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    private var isDownloaded: Bool {
        offlineIndex.isDownloaded(serverId: server.id, remoteItemId: item.id)
    }
}
