#if os(macOS)
import SwiftUI
import AppKit
import GenPlayerCore

public struct MacVODLibraryView: View {
    private let initialServer: ServerConfig
    @ObservedObject private var network = AppNetworkService.shared
    @State private var browsingSourceID: UUID?
    @State private var aggregateCategory: MacVODContentKind?
    private var aggregateHome: Bool { browsingSourceID == nil && owner.macVODEndpoints.count > 1 }
    @State private var showsSourceEditor = false
    @State private var showsSourceMenu = false
    @State private var sourceUnavailable = false
    @State private var searchRefreshID = UUID()
    private var owner: ServerConfig { network.servers.first(where: { $0.id == initialServer.id }) ?? initialServer }
    private var server: ServerConfig {
        owner.macVODEndpoints.first(where: { $0.id == browsingSourceID }) ?? owner.macVODEndpoints.first ?? initialServer
    }
    private var searching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var onExit: (() -> Void)? = nil

    @ObservedObject private var vodService = VODService.shared
    @State private var categories: [VODCategory] = []
    @State private var selectedCategoryId: String = "ALL"
    @State private var items: [VODItem] = []
    @State private var currentPage: Int = 1
    @State private var totalPages: Int = 1
    @State private var totalCount: Int = 0
    @State private var isLoading: Bool = false
    @State private var isLoadingMore: Bool = false
    @State private var errorMessage: String? = nil
    @State private var searchText: String = ""
    @State private var searchTask: Task<Void, Never>? = nil
    @State private var loadRequestID = UUID()
    @State private var selectedItem: VODItem? = nil
    @State private var selectedSearchGroup: MacVODSearchGroup?
    @State private var selectedSearchEntry: MacVODSearchEntry?
    private var detailServer: ServerConfig {
        owner.macVODEndpoints.first(where: { $0.id == selectedSearchEntry?.sourceID }) ?? server
    }
    @State private var storedTargetID = UUID()
    @State private var sortOption = "Default"
    @State private var sortAscending = true
    @State private var isHome = true
    @State private var categoryRootID = "ALL"
    @State private var categoryPager = MacVODCategoryPager()
    @ObservedObject private var navigation = MacNavigationManager.shared
    @StateObject private var home = MacVODHomeModel()
    @AppStorage("MacVODIsGridView") private var isGridView: Bool = true
    @AppStorage("MacVODDisplayMode") private var displayModeRaw = ""

