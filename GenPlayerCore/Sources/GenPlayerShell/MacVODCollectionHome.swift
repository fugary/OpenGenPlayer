#if os(macOS)
import Foundation
import Combine
import SwiftUI
import GenPlayerCore

@MainActor
final class MacVODCollectionHomeModel: ObservableObject {
    struct Stream {
        let source: ServerConfig
        let category: VODCategory
        let categories: [VODCategory]
        var pager: MacVODCategoryPager
        var page = 0
        var hasMore = true
    }
    @Published var entries: [MacVODContentKind: [MacVODSearchEntry]] = [:]
    @Published var candidates: [MacVODSearchEntry] = []
    @Published var errors: [String: String] = [:]
    @Published var busy = false
    private var streams: [MacVODContentKind: [Stream]] = [:]
    private var generation = UUID()
    private var allStreams: [MacVODContentKind: [Stream]] = [:]
    private var allEntries: [MacVODContentKind: [MacVODSearchEntry]] = [:]
    @Published private(set) var filters: [MacVODContentKind: String] = [:]

    private func facetKey(_ name: String) -> String {
        (name.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? name)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func facetStreams(_ kind: MacVODContentKind) -> [Stream] {
        var result: [Stream] = []
        var seen = Set<String>()
        for root in allStreams[kind] ?? [] {
            for category in root.categories where category.id != root.category.id {
                var parent = category.typePid.map { String($0.value) }
                var visited = Set<String>()
                while let id = parent, visited.insert(id).inserted {
                    if id == root.category.id {
                        let identity = root.source.id.uuidString + ":" + category.id
                        if seen.insert(identity).inserted {
                            result.append(Stream(source: root.source, category: category, categories: root.categories, pager: MacVODCategoryPager()))
                        }
                        break
                    }
                    parent = root.categories.first(where: { $0.id == id })?.typePid.map { String($0.value) }
                }
            }
        }
        return result
    }

    func facets(_ kind: MacVODContentKind) -> [(id: String, name: String)] {
        var seen = Set<String>()
        return facetStreams(kind).compactMap {
            let key = facetKey($0.category.typeName)
            return seen.insert(key).inserted ? (key, $0.category.typeName) : nil
        }
    }

    func selectFilter(_ filter: String?, kind: MacVODContentKind) async {
        guard !busy, filters[kind] != filter else { return }
        if filters[kind] == nil {
            allStreams[kind] = streams[kind]
            allEntries[kind] = entries[kind]
        }
        filters[kind] = filter
        guard let filter else {
            streams[kind] = allStreams[kind]
            entries[kind] = allEntries[kind]
            return
        }
        streams[kind] = facetStreams(kind).filter { facetKey($0.category.typeName) == filter }
        entries[kind] = []
        await more(kind)
    }

    func groups(_ kind: MacVODContentKind, unfiltered: Bool = false) -> [MacVODSearchGroup] {
        let items = unfiltered && filters[kind] != nil ? allEntries[kind] : entries[kind]
        return MacVODSearchGroup.aggregate(MacVODSearchGroup.interleaved(items ?? []))
    }
    func hasMore(_ kind: MacVODContentKind) -> Bool { streams[kind]?.contains(where: \.hasMore) == true }

    func reload(_ owner: ServerConfig, forceRefresh: Bool = false) async {
        generation = UUID()
        let token = generation
        busy = true
        entries = [:]; candidates = []; errors = [:]; streams = [:]
        allStreams = [:]; allEntries = [:]; filters = [:]
        defer { if token == generation { busy = false } }
        let sources = owner.macVODEndpoints
        for offset in stride(from: 0, to: sources.count, by: 3) {
            guard !Task.isCancelled, token == generation else { return }
            // Publish in configured source order, regardless of response timing.
            var responses: [UUID: ([VODCategory], [VODItem], String?)] = [:]
            await withTaskGroup(of: (UUID, [VODCategory], [VODItem], String?).self) { group in
                for source in sources[offset..<min(offset + 3, sources.count)] {
                    group.addTask {
                        do {
                            let categories = try await VODService.shared.fetchCategories(server: source, forceRefresh: forceRefresh)
                            let items = (try? await VODService.shared.fetchList(server: source))?.items ?? []
                            return (source.id, categories, items, nil)
                        } catch { return (source.id, [], [], error.localizedDescription) }
                    }
                }
                for await response in group {
                    guard !Task.isCancelled, token == generation else { group.cancelAll(); return }
                    responses[response.0] = (response.1, response.2, response.3)
                    // Show a fast source without waiting for the slowest source in this batch.
                    candidates += response.2.prefix(8).map { MacVODSearchEntry(sourceID: response.0, item: $0) }
                    let order = Dictionary(uniqueKeysWithValues: sources.enumerated().map { ($0.element.id, $0.offset) })
                    candidates = candidates.enumerated().sorted {
                        let left = order[$0.element.sourceID] ?? 0
                        let right = order[$1.element.sourceID] ?? 0
                        return left == right ? $0.offset < $1.offset : left < right
                    }.map(\.element)
                }
            }
            guard !Task.isCancelled, token == generation else { return }
            for source in sources[offset..<min(offset + 3, sources.count)] {
                guard let response = responses[source.id] else { continue }
                if let error = response.2 { errors[source.name] = error }
                for category in response.0 {
                    guard let kind = MacVODContentKind.classify(category.typeName), MacVODContentKind.homeKinds.contains(kind) else { continue }
                    // Skip descendants already covered by a mapped ancestor.
                    var parent = category.typePid.map { String($0.value) }
                    var seen: Set<String> = [category.id]
                    var covered = false
                    while let id = parent, let ancestor = response.0.first(where: { $0.id == id }), seen.insert(id).inserted {
                        if MacVODContentKind.classify(ancestor.typeName) == kind { covered = true; break }
                        parent = ancestor.typePid.map { String($0.value) }
                    }
                    if !covered { streams[kind, default: []].append(Stream(source: source, category: category, categories: response.0, pager: MacVODCategoryPager())) }
                }
            }
        }
        allStreams = streams
        let kinds = MacVODContentKind.homeKinds
        var jobs: [(MacVODContentKind, Int)] = []
        for index in 0..<(streams.values.map(\.count).max() ?? 0) {
            for kind in kinds where index < (streams[kind]?.count ?? 0) { jobs.append((kind, index)) }
        }
        for offset in stride(from: 0, to: jobs.count, by: 3) {
            guard !Task.isCancelled, token == generation else { return }
            await withTaskGroup(of: Void.self) { group in
                for (kind, index) in jobs[offset..<min(offset + 3, jobs.count)] {
                    group.addTask { await self.advance(kind, token: token, onlyIndex: index) }
                }
            }
        }
    }

    func more(_ kind: MacVODContentKind) async {
        guard !busy else { return }
        let token = generation
        busy = true
        defer { if token == generation { busy = false } }
        await advance(kind, token: token)
    }

    private func advance(_ kind: MacVODContentKind, token: UUID, onlyIndex: Int? = nil) async {
        guard let current = streams[kind] else { return }
        for offset in stride(from: 0, to: current.count, by: 3) {
            guard !Task.isCancelled, token == generation else { return }
            await withTaskGroup(of: (Int, Stream, [VODItem], String?).self) { group in
                for index in offset..<min(offset + 3, current.count) where current[index].hasMore && (onlyIndex == nil || onlyIndex == index) {
                    var stream = current[index]
                    group.addTask {
                        do {
                            let result = try await stream.pager.load(server: stream.source, categoryID: stream.category.id, categories: stream.categories, page: stream.page + 1)
                            stream.page += 1
                            stream.hasMore = result.totalPages > stream.page
                            return (index, stream, result.items, nil)
                        } catch { return (index, stream, [], error.localizedDescription) }
                    }
                }
                for await result in group {
                    guard !Task.isCancelled, token == generation else { group.cancelAll(); return }
                    streams[kind]?[result.0] = result.1
                    let key = result.1.source.name + " · " + result.1.category.typeName
                    errors[key] = result.3
                    entries[kind, default: []] += result.2.map { MacVODSearchEntry(sourceID: result.1.source.id, item: $0) }
                    // Response timing must not change the preferred source of a merged work.
                    let order = current.map { $0.source.id }.reduce(into: [UUID: Int]()) { map, id in
                        if map[id] == nil { map[id] = map.count }
                    }
                    entries[kind] = (entries[kind] ?? []).enumerated().sorted {
                        let left = order[$0.element.sourceID] ?? 0
                        let right = order[$1.element.sourceID] ?? 0
                        return left == right ? $0.offset < $1.offset : left < right
                    }.map(\.element)
                }
            }
        }
    }
}

struct MacVODCollectionHome: View {
    let owner: ServerConfig
    let refreshID: UUID
    let active: Bool
    @Binding var category: MacVODContentKind?
    let displayMode: LibraryDisplayMode
    let sortOption: String
    let sortAscending: Bool
    let onSelect: (MacVODSearchGroup) -> Void
    @StateObject private var model = MacVODCollectionHomeModel()
    @State private var carouselIndex = 0
    @State private var hovered = false
    @State private var lastRefreshID: UUID?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private struct LoadKey: Equatable { let sources: [VODSourceConfig]; let refresh: UUID }
    private var heroGroups: [MacVODSearchGroup] { Array(MacVODSearchGroup.aggregate(MacVODSearchGroup.interleaved(model.candidates)).prefix(8)) }
    private func heroID(_ group: MacVODSearchGroup) -> String {
        guard let first = group.entries.first else { return "" }
        return first.sourceID.uuidString + ":" + first.item.id
    }
    private var heroEntries: [MacHomeCarouselEntry] {
        heroGroups.compactMap { group in
            guard let item = group.entries.first?.item else { return nil }
            return MacHomeCarouselEntry(node: MacMediaLibraryNode(id: heroID(group), name: item.vodName, type: .video, isFolder: false,
                posterURL: item.vodPic.flatMap(URL.init(string:)), summary: item.cleanSynopsis,
                metadataLine: [item.vodYear, item.vodRemarks].compactMap { $0 }.joined(separator: " · ")),
                sourceTitle: item.typeName ?? platformShellString("Browse"), sourceSystemImageName: "film")
        }
    }
    private func openHero(_ id: String) { if let group = heroGroups.first(where: { heroID($0) == id }) { onSelect(group) } }
    private var canAdvance: Bool { active && category == nil && !hovered && !reduceMotion && scenePhase == .active && heroGroups.count > 1 }

