#if os(macOS)
import SwiftUI
import GenPlayerCore

public struct MainSplitView: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    @State private var sidebarSelection: PlatformShellDestination? = .servers
    @State private var showingServerDiscovery = false
    @State private var editorContext: MacServerEditorContext?
    /// Remembers the last server the user entered so that clicking "Network" from
    /// another tab restores that server instead of going to the server list.
    @State private var lastServerSelection: PlatformShellDestination? = nil
    
    private var shouldHidePrivateServers: Bool {
        securityService.isPrivacySpaceEnabled &&
        securityService.hideLockedItems &&
        !securityService.isPrivacySpaceUnlocked
    }

    private var visibleServers: [ServerConfig] {
        networkService.servers.filter { server in
            !shouldHidePrivateServers || !privacySpace.isServerMarkedPrivate(server)
        }
    }

    public init() {}

    public var body: some View {
        Group {
            if #available(macOS 13.0, *) {
                ModernMainSplitView(
                    servers: visibleServers,
                    selection: $sidebarSelection,
                    lastServerSelection: $lastServerSelection,
                    showingServerDiscovery: $showingServerDiscovery,
                    onCreateServer: openCreateServerEditor,
                    onCreateIPTVServer: openCreateIPTVServerEditor,
                    onEditServer: openEditServerEditor,
                    onDeleteServer: deleteServer
                )
            } else {
                LegacyMainSplitView(
                    servers: visibleServers,
                    selection: $sidebarSelection,
                    lastServerSelection: $lastServerSelection,
                    showingServerDiscovery: $showingServerDiscovery,
                    onCreateServer: openCreateServerEditor,
                    onCreateIPTVServer: openCreateIPTVServerEditor,
                    onEditServer: openEditServerEditor,
                    onDeleteServer: deleteServer
                )
            }
        }
        .modifier(HideToolbarIfLockedModifier(isLocked: securityService.isLocked))
        .onReceive(NotificationCenter.default.publisher(for: .macNavigateToSettingsAbout)) { _ in
            sidebarSelection = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .macNavigateToDownloads)) { _ in
            sidebarSelection = .downloads
        }
        .overlay {
            if securityService.isLocked {
                MacLockScreenView(securityService: securityService)
                    .transition(.opacity)
                    .zIndex(100)
            }
        }
        .sheet(item: $editorContext) { context in
            MacServerEditorView(existingServer: context.existingServer, prefilledServer: context.prefilledServer, initialType: context.initialType, onSave: context.onSave)
        }
        .sheet(isPresented: $showingServerDiscovery) {
            MacServerDiscoveryView { server in
                showingServerDiscovery = false
                editorContext = MacServerEditorContext(existingServer: nil, prefilledServer: server)
            }
        }

        .frame(minWidth: 1100, minHeight: 720)
        .macRemoteShareOverlay()
        .onAppear {
            normalizeSelection(with: visibleServers)
        }
        .onChange(of: visibleServers) { servers in
            normalizeSelection(with: servers)
        }

    }

    private func normalizeSelection(with servers: [ServerConfig]) {
        sidebarSelection = PlatformShellDestination.normalized(sidebarSelection, servers: servers)
        // If the remembered server was deleted, forget it so we don't restore to a ghost server.
        if let last = lastServerSelection, case .server(let id) = last {
            if !servers.contains(where: { $0.id == id }) {
                lastServerSelection = nil
            }
        }
    }

    private func openCreateServerEditor(initialType: ServerConfig.ServerType = .smb) {
        editorContext = MacServerEditorContext(existingServer: nil, prefilledServer: nil, initialType: initialType)
    }

    private func openCreateIPTVServerEditor() {
        let prefilled = ServerConfig(name: "", address: "", port: nil, useSSL: false, type: .iptv)
        editorContext = MacServerEditorContext(existingServer: nil, prefilledServer: prefilled, initialType: .iptv)
    }

    private func openEditServerEditor(_ server: ServerConfig) {
        editorContext = MacServerEditorContext(existingServer: server, prefilledServer: nil)
    }

    private func deleteServer(_ server: ServerConfig) {
        networkService.deleteServer(server)
        if case .server(let identifier) = sidebarSelection, identifier == server.id {
            sidebarSelection = .servers
        }
    }
}

@available(macOS 13.0, *)
private struct ModernMainSplitView: View {
    let servers: [ServerConfig]
    @Binding var selection: PlatformShellDestination?
    @Binding var lastServerSelection: PlatformShellDestination?
    @Binding var showingServerDiscovery: Bool
    let onCreateServer: (ServerConfig.ServerType) -> Void
    let onCreateIPTVServer: () -> Void
    let onEditServer: (ServerConfig) -> Void
    let onDeleteServer: (ServerConfig) -> Void

    var body: some View {
        NavigationSplitView {
            PlatformSidebarList(
                servers: servers,
                selection: $selection,
                lastServerSelection: $lastServerSelection
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
            .navigationTitle(Text(""))
        } detail: {
            MacDetailTabView(
                selectionBinding: $selection,
                lastServerSelection: $lastServerSelection,
                selection: resolvedSelection,
                servers: servers,
                onCreateServer: onCreateServer,
                onCreateIPTVServer: onCreateIPTVServer,
                onDiscoverServer: { showingServerDiscovery = true },
                onEditServer: onEditServer,
                onDeleteServer: onDeleteServer
            )
            .navigationTitle(Text(""))
            .ignoresSafeArea(.container, edges: .top)
        }
        .onChange(of: selection) { newValue in
            // Keep lastServerSelection up-to-date whenever the user navigates into a server.
            if case .server = newValue {
                lastServerSelection = newValue
            } else if newValue == .servers {
                lastServerSelection = nil
            }
        }
    }

    private var resolvedSelection: PlatformShellDestination {
        PlatformShellDestination.normalized(selection, servers: servers)
    }
}

private struct LegacyMainSplitView: View {
    let servers: [ServerConfig]
    @Binding var selection: PlatformShellDestination?
    @Binding var lastServerSelection: PlatformShellDestination?
    @Binding var showingServerDiscovery: Bool
    let onCreateServer: (ServerConfig.ServerType) -> Void
    let onCreateIPTVServer: () -> Void
    let onEditServer: (ServerConfig) -> Void
    let onDeleteServer: (ServerConfig) -> Void

    var body: some View {
        NavigationView {
            PlatformSidebarList(
                servers: servers,
                selection: $selection,
                lastServerSelection: $lastServerSelection
            )
            MacDetailTabView(
                selectionBinding: $selection,
                lastServerSelection: $lastServerSelection,
                selection: resolvedSelection,
                servers: servers,
                onCreateServer: onCreateServer,
                onCreateIPTVServer: onCreateIPTVServer,
                onDiscoverServer: { showingServerDiscovery = true },
                onEditServer: onEditServer,
                onDeleteServer: onDeleteServer
            )
            .navigationTitle(Text(""))
            .ignoresSafeArea(.container, edges: .top)
        }
        .onChange(of: selection) { newValue in
            if case .server = newValue {
                lastServerSelection = newValue
            } else if newValue == .servers {
                lastServerSelection = nil
            }
        }
    }