    private var sortedItems: [VODItem] {
        guard sortOption != "Default" else { return items }
        return items.sorted { a, b in
            let lhs: String
            let rhs: String
            switch sortOption {
            case "ProductionYear": lhs = a.vodYear ?? ""; rhs = b.vodYear ?? ""
            case "Updated": lhs = a.vodTime ?? ""; rhs = b.vodTime ?? ""
            default: lhs = a.vodName; rhs = b.vodName
            }
            let order = lhs.localizedStandardCompare(rhs)
            if order == .orderedSame { return a.id < b.id }
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    private var displayMode: LibraryDisplayMode {
        LibraryDisplayMode(rawValue: displayModeRaw) ?? (isGridView ? .poster : .list)
    }

    private var displayModeBinding: Binding<LibraryDisplayMode> {
        Binding(get: { displayMode }, set: { displayModeRaw = $0.rawValue })
    }

    public init(server: ServerConfig, onExit: (() -> Void)? = nil) {
        self.initialServer = server
        self.onExit = onExit
    }

    @ViewBuilder private var sourcePicker: some View {
        if let group = selectedSearchGroup, group.entries.count > 1, let entry = selectedSearchEntry {
            VStack(alignment: .leading, spacing: 12) {
                Text(platformShellString("VOD Sources")).font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(group.entries) { choice in
                            Button {
                                selectedSearchEntry = choice
                                selectedItem = choice.item
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(owner.macVODEndpoints.first(where: { $0.id == choice.sourceID })?.name ?? "",
                                          systemImage: choice.id == entry.id ? "checkmark.circle.fill" : "play.circle")
                                        .font(.headline)
                                    Text(choice.item.vodRemarks ?? "").font(.caption).foregroundColor(.secondary)
                                }.frame(minWidth: 140, alignment: .leading).padding(6)
                            }.buttonStyle(.bordered)
                            .tint(choice.id == entry.id ? .accentColor : .secondary)
                        }
                    }
                }
            }.padding(.horizontal, 32).padding(.vertical, 16)
        }
    }

    public var body: some View {
        ZStack {
            libraryContentView
                .opacity(selectedItem == nil ? 1 : 0)
                .allowsHitTesting(selectedItem == nil)
                .disabled(selectedItem != nil)
                .accessibilityHidden(selectedItem != nil)
            if let item = selectedItem {
                VStack(spacing: 0) {
                MacVODDetailView(
                    server: detailServer,
                    item: item,
                    ownerServerID: owner.id,
                    toolbarServer: owner,
                    sourceControls: AnyView(sourcePicker),
                    onBack: {
                        selectedItem = nil
                    },
                    onExit: {
                        selectedItem = nil
                        onExit?()
                    },
                    onHome: {
                        selectedItem = nil
                        browsingSourceID = nil
                        returnHome()
                    }
                )
                .id(storedTargetID.uuidString + detailServer.id.uuidString + item.id)
                }
            }
        }
        .sheet(isPresented: $showsSourceEditor) {
            MacServerEditorView(existingServer: owner)
        }
        .onChange(of: owner.vodSources) { _ in
            selectedItem = nil
            home.reset()
            categories = []
            returnHome()
            home.refresh(server: server, forceCategoryRefresh: true)
        }
        .alert(platformShellString("VOD Source Unavailable"), isPresented: $sourceUnavailable) {
            Button(platformShellString("OK"), role: .cancel) { }
        }
        .onAppear { resolveStoredTarget() }
        .onChange(of: navigation.targetFileToResolve?.id) { _ in resolveStoredTarget() }
        .onChange(of: selectedItem?.id) { id in
            home.setActive(id == nil && showingHome && !aggregateHome, server: server)
            if id == nil { selectedSearchEntry = nil; selectedSearchGroup = nil }
            if id != nil {
                searchTask?.cancel()
                loadRequestID = UUID()
                isLoading = false
                isLoadingMore = false
            }
        }

    }

    private func resolveStoredTarget() {
        guard let file = navigation.targetFileToResolve,
              file.serverType == .vod, file.jellyfinServerId == owner.id.uuidString,
              let storedID = file.seriesId, !storedID.isEmpty else { return }
        guard let target = owner.macVODResolveRecord(storedID) else {
            navigation.targetFileToResolve = nil
            sourceUnavailable = true
            return
        }
        browsingSourceID = target.source.id
        navigation.targetFileToResolve = nil
        storedTargetID = UUID()
        selectedItem = VODItem(vodId: target.itemID, vodName: file.name)
    }

    // MARK: - Library Browser View

    private var libraryContentView: some View {
        VStack(spacing: 0) {
            // Category Filter Section
            if !searching && !isHome && !categories.isEmpty {
                categoryFilterSection
            }

            // Content
            ZStack {
                Color(NSColor.windowBackgroundColor)
                    .ignoresSafeArea()

                homeContent
                    .opacity(showingHome ? 1 : 0)
                    .allowsHitTesting(showingHome)
                    .disabled(!showingHome)
                    .accessibilityHidden(!showingHome)

                if searching {
                    MacVODMultiSourceSearchView(owner: owner, keyword: $searchText, refreshID: searchRefreshID, displayMode: displayMode, sortOption: sortOption, sortAscending: sortAscending) { group in
                        selectedSearchGroup = group
                        selectedSearchEntry = group.entries.first
                        selectedItem = group.entries.first?.item
                    }
                } else if !showingHome {
                    if isLoading && items.isEmpty {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.1)
                            Text(platformShellString("Loading..."))
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let error = errorMessage, items.isEmpty {
                        VStack(spacing: 14) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.system(size: 38))
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 32)
                            Button(platformShellString("Retry")) {
                                loadInitialData(forceRefresh: true)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.regular)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if items.isEmpty && !(categoryPager.isAggregate && currentPage < totalPages) {
                        VStack(spacing: 12) {
                            Image(systemName: "film.stack")
                                .font(.system(size: 42))
                                .foregroundColor(.secondary.opacity(0.6))
                            Text(platformShellString("No items found"))
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        mainScrollView
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        .macServerToolbar(
            server: server,
            title: owner.name,
            canGoBack: !showingHome || aggregateCategory != nil,
            isImmersive: showingHome && aggregateCategory == nil && (aggregateHome || !home.items.isEmpty),
            searchText: $searchText,
            onBack: {
                if !searchText.isEmpty {
                    searchText = ""

                } else if aggregateCategory != nil {
                    aggregateCategory = nil
                } else {
                    returnHome()
                }
            },
            onHome: { browsingSourceID = nil; returnHome() },
            onExit: {
                searchTask?.cancel()
                searchText = ""
                onExit?()
            }
        ) {
            HStack(spacing: 6) {
                if searching || !showingHome || (aggregateHome && aggregateCategory != nil) {
                    MacDisplayModeMenuPopover(displayMode: displayModeBinding)
                    MacSortMenuPopover(sortOptionRaw: $sortOption, isSortAscending: $sortAscending,
                        options: [("Default", "Default"), ("Name", "SortName"), ("Release Year", "ProductionYear"), ("Updated", "Updated")],
                        heading: "Sort Loaded Items")
                }
                MacToolbarButton(systemImage: "slider.horizontal.3", title: platformShellString("Manage VOD Sources")) {
                    showsSourceMenu.toggle()
                }
                .popover(isPresented: $showsSourceMenu) {
                  VStack(alignment: .leading, spacing: 10) {
                    if owner.macVODEndpoints.count > 1 {
                        Button(platformShellString("All Sources Home")) {
                            showsSourceMenu = false
                            browsingSourceID = nil
                            returnHome()
                        }
                        Divider()
                    }
                    ForEach(owner.macVODEndpoints) { endpoint in
                        Button {
                            showsSourceMenu = false
                            browsingSourceID = endpoint.id
                            home.reset()
                            categories = []
                            returnHome()
                            home.refresh(server: server, forceCategoryRefresh: true)
                        } label: {
                            Label(endpoint.name, systemImage: !aggregateHome && endpoint.id == server.id ? "checkmark" : "film")
                        }
                    }
                    Divider()
                    Button(platformShellString("Manage VOD Sources")) {
                        showsSourceMenu = false
                        showsSourceEditor = true
                    }
                  }.padding()
                }
                MacToolbarButton(
                    systemImage: "arrow.clockwise",
                    title: platformShellString("Refresh"),
                    action: {
                        if searching || aggregateHome { searchRefreshID = UUID() }
                        else if showingHome { home.refresh(server: server) }
                        else { loadInitialData(forceRefresh: true) }
                    }
                )
                .disabled(showingHome ? home.isLoading : isLoading)
            }
        }
        .onChange(of: searchText) { newText in
            home.setActive(showingHome && selectedItem == nil && !aggregateHome, server: server)
            if showingHome {
                searchTask?.cancel()
                loadRequestID = UUID()
                isLoading = false
                isLoadingMore = false
            } else if !searching {
                loadPage(1, forceCategoryRefresh: false)
            } else {
                searchTask?.cancel()
                loadRequestID = UUID()
                isLoading = false
                isLoadingMore = false
            }
        }
        .onAppear {
            home.setActive(showingHome && selectedItem == nil && !aggregateHome, server: server)
            if !showingHome && items.isEmpty && !isLoading {
                loadInitialData(forceRefresh: false)
            }
        }
        .onDisappear {
            home.setActive(false, server: server)
            searchTask?.cancel()
            loadRequestID = UUID()
            isLoading = false
            isLoadingMore = false
        }
    }

    // MARK: - Category Filter Section

    private var categoryFilterSection: some View {
        VStack(spacing: 0) {
            MacVODFilterSection(
                label: home.categories.first(where: { $0.id == categoryRootID })?.typeName ?? platformShellString("Category"),
                allTitle: platformShellString("All"),
                allID: categoryRootID,
                categories: resultCategories,
                selectedCategoryId: selectedCategoryId,
                onSelectCategory: { id in
                    guard id != selectedCategoryId else { return }
                    selectedCategoryId = id
                    loadInitialData(forceRefresh: false)
                }
            )
            .padding(.horizontal, 24)
            .padding(.vertical, 10)

            Divider()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Main Scroll View

    private var mainScrollView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up")
                    if categoryPager.isAggregate {
                        Text(String(format: platformShellString("Loaded %d items"), items.count))
                    } else {
                        Text(MediaCountFormatter.formatTotal(count: totalCount, libraryType: JellyfinLibrary.LibraryType.mixed))
                    }
                    Spacer()
                    if !categoryPager.isAggregate {
                        Text("\(currentPage) / \(totalPages)")
                    }
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 16)

                if let error = errorMessage {
                    homeError(error) { loadPage(currentPage + 1, forceCategoryRefresh: false) }
                        .padding(.horizontal, 20)
                } else if categoryPager.hasFailures {
                    Text(platformShellString("Some categories could not be loaded."))
                        .foregroundColor(.secondary)
                }

                if displayMode != .list {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: displayMode == .thumb ? 204 : 150, maximum: displayMode == .thumb ? 260 : 190), spacing: 18)], spacing: 22) {
                        ForEach(sortedItems) { item in
                            MacVODCard(item: item, landscape: displayMode == .thumb) {
                                selectedItem = item
                            }
                        }
                    }
                    .padding(20)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(sortedItems) { item in
                            MacVODRow(item: item) {
                                selectedItem = item
                            }
                        }
                    }
                    .padding(20)
                }

                // Pagination Trigger
                if currentPage < totalPages {
                    HStack {
                        Spacer()
                        if isLoadingMore {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else if categoryPager.isAggregate || errorMessage != nil {
                            Button(platformShellString("Load More")) { loadNextPage() }
                        } else {
                            Color.clear
                                .frame(height: 30)
                                .onAppear {
                                    loadNextPage()
                                }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 12)
                }
            }
        }
    }

    // MARK: - Home

    private var showingHome: Bool {
        isHome && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resultCategories: [VODCategory] {
        guard let root = home.categories.first(where: { $0.id == categoryRootID }) else {
            return home.roots.isEmpty ? categories : home.roots
        }
        return home.children(of: root)
    }

    private func openCategory(_ id: String) {
        var rootID = id
        var visited = Set<String>()
        while visited.insert(rootID).inserted,
              let category = home.categories.first(where: { $0.id == rootID }),
              let parentID = category.typePid?.value, parentID != 0,
              home.categories.contains(where: { $0.id == String(parentID) }),
              !home.roots.contains(where: { $0.id == rootID }) {
            rootID = String(parentID)
        }
        categoryRootID = rootID
        selectedCategoryId = id
        categories = home.categories
        isHome = false
        home.setActive(false, server: server)
        if searchText.isEmpty { loadInitialData(forceRefresh: false) }
        else { searchText = "" }
    }

    private func returnHome() {
        searchTask?.cancel()
        loadRequestID = UUID()
        isLoading = false
        isLoadingMore = false
        isHome = true
        aggregateCategory = nil
        selectedCategoryId = "ALL"
        searchText = ""
        home.setActive(!aggregateHome, server: server)
    }

    @ViewBuilder private var homeContent: some View {
        if aggregateHome {
            MacVODCollectionHome(owner: owner, refreshID: searchRefreshID, active: showingHome && selectedItem == nil,
                category: $aggregateCategory, displayMode: displayMode, sortOption: sortOption, sortAscending: sortAscending) { group in
                    selectedSearchGroup = group
                    selectedSearchEntry = group.entries.first
                    selectedItem = group.entries.first?.item
                }
        } else {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if !home.items.isEmpty {
                        MacVODCarousel(server: server, items: home.items, active: showingHome && selectedItem == nil) {
                            selectedItem = $0
                        }
                        .padding(.horizontal, -24)
                        .padding(.top, -24)
                    } else if home.isLoading {
                        shelfPlaceholder
                    }
                    if let error = home.error {
                        homeError(error) { home.refresh(server: server) }
                    }
                    if !home.isLoading && home.items.isEmpty && home.previewCategories.isEmpty && home.error == nil {
                        Text(platformShellString("No items found")).foregroundColor(.secondary)
                    }

                    if let error = home.categoryError {
                        homeError(error) { home.refresh(server: server) }
                    }

                    ForEach(home.previewCategories.filter { home.shelves[$0.id]?.isConfirmedEmpty != true }) { category in
                        categoryShelf(category)
                            .onAppear { home.showCategory(category.id, server: server) }
                            .onDisappear { home.hideCategory(category.id) }
                    }
                }
                .padding(24)
            }
        }
    }

    }

    @ViewBuilder
    private func categoryShelf(_ category: VODCategory) -> some View {
        let shelf = home.shelves[category.id]
        VStack(alignment: .leading, spacing: 0) {
            MacMediaShelfSection(
                title: category.typeName,
                systemImageName: "rectangle.stack",
                itemCount: shelf?.totalCount,
                onSeeAll: { openCategory(category.id) },
                items: shelf?.items ?? [],
                artworkHeight: MacVODCard.posterHeight(forWidth: 158)
            ) { item in
                MacVODCard(item: item, showsCategory: false) { selectedItem = item }
                    .frame(width: 158)
            }
            if let error = shelf?.error {
                homeError(error) { home.retryCategory(category.id, server: server) }
                    .padding(.horizontal, 24)
            }
            if shelf?.loaded != true && (shelf?.items.isEmpty ?? true) {
                shelfPlaceholder
            } else if shelf?.items.isEmpty == true && shelf?.hasMore != true && shelf?.error == nil {
                Text(platformShellString("No items found"))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 24)
            }
        }
        .padding(.horizontal, -24)
    }

    private var shelfPlaceholder: some View {
        HStack {
            Spacer()
            ProgressView().accessibilityLabel(platformShellString("Loading..."))
            Spacer()
        }
        .frame(height: 310)
    }

    private func homeError(_ message: String, retry: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Text(message)
                .font(.callout)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .help(message)
            Spacer()
            Button(platformShellString("Retry"), action: retry)
        }
    }

    // MARK: - Data Loading

    private func loadInitialData(forceRefresh: Bool) {
        loadPage(1, forceCategoryRefresh: forceRefresh)
    }

    private func loadNextPage() {
        guard selectedItem == nil, !isLoading, !isLoadingMore, currentPage < totalPages else { return }
        loadPage(currentPage + 1, forceCategoryRefresh: false)
    }

    private func loadPage(_ page: Int, forceCategoryRefresh: Bool, debounce: Bool = false) {
        searchTask?.cancel()
        let requestID = UUID()
        loadRequestID = requestID
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let typeID = selectedCategoryId == "ALL" ? nil : selectedCategoryId
        isLoading = page == 1
        isLoadingMore = page > 1
        errorMessage = nil
        if page == 1 {
            items = []
            currentPage = 1
            totalPages = 1
            totalCount = 0
        }

        searchTask = Task { @MainActor in
            do {
                if debounce { try await Task.sleep(nanoseconds: 350_000_000) }
                guard !Task.isCancelled, loadRequestID == requestID else { return }
                if keyword.isEmpty && (categories.isEmpty || forceCategoryRefresh) {
                    let fetched = try? await vodService.fetchCategories(server: server, forceRefresh: forceCategoryRefresh)
                    guard !Task.isCancelled, loadRequestID == requestID else { return }
                    if let fetched { categories = fetched }
                }
                let result: (items: [VODItem], totalPages: Int, totalCount: Int)
                var pager = categoryPager
                result = try await pager.load(server: server, categoryID: typeID, categories: categories, page: page, keyword: keyword)
                guard !Task.isCancelled, loadRequestID == requestID else { return }
                categoryPager = pager
                if page == 1 {
                    items = result.items
                } else {
                    let existingIDs = Set(items.map(\.id))
                    items.append(contentsOf: result.items.filter { !existingIDs.contains($0.id) })
                }
                currentPage = page
                totalPages = result.totalPages
                totalCount = result.totalCount
                isLoading = false
                isLoadingMore = false
            } catch {
                guard !Task.isCancelled, loadRequestID == requestID else { return }
                errorMessage = error.localizedDescription
                isLoading = false
                isLoadingMore = false
            }
        }
    }
}

