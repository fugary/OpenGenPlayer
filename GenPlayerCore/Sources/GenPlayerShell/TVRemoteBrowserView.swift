#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


struct TVRemoteBrowserView: View {
    private static let viewModeDefaultsKey = "smbFileViewMode"

    let server: ServerConfig
    let rootTitle: String?
    let stackParentPath: String?
    let targetFilePath: String?

    @Environment(\.tvBrowsingNavigation) private var browsingNavigation
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.resetFocus) private var resetFocus
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var privacySpaceService = PrivacySpaceService.shared
    @ObservedObject private var securityService = TVSecurityService.shared
    private let playbackCoordinator = TVPlaybackCoordinator.shared
    @Namespace private var fileFocusNamespace
    @AppStorage("smbFileSortOption") private var sortOptionRaw = TVFileSortOption.name.rawValue
    @AppStorage("smbFileSortAscending") private var isSortAscending = true
    @AppStorage("smbFileFoldersOnTop") private var showsFoldersOnTop = true
    @AppStorage("tvRemoteBrowserGridLayout") private var isGridLayout: Bool = true
    @State private var path: String
    @State private var items: [VideoFile] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var didJumpToRootFolder = false
    @State private var focusedTargetFilePath: String?
    @State private var hasFocusedTargetFile = false
    @State private var isTestingConnection = false
    @State private var connectionAlert: TVTransientAlert?
    @State private var testTask: Task<Void, Never>?
    @State private var isShowingPrivacyUnlock = false
    @State private var pendingUnmarkRemotePath: String?
    @State private var pendingPrivatePlaybackFile: VideoFile?
    @State private var privacyUnlockTitle = platformShellString("Privacy Space")
    @State private var isShowingDownloads = false
    @State private var selectedFileForNavigation: VideoFile?

    private let onClose: (() -> Void)?

    init(
        server: ServerConfig,
        path: String,
        rootTitle: String?,
        stackParentPath: String? = nil,
        targetFilePath: String? = nil,
        onClose: (() -> Void)? = nil
    ) {
        self.server = server
        self.rootTitle = rootTitle
        self.stackParentPath = stackParentPath
        let resolvedTargetFilePath = targetFilePath.map(tvNormalizedRemotePath)
        self.targetFilePath = resolvedTargetFilePath
        _path = State(initialValue: tvNormalizedRemotePath(path))

        self.onClose = onClose
    }

    private var sortOption: TVFileSortOption {
        TVFileSortOption(rawValue: sortOptionRaw) ?? .name
    }

    private var sortedVisibleItems: [VideoFile] {
        tvSortVideoFiles(
            visibleItems,
            option: sortOption,
            ascending: isSortAscending,
            foldersOnTop: showsFoldersOnTop
        )
    }

    private var groupedItems: [(type: VideoFile.FileType, items: [VideoFile])] {
        tvGroupedVideoFiles(
            sortedVisibleItems,
            option: sortOption,
            ascending: isSortAscending,
            foldersOnTop: showsFoldersOnTop
        )
    }

    private var contentSummary: String? {
        tvFileGroupSummary(for: groupedItems)
    }

    private var currentServer: ServerConfig {
        networkService.servers.first(where: { $0.id == server.id }) ?? server
    }

    private var visibleItems: [VideoFile] {
        _ = securityService.hideLockedItems
        _ = securityService.isPrivacySpaceUnlocked
        return items.filter { file in
            !shouldHideHiddenRemoteBrowserItem(file) &&
            !tvShouldHidePrivateFile(file)
        }
    }

    private var playableItems: [VideoFile] {
        sortedVisibleItems.filter { $0.type == .video || $0.type == .audio }
    }

    private var imageItems: [VideoFile] {
        sortedVisibleItems.filter { $0.type == .image }
    }

    private func shouldHideHiddenRemoteBrowserItem(_ file: VideoFile) -> Bool {
        let candidates = [
            file.name,
            file.url.lastPathComponent,
            URL(fileURLWithPath: file.remoteDownloadPath).lastPathComponent
        ]

        guard let name = candidates
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else {
            return false
        }

        return name.hasPrefix(".")
    }

    private var displayTitle: String {
        if path == "/" {
            return server.name
        }
        return tvDisplayName(forRemotePath: path)
    }

    private var breadcrumbSubtitle: String? {
        tvRemoteFolderBreadcrumb(serverName: server.name, path: path)
    }

    private var parentPath: String? {
        tvParentRemotePath(for: path)
    }

    private var parentFolderTitle: String {
        guard let parentPath, parentPath != "/" else { return server.name }
        return tvDisplayName(forRemotePath: parentPath)
    }

    private var requiresPrivacyAccess: Bool {
        tvRequiresPrivacyAccess(server: server, remotePath: path)
    }

    var body: some View {
        TVPageScrollView(
            title: displayTitle,
            subtitle: nil,
            handlesExitCommand: true,
            customExitCommand: handleRemoteExitCommand,
            showsTitle: false,
            topPadding: 26,
            scrollTargetID: focusedTargetFilePath,
            showsHomeAction: requiresPrivacyAccess && parentPath != nil,
            customHomeAction: { returnToRootFolder() },
            showsDownloadsAction: requiresPrivacyAccess
        ) {
            if requiresPrivacyAccess {
                TVPrivacyUnlockGate(title: displayTitle)
            } else {
                ZStack {
                    HStack(alignment: .center) {
                        TVServerIdentityPill(server: currentServer)
                        Spacer()
                        TVRemoteBrowserHeaderControls(
                            sortOptionRaw: $sortOptionRaw,
                            isAscending: $isSortAscending,
                            showsFoldersOnTop: $showsFoldersOnTop,
                            isGridLayout: $isGridLayout,
                            showsFileControls: !visibleItems.isEmpty,
                            showsHomeAction: parentPath != nil,
                            onRefresh: { loadContents() },
                            onHome: returnToRootFolder,
                            onDownloads: { isShowingDownloads = true },
                            onClose: path == "/" ? (onClose ?? { closeBrowserRoot() }) : nil
                        )
                    }
                    
                    VStack(alignment: .center, spacing: 6) {
                        Text(displayTitle)
                            .font(.system(size: 34, weight: .bold))
                            .foregroundColor(TVShellStyle.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)
                            .multilineTextAlignment(.center)
                        
                        if let contentSummary, !contentSummary.isEmpty {
                            Text(contentSummary)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(TVShellStyle.secondary)
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.bottom, 18)
                .tvFocusSectionIfAvailable()
                

                if parentPath != nil {
                    TVRemoteBrowserLocationBar(
                        pathText: breadcrumbSubtitle ?? server.name,
                        parentTitle: parentFolderTitle,
                        onParent: { _ = returnToParentFolder() }
                    )
                    .tvFocusSectionIfAvailable()
                }

                if isLoading {
                    TVLoadingCard()
                } else if let errorMessage {
                    remoteBrowserFailureContent(errorMessage)
                } else if visibleItems.isEmpty {
                    TVEmptyStateCard(
                        title: platformShellString("Platform Shell TV Folder Empty Title"),
                        message: platformShellString("Platform Shell TV Folder Empty Body"),
                        systemImageName: "folder"
                    )
                } else {
                    remoteBrowserFilesContent
                }
            }
        }
        .navigationTitle(Text(displayTitle))
        .focusScope(fileFocusNamespace)
        .sheet(isPresented: $isShowingPrivacyUnlock, onDismiss: {
            if TVSecurityService.shared.isPrivacySpaceUnlocked {
                handlePrivacyUnlockSuccess()
            }
        }) {
            TVPrivacyUnlockSheet(
                title: privacyUnlockTitle,
                isPresented: $isShowingPrivacyUnlock
            )
        }
        .onAppear {
            loadContents()
        }

        .onDisappear {
            testTask?.cancel()
            testTask = nil
        }
        .alert(item: $connectionAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(platformShellString("OK")))
            )
        }
        .background(remoteBrowserDownloadsNavigationLink)
        .background(programmaticFileNavigationLink)
    }

    private var remoteBrowserDownloadsNavigationLink: some View {
        NavigationLink(
            destination: TVDownloadsDetailView(),
            isActive: $isShowingDownloads
        ) {
            EmptyView()
        }
        .hidden()
    }

    private var programmaticFileNavigationLink: some View {
        NavigationLink(
            destination: Group {
                if let file = selectedFileForNavigation {
                    dynamicDestination(for: file)
                } else {
                    EmptyView()
                }
            },
            isActive: Binding(
                get: { selectedFileForNavigation != nil },
                set: { isActive in
                    if !isActive { selectedFileForNavigation = nil }
                }
            )
        ) {
            EmptyView()
        }
        .hidden()
    }

    @ViewBuilder
    private func dynamicDestination(for file: VideoFile) -> some View {
        switch file.type {
        case .folder:
            tvDestination(for: file)
        case .image:
            TVImagePreviewView(initialFile: file, files: imageItems, server: server)
        case .subtitle, .document, .unknown:
            if file.supportsTextPreview {
                TVFilePreviewView(file: file, server: server)
            } else {
                EmptyView()
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var remoteBrowserFilesContent: some View {
        if isGridLayout {
            TVFileGridSection(
                title: nil,
                subtitle: nil,
                itemType: .unknown,
                items: sortedVisibleItems
            ) { item in
                tvGridEntry(for: item)
            }
        } else {
            ForEach(Array(groupedItems.enumerated()), id: \.offset) { _, group in
                TVFileListSection(
                    title: tvMediaTypeTitle(for: group.type),
                    subtitle: nil,
                    items: group.items
                ) { item in
                    tvListEntry(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func remoteBrowserFailureContent(_ errorMessage: String) -> some View {
        if path == "/" {
            TVInfoPanel(
                title: platformShellString("Connection Failed"),
                message: errorMessage,
                systemImageName: "wifi.exclamationmark",
                kind: .error,
                tintColor: .red
            )

            TVCompactActionsRow {
                Button(action: { loadContents(force: true) }) {
                    TVCompactActionButton(
                        title: platformShellString("Retry"),
                        systemImageName: isLoading ? "hourglass" : "arrow.clockwise"
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .disabled(isLoading)

                NavigationLink(destination: TVServerEditorView(existingServer: currentServer, prefilledServer: nil)) {
                    TVCompactActionButton(
                        title: platformShellString("Edit Server"),
                        systemImageName: "slider.horizontal.3"
                    )
                }
                .buttonStyle(TVPlainButtonStyle())

                Button(action: testConnection) {
                    TVCompactActionButton(
                        title: platformShellString("Test Connection"),
                        systemImageName: isTestingConnection ? "hourglass" : "network"
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .disabled(isLoading || isTestingConnection)

                Button(action: dismissToServerList) {
                    TVCompactActionButton(
                        title: platformShellString("Saved Servers"),
                        systemImageName: "server.rack"
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
            }
        } else {
            TVFeedbackPanel(
                title: platformShellString("Platform Shell TV Remote Load Failed Title"),
                message: errorMessage,
                systemImageName: "wifi.exclamationmark",
                kind: .error,
                tintColor: .red,
                action: TVFeedbackPanelAction(
                    title: platformShellString("Retry"),
                    systemImageName: "arrow.clockwise",
                    action: { loadContents(force: true) }
                )
            )
        }
    }

    private func loadContents(force: Bool = false) {
        loadContents(force: force, at: path)
    }

    private func loadContents(force: Bool = false, at targetPath: String) {
        let targetPath = tvNormalizedRemotePath(targetPath)
        let serverToLoad = currentServer
        guard serverToLoad.type.tvSupportsFileBrowsing else { return }
        guard force || (!isLoading && items.isEmpty && errorMessage == nil) else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                let loaded = try await networkService.fetchContents(for: serverToLoad, at: targetPath)
                networkService.recordServerAccess(serverToLoad.id)
                await MainActor.run {
                    guard path == targetPath else { return }
                    items = sortVideoFiles(loaded)
                    isLoading = false
                    activateTargetFileFocusIfNeeded(loadedItems: items)
                }
            } catch {
                await MainActor.run {
                    guard path == targetPath else { return }
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }

    private func testConnection() {
        guard currentServer.type.tvSupportsConnectionTest else { return }
        isTestingConnection = true
        connectionAlert = nil
        testTask?.cancel()
        let serverToTest = currentServer

        testTask = Task {
            do {
                let verifiedServer = try await tvTestServerConnectionWithTimeout(serverToTest)
                if Task.isCancelled { return }

                let summary = tvServerSummary(for: verifiedServer)
                let message = tvHasText(summary) ? summary : verifiedServer.fullURL
                await MainActor.run {
                    if networkService.servers.contains(where: { $0.id == verifiedServer.id }) {
                        networkService.updateServer(verifiedServer)
                    }
                    isTestingConnection = false
                    connectionAlert = TVTransientAlert(
                        title: platformShellString("Connection Successful"),
                        message: message
                    )
                    loadContents(force: true)
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isTestingConnection = false
                    connectionAlert = TVTransientAlert(
                        title: platformShellString("Connection Failed"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    private func dismissToServerList() { closeBrowserRoot() }

    private func closeBrowserRoot() {
        if let browsingNavigation {
            browsingNavigation.back()
        } else {
            presentationMode.wrappedValue.dismiss()
        }
    }

    @ViewBuilder
    private func tvGridEntry(for file: VideoFile) -> some View {
        let fileFocusID = tvRemoteBrowserFocusID(for: file)
        let privacyBadgeSystemName = privacyBadgeSystemName(for: file)

        switch file.type {
        case .folder:
            Button(action: {
                selectedFileForNavigation = file
            }) {
                TVFileGridCard(file: file, server: server, privacyBadgeSystemName: privacyBadgeSystemName)
            }
            .id(fileFocusID)
            .prefersDefaultFocus(isTargetFile(file), in: fileFocusNamespace)
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
            .contextMenu {
                tvFileContextMenu(for: file)
            }

        case .video, .audio:
            Button(action: {
                playOrUnlock(file)
            }) {
                TVFileGridCard(file: file, server: server, privacyBadgeSystemName: privacyBadgeSystemName)
            }
            .id(fileFocusID)
            .prefersDefaultFocus(isTargetFile(file), in: fileFocusNamespace)
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
            .contextMenu {
                tvFileContextMenu(for: file)
            }

        case .image:
            Button(action: {
                selectedFileForNavigation = file
            }) {
                TVFileGridCard(file: file, server: server, privacyBadgeSystemName: privacyBadgeSystemName)
            }
            .id(fileFocusID)
            .prefersDefaultFocus(isTargetFile(file), in: fileFocusNamespace)
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
            .contextMenu {
                tvFileContextMenu(for: file)
            }

        case .subtitle, .document, .unknown:
            if file.supportsTextPreview {
                Button(action: {
                    selectedFileForNavigation = file
                }) {
                    TVFileGridCard(file: file, server: server, privacyBadgeSystemName: privacyBadgeSystemName)
                }
                .id(fileFocusID)
                .prefersDefaultFocus(isTargetFile(file), in: fileFocusNamespace)
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
                .contextMenu {
                    tvFileContextMenu(for: file)
                }
            } else {
                Button(action: { showUnsupportedPreviewAlert(for: file) }) {
                    TVFileGridCard(file: file, server: server, privacyBadgeSystemName: privacyBadgeSystemName)
                }
                .id(fileFocusID)
                .prefersDefaultFocus(isTargetFile(file), in: fileFocusNamespace)
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
                .contextMenu {
                    tvFileContextMenu(for: file)
                }
            }
        }
    }

    @ViewBuilder
    private func tvListEntry(for file: VideoFile) -> some View {
        let fileFocusID = tvRemoteBrowserFocusID(for: file)
        let privacyBadgeSystemName = privacyBadgeSystemName(for: file)
        switch file.type {
        case .folder:
            Button(action: {
                selectedFileForNavigation = file
            }) {
                TVBrowserRow(file: file, server: server, privacyBadgeSystemName: privacyBadgeSystemName)
            }
            .id(fileFocusID)
            .prefersDefaultFocus(isTargetFile(file), in: fileFocusNamespace)
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                tvFileContextMenu(for: file)
            }

        case .video, .audio:
            Button(action: {
                playOrUnlock(file)
            }) {
                TVBrowserRow(file: file, server: server, privacyBadgeSystemName: privacyBadgeSystemName)
            }
            .id(fileFocusID)
            .prefersDefaultFocus(isTargetFile(file), in: fileFocusNamespace)
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                tvFileContextMenu(for: file)
            }

        case .image:
            Button(action: {
                selectedFileForNavigation = file
            }) {
                TVBrowserRow(file: file, server: server, privacyBadgeSystemName: privacyBadgeSystemName)
            }
            .id(fileFocusID)
            .prefersDefaultFocus(isTargetFile(file), in: fileFocusNamespace)
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .contextMenu {
                tvFileContextMenu(for: file)
            }

        case .subtitle, .document, .unknown:
            if file.supportsTextPreview {
                Button(action: {
                    selectedFileForNavigation = file
                }) {
                    TVBrowserRow(file: file, server: server, privacyBadgeSystemName: privacyBadgeSystemName)
                }
                .id(fileFocusID)
                .prefersDefaultFocus(isTargetFile(file), in: fileFocusNamespace)
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    tvFileContextMenu(for: file)
                }
            } else {
                Button(action: { showUnsupportedPreviewAlert(for: file) }) {
                    TVBrowserRow(file: file, server: server, privacyBadgeSystemName: privacyBadgeSystemName)
                }
                .id(fileFocusID)
                .prefersDefaultFocus(isTargetFile(file), in: fileFocusNamespace)
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    tvFileContextMenu(for: file)
                }
            }
        }
    }

    @ViewBuilder
    private func tvFileContextMenu(for file: VideoFile) -> some View {
        Button(action: { toggleFavorite(file) }) {
            Label(
                platformShellString(isFavorite(file) ? "Remove Favorite" : "Add Favorite"),
                systemImage: isFavorite(file) ? "star.slash" : "star"
            )
        }

        if file.type != .folder {
            Button(action: { enqueueDownload(for: file) }) {
                Label(platformShellString("Download"), systemImage: "arrow.down.circle")
            }
            .disabled(isDownloadTracked(file))
        }

        if file.type == .folder && securityService.isPrivacySpaceEnabled {
            let targetPath = tvNormalizedRemotePath(file.remoteDownloadPath)
            let isDirectlyPrivate = privacySpaceService.isRemoteFolderDirectlyMarkedPrivate(server: server, path: targetPath)
            Button(action: {
                toggleRemoteFolderPrivacy(file)
            }) {
                Label(
                    platformShellString(
                        isDirectlyPrivate
                            ? "Platform Shell TV Remove Folder From Privacy Space"
                            : "Platform Shell TV Add Folder To Privacy Space"
                    ),
                    systemImage: isDirectlyPrivate ? "lock.open" : "lock"
                )
            }
        }
    }

    private func playablePlaylist(for file: VideoFile) -> [VideoFile] {
        sortedVisibleItems
            .filter { $0.type == file.type || $0.type == .subtitle }
            .map { tvPlayableFile(from: $0, downloadCenter: downloadCenter) ?? $0 }
    }

    private func tvRemoteBrowserFocusID(for file: VideoFile) -> String {
        tvNormalizedRemotePath(file.remoteDownloadPath)
    }

    private func privacyBadgeSystemName(for file: VideoFile) -> String? {
        guard file.type == .folder else {
            return nil
        }

        let isDirectlyPrivate = privacySpaceService.isRemoteFolderDirectlyMarkedPrivate(
            server: server,
            path: tvNormalizedRemotePath(file.remoteDownloadPath)
        )
        guard isDirectlyPrivate,
              securityService.isPrivacySpaceEnabled || !securityService.hasPrivacyPassword else {
            return nil
        }

        return securityService.hasPrivacyPassword && securityService.isPrivacySpaceUnlocked ? "lock.open" : "lock"
    }

    private func isTargetFile(_ file: VideoFile) -> Bool {
        guard let focusedTargetFilePath else { return false }
        let target = focusedTargetFilePath.lowercased().removingPercentEncoding ?? focusedTargetFilePath.lowercased()
        let fileID = tvRemoteBrowserFocusID(for: file).lowercased()
        let normalizedFileID = fileID.removingPercentEncoding ?? fileID
        if target == normalizedFileID {
            return true
        }
        let targetName = URL(string: target)?.lastPathComponent ?? URL(fileURLWithPath: target).lastPathComponent
        let fileName = URL(string: normalizedFileID)?.lastPathComponent ?? URL(fileURLWithPath: normalizedFileID).lastPathComponent
        return !targetName.isEmpty && targetName == fileName
    }

    private func activateTargetFileFocusIfNeeded(loadedItems: [VideoFile]) {
        guard !hasFocusedTargetFile,
              let targetFilePath else {
            return
        }

        let target = targetFilePath.lowercased().removingPercentEncoding ?? targetFilePath.lowercased()
        let match = loadedItems.first { file in
            let fileID = tvRemoteBrowserFocusID(for: file).lowercased()
            let normalizedFileID = fileID.removingPercentEncoding ?? fileID
            if target == normalizedFileID {
                return true
            }
            let targetName = URL(string: target)?.lastPathComponent ?? URL(fileURLWithPath: target).lastPathComponent
            let fileName = URL(string: normalizedFileID)?.lastPathComponent ?? URL(fileURLWithPath: normalizedFileID).lastPathComponent
            return !targetName.isEmpty && targetName == fileName
        }

        guard let matchedFile = match else { return }

        hasFocusedTargetFile = true
        focusedTargetFilePath = tvRemoteBrowserFocusID(for: matchedFile)
        requestTargetFileFocus()
    }

    private func requestTargetFileFocus() {
        for delay in [0.0, 0.12, 0.35, 0.70] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                resetFocus(in: fileFocusNamespace)
            }
        }
    }

    private func favoritePath(for file: VideoFile) -> String? {
        file.type == .folder ? tvNormalizedRemotePath(file.remoteDownloadPath) : nil
    }

    private func isFavorite(_ file: VideoFile) -> Bool {
        favoriteService.isFavorite(file: file, folderPath: favoritePath(for: file))
    }

    private func toggleFavorite(_ file: VideoFile) {
        favoriteService.toggleFavorite(file: file, folderPath: favoritePath(for: file))
    }

    private func playOrUnlock(_ file: VideoFile) {
        if tvRequiresPrivacyAccess(file: file) {
            pendingPrivatePlaybackFile = file
            privacyUnlockTitle = tvDisplayTitle(for: file)
            isShowingPrivacyUnlock = true
            return
        }

        startPlayback(file)
    }

    private func showUnsupportedPreviewAlert(for file: VideoFile) {
        connectionAlert = TVTransientAlert(
            title: platformShellString("Preview Not Available"),
            message: platformShellString("Platform Shell TV Preview Unsupported Body")
        )
    }

    private func toggleRemoteFolderPrivacy(_ file: VideoFile) {
        let targetPath = tvNormalizedRemotePath(file.remoteDownloadPath)
        let isDirectlyPrivate = privacySpaceService.isRemoteFolderDirectlyMarkedPrivate(server: server, path: targetPath)

        if isDirectlyPrivate,
           !securityService.isPrivacySpaceUnlocked {
            pendingUnmarkRemotePath = targetPath
            privacyUnlockTitle = tvDisplayTitle(for: file)
            isShowingPrivacyUnlock = true
            return
        }

        privacySpaceService.setRemoteFolderMarkedPrivate(!isDirectlyPrivate, server: server, path: targetPath)
    }

    private func handlePrivacyUnlockSuccess() {
        if let pendingUnmarkRemotePath {
            privacySpaceService.setRemoteFolderMarkedPrivate(false, server: server, path: pendingUnmarkRemotePath)
            self.pendingUnmarkRemotePath = nil
        }

        if let pendingPrivatePlaybackFile {
            self.pendingPrivatePlaybackFile = nil
            startPlayback(pendingPrivatePlaybackFile)
        }
    }

    private func startPlayback(_ file: VideoFile) {
        Task {
            let playbackFile: VideoFile
            if let localFile = tvPlayableFile(from: file, downloadCenter: downloadCenter) {
                playbackFile = localFile
            } else {
                playbackFile = (try? await networkService.resolvedPlaybackFile(file)) ?? file
            }
            await MainActor.run {
                playbackCoordinator.play(file: playbackFile, playlist: playablePlaylist(for: file))
            }
        }
    }

    private func isDownloadTracked(_ file: VideoFile) -> Bool {
        downloadCenter.taskStatus(serverId: server.id, remotePath: file.remoteDownloadPath) != nil
    }

    private func enqueueDownload(for file: VideoFile) {
        downloadCenter.enqueueDownload(
            server: server,
            remotePath: file.remoteDownloadPath,
            fileName: file.name,
            totalBytes: file.size > 0 ? file.size : nil,
            displayTitle: tvDisplayTitle(for: file)
        )
    }

    private func handleRemoteExitCommand() -> Bool {
        if path == "/", didJumpToRootFolder {
            didJumpToRootFolder = false
            if tvPopToRootNavigationIfPossible(in: browsingNavigation) {
                return true
            }
        }

        return returnToParentFolder()
    }

    @discardableResult
    private func returnToParentFolder() -> Bool {
        guard let parentPath else { return false }

        if stackParentPath == parentPath, tvPopNavigationIfPossible(in: browsingNavigation) {
            return true
        }

        path = parentPath
        items = []
        errorMessage = nil
        isLoading = false
        focusedTargetFilePath = nil
        loadContents(force: true, at: parentPath)
        return true
    }

    private func returnToRootFolder() {
        path = "/"
        didJumpToRootFolder = true
        items = []
        errorMessage = nil
        isLoading = false
        focusedTargetFilePath = nil
        loadContents(force: true, at: "/")
    }

    @ViewBuilder
    private func tvDestination(for file: VideoFile) -> some View {
        if file.type == .folder {
            TVRemoteBrowserView(
                server: server,
                path: file.url.path,
                rootTitle: tvDisplayTitle(for: file),
                stackParentPath: path,
                onClose: onClose
            )
        } else {
            TVMediaDetailView(file: file)
        }
    }
}



struct TVParentFolderRow: View {
    let title: String
    let subtitle: String

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var primaryColor: Color {
        TVRowFocusStyle.primary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var secondaryColor: Color {
        TVRowFocusStyle.secondary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(showsFocus ? Color.black.opacity(0.08) : TVShellStyle.accentSoft.opacity(0.16))

                Image(systemName: "arrow.up.left")
                    .font(.system(size: 25, weight: .bold))
                    .foregroundColor(showsFocus ? primaryColor : TVShellStyle.accentSoft)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(primaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(subtitle)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 24)

            Image(systemName: "chevron.left")
                .font(.headline.weight(.bold))
                .foregroundColor(secondaryColor)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 620, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(TVInteractiveRowSurfaceModifier())
    }
}



struct TVRemoteBrowserLocationBar: View {
    let pathText: String
    let parentTitle: String
    let onParent: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "location.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(TVShellStyle.secondary)

                Text(pathText)
                    .font(.system(size: 25, weight: .bold))
                    .foregroundColor(TVShellStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.72)
            }
            .padding(.horizontal, 18)
            .frame(height: 62)
            .frame(maxWidth: 760, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .fill(TVShellStyle.subtleFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(TVShellStyle.glassStroke, lineWidth: 1)
            )

            Button(action: onParent) {
                TVRemoteBrowserLocationButton(
                    title: parentTitle,
                    systemImageName: "arrow.up.left"
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
            
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}



struct TVRemoteBrowserSortControls: View {
    @Binding var sortOptionRaw: String
    @Binding var isAscending: Bool
    @Binding var showsFoldersOnTop: Bool

    private var sortOption: TVFileSortOption {
        TVFileSortOption(rawValue: sortOptionRaw) ?? .name
    }

    private var orderTitle: String {
        platformShellString(isAscending ? "Ascending" : "Descending")
    }

    private var summaryTitle: String {
        "\(sortOption.title) · \(orderTitle)"
    }

    private func selectSortOption(_ option: TVFileSortOption) {
        guard sortOptionRaw != option.rawValue else { return }
        sortOptionRaw = option.rawValue
        isAscending = option == .name
    }

    var body: some View {
        if #available(tvOS 17.0, *) {
            Menu {
                ForEach(TVFileSortOption.allCases) { option in
                    Button(action: { selectSortOption(option) }) {
                        HStack {
                            Text(option.title)
                            if sortOption == option {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }

                Divider()

                Button(action: { isAscending = true }) {
                    HStack {
                        Text(platformShellString("Ascending"))
                        if isAscending {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Button(action: { isAscending = false }) {
                    HStack {
                        Text(platformShellString("Descending"))
                        if !isAscending {
                            Image(systemName: "checkmark")
                        }
                    }
                }

                Divider()

                Button(action: { showsFoldersOnTop.toggle() }) {
                    HStack {
                        Text(platformShellString("Folder Top"))
                        if showsFoldersOnTop {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                TVTopChromeIconButton(
                    title: summaryTitle,
                    systemImageName: "line.3.horizontal.decrease.circle",
                    diameter: 66
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
        } else {
            NavigationLink(
                destination: TVRemoteBrowserSortView(
                    sortOptionRaw: $sortOptionRaw,
                    isAscending: $isAscending,
                    showsFoldersOnTop: $showsFoldersOnTop
                )
            ) {
                TVTopChromeIconButton(
                    title: summaryTitle,
                    systemImageName: "line.3.horizontal.decrease.circle",
                    diameter: 66
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
        }
    }
}



struct TVRemoteBrowserSortView: View {
    @Binding var sortOptionRaw: String
    @Binding var isAscending: Bool
    @Binding var showsFoldersOnTop: Bool

    private var sortOption: TVFileSortOption {
        TVFileSortOption(rawValue: sortOptionRaw) ?? .name
    }

    var body: some View {
        TVSettingsChoicePage(title: platformShellString("Sort")) {
            VStack(alignment: .leading, spacing: 28) {
                sortFieldSection
                sortOrderSection
                sortOptionsSection
            }
        }
    }

    private var sortFieldSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVSettingsSectionHeader(title: platformShellString("Sort By"))

            ForEach(TVFileSortOption.allCases) { option in
                Button(action: { selectSortOption(option) }) {
                    TVSettingsChoiceRow(
                        title: option.title,
                        subtitle: nil,
                        isSelected: sortOption == option
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
        }
    }

    private var sortOrderSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVSettingsSectionHeader(title: platformShellString("Sort Order"))

            Button(action: { isAscending = true }) {
                TVSettingsChoiceRow(
                    title: platformShellString("Ascending"),
                    subtitle: nil,
                    isSelected: isAscending
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()

            Button(action: { isAscending = false }) {
                TVSettingsChoiceRow(
                    title: platformShellString("Descending"),
                    subtitle: nil,
                    isSelected: !isAscending
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
        }
    }

    private var sortOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVSettingsSectionHeader(title: platformShellString("Sort"))

            Button(action: { showsFoldersOnTop.toggle() }) {
                TVSettingsChoiceRow(
                    title: platformShellString("Folder Top"),
                    subtitle: nil,
                    isSelected: showsFoldersOnTop
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
        }
    }

    private func selectSortOption(_ option: TVFileSortOption) {
        guard sortOptionRaw != option.rawValue else { return }
        sortOptionRaw = option.rawValue
        isAscending = option == .name
    }
}



struct TVRemoteBrowserLocationButton: View {
    let title: String
    let systemImageName: String

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var foregroundColor: Color {
        if showsFocus {
            return TVRowFocusStyle.primary(showsFocus: true, isEnabled: isEnabled, colorScheme: colorScheme)
        }
        return TVShellStyle.primary
    }

    private var focusFillColor: Color {
        TVRowFocusStyle.focusedFill(for: colorScheme)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImageName)
                .font(.system(size: 23, weight: .heavy))

            Text(title)
                .font(.system(size: 24, weight: .heavy))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .foregroundColor(foregroundColor)
        .padding(.horizontal, 18)
        .frame(minWidth: 150, maxWidth: 270, minHeight: 62)
        .contentShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .fill(showsFocus ? focusFillColor : TVShellStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 19, style: .continuous)
                .stroke(showsFocus ? Color.clear : TVShellStyle.separator, lineWidth: 1.1)
        )
        .overlay(TVFocusedBlockOverlay(cornerRadius: 19, showsFocus: showsFocus, outerLineWidth: 2.8, innerInset: 3))
        .scaleEffect(showsFocus ? 1.018 : 1.0)
        .shadow(
            color: showsFocus ? Color.black.opacity(0.20) : .clear,
            radius: showsFocus ? 12 : 0,
            x: 0,
            y: showsFocus ? 6 : 0
        )
        .modifier(TVFocusedCardLayerModifier())
        .animation(.easeOut(duration: 0.16), value: showsFocus)
        .tvDisableSystemFocusEffect()
    }
}



enum TVFileSortOption: String, CaseIterable, Identifiable {
    case name
    case date
    case size

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name:
            return platformShellString("Name")
        case .date:
            return platformShellString("Date")
        case .size:
            return platformShellString("Size")
        }
    }
}
#endif