    private var resolvedSelection: PlatformShellDestination {
        PlatformShellDestination.normalized(selection, servers: servers)
    }
}

private struct PlatformSidebarList: View {
    let servers: [ServerConfig]
    @Binding var selection: PlatformShellDestination?
    @Binding var lastServerSelection: PlatformShellDestination?

    var body: some View {
        #if os(macOS)
        MacSidebarRail(servers: servers, selection: $selection, lastServerSelection: $lastServerSelection)
        #else
        List(selection: $selection) {
            Section {
                ForEach(PlatformShellDestination.primaryItems, id: \.self) { item in
                    Label(item.localizedTitle, systemImage: item.systemImageName)
                        .tag(Optional(item))
                }
            }

            #if !os(macOS)
            Section(header: platformShellText("Platform Shell Mac Servers Section")) {
                if servers.isEmpty {
                    Text(platformShellString("Platform Shell Empty Servers Title"))
                        .foregroundColor(.secondary)
                } else {
                    ForEach(servers) { server in
                        Label(server.name, systemImage: server.type.systemIconName)
                            .tag(Optional(PlatformShellDestination.server(server.id)))
                    }
                }
            }
            #endif
        }
        .listStyle(.sidebar)
        #endif
    }
}

#if os(macOS)
private struct MacSidebarRail: View {
    let servers: [ServerConfig]
    @Binding var selection: PlatformShellDestination?
    @Binding var lastServerSelection: PlatformShellDestination?
    
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var playerWindowManager = MacPlayerWindowManager.shared
    @State private var showingPrivacyUnlock = false
    @State private var lastNetworkTabClickTime: Date? = nil
    @State private var isPrivacyHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor)
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 30, height: 30)

                Text("Gen Player")
                    .font(.system(size: 18, weight: .bold))
                    .lineLimit(1)
            }
            .padding(.top, 20)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(PlatformShellDestination.primaryItems, id: \.self) { item in
                    MacSidebarRailRow(
                        item: item,
                        isSelected: isSelected(item),
                        action: { handleTap(item) }
                    )
                    .id("\(item.titleKey)_\(appLanguage)")
                }
            }
            .padding(.horizontal, 12)

            Spacer()
            
            if !playerWindowManager.activeFiles.isEmpty {
                let sortedFiles = Array(playerWindowManager.activeFiles.values).sorted(by: { $0.name < $1.name })
                
                if sortedFiles.count > 3 {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(sortedFiles, id: \.id) { playingFile in
                                MacNowPlayingRailItemWrapper(
                                    playingFile: playingFile,
                                    playbackService: playerWindowManager.activePlaybackServices[playingFile.id],
                                    action: {
                                        if let wc = playerWindowManager.activeWindows[playingFile.id] {
                                            wc.window?.makeKeyAndOrderFront(nil)
                                        }
                                    }
                                )
                            }
                        }
                    }
                    .frame(maxHeight: 240)
                    .padding(.horizontal, 12)
                    .padding(.bottom, securityService.isPrivacySpaceEnabled ? 8 : 16)
                } else {
                    VStack(spacing: 8) {
                        ForEach(sortedFiles, id: \.id) { playingFile in
                            MacNowPlayingRailItemWrapper(
                                playingFile: playingFile,
                                playbackService: playerWindowManager.activePlaybackServices[playingFile.id],
                                action: {
                                    if let wc = playerWindowManager.activeWindows[playingFile.id] {
                                        wc.window?.makeKeyAndOrderFront(nil)
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, securityService.isPrivacySpaceEnabled ? 8 : 16)
                }
            }
            
            if securityService.isPrivacySpaceEnabled {
                Button(action: togglePrivacySpaceLock) {
                    HStack(spacing: 8) {
                        Image(systemName: securityService.isPrivacySpaceUnlocked ? "lock.open.fill" : "lock.fill")
                            .font(.system(size: 14))
                        Text(securityService.isPrivacySpaceUnlocked ? platformShellString("Privacy Unlocked") : platformShellString("Privacy Locked"))
                            .font(.system(size: 13, weight: .medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(securityService.isPrivacySpaceUnlocked ? (isPrivacyHovered ? .primary : .secondary) : (isPrivacyHovered ? .accentColor.opacity(0.85) : .accentColor))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isPrivacyHovered ? Color.primary.opacity(0.05) : Color.clear)
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isPrivacyHovered = $0 }
                .macPointerHover()
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(minWidth: 220, idealWidth: 240, maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showingPrivacyUnlock) {
            MacPrivacySpaceUnlockView(isPresented: $showingPrivacyUnlock)
        }
    }

    private func handleTap(_ item: PlatformShellDestination) {
        MacNavigationManager.shared.returnTabSelection = nil
        if item == .servers {
            // If already inside a server, double tapping the Network tab forcefully closes the server page.
            if case .server = selection {
                let now = Date()
                if let last = lastNetworkTabClickTime, now.timeIntervalSince(last) < 0.5 {
                    // Double click confirmed
                    selection = .servers
                    lastServerSelection = nil
                    lastNetworkTabClickTime = nil
                } else {
                    // Single click: just record time
                    lastNetworkTabClickTime = now
                }
                return
            }
            lastNetworkTabClickTime = nil
            // If we are already at the server list root, no-op.
            if selection == .servers {
                return
            }
            // If we have a remembered server, restore it instead of showing the server grid.
            if let last = lastServerSelection {
                selection = last
                return
            }
            // No remembered server — fall through to show the server list.
        }
        selection = item
    }
    
    private func togglePrivacySpaceLock() {
        if securityService.isPrivacySpaceUnlocked {
            securityService.lockPrivacySpace()
        } else {
            showingPrivacyUnlock = true
        }
    }

    private func isSelected(_ item: PlatformShellDestination) -> Bool {
        switch (item, selection) {
        case (.servers, .some(.server)):
            return true
        case (item, .some(let selected)):
            return item == selected
        default:
            return false
        }
    }
}

private struct MacSidebarRailRow: View {
    let item: PlatformShellDestination
    let isSelected: Bool
    let action: () -> Void
    
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @State private var bounceScale: CGFloat = 1.0
    @State private var badgeCount: Int = 0
    @State private var isHovered = false
    
    private var activeDownloadsCount: Int {
        downloadCenter.tasks.filter { $0.status == .downloading || $0.status == .queued }.count
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.18) : (isHovered ? Color.primary.opacity(0.04) : Color.white.opacity(0.001)))
                    Image(systemName: item.systemImageName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isSelected ? .accentColor : (isHovered ? .primary : .secondary))
                }
                .frame(width: 34, height: 34)

                Text(item.localizedTitle)
                    .font(.system(size: 15, weight: isSelected ? .semibold : .medium))
                    .foregroundColor(isSelected ? .primary : (isHovered ? .primary : .secondary))
                    .lineLimit(1)

                Spacer(minLength: 0)
                
                if item == .downloads && badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.08) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(Color.accentColor)
                        .frame(width: 3, height: 24)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .macPointerHover()
        .background(
            Group {
                if item == .downloads {
                    ScreenPositionReader { screenPoint in
                        MacDownloadAnimationService.shared.sidebarDownloadIconScreenPoint = screenPoint
                    }
                }
            }
        )
        .scaleEffect(item == .downloads ? bounceScale : 1.0)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MacDownloadStarted"))) { notification in
            guard item == .downloads else { return }
            if let title = notification.userInfo?["title"] as? String {
                MacDownloadAnimationService.shared.startAnimation(title: title)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("MacDownloadAnimationFinished"))) { _ in
            guard item == .downloads else { return }
            // Sync the badgeCount to match real active downloads when the flying animation lands
            badgeCount = activeDownloadsCount
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5, blendDuration: 0.1)) {
                bounceScale = 1.25
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6, blendDuration: 0.1)) {
                    bounceScale = 1.0
                }
            }
        }
        .onAppear {
            badgeCount = activeDownloadsCount
        }
        .onChange(of: activeDownloadsCount) { newValue in
            // Immediately sync down if count decreases (e.g. download finished or canceled)
            if newValue <= badgeCount {
                badgeCount = newValue
            }
        }
    }
}
#endif