    private func sortedGroups(_ kind: MacVODContentKind) -> [MacVODSearchGroup] {
        let groups = model.groups(kind)
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
            let comparison = value($0.element).localizedStandardCompare(value($1.element))
            if comparison == .orderedSame { return $0.offset < $1.offset }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }.map(\.element)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if let category {
                    Text(platformShellString(category.rawValue)).font(.title2.bold())
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            filterButton(platformShellString("All"), id: nil, kind: category)
                            ForEach(model.facets(category), id: \.id) { facet in
                                filterButton(facet.name, id: facet.id, kind: category)
                            }
                        }
                    }.disabled(model.busy)
                    if displayMode == .list {
                        ForEach(sortedGroups(category)) { group in
                            if let item = group.entries.first?.item { MacVODRow(item: item) { onSelect(group) } }
                        }
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: displayMode == .thumb ? 240 : 150, maximum: displayMode == .thumb ? 300 : 190), alignment: .top)], alignment: .leading, spacing: 20) {
                            ForEach(sortedGroups(category)) { group in card(group) }
                        }
                    }
                    if model.hasMore(category) {
                        Button(platformShellString("Load More")) { Task { await model.more(category) } }.disabled(model.busy)
                    }
                    if model.groups(category).isEmpty && !model.busy { Text(platformShellString("No items found")) }
                } else {
                    if !heroEntries.isEmpty {
                        MacMediaHeroCarousel(server: owner, entries: heroEntries, selectedIndex: $carouselIndex,
                            onPrimaryAction: { openHero($0.node.id) }, onOpenDetails: { openHero($0.id) },
                            primaryActionTitleOverride: platformShellString("View Details"))
                            .padding(.horizontal, -24).padding(.top, -24)
                            .onHover { hovered = $0 }
                    }
                    ForEach(MacVODContentKind.homeKinds) { kind in
                        let groups = model.groups(kind, unfiltered: true)
                        if !groups.isEmpty {
                            MacMediaShelfSection(title: platformShellString(kind.rawValue), systemImageName: "film", onSeeAll: { category = kind }, items: Array(groups.prefix(18)), artworkHeight: MacVODCard.posterHeight(forWidth: 158)) { group in
                                card(group).frame(width: 158)
                            }
                        }
                    }
                }
                if model.busy { ProgressView() }
                if !model.busy && model.candidates.isEmpty && model.entries.values.allSatisfy(\.isEmpty) && model.errors.isEmpty {
                    Text(platformShellString("No items found")).foregroundColor(.secondary)
                }
                ForEach(model.errors.keys.sorted(), id: \.self) { key in
                    Text(key + ": " + (model.errors[key] ?? "")).font(.caption).foregroundColor(.secondary)
                }
            }.padding(24)
        }
        .task(id: LoadKey(sources: owner.macVODSources, refresh: refreshID)) {
            let force = lastRefreshID != nil
            lastRefreshID = refreshID
            await model.reload(owner, forceRefresh: force)
        }
        .task(id: canAdvance) {
            guard canAdvance else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 7_000_000_000) } catch { return }
                guard canAdvance, !Task.isCancelled else { return }
                carouselIndex = (carouselIndex + 1) % heroGroups.count
            }
        }
    }

    private func filterButton(_ title: String, id: String?, kind: MacVODContentKind) -> some View {
        Button { Task { await model.selectFilter(id, kind: kind) } } label: {
            Text(title).fontWeight(model.filters[kind] == id ? .semibold : .regular)
                .foregroundColor(model.filters[kind] == id ? .accentColor : .primary)
        }.buttonStyle(.bordered)
    }

    @ViewBuilder private func card(_ group: MacVODSearchGroup) -> some View {
        if let item = group.entries.first?.item {
            VStack(alignment: .leading) {
                MacVODCard(item: item, showsCategory: false, landscape: category != nil && displayMode == .thumb) { onSelect(group) }
                Text(String(format: platformShellString("VOD Source Count %d"), group.sourceCount))
                    .font(.caption).foregroundColor(.secondary).lineLimit(1)
                    .frame(height: 16, alignment: .topLeading)
            }
        }
    }
}
#endif