// MARK: - Mac VOD Grid Card (Strict 2:3 Aspect Ratio Container)

struct MacVODCard: View {
    let item: VODItem
    var showsCategory = true
    var landscape = false
    let onSelect: () -> Void

    /// Height of the 2:3 poster for a given card width; the poster is laid out with
    /// `aspectRatio(2/3, contentMode: .fit)`.
    static func posterHeight(forWidth width: CGFloat) -> CGFloat {
        width * 3 / 2
    }

    @State private var isHovered: Bool = false

    private var posterURL: URL? {
        item.vodPic.flatMap { URL(string: $0) }
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                // Strict 2:3 Aspect Ratio Poster Container
                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                        .aspectRatio(landscape ? 16.0 / 9.0 : 2.0 / 3.0, contentMode: .fit)
                        .overlay(
                            MacCachedAsyncImage(url: posterURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                default:
                                    ZStack {
                                        Color(NSColor.controlBackgroundColor)
                                        Image(systemName: "film")
                                            .font(.system(size: 30))
                                            .foregroundColor(.secondary.opacity(0.4))
                                    }
                                }
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    // Remarks Badge (Bottom Trailing)
                    if let remarks = item.vodRemarks, !remarks.isEmpty {
                        Text(remarks)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2.5)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(4)
                            .padding(6)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isHovered ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isHovered ? 2 : 1)
                )
                .shadow(color: Color.black.opacity(isHovered ? 0.22 : 0.06), radius: isHovered ? 8 : 4, x: 0, y: isHovered ? 4 : 2)
                .scaleEffect(isHovered ? 1.03 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)

