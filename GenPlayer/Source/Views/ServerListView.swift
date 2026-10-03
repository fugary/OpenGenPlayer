#if os(iOS)
import MessageUI
#endif
import SwiftUI
import AuthenticationServices
import GenPlayerShell
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

struct ServerBackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum ServerListAlertType: Identifiable {
    case delete
    case clearAll
    case clearServers
    case clearIPTV
    case connectionError
    case transfer
    var id: Int { hashValue }
}

struct ServerListView: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var discoveryService = SMBDiscoveryService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    @ObservedObject private var iptvService = IPTVService.shared
    @ObservedObject private var mediaSummaryService = MediaServerSummaryService.shared
    private struct AddServerContext: Identifiable {
        let id = UUID()
        let initialType: ServerConfig.ServerType
    }

    @State private var addServerContext: AddServerContext? = nil
    @State private var showingTVScanner = false
    @State private var pendingTVPairing: TVAuthorizationQRCode.Pairing?
    @State private var showingAddServerTypePicker = false
    @State private var isImportingServers = false
    @State private var isExportingServers = false
    @State private var serverToEdit: ServerConfig?
    @State private var serverFromDiscovery: ServerConfig?
    @State private var jellyfinServerToLogin: ServerConfig?
    @State private var embyServerToLogin: ServerConfig?
    @State private var selectedLibraryServer: ServerConfig?
    @State private var isLoggingIn = false
    @State private var serverToDelete: ServerConfig?
    @State private var pickingID: UUID?
    @State private var activeID: UUID?
    @State private var connectingServerID: UUID?
    @State private var connectionTask: Task<Void, Never>?
    @State private var pendingUnmarkPrivacy: ServerConfig?
    @State private var verifiedServer: ServerConfig?
    @State private var verificationError: Error?
    @State private var activeAlertType: ServerListAlertType?
    @State private var exportDocument = ServerBackupDocument(data: Data())
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var exportDefaultFileName = ""
    @State private var transferAlertTitle = ""
    @State private var transferAlertMessage = ""
    @State private var pendingPrivateServer: ServerConfig?
    @State private var isShowingPrivacyUnlock = false
    @State private var privacyActionMessage: String?
    @State private var showingDiscoverySheet = false
    @State private var showingAddIPTV = false
    @State private var sectionToClear: String? = nil
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        #if targetEnvironment(macCatalyst)
        return [GridItem(.adaptive(minimum: 420, maximum: 600), spacing: 24)]
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac || UIDevice.current.userInterfaceIdiom == .mac {
            return [GridItem(.adaptive(minimum: 420, maximum: 600), spacing: 24)]
        }
        if UIDevice.current.userInterfaceIdiom == .pad || horizontalSizeClass == .regular {
            return [GridItem(.adaptive(minimum: MediaCardMetrics.regularLibraryShelfMinWidth, maximum: 320), spacing: 16)]
        }
        let minimumWidth: CGFloat = verticalSizeClass == .compact
            ? MediaCardMetrics.compactLandscapeLibraryShelfMinWidth
            : 154
        return [GridItem(.adaptive(minimum: minimumWidth), spacing: 16)]
        #endif
    }

    private var shouldHidePrivateServers: Bool {
        securityService.isPrivacySpaceEnabled &&
        securityService.hideLockedItems &&
        !securityService.isPrivacySpaceUnlocked
    }

    private var visibleSavedServers: [ServerConfig] {
        networkService.savedServers.filter { server in
            !shouldHidePrivateServers || !privacySpace.isServerMarkedPrivate(server)
        }
    }

    private var visibleRegularServers: [ServerConfig] {
        networkService.savedServers.filter { server in
            server.type != .iptv && (!shouldHidePrivateServers || !privacySpace.isServerMarkedPrivate(server))
        }
    }

    private var visibleIPTVServers: [ServerConfig] {
        networkService.savedServers.filter { server in
            server.type == .iptv && (!shouldHidePrivateServers || !privacySpace.isServerMarkedPrivate(server))
        }
    }


    var body: some View {
        NavigationView {
            ZStack {
                Color(UIColor.systemGroupedBackground)
                    .ignoresSafeArea()
                

                
                ScrollView {
                    VStack(alignment: .leading, spacing: 32) {
                        
                        // MARK: - Section 1: Saved Servers (Grid)
                        VStack(alignment: .leading, spacing: 12) {
                            ServerSectionHeaderView(
                                title: NSLocalizedString("Servers", comment: ""),
                                count: visibleRegularServers.count,
                                isConfirming: sectionToClear == "servers",
                                onToggleConfirm: { sectionToClear = "servers" },
                                onClear: {
                                    activeAlertType = .clearServers
                                }
                            )
                            
                            ZStack {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onDrop(of: [UTType.plainText], delegate: BackgroundDropDelegate(pickingID: $pickingID, activeID: $activeID))
                                
                                LazyVGrid(columns: columns, spacing: 16) {
                                    if shouldHidePrivateServers {
                                        ForEach(visibleRegularServers) { server in
                                            serverCard(for: server)
                                                .id(server.id)
                                        }
                                    } else {
                                        ReorderableForEach(
                                            items: $networkService.savedServers,
                                            pickingID: $pickingID,
                                            activeID: $activeID
                                        ) { server, isDragged in
                                            if server.type != .iptv {
                                                serverCard(for: server)
                                                    .id(server.id)
                                                    .opacity(isDragged ? 0.5 : 1.0)
                                            }
                                        } preview: { server in
                                            if server.type != .iptv {
                                                serverCardDragPreview(for: server)
                                            }
                                        } onComplete: {
                                            networkService.persistServers()
                                        }
                                    }
                                    
                                    ServerActionCard(
                                        title: NSLocalizedString("Add Server", comment: ""),
                                        systemImage: "plus",
                                        action: { showingAddServerTypePicker = true }
                                    )

                                    ServerActionCard(
                                        title: NSLocalizedString("Discovered Servers", comment: ""),
                                        systemImage: "dot.radiowaves.left.and.right",
                                        action: { showingDiscoverySheet = true }
                                    )
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                        
                        // MARK: - Section 2: IPTV (Grid)
                        VStack(alignment: .leading, spacing: 12) {
                            ServerSectionHeaderView(
                                title: NSLocalizedString("IPTV", comment: ""),
                                count: visibleIPTVServers.count,
                                isConfirming: sectionToClear == "iptv",
                                onToggleConfirm: { sectionToClear = "iptv" },
                                onClear: {
                                    activeAlertType = .clearIPTV
                                }
                            )
                            
                            ZStack {
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onDrop(of: [UTType.plainText], delegate: BackgroundDropDelegate(pickingID: $pickingID, activeID: $activeID))
                                
                                LazyVGrid(columns: columns, spacing: 16) {
                                    if shouldHidePrivateServers {
                                        ForEach(visibleIPTVServers) { server in
                                            serverCard(for: server)
                                                .id(server.id)
                                        }
                                    } else {
                                        ReorderableForEach(
                                            items: $networkService.savedServers,
                                            pickingID: $pickingID,
                                            activeID: $activeID
                                        ) { server, isDragged in
                                            if server.type == .iptv {
                                                serverCard(for: server)
                                                    .id(server.id)
                                                    .opacity(isDragged ? 0.5 : 1.0)
                                            }
                                        } preview: { server in
                                            if server.type == .iptv {
                                                serverCardDragPreview(for: server)
                                            }
                                        } onComplete: {
                                            networkService.persistServers()
                                        }
                                    }
                                    
                                    ServerActionCard(
                                        title: NSLocalizedString("Add IPTV", comment: ""),
                                        systemImage: "plus",
                                        action: { showingAddIPTV = true }
                                    )
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(.top, 25)
                    .padding(.bottom, 40)
                }
                .onTapGesture {
                    if sectionToClear != nil {
                        withAnimation {
                            sectionToClear = nil
                        }
                    }
                }
                .id("ServerListView_\(appLanguage)")
                
            }
            .showTabBarCompat()
            .navigationTitle(NSLocalizedString("Network", comment: ""))
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: { showingAddServerTypePicker = true }) {
                            Label(NSLocalizedString("Add Server", comment: ""), systemImage: "plus")
                        }

                        Button(action: { showingDiscoverySheet = true }) {
                            Label(NSLocalizedString("Discovered Servers", comment: ""), systemImage: "dot.radiowaves.left.and.right")
                        }

                        Button(action: { showingTVScanner = true }) {
                            Label(NSLocalizedString("Scan QR Code", comment: ""), systemImage: "qrcode.viewfinder")
                        }
                    } label: {
                        AppToolbarIcon(systemName: "plus")
                    }

                    if securityService.isPrivacySpaceEnabled {
                        Button(action: {
                            if securityService.isPrivacySpaceUnlocked {
                                securityService.lockPrivacySpace()
                            } else {
                                isShowingPrivacyUnlock = true
                            }
                        }) {
                            AppToolbarIcon(
                                systemName: securityService.isPrivacySpaceUnlocked ? "lock.open" : "lock",
                                style: .primary
                            )
                        }
                    }

                    Menu {
                        Button(action: { isImportingServers = true }) {
                            Label(NSLocalizedString("Import Servers", comment: ""), systemImage: "square.and.arrow.down")
                        }
                        Button(action: exportServers) {
                            Label(NSLocalizedString("Export Servers", comment: ""), systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        AppToolbarIcon(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingTVScanner, onDismiss: {
                // Present the root authorization sheet only after the camera sheet has closed.
                if let pairing = pendingTVPairing {
                    pendingTVPairing = nil
                    TVPairingCompanionService.shared.presentPairing(pairing)
                }
            }) {
                TVAuthorizationScannerSheet { pairing in
                    pendingTVPairing = pairing
                    showingTVScanner = false
                }
            }
            .sheet(isPresented: $showingAddServerTypePicker) {
                ServerTypeSelectionView(
                    onSelect: { type in
                        showingAddServerTypePicker = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            openAddServer(type: type)
                        }
                    },
                    onCancel: {
                        showingAddServerTypePicker = false
                    }
                )
            }
            .sheet(item: $addServerContext) { context in
                AddServerView(networkService: networkService, existingServer: nil, prefilledServer: nil, initialType: context.initialType)
                    .id(context.id)
            }
            .sheet(isPresented: $showingAddIPTV) {
                AddServerView(networkService: networkService, existingServer: nil, prefilledServer: ServerConfig(name: "", address: "", port: nil, useSSL: false, type: .iptv))
            }
            .sheet(isPresented: $showingDiscoverySheet) {
                ServerDiscoverySheetView(discoveryService: discoveryService) { config in
                    self.serverFromDiscovery = config
                }
            }
            .sheet(item: $serverToEdit) { server in
                AddServerView(networkService: networkService, existingServer: server, prefilledServer: nil)
            }
            .sheet(item: $serverFromDiscovery) { server in
                AddServerView(networkService: networkService, existingServer: nil, prefilledServer: server)
            }
            .sheet(item: $jellyfinServerToLogin) { server in
                JellyfinLoginView(server: server, networkService: networkService)
            }
            .sheet(item: $embyServerToLogin) { server in
                EmbyLoginView(server: server, networkService: networkService)
            }
            .fullScreenCover(item: $selectedLibraryServer) { server in
                NavigationView {
                    if server.type == .jellyfin {
                        JellyfinLibraryView(server: server, networkService: networkService, onExit: {
                            selectedLibraryServer = nil
                        })
                    } else if server.type == .emby {
                        EmbyLibraryView(server: server, networkService: networkService, onExit: {
                            selectedLibraryServer = nil
                        })
                    } else if server.type == .plex {
                        PlexLibraryView(server: server, networkService: networkService, onExit: {
                            selectedLibraryServer = nil
                        })
                    } else if server.type == .iptv {
                        IPTVPlaylistView(server: server, onExit: {
                            selectedLibraryServer = nil
                        })
                    } else if server.type == .vod {
                        VODLibraryView(server: server, onExit: {
                            selectedLibraryServer = nil
                        })
                    } else {
                        RemoteFileListView(server: server, networkService: networkService, onExit: {
                            selectedLibraryServer = nil
                        })
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
            .sheet(isPresented: $isShowingPrivacyUnlock, onDismiss: {
                if securityService.isPrivacySpaceUnlocked {
                    if let server = pendingUnmarkPrivacy {
                        _ = privacySpace.toggleServerMarkedPrivate(server)
                        pendingUnmarkPrivacy = nil
                    } else if let server = pendingPrivateServer {
                        pendingPrivateServer = nil
                        connectAndOpen(server)
                    }
                } else {
                    pendingUnmarkPrivacy = nil
                    pendingPrivateServer = nil
                }
            }) {
                PrivacySpaceUnlockView(
                    isPresented: $isShowingPrivacyUnlock,
                    title: pendingPrivateServer?.name ?? pendingUnmarkPrivacy?.name ?? NSLocalizedString("Privacy Space", comment: "")
                )
            }
            .fileImporter(
                isPresented: $isImportingServers,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                importServers(from: result)
            }
            .fileExporter(
                isPresented: $isExportingServers,
                document: exportDocument,
                contentType: .json,
                defaultFilename: exportDefaultFileName
            ) { result in
                handleServerExport(result)
            }
            .alert(item: $activeAlertType) { alertType in
                switch alertType {
                case .connectionError:
                    return Alert(
                        title: Text(NSLocalizedString("Connection Failed", comment: "")),
                        message: Text(verificationError?.localizedDescription ?? NSLocalizedString("Unknown Error", comment: "")),
                        primaryButton: .default(Text(NSLocalizedString("Edit Server", comment: ""))) {
                            if let server = verifiedServer {
                                serverToEdit = server
                            }
                        },
                        secondaryButton: .cancel(Text(NSLocalizedString("OK", comment: "")))
                    )
                case .delete:
                    if let server = serverToDelete {
                        return Alert(
                            title: Text(NSLocalizedString("Delete Server", comment: "")),
                            message: Text(String(format: NSLocalizedString("Are you sure you want to delete \"%@\"?", comment: ""), server.name)),
                            primaryButton: .destructive(Text(NSLocalizedString("Delete", comment: ""))) {
                                networkService.deleteServer(server)
                            },
                            secondaryButton: .cancel()
                        )
                    } else {
                        return Alert(title: Text(NSLocalizedString("Error", comment: "")))
                    }
                case .clearAll, .clearServers:
                    return Alert(
                        title: Text(NSLocalizedString("Clear Servers", comment: "")),
                        message: Text(NSLocalizedString("Are you sure you want to clear all saved servers? This will also remove related history and favorites.", comment: "")),
                        primaryButton: .destructive(Text(NSLocalizedString("Clear", comment: ""))) {
                            networkService.clearNonIPTVServers()
                            sectionToClear = nil
                        },
                        secondaryButton: .cancel {
                            sectionToClear = nil
                        }
                    )
                case .clearIPTV:
                    return Alert(
                        title: Text(NSLocalizedString("Clear IPTV", comment: "")),
                        message: Text(NSLocalizedString("Are you sure you want to clear all IPTV playlists and channels?", comment: "")),
                        primaryButton: .destructive(Text(NSLocalizedString("Clear", comment: ""))) {
                            networkService.clearServers(of: .iptv)
                            sectionToClear = nil
                        },
                        secondaryButton: .cancel {
                            sectionToClear = nil
                        }
                    )
                case .transfer:
                    return Alert(
                        title: Text(transferAlertTitle),
                        message: Text(transferAlertMessage),
                        dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
                    )
                }
            }
            .appErrorAlert(
                message: $privacyActionMessage,
                title: NSLocalizedString("Privacy Space", comment: "")
            )
            .onDisappear {
                discoveryService.stopDiscovery()
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("EditServer"))) { notification in
                if let server = notification.object as? ServerConfig {
                    serverToEdit = server
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .init("DeleteServer"))) { notification in
                if let server = notification.object as? ServerConfig {
                    // key: Delay to allow Menu to dismiss fully before showing Alert
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        serverToDelete = server
                        activeAlertType = .delete
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func openAddServer(type: ServerConfig.ServerType) {
        addServerContext = AddServerContext(initialType: type)
    }
    
    private var dragPreviewWidth: CGFloat {
        #if targetEnvironment(macCatalyst)
        return 440
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac || UIDevice.current.userInterfaceIdiom == .mac {
            return 440
        }
        if UIDevice.current.userInterfaceIdiom == .pad || horizontalSizeClass == .regular {
            return 240
        }
        let isLandscape = verticalSizeClass == .compact
        if isLandscape {
            return 220
        }
        return 170
        #endif
    }

    @ViewBuilder
    private func serverCardDragPreview(for server: ServerConfig) -> some View {
        ServerCardView(
            server: server,
            isConnecting: false,
            showsPrivacyBadge: securityService.isPrivacySpaceEnabled && privacySpace.isServerMarkedPrivate(server),
            privacyBadgeSystemName: securityService.isPrivacySpaceUnlocked ? "lock.open" : "lock"
        )
        .frame(width: dragPreviewWidth)
    }

    @ViewBuilder
    private func serverCard(for server: ServerConfig) -> some View {
        ZStack(alignment: .topTrailing) {
            Button(action: {
                if connectingServerID == server.id {
                    // Tap again to cancel
                    cancelConnection()
                } else {
                    handleServerAccess(server)
                }
            }) {
                ServerCardView(
                    server: server,
                    isConnecting: connectingServerID == server.id || (server.type == .iptv ? iptvService.loadingServers.contains(server.id) : mediaSummaryService.loadingServers.contains(server.id)),
                    showsPrivacyBadge: securityService.isPrivacySpaceEnabled && privacySpace.isServerMarkedPrivate(server),
                    privacyBadgeSystemName: securityService.isPrivacySpaceUnlocked ? "lock.open" : "lock"
                )
            }
            .buttonStyle(PlainButtonStyle())
            .contextMenu {
                serverCardMenu(for: server)
            }

            Menu {
                serverCardMenu(for: server)
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.black.opacity(0.3))

                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(.white)
                }
                .frame(width: 28, height: 28)
                .contentShape(Circle())
            }
            .buttonStyle(PlainButtonStyle())
            .padding(12)
        }
        .onAppear {
            refreshVODSummaryIfNeeded(for: server)
        }
        .onChange(of: server.vodSources) { _ in refreshVODSummaryIfNeeded(for: server) }
    }

    /// VOD does not have the push-style summary updates used by Jellyfin/Emby/Plex.
    /// Populate its card from the same paged list response used by the library on first display.
    private func refreshVODSummaryIfNeeded(for server: ServerConfig) {
        guard server.type == .vod else { return }
        Task { await server.refreshMobileVODSummaries() }
    }

    @ViewBuilder
    private func serverCardMenu(for server: ServerConfig) -> some View {
        Button(action: {
            handleServerAccess(server)
        }) {
            Label(NSLocalizedString("Open", comment: ""), systemImage: server.type == .iptv ? "play.circle" : "arrow.right.circle")
        }
        if server.type == .iptv {
            Button(action: {
                Task {
                    _ = try? await IPTVService.shared.fetchPlaylist(for: server, forceRefresh: true)
                }
            }) {
                Label(NSLocalizedString("Refresh Playlist", comment: ""), systemImage: "arrow.clockwise")
            }
            
            Button(action: {
                UIPasteboard.general.string = server.address
            }) {
                Label(NSLocalizedString("Copy Playlist URL", comment: ""), systemImage: "doc.on.doc")
            }
        } else if server.type.isMediaServer {
            Button(action: {
                Task {
                    if server.type == .vod { await server.refreshMobileVODSummaries(onlyMissing: false) }
                    else { await MediaServerSummaryService.shared.refreshSummary(for: server) }
                }
            }) {
                Label(NSLocalizedString("Refresh Library", comment: ""), systemImage: "arrow.clockwise")
            }
        }
        Button(action: {
            NotificationCenter.default.post(name: .init("EditServer"), object: server)
        }) {
            Label(NSLocalizedString("Edit", comment: ""), systemImage: "pencil")
        }
        if securityService.isPrivacySpaceEnabled {
            Button(action: {
                toggleServerPrivacy(server)
            }) {
                Label(
                    privacySpace.isServerMarkedPrivate(server)
                        ? NSLocalizedString("Remove from Privacy Space", comment: "")
                        : NSLocalizedString("Add to Privacy Space", comment: ""),
                    systemImage: privacySpace.isServerMarkedPrivate(server) ? "lock.open" : "lock"
                )
            }
        }
        if #available(iOS 15.0, *) {
            Button(role: .destructive, action: {
                NotificationCenter.default.post(name: .init("DeleteServer"), object: server)
            }) {
                Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
            }
        } else {
            Button(action: {
                NotificationCenter.default.post(name: .init("DeleteServer"), object: server)
            }) {
                Label {
                    Text(NSLocalizedString("Delete", comment: ""))
                        .foregroundColor(.red)
                } icon: {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
            }
        }
    }

    private func handleServerAccess(_ server: ServerConfig) {
        guard securityService.isPrivacySpaceEnabled,
              !securityService.isPrivacySpaceUnlocked,
              privacySpace.isServerMarkedPrivate(server) else {
            connectAndOpen(server)
            return
        }

        pendingPrivateServer = server
        isShowingPrivacyUnlock = true
    }

    private func toggleServerPrivacy(_ server: ServerConfig) {
        guard securityService.hasPrivacyPassword else {
            privacyActionMessage = NSLocalizedString("Set up Privacy Space in Settings before locking items.", comment: "")
            return
        }

        if privacySpace.isServerMarkedPrivate(server) && !securityService.isPrivacySpaceUnlocked {
            pendingUnmarkPrivacy = server
            isShowingPrivacyUnlock = true
        } else {
            _ = privacySpace.toggleServerMarkedPrivate(server)
        }
    }
    
    // MARK: - Connection Verification
    
    private func connectAndOpen(_ server: ServerConfig) {
        // For IPTV with cached playlist, open immediately without blocking network test
        if server.type == .iptv && iptvService.cachedPlaylist(for: server.id) != nil {
            networkService.recordServerAccess(server.id)
            verifiedServer = server
            selectedLibraryServer = server
            return
        }
        
        // Cancel any existing task first
        connectionTask?.cancel()
        
        connectingServerID = server.id
        verifiedServer = server
        
        connectionTask = Task {
            do {
                let updatedServer = try await withThrowingTaskGroup(of: ServerConfig.self) { group in
                    group.addTask {
                        return try await networkService.testConnection(server)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        throw NSError(domain: "GenPlayer", code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Connection timed out", comment: "")])
                    }
                    if let result = try await group.next() {
                        group.cancelAll()
                        return result
                    } else {
                        throw CancellationError()
                    }
                }
                
                if !Task.isCancelled {
                    await MainActor.run {
                        connectingServerID = nil
                        networkService.recordServerAccess(server.id)
                        if updatedServer.type == .jellyfin || updatedServer.type == .emby || updatedServer.type == .plex {
                            selectedLibraryServer = updatedServer
                        } else {
                            verifiedServer = updatedServer
                            selectedLibraryServer = updatedServer
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        connectingServerID = nil
                        verificationError = error
                        activeAlertType = .connectionError
                    }
                }
            }
        }
    }
    
    private func cancelConnection() {
        connectionTask?.cancel()
        connectionTask = nil
        connectingServerID = nil
    }

    private func presentClearAllServersConfirmation() {
        guard !networkService.savedServers.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            activeAlertType = .clearAll
        }
    }

    private func clearAllServers() {
        cancelConnection()
        serverToDelete = nil
        verifiedServer = nil
        networkService.clearAllServers()
    }

    private func exportServers() {
        guard !networkService.savedServers.isEmpty else {
            presentTransferAlert(
                title: NSLocalizedString("Server Backup", comment: ""),
                message: NSLocalizedString("There are no saved servers to export.", comment: "")
            )
            return
        }

        do {
            let data = try networkService.exportServerBackupData()
            exportDocument = ServerBackupDocument(data: data)
            exportDefaultFileName = makeServerBackupFileName()
            DispatchQueue.main.async {
                isExportingServers = true
            }
        } catch {
            presentTransferAlert(
                title: NSLocalizedString("Server Backup", comment: ""),
                message: error.localizedDescription
            )
        }
    }

    private func importServers(from result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let fileURL = urls.first else { return }
            let hasScopedAccess = fileURL.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess {
                    fileURL.stopAccessingSecurityScopedResource()
                }
            }

            do {
                let data = try Data(contentsOf: fileURL)
                let importResult = try networkService.importServers(from: data)
                presentTransferAlert(
                    title: NSLocalizedString("Server Backup", comment: ""),
                    message: importSummaryMessage(for: importResult)
                )
            } catch {
                presentTransferAlert(
                    title: NSLocalizedString("Server Backup", comment: ""),
                    message: error.localizedDescription
                )
            }
        case .failure(let error):
            presentTransferAlert(
                title: NSLocalizedString("Server Backup", comment: ""),
                message: error.localizedDescription
            )
        }
    }

    private func importSummaryMessage(for result: ServerImportResult) -> String {
        if result.importedCount > 0 && result.skippedCount > 0 {
            return String(
                format: NSLocalizedString("Imported %1$d servers. Skipped %2$d duplicate servers.", comment: ""),
                result.importedCount,
                result.skippedCount
            )
        }

        if result.importedCount > 0 {
            return String(
                format: NSLocalizedString("Imported %d servers.", comment: ""),
                result.importedCount
            )
        }

        if result.skippedCount > 0 {
            return String(
                format: NSLocalizedString("No new servers were imported. %d duplicates were skipped.", comment: ""),
                result.skippedCount
            )
        }

        return NSLocalizedString("No new servers were imported.", comment: "")
    }

    private func handleServerExport(_ result: Result<URL, Error>) {
        if case .failure(let error) = result {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                return
            }

            presentTransferAlert(
                title: NSLocalizedString("Server Backup", comment: ""),
                message: error.localizedDescription
            )
        }
    }

    private func makeServerBackupFileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "GenPlayer-Servers-\(formatter.string(from: Date()))"
    }

    private func presentTransferAlert(title: String, message: String) {
        transferAlertTitle = title
        transferAlertMessage = message
        activeAlertType = .transfer
    }
}

// MARK: - Subviews

struct ServerCardView: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    let server: ServerConfig
    var isConnecting: Bool = false
    var showsPrivacyBadge: Bool = false
    var privacyBadgeSystemName: String = "lock"
    private let topTrailingAccessoryWidth: CGFloat = 44
    
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
            return [Color(red: 0.00, green: 0.70, blue: 0.85), Color(red: 0.00, green: 0.42, blue: 0.61)]
        case .pan115:
            return [Color(red: 0.20, green: 0.40, blue: 0.95), Color(red: 0.10, green: 0.18, blue: 0.60)]
        case .onedrive:
            return [Color(red: 0.00, green: 0.47, blue: 0.83), Color(red: 0.04, green: 0.26, blue: 0.52)]
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
        GeometryReader { geo in
            let isCompactCard = geo.size.width < 170
            let horizontalPadding: CGFloat = isCompactCard ? 12 : 14
            let topPadding: CGFloat = isCompactCard ? 9 : 10
            let bottomPadding: CGFloat = isCompactCard ? 8 : 9
            let badgeFontSize: CGFloat = isCompactCard ? 9.5 : 10
            let typeIconSize: CGFloat = isCompactCard ? 22 : 25
            let backgroundArtSize: CGFloat = isCompactCard ? 70 : 82
            let titleFontSize: CGFloat = isCompactCard ? 14 : 15
            let subtitleFontSize: CGFloat = isCompactCard ? 10.5 : 11
            let typeRowSpacing: CGFloat = isCompactCard ? 5 : 6
            let reservedMenuWidth: CGFloat = isCompactCard ? 36 : topTrailingAccessoryWidth

            ZStack {
                LinearGradient(gradient: Gradient(colors: gradientColors), startPoint: .topLeading, endPoint: .bottomTrailing)

                ZStack(alignment: .bottomTrailing) {
                    Color.clear
                    if let uiImage = UIImage(named: server.type.iconAssetName) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .renderingMode(.template)
                            .aspectRatio(contentMode: .fit)
                            .frame(width: backgroundArtSize, height: backgroundArtSize)
                            .foregroundColor(.black.opacity(0.1))
                            .rotationEffect(.degrees(-20))
                            .offset(x: 20, y: 20)
                    } else {
                        Image(systemName: server.type.systemIconName)
                            .font(.system(size: isCompactCard ? 66 : 80))
                            .foregroundColor(.black.opacity(0.1))
                            .rotationEffect(.degrees(-20))
                            .offset(x: 20, y: 20)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                VStack(alignment: .leading, spacing: 0) {
                    // Header: Type Icon + Type Pill Badge
                    HStack(alignment: .center, spacing: 10) {
                        HStack(spacing: typeRowSpacing) {
                            typeIcon(size: typeIconSize)

                            Text(server.type.displayName)
                                .font(.system(size: badgeFontSize, weight: .bold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                                .foregroundColor(.white.opacity(0.95))
                                .padding(.horizontal, isCompactCard ? 6.5 : 7.5)
                                .padding(.vertical, isCompactCard ? 2 : 2.5)
                                .background(Color.black.opacity(0.22))
                                .clipShape(Capsule())
                        }

                        Spacer(minLength: 0)

                        Color.clear
                            .frame(width: reservedMenuWidth, height: 1)
                    }

                    if hasThirdLine {
                        Spacer(minLength: 2)
                            .frame(maxHeight: isCompactCard ? 5 : 7)

                        // Footer: Server Name, Address, Summary Stats
                        VStack(alignment: .leading, spacing: isCompactCard ? 1.5 : 2) {
                            Text(server.name)
                                .font(.system(size: titleFontSize, weight: .bold))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .shadow(color: .black.opacity(0.12), radius: 2, x: 0, y: 1)

                            Text(server.address.isEmpty ? server.type.displayName : server.address)
                                .font(.system(size: subtitleFontSize, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                                .lineLimit(1)

                            if server.type == .iptv {
                                if let summary = IPTVService.shared.summary(for: server.id) {
                                    HStack(spacing: isCompactCard ? 5 : 7) {
                                        HStack(spacing: 2.5) {
                                            Image(systemName: "rectangle.stack")
                                            Text("\(summary.groupCount)")
                                        }
                                        HStack(spacing: 2.5) {
                                            Image(systemName: "tv")
                                            Text(NumberFormatter.localizedString(from: NSNumber(value: summary.channelCount), number: .decimal))
                                        }
                                        HStack(spacing: 2.5) {
                                            Image(systemName: "clock")
                                            Text(IPTVService.shared.formatLastUpdated(summary.lastUpdated))
                                        }
                                    }
                                    .font(.system(size: isCompactCard ? 9.5 : 10.5, weight: .medium))
                                    .foregroundColor(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .padding(.top, 1)
                                } else {
                                    Text(NSLocalizedString("Not loaded yet", comment: ""))
                                        .font(.system(size: isCompactCard ? 9.5 : 10.5))
                                        .foregroundColor(.white.opacity(0.72))
                                        .lineLimit(1)
                                        .padding(.top, 1)
                                }
                            } else if let mediaSummary = server.mobileMediaSummary {
                                HStack(spacing: isCompactCard ? 5 : 7) {
                                    if mediaSummary.movieCount > 0 || mediaSummary.seriesCount > 0 {
                                        if mediaSummary.movieCount > 0 {
                                            HStack(spacing: 2.5) {
                                                Image(systemName: "film")
                                                Text(NumberFormatter.localizedString(from: NSNumber(value: mediaSummary.movieCount), number: .decimal))
                                            }
                                        }
                                        if mediaSummary.seriesCount > 0 {
                                            HStack(spacing: 2.5) {
                                                Image(systemName: "tv")
                                                Text(NumberFormatter.localizedString(from: NSNumber(value: mediaSummary.seriesCount), number: .decimal))
                                            }
                                        }
                                    } else {
                                        HStack(spacing: 2.5) {
                                            Image(systemName: "square.stack.3d.up")
                                            Text(NumberFormatter.localizedString(from: NSNumber(value: mediaSummary.libraryCount), number: .decimal))
                                        }
                                    }
                                    if server.type == .vod, let sources = server.vodSources, sources.count > 1 {
                                        Text(String(format: platformShellString("VOD Source Count %d"), sources.count))
                                    }
                                    HStack(spacing: 2.5) {
                                        Image(systemName: "clock")
                                        Text(MediaServerSummaryService.shared.formatLastUpdated(mediaSummary.lastUpdated))
                                    }
                                }
                                .font(.system(size: isCompactCard ? 9.5 : 10.5, weight: .medium))
                                .foregroundColor(.white.opacity(0.92))
                                .lineLimit(1)
                                .padding(.top, 1)
                            } else if server.type.isMediaServer {
                                Text(NSLocalizedString("Not loaded yet", comment: ""))
                                    .font(.system(size: isCompactCard ? 9.5 : 10.5))
                                    .foregroundColor(.white.opacity(0.72))
                                    .lineLimit(1)
                                    .padding(.top, 1)
                            } else {
                                if let lastAccessed = server.lastAccessed {
                                    HStack(spacing: 2.5) {
                                        Image(systemName: "clock")
                                        Text(MediaServerSummaryService.shared.formatLastUpdated(lastAccessed))
                                    }
                                    .font(.system(size: isCompactCard ? 9.5 : 10.5, weight: .medium))
                                    .foregroundColor(.white.opacity(0.92))
                                    .lineLimit(1)
                                    .padding(.top, 1)
                                } else {
                                    Text(NSLocalizedString("Not accessed yet", comment: ""))
                                        .font(.system(size: isCompactCard ? 9.5 : 10.5))
                                        .foregroundColor(.white.opacity(0.72))
                                        .lineLimit(1)
                                        .padding(.top, 1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, showsPrivacyBadge ? (isCompactCard ? 26 : 30) : 0)

                        Spacer(minLength: 2)
                    }
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.top, topPadding)
                .padding(.bottom, bottomPadding)

                if showsPrivacyBadge {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.3))

                        Image(systemName: privacyBadgeSystemName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
                    .padding(.bottom, bottomPadding)
                    .padding(.trailing, horizontalPadding - 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }

                // Inline loading overlay
                if isConnecting {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.black.opacity(0.5))

                    VStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(1.2)
                        Text(NSLocalizedString("Connecting...", comment: ""))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                        Text(NSLocalizedString("Tap to cancel", comment: ""))
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }
        }
        .frame(height: {
            #if targetEnvironment(macCatalyst)
            return CGFloat(138)
            #else
            if ProcessInfo.processInfo.isiOSAppOnMac || UIDevice.current.userInterfaceIdiom == .mac {
                return CGFloat(138)
            }
            if UIDevice.current.userInterfaceIdiom == .pad {
                return CGFloat(120)
            }
            return CGFloat(108)
            #endif
        }())
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 5)
    }

    @ViewBuilder
    private func typeIcon(size: CGFloat) -> some View {
        if let uiImage = UIImage(named: server.type.iconAssetName) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: server.type.systemIconName)
                .font(.system(size: max(size * 0.85, 14), weight: .semibold))
                .foregroundColor(.white)
                .frame(width: size, height: size)
        }
    }
}

struct DiscoveredServerRow: View {
    let server: SMBDiscoveryService.DiscoveredServer

    private var typeTitle: String {
        switch server.type {
        case .smb: return "SMB"
        case .webdav: return server.useSSL ? "WebDAV (HTTPS)" : "WebDAV"
        case .alist: return "AList"
        case .pan115: return "115"
        case .onedrive: return "OneDrive"
        case .googledrive: return "Google Drive"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        case .nfs: return "NFS"
        case .jellyfin: return "Jellyfin"
        case .emby: return "Emby"
        case .plex: return "Plex"
        case .iptv: return "IPTV"
        case .vod: return "Web VOD"
        }
    }

    private var iconName: String {
        switch server.type {
        case .smb: return "server.rack"
        case .webdav: return "globe"
        case .alist: return "externaldrive.badge.icloud"
        case .pan115: return "icloud.fill"
        case .onedrive: return "cloud.fill"
        case .googledrive: return "externaldrive.badge.icloud"
        case .ftp: return "network"
        case .sftp: return "lock.shield"
        case .nfs: return "externaldrive.connected.to.line.below"
        case .jellyfin: return "play.tv.fill"
        case .emby: return "leaf.fill"
        case .plex: return "play.square.fill"
        case .iptv: return "play.tv.fill"
        case .vod: return "film.stack"
        }
    }

    private var iconAssetName: String {
        server.type.iconAssetName
    }

    private var iconTint: Color {
        switch server.type {
        case .smb:
            return Color(red: 0.30, green: 0.53, blue: 0.93)
        case .webdav:
            return Color(red: 0.11, green: 0.60, blue: 0.90)
        case .alist:
            return Color(red: 0.00, green: 0.70, blue: 0.85)
        case .pan115:
            return Color(red: 0.20, green: 0.40, blue: 0.95)
        case .onedrive:
            return Color(red: 0.00, green: 0.47, blue: 0.83)
        case .googledrive:
            return Color(red: 0.96, green: 0.70, blue: 0.12)
        case .ftp:
            return Color(red: 0.83, green: 0.48, blue: 0.41)
        case .sftp:
            return Color(red: 0.33, green: 0.68, blue: 0.71)
        case .nfs:
            return Color(red: 0.51, green: 0.63, blue: 0.80)
        case .jellyfin:
            return Color(red: 0.56, green: 0.37, blue: 0.91)
        case .emby:
            return Color(red: 0.24, green: 0.69, blue: 0.36)
        case .plex:
            return Color(red: 0.96, green: 0.64, blue: 0.17)
        case .iptv:
            return Color(red: 0.38, green: 0.34, blue: 0.88)
        case .vod:
            return Color(red: 0.18, green: 0.52, blue: 0.92)
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(iconTint.opacity(0.14))
                    .frame(width: 36, height: 36)
                if let uiImage = UIImage(named: iconAssetName) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .renderingMode(.original)
                        .scaledToFit()
                        .frame(width: 20, height: 20)
                } else {
                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconTint)
                }
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(typeTitle + " · " + server.address)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Spacer()
            
            Image(systemName: "plus.circle.fill")
                .foregroundColor(.accentColor)
                .font(.system(size: 20, weight: .semibold))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct ServerActionCard: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    let title: String
    let systemImage: String
    var action: (() -> Void)? = nil
    
    private var cardHeight: CGFloat {
        #if targetEnvironment(macCatalyst)
        return 138
        #else
        if ProcessInfo.processInfo.isiOSAppOnMac || UIDevice.current.userInterfaceIdiom == .mac {
            return 138
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            return 120
        }
        return 108
        #endif
    }

    private var cardContent: some View {
        VStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .medium))
                .foregroundColor(.accentColor)
            
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(Color(UIColor.label))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .frame(height: cardHeight)
        .background(Color(UIColor.secondarySystemGroupedBackground).opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.accentColor.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [5]))
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .contentShape(Rectangle())
    }
    
    var body: some View {
        if let action = action {
            Button(action: action) {
                cardContent
            }
            .buttonStyle(PlainButtonStyle())
        } else {
            cardContent
        }
    }
}

struct ServerDiscoverySheetView: View {
    @ObservedObject var discoveryService: SMBDiscoveryService
    let onSelectServer: (ServerConfig) -> Void
    @Environment(\.presentationMode) private var presentationMode
    
    var body: some View {
        NavigationView {
            Group {
                if discoveryService.discoveredServers.isEmpty {
                    VStack(spacing: 16) {
                        if discoveryService.isSearching {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text(NSLocalizedString("Searching...", comment: ""))
                                .foregroundColor(.secondary)
                        } else {
                            Image(systemName: "dot.radiowaves.left.and.right")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary.opacity(0.3))
                            Text(NSLocalizedString("No local servers found", comment: ""))
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Button(action: { discoveryService.startDiscovery() }) {
                                Text(NSLocalizedString("Retry", comment: ""))
                                    .fontWeight(.medium)
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 8)
                                    .background(Color.accentColor)
                                    .foregroundColor(.white)
                                    .cornerRadius(16)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(discoveryService.discoveredServers) { server in
                            Button(action: {
                                let config = discoveryService.createServerConfig(from: server)
                                presentationMode.wrappedValue.dismiss()
                                onSelectServer(config)
                            }) {
                                DiscoveredServerRow(server: server)
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .listStyle(InsetGroupedListStyle())
                }
            }
            .navigationTitle(NSLocalizedString("Discovered Servers", comment: ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        presentationMode.wrappedValue.dismiss()
                    }) {
                        AppToolbarIcon(systemName: "xmark", style: .secondary)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if discoveryService.isSearching {
                        ProgressView()
                            .scaleEffect(0.8)
                    } else {
                        Button(action: { discoveryService.startDiscovery() }) {
                            AppToolbarIcon(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
        }
        .onAppear {
            discoveryService.startDiscovery()
        }
        .onDisappear {
            discoveryService.stopDiscovery()
        }
    }
}



struct ServerTypeIconBadge: View {
    let type: ServerConfig.ServerType
    var size: CGFloat = 36
    var iconSize: CGFloat = 18

    private func icon(for type: ServerConfig.ServerType) -> String {
        switch type {
        case .smb: return "externaldrive.fill"
        case .webdav: return "externaldrive.badge.icloud"
        case .ftp: return "network"
        case .sftp: return "lock.shield"
        case .nfs: return "externaldrive.connected.to.line.below"
        case .jellyfin: return "play.tv.fill"
        case .emby: return "play.rectangle.fill"
        case .plex: return "play.square.fill"
        case .alist: return "externaldrive.badge.icloud"
        case .pan115: return "icloud.fill"
        case .onedrive: return "cloud.fill"
        case .googledrive: return "externaldrive.badge.icloud"
        case .iptv: return "play.tv.fill"
        case .vod: return "film.stack"
        }
    }

    private func iconAssetName(for type: ServerConfig.ServerType) -> String {
        return type.iconAssetName
    }

    private func tint(for type: ServerConfig.ServerType) -> Color {
        switch type {
        case .smb:
            return Color(red: 0.30, green: 0.53, blue: 0.93)
        case .webdav:
            return Color(red: 0.11, green: 0.60, blue: 0.90)
        case .ftp:
            return Color(red: 0.83, green: 0.48, blue: 0.41)
        case .sftp:
            return Color(red: 0.33, green: 0.68, blue: 0.71)
        case .nfs:
            return Color(red: 0.51, green: 0.63, blue: 0.80)
        case .jellyfin:
            return Color(red: 0.56, green: 0.37, blue: 0.91)
        case .emby:
            return Color(red: 0.24, green: 0.69, blue: 0.36)
        case .plex:
            return Color(red: 0.96, green: 0.64, blue: 0.17)
        case .alist:
            return Color(red: 0.0, green: 0.70, blue: 0.85)
        case .pan115:
            return Color(red: 0.20, green: 0.40, blue: 0.95)
        case .onedrive:
            return Color(red: 0.0, green: 0.47, blue: 0.83)
        case .googledrive:
            return Color(red: 0.96, green: 0.70, blue: 0.12)
        case .iptv:
            return Color(red: 0.38, green: 0.34, blue: 0.88)
        case .vod:
            return Color(red: 0.18, green: 0.52, blue: 0.92)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28)
                .fill(tint(for: type).opacity(0.16))
                .frame(width: size, height: size)

            if let uiImage = UIImage(named: iconAssetName(for: type)) {
                Image(uiImage: uiImage)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
            } else {
                Image(systemName: icon(for: type))
                    .font(.system(size: iconSize * 0.9, weight: .semibold))
                    .foregroundColor(tint(for: type))
            }
        }
    }
}

struct ServerTypeSelectionView: View {
    let onSelect: (ServerConfig.ServerType) -> Void
    var onCancel: (() -> Void)? = nil

    private var cloudTypes: [ServerConfig.ServerType] { ServerConfig.ServerType.cloudTypes }
    private var protocolTypes: [ServerConfig.ServerType] { ServerConfig.ServerType.protocolTypes.filter { !ServerConfig.ServerType.cloudTypes.contains($0) } }
    private var mediaTypes: [ServerConfig.ServerType] { ServerConfig.ServerType.mediaTypes }
    private var liveTypes: [ServerConfig.ServerType] { ServerConfig.ServerType.liveTypes }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text(NSLocalizedString("Media Servers", comment: ""))) {
                    ForEach(mediaTypes, id: \.self) { type in
                        typeRow(for: type)
                    }
                }

                Section(header: Text(NSLocalizedString("File Protocols", comment: ""))) {
                    ForEach(protocolTypes, id: \.self) { type in
                        typeRow(for: type)
                    }
                }

                Section(header: Text(NSLocalizedString("Live TV", comment: ""))) {
                    ForEach(liveTypes, id: \.self) { type in
                        typeRow(for: type)
                    }
                }

                Section(header: Text(NSLocalizedString("Cloud Drives", comment: ""))) {
                    ForEach(cloudTypes, id: \.self) { type in
                        typeRow(for: type)
                    }
                }
            }
            .listStyle(InsetGroupedListStyle())
            .navigationTitle(NSLocalizedString("Choose Server Type", comment: ""))
            .navigationBarItems(
                leading: Button(NSLocalizedString("Cancel", comment: "")) {
                    onCancel?()
                }
            )
        }
        .navigationViewStyle(.stack)
    }

    private func typeRow(for type: ServerConfig.ServerType) -> some View {
        Button(action: {
            onSelect(type)
        }) {
            HStack(spacing: 14) {
                ServerTypeIconBadge(type: type, size: 34, iconSize: 18)

                Text(type.displayName)
                    .strikethrough(type == .googledrive)
                    .font(.body.weight(.medium))
                    .foregroundColor(.primary)

                if type.isBeta {
                    Text("Beta")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

private struct ServerTypeSelector: View {
    @Binding var selectedType: ServerConfig.ServerType
    @State private var showingPicker = false
    @State private var requestedServiceType = ""
    @State private var feedbackMailDraft: FeedbackDraft?
    @State private var feedbackAlert: ServiceRequestAlert?

    private var cloudTypes: [ServerConfig.ServerType] { ServerConfig.ServerType.cloudTypes }
    private var protocolTypes: [ServerConfig.ServerType] { ServerConfig.ServerType.protocolTypes.filter { !ServerConfig.ServerType.cloudTypes.contains($0) } }
    private var mediaTypes: [ServerConfig.ServerType] { ServerConfig.ServerType.mediaTypes }
    private var liveTypes: [ServerConfig.ServerType] { ServerConfig.ServerType.liveTypes }

    var body: some View {
        Button(action: { showingPicker = true }) {
            HStack(spacing: 12) {
                ServerTypeIconBadge(type: selectedType, size: 36, iconSize: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(NSLocalizedString("Server Type", comment: ""))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    HStack(spacing: 6) {
                        Text(selectedType.displayName)
                            .font(.body.weight(.semibold))
                            .foregroundColor(.primary)
                        if selectedType.isBeta {
                            Text("Beta")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1.5)
                                .background(Color.orange.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }

                Spacer()

                Image(systemName: "chevron.down")
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .sheet(isPresented: $showingPicker) {
            NavigationView {
                List {
                    Section(header: Text(NSLocalizedString("Media Servers", comment: ""))) {
                        ForEach(mediaTypes, id: \.self) { type in
                            pickerRow(for: type)
                        }
                    }

                    Section(header: Text(NSLocalizedString("File Protocols", comment: ""))) {
                        ForEach(protocolTypes, id: \.self) { type in
                            pickerRow(for: type)
                        }
                    }

                    Section(header: Text(NSLocalizedString("Live TV", comment: ""))) {
                        ForEach(liveTypes, id: \.self) { type in
                            pickerRow(for: type)
                        }
                    }

                    Section(header: Text(NSLocalizedString("Cloud Drives", comment: ""))) {
                        ForEach(cloudTypes, id: \.self) { type in
                            pickerRow(for: type)
                        }
                    }

                    Section(footer: Text(NSLocalizedString("Add Server Future Support Footer", comment: ""))) {
                        NavigationLink(destination: ServiceRequestForm(
                            requestedServiceType: $requestedServiceType,
                            feedbackMailDraft: $feedbackMailDraft,
                            feedbackAlert: $feedbackAlert,
                            showingPicker: $showingPicker
                        )) {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(NSLocalizedString("Add Server Future Support Title", comment: ""))
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(.primary)
                                    Text(NSLocalizedString("Add Server Future Support Message", comment: ""))
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .navigationTitle(NSLocalizedString("Choose Server Type", comment: ""))
                .navigationBarItems(
                    leading: Button(NSLocalizedString("Cancel", comment: "")) {
                        showingPicker = false
                    }
                )
            }
        }
        .sheet(item: $feedbackMailDraft) { draft in
            MailComposeSheet(draft: draft, onFinish: handleMailComposeResult)
        }
    }

    private func pickerRow(for type: ServerConfig.ServerType) -> some View {
        Button(action: {
            selectedType = type
            showingPicker = false
        }) {
            HStack(spacing: 12) {
                ServerTypeIconBadge(type: type, size: 30, iconSize: 16)
                Text(type.displayName)
                    .strikethrough(type == .googledrive)
                    .foregroundColor(.primary)
                if type.isBeta {
                    Text("Beta")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule())
                }
                Spacer()
                if selectedType == type {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    #if os(iOS)
    private func handleMailComposeResult(_ result: Result<MFMailComposeResult, Error>) {
        switch result {
        case .success:
            requestedServiceType = ""
        case .failure:
            feedbackAlert = .message(
                title: NSLocalizedString("Unable to Send Feedback", comment: ""),
                message: NSLocalizedString("Feedback Compose Failed Message", comment: "")
            )
        }
    }
    #endif
}

private enum ServiceRequestAlert: Identifiable {
    case message(title: String, message: String)

    var id: String {
        switch self {
        case .message(let title, let message):
            return "\(title)-\(message)"
        }
    }

    var title: String {
        switch self {
        case .message(let title, _):
            return title
        }
    }

    var message: String {
        switch self {
        case .message(_, let message):
            return message
        }
    }
}

private struct ServiceRequestForm: View {
    @Binding var requestedServiceType: String
    @Binding var feedbackMailDraft: FeedbackDraft?
    @Binding var feedbackAlert: ServiceRequestAlert?
    @Binding var showingPicker: Bool

    var body: some View {
        Form {
            Section(
                header: Text(NSLocalizedString("Add Server Future Support Title", comment: "")),
                footer: Text(NSLocalizedString("Add Server Future Support Footer", comment: ""))
            ) {
                Text(NSLocalizedString("Add Server Future Support Message", comment: ""))
                    .font(.footnote)
                    .foregroundColor(.secondary)

                TextField(NSLocalizedString("Requested Service Type Placeholder", comment: ""), text: $requestedServiceType)
                    .autocapitalization(.none)
            }

            Section {
                Button(action: sendServiceRequest) {
                    HStack {
                        Image(systemName: "envelope")
                        Text(NSLocalizedString("Request New Service", comment: ""))
                    }
                }
                .disabled(requestedServiceType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .navigationTitle(NSLocalizedString("Request New Service", comment: ""))
        .navigationBarTitleDisplayMode(.inline)
        .alert(item: $feedbackAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
            )
        }
    }

    private func sendServiceRequest() {
        let draft = FeedbackSupport.makeServiceRequestDraft(
            requestedService: requestedServiceType
        )

        if MailComposeSheet.canSendMail {
            feedbackMailDraft = draft
            showingPicker = false
            return
        }

        if let mailtoURL = FeedbackSupport.mailtoURL(for: draft),
           UIApplication.shared.canOpenURL(mailtoURL) {
            UIApplication.shared.open(mailtoURL, options: [:], completionHandler: nil)
            requestedServiceType = ""
            showingPicker = false
            return
        }

        feedbackAlert = .message(
            title: NSLocalizedString("No Email App Available", comment: ""),
            message: NSLocalizedString("Feedback Fallback Message", comment: "")
        )
    }
}

struct AddServerView: View {
    @ObservedObject var networkService: AppNetworkService
    @Environment(\.presentationMode) var presentationMode
    
    let existingServer: ServerConfig?
    let prefilledServer: ServerConfig?
    
    @State private var type: ServerConfig.ServerType
    @State private var drafts: [ServerConfig.ServerType: ServerTypeDraft] = [:]
    @State private var vodSourceDrafts: [VODSourceConfig] = []
    @State private var isPasswordVisible = false
    
    // Auth tokens from test
    @State private var verifiedAccessToken: String?
    @State private var verifiedUserId: String?
    
    @State private var isTesting = false
    @State private var testTask: Task<Void, Never>?
    @State private var testResult: Result<Void, Error>?
    @State private var showingTestAlert = false
    
    // Plex
    @State private var plexPin: PlexPin?
    @State private var isPlexAuthorizing = false
    @State private var plexPollingTask: Task<Void, Never>?
    @State private var plexLoginURL: URL?
    
    // 115
    @State private var pan115LoginMode: Int = 0 // 0: Web, 1: QR Code
    @State private var pan115QRSession: Pan115Manager.QRCodeSessionInfo?
    @State private var pan115QRStatusText: String = ""
    @State private var pan115PollingTask: Task<Void, Never>?
    @State private var showingPan115WebLogin = false
    
    // OneDrive
    @State private var isOneDriveAuthorizing = false
    @State private var oneDriveAuthSession: ASWebAuthenticationSession?
    @State private var oneDriveAuthContextProvider: WebAuthContextProvider?

    // Google Drive
    @State private var isGoogleDriveAuthorizing = false
    @State private var googleDriveAuthSession: ASWebAuthenticationSession?
    @State private var googleDriveAuthContextProvider: WebAuthContextProvider?
    
    init(networkService: AppNetworkService, existingServer: ServerConfig? = nil, prefilledServer: ServerConfig? = nil, initialType: ServerConfig.ServerType = .smb) {
        self.networkService = networkService
        self.existingServer = existingServer
        self.prefilledServer = prefilledServer
        
        let targetType: ServerConfig.ServerType
        var initialDrafts: [ServerConfig.ServerType: ServerTypeDraft] = [:]
        
        if let rawServer = existingServer ?? prefilledServer {
            let server = networkService.hydratedServer(from: rawServer)
            targetType = server.type
            initialDrafts[server.type] = ServerTypeDraft.initial(for: server.type, existing: server)
            if server.type == .pan115 && !(server.passwordSecret ?? "").isEmpty {
                _pan115LoginMode = State(initialValue: 1)
            }
        } else {
            targetType = initialType
            initialDrafts[initialType] = ServerTypeDraft.initial(for: initialType, existing: nil)
        }
        
        _vodSourceDrafts = State(initialValue: existingServer.map { $0.vodSources ?? [VODSourceConfig(id: $0.id, name: $0.name, address: $0.fullURL)] } ?? [])
        _type = State(initialValue: targetType)
        _drafts = State(initialValue: initialDrafts)
    }
    
    var isEditing: Bool { existingServer != nil }
    
    private var spec: ServerFormSpec {
        ServerFormSpec.spec(for: type)
    }
    
    private var currentDraft: Binding<ServerTypeDraft> {
        Binding(
            get: {
                if let draft = drafts[type] {
                    return draft
                }
                return ServerTypeDraft.initial(for: type, existing: existingServer)
            },
            set: { newValue in
                drafts[type] = newValue
            }
        )
    }
    
    private var defaultPortHint: String {
        let port = spec.defaultPort(useSSL: currentDraft.useSSL.wrappedValue)
        return NSLocalizedString("Default", comment: "") + ": \(port)"
    }
    
    private var effectivePlexToken: String? {
        let candidates: [String?] = [
            verifiedAccessToken,
            currentDraft.accessToken.wrappedValue,
            existingServer?.accessToken,
            existingServer?.passwordSecret
        ]
        for candidate in candidates {
            if let token = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
                return token
            }
        }
        return nil
    }

    private var hasFreshPlexToken: Bool {
        if let token = verifiedAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return true
        }
        return false
    }

    private var hasStoredPlexToken: Bool {
        let storedCandidates: [String?] = [
            existingServer?.accessToken,
            existingServer?.passwordSecret
        ]
        for token in storedCandidates {
            if let value = token?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                return true
            }
        }
        return false
    }

    private var canSave: Bool {
        currentDraft.wrappedValue.isValidForSave(spec: spec)
            && (type != .vod || VODSourceEditor.valid(vodSourceDrafts))
    }

    private var canTest: Bool {
        let draft = currentDraft.wrappedValue
        if spec.authStyle == .pan115 {
            return !draft.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else if spec.authStyle == .onedrive || spec.authStyle == .googledrive {
            return !draft.accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } else {
            return !draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(NSLocalizedString("Server Info", comment: ""))) {
                    ServerTypeSelector(selectedType: $type)
                    TextField(NSLocalizedString("Server Name", comment: ""), text: currentDraft.name)
                }
                
                if spec.authStyle == .pan115 {
                    pan115Section
                } else if spec.authStyle == .onedrive {
                    oneDriveSection
                } else if spec.authStyle == .googledrive {
                    googleDriveSection
                } else if spec.authStyle == .iptv {
                    iptvSection
                } else if spec.authStyle == .vod {
                    vodSection
                } else {
                    standardConnectionSection
                    credentialsSection
                }
                
                Section {
                    if isTesting {
                        Button(action: cancelTestConnection) {
                            HStack {
                                Text(NSLocalizedString("Cancel Test", comment: ""))
                                    .foregroundColor(.red)
                                Spacer()
                                ProgressView()
                            }
                        }
                    } else {
                        Button(action: testConnection) {
                            Text(NSLocalizedString("Test Connection", comment: ""))
                        }
                        .disabled(!canTest)
                    }
                }
            }
            .navigationTitle(isEditing ? NSLocalizedString("Edit Server", comment: "") : NSLocalizedString("Add Server", comment: ""))
            .navigationBarItems(
                leading: Button(action: { presentationMode.wrappedValue.dismiss() }) {
                    AppToolbarIcon(systemName: "xmark", style: .secondary)
                },
                trailing: Button(NSLocalizedString("Save", comment: "")) {
                    saveServer()
                    presentationMode.wrappedValue.dismiss()
                }.disabled(!canSave)
            )
            .onDisappear {
                cancelAllTasks()
            }
            .onChange(of: type) { newType in
                handleTypeChange(to: newType)
            }
            .sheet(isPresented: $showingPan115WebLogin) {
                Pan115WebLoginSheet { capturedCookie in
                    showingPan115WebLogin = false
                    currentDraft.password.wrappedValue = capturedCookie
                    testResult = .success(())
                    showingTestAlert = true
                }
            }
            .sheet(isPresented: Binding(
                get: { plexLoginURL != nil },
                set: { isPresented in
                    if !isPresented {
                        plexLoginURL = nil
                    }
                }
            )) {
                if let loginURL = plexLoginURL {
                    SafariView(url: loginURL)
                        .edgesIgnoringSafeArea(.all)
                }
            }
            .alert(isPresented: $showingTestAlert) {
                switch testResult {
                case .success:
                    return Alert(
                        title: Text(NSLocalizedString("Connection Successful", comment: "")),
                        message: Text(NSLocalizedString("Your server settings are correct and a connection was established.", comment: "")),
                        dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
                    )
                case .failure(let error):
                    return Alert(
                        title: Text(NSLocalizedString("Connection Failed", comment: "")),
                        message: Text(error.localizedDescription),
                        dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
                    )
                case .none:
                    return Alert(title: Text(NSLocalizedString("Unknown", comment: "")))
                }
            }
        }
    }

    // MARK: - Pan115 Section
    @ViewBuilder
    private var pan115Section: some View {
        Section {
            Picker("", selection: $pan115LoginMode) {
                Text(NSLocalizedString("QR Code Login", comment: "")).tag(0)
                Text(NSLocalizedString("Web Login", comment: "")).tag(1)
            }
            .pickerStyle(.segmented)
        }

        if pan115LoginMode == 1 {
            Section(
                header: Text(NSLocalizedString("Web Login", comment: "")),
                footer: VStack(alignment: .leading, spacing: 6) {
                    Text(NSLocalizedString("Log in via official 115 web page with SMS, password, or WeChat. GenPlayer will automatically authorize and capture credentials.", comment: ""))
                    Text(NSLocalizedString("Cloud Drive Beta Disclaimer", comment: ""))
                        .foregroundColor(.orange)
                }
            ) {
                Button(action: { showingPan115WebLogin = true }) {
                    HStack {
                        Image(systemName: "globe")
                            .font(.title2)
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(NSLocalizedString("Sign in on 115.com", comment: ""))
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text(NSLocalizedString("Supports SMS verification code, password, or WeChat", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading, 6)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 6)
                }
            }
        } else {
            Section(header: Text(NSLocalizedString("Scan with 115 Mobile App", comment: ""))) {
                VStack(spacing: 16) {
                    if let qr = pan115QRSession {
                        AsyncImage(url: qr.qrCodeURL) { phase in
                            switch phase {
                            case .empty:
                                ProgressView().frame(width: 200, height: 200)
                            case .success(let image):
                                image
                                    .resizable()
                                    .interpolation(.none)
                                    .scaledToFit()
                                    .frame(width: 200, height: 200)
                                    .cornerRadius(12)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                                    )
                            case .failure:
                                VStack(spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.largeTitle)
                                        .foregroundColor(.orange)
                                    Text(NSLocalizedString("Failed to load QR code", comment: ""))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Button(NSLocalizedString("Retry", comment: "")) {
                                        loadPan115QRCode()
                                    }
                                    .buttonStyle(.bordered)
                                }
                                .frame(width: 200, height: 200)
                            @unknown default:
                                EmptyView()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 8)

                        Text(pan115QRStatusText.isEmpty ? NSLocalizedString("Scan with 115 Mobile App", comment: "") : pan115QRStatusText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, alignment: .center)

                        Button(action: loadPan115QRCode) {
                            Label(NSLocalizedString("Refresh QR Code", comment: ""), systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 200)
                            .onAppear { loadPan115QRCode() }
                    }
                }
            }
        }
    }

    // MARK: - OneDrive Section
    @ViewBuilder
    private var oneDriveSection: some View {
        let isAuthorized = !currentDraft.accessToken.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                           !currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        Section(
            header: Text(NSLocalizedString("Microsoft Account Authorization", comment: "")),
            footer: VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("Sign in securely with your personal, work, or school Microsoft Account via official Microsoft authentication.", comment: ""))
                Text(NSLocalizedString("Cloud Drive Beta Disclaimer", comment: ""))
                    .foregroundColor(.orange)
            }
        ) {
            VStack(spacing: 16) {
                ServerTypeIconBadge(type: .onedrive, size: 48, iconSize: 26)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)

                Text(NSLocalizedString("Connect to OneDrive", comment: ""))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text(NSLocalizedString("Access your videos, photos, and documents stored in OneDrive with high-speed streaming.", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)

                if isAuthorized {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(NSLocalizedString("Connection Successful", comment: ""))
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Spacer()
                        Button(NSLocalizedString("Re-authorize Device", comment: "")) {
                            startOneDriveSignIn()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button(action: startOneDriveSignIn) {
                        HStack {
                            if isOneDriveAuthorizing {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .padding(.trailing, 6)
                            } else {
                                Image(systemName: "lock.shield")
                                    .font(.headline)
                            }
                            Text(isOneDriveAuthorizing ? NSLocalizedString("Signing in...", comment: "") : NSLocalizedString("Sign in with Microsoft", comment: ""))
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.0, green: 0.47, blue: 0.83))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(isOneDriveAuthorizing)
                    .padding(.vertical, 8)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Google Drive Section
    @ViewBuilder
    private var googleDriveSection: some View {
        let isAuthorized = !currentDraft.accessToken.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                           !currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        Section(
            header: Text(NSLocalizedString("Google Account Authorization", comment: "")),
            footer: VStack(alignment: .leading, spacing: 6) {
                Text(NSLocalizedString("Sign in securely with your Google Account via official Google authentication.", comment: ""))
                Text(NSLocalizedString("Cloud Drive Beta Disclaimer", comment: ""))
                    .foregroundColor(.orange)
            }
        ) {
            VStack(spacing: 16) {
                ServerTypeIconBadge(type: .googledrive, size: 48, iconSize: 26)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)

                Text(NSLocalizedString("Connect to Google Drive", comment: ""))
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .center)

                Text(NSLocalizedString("Access your videos, photos, and documents stored in Google Drive with high-speed streaming.", comment: ""))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .center)

                if isAuthorized {
                    HStack {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(NSLocalizedString("Connection Successful", comment: ""))
                            .font(.subheadline)
                            .foregroundColor(.primary)
                        Spacer()
                        Button(NSLocalizedString("Re-authorize Device", comment: "")) {
                            startGoogleDriveSignIn()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 4)
                } else {
                    Button(action: startGoogleDriveSignIn) {
                        HStack {
                            if isGoogleDriveAuthorizing {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .padding(.trailing, 6)
                            } else {
                                Image(systemName: "lock.shield")
                                    .font(.headline)
                            }
                            Text(isGoogleDriveAuthorizing ? NSLocalizedString("Signing in...", comment: "") : NSLocalizedString("Sign in with Google", comment: ""))
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.96, green: 0.70, blue: 0.12))
                        .foregroundColor(.white)
                        .cornerRadius(10)
                    }
                    .buttonStyle(.plain)
                    .disabled(isGoogleDriveAuthorizing)
                    .padding(.vertical, 8)
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - IPTV Section
    @ViewBuilder
    private var iptvSection: some View {
        Section(header: Text(NSLocalizedString("Connection", comment: ""))) {
            Toggle("HTTPS", isOn: currentDraft.useSSL)
            TextField(NSLocalizedString("Playlist URL or File Path", comment: ""), text: currentDraft.address)
                .autocapitalization(.none)
                .keyboardType(.URL)
            TextField(NSLocalizedString("EPG URL (optional)", comment: ""), text: currentDraft.customEPGURL)
                .autocapitalization(.none)
                .keyboardType(.URL)
        }
    }

    // MARK: - VOD Section
    @ViewBuilder
    private var vodSection: some View {
        Section(header: Text(platformShellString("VOD Sources"))) {
            VODSourceEditor(sources: $vodSourceDrafts)
        }
        .onAppear { initializeVODSources() }
        .onChange(of: vodSourceDrafts) { sources in
            currentDraft.wrappedValue.address = sources.first(where: \.isEnabled)?.address ?? ""
        }
    }

    private func initializeVODSources() {
        if vodSourceDrafts.isEmpty {
            vodSourceDrafts = [VODSourceConfig(name: currentDraft.wrappedValue.name, address: currentDraft.wrappedValue.address)]
        }
    }

    // MARK: - Standard Connection Section
    @ViewBuilder
    private var standardConnectionSection: some View {
        Section(header: Text(NSLocalizedString("Connection", comment: ""))) {
            if spec.allowsSSL {
                Toggle("HTTPS", isOn: currentDraft.useSSL)
            }
            if spec.requiresAddressInput {
                TextField(NSLocalizedString("Address", comment: "") + " (\(spec.addressPlaceholder))", text: currentDraft.address)
                    .autocapitalization(.none)
                    .keyboardType(.URL)
            }
            if spec.requiresPortInput {
                TextField(NSLocalizedString("Port", comment: "") + " (\(defaultPortHint))", text: currentDraft.portString)
                    .keyboardType(.numberPad)
            }
        }
    }

    // MARK: - Credentials Section
    @ViewBuilder
    private var credentialsSection: some View {
        Section(header: Text(NSLocalizedString("Credentials", comment: ""))) {
            if spec.authStyle == .plex {
                VStack(alignment: .leading, spacing: 8) {
                    Text(NSLocalizedString("Recommended: use Plex sign-in flow to obtain token.", comment: ""))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    if let pin = plexPin {
                        Text(String(format: NSLocalizedString("Plex code: %@", comment: ""), pin.code))
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    if isPlexAuthorizing {
                        HStack {
                            ProgressView()
                            Text(NSLocalizedString("Waiting for Plex authorization...", comment: ""))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    } else if hasFreshPlexToken {
                        Label(NSLocalizedString("Token acquired. It will be saved and used automatically.", comment: ""), systemImage: "checkmark.shield.fill")
                            .font(.footnote)
                            .foregroundColor(.green)
                        Text(NSLocalizedString("Plex token captured. Please test connection to verify server reachability.", comment: ""))
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else if hasStoredPlexToken {
                        Label(NSLocalizedString("Stored Plex token detected.", comment: ""), systemImage: "key.fill")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    Button(action: startPlexLogin) {
                        Text(isPlexAuthorizing ? NSLocalizedString("Re-open Plex Login", comment: "") : NSLocalizedString("Sign in with Plex", comment: ""))
                    }
                    .disabled(currentDraft.address.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                TextField(NSLocalizedString("Username (optional)", comment: ""), text: currentDraft.username)
                    .autocapitalization(.none)

                HStack {
                    Group {
                        if isPasswordVisible {
                            TextField(NSLocalizedString("Password (optional)", comment: ""), text: currentDraft.password)
                                .autocapitalization(.none)
                        } else {
                            SecureField(NSLocalizedString("Password (optional)", comment: ""), text: currentDraft.password)
                        }
                    }

                    Button(action: { isPasswordVisible.toggle() }) {
                        Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                }
            }
            if spec.showsWorkgroup {
                TextField(NSLocalizedString("Workgroup (optional)", comment: ""), text: currentDraft.workgroup)
                    .autocapitalization(.none)
            }
        }
    }

    // MARK: - Actions & Logic
    private func handleTypeChange(to newType: ServerConfig.ServerType) {
        cancelAllTasks()
        if drafts[newType] == nil {
            drafts[newType] = ServerTypeDraft.initial(for: newType, existing: existingServer)
        }
        if newType == .pan115 {
            if currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                loadPan115QRCode()
            }
        }
    }

    private func cancelAllTasks() {
        plexPollingTask?.cancel()
        plexPollingTask = nil
        plexPin = nil
        plexLoginURL = nil
        isPlexAuthorizing = false

        pan115PollingTask?.cancel()
        pan115PollingTask = nil
        pan115QRSession = nil

        oneDriveAuthSession?.cancel()
        oneDriveAuthSession = nil
        isOneDriveAuthorizing = false

        testTask?.cancel()
        testTask = nil
        isTesting = false
    }

    private func startOneDriveSignIn() {
        isOneDriveAuthorizing = true
        let pkce = OneDriveManager.generatePKCE()

        guard let authURL = OneDriveManager.buildAuthorizationURL(challenge: pkce.challenge) else {
            isOneDriveAuthorizing = false
            testResult = .failure(NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to build authorization URL", comment: "")]))
            showingTestAlert = true
            return
        }

        let contextProvider = WebAuthContextProvider()
        self.oneDriveAuthContextProvider = contextProvider

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: "genplayer") { callbackURL, error in
            DispatchQueue.main.async {
                self.isOneDriveAuthorizing = false
            }

            if let error = error {
                if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                    return
                }
                DispatchQueue.main.async {
                    self.testResult = .failure(error)
                    self.showingTestAlert = true
                }
                return
            }

            guard let callbackURL = callbackURL,
                  let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                DispatchQueue.main.async {
                    self.testResult = .failure(NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Authorization code not returned.", comment: "")]))
                    self.showingTestAlert = true
                }
                return
            }

            Task {
                do {
                    let tokenResponse = try await OneDriveManager.shared.exchangeCodeForTokens(code: code, verifier: pkce.verifier)
                    await MainActor.run {
                        var draft = self.currentDraft.wrappedValue
                        draft.accessToken = tokenResponse.accessToken
                        draft.password = tokenResponse.refreshToken
                        if draft.name.isEmpty || draft.name == "OneDrive" {
                            draft.name = tokenResponse.displayName.isEmpty ? "OneDrive" : "OneDrive - \(tokenResponse.displayName)"
                        }
                        self.currentDraft.wrappedValue = draft
                        self.testResult = .success(())
                        self.showingTestAlert = true
                    }
                } catch {
                    await MainActor.run {
                        self.testResult = .failure(error)
                        self.showingTestAlert = true
                    }
                }
            }
        }

        session.presentationContextProvider = contextProvider
        session.prefersEphemeralWebBrowserSession = false
        self.oneDriveAuthSession = session
        session.start()
    }

    private func startGoogleDriveSignIn() {
        isGoogleDriveAuthorizing = true
        let pkce = GoogleDriveManager.generatePKCE()

        guard let authURL = GoogleDriveManager.buildAuthorizationURL(challenge: pkce.challenge) else {
            isGoogleDriveAuthorizing = false
            testResult = .failure(NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to build authorization URL", comment: "")]))
            showingTestAlert = true
            return
        }

        let contextProvider = WebAuthContextProvider()
        self.googleDriveAuthContextProvider = contextProvider

        let session = ASWebAuthenticationSession(url: authURL, callbackURLScheme: GoogleDriveManager.callbackScheme) { callbackURL, error in
            DispatchQueue.main.async {
                self.isGoogleDriveAuthorizing = false
            }

            if let error = error {
                if let authError = error as? ASWebAuthenticationSessionError, authError.code == .canceledLogin {
                    return
                }
                DispatchQueue.main.async {
                    self.testResult = .failure(error)
                    self.showingTestAlert = true
                }
                return
            }

            guard let callbackURL = callbackURL,
                  let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                  let code = components.queryItems?.first(where: { $0.name == "code" })?.value else {
                DispatchQueue.main.async {
                    self.testResult = .failure(NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Authorization code not returned.", comment: "")]))
                    self.showingTestAlert = true
                }
                return
            }

            Task {
                do {
                    let tokenResponse = try await GoogleDriveManager.shared.exchangeCodeForTokens(code: code, verifier: pkce.verifier)
                    await MainActor.run {
                        var draft = self.currentDraft.wrappedValue
                        draft.accessToken = tokenResponse.accessToken
                        if !tokenResponse.refreshToken.isEmpty {
                            draft.password = tokenResponse.refreshToken
                        }
                        if draft.name.isEmpty || draft.name == "Google Drive" {
                            draft.name = tokenResponse.displayName.isEmpty ? "Google Drive" : "Google Drive - \(tokenResponse.displayName)"
                        }
                        self.currentDraft.wrappedValue = draft
                        self.testResult = .success(())
                        self.showingTestAlert = true
                    }
                } catch {
                    await MainActor.run {
                        self.testResult = .failure(error)
                        self.showingTestAlert = true
                    }
                }
            }
        }

        session.presentationContextProvider = contextProvider
        session.prefersEphemeralWebBrowserSession = false
        self.googleDriveAuthSession = session
        session.start()
    }

    private func loadPan115QRCode() {
        pan115PollingTask?.cancel()
        pan115QRSession = nil
        pan115QRStatusText = NSLocalizedString("Scan with 115 Mobile App", comment: "")
        pan115PollingTask = Task {
            do {
                let session = try await Pan115Manager.shared.fetchQRCode()
                if Task.isCancelled { return }
                await MainActor.run {
                    self.pan115QRSession = session
                    self.pan115QRStatusText = NSLocalizedString("Scan with 115 Mobile App", comment: "")
                }
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                    let statusResult = await Pan115Manager.shared.pollQRCodeStatus(session: session)
                    if Task.isCancelled { return }
                    var shouldStop = false
                    await MainActor.run {
                        switch statusResult {
                        case .waiting:
                            self.pan115QRStatusText = NSLocalizedString("Scan with 115 Mobile App", comment: "")
                        case .scanned:
                            self.pan115QRStatusText = NSLocalizedString("Scanned. Please confirm on phone.", comment: "")
                        case .success(let cookie):
                            self.pan115QRStatusText = NSLocalizedString("Authorization successful!", comment: "")
                            if !cookie.isEmpty {
                                self.currentDraft.password.wrappedValue = cookie
                                self.testResult = .success(())
                                self.showingTestAlert = true
                            }
                            shouldStop = true
                        case .expired:
                            self.pan115QRStatusText = NSLocalizedString("QR code expired. Click to reload.", comment: "")
                            shouldStop = true
                        case .error(let err):
                            self.pan115QRStatusText = err
                            shouldStop = true
                        }
                    }
                    if shouldStop {
                        break
                    }
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    self.pan115QRStatusText = error.localizedDescription
                }
            }
        }
    }

    private func createTempServer() -> ServerConfig {
        var server = currentDraft.wrappedValue.buildServerConfig(type: type)
        if type == .plex {
            server.accessToken = effectivePlexToken
        }
        return server
    }
    
    private func testConnection() {
        if type == .onedrive {
            let hasToken = !currentDraft.accessToken.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                           !currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasToken {
                testResult = .success(())
            } else {
                testResult = .failure(NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Please sign in with Microsoft first.", comment: "")]))
            }
            showingTestAlert = true
            return
        }

        if type == .googledrive {
            let hasToken = !currentDraft.accessToken.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                           !currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasToken {
                testResult = .success(())
            } else {
                testResult = .failure(NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Please sign in with Google first.", comment: "")]))
            }
            showingTestAlert = true
            return
        }

        if type == .pan115 {
            let hasCookie = !currentDraft.password.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasCookie {
                testResult = .success(())
            } else {
                testResult = .failure(NSError(domain: "GenPlayer", code: -1, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Please scan QR code or log in via Web first.", comment: "")]))
            }
            showingTestAlert = true
            return
        }

        isTesting = true
        let server = createTempServer()
        
        testTask = Task {
            do {
                let updatedServer = try await withThrowingTaskGroup(of: ServerConfig.self) { group in
                    group.addTask {
                        return try await networkService.testConnection(server)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 15_000_000_000)
                        throw NSError(domain: "GenPlayer", code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Connection timed out", comment: "")])
                    }
                    if let result = try await group.next() {
                        group.cancelAll()
                        return result
                    } else {
                        throw CancellationError()
                    }
                }
                
                if !Task.isCancelled {
                    await MainActor.run {
                        isTesting = false
                        testResult = .success(())
                        showingTestAlert = true
                        
                        if let token = updatedServer.accessToken {
                            verifiedAccessToken = token
                            self.currentDraft.accessToken.wrappedValue = token
                        }
                        if let uid = updatedServer.userId {
                            verifiedUserId = uid
                            self.currentDraft.userId.wrappedValue = uid
                        }
                        if updatedServer.type == .plex {
                            self.currentDraft.useSSL.wrappedValue = updatedServer.useSSL
                            self.currentDraft.portString.wrappedValue = updatedServer.port.map(String.init) ?? ""
                        }
                    }
                }
            } catch {
                if !Task.isCancelled {
                    await MainActor.run {
                        isTesting = false
                        testResult = .failure(error)
                        showingTestAlert = true
                    }
                }
            }
        }
    }
    
    private func cancelTestConnection() {
        testTask?.cancel()
        testTask = nil
        isTesting = false
    }

    private func startPlexLogin() {
        guard type == .plex else { return }

        plexPollingTask?.cancel()
        isPlexAuthorizing = true
        plexPin = nil

        plexPollingTask = Task {
            do {
                let pin = try await PlexService.shared.createLoginPin()
                guard let loginURL = PlexService.shared.buildLoginURL(for: pin) else {
                    throw NSError(
                        domain: "GenPlayer",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Failed to build Plex login URL", comment: "")]
                    )
                }

                await MainActor.run {
                    plexPin = pin
                    plexLoginURL = loginURL
                }

                for _ in 0..<60 {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    if Task.isCancelled { return }
                    let polled = try await PlexService.shared.pollLoginPin(id: pin.id, code: pin.code)
                    if let token = polled.authToken, !token.isEmpty {
                        await MainActor.run {
                            verifiedAccessToken = token
                            self.currentDraft.accessToken.wrappedValue = token
                            if let existing = existingServer {
                                var persisted = existing
                                persisted.accessToken = token
                                networkService.updateServer(persisted)
                            }
                            isPlexAuthorizing = false
                            plexPin = nil
                            plexLoginURL = nil
                        }
                        return
                    }
                }

                await MainActor.run {
                    isPlexAuthorizing = false
                    plexPin = nil
                    plexLoginURL = nil
                    testResult = .failure(NSError(domain: "GenPlayer", code: NSURLErrorTimedOut, userInfo: [NSLocalizedDescriptionKey: NSLocalizedString("Plex login timed out. Please try again.", comment: "")]))
                    showingTestAlert = true
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isPlexAuthorizing = false
                    plexPin = nil
                    plexLoginURL = nil
                    testResult = .failure(error)
                    showingTestAlert = true
                }
            }
        }
    }
    
    private func saveServer() {
        let draft = currentDraft.wrappedValue
        var server = draft.buildServerConfig(type: type, id: existingServer?.id ?? UUID())
        if type == .vod {
            server.vodSources = vodSourceDrafts
            server.address = vodSourceDrafts.first(where: \.isEnabled)?.address.trimmingCharacters(in: .whitespacesAndNewlines) ?? server.address
        }
        
        let connectionSettingsChanged: Bool = {
            guard let existing = existingServer, existing.type == type else { return true }
            return existing.address.trimmingCharacters(in: .whitespacesAndNewlines) != server.address ||
                   existing.port != server.port ||
                   existing.useSSL != server.useSSL ||
                   (existing.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != (server.username ?? "") ||
                   (existing.passwordSecret ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != (server.passwordSecret ?? "") ||
                   (existing.workgroup ?? "").trimmingCharacters(in: .whitespacesAndNewlines) != (server.workgroup ?? "")
        }()

        let testFailed: Bool = {
            if case .failure = testResult { return true }
            return false
        }()
        
        if type == .plex {
            if testFailed {
                server.accessToken = nil
            } else {
                server.accessToken = effectivePlexToken
            }
        } else if let token = verifiedAccessToken {
            server.accessToken = token
        } else if let existing = existingServer, existing.type == type, !connectionSettingsChanged, !testFailed {
            server.accessToken = existing.accessToken
        } else if !type.isCloudDrive {
            server.accessToken = nil
        }

        if type == .jellyfin || type == .emby {
            if let uid = verifiedUserId {
                server.userId = uid
            } else if let existing = existingServer, existing.type == type, !connectionSettingsChanged, !testFailed {
                server.userId = existing.userId
            } else {
                server.userId = nil
            }
        }
        
        if let existing = existingServer {
            server.id = existing.id
            if server.accessToken == nil && !type.isCloudDrive {
                networkService.clearServerAuthTokens(for: existing.id)
            }
            networkService.updateServer(server)
        } else {
            networkService.addServer(server)
        }
        
        networkService.recordServerAccess(server.id)
    }
}

struct JellyfinLoginView: View {
    let server: ServerConfig
    @ObservedObject var networkService: AppNetworkService
    @Environment(\.presentationMode) var presentationMode
    @State private var username = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(NSLocalizedString("Server", comment: ""))) {
                    HStack {
                        Text(NSLocalizedString("Name", comment: ""))
                        Spacer()
                        Text(server.name)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text(NSLocalizedString("Address", comment: ""))
                        Spacer()
                        Text(server.fullURL)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Section(header: Text(NSLocalizedString("Credentials", comment: ""))) {
                    TextField(NSLocalizedString("Username", comment: ""), text: $username)
                        .autocapitalization(.none)
                        .textContentType(.username)
                    HStack {
                        Group {
                            if isPasswordVisible {
                                TextField(NSLocalizedString("Password", comment: ""), text: $password)
                                    .autocapitalization(.none)
                            } else {
                                SecureField(NSLocalizedString("Password", comment: ""), text: $password)
                            }
                        }
                        .textContentType(.password)

                        Button(action: { isPasswordVisible.toggle() }) {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
                
                Section {
                    Button(action: login) {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text(NSLocalizedString("Login", comment: ""))
                            }
                            Spacer()
                        }
                    }
                    .disabled(username.isEmpty || isLoading)
                }
            }
            .navigationTitle(NSLocalizedString("Jellyfin Login", comment: ""))
            .navigationBarItems(
                leading: Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    AppToolbarIcon(systemName: "xmark", style: .secondary)
                }
            )
        }
    }
    
    private func login() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let result = try await JellyfinService.shared.login(
                    server: server,
                    username: username,
                    password: password
                )
                var updatedServer = server
                updatedServer.accessToken = result.accessToken
                updatedServer.userId = result.user.id
                updatedServer.username = username
                updatedServer.passwordSecret = password
                await MainActor.run {
                    networkService.updateServer(updatedServer)
                    isLoading = false
                    presentationMode.wrappedValue.dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

struct EmbyLoginView: View {
    let server: ServerConfig
    @ObservedObject var networkService: AppNetworkService
    @Environment(\.presentationMode) var presentationMode
    @State private var username = ""
    @State private var password = ""
    @State private var isPasswordVisible = false
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(NSLocalizedString("Server", comment: ""))) {
                    HStack {
                        Text(NSLocalizedString("Name", comment: ""))
                        Spacer()
                        Text(server.name)
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text(NSLocalizedString("Address", comment: ""))
                        Spacer()
                        Text(server.fullURL)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Section(header: Text(NSLocalizedString("Credentials", comment: ""))) {
                    TextField(NSLocalizedString("Username", comment: ""), text: $username)
                        .autocapitalization(.none)
                        .textContentType(.username)
                    HStack {
                        Group {
                            if isPasswordVisible {
                                TextField(NSLocalizedString("Password", comment: ""), text: $password)
                                    .autocapitalization(.none)
                            } else {
                                SecureField(NSLocalizedString("Password", comment: ""), text: $password)
                            }
                        }
                        .textContentType(.password)

                        Button(action: { isPasswordVisible.toggle() }) {
                            Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                if let error = errorMessage {
                    Section {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
                
                Section {
                    Button(action: login) {
                        HStack {
                            Spacer()
                            if isLoading {
                                ProgressView()
                            } else {
                                Text(NSLocalizedString("Login", comment: ""))
                            }
                            Spacer()
                        }
                    }
                    .disabled(username.isEmpty || isLoading)
                }
            }
            .navigationTitle(NSLocalizedString("Emby Login", comment: ""))
            .navigationBarItems(
                leading: Button(action: {
                    presentationMode.wrappedValue.dismiss()
                }) {
                    AppToolbarIcon(systemName: "xmark", style: .secondary)
                }
            )
        }
    }
    
    private func login() {
        isLoading = true
        errorMessage = nil
        Task {
            do {
                let result = try await EmbyService.shared.login(
                    server: server,
                    username: username,
                    password: password
                )
                var updatedServer = server
                updatedServer.accessToken = result.accessToken
                updatedServer.userId = result.user.id
                updatedServer.username = username
                updatedServer.passwordSecret = password
                await MainActor.run {
                    networkService.updateServer(updatedServer)
                    isLoading = false
                    presentationMode.wrappedValue.dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

struct BackgroundDropDelegate: DropDelegate {
    @Binding var pickingID: UUID?
    @Binding var activeID: UUID?
    
    func dropUpdated(info: DropInfo) -> DropProposal? {
        if let id = pickingID, activeID == nil {
            activeID = id
        }
        return DropProposal(operation: .move)
    }
    
    func performDrop(info: DropInfo) -> Bool {
        self.activeID = nil
        self.pickingID = nil
        return true
    }
    
    func dropExited(info: DropInfo) {}
}

private struct ServerSectionHeaderView: View {
    let title: String
    let count: Int
    let isConfirming: Bool
    let onToggleConfirm: () -> Void
    let onClear: () -> Void
    
    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Color(UIColor.secondaryLabel))
            
            Spacer()
            
            if count > 0 {
                Button(action: {
                    if isConfirming {
                        withAnimation {
                            onClear()
                        }
                    } else {
                        withAnimation {
                            onToggleConfirm()
                        }
                    }
                }) {
                    HStack(spacing: 4) {
                        if isConfirming {
                            Image(systemName: "trash.fill")
                                .font(.system(size: 13, weight: .semibold))
                        } else {
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                                .fontWeight(.medium)
                        }
                    }
                    .foregroundColor(isConfirming ? .white : .secondary)
                    .padding(.horizontal, isConfirming ? 10 : 8)
                    .frame(minWidth: 28)
                    .frame(height: 24)
                    .background(isConfirming ? Color.red : Color(UIColor.systemGray4))
                    .cornerRadius(8)
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.leading, 36)
        .padding(.trailing, 28)
    }
}
