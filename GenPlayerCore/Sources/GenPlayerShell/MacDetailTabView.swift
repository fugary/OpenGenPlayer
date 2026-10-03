import SwiftUI
import GenPlayerCore

#if os(macOS)
class MacTabContext: ObservableObject {
    @Published var activeSelection: PlatformShellDestination?
    @Published var appLanguage: String = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
}

struct MacDetailTabView: NSViewControllerRepresentable {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @Binding var selectionBinding: PlatformShellDestination?
    @Binding var lastServerSelection: PlatformShellDestination?
    let selection: PlatformShellDestination
    let servers: [ServerConfig]
    let onCreateServer: (ServerConfig.ServerType) -> Void
    let onCreateIPTVServer: () -> Void
    let onDiscoverServer: () -> Void
    let onEditServer: (ServerConfig) -> Void
    let onDeleteServer: (ServerConfig) -> Void

    func makeNSViewController(context: Context) -> MacDetailCacheController {
        MacDetailCacheController()
    }

    func updateNSViewController(_ nsViewController: MacDetailCacheController, context: Context) {
        nsViewController.tabContext.activeSelection = selection
        if nsViewController.tabContext.appLanguage != appLanguage {
            nsViewController.tabContext.appLanguage = appLanguage
        }
        nsViewController.update(
            selectionBinding: _selectionBinding,
            lastServerSelection: _lastServerSelection,
            selection: selection,
            servers: servers,
            onCreateServer: onCreateServer,
            onCreateIPTVServer: onCreateIPTVServer,
            onDiscoverServer: onDiscoverServer,
            onEditServer: onEditServer,
            onDeleteServer: onDeleteServer
        )
    }
}

class MacDetailCacheController: NSTabViewController {
    let tabContext = MacTabContext()
    private var cachedControllers: [String: NSViewController] = [:]
    private var servers: [ServerConfig] = []
    
    override func viewDidLoad() {
        super.viewDidLoad()
        self.tabStyle = .unspecified
        self.transitionOptions = []
        self.tabView.drawsBackground = false
    }
    