                // Title (2 lines max, top aligned for consistent grid baseline)
                Text(item.vodName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(isHovered ? .accentColor : .primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .topLeading)

                // Metadata (Type · Year)
                HStack(spacing: 4) {
                    if showsCategory, let typeName = item.typeName, !typeName.isEmpty {
                        Text(typeName)
                    }
                    if let year = item.vodYear, !year.isEmpty {
                        if showsCategory, let typeName = item.typeName, !typeName.isEmpty { Text("•") }
                        Text(year)
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .frame(height: 14, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Mac VOD List Row

struct MacVODRow: View {
    let item: VODItem
    let onSelect: () -> Void

    @State private var isHovered: Bool = false

    private var posterURL: URL? {
        item.vodPic.flatMap { URL(string: $0) }
    }

    private func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                // Thumbnail (Strict 2:3 ratio)
                ZStack {
                    Color.clear
                        .aspectRatio(2 / 3, contentMode: .fit)
                        .overlay(
                            MacCachedAsyncImage(url: posterURL) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                default:
                                    ZStack {
                                        Color(NSColor.controlBackgroundColor)
                                        Image(systemName: "film")
                                            .font(.system(size: 16))
                                            .foregroundColor(.secondary.opacity(0.4))
                                    }
                                }
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .frame(width: 44, height: 66)

                // Text info
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.vodName)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(isHovered ? .accentColor : .primary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        if let typeName = item.typeName, !typeName.isEmpty {
                            Text(typeName)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundColor(.accentColor)
                                .cornerRadius(3)
                        }
                        if let year = item.vodYear, !year.isEmpty {
                            Text(year)
                                .font(.system(size: 11.5))
                                .foregroundColor(.secondary)
                        }
                        if let remarks = item.vodRemarks, !remarks.isEmpty {
                            Text(remarks)
                                .font(.system(size: 11.5))
                                .foregroundColor(.orange)
                        }
                    }
                    let people = [
                        nonempty(item.vodArea),
                        nonempty(item.vodDirector).map { String(format: platformShellString("Director: %@"), $0) },
                        nonempty(item.vodActor).map { String(format: platformShellString("Actors: %@"), $0) }
                    ].compactMap { $0 }.joined(separator: " · ")
                    if !people.isEmpty {
                        Text(people)
                            .font(.system(size: 11.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    if !item.cleanSynopsis.isEmpty {
                        Text(item.cleanSynopsis)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let updateTime = item.vodTime, !updateTime.isEmpty {
                    Text(updateTime)
                        .font(.system(size: 11.5))
                        .foregroundColor(.secondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Color(NSColor.selectedContentBackgroundColor).opacity(0.12) : Color(NSColor.controlBackgroundColor).opacity(0.3))
            .cornerRadius(8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Mac VOD Full Detail View (Jellyfin Style)

public struct MacVODDetailView: View {
    public let server: ServerConfig
    public let item: VODItem
    public var ownerServerID: UUID? = nil
    public var toolbarServer: ServerConfig? = nil
    public var sourceControls: AnyView? = nil
    public let onBack: () -> Void
    public var onExit: (() -> Void)? = nil
    public var onHome: (() -> Void)? = nil

    @ObservedObject private var vodService = VODService.shared
    @ObservedObject private var favorites = FavoriteService.shared
    @ObservedObject private var history = HistoryService.shared
    @State private var manuallySelectedSource = false
    @State private var detailedItem: VODItem?
    @State private var selectedSourceIndex: Int = 0
    @State private var episodePage = 0
    @State private var isLoadingDetail: Bool = false

    private var currentItem: VODItem {
        detailedItem ?? item
    }

    private var playSources: [VODPlaySource] {
        currentItem.playSources
    }

    private var currentSource: VODPlaySource? {
        playSources.first(where: { $0.index == selectedSourceIndex }) ?? playSources.first
    }

    private var recordServerID: UUID { ownerServerID ?? server.id }
    private var recordItemID: String {
        server.macVODRecordID(ownerID: recordServerID, itemID: currentItem.id)
    }

    private func playbackFile(_ episode: VODEpisode, source: VODPlaySource) -> VideoFile {
        var file = VODService.shared.makeVideoFile(for: episode, item: currentItem, server: server, source: source)
        file.jellyfinServerId = recordServerID.uuidString
        file.seriesId = recordItemID
        return file
    }

    private var favoriteFile: VideoFile {
        VideoFile(name: currentItem.vodName,
                  url: URL(string: "genplayer-vod://" + recordServerID.uuidString + "/" + recordItemID)!,
                  type: .video, size: 0, date: Date(), isRemote: true,
                  jellyfinItemId: recordItemID, jellyfinServerId: recordServerID.uuidString,
                  serverType: .vod, customArtworkURL: posterURL, seriesId: recordItemID)
    }

    private var resumeTarget: (source: VODPlaySource, episode: VODEpisode, file: VideoFile)? {
        guard HistoryService.isHistoryEnabled(for: favoriteFile) else { return nil }
        for record in history.remoteHistory where record.serverType == .vod && record.jellyfinServerId == recordServerID.uuidString && record.seriesId == recordItemID {
            for source in playSources where !manuallySelectedSource || source.index == selectedSourceIndex {
                for episode in source.episodes {
                    let file = playbackFile(episode, source: source)
                    if record.url == episode.url || (record.jellyfinItemId == file.jellyfinItemId && record.name == file.name) {
                        return (source, episode, record)
                    }
                }
            }
        }
        return nil
    }

    private var heroNode: MacMediaLibraryNode {
        var node = MacMediaLibraryNode(
            id: currentItem.id, name: currentItem.vodName, type: .video, isFolder: false,
            posterURL: posterURL, summary: currentItem.cleanSynopsis,
            metadataLine: [currentItem.vodYear, currentItem.typeName, currentItem.vodArea, currentItem.vodRemarks]
                .compactMap { $0 }.filter { !$0.isEmpty && $0 != "0" }.joined(separator: " · ")
        )
        if let target = resumeTarget {
            node.technicalMetadataLine = target.source.name + " · " + target.episode.name
        }
        if let record = resumeTarget?.file, let duration = record.duration, duration.isFinite, duration > 0,
           let position = history.getLastPlayedPosition(for: record), position.isFinite, position > 0 {
            node.runTimeTicks = Int64(min(duration, 1e10) * 10_000_000)
            node.playbackPositionTicks = Int64(min(position, duration, 1e10) * 10_000_000)
        }
        return node
    }

    private var posterURL: URL? {
        currentItem.vodPic.flatMap { URL(string: $0) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Top Hero Banner Section (Jellyfin/Emby style)
                    heroBannerSection
                    if let sourceControls { sourceControls }
                    // Episodes Shelf Section
                    if isLoadingDetail || playSources.isEmpty || playSources.count > 1 || (currentSource?.episodes.count ?? 0) > 1 {
                        episodesShelfSection
                    }
                    castSection
                    mediaInfoSection
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.windowBackgroundColor))
        .macServerToolbar(
            server: toolbarServer ?? server,
            title: (toolbarServer ?? server).name,
            canGoBack: true,
            hideSearchAndExit: true,
            isImmersive: true,
            searchText: .constant(""),
            onBack: onBack,
            onHome: { (onHome ?? onBack)() },
            onExit: { onExit?() }
        ) {
            EmptyView()
        }
        .onAppear {
            loadDetailIfNeeded()
            if !manuallySelectedSource, let target = resumeTarget {
                selectedSourceIndex = target.source.index
                episodePage = (target.source.episodes.firstIndex(where: { $0.id == target.episode.id }) ?? 0) / 50
            }
        }
    }

    private var people: [MacMediaPerson] {
        var result: [MacMediaPerson] = []
        for (text, role) in [(currentItem.vodDirector, "Director"), (currentItem.vodActor, "Actor")] {
            var seen = Set<String>()
            for raw in (text ?? "").components(separatedBy: CharacterSet(charactersIn: ",，、;；/")) {
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && seen.insert(name).inserted {
                    result.append(MacMediaPerson(id: role + name, name: name, role: platformShellString(role), primaryImageURL: nil))
                }
            }
        }
        return result
    }

    @ViewBuilder private var castSection: some View {
        if !people.isEmpty {
            VStack(alignment: .leading, spacing: 24) {
                Text(platformShellString("Cast & Crew")).font(.headline)
                MacHorizontalShelf(items: people, spacing: 24, horizontalPadding: 0, verticalPadding: 0, artworkHeight: 110) { person in
                    VStack(spacing: 10) {
                        ZStack {
                            Circle().fill(Color.secondary.opacity(0.12))
                            Image(systemName: "person.fill").font(.system(size: 44)).foregroundColor(.secondary)
                        }.frame(width: 110, height: 110)
                        Text(person.name).font(.headline).lineLimit(2).frame(height: 36, alignment: .top)
                        Text(person.role ?? "").font(.caption).foregroundColor(.secondary)
                    }.frame(width: 140).help(person.name)
                }
            }.padding(.horizontal, 44).padding(.vertical, 24)
        }
    }

    @ViewBuilder private var mediaInfoSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(platformShellString("Media Info")).font(.headline)
            infoRow("Server Info", server.name)
            if let value = currentItem.vodLanguage?.value, !value.isEmpty { infoRow("Language", value) }
            if let value = currentItem.vodDuration?.value, !value.isEmpty && value != "0" { infoRow("Duration", value) }
            if let value = currentItem.vodTime, !value.isEmpty { infoRow("Updated", value) }
            if let id = currentItem.vodDoubanID?.value, let number = Int(id), number > 0,
               let url = URL(string: "https://movie.douban.com/subject/" + String(number) + "/") {
                Link(platformShellString("Douban"), destination: url)
            }
            if let source = currentSource {
                infoRow("Sources", source.name)
                let target = resumeTarget.flatMap { $0.source.index == source.index ? $0.episode : nil } ?? source.episodes.first
                if let target {
                    infoRow("Stream URL", target.name + " · " + target.url.absoluteString)
                    Button(platformShellString("Copy Stream URL")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(target.url.absoluteString, forType: .string)
                    }
                }
            }
        }.padding(24)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 44).padding(.vertical, 24)
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 20) {
            Text(platformShellString(key)).foregroundColor(.secondary).frame(width: 110, alignment: .leading)
            Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.body)
    }

    // MARK: - Hero Banner Section

    private var heroBannerSection: some View {
        MacMediaDetailHero(
            server: server,
            node: heroNode,
            isFavorite: favorites.isFavorite(file: favoriteFile),
            isPlayed: false,
            onPlay: {
                if let target = resumeTarget {
                    selectedSourceIndex = target.source.index
                    playEpisode(target.episode, in: target.source, resumePosition: history.getLastPlayedPosition(for: target.file))
                } else if let source = currentSource, let episode = source.episodes.first {
                    playEpisode(episode, in: source)
                }
            },
            onDownload: {},
            onFavorite: { favorites.toggleFavorite(file: favoriteFile) },
            onTogglePlayed: {},
            showsMediaServerActions: false,
            canPlay: currentSource?.episodes.isEmpty == false,
            showsStandaloneFavorite: true
        )
    }

    // MARK: - Episodes Shelf Section

    private var episodesShelfSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            Divider()

            if isLoadingDetail {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(0.9)
                        Text(platformShellString("Loading..."))
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 40)
            } else if playSources.isEmpty {
                Text(platformShellString("No episodes found"))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.vertical, 24)
            } else {
                // Play Source Switcher Tabs
                if playSources.count > 1 {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(platformShellString("Sources"))
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.primary)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(playSources) { src in
                                    let isSelected = currentSource?.index == src.index
                                    Button {
                                        manuallySelectedSource = true
                                        selectedSourceIndex = src.index
                                        episodePage = 0
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "play.tv")
                                                .font(.system(size: 11))
                                            Text(src.name)
                                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                                        }
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(isSelected ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                                        .foregroundColor(isSelected ? .white : .primary)
                                        .cornerRadius(6)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                // Episodes Grid
                if let source = currentSource, source.episodes.count > 1 {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(platformShellString("Episodes"))
                                .font(.system(size: 15, weight: .bold))
                            Spacer()
                            Text("\(source.episodes.count) " + platformShellString("episodes"))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                        }

                        if source.episodes.count > 50 {
                            Picker(platformShellString("Episodes"), selection: $episodePage) {
                                ForEach(0..<((source.episodes.count + 49) / 50), id: \.self) { page in
                                    Text("\(page * 50 + 1)–\(min((page + 1) * 50, source.episodes.count))").tag(page)
                                }
                            }.fixedSize()
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 85, maximum: 115), spacing: 10)], spacing: 10) {
                            ForEach(Array(source.episodes.dropFirst(episodePage * 50).prefix(50))) { ep in
                                MacEpisodeButton(name: localizedEpisodeName(ep.name)) {
                                    playEpisode(ep, in: source)
                                }
                                .contextMenu {
                                    Button(platformShellString("Copy Stream URL")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(ep.url.absoluteString, forType: .string)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 24)
    }

    private func localizedEpisodeName(_ name: String) -> String {
        let text = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.range(of: "^第[0-9]+集$", options: .regularExpression) != nil,
              let number = Int(text.dropFirst().dropLast()) else { return name }
        return String(format: platformShellString("Episode %d"), number)
    }

    private func badge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(4)
    }

    private func playEpisode(_ episode: VODEpisode, in source: VODPlaySource, resumePosition: TimeInterval? = nil) {
        var file = playbackFile(episode, source: source)
        if let resumePosition, resumePosition.isFinite, resumePosition >= 0 { file.lastPlayedPosition = resumePosition }
        let allFiles = source.episodes.map { playbackFile($0, source: source) }
        MacPlayerWindowManager.shared.openPlayer(for: file, playlist: allFiles, thumbnailURL: posterURL)
    }

    private func loadDetailIfNeeded() {
        guard currentItem.playSources.isEmpty else { return }
        isLoadingDetail = true

        Task {
            if let detail = try? await VODService.shared.fetchDetail(server: server, vodId: currentItem.id) {
                await MainActor.run {
                    self.detailedItem = detail
                    if !manuallySelectedSource, let target = resumeTarget {
                selectedSourceIndex = target.source.index
                episodePage = (target.source.episodes.firstIndex(where: { $0.id == target.episode.id }) ?? 0) / 50
            }
                    self.isLoadingDetail = false
                }
            } else {
                await MainActor.run {
                    self.isLoadingDetail = false
                }
            }
        }
    }
}

// MARK: - Mac Episode Button with Hover Effect

private struct MacEpisodeButton: View {
    let name: String
    let action: () -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: action) {
            Text(name)
                .font(.system(size: 12.5, weight: isHovered ? .semibold : .medium))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .padding(.horizontal, 8)
                .background(isHovered ? Color.accentColor : Color(NSColor.controlBackgroundColor))
                .foregroundColor(isHovered ? .white : .primary)
                .cornerRadius(7)
                .overlay(
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(isHovered ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Multi-Row VOD Category Filter Section

private struct MacVODFilterLayoutResult: Equatable {
    var row1: [VODCategory] = []
    var row2: [VODCategory] = []
    var overflow: [VODCategory] = []
    var totalHeight: CGFloat = 34
}

private struct MacVODFilterSection: View {
    let label: String
    let allTitle: String
    var allID: String = "ALL"
    let categories: [VODCategory]
    let selectedCategoryId: String
    let onSelectCategory: (String) -> Void

    @State private var containerWidth: CGFloat = 0

    private let chipSpacing: CGFloat = 8
    private let rowHeight: CGFloat = 34

    private func estimateWidth(for text: String) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .subheadline)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return size.width + 26
    }

    private func computeLayout(width: CGFloat) -> MacVODFilterLayoutResult {
        guard width > 60 else { return MacVODFilterLayoutResult() }

        let labelWidth: CGFloat = 50
        let spacing: CGFloat = 12
        let availableWidth = max(width - labelWidth - spacing, 100)

        var row1: [VODCategory] = []
        var row2: [VODCategory] = []
        var overflow: [VODCategory] = []

        var currentX: CGFloat = estimateWidth(for: allTitle) + chipSpacing
        var currentRow = 1

        for cat in categories {
            let itemWidth = estimateWidth(for: cat.typeName)

            if currentRow == 1 {
                if currentX + itemWidth > availableWidth {
                    currentRow = 2
                    currentX = itemWidth + chipSpacing
                    row2.append(cat)
                } else {
                    row1.append(cat)
                    currentX += itemWidth + chipSpacing
                }
            } else if currentRow == 2 {
                let isLast = cat.id == categories.last?.id
                let moreButtonWidth: CGFloat = 40
                let requiredSpace = itemWidth + (isLast ? 0 : (chipSpacing + moreButtonWidth))

                if currentX + requiredSpace > availableWidth {
                    currentRow = 3
                    overflow.append(cat)
                } else {
                    row2.append(cat)
                    currentX += itemWidth + chipSpacing
                }
            } else {
                overflow.append(cat)
            }
        }

        let height: CGFloat = currentRow > 1 ? (rowHeight * 2 + chipSpacing) : rowHeight
        return MacVODFilterLayoutResult(row1: row1, row2: row2, overflow: overflow, totalHeight: height)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.vertical, 6)
                .frame(width: 50, alignment: .leading)

            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: containerWidth > 0 ? computeLayout(width: containerWidth).totalHeight : rowHeight)
                .overlay(alignment: .topLeading) {
                    let layout = computeLayout(width: containerWidth)

                    VStack(alignment: .leading, spacing: chipSpacing) {
                        HStack(spacing: chipSpacing) {
                            MacVODFilterChip(
                                title: allTitle,
                                isSelected: selectedCategoryId == allID,
                                action: { onSelectCategory(allID) }
                            )
                            ForEach(layout.row1) { cat in
                                MacVODFilterChip(
                                    title: cat.typeName,
                                    isSelected: selectedCategoryId == cat.id,
                                    action: { onSelectCategory(cat.id) }
                                )
                            }
                        }

                        if !layout.row2.isEmpty || !layout.overflow.isEmpty {
                            HStack(spacing: chipSpacing) {
                                ForEach(layout.row2) { cat in
                                    MacVODFilterChip(
                                        title: cat.typeName,
                                        isSelected: selectedCategoryId == cat.id,
                                        action: { onSelectCategory(cat.id) }
                                    )
                                }

                                if !layout.overflow.isEmpty {
                                    let overflowSelected = layout.overflow.contains { $0.id == selectedCategoryId }
                                    let selectedCat = categories.first { $0.id == selectedCategoryId }

                                    Menu {
                                        ForEach(layout.overflow) { cat in
                                            Button(cat.typeName) {
                                                onSelectCategory(cat.id)
                                            }
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            if overflowSelected, let selectedCat {
                                                Text(selectedCat.typeName)
                                                    .font(.subheadline)
                                                    .fontWeight(.medium)
                                            }
                                            Image(systemName: "ellipsis")
                                                .font(.system(size: 13, weight: .semibold))
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(overflowSelected ? Color.accentColor : Color.primary.opacity(0.06))
                                        .foregroundColor(overflowSelected ? .white : .secondary)
                                        .cornerRadius(12)
                                    }
                                    .menuStyle(.borderlessButton)
                                }
                            }
                        }
                    }
                }
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .onAppear { containerWidth = geo.size.width }
                            .onChange(of: geo.size.width) { w in containerWidth = w }
                    }
                )
        }
    }
}

private struct MacVODFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.08) : Color.clear))
                .foregroundColor(isSelected ? .white : (isHovered ? .primary : .secondary))
                .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovered = hovering
            }
        }
        .macPointerHover()
    }
}
#endif