private struct PlatformContentColumn: View {
    @Binding var selectionBinding: PlatformShellDestination?
    let selection: PlatformShellDestination
    let servers: [ServerConfig]
    let onCreateServer: () -> Void
    let onDiscoverServer: () -> Void
    let onEditServer: (ServerConfig) -> Void
    let onDeleteServer: (ServerConfig) -> Void

    @State private var connectingServerID: UUID? = nil
    @State private var connectionError: Error? = nil
    @State private var showingErrorAlert = false
    @State private var authFailedServer: ServerConfig? = nil
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var iptvService = IPTVService.shared
    @ObservedObject private var mediaSummaryService = MediaServerSummaryService.shared

    @State private var pickingID: UUID? = nil
    @State private var activeID: UUID? = nil

    private var shouldHidePrivateServers: Bool {
        securityService.isPrivacySpaceEnabled &&
        securityService.hideLockedItems &&
        !securityService.isPrivacySpaceUnlocked
    }

    var body: some View {
        Group {
            switch selection {
            case .servers:
                serversRootView
            case .server(let identifier):
                serverRootView(for: identifier)
            case .localFiles:
                MacLocalBrowserView()
                    .ignoresSafeArea(.container, edges: .top)
            case .history:
                MacHistoryRootView(
                    onNavigateToServer: { serverId, targetFile in
                        MacNavigationManager.shared.targetFileToResolve = targetFile
                        selectionBinding = .server(serverId)
                    },
                    onNavigateToLocal: { folderURL, targetFile in
                        MacNavigationManager.shared.targetLocalFolderURL = folderURL
                        MacNavigationManager.shared.targetFileToResolve = targetFile
                        selectionBinding = .localFiles
                    }
                )
            case .favorites:
                MacFavoritesRootView(
                    onNavigateToServer: { serverId, targetFile in
                        MacNavigationManager.shared.targetFileToResolve = targetFile
                        selectionBinding = .server(serverId)
                    },
                    onNavigateToLocal: { folderURL, targetFile in
                        MacNavigationManager.shared.targetLocalFolderURL = folderURL
                        MacNavigationManager.shared.targetFileToResolve = targetFile
                        selectionBinding = .localFiles
                    }
                )
            case .settings:
                MacSettingsRootView()
            case .downloads:
                MacDownloadCenterRootView()
            }
        }
        .sheet(item: $showingPrivacyUnlockForServer) { server in
            MacPrivacySpaceUnlockView(isPresented: Binding(
                get: { showingPrivacyUnlockForServer != nil },
                set: { if !$0 { showingPrivacyUnlockForServer = nil } }
            ))
            .onDisappear {
                if securityService.isPrivacySpaceUnlocked {
                    if let pendingServer = pendingPrivacyToggleServer {
                        _ = privacySpace.toggleServerMarkedPrivate(pendingServer)
                        pendingPrivacyToggleServer = nil
                    } else {
                        handleServerTap(server)
                    }
                } else {
                    pendingPrivacyToggleServer = nil
                }
            }
        }
        .alert(isPresented: $showingErrorAlert) {
            Alert(
                title: Text(platformShellString("Connection Failed")),
                message: Text(connectionError?.localizedDescription ?? ""),
                primaryButton: .default(Text(platformShellString("Edit Server"))) {
                    if let s = authFailedServer {
                        onEditServer(s)
                    }
                },
                secondaryButton: .cancel(Text(platformShellString("OK")))
            )
        }
    }

    @ViewBuilder
    private var serversRootView: some View {
        Group {
            if servers.isEmpty {
                VStack(spacing: 14) {
                    PlatformShellEmptyState(
                        titleKey: "Platform Shell Empty Servers Title",
                        bodyKey: "Platform Shell Empty Servers Body"
                    )
                    Button(platformShellString("Add Server"), action: onCreateServer)
                }
            } else {
                List(servers) { server in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(server.name)
                            .font(.headline)
                        Text(server.type.displayName)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text(server.fullURL)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                    .overlay(
                        MacRightClickMenuOverlay {
                            MacServerMenuBuilder.buildMenu(
                                for: server,
                                onOpen: { server in handleServerTap(server) },
                                onEdit: onEditServer,
                                onDelete: onDeleteServer,
                                privacyEnabled: securityService.isPrivacySpaceEnabled,
                                isPrivateServer: privacySpace.isServerMarkedPrivate(server),
                                onTogglePrivacy: { handleTogglePrivacy(for: server) }
                            )
                        }
                    )
                }
            }
        }
        .navigationTitle(Text(selection.localizedTitle))
    }

    @ViewBuilder
    private func macServerCardWithMenu(for server: ServerConfig, isDragged: Bool) -> some View {
        MacServerCardCell(
            server: server,
            isDragged: isDragged,
            isConnecting: connectingServerID == server.id || (server.type == .iptv ? iptvService.loadingServers.contains(server.id) : mediaSummaryService.loadingServers.contains(server.id)),
            onOpen: { server in handleServerTap(server) },
            onEdit: onEditServer,
            onDelete: onDeleteServer,
            privacyEnabled: securityService.isPrivacySpaceEnabled,
            isPrivateServer: privacySpace.isServerMarkedPrivate(server),
            onTogglePrivacy: { handleTogglePrivacy(for: server) }
        )
    }

