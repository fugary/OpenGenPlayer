import SwiftUI
import AVFoundation

// MARK: - Models
struct HistoryGroup: Identifiable {
    let id: String
    let name: String
    var files: [VideoFile]
    var server: ServerConfig? = nil
}

// MARK: - Subviews


struct RecordListView: View {
    @ObservedObject private var historyService = HistoryService.shared
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    enum AlertType: Identifiable {
        case clearAll
        case clearGroup(HistoryGroup)
        case deleteItem(VideoFile)
        case connectionError(String)
        case resourceNotFound(VideoFile, String)
        
        var id: String {
            switch self {
            case .clearAll: return "clearAll"
            case .clearGroup(let group): return "clearGroup-\(group.id)"
            case .deleteItem(let file): return "deleteItem-\(file.id)"
            case .connectionError(let message): return "connectionError-\(message)"
            case .resourceNotFound(let file, let message): return "resourceNotFound-\(file.id)-\(message)"
            }
        }
    }
    
    @State private var activeAlert: AlertType? = nil
    @State private var fullScreenFile: VideoFile?
    @State private var previewFile: VideoFile?
    @State private var audioSheetFile: VideoFile?
    @State private var groupToClearID: String? // For 2-step clear confirmation
    
    // Navigation State
    enum NavigationTarget: Identifiable, Hashable {
        case localFolder(URL)
        case remoteFolder(ServerConfig, String, String?)
        case iptvPlaylist(ServerConfig, String?)
        case jellyfinDetail(ServerConfig, String)
        case embyDetail(ServerConfig, String)
        case plexDetail(ServerConfig, String)
        case serverHome(ServerConfig) // Jump to server root
        case localHome // Jump to local root
        
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
        case openFile(VideoFile)
        case openNavigationTarget(NavigationTarget, VideoFile?)
    }

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
    
    // Grouping Logic
    private var groupedHistory: [HistoryGroup] {
        var groups: [HistoryGroup] = []
        
        // 1. Local
        let localFiles = historyService.localHistory.filter { file in
            guard HistoryService.isHistoryEnabled(for: file) else { return false }
            if shouldHidePrivateHistoryItems && privacySpace.isFileMarkedPrivate(file) { return false }
            return true
        }.sorted(by: { $0.date > $1.date })
        
        if !localFiles.isEmpty {
            groups.append(HistoryGroup(id: "local", name: NSLocalizedString("Local", comment: ""), files: localFiles))
        }
        
        // 2. Remote
        let remoteFiles = historyService.remoteHistory.filter { file in
            guard HistoryService.isHistoryEnabled(for: file) else { return false }
            if shouldHidePrivateHistoryItems && privacySpace.isFileMarkedPrivate(file) { return false }
            return true
        }.sorted(by: { $0.date > $1.date })
            
        var remoteServices: [UUID: [VideoFile]] = [:] // Key by Server UUID
        var legacyRemoteGroups: [String: [VideoFile]] = [:] // Fallback for unmatched
        
        let orderedServers = networkService.servers
        
        for file in remoteFiles {
            let matchedServer = file.resolvedServer
            
            if let server = matchedServer {
                if remoteServices[server.id] == nil {
                    remoteServices[server.id] = []
                }
                remoteServices[server.id]?.append(file)
            } else {
                // Fallback to old grouping by name/scheme
                let key: String
                if let host = file.url.host {
                    let scheme = file.url.scheme?.lowercased() ?? ""
                    if scheme == "smb" { key = "SMB (\(host))" }
                    else if scheme.hasPrefix("http") { key = "WebDAV/Stream (\(host))" }
                    else { key = "\(scheme.uppercased()) (\(host))" }
                } else {
                    key = NSLocalizedString("Remote", comment: "")
                }
                
                if legacyRemoteGroups[key] == nil {
                    legacyRemoteGroups[key] = []
                }
                legacyRemoteGroups[key]?.append(file)
            }
        }
        
        // Convert matched servers to groups RESPECTING SAVED ORDER
        for server in orderedServers {
            if let files = remoteServices[server.id] {
                // Sort files within the group by date (descending)
                let sortedFiles = files.sorted(by: { $0.date > $1.date })
                groups.append(HistoryGroup(id: "server-\(server.id)", name: server.name, files: sortedFiles, server: server))
            }
        }
        
        // Add Legacy
        let sortedLegacyKeys = legacyRemoteGroups.keys.sorted()
        for key in sortedLegacyKeys {
            if let files = legacyRemoteGroups[key] {
                 // Sort files within the group by date (descending)
                let sortedFiles = files.sorted(by: { $0.date > $1.date })
                groups.append(HistoryGroup(id: key, name: key, files: sortedFiles))
            }
        }
        
        return groups
    }
    