#if os(macOS)
private struct MacVODMultiSourceSearchView: View {
    let owner: ServerConfig
    @Binding var keyword: String
    let refreshID: UUID
    let displayMode: LibraryDisplayMode
    let sortOption: String
    let sortAscending: Bool
    @State private var sourceFilter: UUID?
    @State private var contentFilter: MacVODContentKind?
    let onSelect: (MacVODSearchGroup) -> Void
    @State private var results: [UUID: [VODItem]] = [:]
    @State private var errors: [UUID: String] = [:]
    @State private var pages: [UUID: Int] = [:]
    @State private var totals: [UUID: Int] = [:]
    @State private var busy = false
    @State private var requestID = UUID()
    @State private var work: Task<Void, Never>?

    private var sources: [ServerConfig] {
        owner.macVODEndpoints.filter { sourceFilter == nil || $0.id == sourceFilter }
    }

    private var groupedResults: [MacVODSearchGroup] {
        let entries = sources.flatMap { source in
            (results[source.id] ?? []).filter { item in
                contentFilter == nil || MacVODContentKind.classify(item.typeName ?? "") == contentFilter
            }.map { MacVODSearchEntry(sourceID: source.id, item: $0) }
        }
        let groups = MacVODSearchGroup.ranked(MacVODSearchGroup.aggregate(entries), keyword: keyword)
        guard sortOption != "Default" else { return groups }
        func value(_ group: MacVODSearchGroup) -> String {
            guard let item = group.entries.first?.item else { return "" }
            switch sortOption {
            case "ProductionYear": return item.vodYear ?? ""
            case "Updated": return item.vodTime ?? ""
            default: return item.vodName
            }
        }
        return groups.enumerated().sorted {
            let order = value($0.element).localizedStandardCompare(value($1.element))
            if order == .orderedSame { return $0.offset < $1.offset }
            return sortAscending ? order == .orderedAscending : order == .orderedDescending
        }.map(\.element)
    }