    @State private var connectingTask: Task<Void, Never>?
    @State private var showingPrivacyUnlockForServer: ServerConfig? = nil
    @State private var pendingPrivacyToggleServer: ServerConfig? = nil

    private func handleTogglePrivacy(for server: ServerConfig) {
        if privacySpace.isServerMarkedPrivate(server) && !securityService.isPrivacySpaceUnlocked {
            pendingPrivacyToggleServer = server
            showingPrivacyUnlockForServer = server
        } else {
            _ = privacySpace.toggleServerMarkedPrivate(server)
        }
    }

    private func handleServerTap(_ server: ServerConfig) {
        if privacySpace.isServerMarkedPrivate(server) && !securityService.isPrivacySpaceUnlocked {
            showingPrivacyUnlockForServer = server
            return
        }
        
        if connectingServerID == server.id {
            connectingTask?.cancel()
            connectingTask = nil
            connectingServerID = nil
            return
        }
        if connectingServerID != nil { return }
        
        connectingServerID = server.id
        connectingTask = Task {
            do {
                let updated = try await macTestServerConnection(server)
                if Task.isCancelled { return }
                await MainActor.run {
                    connectingServerID = nil
                    connectingTask = nil
                    AppNetworkService.shared.updateServer(updated)
                    AppNetworkService.shared.recordServerAccess(updated.id)
                    selectionBinding = .server(updated.id)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    connectingServerID = nil
                    connectingTask = nil
                    connectionError = error
                    authFailedServer = server
                    showingErrorAlert = true
                    let nsError = error as NSError
                    let isAuthError = (nsError.domain == "GenPlayerShell" && nsError.code == 401) || nsError.code == 401 || nsError.code == 403
                    if isAuthError {
                        AppNetworkService.shared.clearServerAuthTokens(for: server.id)
                    }
                }
            }
        }
    }


    @ViewBuilder
    private func serverRootView(for identifier: UUID) -> some View {
        if let server = servers.first(where: { $0.id == identifier }) {
            if server.type == .vod {
                MacVODLibraryView(server: server) {
                    selectionBinding = .servers
                }
            } else if server.type.macIsMediaLibraryServer {
                if #available(macOS 13.0, *) {
                    NavigationStack {
                        MacServerHubView(server: server) {
                            selectionBinding = .servers
                        }
                    }
                } else {
                    NavigationView {
                        MacServerHubView(server: server) {
                            selectionBinding = .servers
                        }
                    }
                }
            } else {
                MacRemoteBrowserView(server: server) {
                    selectionBinding = .servers
                }
            }
        } else {
            PlatformShellEmptyState(
                titleKey: "Platform Shell Detail Placeholder Title",
                bodyKey: "Platform Shell Detail Placeholder Body"
            )
        }
    }
}

private struct MacServerEditorContext: Identifiable {
    let id = UUID()
    let existingServer: ServerConfig?
    let prefilledServer: ServerConfig?
    var initialType: ServerConfig.ServerType = .smb
    var onSave: ((ServerConfig) -> Void)? = nil
}

private struct PlatformDetailColumn: View {
    let selection: PlatformShellDestination
    let servers: [ServerConfig]

    var body: some View {
        switch selection {
        case .server(let identifier):
            if let server = servers.first(where: { $0.id == identifier }) {
                if server.type.macIsMediaLibraryServer {
                    PlatformSectionPreview(selection: selection)
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        Label(server.name, systemImage: server.type.systemIconName)
                            .font(.title2.weight(.semibold))
                        Text(server.fullURL)
                            .foregroundColor(.secondary)
                        Divider()
                        Text(platformShellString("Platform Shell Detail Placeholder Body"))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(28)
                }
            } else {
                PlatformShellEmptyState(
                    titleKey: "Platform Shell Detail Placeholder Title",
                    bodyKey: "Platform Shell Detail Placeholder Body"
                )
            }
        case .downloads:
            VStack {
                Text(platformShellString("Download Center"))
                    .font(.title)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        default:
            VStack {
                VLCPlayerSurfacePlaceholderView()
            }
            .padding(28)
        }
    }
}

private struct PlatformSectionPreview: View {
    let selection: PlatformShellDestination

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(selection.localizedTitle, systemImage: selection.systemImageName)
                .font(.title2.weight(.semibold))
            Text(platformShellString("Platform Shell Detail Placeholder Body"))
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(28)
    }
}

private struct PlatformShellEmptyState: View {
    let titleKey: String
    let bodyKey: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "rectangle.stack.badge.plus")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(.accentColor)
            Text(platformShellString(titleKey))
                .font(.headline)
            Text(platformShellString(bodyKey))
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct PlatformKeyValueRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.body)
        }
        .padding(.vertical, 4)
    }
}

#if os(macOS)
/// Full cell combining card + "…" menu button, with unified hover scale/shadow.
/// No Button wrapper — uses onTapGesture so .onDrag fires correctly on macOS.
struct MacServerCardCell: View {
    let server: ServerConfig
    var isDragged: Bool = false
    var isConnecting: Bool = false
    var onOpen: ((ServerConfig) -> Void)? = nil
    let onEdit: (ServerConfig) -> Void
    let onDelete: (ServerConfig) -> Void
    var privacyEnabled: Bool = false
    var isPrivateServer: Bool = false
    let onTogglePrivacy: () -> Void

    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @State private var isHovered = false

    private func buildMenu() -> NSMenu {
        MacServerMenuBuilder.buildMenu(
            for: server,
            onOpen: onOpen,
            onEdit: onEdit,
            onDelete: onDelete,
            privacyEnabled: privacyEnabled,
            isPrivateServer: isPrivateServer,
            onTogglePrivacy: onTogglePrivacy
        )
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MacServerCardView(
                server: server,
                isConnecting: isConnecting,
                isHoveredExternally: isHovered
            )
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .onTapGesture {
                onOpen?(server)
            }
            .overlay(
                MacRightClickMenuOverlay(menuBuilder: buildMenu)
            )

            MacServerMenuButton(
                server: server,
                onOpen: onOpen,
                onEdit: onEdit,
                onDelete: onDelete,
                privacyEnabled: privacyEnabled,
                isPrivateServer: isPrivateServer,
                onTogglePrivacy: onTogglePrivacy
            )
                .padding(.top, 12)
                .padding(.trailing, 12)
        }
        .opacity(isDragged ? 0.5 : 1.0)
        .shadow(color: Color.black.opacity(isHovered ? 0.25 : 0.15),
                radius: isHovered ? 10 : 5, x: 0, y: isHovered ? 5 : 2)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .zIndex(isHovered ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { isHovered = $0 }
        .macPointerHover()
        .onAppear {
            refreshVODSummaryIfNeeded()
        }
        .onChange(of: server.vodSources) { _ in
            refreshVODSummaryIfNeeded()
        }
    }