    override func viewDidAppear() {
        super.viewDidAppear()
        updateWindowTitle()
    }
    
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        updateWindowTitle()
    }
    
    func updateWindowTitle() {
        guard let window = self.view.window else { return }
        if let selection = tabContext.activeSelection {
            let title = titleForSelection(selection, servers: self.servers)
            window.title = title
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }
    }
    
    private func titleForSelection(_ selection: PlatformShellDestination, servers: [ServerConfig]) -> String {
        // We now use MacPageHeaderView inside the views.
        // Returning "" clears any leftover system title when switching away from a server view.
        return ""
    }
    
    func update(
        selectionBinding: Binding<PlatformShellDestination?>,
        lastServerSelection: Binding<PlatformShellDestination?>,
        selection: PlatformShellDestination,
        servers: [ServerConfig],
        onCreateServer: @escaping (ServerConfig.ServerType) -> Void,
        onCreateIPTVServer: @escaping () -> Void,
        onDiscoverServer: @escaping () -> Void,
        onEditServer: @escaping (ServerConfig) -> Void,
        onDeleteServer: @escaping (ServerConfig) -> Void
    ) {
        self.servers = servers
        let destId = selection.id
        
        let hostingController: NSHostingController<AnyView>
        if let existing = cachedControllers[destId] as? NSHostingController<AnyView> {
            hostingController = existing
            // Do NOT rebuild the rootView for any tab. Recreating rootView causes SwiftUI to
            // potentially orphan NavigationStack-pushed views (like PersonDetailView), making them
            // stick above the window. Data updates should rely entirely on SwiftUI state bindings.
        } else {
            hostingController = NSHostingController(rootView: makeRootView(
                for: selection,
                selectionBinding: selectionBinding,
                lastServerSelection: lastServerSelection,
                onCreateServer: onCreateServer,
                onCreateIPTVServer: onCreateIPTVServer,
                onDiscoverServer: onDiscoverServer,
                onEditServer: onEditServer,
                onDeleteServer: onDeleteServer
            ))
            
            // Cache all primary views
            cachedControllers[destId] = hostingController
        }
        
        if let index = self.tabViewItems.firstIndex(where: { $0.viewController == hostingController }) {
            if self.selectedTabViewItemIndex != index {
                self.selectedTabViewItemIndex = index
            }
        } else {
            let item = NSTabViewItem(viewController: hostingController)
            self.addTabViewItem(item)
            self.selectedTabViewItemIndex = self.tabViewItems.count - 1
        }
        
        updateWindowTitle()
    }
    
    private func makeRootView(
        for selection: PlatformShellDestination,
        selectionBinding: Binding<PlatformShellDestination?>,
        lastServerSelection: Binding<PlatformShellDestination?>,
        onCreateServer: @escaping (ServerConfig.ServerType) -> Void,
        onCreateIPTVServer: @escaping () -> Void,
        onDiscoverServer: @escaping () -> Void,
        onEditServer: @escaping (ServerConfig) -> Void,
        onDeleteServer: @escaping (ServerConfig) -> Void
    ) -> AnyView {
        switch selection {
        case .servers:
            return AnyView(
                MacServersGridProxy(
                    selectionBinding: selectionBinding,
                    selection: selection,
                    onCreateServer: onCreateServer,
                    onCreateIPTVServer: onCreateIPTVServer,
                    onDiscoverServer: onDiscoverServer,
                    onEditServer: onEditServer,
                    onDeleteServer: onDeleteServer
                )
                .environmentObject(self.tabContext)
            )
        case .history:
            return AnyView(
                MacHistoryRootView(
                    onNavigateToServer: { serverId, targetFile in
                        MacNavigationManager.shared.targetFileToResolve = targetFile
                        MacNavigationManager.shared.returnTabSelection = .history
                        selectionBinding.wrappedValue = .server(serverId)
                    },
                    onNavigateToLocal: { folderURL, targetFile in
                        MacNavigationManager.shared.targetLocalFolderURL = folderURL
                        MacNavigationManager.shared.targetFileToResolve = targetFile
                        MacNavigationManager.shared.returnTabSelection = .history
                        selectionBinding.wrappedValue = .localFiles
                    }
                )
                .environmentObject(self.tabContext)
            )
        case .favorites:
            return AnyView(
                MacFavoritesRootView(
                    onNavigateToServer: { serverId, targetFile in
                        MacNavigationManager.shared.targetFileToResolve = targetFile
                        MacNavigationManager.shared.returnTabSelection = .favorites
                        selectionBinding.wrappedValue = .server(serverId)
                    },
                    onNavigateToLocal: { folderURL, targetFile in
                        MacNavigationManager.shared.targetLocalFolderURL = folderURL
                        MacNavigationManager.shared.targetFileToResolve = targetFile
                        MacNavigationManager.shared.returnTabSelection = .favorites
                        selectionBinding.wrappedValue = .localFiles
                    }
                )
                .environmentObject(self.tabContext)
            )
        case .downloads:
            return AnyView(
                MacDownloadCenterRootView { serverId, targetFile in
                    MacNavigationManager.shared.targetFileToResolve = targetFile
                    MacNavigationManager.shared.returnTabSelection = .downloads
                    selectionBinding.wrappedValue = .server(serverId)
                }
                .environmentObject(self.tabContext)
            )
        case .settings:
            return AnyView(MacSettingsRootView().environmentObject(self.tabContext))
        case .localFiles:
            return AnyView(
                MacLocalBrowserView()
                    .environmentObject(self.tabContext)
                    .ignoresSafeArea(.container, edges: .top)
            )
        case .server(let identifier):
            if let server = AppNetworkService.shared.savedServers.first(where: { $0.id == identifier }) {
                if server.type == .iptv {
                    return AnyView(
                        MacIPTVPlaylistView(server: server) {
                            DispatchQueue.main.async {
                                lastServerSelection.wrappedValue = nil
                                if let returnTab = MacNavigationManager.shared.returnTabSelection {
                                    selectionBinding.wrappedValue = returnTab
                                    MacNavigationManager.shared.returnTabSelection = nil
                                } else {
                                    selectionBinding.wrappedValue = .servers
                                }
                            }
                        }
                        .environmentObject(self.tabContext)
                        .ignoresSafeArea(.container, edges: .top)
                    )
                } else if server.type == .vod {
                    return AnyView(
                        MacVODLibraryView(server: server) {
                            DispatchQueue.main.async {
                                lastServerSelection.wrappedValue = nil
                                if let returnTab = MacNavigationManager.shared.returnTabSelection {
                                    selectionBinding.wrappedValue = returnTab
                                    MacNavigationManager.shared.returnTabSelection = nil
                                } else {
                                    selectionBinding.wrappedValue = .servers
                                }
                            }
                        }
                        .environmentObject(self.tabContext)
                        .ignoresSafeArea(.container, edges: .top)
                    )
                } else if server.type.macIsMediaLibraryServer {
                    // MacServerHubView manages its own detail navigation via state-based
                    // conditional rendering (not NavigationLink push). No outer
                    // NavigationStack is needed — adding one caused detail views to
                    // escape the NSTabViewController tab hierarchy at window level.
                    return AnyView(
                        MacServerHubView(server: server) {
                            DispatchQueue.main.async {
                                lastServerSelection.wrappedValue = nil
                                if let returnTab = MacNavigationManager.shared.returnTabSelection {
                                    selectionBinding.wrappedValue = returnTab
                                    MacNavigationManager.shared.returnTabSelection = nil
                                } else {
                                    selectionBinding.wrappedValue = .servers
                                }
                            }
                        }
                        .environmentObject(self.tabContext)
                        .ignoresSafeArea(.container, edges: .top)
                    )
                } else {
                    // MacRemoteBrowserView manages its own stack, no NavigationStack needed
                    return AnyView(
                        MacRemoteBrowserView(server: server) {
                            DispatchQueue.main.async {
                                lastServerSelection.wrappedValue = nil
                                if let returnTab = MacNavigationManager.shared.returnTabSelection {
                                    selectionBinding.wrappedValue = returnTab
                                    MacNavigationManager.shared.returnTabSelection = nil
                                } else {
                                    selectionBinding.wrappedValue = .servers
                                }
                            }
                        }
                        .environmentObject(self.tabContext)
                        .ignoresSafeArea(.container, edges: .top)
                    )
                }
            } else {
                return AnyView(
                    PlatformShellEmptyStateProxy(
                        titleKey: "Platform Shell Detail Placeholder Title",
                        bodyKey: "Platform Shell Detail Placeholder Body"
                    )
                    .environmentObject(self.tabContext)
                )
            }
        }
    }
}

