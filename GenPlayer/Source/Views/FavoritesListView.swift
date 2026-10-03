import SwiftUI

struct FavoriteGroup: Identifiable {
    let id: String
    let name: String
    var items: [FavoriteItem]
    var server: ServerConfig? = nil
}

struct FavoritesListView: View {
    private enum AlertType: Identifiable {
        case unsupportedFolder(String)
        case clearAll
        case removeFavorite(FavoriteItem)

        var id: String {
            switch self {
            case .unsupportedFolder(let message):
                return "unsupported-\(message)"
            case .clearAll:
                return "clearAll"
            case .removeFavorite(let item):
                return "remove-\(item.id)"
            }
        }
    }

    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    @State private var fullScreenFile: VideoFile?
    @State private var previewFile: VideoFile?
    @State private var audioSheetFile: VideoFile?
    @State private var connectionErrorMessage: String?
    @State private var groupToClearID: String?
    @State private var activeAlert: AlertType?
    
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
    @State private var isShowingPrivacyUnlock = false
    @State private var pendingPrivacyAction: PrivacyAction?

    enum PrivacyAction {
        case openPrimaryAction(FavoriteItem)
        case openNavigationTarget(NavigationTarget, FavoriteItem?)
    }

    private var shouldHidePrivateFavorites: Bool {
        securityService.isPrivacySpaceEnabled &&
        securityService.hideLockedItems &&
        !securityService.isPrivacySpaceUnlocked
    }

    private enum FavoriteNavigationIntent {
        case openItem
        case revealInParent
    }

    private var groupedFavorites: [FavoriteGroup] {
        var groups: [FavoriteGroup] = []

        let localItems = favoriteService.favorites
            .filter { !$0.file.isRemote }
            .filter { item in
                !shouldHidePrivateFavorites || !privacySpace.isFavoriteMarkedPrivate(item)
            }
            .sorted(by: { $0.addedDate > $1.addedDate })

        if !localItems.isEmpty {
            groups.append(FavoriteGroup(id: "local", name: NSLocalizedString("Local", comment: ""), items: localItems))
        }

        let remoteItems = favoriteService.favorites
            .filter { $0.file.isRemote }
            .filter { item in
                !shouldHidePrivateFavorites || !privacySpace.isFavoriteMarkedPrivate(item)
            }
            .sorted(by: { $0.addedDate > $1.addedDate })

        let orderedServers = networkService.servers
        var remoteServices: [UUID: [FavoriteItem]] = [:]
        var legacyRemoteGroups: [String: [FavoriteItem]] = [:]

        for item in remoteItems {
            let file = item.file
            let matchedServer = file.resolvedServer

            if let server = matchedServer {
                remoteServices[server.id, default: []].append(item)
            } else {
                let key: String
                if let host = file.url.host {
                    key = "\((file.url.scheme ?? "remote").uppercased()) (\(host))"
                } else {
                    key = NSLocalizedString("Remote", comment: "")
                }
                legacyRemoteGroups[key, default: []].append(item)
            }
        }

        for server in orderedServers {
            if let items = remoteServices[server.id] {
                groups.append(FavoriteGroup(id: "server-\(server.id)", name: server.name, items: items, server: server))
            }
        }

        for key in legacyRemoteGroups.keys.sorted() {
            if let items = legacyRemoteGroups[key] {
                groups.append(FavoriteGroup(id: key, name: key, items: items))
            }
        }

        return groups
    }