    var body: some View {
        ScrollView {
            Group {
                if groupedHistory.isEmpty {
                    MediaCollectionEmptyStateCard(
                        systemImage: "clock.arrow.circlepath",
                        title: NSLocalizedString("No play history yet", comment: "")
                    )
                    .padding(.horizontal)
                    .padding(.top, 100)
                } else {
                    LazyVStack(spacing: 24, pinnedViews: []) {
                        ForEach(groupedHistory) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                // Section Header Lookalike
                                groupHeader(group)
                                    .padding(.horizontal)
                                    .padding(.top, 8)
                                
                                // Carousel
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: 16) {
                                        ForEach(group.files) { file in
                                            HistoryInteractionCard(
                                                file: file,
                                                onArtworkTap: { openFile(file) },
                                                onTextTap: {
                                                    if let navTarget = getNavigationTarget(for: file) {
                                                        openNavigationTarget(navTarget, associatedFile: file)
                                                    } else {
                                                        openFile(file)
                                                    }
                                                }
                                            )
                                            .contextMenu {
                                                if let navTarget = getNavigationTarget(for: file) {
                                                    Button(action: {
                                                        openNavigationTarget(navTarget, associatedFile: file)
                                                    }) {
                                                        if file.serverType == .iptv {
                                                            Label(NSLocalizedString("View in Playlist", comment: ""), systemImage: "play.tv")
                                                        } else {
                                                            Label(
                                                                shouldOpenHistoryAsLibraryDetail(file)
                                                                    ? NSLocalizedString("View Details", comment: "")
                                                                    : NSLocalizedString("Show in Folder", comment: ""),
                                                                systemImage: shouldOpenHistoryAsLibraryDetail(file) ? "info.circle" : "folder"
                                                            )
                                                        }
                                                    }
                                                }
                                                deleteHistoryMenuButton(file)
                                            }
                                            
                                        }
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 12)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        // Removed explicit background to let standard window background show
        // Removed InsetGroupedListStyle since this is now a ScrollView
        .navigationTitle(NSLocalizedString("Play History", comment: ""))
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if securityService.isPrivacySpaceEnabled && securityService.excludePrivacyFromHistory && securityService.isPrivacySpaceUnlocked {
                    Button(action: togglePrivacySpaceEye) {
                        AppToolbarIcon(
                            systemName: securityService.showPrivateHistory ? "eye" : "eye.slash",
                            style: .primary
                        )
                    }
                    .accessibilityLabel(Text(securityService.showPrivateHistory ? NSLocalizedString("Hide Private History", comment: "") : NSLocalizedString("Show Private History", comment: "")))
                }

                if !groupedHistory.isEmpty {
                    Button(action: { activeAlert = .clearAll }) {
                        AppToolbarIcon(systemName: "trash")
                    }
                }
            }
        }
        .alert(item: $activeAlert) { type in
            switch type {
            case .clearAll:
                return Alert(
                    title: Text(NSLocalizedString("Clear History", comment: "")),
                    message: Text(NSLocalizedString("Are you sure you want to clear all play history?", comment: "")),
                    primaryButton: .destructive(Text(NSLocalizedString("Clear All", comment: ""))) {
                        let shouldExcludePrivate = securityService.isPrivacySpaceEnabled &&
                            (!securityService.isPrivacySpaceUnlocked || !securityService.showPrivateHistory)
                        historyService.clearHistory(excludingPrivate: shouldExcludePrivate)
                    },
                    secondaryButton: .cancel(Text(NSLocalizedString("Cancel", comment: "")))
                )
            case .clearGroup(let group):
                return Alert(
                    title: Text(NSLocalizedString("Clear Group", comment: "")),
                    message: Text(group.name),
                    primaryButton: .destructive(Text(NSLocalizedString("Clear Group", comment: ""))) {
                        historyService.clearHistory(for: group.files)
                    },
                    secondaryButton: .cancel(Text(NSLocalizedString("Cancel", comment: "")))
                )
            case .deleteItem(let file):
                return Alert(
                    title: Text(NSLocalizedString("Delete History", comment: "")),
                    message: Text(String(format: NSLocalizedString("Remove \"%@\" from history?", comment: ""), file.name)),
                    primaryButton: .destructive(Text(NSLocalizedString("Delete", comment: ""))) {
                        historyService.removeFromHistory(file)
                    },
                    secondaryButton: .cancel()
                )
            case .connectionError(let message):
                return Alert(
                    title: Text(NSLocalizedString("Unable to Connect", comment: "")),
                    message: Text(message),
                    dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
                )
            case .resourceNotFound(let file, let message):
                return Alert(
                    title: Text(NSLocalizedString("Unable to Play", comment: "")),
                    message: Text(message),
                    primaryButton: .destructive(Text(NSLocalizedString("Remove from History", comment: ""))) {
                        historyService.removeFromHistory(file)
                    },
                    secondaryButton: .cancel(Text(NSLocalizedString("Cancel", comment: "")))
                )
            }
        }
        .onTapGesture {
            // Reset clear state if tapping elsewhere (simplified)
            if groupToClearID != nil {
                groupToClearID = nil
            }
        }
        .onAppear {
            historyService.refresh()
        }
        .showTabBarCompat()
        .fullScreenCover(item: $fullScreenFile, onDismiss: {
            historyService.refresh()
            UIApplication.refreshInterfaceChrome()
        }) { file in
            fullScreenContent(for: file)
                .privacyProtectedContent(
                    title: file.name,
                    isProtected: shouldHidePrivateHistoryItems && privacySpace.isFileMarkedPrivate(file)
                )
        }
        .sheet(item: $audioSheetFile, onDismiss: { historyService.refresh() }) { file in
            NavigationView {
                AudioPlayerView(initialFile: file)
            }
            .navigationViewStyle(.stack)
            .privacyProtectedContent(
                title: file.name,
                isProtected: shouldHidePrivateHistoryItems && privacySpace.isFileMarkedPrivate(file)
            )
        }
        .sheet(item: $previewFile, onDismiss: { historyService.refresh() }) { file in
            previewSheetContent(for: file)
                .privacyProtectedContent(
                    title: file.name,
                    isProtected: shouldHidePrivateHistoryItems && privacySpace.isFileMarkedPrivate(file)
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
                isProtected: shouldHidePrivateHistoryItems && privacySpace.isServerMarkedPrivate(server)
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
                case .openFile(let file):
                    performOpenFile(file)
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
    
    private func getNavigationTarget(for file: VideoFile) -> NavigationTarget? {
        if file.isRemote {
            guard let server = file.resolvedServer else { return nil }
            if server.type == .jellyfin, let itemId = file.jellyfinItemId {
                return .jellyfinDetail(server, itemId)
            } else if server.type == .emby, let itemId = file.jellyfinItemId {
                return .embyDetail(server, itemId)
            } else if server.type == .plex, let itemId = file.jellyfinItemId {
                return .plexDetail(server, itemId)
            } else if server.type == .plex {
                return .serverHome(server)
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

    private func shouldOpenHistoryAsLibraryDetail(_ file: VideoFile) -> Bool {
        guard file.isRemote,
              file.jellyfinItemId != nil,
              let server = file.resolvedServer else {
            return false
        }
        return server.type == .jellyfin || server.type == .emby || server.type == .plex
    }
    
    @ViewBuilder
    private func groupHeader(_ group: HistoryGroup) -> some View {
        HStack(spacing: 12) {
            if let server = group.server {
                Button(action: {
                    openNavigationTarget(.serverHome(server))
                }) {
                    HStack(spacing: 12) {
                        // Server Icon
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
                            HStack(spacing: 4) {
                                Text(server.name)
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(Color(UIColor.secondaryLabel))
                                if securityService.isPrivacySpaceEnabled && privacySpace.isServerMarkedPrivate(server) {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundColor(.secondary)
                                }
                            }
                            
                            Text(server.address)
                                .font(.system(size: 11))
                                .foregroundColor(Color(UIColor.secondaryLabel).opacity(0.8))
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer() // Add a spacer to push the clear button to the right if applicable
            } else {
                // Legacy / Local Header
                Button(action: {
                    if group.id == "local" {
                        navigationSelection = .localHome
                    }
                }) {
                    HStack(spacing: 4) {
                        Text(group.name)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(Color(UIColor.secondaryLabel))
                        if securityService.isPrivacySpaceEnabled && !group.files.isEmpty && group.files.allSatisfy({ privacySpace.isFileMarkedPrivate($0) }) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
            
            Spacer()
            
            // Integrated Count / Clear Button (2-step)
            Button(action: {
                if groupToClearID == group.id {
                    // Confirm and Clear
                    withAnimation {
                        historyService.clearHistory(for: group.files)
                        groupToClearID = nil
                    }
                } else {
                    // First tap: Arm the button to show trash icon
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
                        Text("\(group.files.count)")
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
        // .padding(.leading, 8) // +20 native = 28pt total
        // .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture {
            if groupToClearID != nil {
                withAnimation {
                    groupToClearID = nil
                }
            }
        }
        .contextMenu {
            if #available(iOS 15.0, *) {
                Button(role: .destructive) {
                    activeAlert = .clearGroup(group)
                } label: {
                    Label(NSLocalizedString("Clear Group", comment: ""), systemImage: "trash")
                }
            } else {
                Button(action: {
                    activeAlert = .clearGroup(group)
                }) {
                    Label(NSLocalizedString("Clear Group", comment: ""), systemImage: "trash")
                }
            }
        }
    }
    
    @ViewBuilder
    private func fullScreenContent(for file: VideoFile) -> some View {
        if file.type == .video || (file.type == .folder && file.jellyfinItemId != nil) {
             PlayerView(initialFile: file)
        } else if file.serverType == .jellyfin || file.serverType == .emby {
            // Assume Jellyfin/Emby items in history are videos if not explicitly audio
             PlayerView(initialFile: file)
        } else if file.type != .audio && file.type != .image {
             PlayerView(initialFile: file)
        } else {
             Text(NSLocalizedString("Unsupported file type", comment: ""))
        }
    }
    
    @ViewBuilder
    private func previewSheetContent(for file: VideoFile) -> some View {
        switch file.type {
        default:
            // Fallback for other types in sheet if they ever end up in history
            PreviewSheetContainer {
                UnsupportedPreviewView()
            }
        }
    }
    
    private func requiresPrivacyAccess(for file: VideoFile) -> Bool {
        securityService.isPrivacySpaceEnabled &&
        !securityService.isPrivacySpaceUnlocked &&
        privacySpace.isFileMarkedPrivate(file)
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

    private func togglePrivacySpaceEye() {
        withAnimation {
            securityService.showPrivateHistory.toggle()
        }
    }

    private func openFile(_ file: VideoFile) {
        if requiresPrivacyAccess(for: file) {
            pendingPrivacyAction = .openFile(file)
            isShowingPrivacyUnlock = true
            return
        }
        performOpenFile(file)
    }

    private func performOpenFile(_ file: VideoFile) {
        let playbackFile = downloadCenter.localPlaybackFile(for: file) ?? file

        if !playbackFile.isRemote {
            if !FileManager.default.fileExists(atPath: playbackFile.url.path) {
                activeAlert = .resourceNotFound(file, NSLocalizedString("The local file does not exist or has been deleted.", comment: ""))
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
            await validateAndOpenFile(playbackFile, originalHistoryFile: file, server: server, requestID: requestID)
        }
    }
    
    private func deleteItems(from list: [VideoFile], at offsets: IndexSet) {
        if let index = offsets.first {
            activeAlert = .deleteItem(list[index])
        }
    }

    private func openNavigationTarget(_ target: NavigationTarget, associatedFile: VideoFile? = nil) {
        if let file = associatedFile, requiresPrivacyAccess(for: file) {
            pendingPrivacyAction = .openNavigationTarget(target, file)
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

    private func validateAndOpenFile(_ file: VideoFile, originalHistoryFile: VideoFile, server: ServerConfig, requestID: UUID) async {
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
        } catch let validationError as PlaybackValidationError {
            await MainActor.run {
                guard libraryConnectionRequestID == requestID, !Task.isCancelled else { return }
                isValidatingServerConnection = false
                validatingServerName = nil
                libraryConnectionTask = nil
                if validationError.isResourceNotFound {
                    activeAlert = .resourceNotFound(originalHistoryFile, validationError.localizedDescription)
                } else {
                    activeAlert = .connectionError(validationError.localizedDescription)
                }
            }
        } catch {
            await MainActor.run {
                guard libraryConnectionRequestID == requestID, !Task.isCancelled else { return }
                isValidatingServerConnection = false
                validatingServerName = nil
                libraryConnectionTask = nil
                activeAlert = .connectionError(error.localizedDescription)
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
                activeAlert = .connectionError(error.localizedDescription)
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
        return file.type == .audio || (file.type != .image && !file.supportsTextPreview)
    }

    private func presentFile(_ file: VideoFile) {
        if file.type == .image {
            previewFile = file
        } else if file.type == .audio {
            audioSheetFile = file
        } else {
            fullScreenFile = file
        }
    }

    @ViewBuilder
    private func deleteHistoryMenuButton(_ file: VideoFile) -> some View {
        if #available(iOS 15.0, *) {
            Button(role: .destructive) {
                activeAlert = .deleteItem(file)
            } label: {
                Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
            }
        } else {
            Button(action: {
                activeAlert = .deleteItem(file)
            }) {
                Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
            }
        }
    }
}

struct HistoryInteractionCard: View {
    let file: VideoFile
    let onArtworkTap: () -> Void
    let onTextTap: () -> Void
    @ObservedObject private var offlineIndex = OfflineMediaIndexStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: onArtworkTap) {
                HistoryRowCardView(file: file, showsText: false)
            }
            .buttonStyle(PlainButtonStyle())
            .macCardHoverEffect(cornerRadius: 12)

            Button(action: onTextTap) {
                HistoryRowCardText(
                    file: file,
                    isDownloaded: offlineIndex.isDownloaded(file: file)
                )
            }
            .buttonStyle(PlainButtonStyle())
        }
        .frame(width: 160, alignment: .leading)
    }
}

struct HistoryRowCardView: View {
    private enum ThumbnailPresentationStyle {
        case landscape
        case containedPreview

        var frameSize: CGSize {
            switch self {
            case .landscape:
                return CGSize(width: 160, height: 100)
            case .containedPreview:
                return CGSize(width: 160, height: 100)
            }
        }

        var imageContentMode: ContentMode {
            switch self {
            case .landscape:
                return .fill
            case .containedPreview:
                return .fit
            }
        }

        var imagePadding: CGFloat {
            switch self {
            case .landscape:
                return 0
            case .containedPreview:
                return 8
            }
        }
    }

    let file: VideoFile
    var showsText: Bool = true
    @ObservedObject private var offlineIndex = OfflineMediaIndexStore.shared
    @ObservedObject private var historyService = HistoryService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    @State private var jellyfinHistoryImageURL: URL?
    @State private var jellyfinImageResolved = false
    @State private var thumbnailAspectRatio: CGFloat?
    @State private var mediaSourceAspectRatio: CGFloat?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Thumbnail / Icon
            ZStack(alignment: .bottomTrailing) {
                // Base background
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(UIColor.systemGray6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(UIColor.systemGray4), lineWidth: 1)
                    )
                    .frame(width: thumbnailFrameSize.width, height: thumbnailFrameSize.height)
                
                // Actual Image or Fallback
                if let thumbURL = resolvedThumbnailURL {
                    RemoteImage(
                        url: thumbURL,
                        sourceFile: file,
                        placeholderSystemImage: iconName,
                        placeholderTint: iconColor,
                        contentMode: thumbnailPresentationStyle.imageContentMode,
                        permitNetworkForAudioArtwork: true,
                        permitNetworkForVideoArtwork: true,
                        onImageLoaded: updateThumbnailAspectRatio
                    )
                        .padding(thumbnailPresentationStyle.imagePadding)
                        .frame(width: thumbnailFrameSize.width, height: thumbnailFrameSize.height)
                        .cornerRadius(12)
                        .clipped()
                } else {
                    Image(systemName: iconName)
                        .font(.largeTitle)
                        .foregroundColor(iconColor)
                        .frame(width: thumbnailFrameSize.width, height: thumbnailFrameSize.height)
                }
                
                // Badges (Top Left: privacy lock, Top Right: remote server name or local marker)
                VStack {
                    HStack {
                        if securityService.isPrivacySpaceEnabled && privacySpace.isFileMarkedPrivate(file) {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.6))
                                .cornerRadius(4)
                                .padding([.top, .leading], 6)
                        }
                        Spacer()
                        HStack(spacing: 2) {
                            if let server = file.resolvedServer {
                                if let uiImage = UIImage(named: server.type.iconAssetName) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .frame(width: 10, height: 10)
                                } else {
                                    Image(systemName: server.type.systemIconName)
                                        .font(.system(size: 8, weight: .bold))
                                }
                                Text(server.name)
                                    .font(.system(size: 9, weight: .bold))
                            } else if file.isRemote {
                                Image(systemName: file.serverType?.systemIconName ?? "server.rack")
                                    .font(.system(size: 8, weight: .bold))
                                Text(file.serverType?.displayName ?? NSLocalizedString("Remote", comment: ""))
                                    .font(.system(size: 9, weight: .bold))
                            } else {
                                Image(systemName: "internaldrive.fill")
                                    .font(.system(size: 8, weight: .bold))
                                Text(NSLocalizedString("Local", comment: ""))
                                    .font(.system(size: 9, weight: .bold))
                            }
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(4)
                        .padding([.top, .trailing], 6)
                    }
                    Spacer()
                }
                
                if let playbackProgressSnapshot = playbackProgressSnapshot {
                    PlaybackProgressBadge(
                        snapshot: playbackProgressSnapshot,
                        diameter: 18,
                        usesDarkBackground: true,
                        symbolName: file.playbackBadgeSystemImage,
                        symbolSize: 9
                    )
                    .padding(.trailing, 8)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: thumbnailFrameSize.width, height: thumbnailFrameSize.height)
            .animation(.easeInOut(duration: 0.2), value: thumbnailPresentationStyle == .containedPreview)
            
            if showsText {
                HistoryRowCardText(file: file, isDownloaded: isDownloaded)
            }
        }
        .onAppear {
            resolveJellyfinHistoryImageIfNeeded()
            resolveMediaSourceAspectRatioIfNeeded()
        }
    }
    
    private var iconName: String {
        // Jellyfin/Emby remote items are usually videos, but keep audio icon for music entries.
        if (file.jellyfinItemId != nil || file.serverType == .jellyfin || file.serverType == .emby), file.type != .audio {
            return "play.rectangle.fill"
        }
        
        switch file.type {
        case .folder: return "folder.fill"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .image: return "photo"
        default: return "doc"
        }
    }
    
    private var iconColor: Color {
        if (file.jellyfinItemId != nil || file.serverType == .jellyfin || file.serverType == .emby), file.type != .audio {
            return .purple
        }
        
        switch file.type {
        case .folder: return .blue
        case .video: return .purple
        case .audio: return .pink
        case .image: return .green
        case .document, .subtitle: return .orange
        default: return .secondary
        }
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        historyService.playbackProgressSnapshot(matching: file)
    }
    
    // Total Duration helper not strictly needed for the simpler UI, 
    // but progress is derived inline above.

    private var resolvedThumbnailURL: URL? {
        if isJellyfinHistory {
            return jellyfinHistoryImageURL ?? jellyfinInitialImageURL() ?? file.thumbnailURL
        }
        return file.thumbnailURL
    }

    private var thumbnailPresentationStyle: ThumbnailPresentationStyle {
        guard prefersContainedThumbnailPresentation else {
            return .landscape
        }

        let aspectRatio = effectiveThumbnailAspectRatio
        guard aspectRatio > 0 else {
            return .landscape
        }

        if file.type == .video {
            return aspectRatio < 1.2 ? .containedPreview : .landscape
        }

        return aspectRatio < 1 ? .containedPreview : .landscape
    }

    private var thumbnailFrameSize: CGSize {
        thumbnailPresentationStyle.frameSize
    }

    private var effectiveThumbnailAspectRatio: CGFloat {
        if let persistedVideoAspectRatioHint, persistedVideoAspectRatioHint > 0 {
            return persistedVideoAspectRatioHint
        }
        if let mediaSourceAspectRatio, mediaSourceAspectRatio > 0 {
            return mediaSourceAspectRatio
        }
        return thumbnailAspectRatio ?? 16.0 / 9.0
    }

    private var persistedVideoAspectRatioHint: CGFloat? {
        if let hint = file.videoAspectRatioHint, hint > 0 {
            return CGFloat(hint)
        }

        if let historyHint = historyService.allHistory.first(where: { file.matchesHistoryEntry($0) })?.videoAspectRatioHint,
           historyHint > 0 {
            return CGFloat(historyHint)
        }

        return nil
    }

    private var prefersContainedThumbnailPresentation: Bool {
        if file.type == .image {
            return true
        }

        guard file.type == .video else {
            return false
        }

        guard let thumbnailURL = resolvedThumbnailURL else {
            return false
        }

        return thumbnailURLMatchesMediaSource(thumbnailURL)
    }

    private var isDownloaded: Bool {
        offlineIndex.isDownloaded(file: file)
    }

    private var isJellyfinHistory: Bool {
        if file.serverType == .emby || file.resolvedServer?.type == .emby { return false }
        if file.serverType == .jellyfin { return true }
        if file.resolvedServer?.type == .jellyfin { return true }
        if inferredServerItemId(from: file.url) != nil, jellyfinTokenFromStreamURL(file.url) != nil { return true }
        return false
    }

    private func resolveJellyfinHistoryImageIfNeeded() {
        guard isJellyfinHistory, !jellyfinImageResolved else { return }
        jellyfinImageResolved = true

        // Keep existing behavior as immediate fallback while we fetch richer detail.
        jellyfinHistoryImageURL = jellyfinInitialImageURL()

        guard let itemId = file.jellyfinItemId ?? inferredServerItemId(from: file.url),
              let context = jellyfinServerContext() else {
            return
        }

        Task {
            do {
                let item = try await JellyfinService.shared.getItemDetails(server: context.server, itemId: itemId, token: context.token)
                let bestURL = preferredHistoryImageURL(for: item, server: context.server) ?? jellyfinHistoryImageURL
                await MainActor.run {
                    jellyfinHistoryImageURL = bestURL
                }
            } catch {
                // Keep fallback thumbnail URL.
            }
        }
    }

    private func jellyfinInitialImageURL() -> URL? {
        guard let itemId = file.jellyfinItemId ?? inferredServerItemId(from: file.url) else {
            return file.thumbnailURL
        }
        guard let context = jellyfinServerContext() else {
            return file.thumbnailURL
        }
        if let seriesId = file.seriesId, !seriesId.isEmpty {
            return JellyfinService.shared.getImageURL(server: context.server, itemId: seriesId, imageType: "Primary", maxWidth: 400)
                ?? file.thumbnailURL
        }
        return JellyfinService.shared.getImageURL(server: context.server, itemId: itemId, imageType: "Primary", maxWidth: 400)
            ?? file.thumbnailURL
    }

    private func preferredHistoryImageURL(for item: JellyfinItem, server: ServerConfig) -> URL? {
        if (item.type == "Episode" || item.type == "Season"),
           let seriesId = item.seriesId, !seriesId.isEmpty {
            return JellyfinService.shared.getImageURL(server: server, itemId: seriesId, imageType: "Primary", maxWidth: 400)
        }
        if item.primaryImageTag != nil || item.imageTags?["Primary"] != nil {
            return item.primaryImageURL(server: server, maxWidth: 400)
        }
        if let seriesId = item.seriesId, !seriesId.isEmpty {
            return JellyfinService.shared.getImageURL(server: server, itemId: seriesId, imageType: "Primary", maxWidth: 400)
        }
        return item.landscapeImageURL(server: server)
    }

    private func jellyfinServerContext() -> (server: ServerConfig, token: String)? {
        if let resolved = file.resolvedServer, resolved.type == .jellyfin {
            if let token = resolved.accessToken, !token.isEmpty {
                return (resolved, token)
            }
            if let fallbackToken = jellyfinTokenFromStreamURL(file.url) {
                var patched = resolved
                patched.accessToken = fallbackToken
                return (patched, fallbackToken)
            }
        }

        return inferredJellyfinServerContext(from: file.url)
    }

    private func updateThumbnailAspectRatio(_ image: UIImage) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let ratio = image.size.width / image.size.height
        guard ratio.isFinite else { return }

        if let current = thumbnailAspectRatio, abs(current - ratio) < 0.01 {
            return
        }

        thumbnailAspectRatio = ratio
    }

    private func thumbnailURLMatchesMediaSource(_ thumbnailURL: URL) -> Bool {
        if thumbnailURL == file.url {
            return true
        }

        if thumbnailURL.isFileURL && file.url.isFileURL {
            return thumbnailURL.standardizedFileURL == file.url.standardizedFileURL
        }

        return thumbnailURL.absoluteString == file.url.absoluteString
    }

    private func resolveMediaSourceAspectRatioIfNeeded() {
        guard file.type == .video,
              prefersContainedThumbnailPresentation,
              mediaSourceAspectRatio == nil else {
            return
        }

        if let serverRatio = mediaSourceAspectRatioFromServerStreams() {
            mediaSourceAspectRatio = serverRatio
            return
        }

        guard file.url.isFileURL else { return }
        let fileURL = file.url

        DispatchQueue.global(qos: .utility).async {
            let asset = AVURLAsset(url: fileURL)
            guard let videoTrack = asset.tracks(withMediaType: .video).first else { return }

            let transformedSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
            let width = abs(transformedSize.width)
            let height = abs(transformedSize.height)
            guard width > 0, height > 0 else { return }

            let ratio = width / height
            guard ratio.isFinite else { return }

            DispatchQueue.main.async {
                if let current = self.mediaSourceAspectRatio, abs(current - ratio) < 0.01 {
                    return
                }
                self.mediaSourceAspectRatio = ratio
            }
        }
    }

    private func mediaSourceAspectRatioFromServerStreams() -> CGFloat? {
        guard let streams = file.serverMediaStreams else { return nil }

        for stream in streams {
            guard let type = stream["Type"] as? String,
                  type.caseInsensitiveCompare("Video") == .orderedSame,
                  let width = stream["Width"] as? Int,
                  let height = stream["Height"] as? Int,
                  width > 0,
                  height > 0 else {
                continue
            }

            let ratio = CGFloat(width) / CGFloat(height)
            if ratio.isFinite {
                return ratio
            }
        }

        return nil
    }
}

struct HistoryRowCardText: View {
    let file: VideoFile
    let isDownloaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(appLineBreakableTitle(file.name))
                .font(.caption)
                .fontWeight(.medium)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .layoutPriority(1)

            HStack(spacing: 4) {
                if isDownloaded {
                    DownloadStatusIcon(size: 10)
                }

                Text(file.formattedListDate)
                    .lineLimit(1)
            }
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .frame(width: 160, alignment: .leading)

            Spacer(minLength: 0)
        }
        .frame(width: 160, height: MediaCardMetrics.posterTextHeight, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

private func inferredServerItemId(from url: URL) -> String? {
    let components = url.path.split(separator: "/")
    guard let videosIndex = components.firstIndex(where: { $0.caseInsensitiveCompare("Videos") == .orderedSame }),
          videosIndex + 1 < components.count else {
        return nil
    }

    let raw = String(components[videosIndex + 1])
    let decoded = raw.removingPercentEncoding ?? raw
    return decoded.isEmpty ? nil : decoded
}

private func jellyfinTokenFromStreamURL(_ url: URL) -> String? {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return nil
    }
    let token = components.queryItems?.first(where: { $0.name == "api_key" })?.value
    guard let token, !token.isEmpty else { return nil }
    return token
}

private func inferredJellyfinServerContext(from streamURL: URL) -> (server: ServerConfig, token: String)? {
    guard let host = streamURL.host,
          let scheme = streamURL.scheme?.lowercased(),
          (scheme == "http" || scheme == "https"),
          let token = jellyfinTokenFromStreamURL(streamURL) else {
        return nil
    }

    var server = ServerConfig(
        name: "Jellyfin",
        address: host,
        port: streamURL.port,
        useSSL: scheme == "https",
        type: .jellyfin,
        username: nil,
        passwordSecret: nil,
        workgroup: nil,
        accessToken: token,
        userId: nil
    )
    server.accessToken = token
    return (server, token)
}