    private func refreshVODSummaryIfNeeded() {
        guard server.type == .vod else { return }
        Task {
            await server.macRefreshVODSummaries(onlyMissing: true)
        }
    }

}
#endif

#if os(macOS)
struct MacServerCardView: View {
    let server: ServerConfig
    var isConnecting: Bool = false
    var isHoveredExternally: Bool = false
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var mediaSummaryService = MediaServerSummaryService.shared
    
    private var hasThirdLine: Bool {
        return true
    }

    var gradientColors: [Color] {
        switch server.type {
        case .smb:
            return [Color(red: 0.1, green: 0.15, blue: 0.3), Color(red: 0.2, green: 0.25, blue: 0.4)]
        case .webdav:
            return [Color(red: 0.16, green: 0.56, blue: 0.95), Color(red: 0.08, green: 0.37, blue: 0.82)]
        case .alist:
            return [Color(red: 0.0, green: 0.70, blue: 0.85), Color(red: 0.02, green: 0.36, blue: 0.48)]
        case .pan115:
            return [Color(red: 0.20, green: 0.40, blue: 0.95), Color(red: 0.10, green: 0.18, blue: 0.60)]
        case .onedrive:
            return [Color(red: 0.0, green: 0.47, blue: 0.83), Color(red: 0.04, green: 0.26, blue: 0.52)]
        case .googledrive:
            return [Color(red: 0.96, green: 0.70, blue: 0.12), Color(red: 0.85, green: 0.48, blue: 0.05)]
        case .ftp:
            return [Color(red: 0.83, green: 0.48, blue: 0.41), Color(red: 0.70, green: 0.35, blue: 0.30)]
        case .sftp:
            return [Color(red: 0.33, green: 0.68, blue: 0.71), Color(red: 0.20, green: 0.53, blue: 0.55)]
        case .nfs:
            return [Color(red: 0.51, green: 0.63, blue: 0.80), Color(red: 0.40, green: 0.50, blue: 0.65)]
        case .jellyfin:
            return [Color(red: 0.6, green: 0.4, blue: 0.8), Color(red: 0.4, green: 0.2, blue: 0.6)]
        case .emby:
            return [Color(red: 0.3, green: 0.7, blue: 0.4), Color(red: 0.1, green: 0.5, blue: 0.2)]
        case .plex:
            return [Color(red: 0.9, green: 0.6, blue: 0.2), Color(red: 0.8, green: 0.4, blue: 0.1)]
        case .iptv:
            return [Color(red: 0.38, green: 0.34, blue: 0.88), Color(red: 0.24, green: 0.18, blue: 0.68)]
        case .vod:
            return [Color(red: 0.18, green: 0.52, blue: 0.92), Color(red: 0.08, green: 0.28, blue: 0.65)]
        }
    }
    
    var body: some View {
        ZStack {
            LinearGradient(gradient: Gradient(colors: gradientColors), startPoint: .topLeading, endPoint: .bottomTrailing)
            
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                if let nsImage = NSImage(named: server.type.iconAssetName) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 90, height: 90)
                        .foregroundColor(.black.opacity(0.1))
                        .rotationEffect(.degrees(-20))
                        .offset(x: 20, y: 20)
                } else {
                    Image(systemName: server.type.systemIconName)
                        .font(.system(size: 80))
                        .foregroundColor(.black.opacity(0.1))
                        .rotationEffect(.degrees(-20))
                        .offset(x: 20, y: 20)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 10) {
                    HStack(spacing: 6) {
                        if let nsImage = NSImage(named: server.type.iconAssetName) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 28, height: 28)
                        } else {
                            Image(systemName: server.type.systemIconName)
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundColor(.white)
                        }
                        
                        Text(server.type.displayName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white.opacity(0.92))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.3))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                
                if hasThirdLine {
                    Spacer(minLength: 2)
                        .frame(maxHeight: 8)

                    VStack(alignment: .leading, spacing: 2.5) {
                        Text(server.name)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        
                        Text(server.address)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.8))
                            .lineLimit(1)
                        
                        if server.type == .iptv {
                            if let summary = IPTVService.shared.summary(for: server.id) {
                                HStack(spacing: 7) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "rectangle.stack")
                                        Text("\(summary.groupCount)")
                                    }
                                    HStack(spacing: 3) {
                                        Image(systemName: "tv")
                                        Text(NumberFormatter.localizedString(from: NSNumber(value: summary.channelCount), number: .decimal))
                                    }
                                    HStack(spacing: 3) {
                                        Image(systemName: "clock")
                                        Text(IPTVService.shared.formatLastUpdated(summary.lastUpdated))
                                    }
                                }
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.92))
                                .lineLimit(1)
                            } else {
                                Text(platformShellString("Not loaded yet"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.72))
                                    .lineLimit(1)
                            }
                        } else if server.type == .vod && server.macVODSources.count > 1 {
                            HStack(spacing: 7) {
                                Label(String(format: platformShellString("VOD Source Count %d"), server.macVODSources.count), systemImage: "square.stack.3d.up")
                                if let count = server.macVODSummaryEndpoints.compactMap({ mediaSummaryService.summary(for: $0.id)?.libraryCount }).max() {
                                    Label(NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal), systemImage: "film")
                                }
                            }
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.92))
                                .lineLimit(1)
                        } else if let mediaSummary = mediaSummaryService.summary(for: server.id) {
                            HStack(spacing: 7) {
                                if mediaSummary.movieCount > 0 || mediaSummary.seriesCount > 0 {
                                    if mediaSummary.movieCount > 0 {
                                        HStack(spacing: 3) {
                                            Image(systemName: "film")
                                            Text(NumberFormatter.localizedString(from: NSNumber(value: mediaSummary.movieCount), number: .decimal))
                                        }
                                    }
                                    if mediaSummary.seriesCount > 0 {
                                        HStack(spacing: 3) {
                                            Image(systemName: "tv")
                                            Text(NumberFormatter.localizedString(from: NSNumber(value: mediaSummary.seriesCount), number: .decimal))
                                        }
                                    }
                                } else {
                                    HStack(spacing: 3) {
                                        Image(systemName: "square.stack.3d.up")
                                        Text(NumberFormatter.localizedString(from: NSNumber(value: mediaSummary.libraryCount), number: .decimal))
                                    }
                                }
                                HStack(spacing: 3) {
                                    Image(systemName: "clock")
                                    Text(MediaServerSummaryService.shared.formatLastUpdated(mediaSummary.lastUpdated))
                                }
                            }
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(.white.opacity(0.92))
                            .lineLimit(1)
                        } else if server.type.isMediaServer {
                            Text(platformShellString("Not loaded yet"))
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.72))
                                .lineLimit(1)
                        } else {
                            if let lastAccessed = server.lastAccessed {
                                HStack(spacing: 3) {
                                    Image(systemName: "clock")
                                    Text(MediaServerSummaryService.shared.formatLastUpdated(lastAccessed))
                                }
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.92))
                                .lineLimit(1)
                            } else {
                                Text(platformShellString("Not accessed yet"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.white.opacity(0.72))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Spacer(minLength: 2)
                }
            }
            .padding(16)
            
            if isConnecting {
                ZStack {
                    Color.black.opacity(0.3)
                    VStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.8)
                            .colorScheme(.dark)
                        if isHoveredExternally {
                            Text(platformShellString("Cancel"))
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.white)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            
            if securityService.isPrivacySpaceEnabled && privacySpace.isServerMarkedPrivate(server) {
                Image(systemName: securityService.isPrivacySpaceUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.black.opacity(0.3))
                    .clipShape(Circle())
                    .padding(.bottom, 12)
                    .padding(.trailing, 12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 120, alignment: .topLeading)
        .cornerRadius(20)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.white.opacity(isHoveredExternally ? 0.3 : 0.1), lineWidth: 1)
        )
    }
}

