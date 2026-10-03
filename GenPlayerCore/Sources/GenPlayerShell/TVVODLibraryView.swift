#if os(tvOS)
import SwiftUI
import GenPlayerCore

/// A content-first browser for MacCMS-compatible Web VOD sources.
///
/// VOD returns a paginated flat list instead of the hierarchical node model used by
/// Jellyfin, Emby, and Plex, so routing it through `TVMediaLibraryBrowserView` would
/// successfully fetch data but render an empty node list.
struct TVVODLibraryView: View {
    let server: ServerConfig

    @StateObject private var catalog = VODCatalog()
    @ObservedObject private var network = AppNetworkService.shared
    @State private var selectedCategoryID = "ALL"
    @State private var rootCategoryID: String?
    @State private var rootCategoryName: String?
    private var isHome: Bool { rootCategoryID == nil && searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    @State private var searchText = ""
    @State private var sort = "Default"
    @State private var showSort = false
    private var owner: ServerConfig { network.servers.first { $0.id == server.id } ?? server }
    private var categories: [VODCategory] { catalog.categories.filter { rootCategoryID == nil || $0.parentKeys.contains(rootCategoryID!) }.map { VODCategory(typeId: $0.id, typeName: platformShellString($0.name)) } }
    private var items: [VODCatalogGroup] {
        switch sort {
        case "Name": return catalog.groups.sorted { $0.item.vodName.localizedStandardCompare($1.item.vodName) == .orderedAscending }
        case "Release Year": return catalog.groups.sorted { ($0.item.vodYear ?? "") > ($1.item.vodYear ?? "") }
        default: return catalog.groups
        }
    }
    private var isLoading: Bool { catalog.loading }
    private var isLoadingNextPage: Bool { catalog.loading }
    private var errorMessage: String? { catalog.errors.first }

    private var selectedCategoryTitle: String {
        categories.first(where: { $0.id == selectedCategoryID })?.typeName
            ?? platformShellString("All")
    }

    private var librarySummary: String {
        String(format: platformShellString("Loaded %d items"), catalog.groups.count)
    }

    var body: some View {
        TVPageScrollView(
            title: server.name,
            subtitle: isHome ? nil : librarySummary,
            handlesExitCommand: true,
            customExitCommand: {
                if !searchText.isEmpty {
                    searchText = ""
                    reload(forceCategoryRefresh: false)
                    return true
                }
                guard rootCategoryID != nil else { return false }
                rootCategoryID = nil; rootCategoryName = nil; selectedCategoryID = "ALL"
                reload(forceCategoryRefresh: false)
                return true
            },
            titleAccessory: AnyView(
                Button(action: { reload(forceCategoryRefresh: true) }) {
                    TVTopChromeIconButton(
                        title: platformShellString("Refresh"),
                        systemImageName: "arrow.clockwise",
                        diameter: 66
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            )
        ) {
            HStack(spacing: 24) {
                TextField(platformShellString("Search in VOD"), text: $searchText)
                    .onSubmit { reload(forceCategoryRefresh: false) }
                Button(platformShellString("Search")) { reload(forceCategoryRefresh: false) }
                if !isHome {
                Button(platformShellString("Sort By")) { showSort = true }
                    .confirmationDialog(platformShellString("Sort By"), isPresented: $showSort) {
                        ForEach(["Default", "Name", "Release Year"], id: \.self) { value in
                            Button(platformShellString(value)) { sort = value }
                        }
                    }
                }
            }.tvFocusSectionIfAvailable()
            if rootCategoryID != nil {
                categoryShelf
            }

            if isLoading && items.isEmpty {
                loadingState
            } else if let errorMessage, items.isEmpty {
                errorState(message: errorMessage)
            } else if items.isEmpty {
                emptyState
            } else if isHome {
                ForEach(catalog.categories.filter(\.isRoot)) { category in
                    TVVODHomeShelf(owner: owner, category: category, parent: catalog) {
                        rootCategoryName = category.name; rootCategoryID = category.id; selectedCategoryID = category.id; reload(forceCategoryRefresh: false)
                    }
                }
            } else {
                TVShelfSectionPlainHeader(
                    title: selectedCategoryTitle,
                    subtitle: librarySummary,
                    systemImage: "film.stack",
                    server: nil,
                    headerAccessory: nil
                )

                posterGrid

                if catalog.hasMore {
                    pageControls
                }
            }
        }
        .onAppear {
            if items.isEmpty && !isLoading {
                reload(forceCategoryRefresh: false)
            }
        }
        .onDisappear { catalog.cancel() }
        .onChange(of: catalog.revision) { _ in
            guard let name = rootCategoryName else { return }
            guard let root = catalog.categories.first(where: { VODCatalog.categoryKey($0.name) == VODCatalog.categoryKey(name) }) else {
                rootCategoryID = nil; rootCategoryName = nil; selectedCategoryID = "ALL"
                reload(forceCategoryRefresh: false)
                return
            }
            rootCategoryID = root.id
            selectedCategoryID = catalog.resolvedCategoryID ?? root.id
        }
        .onChange(of: owner.vodSources) { _ in reload(forceCategoryRefresh: true) }
    }

    private var categoryShelf: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                Button(platformShellString("Home")) { rootCategoryID = nil; rootCategoryName = nil; selectedCategoryID = "ALL"; reload(forceCategoryRefresh: false) }
                categoryButton(title: platformShellString("All"), id: rootCategoryID ?? "ALL")

                ForEach(categories) { category in
                    categoryButton(title: category.typeName, id: category.id)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvFocusSectionIfAvailable()
    }

    private func categoryButton(title: String, id: String) -> some View {
        Button(action: {
            guard selectedCategoryID != id else { return }
            selectedCategoryID = id
            reload(forceCategoryRefresh: false)
        }) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .buttonStyle(TVCategoryTabButtonStyle(isSelected: selectedCategoryID == id))
    }

    private var loadingState: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.4)
            Text(platformShellString("Loading..."))
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(TVShellStyle.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private func errorState(message: String) -> some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.orange)

            Text(message)
                .font(.system(size: 22))
                .foregroundColor(TVShellStyle.secondary)
                .multilineTextAlignment(.center)

            Button(action: { reload(forceCategoryRefresh: true) }) {
                TVMaintenanceButtonLabel(
                    title: platformShellString("Retry"),
                    systemImageName: "arrow.clockwise"
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "film.stack")
                .font(.system(size: 60))
                .foregroundColor(TVShellStyle.secondary.opacity(0.45))

            Text(platformShellString("No items found"))
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(TVShellStyle.primary)

            Button(action: { reload(forceCategoryRefresh: true) }) {
                TVMaintenanceButtonLabel(
                    title: platformShellString("Refresh"),
                    systemImageName: "arrow.clockwise"
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var posterGrid: some View {
        TVFocusableRowGrid(
            items: items,
            columnsPerRow: 6,
            columnWidth: 220,
            rowMinHeight: 440,
            columnSpacing: 28,
            rowSpacing: 38
        ) { item in
            TVNavigationLink(destination: TVVODGroupDetailView(owner: owner, group: item)) {
                TVVODPosterCard(server: item.entries[0].source, item: item.item)
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
        }
    }

    private var pageControls: some View {
        HStack(spacing: 20) {
            Spacer(minLength: 0)

            if isLoadingNextPage {
                ProgressView()
                    .scaleEffect(1.1)
            } else {
                Button(action: { loadNextPage() }) {
                    TVCompactActionButton(
                        title: platformShellString("Next"),
                        systemImageName: "chevron.right"
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

                Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
        .tvFocusSectionIfAvailable()
    }

    private func reload(forceCategoryRefresh: Bool) {
        catalog.reload(owner: owner, category: selectedCategoryID == "ALL" ? nil : selectedCategoryID,
                       query: searchText, force: forceCategoryRefresh)
    }
    private func loadNextPage() { catalog.next() }
}

private struct TVVODPosterCard: View {
    let server: ServerConfig
    let item: VODItem

    @Environment(\.isFocused) private var isFocused

    private var posterURL: URL? {
        item.vodPic.flatMap(URL.init(string:))
    }

    private var metadata: String {
        [item.typeName, item.vodYear]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                TVRemoteArtworkView(
                    url: posterURL,
                    server: server,
                    placeholderSystemImageName: "film"
                )
                .frame(width: 220, height: 330)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                if let remarks = item.vodRemarks?.trimmingCharacters(in: .whitespacesAndNewlines), !remarks.isEmpty {
                    Text(remarks)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.black.opacity(0.74))
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .padding(10)
                }
            }
            .tvFocusedPosterArtwork(cornerRadius: 16)
            .shadow(
                color: Color.black.opacity(isFocused ? 0.32 : 0.20),
                radius: isFocused ? 18 : 10,
                x: 0,
                y: isFocused ? 12 : 5
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(item.vodName)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(isFocused ? TVShellStyle.primary : TVShellStyle.primary.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50, alignment: .topLeading)

                Text(metadata)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(isFocused ? TVShellStyle.secondary : TVShellStyle.secondary.opacity(0.72))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 20, alignment: .topLeading)
            }
            .frame(width: 220, alignment: .topLeading)
        }
        .frame(width: 220, height: 424, alignment: .topLeading)
        .tvPosterShelfCard(width: 220, minHeight: 424)
    }
}

private struct TVVODDetailView: View {
    let server: ServerConfig
    let item: VODItem
    var ownerID: UUID? = nil
    @ObservedObject private var history = HistoryService.shared
    private func preferredEpisode(_ source: VODPlaySource) -> VODEpisode? {
        for record in history.allHistory where record.serverType == .vod && record.jellyfinServerId == (ownerID ?? server.id).uuidString {
            guard HistoryService.isHistoryEnabled(for: record), let position = record.lastPlayedPosition, position > 0,
                  !HistoryService.playbackIsFinished(position: position, duration: record.duration ?? 0) else { continue }
            if let episode = source.episodes.first(where: { $0.url == record.url }) { return episode }
        }
        return nil
    }
    @State private var episodePage = 0
    @State private var detailTask: Task<Void, Never>?

    private let playbackCoordinator = TVPlaybackCoordinator.shared
    @State private var detailedItem: VODItem?
    @State private var selectedSourceIndex = 0
    @State private var isLoadingDetail = false

    private var currentItem: VODItem { detailedItem ?? item }

    private var playSources: [VODPlaySource] { currentItem.playSources }

    private var currentSource: VODPlaySource? {
        playSources.first(where: { $0.index == selectedSourceIndex }) ?? playSources.first
    }

    private var posterURL: URL? {
        currentItem.vodPic.flatMap(URL.init(string:))
    }

    private var metadata: String {
        [currentItem.typeName, currentItem.vodYear, currentItem.vodArea]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        TVPageScrollView(
            title: currentItem.vodName,
            subtitle: metadata.isEmpty ? nil : metadata,
            handlesExitCommand: true
        ) {
            detailHeader

            if isLoadingDetail && playSources.isEmpty {
                loadingDetailState
            } else if playSources.isEmpty {
                emptyEpisodesState
            } else {
                if playSources.count > 1 {
                    sourceShelf
                }
                if let currentSource {
                    episodeGrid(for: currentSource)
                }
            }
            VODDetailMetadata(item: currentItem, server: server)
        }
        .onAppear { loadDetailIfNeeded() }
        .onDisappear { detailTask?.cancel(); isLoadingDetail = false }
        .onChange(of: selectedSourceIndex) { _ in episodePage = 0 }
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: 34) {
            TVRemoteArtworkView(
                url: posterURL,
                server: server,
                placeholderSystemImageName: "film"
            )
            .frame(width: 240, height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

            VStack(alignment: .leading, spacing: 18) {
                if let remarks = currentItem.vodRemarks?.trimmingCharacters(in: .whitespacesAndNewlines), !remarks.isEmpty {
                    Text(remarks)
                        .font(.title3.weight(.bold))
                        .foregroundColor(TVShellStyle.accentSoft)
                }

                if !currentItem.cleanSynopsis.isEmpty {
                    Text(currentItem.cleanSynopsis)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundColor(TVShellStyle.secondary)
                        .lineLimit(5)
                        .frame(maxWidth: 920, alignment: .leading)
                }

                if let source = currentSource, let episode = preferredEpisode(source) ?? source.episodes.first {
                    Button(action: { play(episode, in: source) }) {
                        TVMaintenanceButtonLabel(
                            title: platformShellString(preferredEpisode(source) == nil ? "Play" : "Resume"),
                            systemImageName: "play.fill"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                    .frame(maxWidth: 460)
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvFocusSectionIfAvailable()
    }

    private var sourceShelf: some View {
        VStack(alignment: .leading, spacing: 14) {
            TVShelfSectionPlainHeader(
                title: platformShellString("Sources"),
                subtitle: nil,
                systemImage: "rectangle.stack",
                server: nil,
                headerAccessory: nil
            )

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(playSources) { source in
                        Button(action: { selectedSourceIndex = source.index }) {
                            Text(source.name)
                                .font(.system(size: 21, weight: .bold))
                                .lineLimit(1)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(TVCategoryTabButtonStyle(isSelected: selectedSourceIndex == source.index))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 8)
            }
            .tvFocusSectionIfAvailable()
        }
    }

    private func episodeGrid(for source: VODPlaySource) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            TVShelfSectionPlainHeader(
                title: platformShellString("Episodes"),
                subtitle: MediaCountFormatter.format(count: source.episodes.count, libraryType: JellyfinLibrary.LibraryType.mixed),
                systemImage: "list.number",
                server: nil,
                headerAccessory: nil
            )

            if source.episodes.count > 48 {
                HStack(spacing: 24) {
                    Button(platformShellString("Previous")) { episodePage -= 1 }.disabled(episodePage == 0)
                    Text("\(episodePage * 48 + 1)–\(min((episodePage + 1) * 48, source.episodes.count))")
                    Button(platformShellString("Next")) { episodePage += 1 }
                        .disabled((episodePage + 1) * 48 >= source.episodes.count)
                }.tvFocusSectionIfAvailable()
            }
            TVFocusableRowGrid(
                items: Array(source.episodes.dropFirst(episodePage * 48).prefix(48)),
                columnsPerRow: 6,
                columnWidth: 220,
                rowMinHeight: 84,
                columnSpacing: 28,
                rowSpacing: 18
            ) { episode in
                Button(action: { play(episode, in: source) }) {
                    Text(VODEpisode.displayName(episode.name, format: platformShellString("Episode %d")))
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                        .frame(width: 220, height: 66, alignment: .leading)
                        .padding(.horizontal, 18)
                        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(TVCategoryTabButtonStyle(isSelected: false))
            }
        }
    }

    private var loadingDetailState: some View {
        HStack(spacing: 16) {
            ProgressView()
            Text(platformShellString("Loading..."))
                .foregroundColor(TVShellStyle.secondary)
        }
        .font(.title3.weight(.medium))
        .padding(.vertical, 40)
    }

    private var emptyEpisodesState: some View {
        TVInfoPanel(
            title: platformShellString("No items found"),
            message: currentItem.vodName,
            systemImageName: "film"
        )
    }

    private func play(_ episode: VODEpisode, in source: VODPlaySource) {
        let entry = VODCatalogEntry(source: server, item: currentItem)
        let file = entry.file(for: episode, line: source, ownerID: ownerID ?? server.id)
        let playlist = source.episodes.map { entry.file(for: $0, line: source, ownerID: ownerID ?? server.id) }
        playbackCoordinator.play(file: file, playlist: playlist)
    }

    private func loadDetailIfNeeded() {
        guard currentItem.playSources.isEmpty, !isLoadingDetail else { return }
        isLoadingDetail = true

        detailTask?.cancel()
        detailTask = Task {
            let detail = try? await VODService.shared.fetchDetail(server: server, vodId: currentItem.id)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self.detailedItem = detail
                self.isLoadingDetail = false
            }
        }
    }
}
private struct TVVODGroupDetailView: View {
    let owner: ServerConfig
    let group: VODCatalogGroup
    @State private var selected = 0
    var body: some View {
        VStack(spacing: 16) {
            if group.entries.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 20) {
                        ForEach(group.entries.indices, id: \.self) { index in
                            Button { selected = index } label: {
                                Text(group.entries[index].source.name).padding()
                            }.buttonStyle(TVCategoryTabButtonStyle(isSelected: selected == index))
                        }
                    }.padding(.horizontal, 60)
                }.frame(height: 100).tvFocusSectionIfAvailable()
            }
            let entry = group.entries[selected]
            TVVODDetailView(server: entry.source, item: entry.item, ownerID: owner.id).id(entry.id)
        }
    }
}
#endif

#if os(tvOS)
private struct TVVODHomeShelf: View {
    let owner: ServerConfig
    let category: VODCatalog.Category
    @ObservedObject var parent: VODCatalog
    let onOpen: () -> Void
    @StateObject private var preview = VODCatalog()
    @State private var didLoad = false
    @State private var visible = false
    @State private var batches = 0
    var body: some View {
        Group {
            if !preview.groups.isEmpty {
                TVShelfSection(title: platformShellString(category.name), subtitle: nil,
                    systemImage: "film",
                    headerAccessory: AnyView(Button(platformShellString("See All"), action: onOpen))) {
                    ForEach(Array(preview.groups.prefix(12))) { group in
                        TVNavigationLink(destination: TVVODGroupDetailView(owner: owner, group: group)) {
                            TVVODPosterCard(server: group.entries[0].source, item: group.item)
                        }.buttonStyle(TVPlainButtonStyle()).tvDisableSystemFocusEffect()
                    }
                }
            } else if preview.loading || !didLoad { ProgressView().padding() }
            else if !preview.errors.isEmpty { Button(platformShellString(category.name)) { load() } }
        }
        .onAppear { visible = true; if !didLoad { load() } else { fillPreview() } }
        .onDisappear { visible = false; if preview.loading { didLoad = false }; preview.cancel() }
        .onChange(of: parent.revision) { _ in if visible { load() } else { didLoad = false } }
        .onChange(of: preview.loading) { loading in if !loading { fillPreview() } }
    }
    private func load() {
        didLoad = true; batches = 1
        preview.seedCategories(from: parent); preview.reload(owner: owner, category: category.id)
    }
    private func fillPreview() {
        guard visible, didLoad, !preview.loading, preview.groups.count < 12, preview.hasMore, batches < 4 else { return }
        batches += 1
        preview.next()
    }
}
#endif
