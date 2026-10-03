import SwiftUI
import GenPlayerCore
import GenPlayerShell

public struct VODDetailView: View {
    public let server: ServerConfig
    public let item: VODItem
    public var ownerID: UUID?
    var sourceSelector: AnyView?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
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

    @State private var detailedItem: VODItem?
    @State private var selectedSourceIndex: Int = 0
    @State private var isLoadingDetail: Bool = false
    @State private var isSynopsisExpanded: Bool = false
    @State private var fullScreenFile: VideoFile?
    @State private var activePlaylist: [VideoFile]? = nil
    @State private var activeFileToPlay: VideoFile?

    @Environment(\.presentationMode) private var presentationMode

    public init(server: ServerConfig, item: VODItem, ownerID: UUID? = nil, sourceSelector: AnyView? = nil) {
        self.server = server
        self.item = item
        self.ownerID = ownerID
        self.sourceSelector = sourceSelector
    }

    private var currentItem: VODItem {
        detailedItem ?? item
    }

    private var playSources: [VODPlaySource] {
        currentItem.playSources
    }

    private var currentSource: VODPlaySource? {
        playSources.first(where: { $0.index == selectedSourceIndex }) ?? playSources.first
    }

    private var posterURL: URL? {
        currentItem.vodPic.flatMap { URL(string: $0) }
    }