struct MacAddServerCardView: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.accentColor)
            
            Text(platformShellString("Add Server"))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 120)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.accentColor.opacity(isHovered ? 0.6 : 0.3), style: StrokeStyle(lineWidth: 2, dash: [6]))
        )
        .cornerRadius(20)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .zIndex(isHovered ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .macPointerHover()
        .contentShape(Rectangle())
    }
}

struct MacDiscoverServerCardView: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.accentColor)
            
            Text(platformShellString("Discovered Servers"))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 120)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.accentColor.opacity(isHovered ? 0.6 : 0.3), style: StrokeStyle(lineWidth: 2, dash: [6]))
        )
        .cornerRadius(20)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .zIndex(isHovered ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .macPointerHover()
        .contentShape(Rectangle())
    }
}

struct MacAddIPTVCardView: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            Image(systemName: "plus")
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.accentColor)
            
            Text(platformShellString("Add IPTV"))
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 120, idealHeight: 120)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color.accentColor.opacity(isHovered ? 0.6 : 0.3), style: StrokeStyle(lineWidth: 2, dash: [6]))
        )
        .cornerRadius(20)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .zIndex(isHovered ? 1 : 0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .macPointerHover()
        .contentShape(Rectangle())
    }
}
#endif



#if os(macOS)
@objc final class MacServerMenuActionBridge: NSObject {
    let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
        super.init()
    }

    @objc func invoke() {
        handler()
    }
}

enum MacServerMenuBuilder {
    static func buildMenu(
        for server: ServerConfig,
        onOpen: ((ServerConfig) -> Void)?,
        onEdit: @escaping (ServerConfig) -> Void,
        onDelete: @escaping (ServerConfig) -> Void,
        privacyEnabled: Bool,
        isPrivateServer: Bool,
        onTogglePrivacy: (() -> Void)?
    ) -> NSMenu {
        let menu = NSMenu()

        if let onOpen = onOpen {
            let openItem = NSMenuItem(
                title: platformShellString("Open"),
                action: #selector(MacServerMenuActionBridge.invoke),
                keyEquivalent: ""
            )
            openItem.image = NSImage(systemSymbolName: server.type == .iptv ? "play.circle" : "arrow.right.circle", accessibilityDescription: nil)
            let bridge = MacServerMenuActionBridge { onOpen(server) }
            openItem.target = bridge
            openItem.representedObject = bridge
            menu.addItem(openItem)
        }

        if server.type == .iptv {
            let refreshItem = NSMenuItem(
                title: platformShellString("Refresh Playlist"),
                action: #selector(MacServerMenuActionBridge.invoke),
                keyEquivalent: ""
            )
            refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            let refreshBridge = MacServerMenuActionBridge {
                Task {
                    _ = try? await IPTVService.shared.fetchPlaylist(for: server, forceRefresh: true)
                }
            }
            refreshItem.target = refreshBridge
            refreshItem.representedObject = refreshBridge
            menu.addItem(refreshItem)

            let copyUrlItem = NSMenuItem(
                title: platformShellString("Copy Playlist URL"),
                action: #selector(MacServerMenuActionBridge.invoke),
                keyEquivalent: ""
            )
            copyUrlItem.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            let copyUrlBridge = MacServerMenuActionBridge {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(server.address, forType: .string)
            }
            copyUrlItem.target = copyUrlBridge
            copyUrlItem.representedObject = copyUrlBridge
            menu.addItem(copyUrlItem)
        } else if server.type.macIsMediaLibraryServer {
            let refreshItem = NSMenuItem(
                title: platformShellString("Refresh Library"),
                action: #selector(MacServerMenuActionBridge.invoke),
                keyEquivalent: ""
            )
            refreshItem.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            let refreshBridge = MacServerMenuActionBridge {
                Task {
                    if server.type == .vod {
                        await server.macRefreshVODSummaries(onlyMissing: false)
                    } else {
                        await MediaServerSummaryService.shared.refreshSummary(for: server)
                    }
                }
            }
            refreshItem.target = refreshBridge
            refreshItem.representedObject = refreshBridge
            menu.addItem(refreshItem)
        }

        let editItem = NSMenuItem(
            title: platformShellString("Edit Server"),
            action: #selector(MacServerMenuActionBridge.invoke),
            keyEquivalent: ""
        )
        editItem.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        let editBridge = MacServerMenuActionBridge { onEdit(server) }
        editItem.target = editBridge
        editItem.representedObject = editBridge
        menu.addItem(editItem)

        if privacyEnabled {
            let privacyTitle = platformShellString(isPrivateServer ? "Remove from Privacy Space" : "Add to Privacy Space")
            let privacyIcon = isPrivateServer ? "lock.open" : "lock"
            let privacyItem = NSMenuItem(
                title: privacyTitle,
                action: #selector(MacServerMenuActionBridge.invoke),
                keyEquivalent: ""
            )
            privacyItem.image = NSImage(systemSymbolName: privacyIcon, accessibilityDescription: nil)
            let privacyBridge = MacServerMenuActionBridge { onTogglePrivacy?() }
            privacyItem.target = privacyBridge
            privacyItem.representedObject = privacyBridge
            menu.addItem(privacyItem)
        }

        let deleteItem = NSMenuItem(
            title: platformShellString("Delete"),
            action: #selector(MacServerMenuActionBridge.invoke),
            keyEquivalent: ""
        )
        deleteItem.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        let deleteBridge = MacServerMenuActionBridge { onDelete(server) }
        deleteItem.target = deleteBridge
        deleteItem.representedObject = deleteBridge
        menu.addItem(deleteItem)

        return menu
    }
}

