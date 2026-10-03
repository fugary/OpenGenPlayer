#if os(macOS)
import SwiftUI
import AppKit
import GenPlayerCore

struct MacVODCarousel: View {
    let server: ServerConfig
    let items: [VODItem]
    let active: Bool
    let onOpen: (VODItem) -> Void
    @State private var index = 0
    @State private var hovered = false
    @State private var visible = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var entries: [VODItem] { Array(items.prefix(8)) }
    private var canAdvance: Bool {
        active && visible && !hovered && !reduceMotion && scenePhase == .active && entries.count > 1
    }

    private var heroEntries: [MacHomeCarouselEntry] {
        entries.map { item in
            MacHomeCarouselEntry(
                node: MacMediaLibraryNode(
                    id: item.id, name: item.vodName, type: .video, isFolder: false,
                    posterURL: item.vodPic.flatMap(URL.init(string:)),
                    summary: item.cleanSynopsis,
                    metadataLine: [item.vodYear, item.vodRemarks].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                ),
                sourceTitle: item.typeName ?? platformShellString("Browse"),
                sourceSystemImageName: "film"
            )
        }
    }

    var body: some View {
        MacMediaHeroCarousel(
            server: server,
            entries: heroEntries,
            selectedIndex: $index,
            onPrimaryAction: { entry in open(entry.node.id) },
            onOpenDetails: { node in open(node.id) },
            primaryActionTitleOverride: platformShellString("View Details")
        )
        .onHover { hovered = $0 }
        .onChange(of: entries.map(\.id)) { _ in index = 0 }
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task(id: canAdvance) {
            guard canAdvance else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 7_000_000_000) }
                catch { return }
                guard !Task.isCancelled, canAdvance else { return }
                move(1)
            }
        }
    }

    private func open(_ id: String) {
        if let item = entries.first(where: { $0.id == id }) { onOpen(item) }
    }

    private func move(_ delta: Int) {
        guard !entries.isEmpty else { return }
        index = (index + delta + entries.count) % entries.count
    }
}
#endif
