import SwiftUI

struct ProfileView: View {
    @ObservedObject private var historyService = HistoryService.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    private enum DestructiveAction: Identifiable {
        case deleteHistory(VideoFile)
        case removeFavorite(FavoriteItem)

        var id: String {
            switch self {
            case .deleteHistory(let file):
                return "history-\(file.id)"
            case .removeFavorite(let item):
                return "favorite-\(item.id)"
            }
        }
    }

    @State private var fullScreenFile: VideoFile?
    @State private var previewFile: VideoFile?
    @State private var audioSheetFile: VideoFile?
    @State private var connectionErrorMessage: String?
    @State private var pendingDestructiveAction: DestructiveAction?
    @State private var isShowingPrivacyUnlock = false
    
    // Navigation State
    enum NavigationTarget: Identifiable, Hashable {
        case localFolder(URL)
        case remoteFolder(ServerConfig, String, String?)
        case iptvPlaylist(ServerConfig, String?)
        case jellyfinDetail(ServerConfig, String)
        case embyDetail(ServerConfig, String)
        case plexDetail(ServerConfig, String)
        case serverHome(ServerConfig)
        case localHome
        
        var id: String {
            switch self {
            case .localFolder(let url): return "local-\(url.absoluteString)"
            case .remoteFolder(let server, let path, _): return "remote-\(server.id)-\(path)"
            case .iptvPlaylist(let server, let channelId): return "iptv-\(server.id)-\(channelId ?? "")"
            case .jellyfinDetail(let server, let itemId): return "jf-\(server.id)-\(itemId)"
            case .embyDetail(let server, let itemId): return "emby-\(server.id)-\(itemId)"
            case .plexDetail(let server, let itemId): return "plex-\(server.id)-\(itemId)"
            case .serverHome(let server): return "home-\(server.id)"
            case .localHome: return "local-home"
            }
        }
        
        static func == (lhs: NavigationTarget, rhs: NavigationTarget) -> Bool {
            return lhs.id == rhs.id
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }
    
    @State private var navigationSelection: NavigationTarget?
    #if os(iOS)
    @State private var selectedRemoteFolder: RemoteFolderPresentation?
    #endif
    @State private var selectedLibraryServer: ServerConfig?
    @State private var selectedLibraryTargetItemId: String?
    @State private var isValidatingServerConnection = false
    @State private var validatingServerName: String?
    @State private var libraryConnectionTask: Task<Void, Never>?
    @State private var libraryConnectionRequestID = UUID()

    private var shouldHidePrivateHistoryItems: Bool {
        guard securityService.isPrivacySpaceEnabled else { return false }
        if !securityService.isPrivacySpaceUnlocked {
            return true
        }
        if securityService.excludePrivacyFromHistory {
            return !securityService.showPrivateHistory
        }
        return false
    }

    private var visibleHistoryItems: [VideoFile] {
        historyService.allHistory.filter { file in
            guard HistoryService.isHistoryEnabled(for: file) else { return false }
            if shouldHidePrivateHistoryItems && privacySpace.isFileMarkedPrivate(file) {
                return false
            }
            return true
        }
    }

    private var visibleFavoriteItems: [FavoriteItem] {
        favoriteService.favorites.filter { item in
            !securityService.isPrivacySpaceEnabled ||
            securityService.isPrivacySpaceUnlocked ||
            !privacySpace.isFavoriteMarkedPrivate(item)
        }
    }

    private enum FavoriteNavigationIntent {
        case openItem
        case revealInParent
    }

    private var privacySpaceLockButtonLabel: String {
        securityService.isPrivacySpaceUnlocked
            ? NSLocalizedString("Lock Privacy Space Now", comment: "")
            : NSLocalizedString("Unlock Privacy Space", comment: "")
    }
    
    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemGroupedBackground)
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // 1. Header Section
                        profileHeader
                        
                        // 2. Play History Carousel
                        historySection

