#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift

struct TVServersRootView: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    private enum ServerAlert: Identifiable {
        case result(title: String, message: String)
        case connectionFailure(server: ServerConfig, message: String)
        case remove(ServerConfig)
        case clearServers
        case clearIPTV

        var id: String {
            switch self {
            case .result(let title, let message):
                return "result-\(title)-\(message)"
            case .connectionFailure(let server, let message):
                return "connection-failure-\(server.id.uuidString)-\(message)"
            case .remove(let server):
                return "remove-\(server.id.uuidString)"
            case .clearServers:
                return "clear-servers"
            case .clearIPTV:
                return "clear-iptv"
            }
        }
    }

    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var privacySpaceService = PrivacySpaceService.shared
    @ObservedObject private var iptvService = IPTVService.shared
    @ObservedObject private var mediaSummaryService = MediaServerSummaryService.shared
    @ObservedObject private var securityService = TVSecurityService.shared
    @State private var presentedServerEditor: ServerConfig?
    @State private var activeAlert: ServerAlert?
    @State private var connectingServerID: UUID?
    @State private var connectionTask: Task<Void, Never>?
    @State private var testingServerID: UUID?
    @State private var testTask: Task<Void, Never>?
    @State private var isShowingPrivacyUnlock = false
    @State private var isShowingPrivacySetup = false
    @State private var pendingPrivacyToggleServer: ServerConfig?
    @State private var pendingPrivacyAccessServer: ServerConfig?
    @State private var isShowingAddServer = false
    @State private var isShowingAddIPTV = false
    @State private var isShowingDiscovery = false
    @State private var focusedHeaderAction: TVHeaderActionFocus?
    @State private var reorderingServer: ServerConfig?
    @FocusState private var focusedServerID: UUID?
    @FocusState private var isReorderingFocusActive: Bool
    @Namespace private var reorderNamespace
    @Binding var selection: TVRootTab

    private var visibleServers: [ServerConfig] {
        networkService.servers.filter { server in
            !tvShouldHidePrivateServer(server)
        }
    }

    private var visibleRegularServers: [ServerConfig] {
        visibleServers.filter { $0.type != .iptv }
    }

    private var visibleIPTVServers: [ServerConfig] {
        visibleServers.filter { $0.type == .iptv }
    }

    private var hasPrivateServers: Bool {
        networkService.servers.contains { privacySpaceService.isServerMarkedPrivate($0) }
    }

    private var privacyHeaderActionTitle: String {
        if !securityService.hasPrivacyPassword {
            return platformShellString("Create Password")
        }

        return securityService.isPrivacySpaceUnlocked
            ? platformShellString("Lock Privacy Space Now")
            : platformShellString("Unlock Privacy Space")
    }

    private var privacyHeaderActionIconName: String {
        securityService.hasPrivacyPassword && securityService.isPrivacySpaceUnlocked ? "lock.open" : "lock"
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TVRootPageScrollView {
                if networkService.servers.isEmpty {
                    TVNetworkEmptyHero()

                    TVCompactActionStrip(title: platformShellString("Server")) {
                        Button(action: {
                            isShowingAddServer = true
                        }) {
                            TVCompactActionCard(
                                title: platformShellString("Add Server"),
                                systemImageName: "plus.circle"
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()

                        Button(action: {
                            isShowingDiscovery = true
                        }) {
                            TVCompactActionCard(
                                title: platformShellString("Discovered Servers"),
                                systemImageName: "dot.radiowaves.left.and.right"
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                    }
                } else {
                    if !visibleRegularServers.isEmpty || visibleIPTVServers.isEmpty {
                        TVServerGridSection(
                            title: platformShellString("Servers"),
                            headerAccessory: AnyView(serverHeaderActions),
                            servers: visibleRegularServers
                        ) { server in
                            tvServerEntry(for: server)
                        }
                    }

                    if !visibleIPTVServers.isEmpty || !visibleRegularServers.isEmpty {
                        TVServerGridSection(
                            title: platformShellString("IPTV"),
                            headerAccessory: AnyView(iptvHeaderActions),
                            servers: visibleIPTVServers
                        ) { server in
                            tvServerEntry(for: server)
                        }
                    }
                }
            }
            .disabled(reorderingServer != nil)
            .allowsHitTesting(reorderingServer == nil)

            if let movingServer = reorderingServer {
                Button(action: {
                    exitReordering()
                }) {
                    ZStack(alignment: .bottom) {
                        Color.black.opacity(0.001)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .ignoresSafeArea()
                            .contentShape(Rectangle())

                        TVServerReorderingHUD(server: movingServer)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .focused($isReorderingFocusActive)
                .focusScope(reorderNamespace)
                .onAppear {
                    DispatchQueue.main.async {
                        isReorderingFocusActive = true
                    }
                }
                .onMoveCommand { direction in
                    handleServerMove(server: movingServer, direction: direction)
                }
                .onExitCommand {
                    exitReordering()
                }
                .onPlayPauseCommand {
                    exitReordering()
                }
                .transition(.opacity)
                .zIndex(100)
            }
        }
        .navigationTitle(Text(platformShellString("Network")))
        .navigationDestination(isPresented: $isShowingAddServer) {
            TVServerEditorView(existingServer: nil, prefilledServer: nil)
        }
        .navigationDestination(isPresented: $isShowingAddIPTV) {
            TVServerEditorView(existingServer: nil, prefilledServer: ServerConfig(name: "", address: "", port: nil, useSSL: false, type: .iptv))
        }
        .navigationDestination(isPresented: $isShowingDiscovery) {
            TVServerDiscoveryView()
        }
        .onDisappear {
            connectionTask?.cancel()
            testTask?.cancel()
        }
        .fullScreenCover(item: $presentedServerEditor) { server in
            NavigationView {
                TVServerEditorView(existingServer: server, prefilledServer: nil)
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .result(let title, let message):
                return Alert(
                    title: Text(title),
                    message: Text(message),
                    dismissButton: .default(Text(platformShellString("OK")))
                )
            case .connectionFailure(let server, let message):
                return Alert(
                    title: Text(platformShellString("Connection Failed")),
                    message: Text(message),
                    primaryButton: .default(Text(platformShellString("Edit Server"))) {
                        presentedServerEditor = server
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .remove(let server):
                return Alert(
                    title: Text(platformShellString("Remove Server")),
                    message: Text(platformShellString("Platform Shell TV Remove Server Confirm")),
                    primaryButton: .destructive(Text(platformShellString("Remove Server"))) {
                        networkService.deleteServer(server)
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .clearServers:
                return Alert(
                    title: Text(platformShellString("Clear Servers")),
                    message: Text(platformShellString("Platform Shell TV Clear Servers Confirm")),
                    primaryButton: .destructive(Text(platformShellString("Clear All"))) {
                        networkService.clearNonIPTVServers()
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .clearIPTV:
                return Alert(
                    title: Text(platformShellString("Clear IPTV")),
                    message: Text(platformShellString("Platform Shell TV Clear IPTV Confirm")),
                    primaryButton: .destructive(Text(platformShellString("Clear All"))) {
                        networkService.clearServers(of: .iptv)
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            }
        }
        .sheet(
            isPresented: $isShowingPrivacyUnlock,
            onDismiss: {
                if TVSecurityService.shared.isPrivacySpaceUnlocked {
                    let serverToOpen = pendingPrivacyAccessServer
                    if let pendingPrivacyToggleServer {
                        _ = privacySpaceService.toggleServerMarkedPrivate(pendingPrivacyToggleServer)
                    }
                    if let serverToOpen {
                        connectAndOpen(serverToOpen)
                    }
                }
                pendingPrivacyToggleServer = nil
                pendingPrivacyAccessServer = nil
            }
        ) {
            TVPrivacyUnlockSheet(
                title: pendingPrivacyToggleServer?.name ?? pendingPrivacyAccessServer?.name ?? platformShellString("Privacy Space"),
                isPresented: $isShowingPrivacyUnlock
            )
        }
        .sheet(
            isPresented: $isShowingPrivacySetup,
            onDismiss: {
                pendingPrivacyAccessServer = nil
            }
        ) {
            TVPasswordSetupSheet(
                mode: .create,
                title: platformShellString("Privacy Space"),
                isPresented: $isShowingPrivacySetup,
                existingPasswordIsSimple: false,
                validateCurrentPassword: nil,
                onSave: { password in
                    let serverToOpen = pendingPrivacyAccessServer
                    securityService.setPrivacyPassword(password)
                    securityService.togglePrivacySpace(true)
                    _ = securityService.unlockPrivacySpace(with: password)
                    pendingPrivacyAccessServer = nil

                    if let serverToOpen {
                        DispatchQueue.main.async {
                            connectAndOpen(serverToOpen)
                        }
                    }
                }
            )
        }
        .id("TVServersRootView_\(appLanguage)")
    }



    private var serverHeaderActions: some View {
        HStack(spacing: 14) {
            Button(action: {
                isShowingAddServer = true
            }) {
                TVHeaderIconActionButton(
                    title: platformShellString("Add Server"),
                    systemImageName: "plus",
                    onFocusChange: { _, isFocused in
                        handleHeaderActionFocus(id: "add-server", title: platformShellString("Add Server"), isFocused: isFocused)
                    }
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()

            Button(action: {
                isShowingDiscovery = true
            }) {
                TVHeaderIconActionButton(
                    title: platformShellString("Discovered Servers"),
                    systemImageName: "dot.radiowaves.left.and.right",
                    onFocusChange: { _, isFocused in
                        handleHeaderActionFocus(id: "discovered-servers", title: platformShellString("Discovered Servers"), isFocused: isFocused)
                    }
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()

            if hasPrivateServers {
                Button(action: togglePrivacySpaceFromHeader) {
                    TVHeaderIconActionButton(
                        title: privacyHeaderActionTitle,
                        systemImageName: privacyHeaderActionIconName,
                        onFocusChange: { _, isFocused in
                            handleHeaderActionFocus(id: "privacy-space", title: privacyHeaderActionTitle, isFocused: isFocused)
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

            Button(action: {
                activeAlert = .clearServers
            }) {
                TVHeaderIconActionButton(
                    title: platformShellString("Clear Servers"),
                    systemImageName: "trash",
                    isDestructive: true,
                    onFocusChange: { _, isFocused in
                        handleHeaderActionFocus(id: "clear-servers", title: platformShellString("Clear Servers"), isFocused: isFocused, isDestructive: true)
                    }
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()

            let isServerAction = focusedHeaderAction?.id == "add-server" || focusedHeaderAction?.id == "discovered-servers" || focusedHeaderAction?.id == "privacy-space" || focusedHeaderAction?.id == "clear-servers"
            TVHeaderActionDescriptionText(
                text: isServerAction ? focusedHeaderAction?.title : nil,
                width: 360,
                isDestructive: focusedHeaderAction?.isDestructive ?? false
            )

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var iptvHeaderActions: some View {
        HStack(spacing: 14) {
            Button(action: {
                isShowingAddIPTV = true
            }) {
                TVHeaderIconActionButton(
                    title: platformShellString("Add IPTV"),
                    systemImageName: "plus",
                    onFocusChange: { _, isFocused in
                        handleHeaderActionFocus(id: "add-iptv", title: platformShellString("Add IPTV"), isFocused: isFocused)
                    }
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()

            if !visibleIPTVServers.isEmpty {
                Button(action: {
                    activeAlert = .clearIPTV
                }) {
                    TVHeaderIconActionButton(
                        title: platformShellString("Clear IPTV"),
                        systemImageName: "trash",
                        isDestructive: true,
                        onFocusChange: { _, isFocused in
                            handleHeaderActionFocus(id: "clear-iptv", title: platformShellString("Clear IPTV"), isFocused: isFocused, isDestructive: true)
                        }
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

            let isIPTVAction = focusedHeaderAction?.id == "add-iptv" || focusedHeaderAction?.id == "clear-iptv"
            TVHeaderActionDescriptionText(
                text: isIPTVAction ? focusedHeaderAction?.title : nil,
                width: 360,
                isDestructive: focusedHeaderAction?.isDestructive ?? false
            )

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handleHeaderActionFocus(id: String, title: String, isFocused: Bool, isDestructive: Bool = false) {
        if isFocused {
            focusedHeaderAction = TVHeaderActionFocus(id: id, title: title, isDestructive: isDestructive)
            return
        }

        if focusedHeaderAction?.id == id {
            focusedHeaderAction = nil
        }
    }

    private func togglePrivacySpaceFromHeader() {
        guard securityService.hasPrivacyPassword else {
            pendingPrivacyToggleServer = nil
            pendingPrivacyAccessServer = nil
            isShowingPrivacySetup = true
            return
        }

        if securityService.isPrivacySpaceUnlocked {
            securityService.lockPrivacySpace()
            return
        }

        pendingPrivacyToggleServer = nil
        pendingPrivacyAccessServer = nil
        isShowingPrivacyUnlock = true
    }

    @ViewBuilder
    private func tvServerEntry(for server: ServerConfig) -> some View {
        let isReorderingThisServer = reorderingServer?.id == server.id
        let isAnyReordering = reorderingServer != nil
        let card = TVServerCard(
            server: server,
            showsPrivacyBadge: showsPrivacyBadge(for: server),
            privacyBadgeSystemName: privacyBadgeSystemName(for: server),
            isConnecting: connectingServerID == server.id || (server.type == .iptv ? iptvService.loadingServers.contains(server.id) : mediaSummaryService.loadingServers.contains(server.id))
        )
        .onAppear {
            refreshVODSummaryIfNeeded(for: server)
        }
        .onChange(of: server.vodSources) { _ in refreshVODSummaryIfNeeded(for: server) }
        .overlay(
            Group {
                if isReorderingThisServer {
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .strokeBorder(Color.blue, lineWidth: 4.5)
                            .shadow(color: Color.blue.opacity(0.7), radius: 14)
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(Color.white.opacity(0.85), lineWidth: 1.5)
                            )

                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                                .font(.system(size: 13, weight: .bold))
                            Text(platformShellString("Move"))
                                .font(.system(size: 13, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.blue)
                        .clipShape(Capsule())
                        .shadow(color: Color.black.opacity(0.35), radius: 4)
                        .padding(10)
                    }
                }
            }
        )
        .scaleEffect(isReorderingThisServer ? 1.06 : (isAnyReordering ? 0.96 : 1.0))
        .opacity(isAnyReordering && !isReorderingThisServer ? 0.65 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isReorderingThisServer)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: isAnyReordering)

        if isAnyReordering {
            card
                .allowsHitTesting(false)
        } else {
            Button(action: {
                handleServerPrimaryAction(server)
            }) {
                card
            }
            .buttonStyle(TVPlainButtonStyle())
            .focused($focusedServerID, equals: server.id)
            .tvDisableSystemFocusEffect()
            .contextMenu {
                tvServerManagementMenu(for: server)
            }
        }
    }

    private func refreshVODSummaryIfNeeded(for server: ServerConfig) {
        guard server.type == .vod else { return }
        Task { await server.refreshMobileVODSummaries() }
    }

    private func showsPrivacyBadge(for server: ServerConfig) -> Bool {
        guard privacySpaceService.isServerMarkedPrivate(server) else { return false }
        return securityService.isPrivacySpaceEnabled || !securityService.hasPrivacyPassword
    }

    private func privacyBadgeSystemName(for server: ServerConfig) -> String {
        guard securityService.hasPrivacyPassword else { return "lock" }
        return tvRequiresPrivacyAccess(server: server) ? "lock" : "lock.open"
    }

    private func handleServerPrimaryAction(_ server: ServerConfig) {
        if privacySpaceService.isServerMarkedPrivate(server),
           !securityService.hasPrivacyPassword {
            pendingPrivacyAccessServer = server
            isShowingPrivacySetup = true
            return
        }

        guard !tvRequiresPrivacyAccess(server: server) else {
            pendingPrivacyAccessServer = server
            isShowingPrivacyUnlock = true
            return
        }

        connectAndOpen(server)
    }

    private func connectAndOpen(_ server: ServerConfig) {
        let serverToConnect = networkService.servers.first(where: { $0.id == server.id }) ?? server
        connectionTask?.cancel()
        activeAlert = nil
        connectingServerID = server.id

        connectionTask = Task {
            do {
                let verifiedServer = try await tvTestServerConnectionWithTimeout(serverToConnect)
                if Task.isCancelled { return }

                await MainActor.run {
                    connectingServerID = nil
                    connectionTask = nil
                    if networkService.servers.contains(where: { $0.id == verifiedServer.id }) {
                        networkService.updateServer(verifiedServer)
                    }
                    openServer(verifiedServer)
                }
            } catch {
                if Task.isCancelled { return }

                await MainActor.run {
                    connectingServerID = nil
                    connectionTask = nil
                    activeAlert = .connectionFailure(server: serverToConnect, message: error.localizedDescription)
                }
            }
        }
    }

    private func openServer(_ server: ServerConfig) {
        networkService.recordServerAccess(server.id)
        TVStoredMediaPresentationManager.shared.server = server
    }

    @ViewBuilder
    private func tvServerManagementMenu(for server: ServerConfig) -> some View {
        Button(action: {
            handleServerPrimaryAction(server)
        }) {
            Label(
                platformShellString("Open"),
                systemImage: server.type == .iptv ? "play.circle" : "arrow.right.circle"
            )
        }

        let sectionServers = server.type == .iptv ? visibleIPTVServers : visibleRegularServers
        if sectionServers.count > 1 {
            Button(action: {
                withAnimation(.easeInOut(duration: 0.25)) {
                    reorderingServer = server
                    focusedServerID = server.id
                }
            }) {
                Label(platformShellString("Move"), systemImage: "arrow.up.and.down.and.arrow.left.and.right")
            }
        }

        if server.type == .iptv {
            Button(action: {
                Task {
                    _ = try? await IPTVService.shared.fetchPlaylist(for: server, forceRefresh: true)
                }
            }) {
                Label(platformShellString("Refresh Playlist"), systemImage: "arrow.clockwise")
            }
        } else if server.type.tvIsMediaLibraryServer {
            Button(action: {
                Task {
                    await MediaServerSummaryService.shared.refreshSummary(for: server)
                }
            }) {
                Label(platformShellString("Refresh Library"), systemImage: "arrow.clockwise")
            }
        }

        Button(action: {
            presentedServerEditor = server
        }) {
            Label(platformShellString("Edit Server"), systemImage: "slider.horizontal.3")
        }

        if server.type.tvSupportsConnectionTest {
            Button(action: {
                testConnection(for: server)
            }) {
                Label(platformShellString("Test Connection"), systemImage: testingServerID == server.id ? "hourglass" : "network")
            }
            .disabled(testingServerID == server.id)
        }

        if securityService.isPrivacySpaceEnabled {
            Button(action: {
                if privacySpaceService.isServerMarkedPrivate(server), !securityService.isPrivacySpaceUnlocked {
                    pendingPrivacyToggleServer = server
                    isShowingPrivacyUnlock = true
                } else {
                    _ = privacySpaceService.toggleServerMarkedPrivate(server)
                }
            }) {
                Label(
                    platformShellString(
                        privacySpaceService.isServerMarkedPrivate(server)
                            ? "Platform Shell TV Remove Server From Privacy Space"
                            : "Platform Shell TV Add Server To Privacy Space"
                    ),
                    systemImage: privacySpaceService.isServerMarkedPrivate(server) ? "lock.open" : "lock"
                )
            }
        }

        tvDestructiveContextMenuButton(
            title: platformShellString("Remove Server"),
            systemImageName: "trash"
        ) {
            activeAlert = .remove(server)
        }
    }

    private func handleServerMove(server: ServerConfig, direction: MoveCommandDirection) {
        let sectionServers = server.type == .iptv ? visibleIPTVServers : visibleRegularServers
        guard let currentIndex = sectionServers.firstIndex(where: { $0.id == server.id }) else { return }
        let columnsPerRow = TVServerCardMetrics.columnsPerRow
        let totalCount = sectionServers.count
        guard totalCount > 1 else { return }

        let currentRow = currentIndex / columnsPerRow
        let currentCol = currentIndex % columnsPerRow
        let totalRows = (totalCount + columnsPerRow - 1) / columnsPerRow

        let targetIndex: Int
        switch direction {
        case .left:
            targetIndex = currentIndex - 1
        case .right:
            targetIndex = currentIndex + 1
        case .up:
            guard currentRow > 0 else { return }
            targetIndex = (currentRow - 1) * columnsPerRow + currentCol
        case .down:
            guard currentRow < totalRows - 1 else { return }
            let idealTarget = (currentRow + 1) * columnsPerRow + currentCol
            targetIndex = min(idealTarget, totalCount - 1)
        default:
            return
        }

        guard targetIndex >= 0, targetIndex < totalCount, targetIndex != currentIndex else { return }
        let targetServer = sectionServers[targetIndex]

        guard let sourceGlobalIndex = networkService.savedServers.firstIndex(where: { $0.id == server.id }),
              let targetGlobalIndex = networkService.savedServers.firstIndex(where: { $0.id == targetServer.id }) else { return }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            networkService.savedServers.swapAt(sourceGlobalIndex, targetGlobalIndex)
            networkService.persistServers()
        }
    }

    private func moveServer(_ server: ServerConfig, offset: Int) {
        let sectionServers = server.type == .iptv ? visibleIPTVServers : visibleRegularServers
        guard let currentIndex = sectionServers.firstIndex(where: { $0.id == server.id }) else { return }
        let targetIndex = currentIndex + offset
        guard targetIndex >= 0 && targetIndex < sectionServers.count else { return }

        let targetServer = sectionServers[targetIndex]
        guard let sourceGlobalIndex = networkService.savedServers.firstIndex(where: { $0.id == server.id }),
              let targetGlobalIndex = networkService.savedServers.firstIndex(where: { $0.id == targetServer.id }) else { return }

        withAnimation(.easeInOut(duration: 0.25)) {
            networkService.savedServers.swapAt(sourceGlobalIndex, targetGlobalIndex)
            networkService.persistServers()
        }
    }

    private func moveServerToBoundary(_ server: ServerConfig, toTop: Bool) {
        let sectionServers = server.type == .iptv ? visibleIPTVServers : visibleRegularServers
        guard let currentIndex = sectionServers.firstIndex(where: { $0.id == server.id }) else { return }
        let targetServer = toTop ? sectionServers.first : sectionServers.last
        guard let targetServer, targetServer.id != server.id else { return }
        guard let sourceGlobalIndex = networkService.savedServers.firstIndex(where: { $0.id == server.id }),
              let targetGlobalIndex = networkService.savedServers.firstIndex(where: { $0.id == targetServer.id }) else { return }

        withAnimation(.easeInOut(duration: 0.25)) {
            let item = networkService.savedServers.remove(at: sourceGlobalIndex)
            networkService.savedServers.insert(item, at: targetGlobalIndex)
            networkService.persistServers()
        }
    }

    private func testConnection(for server: ServerConfig) {
        testingServerID = server.id
        activeAlert = nil
        testTask?.cancel()

        testTask = Task {
            do {
                let verifiedServer = try await withThrowingTaskGroup(of: ServerConfig.self) { group in
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

                let summary = tvServerSummary(for: verifiedServer)
                let message = tvHasText(summary) ? summary : verifiedServer.fullURL
                await MainActor.run {
                    testingServerID = nil
                    activeAlert = .result(
                        title: platformShellString("Connection Successful"),
                        message: message
                    )
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    testingServerID = nil
                    activeAlert = .result(
                        title: platformShellString("Connection Failed"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func tvServerDestination(for server: ServerConfig) -> some View {
        TVPrivacyProtectedContent(
            title: server.name,
            isProtected: tvRequiresPrivacyAccess(server: server)
        ) {
            tvServerHomeDestination(for: server)
        }
    }

    private func exitReordering() {
        withAnimation(.easeInOut(duration: 0.2)) {
            let targetID = reorderingServer?.id
            reorderingServer = nil
            isReorderingFocusActive = false
            focusedServerID = targetID
        }
    }
}



enum TVServerCardMetrics {
    static let contentWidth: CGFloat = 420
    static let horizontalPadding: CGFloat = 48
    static let outerWidth: CGFloat = contentWidth + horizontalPadding
    static let outerHeight: CGFloat = 144
    static let gridSpacing: CGFloat = 20
    static let columnsPerRow = 3
}

private struct TVServerGridSection<Content: View>: View {
    let title: String
    var headerAccessory: AnyView? = nil
    let servers: [ServerConfig]
    let content: (ServerConfig) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 14) {
                Text(title)
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.primary)

                if let headerAccessory {
                    headerAccessory
                }

                Spacer()
            }
            .padding(.horizontal, 2)
            .padding(.bottom, 4)
            .tvFocusSectionIfAvailable()

            TVFocusableRowGrid(
                items: servers,
                columnsPerRow: TVServerCardMetrics.columnsPerRow,
                columnWidth: TVServerCardMetrics.outerWidth,
                rowMinHeight: TVServerCardMetrics.outerHeight,
                columnSpacing: TVServerCardMetrics.gridSpacing,
                rowSpacing: 30,
                horizontalPadding: 22,
                verticalPadding: 24,
                content: content
            )
            .padding(.horizontal, -22)
        }
    }
}

private struct TVServerReorderingHUD: View {
    let server: ServerConfig

    var body: some View {
        HStack(spacing: 24) {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(platformShellString("Reorder Server"))
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)

                    Text("· \(server.name)")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(.white.opacity(0.85))
                        .lineLimit(1)
                }

                Text(platformShellString("Platform Shell TV Reorder Server Tip"))
                    .font(.system(size: 16))
                    .foregroundColor(.white.opacity(0.72))
            }

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 20)
        .frame(width: 860)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.black.opacity(0.92))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1.5)
                )
        )
        .shadow(color: Color.black.opacity(0.55), radius: 24, x: 0, y: 12)
        .padding(.bottom, 48)
    }
}
#endif
