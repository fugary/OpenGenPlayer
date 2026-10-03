#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


struct TVNetworkHeroPanel<Actions: View>: View {
    let servers: [ServerConfig]
    let isFilteringPrivateServers: Bool
    let actions: () -> Actions

    private var mediaServerCount: Int {
        servers.filter { $0.type.tvIsMediaLibraryServer }.count
    }

    private var fileServerCount: Int {
        servers.filter { $0.type.tvSupportsFileBrowsing }.count
    }

    private var summaryText: String {
        if servers.isEmpty {
            return platformShellString("Platform Shell TV Empty Servers Body")
        }

        return servers.prefix(4).map(\.name).joined(separator: " • ")
    }

    init(
        servers: [ServerConfig],
        isFilteringPrivateServers: Bool,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.servers = servers
        self.isFilteringPrivateServers = isFilteringPrivateServers
        self.actions = actions
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 44) {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 14) {
                    Image(systemName: "server.rack")
                        .font(.title2.weight(.semibold))
                    Text(platformShellString("Network"))
                        .font(.title2.weight(.semibold))
                }
                .foregroundColor(TVShellStyle.secondary)

                VStack(alignment: .leading, spacing: 12) {
                    Text(platformShellString("Saved Servers"))
                        .font(.system(size: 46, weight: .heavy))
                        .foregroundColor(TVShellStyle.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Text(summaryText)
                        .font(.headline.weight(.medium))
                        .foregroundColor(TVShellStyle.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: 760, alignment: .leading)
                }

                HStack(spacing: 14) {
                    TVNetworkMetricPill(value: "\(servers.count)", label: platformShellString("Saved Servers"))
                    TVNetworkMetricPill(value: "\(mediaServerCount)", label: platformShellString("Browse"))
                    TVNetworkMetricPill(value: "\(fileServerCount)", label: platformShellString("Folder"))
                    if isFilteringPrivateServers {
                        TVNetworkMetricPill(value: platformShellString("On"), label: platformShellString("Hide Locked Items"))
                    }
                }

                HStack(spacing: 18) {
                    actions()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 14) {
                ForEach(servers.prefix(3)) { server in
                    HStack(spacing: 12) {
                        Image(systemName: server.type.systemIconName)
                            .font(.headline.weight(.semibold))
                            .foregroundColor(TVShellStyle.accent)
                            .frame(width: 30)
                        Text(server.name)
                            .font(.headline.weight(.semibold))
                            .foregroundColor(TVShellStyle.primary)
                            .lineLimit(1)
                        Text(server.type.displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundColor(TVShellStyle.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .background(
                        Capsule(style: .continuous)
                            .fill(TVShellStyle.surface)
                    )
                }
            }
            .frame(width: 500, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .leading)
    }
}



struct TVNetworkMetricPill: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.title2.weight(.heavy))
                .foregroundColor(TVShellStyle.primary)
                .lineLimit(1)
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(TVShellStyle.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(width: 146, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(TVShellStyle.surface)
        )
    }
}



struct TVNetworkEmptyHero: View {
    var body: some View {
        HStack(alignment: .center, spacing: 44) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    Image(systemName: "play.tv.fill")
                        .font(.title3.weight(.bold))
                    Text(platformShellString("Network"))
                        .font(.title3.weight(.bold))
                }
                .foregroundColor(TVShellStyle.accentSoft)

                Text(platformShellString("Platform Shell TV Empty Servers Title"))
                    .font(.system(size: 52, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.62)

                Text(platformShellString("Platform Shell TV Empty Servers Body"))
                    .font(.title3.weight(.medium))
                    .foregroundColor(.white.opacity(0.66))
                    .lineLimit(3)
                    .frame(maxWidth: 710, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 18) {
                TVNetworkSourcePreviewCard(type: .jellyfin)
                    .rotationEffect(.degrees(-3))
                    .offset(y: 18)
                TVNetworkSourcePreviewCard(type: .plex)
                    .offset(y: -14)
                TVNetworkSourcePreviewCard(type: .smb)
                    .rotationEffect(.degrees(3))
                    .offset(y: 20)
            }
            .frame(width: 580, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, minHeight: 330, alignment: .leading)
        .padding(.horizontal, 34)
        .padding(.vertical, 34)
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.085),
                            Color(red: 0.05, green: 0.11, blue: 0.16).opacity(0.34),
                            Color.black.opacity(0.22)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 26, x: 0, y: 18)
    }
}



