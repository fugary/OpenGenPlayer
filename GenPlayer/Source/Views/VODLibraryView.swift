import SwiftUI
import GenPlayerCore
import GenPlayerShell

public struct VODLibraryView: View {
    public let server: ServerConfig
    public let onExit: (() -> Void)?

    @StateObject private var catalog = VODCatalog()
    @StateObject private var searchCatalog = VODCatalog()
    @State private var showSourceEditor = false
    private var activeCatalog: VODCatalog { showsSearchResults ? searchCatalog : catalog }
    @ObservedObject private var network = AppNetworkService.shared
    @State private var selectedCategoryId = "ALL"
    @State private var rootCategoryID: String?
    @State private var rootCategoryName: String?
    @State private var destinationCategory: VODCatalog.Category?
    private var isHome: Bool { rootCategoryID == nil }
    private var showsSearchResults: Bool { isSearchMode && !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @State private var searchText = ""
    @State private var isSearchMode = false
    @State private var searchTask: Task<Void, Never>?
    @State private var selectedItemForDetail: VODCatalogGroup?
    @State private var sort = "Default"
    @State private var homeHeaderOffset: CGFloat = 0
    private var usesFullBleedHome: Bool { isHome && !catalog.groups.isEmpty }
    private var useLightToolbar: Bool {
        if #unavailable(iOS 26.0), isSearchMode { return false }
        return usesFullBleedHome && !showsSearchResults && homeHeaderOffset >= -navigationBarInset - 30
    }
    private var toolbarColor: Color { useLightToolbar ? .white : Color(UIColor.label) }
    private var navigationBarInset: CGFloat {
        UIApplication.currentSafeAreaInsets().top + (UIDevice.current.userInterfaceIdiom == .pad ? 50 : 44)
    }
    private var owner: ServerConfig { network.servers.first { $0.id == server.id } ?? server }
    private var categories: [VODCategory] { catalog.categories.filter { rootCategoryID == nil || $0.parentKeys.contains(rootCategoryID!) }.map { VODCategory(typeId: $0.id, typeName: platformShellString($0.name)) } }
    private var items: [VODCatalogGroup] { catalog.groups }
    private var searchResults: [VODCatalogGroup] { searchCatalog.groups }
    private var isLoading: Bool { catalog.loading }
    private var isSearching: Bool { isSearchMode && searchCatalog.loading }
    private var isLoadingMore: Bool { catalog.loading && !catalog.groups.isEmpty }
    private var isLoadingSearchPage: Bool { searchCatalog.loading && !searchCatalog.groups.isEmpty }
    private var errorMessage: String? { catalog.errors.first }

    // Layout
    @AppStorage("vod_library_is_grid") private var legacyGrid: Bool = true
    @AppStorage("vod_library_display_mode") private var displayModeRaw = ""
    @AppStorage("vod_library_sort_ascending") private var ascending = true
    private var displayMode: LibraryDisplayMode {
        LibraryDisplayMode(rawValue: displayModeRaw) ?? (legacyGrid ? .poster : .list)
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    public init(server: ServerConfig, onExit: (() -> Void)? = nil) {
        self.server = server
        self.onExit = onExit
    }

    private init(server: ServerConfig, category: VODCatalog.Category, onExit: (() -> Void)?) {
        self.server = server
        self.onExit = onExit
        _rootCategoryID = State(initialValue: category.id)
        _rootCategoryName = State(initialValue: category.name)
        _selectedCategoryId = State(initialValue: category.id)
    }

    private var displayedItems: [VODCatalogGroup] {
        guard sort != "Default" else { return activeCatalog.groups }
        return activeCatalog.groups.sorted { lhs, rhs in
            let comparison: ComparisonResult
            if sort == "Release Year" {
                let left = Int(lhs.item.vodYear ?? "") ?? 0, right = Int(rhs.item.vodYear ?? "") ?? 0
                comparison = left == right ? .orderedSame : left < right ? .orderedAscending : .orderedDescending
            } else { comparison = lhs.item.vodName.localizedStandardCompare(rhs.item.vodName) }
            if comparison == .orderedSame { return lhs.id < rhs.id }
            return comparison == (ascending ? .orderedAscending : .orderedDescending)
        }
    }

    private var gridColumns: [GridItem] {
        displayMode == .thumb
            ? MediaCardMetrics.libraryThumbColumns(horizontalSizeClass: horizontalSizeClass)
            : MediaCardMetrics.libraryPosterColumns(horizontalSizeClass: horizontalSizeClass)
    }
    private var gridSpacing: CGFloat { MediaCardMetrics.libraryGridSpacing(horizontalSizeClass: horizontalSizeClass) }
    private var gridPadding: CGFloat { MediaCardMetrics.libraryGridPadding(horizontalSizeClass: horizontalSizeClass) }
    private var cardWidth: CGFloat {
        (!isHome || showsSearchResults) && displayMode == .thumb ? MediaCardMetrics.libraryThumbWidth(horizontalSizeClass: horizontalSizeClass)
            : MediaCardMetrics.libraryPosterWidth(horizontalSizeClass: horizontalSizeClass)
    }
    private var artworkHeight: CGFloat { (!isHome || showsSearchResults) && displayMode == .thumb ? cardWidth * 9 / 16 : cardWidth * 1.5 }

    public var body: some View {
        VStack(spacing: 0) {
            // MARK: - Category Selector
            if rootCategoryID != nil {
                categorySelectorView
                    .padding(.vertical, 6)
                    .background(Color(UIColor.systemBackground))
            }

            // MARK: - Main Content
            ZStack {
                Color(UIColor.systemBackground).ignoresSafeArea()

                if isLoading && items.isEmpty && (!isHome || catalog.categories.isEmpty) {
                    loadingView

                } else if isHome && !catalog.categories.isEmpty {
                    homeContent
                } else if let error = errorMessage, items.isEmpty {
                    errorView(error)
                } else if catalog.groups.isEmpty {
                    emptyView
                } else if isHome {
                    homeContent
                } else {
                    contentScrollView
                }
            }
        }
        .ignoresSafeArea(edges: usesFullBleedHome ? [.top, .horizontal] : [])
        .modifier(LibraryInlineSearchModifier(isPresented: $isSearchMode, query: $searchText,
            placeholder: NSLocalizedString("Search in VOD", comment: ""), serverId: server.id.uuidString,
            onSubmit: { query in
                SearchHistoryService.shared.addHistory(query, for: server.id)
                searchTask?.cancel()
                reloadSearch()
            }) { searchContent })
        .refreshableCompat {
            await MainActor.run { refreshData() }
        }
        .navigationBarTitle(Text(""), displayMode: .inline)
        .navigationBarBackButtonHidden(true)
        .navBarTransparentCompat(isTransparent: useLightToolbar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 6) {
                    ServerTypeIconMark(type: server.type, size: 18)
                    Text(isSearchMode ? NSLocalizedString("Search", comment: "") : owner.name)
                        .font(.headline)
                        .lineLimit(1)
                }
                .foregroundColor(toolbarColor)
            }
            if rootCategoryID != nil {
                ToolbarItemGroup(placement: .navigation) {
                    Button { dismiss() } label: {
                        AppToolbarIcon(systemName: "chevron.left")
                    }
                    Button { NavigationUtil.popToRootView() } label: {
                        AppToolbarIcon(systemName: "house")
                    }
                }
            } else {
                ToolbarItem(placement: .cancellationAction) {
                    if let onExit = onExit {
                        Button(action: onExit) {
                            AppToolbarIcon.serverExit(
                                legacyStyle: .secondary,
                                legacyForegroundColor: toolbarColor
                            )
                        }
                    }
                }
            }

            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if #unavailable(iOS 26.0) {
                    Button { isSearchMode.toggle() } label: {
                        AppToolbarIcon(systemName: "magnifyingglass", legacyForegroundColor: toolbarColor)
                    }
                }

                if !isHome || showsSearchResults {
                    Menu {
                        ForEach(LibraryDisplayMode.allCases) { mode in
                            Button { displayModeRaw = mode.rawValue } label: {
                                menuRow(mode.localizedTitle, selected: displayMode == mode)
                            }
                        }
                    } label: { AppToolbarIcon(systemName: displayMode.iconName) }
                    .accessibilityLabel(NSLocalizedString("Display Mode", comment: ""))

                    Menu {
                        Section(header: Text(NSLocalizedString("Sort By", comment: ""))) {
                            ForEach(["Default", "Name", "Release Year"], id: \.self) { value in
                                Button { sort = value; ascending = value != "Release Year" } label: {
                                    menuRow(NSLocalizedString(value, comment: ""), selected: sort == value)
                                }
                            }
                        }
                        if sort != "Default" {
                            Section(header: Text(NSLocalizedString("Sort Order", comment: ""))) {
                                Button { ascending = true } label: { menuRow(NSLocalizedString("Ascending", comment: ""), selected: ascending) }
                                Button { ascending = false } label: { menuRow(NSLocalizedString("Descending", comment: ""), selected: !ascending) }
                            }
                        }
                    } label: { AppToolbarIcon(systemName: "line.3.horizontal.decrease.circle") }
                    .accessibilityLabel(NSLocalizedString("Sort By", comment: ""))
                }

                Button { showSourceEditor = true } label: {
                    AppToolbarIcon(systemName: "slider.horizontal.3", legacyForegroundColor: toolbarColor)
                }
                .accessibilityLabel(platformShellString("Manage VOD Sources"))

            }
        }
        .background(
            NavigationLink(
                destination: Group {
                    if let item = selectedItemForDetail {
                        VODGroupDetailView(owner: owner, group: item)
                    }
                },
                isActive: Binding(
                    get: { selectedItemForDetail != nil },
                    set: { if !$0 { selectedItemForDetail = nil } }
                )
            ) {
                EmptyView()
            }
            .hidden()
        )
        .background(NavigationLink(isActive: Binding(
            get: { destinationCategory != nil }, set: { if !$0 { destinationCategory = nil } }
        )) {
            if let category = destinationCategory {
                VODLibraryView(server: owner, category: category, onExit: onExit)
            }
        } label: { EmptyView() }.hidden())
        .sheet(isPresented: $showSourceEditor) {
            AddServerView(networkService: network, existingServer: owner)
        }
        .onChange(of: searchText) { triggerSearch(keyword: $0) }
        .onChange(of: isSearchMode) { if !$0 { cancelSearch() } }
        .onAppear {
            if catalog.groups.isEmpty { reload() }
            if showsSearchResults && searchCatalog.groups.isEmpty { reloadSearch() }
        }
        .onDisappear { searchTask?.cancel(); catalog.cancel(); searchCatalog.cancel() }
        .onChange(of: catalog.revision) { _ in
            guard let name = rootCategoryName else { return }
            guard let root = catalog.categories.first(where: { VODCatalog.categoryKey($0.name) == VODCatalog.categoryKey(name) }) else {
                dismiss()
                return
            }
            rootCategoryID = root.id
            selectedCategoryId = catalog.resolvedCategoryID ?? root.id
        }
        .onChange(of: owner.vodSources) { _ in
            reload(force: true)
            if showsSearchResults { reloadSearch() }
        }
    }

    private var homeShelfPadding: CGFloat {
        MediaCardMetrics.libraryShelfPadding(horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass)
    }

    private var homeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // A fixed top marker survives lazy shelf recycling while scrolling.
                Color.clear.frame(height: 0).background(GeometryReader { proxy in
                    Color.clear.preference(key: VODHomeOffsetKey.self,
                        value: proxy.frame(in: .named("vodHomeScroll")).minY)
                })
                VStack(alignment: .leading, spacing: 20) {
                    MediaHomeCarouselView(items: Array(catalog.groups.prefix(6)).map { group in
                        let item = group.item
                        let image = item.vodPic.flatMap(URL.init(string:))
                        return MediaHomeCarouselItem(id: group.id, title: item.vodName, subtitle: nil,
                            metadataSegments: [item.vodYear, item.typeName, item.vodRemarks].compactMap { $0 }.filter { !$0.isEmpty && $0 != "0" }, overview: item.cleanSynopsis,
                            sourceTitle: owner.name, sourceSystemImage: "film.stack", imageURL: image,
                            backdropImageURL: nil, portraitImageURL: image, logoURLs: nil,
                            actionTitle: NSLocalizedString("View Details", comment: ""), actionSystemImage: "info.circle", playbackProgress: nil)
                    }, pausesWhenInactive: true,
                       isActive: !isSearchMode && selectedItemForDetail == nil && destinationCategory == nil && !showSourceEditor) { entry in selectedItemForDetail = catalog.groups.first { $0.id == entry.id } }
                    if !catalog.errors.isEmpty {
                        Button { reload(force: true) } label: {
                            Label(NSLocalizedString("Retry", comment: ""), systemImage: "arrow.clockwise")
                        }
                        .padding(.horizontal, 16)
                        .mediaLibraryHorizontalSafeAreaPadding(isEnabled: usesFullBleedHome)
                    }
                    LazyVStack(alignment: .leading, spacing: 20) {
                        ForEach(catalog.categories.filter(\.isRoot)) { category in
                            IOSVODHomeShelf(owner: owner, category: category, parent: catalog, horizontalPadding: homeShelfPadding, onOpen: {
                                destinationCategory = category
                            }) { group in gridCard(for: group, forcePoster: true) }
                        }
                    }
                    .mediaLibraryHorizontalSafeAreaPadding(isEnabled: usesFullBleedHome)

                }
            }
            // Match the library carousel's full-bleed navigation inset.
            .padding(.top, usesFullBleedHome ? -navigationBarInset : 0)
            .padding(.bottom, 24)
        }
        .coordinateSpace(name: "vodHomeScroll")
        .onPreferenceChange(VODHomeOffsetKey.self) { value in
            if value.isFinite { homeHeaderOffset = value }
        }
    }

    // MARK: - Category Selector View

    private var categorySelectorView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryPill(title: NSLocalizedString("All", comment: ""), id: rootCategoryID ?? "ALL")

                ForEach(categories) { cat in
                    categoryPill(title: cat.typeName, id: cat.id)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func categoryPill(title: String, id: String) -> some View {
        let isSelected = selectedCategoryId == id
        return Button(action: {
            guard selectedCategoryId != id else { return }
            selectedCategoryId = id
            reload()
        }) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                .foregroundColor(isSelected ? .white : .primary)
                .padding(.horizontal, gridPadding)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(UIColor.secondarySystemFill))
                .cornerRadius(16)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var searchContent: some View {
        if searchCatalog.loading && searchCatalog.groups.isEmpty {
            loadingView
        } else if searchCatalog.groups.isEmpty, let error = searchCatalog.errors.first {
            errorView(error)
        } else if searchCatalog.groups.isEmpty {
            emptyView
        } else { resultContent }
    }

    // MARK: - Content Scroll View

    private var contentScrollView: some View {
        ScrollView { resultContent }
    }

    private var resultContent: some View {
            LazyVStack(spacing: 0) {
                Group {
                    HStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up")
                        Text(String(format: platformShellString("Loaded %d items"), activeCatalog.groups.count))
                        Spacer()

                    }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }

                if displayMode != .list {
                    MediaLibraryCardGrid(columns: gridColumns, spacing: gridSpacing, legacyCardWidth: cardWidth) { columnWidth in
                        ForEach(displayedItems) { item in
                            gridCard(for: item, columnWidth: columnWidth)
                                .onAppear {
                                    handleItemAppear(item)
                                }
                        }
                    }
                    .padding(.horizontal, gridPadding)
                    .padding(.vertical, gridPadding)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(displayedItems) { item in
                            listRow(for: item)
                                .onAppear {
                                    handleItemAppear(item)
                                }
                        }
                    }
                    .padding(.horizontal, gridPadding)
                    .padding(.vertical, gridPadding)
                }

                if activeCatalog.hasMore && !activeCatalog.loading {
                    Button(NSLocalizedString("Next", comment: "")) { activeCatalog.next() }.padding()
                }
                if !activeCatalog.errors.isEmpty {
                    Button(NSLocalizedString("Retry", comment: "")) { refreshData() }.padding()
                }
                if isSearchMode ? isLoadingSearchPage : isLoadingMore {
                    HStack {
                        Spacer()
                        ProgressView()
                            .padding(.vertical, 16)
                        Spacer()
                    }
                }
            }
    }

    // MARK: - Grid Card

    private func gridCard(for group: VODCatalogGroup, forcePoster: Bool = false, columnWidth: CGFloat? = nil) -> some View {
        let item = group.item
        let thumbnail = !forcePoster && displayMode == .thumb
        let cardWidth = forcePoster ? MediaCardMetrics.posterWidth : (columnWidth ?? self.cardWidth)
        let artworkHeight = thumbnail ? cardWidth * 9 / 16 : cardWidth * 1.5
        return Button(action: {
            selectedItemForDetail = group
        }) {
            VStack(alignment: .leading, spacing: 6) {
                // Poster
                ZStack(alignment: .bottomLeading) {
                    RemoteImage(
                        url: item.vodPic.flatMap { URL(string: $0) },
                        placeholderSystemImage: "film",
                        contentMode: thumbnail ? .fit : .fill
                    )
                    .frame(width: cardWidth, height: artworkHeight)
                    .background(Color(UIColor.secondarySystemFill))
                    .clipped()
                    .cornerRadius(8)
                    .shadow(color: Color.black.opacity(0.1), radius: 4, x: 0, y: 2)

                    // Remarks overlay at top trailing
                    if let remarks = item.vodRemarks, !remarks.isEmpty {
                        VStack {
                            HStack {
                                Spacer()
                                Text(remarks)
                                    .font(.system(size: 9.5, weight: .bold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2.5)
                                    .background(Color.black.opacity(0.65))
                                    .cornerRadius(4)
                                    .padding(4)
                            }
                            Spacer()
                        }
                    }
                }

                .frame(width: cardWidth, height: artworkHeight)

                // Fixed text area to avoid vertical jagged misalignments (AGENTS.md 3.1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appLineBreakableTitle(item.vodName))
                        .font(.caption.weight(.medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(height: 32, alignment: .topLeading)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text([item.vodYear, item.typeName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty && $0 != "0" }.joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if group.sourceCount > 1 {
                        Text(String(format: platformShellString("VOD Source Count %d"), group.sourceCount))
                            .font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                .frame(height: MediaCardMetrics.posterTextHeight + 14, alignment: .topLeading)
            }
            .frame(width: cardWidth, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func menuRow(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title)
            if selected { Image(systemName: "checkmark") }
        }
    }

    // MARK: - List Row

    private func listRow(for group: VODCatalogGroup) -> some View {
        let item = group.item
        return Button(action: {
            selectedItemForDetail = group
        }) {
            HStack(alignment: .center, spacing: 12) {
                RemoteImage(
                    url: item.vodPic.flatMap { URL(string: $0) },
                    placeholderSystemImage: "film",
                    contentMode: .fill
                )
                .frame(width: 60, height: 85)
                .clipped()
                .cornerRadius(6)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.vodName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    if let remarks = item.vodRemarks, !remarks.isEmpty {
                        Text(remarks)
                            .font(.caption)
                            .foregroundColor(.accentColor)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if let year = item.vodYear, !year.isEmpty {
                            Text(year)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let typeName = item.typeName, !typeName.isEmpty {
                            Text(typeName)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        if let area = item.vodArea, !area.isEmpty {
                            Text(area)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    if let actor = item.vodActor, !actor.isEmpty {
                        Text(actor)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(Color(UIColor.tertiaryLabel))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(UIColor.secondarySystemGroupedBackground))
            .cornerRadius(10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Status Views

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(NSLocalizedString("Loading...", comment: ""))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 44))
                .foregroundColor(.orange)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button(NSLocalizedString("Retry", comment: "")) {
                refreshData()
            }
            .buttonStyle(.bordered)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "film")
                .font(.system(size: 44))
                .foregroundColor(Color(UIColor.tertiaryLabel))
            Text(isSearchMode ? NSLocalizedString("No search results", comment: "") : NSLocalizedString("No content available", comment: ""))
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private func reload(force: Bool = false) {
        catalog.reload(owner: owner, category: selectedCategoryId == "ALL" ? nil : selectedCategoryId,
                       query: "", force: force)
    }
    private func refreshData() {
        if showsSearchResults { reloadSearch() } else { reload(force: true) }
    }
    private func reloadSearch() {
        guard isSearchMode, !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searchCatalog.seedCategories(from: catalog)
        searchCatalog.reload(owner: owner, query: searchText)
    }
    private func cancelSearch() { searchTask?.cancel(); searchCatalog.cancel() }
    private func triggerSearch(keyword: String) {
        searchTask?.cancel()
        searchCatalog.cancel()
        guard isSearchMode, !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searchTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            reloadSearch()
        }
    }
    private func handleItemAppear(_ item: VODCatalogGroup) {
        if item.id == activeCatalog.groups.last?.id { activeCatalog.next() }
    }
}

private struct IOSVODHomeShelf<Card: View>: View {
    let owner: ServerConfig
    let category: VODCatalog.Category
    @ObservedObject var parent: VODCatalog
    let horizontalPadding: CGFloat
    let onOpen: () -> Void
    @ViewBuilder let card: (VODCatalogGroup) -> Card
    @StateObject private var preview = VODCatalog()
    @State private var didLoad = false
    @State private var isVisible = false
    @State private var previewBatches = 0
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !preview.groups.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(platformShellString(category.name)).font(.title2.bold())
                        Spacer()
                        Button(action: onOpen) {
                            Text(NSLocalizedString("See All", comment: ""))
                                .font(.subheadline).foregroundColor(.accentColor)
                        }.buttonStyle(.plain)
                    }.padding(.horizontal, horizontalPadding)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(Array(preview.groups.prefix(12))) { card($0) }
                        }.padding(.horizontal, horizontalPadding)
                    }
                    .duoMediaShelfViewport()
                }
            } else if preview.loading || !didLoad {
                VStack(alignment: .leading, spacing: 0) {
                    Text(platformShellString(category.name))
                        .font(.title2.bold())
                        .padding(.horizontal, horizontalPadding)
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                }
                .padding(.vertical, 16)
            }
            else if !preview.errors.isEmpty {
                Button(platformShellString(category.name)) { load() }.padding()
            }
        }
        .onAppear {
            isVisible = true
            if !didLoad { load() }
            else { fillPreviewIfNeeded() }
        }
        .onDisappear {
            isVisible = false
            if preview.loading { didLoad = false }
            preview.cancel()
        }
        .onChange(of: parent.revision) { _ in
            if isVisible { load() } else { didLoad = false }
        }
        .onChange(of: preview.loading) { loading in
            if !loading { fillPreviewIfNeeded() }
        }
    }
    private func load() {
        didLoad = true
        previewBatches = 1
        preview.seedCategories(from: parent)
        preview.reload(owner: owner, category: category.id)
    }
    private func fillPreviewIfNeeded() {
        guard isVisible, didLoad, !preview.loading, preview.groups.count < 12,
              preview.hasMore, previewBatches < 4 else { return }
        previewBatches += 1
        preview.next()
    }
}

private struct VODHomeOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = .infinity
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}