struct MacRightClickMenuOverlay: NSViewRepresentable {
    let menuBuilder: () -> NSMenu

    func makeNSView(context: Context) -> MacRightClickNSView {
        let view = MacRightClickNSView()
        view.menuBuilder = menuBuilder
        return view
    }

    func updateNSView(_ nsView: MacRightClickNSView, context: Context) {
        nsView.menuBuilder = menuBuilder
    }
}

final class MacRightClickNSView: NSView {
    var menuBuilder: (() -> NSMenu)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let currentEvent = NSApp.currentEvent
        let isRightClick = currentEvent?.type == .rightMouseDown || (NSEvent.pressedMouseButtons & 2) != 0
        let isControlLeftClick = currentEvent?.type == .leftMouseDown && (currentEvent?.modifierFlags.contains(.control) == true)
        if isRightClick || isControlLeftClick {
            return self
        }
        return nil
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        return menuBuilder?()
    }

    override func rightMouseDown(with event: NSEvent) {
        if let menu = menuBuilder?() {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        } else {
            super.rightMouseDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            rightMouseDown(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

struct MacServerMenuButton: View {
    let server: ServerConfig
    var onOpen: ((ServerConfig) -> Void)? = nil
    let onEdit: (ServerConfig) -> Void
    let onDelete: (ServerConfig) -> Void
    var privacyEnabled: Bool = false
    var isPrivateServer: Bool = false
    var onTogglePrivacy: (() -> Void)? = nil
    @State private var isHovered = false
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared

    private func showMenu() {
        let menu = MacServerMenuBuilder.buildMenu(
            for: server,
            onOpen: onOpen,
            onEdit: onEdit,
            onDelete: onDelete,
            privacyEnabled: privacyEnabled,
            isPrivateServer: isPrivateServer,
            onTogglePrivacy: onTogglePrivacy
        )

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        }
    }

    var body: some View {
        Button(action: showMenu) {
            ZStack {
                Circle()
                    .fill(Color.black.opacity(isHovered ? 0.65 : 0.30))
                    .frame(width: 28, height: 28)

                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(.white)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .macPointerHover()
    }
}

struct HideToolbarIfLockedModifier: ViewModifier {
    let isLocked: Bool
    
    func body(content: Content) -> some View {
        if #available(macOS 13.0, *) {
            content.toolbar(isLocked ? .hidden : .visible, for: .windowToolbar)
        } else {
            content
        }
    }
}
#endif

#if os(macOS)
import UniformTypeIdentifiers

struct MacReorderableForEach<Item: Identifiable & Equatable, Content: View>: View {
    @Binding var items: [Item]
    @Binding var pickingID: Item.ID?
    @Binding var activeID: Item.ID?
    @ViewBuilder let content: (Item, Bool) -> Content
    let onComplete: () -> Void

    var body: some View {
        ForEach(items) { item in
            let isItemDragged = activeID == item.id
            content(item, isItemDragged)
                .onDrag {
                    self.pickingID = item.id
                    return NSItemProvider(item: "\(item.id)" as NSString, typeIdentifier: UTType.plainText.identifier)
                }
                .id(item.id)
                .onDrop(of: [UTType.plainText], delegate: MacReorderableDropDelegate(
                    item: item,
                    items: $items,
                    pickingID: $pickingID,
                    activeID: $activeID,
                    onComplete: onComplete
                ))
        }
    }
}

struct MacReorderableDropDelegate<Item: Identifiable & Equatable>: DropDelegate {
    let item: Item
    @Binding var items: [Item]
    @Binding var pickingID: Item.ID?
    @Binding var activeID: Item.ID?
    let onComplete: () -> Void

    func dropEntered(info: DropInfo) {
        if let pid = pickingID {
            if activeID == nil {
                activeID = pid
            }
        }
        
        guard let activeID = activeID, activeID != item.id else { return }
        
        if let from = items.firstIndex(where: { $0.id == activeID }),
           let to = items.firstIndex(where: { $0.id == item.id }) {
            if items[to].id != activeID {
                withAnimation {
                    items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                }
            }
        }
    }
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let pid = pickingID, activeID == nil {
            activeID = pid
        }
        return DropProposal(operation: .move)
    }
    
    func performDrop(info: DropInfo) -> Bool {
        self.activeID = nil
        self.pickingID = nil
        onComplete()
        return true
    }
    
    func dropExited(info: DropInfo) {}
}
#endif

#if os(macOS)
struct MacServerCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.9 : 1.0)
    }
}
#endif

#if os(macOS)
private struct MacNowPlayingRailItemWrapper: View {
    let playingFile: VideoFile
    let playbackService: MacVLCPlaybackService?
    let action: () -> Void
    
    var body: some View {
        if let service = playbackService {
            MacNowPlayingRailItem(playingFile: playingFile, playbackService: service, action: action)
        } else {
            MacNowPlayingRailItemFallback(playingFile: playingFile, action: action)
        }
    }
}

private struct MacNowPlayingRailItem: View {
    let playingFile: VideoFile
    @ObservedObject var playbackService: MacVLCPlaybackService
    let action: () -> Void
    @State private var isCloseHovered = false
    
    private var playbackServer: ServerConfig? {
        if let uuidString = playingFile.jellyfinServerId, let uuid = UUID(uuidString: uuidString) {
            return AppNetworkService.shared.servers.first { $0.id == uuid }
        }
        return AppNetworkService.shared.servers.first { $0.type == playingFile.serverType }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                HStack(spacing: 10) {
                    ZStack {
                        MacRemoteFileImage(file: playingFile, server: playbackServer, contentMode: .fill)
                            .frame(width: 32, height: 32)
                            .clipShape(Circle())
                        
                        Circle()
                            .stroke(Color.primary.opacity(0.1), lineWidth: 2)
                            .frame(width: 32, height: 32)
                        
                        Circle()
                            .trim(from: 0, to: max(CGFloat(playbackService.position), 0.001))
                            .stroke(
                                Color.accentColor,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round)
                            )
                            .frame(width: 32, height: 32)
                            .rotationEffect(.degrees(-90))
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playingFile.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .foregroundColor(.primary)
                        HStack(spacing: 4) {
                            Image(systemName: playbackService.isPlaying ? "play.fill" : "pause.fill")
                                .font(.system(size: 9))
                            Text(playbackService.isPlaying ? platformShellString("Playing") : platformShellString("Paused"))
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 24)
                }
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .macPointerHover()
            
            Button {
                MacPlayerWindowManager.shared.closePlayer(for: playingFile.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isCloseHovered ? .primary : .secondary)
                    .frame(width: 20, height: 20)
                    .background(isCloseHovered ? Color.primary.opacity(0.12) : Color.clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isCloseHovered = $0 }
            .macPointerHover()
            .padding(.trailing, 8)
        }
    }
}