    var body: some View {
        ScrollView {
            if groupedFavorites.isEmpty {
                MediaCollectionEmptyStateCard(
                    systemImage: "star.fill",
                    title: NSLocalizedString("No favorites yet", comment: "")
                )
                .padding(.horizontal)
                .padding(.top, 100)
            } else {
                LazyVStack(spacing: 24) {
                    ForEach(groupedFavorites) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            header(group)
                                .padding(.horizontal)
                                .padding(.top, 8)

                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 14) {
                                    ForEach(group.items) { item in
                                        favoriteCard(item)
                                    }
                                }
                                .padding(.horizontal)
                                .padding(.vertical, 12)
                            }
                        }
                    }
                }
                .padding(.vertical)
            }
        }
        .onTapGesture {
            if groupToClearID != nil {
                withAnimation { groupToClearID = nil }
            }
        }
        .navigationTitle(NSLocalizedString("Favorites", comment: ""))
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if !groupedFavorites.isEmpty {
                    Button(action: { activeAlert = .clearAll }) {
                        AppToolbarIcon(systemName: "trash")
                    }
                }
            }
        }
        .appErrorAlert(
            message: $connectionErrorMessage,
            title: NSLocalizedString("Unable to Connect", comment: "")
        )
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .unsupportedFolder(let message):
                return Alert(
                    title: Text(NSLocalizedString("Unable to Open", comment: "")),
                    message: Text(message),
                    dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
                )
            case .clearAll:
                return Alert(
                    title: Text(NSLocalizedString("Clear Favorites", comment: "")),
                    message: Text(NSLocalizedString("Are you sure you want to remove all favorites?", comment: "")),
                    primaryButton: .destructive(Text(NSLocalizedString("Clear All", comment: ""))) {
                        favoriteService.clearAll()
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
        .fullScreenCover(item: $fullScreenFile, onDismiss: {
            UIApplication.refreshInterfaceChrome()
        }) { file in
            fullScreenContent(for: file)
                .privacyProtectedContent(
                    title: file.name,
                    isProtected: shouldHidePrivateFavorites && privacySpace.isFileMarkedPrivate(file)
                )
        }
        .sheet(item: $audioSheetFile) { file in
            NavigationView { AudioPlayerView(initialFile: file) }
                .navigationViewStyle(.stack)
                .privacyProtectedContent(
                    title: file.name,
                    isProtected: shouldHidePrivateFavorites && privacySpace.isFileMarkedPrivate(file)
                )
        }
        .sheet(item: $previewFile) { file in
            previewSheetContent(for: file)
                .privacyProtectedContent(
                    title: file.name,
                    isProtected: shouldHidePrivateFavorites && privacySpace.isFileMarkedPrivate(file)
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
                isProtected: shouldHidePrivateFavorites && privacySpace.isServerMarkedPrivate(server)
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
        .sheet(isPresented: $isShowingPrivacyUnlock, onDismiss: {
            if securityService.isPrivacySpaceUnlocked, let action = pendingPrivacyAction {
                pendingPrivacyAction = nil
                switch action {
                case .openPrimaryAction(let item):
                    performOpenPrimaryAction(for: item)
                case .openNavigationTarget(let target, _):
                    performOpenNavigationTarget(target)
                }
            } else {
                pendingPrivacyAction = nil
            }
        }) {
            PrivacySpaceUnlockView(
                isPresented: $isShowingPrivacyUnlock,
                title: NSLocalizedString("Privacy Space", comment: "")
            )
        }
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
        .onAppear { favoriteService.refresh() }
    }
    
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
    
    private func getNavigationTarget(for item: FavoriteItem, intent: FavoriteNavigationIntent = .revealInParent) -> NavigationTarget? {
        let file = item.file
        if file.isRemote {
            guard let server = file.resolvedServer else { return nil }
            let libraryTargetItemId = preferredLibraryTargetItemId(for: file)
            if server.type == .jellyfin, let itemId = libraryTargetItemId {
                return .jellyfinDetail(server, itemId)
            } else if server.type == .emby, let itemId = libraryTargetItemId {
                return .embyDetail(server, itemId)
            } else if server.type == .plex, let itemId = libraryTargetItemId {
                return .plexDetail(server, itemId)
            } else if server.type == .iptv {
                return .iptvPlaylist(server, file.jellyfinItemId)
            } else if server.type.isFileServer {
                let folderPath = file.type == .folder ? favoriteFolderPath(for: item) : file.remoteFolderPath
                return .remoteFolder(server, folderPath, file.id)
            }
            return nil
        } else {
            let folderURL = file.type == .folder ? file.url : file.url.deletingLastPathComponent()
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

    private func shouldOpenFavoriteAsLibraryDetail(_ file: VideoFile) -> Bool {
        guard file.isRemote,
              preferredLibraryTargetItemId(for: file) != nil,
              let server = file.resolvedServer else {
            return false
        }
        return server.type == .jellyfin || server.type == .emby || server.type == .plex
    }

    @ViewBuilder
    private func favoriteCard(_ item: FavoriteItem) -> some View {
        HistoryInteractionCard(
            file: item.file,
            onArtworkTap: { openPrimaryAction(for: item) },
            onTextTap: {
                if let navTarget = getNavigationTarget(for: item) {
                    openNavigationTarget(navTarget, associatedItem: item)
                } else {
                    openPrimaryAction(for: item)
                }
            }
        )
        .contextMenu {
            if shouldOpenFavoriteAsLibraryDetail(item.file),
               let navTarget = getNavigationTarget(for: item) {
                Button(action: {
                    openNavigationTarget(navTarget, associatedItem: item)
                }) {
                    Label(NSLocalizedString("View Details", comment: ""), systemImage: "info.circle")
                }
            } else if item.file.serverType == .iptv,
                      let navTarget = getNavigationTarget(for: item) {
                Button(action: {
                    openNavigationTarget(navTarget, associatedItem: item)
                }) {
                    Label(NSLocalizedString("View in Playlist", comment: ""), systemImage: "play.tv")
                }
            } else if let navTarget = getNavigationTarget(for: item) {
                Button(action: {
                    openNavigationTarget(navTarget, associatedItem: item)
                }) {
                    Label(NSLocalizedString("Show in Folder", comment: ""), systemImage: "folder")
                }
            }
            removeFavoriteMenuButton(item)
        }
    }

    @ViewBuilder
    private func header(_ group: FavoriteGroup) -> some View {
        HStack(spacing: 12) {
            if let server = group.server {
                Button(action: {
                    openNavigationTarget(.serverHome(server))
                }) {
                    HStack(spacing: 12) {
                        ZStack {
                            if let uiImage = UIImage(named: server.type.iconAssetName) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            } else {
                                Image(systemName: server.type.systemIconName)
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }
                        }
                        .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 0) {
                            Text(server.name)
                                .font(.system(size: 17, weight: .semibold))
                                .foregroundColor(Color(UIColor.secondaryLabel))
                            Text(server.address)
                                .font(.system(size: 11))
                                .foregroundColor(Color(UIColor.secondaryLabel).opacity(0.8))
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Button(action: {
                    if group.id == "local" {
                        navigationSelection = .localHome
                    }
                }) {
                    Text(group.name)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(UIColor.secondaryLabel))
                }
                .buttonStyle(PlainButtonStyle())
            }

            Spacer()

            Button(action: {
                if groupToClearID == group.id {
                    withAnimation {
                        for item in group.items {
                            favoriteService.remove(item)
                        }
                        groupToClearID = nil
                    }
                } else {
                    withAnimation {
                        groupToClearID = group.id
                    }
                }
            }) {
                HStack(spacing: 4) {
                    if groupToClearID == group.id {
                        Image(systemName: "trash.fill")
                            .font(.system(size: 14, weight: .semibold))
                    } else {
                        Text("\(group.items.count)")
                            .font(.caption.monospacedDigit())
                            .fontWeight(.medium)
                    }
                }
                .foregroundColor(groupToClearID == group.id ? .white : .secondary)
                .padding(.horizontal, groupToClearID == group.id ? 10 : 8)
                .frame(minWidth: 28)
                .frame(height: 24)
                .background(groupToClearID == group.id ? Color.red : Color(UIColor.systemGray4))
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
            .macButtonHoverEffect()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if groupToClearID != nil {
                withAnimation { groupToClearID = nil }
            }
        }
    }

    private func requiresPrivacyAccess(for item: FavoriteItem) -> Bool {
        securityService.isPrivacySpaceEnabled &&
        !securityService.isPrivacySpaceUnlocked &&
        privacySpace.isFavoriteMarkedPrivate(item)
    }

    private func requiresPrivacyAccess(for target: NavigationTarget) -> Bool {
        guard securityService.isPrivacySpaceEnabled && !securityService.isPrivacySpaceUnlocked else { return false }
        switch target {
        case .localFolder(let url):
            return privacySpace.isLocalFolderMarkedPrivate(url)
        case .remoteFolder(let server, let path, _):
            return privacySpace.isServerMarkedPrivate(server) || privacySpace.isRemoteFolderMarkedPrivate(server: server, path: path)
        case .jellyfinDetail(let server, _), .embyDetail(let server, _), .plexDetail(let server, _), .iptvPlaylist(let server, _), .serverHome(let server):
            return privacySpace.isServerMarkedPrivate(server)
        case .localHome:
            return false
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

    private func openPrimaryAction(for item: FavoriteItem) {
        if requiresPrivacyAccess(for: item) {
            pendingPrivacyAction = .openPrimaryAction(item)
            isShowingPrivacyUnlock = true
            return
        }
        performOpenPrimaryAction(for: item)
    }

    private func performOpenPrimaryAction(for item: FavoriteItem) {
        if let navTarget = getNavigationTarget(for: item, intent: .openItem),
           item.file.type == .folder {
            performOpenNavigationTarget(navTarget)
            return
        }

        if item.file.type == .folder {
            activeAlert = .unsupportedFolder(NSLocalizedString("This folder favorite is not currently navigable for this server type.", comment: ""))
            return
        }

        openFile(item.file)
    }

    private func openNavigationTarget(_ target: NavigationTarget, associatedItem: FavoriteItem? = nil) {
        if let item = associatedItem, requiresPrivacyAccess(for: item) {
            pendingPrivacyAction = .openNavigationTarget(target, item)
            isShowingPrivacyUnlock = true
            return
        }
        if requiresPrivacyAccess(for: target) {
            pendingPrivacyAction = .openNavigationTarget(target, nil)
            isShowingPrivacyUnlock = true
            return
        }
        performOpenNavigationTarget(target)
    }

    private func performOpenNavigationTarget(_ target: NavigationTarget) {
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
        guard !file.canOpenInPreviewSheet else { return false }
        return file.type == .audio || (file.type != .image && !file.supportsTextPreview)
    }

    private func presentFile(_ file: VideoFile) {
        if file.type == .audio {
            audioSheetFile = file
        } else if file.canOpenInPreviewSheet {
            previewFile = file
        } else {
            fullScreenFile = file
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

    @ViewBuilder
    private func removeFavoriteMenuButton(_ item: FavoriteItem) -> some View {
        if #available(iOS 15.0, *) {
            Button(role: .destructive) {
                activeAlert = .removeFavorite(item)
            } label: {
                Label(NSLocalizedString("Remove Favorite", comment: ""), systemImage: "star.slash")
            }
        } else {
            Button(action: { activeAlert = .removeFavorite(item) }) {
                Label(NSLocalizedString("Remove Favorite", comment: ""), systemImage: "star.slash")
            }
        }
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
}