                        favoritesSection
                    }
                    .padding(.vertical)
                }
                .background(Color.clear)
                .navigationTitle(NSLocalizedString("My Profile", comment: ""))
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        NavigationLink(destination: DownloadCenterView()) {
                            AppToolbarIcon(
                                systemName: "arrow.down.circle",
                                badgeCount: downloadCenter.activeJobs.count
                            )
                            .accessibilityLabel(Text(NSLocalizedString("Downloads", comment: "")))
                            .accessibilityValue(downloadCenter.activeJobs.isEmpty ? Text("") : Text("\(downloadCenter.activeJobs.count)"))
                        }

                        if securityService.isPrivacySpaceEnabled {
                            if securityService.excludePrivacyFromHistory && securityService.isPrivacySpaceUnlocked {
                                Button(action: togglePrivacySpaceEye) {
                                    AppToolbarIcon(
                                        systemName: securityService.showPrivateHistory ? "eye" : "eye.slash",
                                        style: .primary
                                    )
                                    .accessibilityLabel(Text(securityService.showPrivateHistory ? NSLocalizedString("Hide Private History", comment: "") : NSLocalizedString("Show Private History", comment: "")))
                                }
                            }

                            Button(action: togglePrivacySpaceLock) {
                                AppToolbarIcon(
                                    systemName: securityService.isPrivacySpaceUnlocked ? "lock.open" : "lock",
                                    style: .primary
                                )
                                .accessibilityLabel(Text(privacySpaceLockButtonLabel))
                            }
                        }
                    }
                }
                .onAppear {
                    historyService.refresh()
                    favoriteService.refresh()
                }
                .fullScreenCover(item: $fullScreenFile, onDismiss: {
                    historyService.refresh()
                    UIApplication.refreshInterfaceChrome()
                }) { file in
                    fullScreenContent(for: file)
                        .privacyProtectedContent(
                            title: file.name,
                            isProtected: securityService.isPrivacySpaceEnabled &&
                                !securityService.isPrivacySpaceUnlocked &&
                                privacySpace.isFileMarkedPrivate(file)
                        )
                }
                .sheet(item: $audioSheetFile, onDismiss: { historyService.refresh() }) { file in
                    NavigationView {
                        AudioPlayerView(initialFile: file)
                    }
                    .navigationViewStyle(.stack)
                    .privacyProtectedContent(
                        title: file.name,
                        isProtected: securityService.isPrivacySpaceEnabled &&
                            !securityService.isPrivacySpaceUnlocked &&
                            privacySpace.isFileMarkedPrivate(file)
                    )
                }
                .sheet(item: $previewFile, onDismiss: { historyService.refresh() }) { file in
                    previewSheetContent(for: file)
                        .privacyProtectedContent(
                            title: file.name,
                            isProtected: securityService.isPrivacySpaceEnabled &&
                                !securityService.isPrivacySpaceUnlocked &&
                                privacySpace.isFileMarkedPrivate(file)
                        )
                }
                .sheet(isPresented: $isShowingPrivacyUnlock) {
                    PrivacySpaceUnlockView(
                        isPresented: $isShowingPrivacyUnlock,
                        title: NSLocalizedString("Privacy Space", comment: "")
                    )
                }
                #if os(iOS)
                .fullScreenCover(item: $selectedRemoteFolder) { target in
                    RemoteFolderPresentationView(target: target, onExit: { selectedRemoteFolder = nil })
                }
                #endif
                .fullScreenCover(item: $selectedLibraryServer, onDismiss: { selectedLibraryTargetItemId = nil }) { server in
                    NavigationView {
                        if server.type == .jellyfin {
                            JellyfinLibraryView(
                                server: server,
                                networkService: AppNetworkService.shared,
                                onExit: {
                                    selectedLibraryTargetItemId = nil
                                    selectedLibraryServer = nil
                                },
                                targetItemIdToResolve: selectedLibraryTargetItemId
                            )
                        } else if server.type == .emby {
                            EmbyLibraryView(
                                server: server,
                                networkService: AppNetworkService.shared,
                                onExit: {
                                    selectedLibraryTargetItemId = nil
                                    selectedLibraryServer = nil
                                },
                                targetItemIdToResolve: selectedLibraryTargetItemId
                            )
                        } else if server.type == .plex {
                            PlexLibraryView(
                                server: server,
                                networkService: AppNetworkService.shared,
                                onExit: {
                                    selectedLibraryTargetItemId = nil
                                    selectedLibraryServer = nil
                                },
                                targetItemIdToResolve: selectedLibraryTargetItemId
                            )
                        } else if server.type == .iptv {
                            IPTVPlaylistView(
                                server: server,
                                onExit: {
                                    selectedLibraryTargetItemId = nil
                                    selectedLibraryServer = nil
                                },
                                targetChannelIdToResolve: selectedLibraryTargetItemId
                            )
                        }
                    }
                    .navigationViewStyle(.stack)
                    .serverFloatingAudioOverlay()
                    .privacyProtectedContent(
                        title: server.name,
                        isProtected: securityService.isPrivacySpaceEnabled &&
                            !securityService.isPrivacySpaceUnlocked &&
                            privacySpace.isServerMarkedPrivate(server)
                    )
                }
                .background(
                    NavigationLink(
                        destination: targetDestination(for: navigationSelection),
                        isActive: Binding(
                            get: { navigationSelection != nil },
                            set: { if !$0 { navigationSelection = nil } }
                        ),
                        label: { EmptyView() }
                    )
                )
                .overlay(
                    Group {
                        if isValidatingServerConnection {
                            ConnectionProgressOverlay(
                                title: NSLocalizedString("Connecting...", comment: ""),
                                subtitle: validatingServerName
                            ) {
                                cancelLibraryConnection()
                            }
                        }
                    }
                )
                .appErrorAlert(
                    message: $connectionErrorMessage,
                    title: NSLocalizedString("Unable to Connect", comment: "")
                )
            }
            .background(Color(UIColor.systemGroupedBackground))
        }
        .navigationViewStyle(.stack)
        .alert(item: $pendingDestructiveAction) { action in
            switch action {
            case .deleteHistory(let file):
                return Alert(
                    title: Text(NSLocalizedString("Delete History", comment: "")),
                    message: Text(String(format: NSLocalizedString("Remove \"%@\" from history?", comment: ""), file.name)),
                    primaryButton: .destructive(Text(NSLocalizedString("Delete", comment: ""))) {
                        historyService.removeFromHistory(file)
                    },
                    secondaryButton: .cancel(Text(NSLocalizedString("Cancel", comment: "")))
                )
            case .removeFavorite(let item):
                return Alert(
                    title: Text(NSLocalizedString("Remove Favorite", comment: "")),
                    message: Text(item.file.name),
                    primaryButton: .destructive(Text(NSLocalizedString("Remove Favorite", comment: ""))) {
                        favoriteService.remove(item)
                    },
                    secondaryButton: .cancel(Text(NSLocalizedString("Cancel", comment: "")))
                )
            }
        }
    }
    
    // MARK: - Subviews
    
    @ViewBuilder
    private func targetDestination(for target: NavigationTarget?) -> some View {
        if let target = target {
            switch target {
            case .localFolder(let url):
                FilesListView(url: url)
            case .remoteFolder(let server, let path, let targetFileId):
                RemoteFileListView(server: server, path: path, networkService: AppNetworkService.shared, targetFileIdToResolve: targetFileId)
            case .iptvPlaylist(let server, _):
                IPTVPlaylistView(server: server, onExit: { navigationSelection = nil })
            case .jellyfinDetail(let server, let itemId):
                JellyfinLibraryView(server: server, networkService: AppNetworkService.shared, targetItemIdToResolve: itemId)
            case .embyDetail(let server, let itemId):
                EmbyLibraryView(server: server, networkService: AppNetworkService.shared, targetItemIdToResolve: itemId)
            case .plexDetail(let server, let itemId):
                PlexLibraryView(server: server, networkService: AppNetworkService.shared, targetItemIdToResolve: itemId)
            case .serverHome(let server):
                if server.type == .jellyfin {
                    JellyfinLibraryView(server: server, networkService: AppNetworkService.shared)
                } else if server.type == .emby {
                    EmbyLibraryView(server: server, networkService: AppNetworkService.shared)
                } else if server.type == .plex {
                    PlexLibraryView(server: server, networkService: AppNetworkService.shared)
                } else if server.type == .iptv {
                    IPTVPlaylistView(server: server, onExit: { navigationSelection = nil })
                } else {
                    RemoteFileListView(server: server, networkService: AppNetworkService.shared)
                }
            case .localHome:
                FilesListView(url: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!)
            }
        } else {
            EmptyView()
        }
    }
    
    private var profileHeader: some View {
        HStack(spacing: 16) {
            Image(systemName: "play.tv.fill")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .foregroundColor(.blue)
                .padding(10)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(12)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Gen Player", comment: ""))
                    .font(.title2)
                    .fontWeight(.bold)
                Text(NSLocalizedString("Welcome to Gen Player", comment: ""))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
    }
    
    private var historySection: some View {
        VStack(spacing: 12) {
            // Section Header
            HStack {
                Label(NSLocalizedString("Play History", comment: ""), systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                NavigationLink(destination: RecordListView()) {
                    HStack(spacing: 4) {
                        Text(NSLocalizedString("View All", comment: ""))
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline)
                    .foregroundColor(.blue)
                }
            }
            .padding(.horizontal)
            
            historySectionContent
        }
    }

    @ViewBuilder
    private var historySectionContent: some View {
        if historyService.allHistory.isEmpty {
            MediaCollectionEmptyStateCard(
                systemImage: "clock.arrow.circlepath",
                title: NSLocalizedString("No play history yet", comment: ""),
                density: .compact
            )
            .padding(.horizontal)
        } else if visibleHistoryItems.isEmpty {
            MediaCollectionEmptyStateCard(
                systemImage: "clock.arrow.circlepath",
                title: NSLocalizedString("No play history yet", comment: ""),
                density: .compact
            )
            .padding(.horizontal)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    // Show up to 10 most recent items across all groups
                    ForEach(visibleHistoryItems.prefix(10)) { file in
                        HistoryInteractionCard(
                            file: file,
                            onArtworkTap: { openFile(file) },
                            onTextTap: {
                                if let navTarget = getNavigationTarget(for: file) {
                                    openNavigationTarget(navTarget)
                                } else {
                                    openFile(file)
                                }
                            }
                        )
                        .contextMenu {
                            if let navTarget = getNavigationTarget(for: file) {
                                Button(action: {
                                    openNavigationTarget(navTarget)
                                }) {
                                    Label(
                                        shouldOpenHistoryAsLibraryDetail(file)
                                            ? NSLocalizedString("View Details", comment: "")
                                            : NSLocalizedString("Show in Folder", comment: ""),
                                        systemImage: shouldOpenHistoryAsLibraryDetail(file) ? "info.circle" : "folder"
                                    )
                                }
                            }
                            
                            deleteHistoryMenuButton(file)
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
    private var favoritesSection: some View {
        VStack(spacing: 12) {
            HStack {
                Label(NSLocalizedString("Favorites", comment: ""), systemImage: "star.fill")
                    .font(.headline)
                Spacer()
                NavigationLink(destination: FavoritesListView()) {
                    HStack(spacing: 4) {
                        Text(NSLocalizedString("View All", comment: ""))
                        Image(systemName: "chevron.right")
                    }
                    .font(.subheadline)
                    .foregroundColor(.blue)
                }
            }
            .padding(.horizontal)

            favoritesSectionContent
        }
    }

    @ViewBuilder
    private var favoritesSectionContent: some View {
        if favoriteService.favorites.isEmpty || visibleFavoriteItems.isEmpty {
            MediaCollectionEmptyStateCard(
                systemImage: "star.fill",
                title: NSLocalizedString("No favorites yet", comment: ""),
                density: .compact
            )
            .padding(.horizontal)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(visibleFavoriteItems.prefix(10)) { item in
                        favoriteCard(for: item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    @ViewBuilder
    private func favoriteCard(for item: FavoriteItem) -> some View {
        HistoryInteractionCard(
            file: item.file,
            onArtworkTap: { openFavoritePrimaryAction(for: item) },
            onTextTap: {
                if let navTarget = getNavigationTarget(for: item) {
                    openNavigationTarget(navTarget)
                } else {
                    openFavoritePrimaryAction(for: item)
                }
            }
        )
        .contextMenu {
            if shouldOpenFavoriteAsLibraryDetail(item.file),
               let navTarget = getNavigationTarget(for: item) {
                Button(action: {
                    openNavigationTarget(navTarget)
                }) {
                    Label(NSLocalizedString("View Details", comment: ""), systemImage: "info.circle")
                }
            } else if item.file.serverType == .iptv,
                      let navTarget = getNavigationTarget(for: item) {
                Button(action: {
                    openNavigationTarget(navTarget)
                }) {
                    Label(NSLocalizedString("View in Playlist", comment: ""), systemImage: "play.tv")
                }
            } else if let navTarget = getNavigationTarget(for: item) {
                Button(action: {
                    openNavigationTarget(navTarget)
                }) {
                    Label(NSLocalizedString("Show in Folder", comment: ""), systemImage: "folder")
                }
            }
            removeFavoriteMenuButton(item)
        }
    }
    
    private func getNavigationTarget(for file: VideoFile) -> NavigationTarget? {
        if file.isRemote {
            guard let server = file.resolvedServer else { return nil }
            if server.type == .jellyfin, let itemId = file.jellyfinItemId {
                return .jellyfinDetail(server, itemId)
            } else if server.type == .emby, let itemId = file.jellyfinItemId { // Note: Emby also uses jellyfinItemId conceptually in VideoFile
                return .embyDetail(server, itemId)
            } else if server.type == .plex, let itemId = file.jellyfinItemId {
                return .plexDetail(server, itemId)
            } else if server.type == .iptv {
                return .iptvPlaylist(server, file.jellyfinItemId)
            } else if server.type.isFileServer {
                let folderPath = file.type == .folder ? file.remoteDownloadPath : file.remoteFolderPath
                return .remoteFolder(server, folderPath, file.id)
            }
            return nil
        } else {
            let folderURL = file.type == .folder ? file.url : file.url.deletingLastPathComponent()
            return .localFolder(folderURL)
        }
    }

    private func getNavigationTarget(for item: FavoriteItem, intent: FavoriteNavigationIntent = .revealInParent) -> NavigationTarget? {
        let file = item.file
        if file.isRemote {
            guard let server = file.resolvedServer else { return nil }
            let libraryTargetItemId = preferredLibraryTargetItemId(for: file)
            if server.type == .jellyfin, let itemId = libraryTargetItemId {
                return .jellyfinDetail(server, itemId)
            } else if server.type == .emby, let itemId = libraryTargetItemId { // Note: Emby also uses jellyfinItemId conceptually in VideoFile
                return .embyDetail(server, itemId)
            } else if server.type == .plex, let itemId = libraryTargetItemId {
                return .plexDetail(server, itemId)
            } else if server.type == .iptv {
                return .iptvPlaylist(server, file.jellyfinItemId)
            } else if server.type.isFileServer {
                let folderPath: String
                let targetId: String?
                if file.type == .folder && intent == .openItem {
                    folderPath = favoriteFolderPath(for: item)
                    targetId = nil
                } else {
                    folderPath = file.remoteFolderPath
                    targetId = file.id
                }
                return .remoteFolder(server, folderPath, targetId)
            }
            return nil
        } else {
            let folderURL = file.type == .folder && intent == .openItem
                ? file.url
                : file.url.deletingLastPathComponent()
            return .localFolder(folderURL)
        }
    }

    private func favoriteFolderPath(for item: FavoriteItem) -> String {
        if let folderPath = item.folderPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !folderPath.isEmpty {
            return folderPath
        }
        if let serverPath = item.file.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serverPath.isEmpty {
            return serverPath
        }
        let urlPath = item.file.url.path
        return urlPath.isEmpty ? "/" : urlPath
    }

    private func preferredLibraryTargetItemId(for file: VideoFile) -> String? {
        if let seriesId = file.seriesId, !seriesId.isEmpty {
            return seriesId
        }
        return file.jellyfinItemId
    }

    private func shouldOpenHistoryAsLibraryDetail(_ file: VideoFile) -> Bool {
        guard file.isRemote,
              file.jellyfinItemId != nil,
              let server = file.resolvedServer else {
            return false
        }
        return server.type == .jellyfin || server.type == .emby || server.type == .plex
    }

    private func shouldOpenFavoriteAsLibraryDetail(_ file: VideoFile) -> Bool {
        guard file.isRemote,
              preferredLibraryTargetItemId(for: file) != nil,
              let server = file.resolvedServer else {
            return false
        }
        return server.type == .jellyfin || server.type == .emby || server.type == .plex
    }

    @ViewBuilder
    private func fullScreenContent(for file: VideoFile) -> some View {
        if file.type == .video || (file.type == .folder && file.jellyfinItemId != nil) {
            PlayerView(initialFile: file)
        } else if file.serverType == .jellyfin || file.serverType == .emby {
            PlayerView(initialFile: file)
        } else if file.type != .audio && file.type != .image {
            PlayerView(initialFile: file)
        } else {
            Text(NSLocalizedString("Unsupported file type", comment: ""))
        }
    }

    @ViewBuilder
    private func previewSheetContent(for file: VideoFile) -> some View {
        PreviewSheetContainer {
            if file.isRemote {
                ResolvedRemoteFilePreviewLoader(file: file)
            } else {
                FilePreviewContentView(
                    file: file,
                    imagePlaylist: [file],
                    isImageIsolated: true
                )
            }
        }
    }

    private func openFile(_ file: VideoFile) {
        if file.serverType == .iptv || file.isLiveStream {
            presentFile(file)
            return
        }

        let playbackFile = downloadCenter.localPlaybackFile(for: file) ?? file

        if !playbackFile.isRemote {
            if !FileManager.default.fileExists(atPath: playbackFile.url.path) {
                connectionErrorMessage = NSLocalizedString("The local file does not exist or has been deleted.", comment: "")
                return
            }
            presentFile(playbackFile)
            return
        }

        guard requiresRemotePlaybackValidation(for: playbackFile),
              let server = playbackFile.resolvedServer else {
            presentFile(playbackFile)
            return
        }

        libraryConnectionTask?.cancel()
        let requestID = UUID()
        libraryConnectionRequestID = requestID
        libraryConnectionTask = Task {
            await validateAndOpenFile(playbackFile, server: server, requestID: requestID)
        }
    }

    private func openFavoritePrimaryAction(for item: FavoriteItem) {
        if let navTarget = getNavigationTarget(for: item, intent: .openItem),
           item.file.type == .folder {
            openNavigationTarget(navTarget)
            return
        }

        if item.file.type == .folder {
            return
        }

        openFile(item.file)
    }

    private func openNavigationTarget(_ target: NavigationTarget) {
        switch target {
        case .jellyfinDetail(let server, let itemId):
            presentLibrary(server: server, targetItemId: itemId)
        case .embyDetail(let server, let itemId):
            presentLibrary(server: server, targetItemId: itemId)
        case .plexDetail(let server, let itemId):
            presentLibrary(server: server, targetItemId: itemId)
        case .iptvPlaylist(let server, let channelId):
            presentLibrary(server: server, targetItemId: channelId)
        #if os(iOS)
        case .remoteFolder(let server, let path, let targetFileId):
            navigationSelection = nil
            selectedRemoteFolder = RemoteFolderPresentation(server: server, path: path, targetFileId: targetFileId)
        case .serverHome(let server) where server.type.isFileServer:
            navigationSelection = nil
            selectedRemoteFolder = RemoteFolderPresentation(server: server)
        #endif
        case .serverHome(let server) where server.type == .jellyfin || server.type == .emby || server.type == .plex || server.type == .iptv:
            presentLibrary(server: server, targetItemId: nil)
        default:
            navigationSelection = target
        }
    }

    private func presentLibrary(server: ServerConfig, targetItemId: String?) {
        navigationSelection = nil
        libraryConnectionTask?.cancel()
        let requestID = UUID()
        libraryConnectionRequestID = requestID
        libraryConnectionTask = Task {
            await validateAndPresentLibrary(server: server, targetItemId: targetItemId, requestID: requestID)
        }
    }

    private func validateAndOpenFile(_ file: VideoFile, server: ServerConfig, requestID: UUID) async {
        await MainActor.run {
            guard libraryConnectionRequestID == requestID else { return }
            isValidatingServerConnection = true
            validatingServerName = server.name
        }

        do {
            let validatedFile = try await PlaybackResourceValidator.validatePlayback(for: file)
            await MainActor.run {
                guard libraryConnectionRequestID == requestID, !Task.isCancelled else { return }
                isValidatingServerConnection = false
                validatingServerName = nil
                libraryConnectionTask = nil
                presentFile(validatedFile)
            }
        } catch is CancellationError {
            await MainActor.run {
                guard libraryConnectionRequestID == requestID else { return }
                isValidatingServerConnection = false
                validatingServerName = nil
                libraryConnectionTask = nil
            }
        } catch {
            await MainActor.run {
                guard libraryConnectionRequestID == requestID, !Task.isCancelled else { return }
                isValidatingServerConnection = false
                validatingServerName = nil
                libraryConnectionTask = nil
                connectionErrorMessage = error.localizedDescription
            }
        }
    }

    private func validateAndPresentLibrary(server: ServerConfig, targetItemId: String?, requestID: UUID) async {
        if server.type == .iptv && IPTVService.shared.cachedPlaylist(for: server.id) != nil {
            await MainActor.run {
                guard libraryConnectionRequestID == requestID, !Task.isCancelled else { return }
                AppNetworkService.shared.recordServerAccess(server.id)
                selectedLibraryTargetItemId = targetItemId
                selectedLibraryServer = server
                isValidatingServerConnection = false
                validatingServerName = nil
                libraryConnectionTask = nil
            }
            return
        }

        await MainActor.run {
            guard libraryConnectionRequestID == requestID else { return }
            isValidatingServerConnection = true
            validatingServerName = server.name
        }

        do {
            let validatedServer = try await RemoteConnectionValidator.validate(server: server)

            await MainActor.run {
                guard libraryConnectionRequestID == requestID, !Task.isCancelled else { return }
                AppNetworkService.shared.updateServer(validatedServer)
                AppNetworkService.shared.recordServerAccess(server.id)
                selectedLibraryTargetItemId = targetItemId
                selectedLibraryServer = validatedServer
                isValidatingServerConnection = false
                validatingServerName = nil
                libraryConnectionTask = nil
            }
        } catch is CancellationError {
            await MainActor.run {
                guard libraryConnectionRequestID == requestID else { return }
                isValidatingServerConnection = false
                validatingServerName = nil
                libraryConnectionTask = nil
            }
        } catch {
            await MainActor.run {
                guard libraryConnectionRequestID == requestID, !Task.isCancelled else { return }
                isValidatingServerConnection = false
                validatingServerName = nil
                libraryConnectionTask = nil
                connectionErrorMessage = error.localizedDescription
            }
        }
    }

    private func cancelLibraryConnection() {
        libraryConnectionTask?.cancel()
        libraryConnectionRequestID = UUID()
        libraryConnectionTask = nil
        isValidatingServerConnection = false
        validatingServerName = nil
    }

    private func requiresRemotePlaybackValidation(for file: VideoFile) -> Bool {
        guard file.isRemote else { return false }
        if shouldPlayAsRemoteLibraryItem(file) { return true }
        guard !file.canOpenInPreviewSheet else { return false }
        return file.type == .audio || (file.type != .image && !file.supportsTextPreview)
    }

    private func presentFile(_ file: VideoFile) {
        if file.type == .audio {
            audioSheetFile = file
        } else if shouldPlayAsRemoteLibraryItem(file) {
            fullScreenFile = file
        } else if file.canOpenInPreviewSheet {
            previewFile = file
        } else {
            fullScreenFile = file
        }
    }

    private func togglePrivacySpaceEye() {
        withAnimation {
            securityService.showPrivateHistory.toggle()
        }
    }

    private func togglePrivacySpaceLock() {
        if securityService.isPrivacySpaceUnlocked {
            securityService.lockPrivacySpace()
        } else {
            isShowingPrivacyUnlock = true
        }
    }

    private func shouldPlayAsRemoteLibraryItem(_ file: VideoFile) -> Bool {
        guard file.isRemote,
              file.type != .image,
              let serverType = file.serverType else {
            return false
        }
        return serverType == .jellyfin || serverType == .emby || serverType == .plex
    }

    @ViewBuilder
    private func deleteHistoryMenuButton(_ file: VideoFile) -> some View {
        if #available(iOS 15.0, *) {
            Button(role: .destructive) {
                pendingDestructiveAction = .deleteHistory(file)
            } label: {
                Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
            }
        } else {
            Button(action: { pendingDestructiveAction = .deleteHistory(file) }) {
                Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private func removeFavoriteMenuButton(_ item: FavoriteItem) -> some View {
        if #available(iOS 15.0, *) {
            Button(role: .destructive) {
                pendingDestructiveAction = .removeFavorite(item)
            } label: {
                Label(NSLocalizedString("Remove Favorite", comment: ""), systemImage: "star.slash")
            }
        } else {
            Button(action: { pendingDestructiveAction = .removeFavorite(item) }) {
                Label(NSLocalizedString("Remove Favorite", comment: ""), systemImage: "star.slash")
            }
        }
    }
}

struct DownloadCenterView: View {
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared

    @State private var selectedSegment = 0
    @State private var pendingDestructiveAction: PendingDestructiveAction?
    @State private var selectedDownloadFolderURL: URL?
    @State private var expandedJobIDs = Set<UUID>()
    @State private var hasAppliedInitialSegment = false

    enum NavigationTarget: Identifiable, Hashable {
        case localFolder(URL)
        case remoteFolder(ServerConfig, String, String?)
        case jellyfinDetail(ServerConfig, String)
        case embyDetail(ServerConfig, String)
        case plexDetail(ServerConfig, String)
        
        var id: String {
            switch self {
            case .localFolder(let url): return "local-\(url.absoluteString)"
            case .remoteFolder(let server, let path, _): return "remote-\(server.id)-\(path)"
            case .jellyfinDetail(let server, let itemId): return "jf-\(server.id)-\(itemId)"
            case .embyDetail(let server, let itemId): return "emby-\(server.id)-\(itemId)"
            case .plexDetail(let server, let itemId): return "plex-\(server.id)-\(itemId)"
            }
        }
        
        static func == (lhs: NavigationTarget, rhs: NavigationTarget) -> Bool {
            return lhs.id == rhs.id
        }
        
        func hash(into hasher: inout Hasher) {
            hasher.combine(id)
        }
    }

    @State private var navigationSelection: NavigationTarget?
    @State private var selectedLibraryServer: ServerConfig?
    @State private var selectedLibraryTargetItemId: String?
    @State private var isValidatingServerConnection = false
    @State private var validatingServerName: String?
    @State private var libraryConnectionTask: Task<Void, Never>?
    @State private var libraryConnectionRequestID = UUID()

    private struct JobSection: Identifiable {
        let date: Date
        let jobs: [DownloadJobGroup]

        var id: Date { date }
    }

    private enum SectionActionKind {
        case cancelDownloads
        case deleteFiles
        case deleteRecords
    }

    private struct PendingDestructiveAction: Identifiable {
        let kind: SectionActionKind
        let recordCount: Int
        let message: String
        let sectionDate: Date?
        let statuses: [DownloadTaskStatus]?
        let jobId: UUID?

        var id: String {
            if let jobId = jobId {
                return "job-\(jobId.uuidString)-\(kind)-\(recordCount)"
            }
            let timestamp = sectionDate?.timeIntervalSince1970 ?? 0
            return "section-\(timestamp)-\(kind)-\(recordCount)"
        }
    }

    private struct DownloadJobMenuSnapshot: Equatable {
        let jobId: UUID
        let bucket: DownloadJobGroup.Bucket
        let primaryStatus: DownloadTaskStatus
        let itemCount: Int
        let folderPath: String?
        let hasNavigationTarget: Bool

        var hasFolder: Bool { folderPath != nil }

        init(job: DownloadJobGroup, folderURL: URL?, hasNavigationTarget: Bool) {
            jobId = job.id
            bucket = job.bucket ?? .completed
            primaryStatus = job.primaryStatus
            itemCount = job.itemCount
            folderPath = folderURL?.standardizedFileURL.path
            self.hasNavigationTarget = hasNavigationTarget
        }
    }

    private struct DownloadJobOverflowMenu: View, Equatable {
        let snapshot: DownloadJobMenuSnapshot
        let openFolder: () -> Void
        let openNavigation: (() -> Void)?
        let togglePauseResume: () -> Void
        let retry: () -> Void
        let cancel: () -> Void
        let deleteFiles: () -> Void
        let deleteRecords: () -> Void

        static func == (lhs: DownloadJobOverflowMenu, rhs: DownloadJobOverflowMenu) -> Bool {
            lhs.snapshot == rhs.snapshot
        }

        var body: some View {
            Menu {
                if let openNavigation = openNavigation, snapshot.hasNavigationTarget {
                    Button(action: openNavigation) {
                        Label(NSLocalizedString("View Details", comment: ""), systemImage: "info.circle")
                    }
                }

                if snapshot.hasFolder {
                    Button(action: openFolder) {
                        Label(NSLocalizedString("Show in Folder", comment: ""), systemImage: "folder")
                    }
                }

                if snapshot.bucket == .active {
                    Button(action: togglePauseResume) {
                        Label(
                            snapshot.primaryStatus == .paused
                                ? NSLocalizedString("Resume Download", comment: "")
                                : NSLocalizedString("Pause Download", comment: ""),
                            systemImage: snapshot.primaryStatus == .paused ? "play.fill" : "pause.fill"
                        )
                    }

                    if #available(iOS 15.0, *) {
                        Button(role: .destructive, action: cancel) {
                            Label(NSLocalizedString("Cancel Download", comment: ""), systemImage: "xmark.circle")
                        }
                    } else {
                        Button(action: cancel) {
                            Label(NSLocalizedString("Cancel Download", comment: ""), systemImage: "xmark.circle")
                        }
                    }
                } else if snapshot.bucket == .failed {
                    Button(action: retry) {
                        Label(NSLocalizedString("Retry Download", comment: ""), systemImage: "arrow.clockwise")
                    }
                }

                if #available(iOS 15.0, *) {
                    Button(role: .destructive, action: deleteFiles) {
                        Label(
                            snapshot.itemCount > 1
                                ? NSLocalizedString("Delete Files", comment: "")
                                : NSLocalizedString("Delete File", comment: ""),
                            systemImage: "trash"
                        )
                    }

                    Button(role: .destructive, action: deleteRecords) {
                        Label(
                            snapshot.itemCount > 1
                                ? NSLocalizedString("Delete Records", comment: "")
                                : NSLocalizedString("Delete Record", comment: ""),
                            systemImage: "minus.circle"
                        )
                    }
                } else {
                    Button(action: deleteFiles) {
                        Label(
                            snapshot.itemCount > 1
                                ? NSLocalizedString("Delete Files", comment: "")
                                : NSLocalizedString("Delete File", comment: ""),
                            systemImage: "trash"
                        )
                    }

                    Button(action: deleteRecords) {
                        Label(
                            snapshot.itemCount > 1
                                ? NSLocalizedString("Delete Records", comment: "")
                                : NSLocalizedString("Delete Record", comment: ""),
                            systemImage: "minus.circle"
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundColor(.secondary)
                    .font(.body)
                    .padding(.vertical, 8)
                    .padding(.leading, 4)
            }
            .buttonStyle(PlainButtonStyle())
        }
    }

    private var displayedJobs: [DownloadJobGroup] {
        switch selectedSegment {
        case 0: return downloadCenter.activeJobs
        case 1: return downloadCenter.completedJobs
        default: return downloadCenter.failedJobs
        }
    }

    private var displayedSections: [JobSection] {
        let grouped = Dictionary(grouping: displayedJobs) { job in
            Calendar.current.startOfDay(for: job.createdAt)
        }

        return grouped.keys.sorted(by: >).map { day in
            JobSection(
                date: day,
                jobs: grouped[day]?.sorted(by: { $0.createdAt > $1.createdAt }) ?? []
            )
        }
    }

    var body: some View {
        ZStack {
            Color(UIColor.systemBackground)
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    Picker("", selection: $selectedSegment) {
                        Text("\(NSLocalizedString("In Progress", comment: "")) (\(downloadCenter.activeJobs.count))").tag(0)
                        Text("\(NSLocalizedString("Completed", comment: "")) (\(downloadCenter.completedJobs.count))").tag(1)
                        Text("\(NSLocalizedString("Failed", comment: "")) (\(downloadCenter.failedJobs.count))").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 4)

                    if displayedJobs.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "tray")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary.opacity(0.5))
                            Text(NSLocalizedString("No download tasks", comment: ""))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(displayedSections) { section in
                                VStack(alignment: .leading, spacing: 10) {
                                    sectionHeader(for: section)
                                        .padding(.horizontal)

                                    ForEach(section.jobs) { job in
                                        downloadJobCard(job)
                                            .padding(.horizontal)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 12)
            }
            NavigationLink(
                destination: selectedDownloadFolderDestination,
                isActive: Binding(
                    get: { selectedDownloadFolderURL != nil },
                    set: { isActive in
                        if !isActive {
                            selectedDownloadFolderURL = nil
                        }
                    }
                )
            ) {
                EmptyView()
            }
            .hidden()

            NavigationLink(
                destination: targetDestination(for: navigationSelection),
                isActive: Binding(
                    get: { navigationSelection != nil },
                    set: { if !$0 { navigationSelection = nil } }
                )
            ) {
                EmptyView()
            }
            .hidden()
        }
        .navigationTitle(NSLocalizedString("Downloading", comment: ""))
        .fullScreenCover(item: $selectedLibraryServer, onDismiss: { selectedLibraryTargetItemId = nil }) { server in
            NavigationView {
                if server.type == .jellyfin {
                    JellyfinLibraryView(
                        server: server,
                        networkService: AppNetworkService.shared,
                        onExit: {
                            selectedLibraryTargetItemId = nil
                            selectedLibraryServer = nil
                        },
                        targetItemIdToResolve: selectedLibraryTargetItemId
                    )
                } else if server.type == .emby {
                    EmbyLibraryView(
                        server: server,
                        networkService: AppNetworkService.shared,
                        onExit: {
                            selectedLibraryTargetItemId = nil
                            selectedLibraryServer = nil
                        },
                        targetItemIdToResolve: selectedLibraryTargetItemId
                    )
                } else if server.type == .plex {
                    PlexLibraryView(
                        server: server,
                        networkService: AppNetworkService.shared,
                        onExit: {
                            selectedLibraryTargetItemId = nil
                            selectedLibraryServer = nil
                        },
                        targetItemIdToResolve: selectedLibraryTargetItemId
                    )
                } else if server.type == .iptv {
                    IPTVPlaylistView(
                        server: server,
                        onExit: {
                            selectedLibraryTargetItemId = nil
                            selectedLibraryServer = nil
                        },
                        targetChannelIdToResolve: selectedLibraryTargetItemId
                    )
                }
            }
            .navigationViewStyle(.stack)
            .serverFloatingAudioOverlay()
            .privacyProtectedContent(
                title: server.name,
                isProtected: securityService.isPrivacySpaceEnabled &&
                    !securityService.isPrivacySpaceUnlocked &&
                    privacySpace.isServerMarkedPrivate(server)
            )
        }
        .onAppear {
            downloadCenter.reconcileMissingLocalFiles()
            applyInitialSegmentIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            downloadCenter.reconcileMissingLocalFiles()
        }
        .alert(item: $pendingDestructiveAction) { action in
            Alert(
                title: Text(title(for: action)),
                message: Text(action.message),
                primaryButton: .destructive(Text(confirmTitle(for: action))) {
                    confirm(action)
                },
                secondaryButton: .cancel(Text(NSLocalizedString("Cancel", comment: "")))
            )
        }
    }

    private func applyInitialSegmentIfNeeded() {
        guard !hasAppliedInitialSegment else { return }
        hasAppliedInitialSegment = true
        selectedSegment = downloadCenter.activeJobs.isEmpty ? 1 : 0
    }

    @ViewBuilder
    private func sectionHeader(for section: JobSection) -> some View {
        HStack(spacing: 8) {
            Text(section.date, formatter: sectionDateFormatter)
                .font(.footnote.weight(.semibold))
                .foregroundColor(.secondary)

            Spacer()

            if hasMenu(for: section) {
                Menu {
                    sectionHeaderMenu(for: section)
                } label: {
                    sectionCountBadge(section.jobs.count)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                sectionCountBadge(section.jobs.count)
            }
        }
    }

    private func downloadJobCard(_ job: DownloadJobGroup) -> some View {
        let folderURL = downloadedFolderURL(for: job)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Button(action: {
                    handlePrimaryTap(for: job, folderURL: folderURL)
                }) {
                    HStack(alignment: .top, spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(iconBackgroundColor(for: job.primaryStatus))
                                .frame(width: 40, height: 40)

                            Image(systemName: iconName(for: job.primaryStatus))
                                .font(.system(size: 20))
                                .foregroundColor(iconColor(for: job.primaryStatus))
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text(job.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(.primary)
                                .lineLimit(job.isExpandable ? 2 : 1)

                            Text(jobMetadataText(for: job))
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .lineLimit(2)

                            if let detailText = jobDetailText(for: job) {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(detailText)
                                        .font(.system(size: 10))
                                        .foregroundColor(job.primaryStatus == .failed ? .red : .secondary)
                                        .lineLimit(2)

                                    Spacer(minLength: 8)

                                    if job.bucket == .active,
                                       let etaText = estimatedRemainingTimeText(for: job) {
                                        Text(etaText)
                                            .font(.system(size: 10, weight: .regular, design: .rounded))
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }

                            if job.bucket == .active || job.bucket == .failed {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(Color.secondary.opacity(0.2))
                                            .frame(height: 4)

                                        Capsule()
                                            .fill(iconColor(for: job.primaryStatus))
                                            .frame(width: geo.size.width * CGFloat(max(0, min(1, job.aggregateProgress))), height: 4)
                                    }
                                }
                                .frame(height: 4)

                                HStack {
                                    if job.totalBytes > 0 {
                                        Text("\(ByteCountFormatter.string(fromByteCount: job.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file))")
                                            .font(.system(size: 10))
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if let speedText = formattedTransferRate(job.speedBytesPerSec),
                                       job.bucket == .active {
                                        Text(speedText)
                                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }
                                }

                            } else if let locationText = downloadLocationText(for: job) {
                                Text(locationText)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 8)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                HStack(spacing: 10) {
                    if let target = getNavigationTarget(for: job) {
                        Button(action: {
                            openNavigationTarget(target)
                        }) {
                            Image(systemName: "info.circle")
                                .foregroundColor(.blue)
                                .font(.title3)
                        }
                    }

                    if let folderURL = folderURL {
                        Button(action: {
                            selectedDownloadFolderURL = folderURL
                        }) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.blue)
                                .font(.title3)
                        }
                    }

                    if job.bucket == .active {
                        Button(action: {
                            if job.primaryStatus == .paused {
                                downloadCenter.resume(jobId: job.id)
                            } else {
                                downloadCenter.pause(jobId: job.id)
                            }
                        }) {
                            Image(systemName: job.primaryStatus == .paused ? "play.circle.fill" : "pause.circle.fill")
                                .foregroundColor(job.primaryStatus == .paused ? .blue : .secondary)
                                .font(.title3)
                        }
                    } else if job.bucket == .failed {
                        Button(action: {
                            downloadCenter.retry(jobId: job.id)
                        }) {
                            Image(systemName: "arrow.clockwise.circle.fill")
                                .foregroundColor(.blue)
                                .font(.title3)
                        }
                    }

                    DownloadJobOverflowMenu(
                        snapshot: DownloadJobMenuSnapshot(
                            job: job,
                            folderURL: folderURL,
                            hasNavigationTarget: getNavigationTarget(for: job) != nil
                        ),
                        openFolder: {
                            if let folderURL = folderURL {
                                selectedDownloadFolderURL = folderURL
                            }
                        },
                        openNavigation: {
                            if let target = getNavigationTarget(for: job) {
                                openNavigationTarget(target)
                            }
                        },
                        togglePauseResume: {
                            if job.primaryStatus == .paused {
                                downloadCenter.resume(jobId: job.id)
                            } else {
                                downloadCenter.pause(jobId: job.id)
                            }
                        },
                        retry: {
                            downloadCenter.retry(jobId: job.id)
                        },
                        cancel: {
                            queueJobAction(job, kind: .cancelDownloads)
                        },
                        deleteFiles: {
                            queueJobAction(job, kind: .deleteFiles)
                        },
                        deleteRecords: {
                            queueJobAction(job, kind: .deleteRecords)
                        }
                    )
                    .equatable()
                }
            }

            if job.isExpandable {
                Button(action: {
                    toggleJobExpansion(job)
                }) {
                    HStack(spacing: 6) {
                        Text(expandedJobIDs.contains(job.id) ? NSLocalizedString("Hide Items", comment: "") : NSLocalizedString("Show Items", comment: ""))
                            .font(.caption)
                            .fontWeight(.medium)
                        Image(systemName: expandedJobIDs.contains(job.id) ? "chevron.up" : "chevron.down")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundColor(.blue)
                }
                .buttonStyle(PlainButtonStyle())

                if expandedJobIDs.contains(job.id) {
                    VStack(spacing: 8) {
                        ForEach(job.tasks) { task in
                            childTaskRow(task)
                        }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
    }

    private func iconName(for status: DownloadTaskStatus) -> String {
        switch status {
        case .queued: return "clock.fill"
        case .downloading: return "arrow.down.to.line"
        case .paused: return "pause.circle.fill"
        case .completed: return "doc.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .canceled: return "xmark.circle.fill"
        }
    }
    
    private func iconColor(for status: DownloadTaskStatus) -> Color {
        switch status {
        case .queued: return .orange
        case .downloading: return .blue
        case .paused: return .orange
        case .completed: return .green
        case .failed: return .red
        case .canceled: return .gray
        }
    }
    
    private func iconBackgroundColor(for status: DownloadTaskStatus) -> Color {
        iconColor(for: status).opacity(0.15)
    }

    private func message(for kind: SectionActionKind, recordCount: Int, jobTitle: String? = nil) -> String {
        if let jobTitle = jobTitle, !jobTitle.isEmpty {
            return jobTitle
        }

        switch kind {
        case .cancelDownloads:
            if recordCount <= 1 {
                return NSLocalizedString("Are you sure you want to cancel the in-progress download from this date?", comment: "")
            }
            return NSLocalizedString("Are you sure you want to cancel all in-progress downloads from this date?", comment: "")
        case .deleteFiles:
            if recordCount <= 1 {
                return NSLocalizedString("Are you sure you want to delete the downloaded file from this date?", comment: "")
            }
            return NSLocalizedString("Are you sure you want to delete all downloaded files from this date?", comment: "")
        case .deleteRecords:
            if recordCount <= 1 {
                return NSLocalizedString("Are you sure you want to delete the download record from this date?", comment: "")
            }
            return NSLocalizedString("Are you sure you want to delete all download records from this date?", comment: "")
        }
    }

    private func title(for action: PendingDestructiveAction) -> String {
        switch action.kind {
        case .cancelDownloads:
            return NSLocalizedString(action.recordCount <= 1 ? "Cancel Download" : "Cancel Downloads", comment: "")
        case .deleteFiles:
            return NSLocalizedString(action.recordCount <= 1 ? "Delete File" : "Delete Files", comment: "")
        case .deleteRecords:
            return NSLocalizedString(action.recordCount <= 1 ? "Delete Record" : "Delete Records", comment: "")
        }
    }

    private func confirmTitle(for action: PendingDestructiveAction) -> String {
        switch action.kind {
        case .cancelDownloads:
            return NSLocalizedString(action.recordCount <= 1 ? "Cancel Download" : "Cancel Downloads", comment: "")
        case .deleteFiles, .deleteRecords:
            return NSLocalizedString("Delete", comment: "")
        }
    }

    private func queueSectionAction(date: Date, statuses: [DownloadTaskStatus], recordCount: Int, kind: SectionActionKind) {
        pendingDestructiveAction = PendingDestructiveAction(
            kind: kind,
            recordCount: recordCount,
            message: message(for: kind, recordCount: recordCount),
            sectionDate: date,
            statuses: statuses,
            jobId: nil
        )
    }

    private func queueJobAction(_ job: DownloadJobGroup, kind: SectionActionKind) {
        let recordCount: Int
        switch kind {
        case .cancelDownloads:
            recordCount = max(job.tasks.filter(\.isActive).count, 1)
        case .deleteFiles, .deleteRecords:
            recordCount = max(job.itemCount, 1)
        }

        pendingDestructiveAction = PendingDestructiveAction(
            kind: kind,
            recordCount: recordCount,
            message: message(for: kind, recordCount: recordCount, jobTitle: job.title),
            sectionDate: nil,
            statuses: nil,
            jobId: job.id
        )
    }

    private func confirm(_ action: PendingDestructiveAction) {
        defer { pendingDestructiveAction = nil }

        switch action.kind {
        case .cancelDownloads:
            if let jobId = action.jobId {
                downloadCenter.cancel(jobId: jobId)
            } else if let date = action.sectionDate, let statuses = action.statuses {
                downloadCenter.cancelRecords(createdOn: date, statuses: statuses)
            }
        case .deleteFiles:
            if let jobId = action.jobId {
                downloadCenter.removeJob(jobId, deleteLocalFile: true)
            } else if let date = action.sectionDate, let statuses = action.statuses {
                downloadCenter.removeRecords(createdOn: date, statuses: statuses, deleteLocalFiles: true)
            }
        case .deleteRecords:
            if let jobId = action.jobId {
                downloadCenter.removeJob(jobId, deleteLocalFile: false)
            } else if let date = action.sectionDate, let statuses = action.statuses {
                downloadCenter.removeRecords(createdOn: date, statuses: statuses, deleteLocalFiles: false)
            }
        }
    }

    @ViewBuilder
    private var selectedDownloadFolderDestination: some View {
        if let folderURL = selectedDownloadFolderURL {
            FilesListView(url: folderURL)
        } else {
            EmptyView()
        }
    }

    private func getNavigationTarget(for job: DownloadJobGroup) -> NavigationTarget? {
        guard let firstTask = job.tasks.first else { return nil }
        let serverId = job.serverId
        guard let server = AppNetworkService.shared.savedServers.first(where: { $0.id == serverId }) else { return nil }
        
        switch job.sourceType {
        case .jellyfin:
            if let seriesId = firstTask.seriesId, !seriesId.isEmpty {
                return .jellyfinDetail(server, seriesId)
            } else if let itemId = firstTask.remoteItemId, !itemId.isEmpty {
                return .jellyfinDetail(server, itemId)
            }
        case .emby:
            if let seriesId = firstTask.seriesId, !seriesId.isEmpty {
                return .embyDetail(server, seriesId)
            } else if let itemId = firstTask.remoteItemId, !itemId.isEmpty {
                return .embyDetail(server, itemId)
            }
        case .plex:
            if let seriesId = firstTask.seriesId, !seriesId.isEmpty {
                return .plexDetail(server, seriesId)
            } else if let itemId = firstTask.remoteItemId, !itemId.isEmpty {
                return .plexDetail(server, itemId)
            }
        case .smb, .webdav, .alist, .ftp, .sftp, .nfs:
            let folderPath = (firstTask.remotePath as NSString).deletingLastPathComponent
            let finalFolderPath = folderPath.isEmpty ? "/" : folderPath
            return .remoteFolder(server, finalFolderPath, nil)
        default:
            break
        }
        return nil
    }

    private func openNavigationTarget(_ target: NavigationTarget) {
        switch target {
        case .jellyfinDetail(let server, let itemId):
            presentLibrary(server: server, targetItemId: itemId)
        case .embyDetail(let server, let itemId):
            presentLibrary(server: server, targetItemId: itemId)
        case .plexDetail(let server, let itemId):
            presentLibrary(server: server, targetItemId: itemId)
        default:
            navigationSelection = target
        }
    }

    private func presentLibrary(server: ServerConfig, targetItemId: String?) {
        navigationSelection = nil
        libraryConnectionTask?.cancel()
        let requestID = UUID()
        libraryConnectionRequestID = requestID
        libraryConnectionTask = Task {
            await validateAndPresentLibrary(server: server, targetItemId: targetItemId, requestID: requestID)
        }
    }

    private func validateAndPresentLibrary(server: ServerConfig, targetItemId: String?, requestID: UUID) async {
        if server.type == .iptv && IPTVService.shared.cachedPlaylist(for: server.id) != nil {
            await MainActor.run {
                guard libraryConnectionRequestID == requestID, !Task.isCancelled else { return }
                AppNetworkService.shared.recordServerAccess(server.id)
                selectedLibraryTargetItemId = targetItemId
                selectedLibraryServer = server
                isValidatingServerConnection = false
                validatingServerName = nil
                libraryConnectionTask = nil
            }
            return
        }

        await MainActor.run {
            guard libraryConnectionRequestID == requestID else { return }
            isValidatingServerConnection = true
            validatingServerName = server.name
        }

        do {
            let validatedServer = try await RemoteConnectionValidator.validate(server: server)

            await MainActor.run {
                guard libraryConnectionRequestID == requestID, !Task.isCancelled else { return }
                AppNetworkService.shared.updateServer(validatedServer)
                AppNetworkService.shared.recordServerAccess(server.id)
                selectedLibraryTargetItemId = targetItemId
                selectedLibraryServer = validatedServer
                isValidatingServerConnection = false
                validatingServerName = nil
                libraryConnectionTask = nil
            }
        } catch is CancellationError {
            await MainActor.run {
                guard libraryConnectionRequestID == requestID else { return }
                isValidatingServerConnection = false
                validatingServerName = nil
                libraryConnectionTask = nil
            }
        } catch {
            await MainActor.run {
                guard libraryConnectionRequestID == requestID, !Task.isCancelled else { return }
                isValidatingServerConnection = false
                validatingServerName = nil
                libraryConnectionTask = nil
            }
        }
    }

    @ViewBuilder
    private func targetDestination(for target: NavigationTarget?) -> some View {
        if let target = target {
            switch target {
            case .localFolder(let url):
                FilesListView(url: url)
            case .remoteFolder(let server, let path, let targetFileId):
                RemoteFileListView(server: server, path: path, networkService: AppNetworkService.shared, targetFileIdToResolve: targetFileId)
            case .jellyfinDetail(let server, let itemId):
                JellyfinLibraryView(server: server, networkService: AppNetworkService.shared, targetItemIdToResolve: itemId)
            case .embyDetail(let server, let itemId):
                EmbyLibraryView(server: server, networkService: AppNetworkService.shared, targetItemIdToResolve: itemId)
            case .plexDetail(let server, let itemId):
                PlexLibraryView(server: server, networkService: AppNetworkService.shared, targetItemIdToResolve: itemId)
            }
        } else {
            EmptyView()
        }
    }

    private func childTaskRow(_ task: DownloadTaskItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: iconName(for: task.status))
                .foregroundColor(iconColor(for: task.status))
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayTitle)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(childTaskSubtitle(for: task))
                    .font(.system(size: 10))
                    .foregroundColor(task.status == .failed ? .red : .secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(UIColor.systemBackground))
        .cornerRadius(10)
    }

    private func jobMetadataText(for job: DownloadJobGroup) -> String {
        let itemSummary = job.itemCount > 1
            ? String(format: NSLocalizedString("%d Items", comment: ""), job.itemCount)
            : NSLocalizedString("Single Item", comment: "")
        let capabilitySummary = downloadCapabilitySummary(for: job)
        return "\(job.serverName) • \(job.sourceType.displayName) • \(itemSummary) • \(capabilitySummary)"
    }

    private func downloadCapabilitySummary(for job: DownloadJobGroup) -> String {
        let backgroundText: String
        if job.tasks.contains(where: { $0.backgroundCapability == .foregroundOnly }) {
            backgroundText = NSLocalizedString("Foreground only", comment: "")
        } else if job.tasks.allSatisfy({ $0.backgroundCapability == .backgroundTransfer }) {
            backgroundText = NSLocalizedString("Background capable", comment: "")
        } else {
            backgroundText = NSLocalizedString("Background varies", comment: "")
        }

        let resumeText: String
        if job.tasks.contains(where: { $0.resumeCapability == .restartOnly }) {
            resumeText = NSLocalizedString("Restarts on resume", comment: "")
        } else if job.tasks.allSatisfy({ $0.resumeCapability == .resumable }) {
            resumeText = NSLocalizedString("Can resume", comment: "")
        } else {
            resumeText = NSLocalizedString("Resume varies", comment: "")
        }

        return "\(backgroundText) • \(resumeText)"
    }

    private func jobDetailText(for job: DownloadJobGroup) -> String? {
        switch job.bucket {
        case .active:
            let progressText = String(
                format: NSLocalizedString("%d/%d completed", comment: ""),
                job.completedCount,
                job.itemCount
            )
            if job.primaryStatus == .paused {
                return "\(NSLocalizedString("Paused", comment: "")) • \(progressText)"
            }
            return progressText
        case .completed:
            if job.totalBytes > 0 {
                return ByteCountFormatter.string(fromByteCount: job.totalBytes, countStyle: .file)
            }
            return NSLocalizedString("Downloaded", comment: "")
        case .failed:
            if let failedTask = job.tasks.first(where: { $0.status == .failed || $0.status == .canceled }),
               let errorMessage = failedTask.errorMessage,
               !errorMessage.isEmpty {
                return errorMessage
            }
            return String(
                format: NSLocalizedString("%d items need attention", comment: ""),
                max(job.failedCount + job.canceledCount, 1)
            )
        case .none:
            return nil
        }
    }

    private func childTaskSubtitle(for task: DownloadTaskItem) -> String {
        switch task.status {
        case .queued:
            return NSLocalizedString("Queued", comment: "")
        case .downloading:
            if task.bytesTotal > 0 {
                return "\(Int(task.progress * 100))% • \(ByteCountFormatter.string(fromByteCount: task.bytesDownloaded, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: task.bytesTotal, countStyle: .file))"
            }
            return NSLocalizedString("Downloading...", comment: "")
        case .paused:
            return task.errorMessage ?? NSLocalizedString("Paused", comment: "")
        case .completed:
            if task.bytesTotal > 0 {
                return ByteCountFormatter.string(fromByteCount: task.bytesTotal, countStyle: .file)
            }
            return NSLocalizedString("Downloaded", comment: "")
        case .failed:
            return task.errorMessage ?? NSLocalizedString("Failed", comment: "")
        case .canceled:
            return task.errorMessage ?? NSLocalizedString("Canceled by user", comment: "")
        }
    }

    private func toggleJobExpansion(_ job: DownloadJobGroup) {
        if expandedJobIDs.contains(job.id) {
            expandedJobIDs.remove(job.id)
        } else {
            expandedJobIDs.insert(job.id)
        }
    }

    private func handlePrimaryTap(for job: DownloadJobGroup, folderURL: URL?) {
        if job.isExpandable {
            toggleJobExpansion(job)
        } else if let folderURL = folderURL {
            selectedDownloadFolderURL = folderURL
        }
    }

    private func downloadedFolderURL(for job: DownloadJobGroup) -> URL? {
        let folderURLs = job.tasks.compactMap { task -> URL? in
            guard task.status == .completed,
                  let path = task.localFilePath,
                  !path.isEmpty,
                  FileManager.default.fileExists(atPath: path) else {
                return nil
            }
            return URL(fileURLWithPath: path).deletingLastPathComponent()
        }

        guard !folderURLs.isEmpty else {
            return nil
        }
        let unique = Array(Set(folderURLs.map { $0.standardizedFileURL.path })).sorted()
        if let first = unique.first {
            return URL(fileURLWithPath: first)
        }
        return nil
    }

    private func downloadLocationText(for job: DownloadJobGroup) -> String? {
        guard let folderURL = downloadedFolderURL(for: job) else { return nil }
        guard let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return folderURL.lastPathComponent
        }

        let documentsPath = documentsURL.standardizedFileURL.path
        let folderPath = folderURL.standardizedFileURL.path
        if folderPath.hasPrefix(documentsPath) {
            let suffix = String(folderPath.dropFirst(documentsPath.count))
            let relative = suffix.hasPrefix("/") ? String(suffix.dropFirst()) : suffix
            return relative.isEmpty ? "Documents" : relative
        }
        return folderPath
    }

    private func formattedTransferRate(_ bytesPerSecond: Double) -> String? {
        guard bytesPerSecond > 0 else { return nil }

        let kilobyte = 1024.0
        let megabyte = kilobyte * 1024.0
        let gigabyte = megabyte * 1024.0

        if bytesPerSecond >= gigabyte {
            return String(format: "%.2f GB/s", bytesPerSecond / gigabyte)
        }
        if bytesPerSecond >= megabyte {
            return String(format: "%.1f MB/s", bytesPerSecond / megabyte)
        }
        if bytesPerSecond >= kilobyte {
            return String(format: "%.0f KB/s", bytesPerSecond / kilobyte)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    private func estimatedRemainingTimeText(for job: DownloadJobGroup) -> String? {
        let remainingBytes = max(0, job.totalBytes - job.downloadedBytes)
        guard remainingBytes > 0 else { return nil }

        let speedBytesPerSec = job.speedBytesPerSec
        guard speedBytesPerSec > 1 else { return nil }

        let remainingSeconds = Int((Double(remainingBytes) / speedBytesPerSec).rounded(.up))
        guard remainingSeconds > 0 else { return nil }
        return String(
            format: NSLocalizedString("ETA %@",
                                      comment: "Estimated remaining download time"),
            formatDuration(seconds: remainingSeconds)
        )
    }

    private func formatDuration(seconds: Int) -> String {
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    private var sectionDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }

    private var activePauseStatuses: [DownloadTaskStatus] {
        [.queued, .downloading]
    }

    private var activeResumeStatuses: [DownloadTaskStatus] {
        [.paused]
    }

    private var activeCancelableStatuses: [DownloadTaskStatus] {
        [.queued, .downloading, .paused]
    }

    private var clearableStatusesForCurrentSegment: [DownloadTaskStatus]? {
        switch selectedSegment {
        case 1:
            return [.completed]
        case 2:
            return [.failed, .canceled]
        default:
            return nil
        }
    }

    private func hasMenu(for section: JobSection) -> Bool {
        switch selectedSegment {
        case 0:
            return sectionRecordCount(for: section, statuses: activeCancelableStatuses) > 0
        case 1, 2:
            guard let statuses = clearableStatusesForCurrentSegment else { return false }
            return sectionRecordCount(for: section, statuses: statuses) > 0
        default:
            return false
        }
    }

    @ViewBuilder
    private func sectionHeaderMenu(for section: JobSection) -> some View {
        switch selectedSegment {
        case 0:
            activeSectionMenu(for: section)
        case 1, 2:
            cleanupSectionMenu(for: section)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func activeSectionMenu(for section: JobSection) -> some View {
        let pauseCount = sectionRecordCount(for: section, statuses: activePauseStatuses)
        let resumeCount = sectionRecordCount(for: section, statuses: activeResumeStatuses)
        let cancelCount = sectionRecordCount(for: section, statuses: activeCancelableStatuses)

        if pauseCount > 0 {
            Button {
                downloadCenter.pauseRecords(createdOn: section.date, statuses: activePauseStatuses)
            } label: {
                Label(NSLocalizedString("Pause Downloads", comment: ""), systemImage: "pause.fill")
            }
        }

        if resumeCount > 0 {
            Button {
                downloadCenter.resumeRecords(createdOn: section.date, statuses: activeResumeStatuses)
            } label: {
                Label(NSLocalizedString("Resume Downloads", comment: ""), systemImage: "play.fill")
            }
        }

        if cancelCount > 0 {
            if pauseCount > 0 || resumeCount > 0 {
                Divider()
            }

            if #available(iOS 15.0, *) {
                Button(role: .destructive) {
                    queueSectionAction(
                        date: section.date,
                        statuses: activeCancelableStatuses,
                        recordCount: cancelCount,
                        kind: .cancelDownloads
                    )
                } label: {
                    Label(NSLocalizedString("Cancel Downloads", comment: ""), systemImage: "xmark.circle")
                }
            } else {
                Button {
                    queueSectionAction(
                        date: section.date,
                        statuses: activeCancelableStatuses,
                        recordCount: cancelCount,
                        kind: .cancelDownloads
                    )
                } label: {
                    Label(NSLocalizedString("Cancel Downloads", comment: ""), systemImage: "xmark.circle")
                }
            }
        }
    }

    @ViewBuilder
    private func cleanupSectionMenu(for section: JobSection) -> some View {
        if let statuses = clearableStatusesForCurrentSegment {
            let recordCount = sectionRecordCount(for: section, statuses: statuses)

            if #available(iOS 15.0, *) {
                Button(role: .destructive) {
                    queueSectionAction(
                        date: section.date,
                        statuses: statuses,
                        recordCount: recordCount,
                        kind: .deleteFiles
                    )
                } label: {
                    Label(NSLocalizedString("Delete Files", comment: ""), systemImage: "trash")
                }

                Button(role: .destructive) {
                    queueSectionAction(
                        date: section.date,
                        statuses: statuses,
                        recordCount: recordCount,
                        kind: .deleteRecords
                    )
                } label: {
                    Label(NSLocalizedString("Delete Records", comment: ""), systemImage: "minus.circle")
                }
            } else {
                Button {
                    queueSectionAction(
                        date: section.date,
                        statuses: statuses,
                        recordCount: recordCount,
                        kind: .deleteFiles
                    )
                } label: {
                    Label(NSLocalizedString("Delete Files", comment: ""), systemImage: "trash")
                }

                Button {
                    queueSectionAction(
                        date: section.date,
                        statuses: statuses,
                        recordCount: recordCount,
                        kind: .deleteRecords
                    )
                } label: {
                    Label(NSLocalizedString("Delete Records", comment: ""), systemImage: "minus.circle")
                }
            }
        }
    }

    private func sectionCountBadge(_ count: Int) -> some View {
        HStack(spacing: 0) {
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .fontWeight(.medium)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 8)
        .frame(minWidth: 28)
        .frame(height: 24)
        .background(Color(UIColor.secondarySystemFill))
        .cornerRadius(8)
    }

    private func sectionRecordCount(for section: JobSection, statuses: [DownloadTaskStatus]) -> Int {
        section.jobs.reduce(0) { partialResult, job in
            partialResult + job.tasks.filter { statuses.contains($0.status) }.count
        }
    }
}