private struct MacNowPlayingRailItemFallback: View {
    let playingFile: VideoFile
    let action: () -> Void
    @State private var isCloseHovered = false
    
    private var playbackServer: ServerConfig? {
        if let uuidString = playingFile.jellyfinServerId, let uuid = UUID(uuidString: uuidString) {
            return AppNetworkService.shared.servers.first { $0.id == uuid }
        }
        return AppNetworkService.shared.servers.first { $0.type == playingFile.serverType }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: action) {
                HStack(spacing: 10) {
                    MacRemoteFileImage(file: playingFile, server: playbackServer, contentMode: .fill)
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playingFile.name)
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                            .foregroundColor(.primary)
                        Text(platformShellString("Now Playing"))
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    Spacer(minLength: 24)
                }
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .macPointerHover()
            
            Button {
                MacPlayerWindowManager.shared.closePlayer(for: playingFile.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isCloseHovered ? .primary : .secondary)
                    .frame(width: 20, height: 20)
                    .background(isCloseHovered ? Color.primary.opacity(0.12) : Color.clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { isCloseHovered = $0 }
            .macPointerHover()
            .padding(.trailing, 8)
        }
    }
}
#endif

#if os(macOS)

// MARK: - Screen Position Reader (NSView bridge for accurate screen coordinates)

/// Captures the center position of this view in screen coordinates via AppKit.
/// Unlike SwiftUI coordinate spaces, this works reliably across NavigationSplitView columns.
struct ScreenPositionReader: NSViewRepresentable {
    let onChange: (CGPoint) -> Void

    func makeNSView(context: Context) -> ScreenPositionNSView {
        let view = ScreenPositionNSView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: ScreenPositionNSView, context: Context) {
        nsView.onChange = onChange
        // Re-report on every SwiftUI update pass so layout changes are captured
        DispatchQueue.main.async { nsView.reportPosition() }
    }

    class ScreenPositionNSView: NSView {
        var onChange: ((CGPoint) -> Void)?

        override func layout() {
            super.layout()
            reportPosition()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.reportPosition() }
        }

        func reportPosition() {
            guard let window = self.window else { return }
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            let windowPoint = convert(center, to: nil)
            let screenPoint = window.convertPoint(toScreen: windowPoint)
            onChange?(screenPoint)
        }
    }
}

// MARK: - Download Animation Service (NSPanel-based)

class MacDownloadAnimationService: ObservableObject {
    static let shared = MacDownloadAnimationService()

    /// Sidebar download icon position in **screen** coordinates (AppKit bottom-left origin).
    var sidebarDownloadIconScreenPoint: CGPoint = .zero

    /// Captured at button-click time so the mouse hasn't moved by the time the animation fires.
    private var lastClickScreenPoint: CGPoint? = nil

    /// Keep strong references to panels until animation finishes.
    private var activePanels: [NSPanel] = []

    init() {
        NotificationCenter.default.addObserver(
            forName: NSNotification.Name("MacDownloadAction"),
            object: nil, queue: .main
        ) { [weak self] notification in
            if let point = notification.userInfo?["screenPoint"] as? CGPoint {
                self?.lastClickScreenPoint = point
            }
        }
    }

    func startAnimation(title: String) {
        guard let window = NSApp.mainWindow ?? NSApp.keyWindow else { return }
        guard sidebarDownloadIconScreenPoint != .zero else { return }

        // Start: captured click position, or fall back to current mouse position
        let startScreen = lastClickScreenPoint ?? NSEvent.mouseLocation
        let endScreen = sidebarDownloadIconScreenPoint
        let windowFrame = window.frame

        // Convert screen coordinates → panel-local (SwiftUI top-left origin)
        let startLocal = CGPoint(
            x: startScreen.x - windowFrame.origin.x,
            y: windowFrame.height - (startScreen.y - windowFrame.origin.y)
        )
        let endLocal = CGPoint(
            x: endScreen.x - windowFrame.origin.x,
            y: windowFrame.height - (endScreen.y - windowFrame.origin.y)
        )

        // Borderless transparent panel matching the main window frame
        let panel = NSPanel(
            contentRect: windowFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)

        let flyingView = ZStack {
            MacFlyingItemView(
                localStart: startLocal,
                localEnd: endLocal,
                title: title
            )
        }
        .frame(width: windowFrame.width, height: windowFrame.height)
        .allowsHitTesting(false)

        let hostingView = NSHostingView(rootView: flyingView)
        hostingView.frame = NSRect(origin: .zero, size: windowFrame.size)
        panel.contentView = hostingView

        window.addChildWindow(panel, ordered: .above)
        activePanels.append(panel)
        lastClickScreenPoint = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            window.removeChildWindow(panel)
            panel.orderOut(nil)
            self?.activePanels.removeAll { $0 === panel }
        }
    }
}

// MARK: - Parabola Animation Helpers

struct ParabolaModifier: AnimatableModifier {
    var progress: CGFloat
    var startPoint: CGPoint
    var endPoint: CGPoint
    var controlPointHeight: CGFloat = 100

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let x = startPoint.x + (endPoint.x - startPoint.x) * progress
        let p0 = startPoint.y
        let p2 = endPoint.y
        let p1 = min(p0, p2) - controlPointHeight

        let t = progress
        let y = pow(1-t, 2) * p0 + 2 * (1-t) * t * p1 + pow(t, 2) * p2
        
        let currentScale = t > 0.7 ? max(0.2, 1.0 - (t - 0.7) * (1.0 / 0.3)) : 1.0
        let currentOpacity = t > 0.8 ? max(0.0, 1.0 - (t - 0.8) * (1.0 / 0.2)) : 1.0

        return content
            .scaleEffect(currentScale)
            .opacity(currentOpacity)
            .position(x: x, y: y)
    }
}

struct MacFlyingItemView: View {
    let localStart: CGPoint
    let localEnd: CGPoint
    let title: String
    @State private var progress: CGFloat = 0.0

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(.white)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentColor)
        .cornerRadius(20)
        .shadow(radius: 5)
        .modifier(ParabolaModifier(progress: progress, startPoint: localStart, endPoint: localEnd))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.7)) {
                progress = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                NotificationCenter.default.post(name: NSNotification.Name("MacDownloadAnimationFinished"), object: nil)
            }
        }
    }
}
#endif
#endif