struct TVNetworkSourcePreviewCard: View {
    let type: ServerConfig.ServerType

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                type.tvAccentColor.opacity(0.62),
                                type.tvHeroSecondaryAccentColor.opacity(0.80)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                if let uiImage = UIImage(named: type.iconAssetName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 74, height: 74)
                } else {
                    Image(systemName: type.systemIconName)
                        .font(.system(size: 58, weight: .bold))
                        .foregroundColor(.white.opacity(0.90))
                }
            }
            .frame(height: 142)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: 6) {
                Text(type.displayName)
                    .font(.headline.weight(.bold))
                    .foregroundColor(.white.opacity(0.92))
                    .lineLimit(1)

                Text(platformShellString("Browse"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white.opacity(0.54))
                    .lineLimit(1)
            }
        }
        .frame(width: 168)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color.black.opacity(0.30))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.30), radius: 18, x: 0, y: 12)
    }
}



struct TVNetworkHeroServerPreview: View {
    let server: ServerConfig?
    var showsText: Bool = true

    static var empty: TVNetworkHeroServerPreview {
        TVNetworkHeroServerPreview(server: nil)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            (server?.type.tvHeroAccentColor ?? Color.white).opacity(0.34),
                            Color.white.opacity(0.07),
                            Color.black.opacity(0.62)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: server?.type.systemIconName ?? "plus.circle")
                .font(.system(size: 118, weight: .semibold))
                .foregroundColor(.white.opacity(0.16))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

            if showsText {
                VStack(alignment: .leading, spacing: 10) {
                    Text(server?.name ?? platformShellString("Add Server"))
                        .font(.title2.weight(.bold))
                        .foregroundColor(.white)
                        .lineLimit(2)

                    Text(server?.type.displayName ?? platformShellString("Server"))
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.white.opacity(0.58))
                        .lineLimit(1)
                }
                .padding(26)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.32), radius: 22, x: 0, y: 18)
    }
}



struct TVServerHubView: View {
    @Environment(\.presentationMode) private var presentationMode
    let server: ServerConfig

    @ObservedObject private var historyService = HistoryService.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var privacySpaceService = PrivacySpaceService.shared
    @ObservedObject private var securityService = TVSecurityService.shared
    @AppStorage("enableVideoHistory") private var enableVideoHistory = true
    @AppStorage("enableAudioHistory") private var enableAudioHistory = true
    @State private var pendingServerRemoval = false
    @State private var isTestingConnection = false
    @State private var connectionStatusMessage: String?
    @State private var connectionStatusTitle: String?
    @State private var connectionStatusImageName = "network"
    @State private var connectionStatusColor = Color.white
    @State private var testTask: Task<Void, Never>?
    @State private var mediaLibraryRootNodes: [TVMediaLibraryNode] = []
    @State private var remoteRootFolders: [VideoFile] = []
    @State private var isLoadingMediaRootNodes = false
    @State private var isLoadingRemoteRootFolders = false
    @State private var isShowingPrivacyUnlock = false

    private var historyItems: [VideoFile] {
        _ = enableVideoHistory
        _ = enableAudioHistory
        _ = securityService.hideLockedItems
        _ = securityService.isPrivacySpaceUnlocked
        return historyService.allHistory.filter { file in
            guard HistoryService.isHistoryEnabled(for: file) else { return false }
            guard !tvShouldHidePrivateFile(file) else { return false }
            return file.tvResolvedServer(from: networkService.servers)?.id == server.id
        }
    }

    private var favoriteItems: [FavoriteItem] {
        _ = securityService.hideLockedItems
        _ = securityService.isPrivacySpaceUnlocked
        return favoriteService.favorites.filter { item in
            guard !tvShouldHidePrivateFavorite(item) else { return false }
            return item.file.tvResolvedServer(from: networkService.servers)?.id == server.id
        }
    }

    private var downloadJobs: [DownloadJobGroup] {
        downloadCenter.jobs.filter { $0.serverId == server.id }
    }