    public var body: some View {
        GeometryReader { geometry in
            let wide = horizontalSizeClass == .regular || geometry.size.width > 600
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                RemoteImage(url: posterURL, placeholderSystemImage: "film", contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .blur(radius: 40).overlay(Color.black.opacity(0.72)).clipped()
                    .ignoresSafeArea()
                RemoteImage(url: posterURL, placeholderSystemImage: "film", contentMode: .fill)
                    .frame(width: geometry.size.width, height: geometry.size.height * 0.55)
                    .clipped()
                    .overlay(LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.65), .black], startPoint: .top, endPoint: .bottom))
                    .ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        headerView(wide: wide)
                        if let sourceSelector { sourceSelector }
                        sourcesAndEpisodesSection
                        VODDetailMetadata(item: currentItem, server: server)
                    }
                    .duoLibraryHorizontalMargins(
                        legacyPadding: max(24, max(UIApplication.currentSafeAreaInsets().left, UIApplication.currentSafeAreaInsets().right)),
                        minimumPadding: 24
                    )
                    .padding(.top, UIApplication.currentSafeAreaInsets().top + 64)
                    .padding(.bottom, 32)
                }
            }
        }
        .ignoresSafeArea(edges: [.top, .horizontal])
        .environment(\.colorScheme, .dark)
        .navigationBarTitle("", displayMode: .inline)
        .navigationBarBackButtonHidden(true)
        .navBarTransparentCompat(isTransparent: true)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { presentationMode.wrappedValue.dismiss() } label: {
                    AppToolbarIcon(systemName: "chevron.left", legacyForegroundColor: .white)
                }
                Button { NavigationUtil.popToRootView() } label: {
                    AppToolbarIcon(systemName: "house", legacyForegroundColor: .white)
                }
            }
        }
        .fullScreenCover(item: $fullScreenFile) { file in
            PlayerView(initialFile: file, playlist: $activePlaylist)
        }
        .onAppear { loadDetailIfNeeded() }
        .onDisappear { detailTask?.cancel(); isLoadingDetail = false }
        .onChange(of: selectedSourceIndex) { _ in episodePage = 0 }
    }

    // MARK: - Header

    @ViewBuilder private func headerView(wide: Bool) -> some View {
        if wide {
            HStack(alignment: .top, spacing: 24) {
                poster(width: 160)
                mainInformation(centered: false)
            }
        } else {
            VStack(spacing: 16) {
                poster(width: 140)
                mainInformation(centered: true)
            }.frame(maxWidth: .infinity)
        }
    }

    private func poster(width: CGFloat) -> some View {
        RemoteImage(url: posterURL, placeholderSystemImage: "film", contentMode: .fill)
            .frame(width: width, height: width * 1.5).clipped().cornerRadius(12)
            .shadow(color: .black.opacity(0.5), radius: 10, x: 0, y: 5)
    }

    private func mainInformation(centered: Bool) -> some View {
        VStack(alignment: centered ? .center : .leading, spacing: 12) {
            Text(currentItem.vodName)
                .font(.system(size: centered ? 24 : 26, weight: .bold))
                .foregroundColor(.white)
                .multilineTextAlignment(centered ? .center : .leading)
            Text([currentItem.vodYear, currentItem.typeName, currentItem.vodArea, currentItem.vodRemarks]
                .compactMap { $0 }.filter { !$0.isEmpty && $0 != "0" }.joined(separator: " · "))
                .font(.system(size: 13)).foregroundColor(.white.opacity(0.82))
                .multilineTextAlignment(centered ? .center : .leading)
            synopsisView
                .multilineTextAlignment(centered ? .center : .leading)
            if let source = currentSource, let episode = preferredEpisode(source) ?? source.episodes.first {
                PrimaryPlaybackCTAButton(
                    title: NSLocalizedString(preferredEpisode(source) == nil ? "Play" : "Resume", comment: ""),
                    progress: nil, isLoading: isLoadingDetail,
                    action: { playEpisode(episode, in: source) })
            } else if isLoadingDetail { ProgressView() }
        }.frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
    }

    // MARK: - Synopsis

    @ViewBuilder
    private var synopsisView: some View {
        let synopsis = currentItem.cleanSynopsis
        if !synopsis.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(synopsis)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.72))
                    .lineLimit(isSynopsisExpanded ? nil : 3)
                    .animation(.easeInOut, value: isSynopsisExpanded)

                if synopsis.count > 100 {
                    Button(action: {
                        isSynopsisExpanded.toggle()
                    }) {
                        Text(isSynopsisExpanded ? NSLocalizedString("Show Less", comment: "") : NSLocalizedString("Show More", comment: ""))
                            .font(.caption.bold())
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Sources and Episodes

    @ViewBuilder
    private var sourcesAndEpisodesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Source selector pills if multiple
            if playSources.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("Sources", comment: ""))
                        .font(.headline)
                        .foregroundColor(.white)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(playSources) { source in
                                Button(action: {
                                    selectedSourceIndex = source.index
                                }) {
                                    Text(source.name)
                                        .font(.subheadline.weight(currentSource?.index == source.index ? .bold : .regular))
                                        .foregroundColor(currentSource?.index == source.index ? .white : .primary)
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 7)
                                        .background(
                                            currentSource?.index == source.index
                                                ? Color.accentColor
                                                : Color(UIColor.secondarySystemFill)
                                        )
                                        .cornerRadius(8)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            // Episode Grid
            if let source = currentSource {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(NSLocalizedString("Episodes", comment: ""))
                            .font(.headline)
                            .foregroundColor(.white)

                        Spacer()

                        Text("\(source.episodes.count) " + NSLocalizedString("episodes", comment: ""))
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.72))
                    }

                    let columns = [
                        GridItem(.adaptive(minimum: 85, maximum: 120), spacing: 8)
                    ]

                    if source.episodes.count > 50 {
                        Picker(NSLocalizedString("Episodes", comment: ""), selection: $episodePage) {
                            ForEach(0..<((source.episodes.count + 49) / 50), id: \.self) { page in
                                Text("\(page * 50 + 1)–\(min((page + 1) * 50, source.episodes.count))").tag(page)
                            }
                        }.pickerStyle(.menu)
                    }
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(source.episodes.dropFirst(episodePage * 50).prefix(50))) { episode in
                            Button(action: {
                                playEpisode(episode, in: source)
                            }) {
                                Text(VODEpisode.displayName(episode.name))
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .padding(.horizontal, 6)
                                    .background(Color(UIColor.secondarySystemFill))
                                    .foregroundColor(.white)
                                    .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if isLoadingDetail {
                HStack {
                    Spacer()
                    ProgressView()
                        .padding()
                    Spacer()
                }
            } else {
                Text(NSLocalizedString("No episodes found", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.72))
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: - Playback

    private func playEpisode(_ episode: VODEpisode, in source: VODPlaySource) {
        let entry = VODCatalogEntry(source: server, item: currentItem)
        let file = entry.file(for: episode, line: source, ownerID: ownerID ?? server.id)
        let playlist = source.episodes.map { ep in
            entry.file(for: ep, line: source, ownerID: ownerID ?? server.id)
        }

        self.activePlaylist = playlist
        self.fullScreenFile = file
    }

    // MARK: - Detail Loading

    private func loadDetailIfNeeded() {
        guard currentItem.playSources.isEmpty else { return }
        isLoadingDetail = true

        detailTask?.cancel()
        detailTask = Task { @MainActor in
            if let detail = try? await VODService.shared.fetchDetail(server: server, vodId: currentItem.id) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.detailedItem = detail
                    self.isLoadingDetail = false
                }
            } else {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.isLoadingDetail = false
                }
            }
        }
    }
}

struct VODGroupDetailView: View {
    let owner: ServerConfig
    let group: VODCatalogGroup
    @State private var selected = 0
    var body: some View {
        let entry = group.entries[selected]
        VODDetailView(server: entry.source, item: entry.item, ownerID: owner.id,
            sourceSelector: group.entries.count > 1 ? AnyView(
                HStack {
                    Text(platformShellString("VOD Sources")).font(.headline)
                    Spacer()
                    Picker(platformShellString("VOD Sources"), selection: $selected) {
                        ForEach(group.entries.indices, id: \.self) { index in
                            Text(group.entries[index].source.name).tag(index)
                        }
                    }.pickerStyle(.menu)
                }
            ) : nil).id(entry.id)
    }
}