struct MacServerTypePickerPopoverContent: View {
    let onSelect: (ServerConfig.ServerType) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(platformShellString("Media Servers"))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.top, 4)

                    ForEach(ServerConfig.ServerType.mediaTypes, id: \.rawValue) { serverType in
                        typeRow(for: serverType)
                    }

                    Divider()
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)

                    Text(platformShellString("File Protocols"))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)

                    ForEach(ServerConfig.ServerType.protocolTypes, id: \.rawValue) { serverType in
                        typeRow(for: serverType)
                    }

                    Divider()
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)

                    Text(platformShellString("Live TV"))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)

                    ForEach(ServerConfig.ServerType.liveTypes, id: \.rawValue) { serverType in
                        typeRow(for: serverType)
                    }

                    Divider()
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)

                    Text(platformShellString("Cloud Drives"))
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)

                    ForEach(ServerConfig.ServerType.cloudTypes, id: \.rawValue) { serverType in
                        typeRow(for: serverType)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 230, height: 380)
    }

    private func typeRow(for serverType: ServerConfig.ServerType) -> some View {
        Button {
            onSelect(serverType)
        } label: {
            HStack(spacing: 12) {
                MacServerTypeIcon(type: serverType, size: 26)
                Text(serverType.displayName)
                    .strikethrough(serverType == .googledrive)
                    .font(.body)
                    .foregroundColor(.primary)
                if serverType.isBeta {
                    Text("Beta")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MacNetworkHeaderActionsView: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @ObservedObject private var securityService = SecurityService.shared
    @Binding var showingPrivacyUnlock: Bool
    let onCreateServer: (ServerConfig.ServerType) -> Void
    let onDiscoverServer: () -> Void
    @State private var showingAddPopover = false

    private func showMoreMenu() {
        let menu = NSMenu()

        let importItem = NSMenuItem(
            title: platformShellString("Import Servers"),
            action: #selector(MacServerMenuActionBridge.invoke),
            keyEquivalent: ""
        )
        importItem.image = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)
        let importBridge = MacServerMenuActionBridge {
            MacServerBackupManager.shared.importServers()
        }
        importItem.target = importBridge
        importItem.representedObject = importBridge
        menu.addItem(importItem)

        let exportItem = NSMenuItem(
            title: platformShellString("Export Servers"),
            action: #selector(MacServerMenuActionBridge.invoke),
            keyEquivalent: ""
        )
        exportItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        let exportBridge = MacServerMenuActionBridge {
            MacServerBackupManager.shared.exportServers()
        }
        exportItem.target = exportBridge
        exportItem.representedObject = exportBridge
        menu.addItem(exportItem)

        if let event = NSApp.currentEvent {
            NSMenu.popUpContextMenu(menu, with: event, for: NSApp.keyWindow?.contentView ?? NSView())
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            MacToolbarButton(
                systemImage: "plus",
                title: platformShellString("Add Server"),
                symbolSize: 16,
                action: { showingAddPopover.toggle() }
            )
            .popover(isPresented: $showingAddPopover, arrowEdge: .bottom) {
                MacServerTypePickerPopoverContent { type in
                    showingAddPopover = false
                    onCreateServer(type)
                }
            }

            MacToolbarButton(
                systemImage: "dot.radiowaves.left.and.right",
                title: platformShellString("Discovered Servers"),
                symbolSize: 16,
                action: onDiscoverServer
            )

            if securityService.isPrivacySpaceEnabled {
                MacToolbarButton(
                    systemImage: securityService.isPrivacySpaceUnlocked ? "lock.open" : "lock",
                    title: platformShellString("Privacy Space"),
                    symbolSize: 16,
                    action: {
                        if securityService.isPrivacySpaceUnlocked {
                            securityService.lockPrivacySpace()
                        } else {
                            showingPrivacyUnlock = true
                        }
                    }
                )
            }

            MacToolbarButton(
                systemImage: "ellipsis.circle",
                title: platformShellString("More Options"),
                action: showMoreMenu
            )
        }
        .padding(4)
        .modifier(MacToolbarGlass())
    }
}

private struct MacServersGridProxy: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @EnvironmentObject private var tabContext: MacTabContext
    @Binding var selectionBinding: PlatformShellDestination?
    let selection: PlatformShellDestination
    @ObservedObject private var networkService = AppNetworkService.shared
    let onCreateServer: (ServerConfig.ServerType) -> Void
    let onCreateIPTVServer: () -> Void
    let onDiscoverServer: () -> Void
    let onEditServer: (ServerConfig) -> Void
    let onDeleteServer: (ServerConfig) -> Void

    @State private var showingAddServerTypePopover = false

    private enum MacServerGridAlertType: Identifiable {
        case connectionError
        case clearServers
        case clearIPTV
        var id: Int { hashValue }
    }

    @State private var connectingServerID: UUID? = nil
    @State private var connectionError: Error? = nil
    @State private var activeAlert: MacServerGridAlertType? = nil
    @State private var authFailedServer: ServerConfig? = nil
    @State private var connectingTask: Task<Void, Never>?
    @State private var showingPrivacyUnlockForServer: ServerConfig? = nil
    @State private var pendingPrivacyToggleServer: ServerConfig? = nil
    @State private var showingPrivacyUnlock = false
    @State private var pickingID: UUID? = nil
    @State private var activeID: UUID? = nil
    @State private var dragPreviewSize: CGSize = CGSize(width: 220, height: 120)
    @State private var sectionToClear: String? = nil
    @ObservedObject private var iptvService = IPTVService.shared
    @ObservedObject private var mediaSummaryService = MediaServerSummaryService.shared
    @ObservedObject private var backupManager = MacServerBackupManager.shared

    private var shouldHidePrivateServers: Bool {
        SecurityService.shared.isPrivacySpaceEnabled &&
        SecurityService.shared.hideLockedItems &&
        !SecurityService.shared.isPrivacySpaceUnlocked
    }

    private var regularServers: [ServerConfig] {
        networkService.savedServers.filter { $0.type != .iptv && (!shouldHidePrivateServers || !PrivacySpaceService.shared.isServerMarkedPrivate($0)) }
    }

    private var iptvServers: [ServerConfig] {
        networkService.savedServers.filter { $0.type == .iptv && (!shouldHidePrivateServers || !PrivacySpaceService.shared.isServerMarkedPrivate($0)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                MacPageHeaderView(
                    title: platformShellString("Network"),
                    trailingView: AnyView(
                        MacNetworkHeaderActionsView(
                            showingPrivacyUnlock: $showingPrivacyUnlock,
                            onCreateServer: onCreateServer,
                            onDiscoverServer: onDiscoverServer
                        )
                    )
                )
                .padding(.horizontal, 24)
                .padding(.top, 4)

                // MARK: - Section 1: Servers
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(platformShellString("Servers"))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if !regularServers.isEmpty {
                            MacGroupClearCountButton(
                                count: regularServers.count,
                                isConfirming: sectionToClear == "servers",
                                action: {
                                    if sectionToClear == "servers" {
                                        activeAlert = .clearServers
                                    } else {
                                        withAnimation {
                                            sectionToClear = "servers"
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 24)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 24)], spacing: 24) {
                        ForEach(regularServers) { server in
                            MacServerCardCell(
                                server: server,
                                isDragged: activeID == server.id,
                                isConnecting: connectingServerID == server.id || (server.type == .iptv ? iptvService.loadingServers.contains(server.id) : mediaSummaryService.loadingServers.contains(server.id)),
                                onOpen: { server in handleServerTap(server) },
                                onEdit: onEditServer,
                                onDelete: onDeleteServer,
                                privacyEnabled: SecurityService.shared.isPrivacySpaceEnabled,
                                isPrivateServer: PrivacySpaceService.shared.isServerMarkedPrivate(server),
                                onTogglePrivacy: { handleTogglePrivacy(for: server) }
                            )
                            .id(server.id)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .preference(key: ServerCardSizePreferenceKey.self, value: proxy.size)
                                }
                            )
                            .onDrag {
                                self.activeID = nil
                                self.pickingID = server.id
                                return NSItemProvider(object: server.id.uuidString as NSString)
                            } preview: {
                                MacServerCardView(
                                    server: server,
                                    isConnecting: false,
                                    isHoveredExternally: false
                                )
                                .frame(width: max(240, dragPreviewSize.width), height: max(120, dragPreviewSize.height))
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            }
                            .onDrop(of: [.plainText], delegate: MacReorderableDropDelegate(
                                item: server,
                                items: $networkService.savedServers,
                                pickingID: $pickingID,
                                activeID: $activeID,
                                onComplete: { networkService.persistServers() }
                            ))
                        }

                        Button(action: { showingAddServerTypePopover.toggle() }) {
                            MacAddServerCardView()
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showingAddServerTypePopover, arrowEdge: .bottom) {
                            MacServerTypePickerPopoverContent { type in
                                showingAddServerTypePopover = false
                                onCreateServer(type)
                            }
                        }

                        Button(action: { onDiscoverServer() }) {
                            MacDiscoverServerCardView()
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                }

                // MARK: - Section 2: IPTV
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(platformShellString("IPTV"))
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if !iptvServers.isEmpty {
                            MacGroupClearCountButton(
                                count: iptvServers.count,
                                isConfirming: sectionToClear == "iptv",
                                action: {
                                    if sectionToClear == "iptv" {
                                        activeAlert = .clearIPTV
                                    } else {
                                        withAnimation {
                                            sectionToClear = "iptv"
                                        }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 24)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 24)], spacing: 24) {
                        ForEach(iptvServers) { server in
                            MacServerCardCell(
                                server: server,
                                isDragged: activeID == server.id,
                                isConnecting: connectingServerID == server.id || (server.type == .iptv && iptvService.loadingServers.contains(server.id)),
                                onOpen: { server in handleServerTap(server) },
                                onEdit: onEditServer,
                                onDelete: onDeleteServer,
                                privacyEnabled: SecurityService.shared.isPrivacySpaceEnabled,
                                isPrivateServer: PrivacySpaceService.shared.isServerMarkedPrivate(server),
                                onTogglePrivacy: { handleTogglePrivacy(for: server) }
                            )
                            .id(server.id)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear
                                        .preference(key: ServerCardSizePreferenceKey.self, value: proxy.size)
                                }
                            )
                            .onDrag {
                                self.activeID = nil
                                self.pickingID = server.id
                                return NSItemProvider(object: server.id.uuidString as NSString)
                            } preview: {
                                MacServerCardView(
                                    server: server,
                                    isConnecting: false,
                                    isHoveredExternally: false
                                )
                                .frame(width: max(240, dragPreviewSize.width), height: max(120, dragPreviewSize.height))
                                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                            }
                            .onDrop(of: [.plainText], delegate: MacReorderableDropDelegate(
                                item: server,
                                items: $networkService.savedServers,
                                pickingID: $pickingID,
                                activeID: $activeID,
                                onComplete: { networkService.persistServers() }
                            ))
                        }

                        Button(action: onCreateIPTVServer) {
                            MacAddIPTVCardView()
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 32)
            .onPreferenceChange(ServerCardSizePreferenceKey.self) { size in
                if size.width > 0 && size.height > 0 {
                    dragPreviewSize = size
                }
            }
        }
        .onTapGesture {
            if sectionToClear != nil {
                withAnimation {
                    sectionToClear = nil
                }
            }
        }
        .sheet(item: $showingPrivacyUnlockForServer) { server in
            MacPrivacySpaceUnlockView(isPresented: Binding(
                get: { showingPrivacyUnlockForServer != nil },
                set: { if !$0 { showingPrivacyUnlockForServer = nil } }
            ))
            .onDisappear {
                if SecurityService.shared.isPrivacySpaceUnlocked {
                    if let pendingServer = pendingPrivacyToggleServer {
                        _ = PrivacySpaceService.shared.toggleServerMarkedPrivate(pendingServer)
                        pendingPrivacyToggleServer = nil
                    } else {
                        handleServerTap(server)
                    }
                } else {
                    pendingPrivacyToggleServer = nil
                }
            }
        }
        .sheet(isPresented: $showingPrivacyUnlock) {
            MacPrivacySpaceUnlockView(isPresented: $showingPrivacyUnlock)
        }
        .alert(item: $backupManager.alertItem) { item in
            Alert(
                title: Text(item.title),
                message: Text(item.message),
                dismissButton: .default(Text(platformShellString("OK")))
            )
        }
        .alert(item: $activeAlert) { alertType in
            switch alertType {
            case .connectionError:
                return Alert(
                    title: Text(platformShellString("Connection Failed")),
                    message: Text(connectionError?.localizedDescription ?? ""),
                    primaryButton: .default(Text(platformShellString("Edit Server"))) {
                        if let s = authFailedServer {
                            onEditServer(s)
                        }
                    },
                    secondaryButton: .cancel(Text(platformShellString("OK")))
                )
            case .clearServers:
                return Alert(
                    title: Text(platformShellString("Clear Servers")),
                    message: Text(platformShellString("Are you sure you want to clear all saved servers? This will also remove related history and favorites.")),
                    primaryButton: .destructive(Text(platformShellString("Clear"))) {
                        networkService.clearNonIPTVServers()
                        sectionToClear = nil
                    },
                    secondaryButton: .cancel {
                        sectionToClear = nil
                    }
                )
            case .clearIPTV:
                return Alert(
                    title: Text(platformShellString("Clear IPTV")),
                    message: Text(platformShellString("Are you sure you want to clear all IPTV playlists and channels?")),
                    primaryButton: .destructive(Text(platformShellString("Clear"))) {
                        networkService.clearServers(of: .iptv)
                        sectionToClear = nil
                    },
                    secondaryButton: .cancel {
                        sectionToClear = nil
                    }
                )
            }
        }
        .id("MacServersGridProxy_\(appLanguage)")
    }
    
    private func handleTogglePrivacy(for server: ServerConfig) {
        if PrivacySpaceService.shared.isServerMarkedPrivate(server) && !SecurityService.shared.isPrivacySpaceUnlocked {
            pendingPrivacyToggleServer = server
            showingPrivacyUnlockForServer = server
        } else {
            _ = PrivacySpaceService.shared.toggleServerMarkedPrivate(server)
        }
    }

    private func handleServerTap(_ server: ServerConfig) {
        if PrivacySpaceService.shared.isServerMarkedPrivate(server) && !SecurityService.shared.isPrivacySpaceUnlocked {
            showingPrivacyUnlockForServer = server
            return
        }

        if server.type == .iptv && iptvService.cachedPlaylist(for: server.id) != nil {
            AppNetworkService.shared.recordServerAccess(server.id)
            selectionBinding = .server(server.id)
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
                    activeAlert = .connectionError
                    AppNetworkService.shared.clearServerAuthTokens(for: server.id)
                }
            }
        }
    }
}

private struct PlatformShellEmptyStateProxy: View {
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
#endif

#if os(macOS)
private struct ServerCardSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}
#endif