    private var groupedHistoryItems: [(type: VideoFile.FileType, items: [VideoFile])] {
        tvGroupedVideoFiles(historyItems)
    }

    private var groupedFavoriteItems: [(type: VideoFile.FileType, items: [FavoriteItem])] {
        tvGroupedFavoriteItems(favoriteItems)
    }

    var body: some View {
        TVPageScrollView(
            title: server.name,
            subtitle: nil,
            handlesExitCommand: true
        ) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: server.type.systemIconName)
                        .font(.title3.weight(.semibold))
                    Text(server.type.displayName)
                        .font(.title3.weight(.semibold))
                }
                Text(tvServerSummary(for: server))
                    .font(.headline)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .tvDetailPanel()

            TVMetricsRow {
                TVMetricCard(
                    title: platformShellString("Play History"),
                    value: "\(historyItems.count)",
                    systemImageName: "clock.arrow.circlepath"
                )
                TVMetricCard(
                    title: platformShellString("Favorites"),
                    value: "\(favoriteItems.count)",
                    systemImageName: "star"
                )
                TVMetricCard(
                    title: platformShellString("Downloads"),
                    value: "\(downloadJobs.count)",
                    systemImageName: "arrow.down.circle"
                )
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 24) {
                    if server.type.tvIsMediaLibraryServer {
                        NavigationLink(destination: TVMediaLibraryBrowserView(server: server, title: server.name, parentNode: nil)) {
                            TVNavigationCard(
                                title: platformShellString("Browse"),
                                subtitle: platformShellString("Platform Shell TV Media Servers Subtitle"),
                                systemImageName: "rectangle.stack"
                            )
                        }
                    }

                    if server.type.tvSupportsFileBrowsing {
                        NavigationLink(destination: TVRemoteBrowserView(server: server, path: "/", rootTitle: server.name)) {
                            TVNavigationCard(
                                title: platformShellString("Browse Root Directory"),
                                subtitle: platformShellString("Platform Shell TV Browse Server Subtitle"),
                                systemImageName: "folder"
                            )
                        }
                    }

                    NavigationLink(destination: TVServerEditorView(existingServer: server, prefilledServer: nil)) {
                        TVNavigationCard(
                            title: platformShellString("Edit Server"),
                            subtitle: server.fullURL,
                            systemImageName: "slider.horizontal.3"
                        )
                    }

                    if securityService.isPrivacySpaceEnabled {
                        Button(action: togglePrivacySpace) {
                            TVNavigationCard(
                                title: platformShellString(
                                    privacySpaceService.isServerMarkedPrivate(server)
                                        ? "Platform Shell TV Remove Server From Privacy Space"
                                        : "Platform Shell TV Add Server To Privacy Space"
                                ),
                                subtitle: server.name,
                                systemImageName: privacySpaceService.isServerMarkedPrivate(server) ? "lock.open" : "lock"
                            )
                        }
                    }

                    if server.type.tvSupportsConnectionTest {
                        Button(action: testConnection) {
                            TVNavigationCard(
                                title: platformShellString("Test Connection"),
                                subtitle: isTestingConnection ? platformShellString("Platform Shell TV Loading") : server.fullURL,
                                systemImageName: isTestingConnection ? "hourglass" : "network"
                            )
                        }
                        .disabled(isTestingConnection)
                    }

                    Button(action: { pendingServerRemoval = true }) {
                        TVNavigationCard(
                            title: platformShellString("Remove Server"),
                            subtitle: server.name,
                            systemImageName: "trash",
                            accentColor: .red,
                            isDestructive: true
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            if isLoadingMediaRootNodes || isLoadingRemoteRootFolders {
                TVLoadingCard()
            }

            if !mediaLibraryRootNodes.isEmpty {
                TVShelfSection(
                    title: platformShellString("Browse"),
                    subtitle: platformShellString("Platform Shell TV Media Servers Subtitle")
                ) {
                    ForEach(mediaLibraryRootNodes) { node in
                        NavigationLink(destination: TVMediaLibraryBrowserView(server: server, title: tvDisplayTitle(from: node.name, type: .folder), parentNode: node)) {
                            TVNavigationCard(
                                title: tvDisplayTitle(from: node.name, type: node.type),
                                subtitle: tvMediaTypeTitle(for: node.type),
                                systemImageName: node.isFolder ? "folder" : node.type.tvSystemImageName
                            )
                        }
                    }
                }
            }

            if !remoteRootFolders.isEmpty {
                TVShelfSection(
                    title: platformShellString("Browse Root Directory"),
                    subtitle: platformShellString("Platform Shell TV Browse Server Subtitle")
                ) {
                    ForEach(remoteRootFolders) { file in
                        NavigationLink(destination: tvServerHubDestination(for: file)) {
                            TVBrowserRow(file: file)
                        }
                    }
                }
            }

            if let connectionStatusTitle, let connectionStatusMessage {
                TVInfoPanel(
                    title: connectionStatusTitle,
                    message: connectionStatusMessage,
                    systemImageName: connectionStatusImageName,
                    tintColor: connectionStatusColor
                )
            }

            if !historyItems.isEmpty {
                ForEach(Array(groupedHistoryItems.enumerated()), id: \.offset) { _, group in
                    TVShelfSection(
                        title: tvMediaTypeTitle(for: group.type),
                        subtitle: platformShellString("Play History"),
                        headerDestination: TVServerHistoryDetailView(server: server)
                    ) {
                        ForEach(Array(group.items.prefix(12))) { file in
                            TVStoredMediaNavigationLink(file: file, intent: .revealParent) {
                                TVMediaCard(file: file)
                            }
                        }
                    }
                }
            }

            if !favoriteItems.isEmpty {
                ForEach(Array(groupedFavoriteItems.enumerated()), id: \.offset) { _, group in
                    TVShelfSection(
                        title: tvMediaTypeTitle(for: group.type),
                        subtitle: platformShellString("Favorites"),
                        headerDestination: TVServerFavoritesDetailView(server: server)
                    ) {
                        ForEach(Array(group.items.prefix(12))) { item in
                            TVStoredMediaNavigationLink(file: item.file, intent: .openItem) {
                                TVMediaCard(file: item.file)
                            }
                        }
                    }
                }
            }

            if !downloadJobs.isEmpty {
                TVShelfSection(
                    title: platformShellString("Downloads"),
                    subtitle: nil,
                    headerDestination: TVServerDownloadsDetailView(server: server)
                ) {
                    ForEach(Array(downloadJobs.prefix(10))) { job in
                        NavigationLink(destination: TVDownloadJobDetailView(jobId: job.id)) {
                            TVDownloadJobCard(job: job)
                        }
                    }
                }
            }
        }
        .navigationTitle(Text(server.name))
        .onAppear {
            loadServerRootPreviews()
        }
        .onDisappear {
            testTask?.cancel()
        }
        .alert(isPresented: $pendingServerRemoval) {
            Alert(
                title: Text(platformShellString("Remove Server")),
                message: Text(platformShellString("Platform Shell TV Remove Server Confirm")),
                primaryButton: .destructive(Text(platformShellString("Remove Server"))) {
                    networkService.deleteServer(server)
                    presentationMode.wrappedValue.dismiss()
                },
                secondaryButton: .cancel(Text(platformShellString("Cancel")))
            )
        }
        .sheet(isPresented: $isShowingPrivacyUnlock, onDismiss: {
            if TVSecurityService.shared.isPrivacySpaceUnlocked {
                _ = privacySpaceService.toggleServerMarkedPrivate(server)
            }
        }) {
            TVPrivacyUnlockSheet(
                title: server.name,
                isPresented: $isShowingPrivacyUnlock
            )
        }
    }

    private func testConnection() {
        isTestingConnection = true
        connectionStatusTitle = nil
        connectionStatusMessage = nil
        connectionStatusImageName = "network"
        connectionStatusColor = .white

        testTask = Task {
            do {
                _ = try await withThrowingTaskGroup(of: ServerConfig.self) { group in
                    group.addTask {
                        try await tvTestServerConnection(server)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        throw NSError(
                            domain: "GenPlayerShell",
                            code: NSURLErrorTimedOut,
                            userInfo: [NSLocalizedDescriptionKey: platformShellString("Connection timed out")]
                        )
                    }
                    guard let result = try await group.next() else {
                        throw CancellationError()
                    }
                    group.cancelAll()
                    return result
                }

                if Task.isCancelled { return }
                await MainActor.run {
                    isTestingConnection = false
                    connectionStatusTitle = platformShellString("Connection Successful")
                    connectionStatusMessage = server.fullURL
                    connectionStatusImageName = "checkmark.circle.fill"
                    connectionStatusColor = .green
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isTestingConnection = false
                    connectionStatusTitle = platformShellString("Connection Failed")
                    connectionStatusMessage = error.localizedDescription
                    connectionStatusImageName = "exclamationmark.triangle.fill"
                    connectionStatusColor = .red
                }
            }
        }
    }

    private func togglePrivacySpace() {
        if privacySpaceService.isServerMarkedPrivate(server), !securityService.isPrivacySpaceUnlocked {
            isShowingPrivacyUnlock = true
            return
        }
        _ = privacySpaceService.toggleServerMarkedPrivate(server)
    }

    @ViewBuilder
    private func tvServerHubDestination(for file: VideoFile) -> some View {
        if file.type == .folder {
            TVRemoteBrowserView(server: server, path: file.url.path, rootTitle: tvDisplayTitle(for: file))
        } else {
            tvStoredMediaDestination(for: file, intent: .revealParent)
        }
    }

    private func loadServerRootPreviews() {
        if server.type.tvIsMediaLibraryServer, mediaLibraryRootNodes.isEmpty, !isLoadingMediaRootNodes {
            isLoadingMediaRootNodes = true
            Task {
                do {
                    let fetched: [TVMediaLibraryNode]
                    switch server.type {
                    case .jellyfin, .emby:
                        fetched = try await tvFetchJellyfinLikeNodes(server: server, parentNode: nil)
                    case .plex:
                        fetched = try await tvFetchPlexNodes(server: server, parentNode: nil)
                    default:
                        fetched = []
                    }
                    if Task.isCancelled { return }
                    Task {
                        await MediaServerSummaryService.shared.refreshSummary(for: server)
                    }
                    await MainActor.run {
                        mediaLibraryRootNodes = Array(fetched.prefix(12))
                        isLoadingMediaRootNodes = false
                    }
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        mediaLibraryRootNodes = []
                        isLoadingMediaRootNodes = false
                    }
                }
            }
        }

        if server.type.tvSupportsFileBrowsing, remoteRootFolders.isEmpty, !isLoadingRemoteRootFolders {
            isLoadingRemoteRootFolders = true
            Task {
                do {
                    let loaded = try await networkService.fetchContents(for: server, at: "/")
                    if Task.isCancelled { return }
                    await MainActor.run {
                        remoteRootFolders = Array(sortVideoFiles(loaded).filter { $0.type == .folder }.prefix(12))
                        isLoadingRemoteRootFolders = false
                    }
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        remoteRootFolders = []
                        isLoadingRemoteRootFolders = false
                    }
                }
            }
        }
    }
}



struct TVMediaServerPresentationRoot: View {
    let server: ServerConfig

    var body: some View {
        Group {
            if server.type == .vod {
                TVVODLibraryView(server: server)
            } else {
                TVMediaLibraryBrowserView(server: server, title: server.name, parentNode: nil)
            }
        }
        .background(TVShellStyle.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }
}



struct TVFileServerPresentationRoot: View {
    let server: ServerConfig
    @Environment(\.tvBrowsingNavigation) private var browsingNavigation
    @Environment(\.presentationMode) private var presentationMode

    var body: some View {
        Group {
            TVRemoteBrowserView(
                server: server,
                path: "/",
                rootTitle: server.name,
                onClose: {
                    if let browsingNavigation {
                        browsingNavigation.onExit()
                    } else {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            )
        }
        .background(TVShellStyle.background.ignoresSafeArea())
        .tvApplyAppTheme()
    }
}

struct TVIPTVPresentationRoot: View {
    let server: ServerConfig
    let onExit: () -> Void

    var body: some View {
        Group {
            TVIPTVPlaylistView(server: server, onExit: onExit)
        }
        .background(TVShellStyle.background.ignoresSafeArea())
        .tvApplyAppTheme()
    }
}
#endif