    var body: some View {
        VStack(spacing: 12) {
                HStack {
                    Picker(platformShellString("VOD Sources"), selection: $sourceFilter) {
                        Text(platformShellString("All")).tag(Optional<UUID>.none)
                        ForEach(owner.macVODEndpoints) { source in Text(source.name).tag(Optional(source.id)) }
                    }.frame(maxWidth: 300)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            contentButton(nil)
                            ForEach(MacVODContentKind.allCases) { contentButton($0) }
                        }
                    }
                    Spacer()
                    if busy { ProgressView().controlSize(.small) }
                }.padding(.horizontal, 24).padding(.vertical, 12)
                Divider()
                ScrollView {
                    if displayMode == .list {
                        LazyVStack(spacing: 12) {
                            ForEach(groupedResults) { group in
                                if let item = group.entries.first?.item {
                                    VStack(alignment: .leading, spacing: 4) {
                                        MacVODRow(item: item) { onSelect(group) }
                                        sourceCount(group)
                                    }
                                }
                            }
                        }.padding()
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: displayMode == .thumb ? 240 : 150, maximum: displayMode == .thumb ? 300 : 200), alignment: .top)], alignment: .leading, spacing: 20) {
                            ForEach(groupedResults) { group in
                                if let first = group.entries.first {
                                    VStack(alignment: .leading) {
                                        MacVODCard(item: first.item, landscape: displayMode == .thumb) { onSelect(group) }
                                        sourceCount(group)
                                    }
                                }
                            }
                        }.padding()
                    }
                    if !busy && groupedResults.isEmpty && errors.isEmpty {
                        Text(platformShellString("No items found")).foregroundColor(.secondary)
                    }
                    ForEach(sources.filter { errors[$0.id] != nil }) { source in
                        HStack {
                            Text(source.name + ": " + (errors[source.id] ?? ""))
                            Button(platformShellString("Retry")) { search(only: source, page: (pages[source.id] ?? 0) + 1) }.disabled(busy)
                        }.padding(.horizontal)
                    }
                    if sources.contains(where: { (pages[$0.id] ?? 0) < (totals[$0.id] ?? 0) }) {
                        Button(platformShellString("Load More")) { search(more: true) }.disabled(busy).padding()
                    }
                }
        }
        .onChange(of: keyword) { _ in cancel(); results = [:]; errors = [:]; pages = [:]; totals = [:] }
        .task(id: keyword) {
            do { try await Task.sleep(nanoseconds: 350_000_000) } catch { return }
            guard !Task.isCancelled else { return }
            search()
        }
        .onChange(of: sources) { _ in cancel(); search() }
        .onChange(of: refreshID) { _ in search() }
        .onDisappear { cancel() }
    }

    private func contentButton(_ kind: MacVODContentKind?) -> some View {
        Button { contentFilter = kind } label: {
            Text(platformShellString(kind?.rawValue ?? "All"))
                .fontWeight(contentFilter == kind ? .semibold : .regular)
                .foregroundColor(contentFilter == kind ? .accentColor : .primary)
        }.buttonStyle(.bordered)
    }

    private func sourceCount(_ group: MacVODSearchGroup) -> some View {
        Text(String(format: platformShellString("VOD Source Count %d"), group.sourceCount))
            .font(.caption).foregroundColor(.secondary).lineLimit(1).frame(height: 16)
    }

    private func cancel() { work?.cancel(); requestID = UUID(); busy = false }

    private func search(only source: ServerConfig? = nil, page: Int = 1, more: Bool = false) {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        cancel()
        if source == nil && !more { results = [:]; errors = [:]; pages = [:]; totals = [:] }
        let targets = source.map { [$0] } ?? sources.filter { !more || (pages[$0.id] ?? 0) < (totals[$0.id] ?? 0) }
        let requestedPages = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, more ? (pages[$0.id] ?? 0) + 1 : page) })
        let id = requestID
        busy = true
        work = Task { @MainActor in
            // Bounded batches avoid flooding every saved endpoint at once.
            for start in stride(from: 0, to: targets.count, by: 3) {
                guard !Task.isCancelled, id == requestID else { return }
                await withTaskGroup(of: (UUID, [VODItem], Int, String?).self) { group in
                    for target in targets[start..<min(start + 3, targets.count)] {
                        group.addTask {
                            do {
                                let result = try await VODService.shared.search(server: target, keyword: query, page: requestedPages[target.id] ?? page)
                                return (target.id, result.items, result.totalPages, nil)
                            } catch { return (target.id, [], 0, error.localizedDescription) }
                        }
                    }
                    for await (serverID, items, total, error) in group {
                        guard !Task.isCancelled, id == requestID else { group.cancelAll(); return }
                        errors[serverID] = error
                        if error == nil {
                            let requestedPage = requestedPages[serverID] ?? page
                            let previous = requestedPage == 1 ? [] : results[serverID] ?? []
                            var seen = Set<String>()
                            results[serverID] = (previous + items).filter { seen.insert($0.id).inserted }
                            pages[serverID] = requestedPage
                            totals[serverID] = total
                        }
                    }
                }
            }
            if id == requestID { busy = false }
        }
    }
}
#endif
