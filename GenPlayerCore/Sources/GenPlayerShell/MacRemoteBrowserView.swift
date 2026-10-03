#if os(macOS)
import SwiftUI
import AppKit
import GenPlayerCore

struct MacRemoteBrowserView: View {
    let server: ServerConfig
    
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
        @ObservedObject private var privacySpace = PrivacySpaceService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @State private var stack: [(path: String, name: String)] = []
    @State private var entries: [VideoFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @AppStorage("MacRemoteBrowserIsGrid") private var isGridView = true
    @AppStorage("smbFileSortOption") private var smbSortOptionRaw: String = "name"
    @AppStorage("smbFileSortAscending") private var isSMBSortAscending: Bool = true
    @AppStorage("smbFileFoldersOnTop") private var showsFoldersOnTop = true
    @AppStorage("allowRemoteMutationOperations") private var allowRemoteMutationOperations: Bool = false
    
    @State private var searchText: String = ""
    
    // File operation states
    @State private var isShowingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var isShowingRenameAlert = false
    @State private var renameTargetFile: VideoFile?
    @State private var renameInputName = ""
    @State private var isShowingDeleteAlert = false
    @State private var deleteTargetFile: VideoFile?
    
    // Preview states
    @State private var previewFile: VideoFile?
    @State private var previewURL: URL?
    @State private var isDownloadingPreview = false
    @State private var previewDownloadProgress: Double = 0.0
    @State private var previewRequestID: UUID?
    @State private var previewDownloadTask: Task<Void, Never>?
    @State private var previewWindowRequestID: UUID?
    
    // Download confirmation states
    @State private var isShowingDownloadConfirmation = false
    @State private var confirmDownloadFile: VideoFile?
    
    // Privacy unlock states
    @State private var isShowingPrivacyUnlock = false
    @State private var pendingPrivacyFolder: VideoFile?
    @State private var isShowingEditServerSheet = false
    
    var onExit: (() -> Void)? = nil
    
    private var currentServer: ServerConfig {
        networkService.savedServers.first(where: { $0.id == server.id }) ?? server
    }

    private var currentPath: String { stack.last?.path ?? "/" }
    private var currentName: String { currentServer.name }

    private var currentLocationRequiresPrivacyAccess: Bool {
        securityService.isPrivacySpaceEnabled &&
        !securityService.isPrivacySpaceUnlocked &&
        (privacySpace.isServerMarkedPrivate(currentServer) || privacySpace.isRemoteFolderMarkedPrivate(server: currentServer, path: currentPath))
    }

    private var displayEntries: [VideoFile] {
        var result = entries
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return result
    }

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    if !stack.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                MacBreadcrumbButton(action: {
                                    stack.removeAll()
                                    loadContents(at: "/")
                                }, isCurrent: false) {
                                    Image(systemName: "house")
                                }
                                
                                ForEach(Array(stack.enumerated()), id: \.offset) { index, component in
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundColor(.secondary.opacity(0.6))
                                    
                                    MacBreadcrumbButton(action: {
                                        stack.removeLast(stack.count - 1 - index)
                                        loadContents(at: stack.last?.path ?? "/")
                                    }, isCurrent: index == stack.count - 1) {
                                        Text(component.name)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .font(.callout)
                            .padding(.horizontal, 24)
                            .padding(.top, 12)
                            .padding(.bottom, 4)
                        }
                    } else if !currentPath.isEmpty && currentPath != "/" {
                        Text(currentPath)
                            .font(.callout)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 24)
                    }
                
                if isLoading && displayEntries.isEmpty {
                    Spacer()
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    Spacer()
                } else if let errorMessage = errorMessage, displayEntries.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.red)
                        Text(platformShellString("Unable to load this location"))
                            .font(.headline)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 12) {
                            Button(platformShellString("Retry")) {
                                loadContents(at: currentPath)
                            }
                            Button(platformShellString("Edit Server")) {
                                isShowingEditServerSheet = true
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if displayEntries.isEmpty {
                    HStack {
                        Spacer()
                        Text(platformShellString("Folder is empty"))
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    contentView
                }
            }
            }
            .disabled(currentLocationRequiresPrivacyAccess)
            .blur(radius: currentLocationRequiresPrivacyAccess ? 14 : 0)

            if currentLocationRequiresPrivacyAccess {
                macPrivacyProtectionOverlay(
                    title: stack.last?.name ?? currentServer.name,
                    onUnlock: { isShowingPrivacyUnlock = true }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .macServerToolbar(
            server: currentServer,
            title: currentName,
            canGoBack: !stack.isEmpty,
            searchText: $searchText,
            onBack: {
                _ = stack.popLast()
                loadContents(at: currentPath)
            },
            onHome: {
                stack.removeAll()
                loadContents(at: currentPath)
            },
            onExit: {
                onExit?()
            }
        ) {
            HStack(spacing: 6) {
                MacToolbarButton(
                    systemImage: isGridView ? "list.bullet" : "square.grid.2x2",
                    title: platformShellString("Toggle View"),
                    action: { isGridView.toggle() }
                )
                
                MacRemoteSortMenuPopover(
                    sortOptionRaw: $smbSortOptionRaw,
                    isSortAscending: $isSMBSortAscending,
                    showsFoldersOnTop: $showsFoldersOnTop,
                    updateSortField: updateSortField,
                    updateSortOrder: updateSortOrder,
                    updateFoldersOnTop: updateFoldersOnTop
                )

                MacToolbarButton(
                    systemImage: "arrow.clockwise",
                    title: platformShellString("Refresh"),
                    action: { loadContents(at: currentPath, isRefresh: true) }
                )
                .disabled(isLoading)

                if allowRemoteMutationOperations {
                    MacToolbarButton(
                        systemImage: "plus.rectangle.on.folder",
                        title: platformShellString("New Folder"),
                        action: {
                            newFolderName = ""
                            isShowingNewFolderAlert = true
                        }
                    )
                }
            }
        }
        .onChange(of: smbSortOptionRaw) { _ in applyRemoteSort() }
        .onChange(of: isSMBSortAscending) { _ in applyRemoteSort() }
        .onChange(of: showsFoldersOnTop) { _ in applyRemoteSort() }
        .onAppear {
            consumeTargetFileIfNeeded()
            if stack.isEmpty {
                loadContents(at: currentPath)
            }
        }
        .alert(platformShellString("New Folder"), isPresented: $isShowingNewFolderAlert) {
            TextField(platformShellString("Folder Name"), text: $newFolderName)
            Button(platformShellString("Create"), action: {
                if !newFolderName.isEmpty {
                    createFolder(name: newFolderName)
                }
            })
            Button(platformShellString("Cancel"), role: .cancel, action: {})
        }
        .alert(platformShellString("Rename"), isPresented: $isShowingRenameAlert) {
            TextField(platformShellString("New Name"), text: $renameInputName)
            Button(platformShellString("Rename"), action: {
                if let target = renameTargetFile, !renameInputName.isEmpty {
                    renameFile(target, newName: renameInputName)
                }
            })
            Button(platformShellString("Cancel"), role: .cancel, action: {})
        }
        .alert(platformShellString("Delete File"), isPresented: $isShowingDeleteAlert) {
            Button(platformShellString("Delete"), role: .destructive, action: {
                if let target = deleteTargetFile {
                    deleteFile(target)
                }
            })
            Button(platformShellString("Cancel"), role: .cancel, action: {})
        } message: {
            if let file = deleteTargetFile {
                Text(String(format: platformShellString("Are you sure you want to delete \"%@\"?"), file.name))
            }
        }
        .alert(platformShellString("Download File"), isPresented: $isShowingDownloadConfirmation) {
            Button(platformShellString("Download"), action: {
                if let file = confirmDownloadFile {
                    openRemoteFileLocally(file)
                }
            })
            Button(platformShellString("Cancel"), role: .cancel, action: {})
        } message: {
            if let file = confirmDownloadFile {
                Text(String(format: platformShellString("This file type may not be supported for preview. Do you want to download \"%@\" to open it?"), file.name))
            }
        }
        .onChange(of: server.id) { _ in
            stack.removeAll()
            entries.removeAll()
            consumeTargetFileIfNeeded()
            loadContents(at: currentPath)
        }
        .sheet(isPresented: $isShowingPrivacyUnlock) {
            MacPrivacySpaceUnlockView(isPresented: $isShowingPrivacyUnlock)
                .onDisappear {
                    if securityService.isPrivacySpaceUnlocked, let folder = pendingPrivacyFolder {
                        pendingPrivacyFolder = nil
                        handleSelection(folder)
                    } else {
                        pendingPrivacyFolder = nil
                    }
                }
        }
        .sheet(isPresented: $isShowingEditServerSheet) {
            MacServerEditorView(existingServer: currentServer, prefilledServer: nil)
        }
        .onChange(of: previewURL) { url in
            if let file = previewFile, let u = url {
                let imagePlaylist = displayEntries.filter { $0.type == .image }
                let currentIndex = imagePlaylist.firstIndex(where: { $0.id == file.id })
                
                let onPrevious: (() -> Void)? = (currentIndex != nil && currentIndex! > 0) ? {
                    let nextFile = imagePlaylist[currentIndex! - 1]
                    openRemoteFileLocally(nextFile, replacingPreviewURL: u)
                } : nil
                
                let onNext: (() -> Void)? = (currentIndex != nil && currentIndex! < imagePlaylist.count - 1) ? {
                    let nextFile = imagePlaylist[currentIndex! + 1]
                    openRemoteFileLocally(nextFile, replacingPreviewURL: u)
                } : nil
                
                MacPreviewWindowManager.shared.openPreview(url: u, file: file, onPrevious: onPrevious, onNext: onNext) {
                    cancelPreviewDownload()
                    previewURL = nil
                    previewFile = nil
                }
            } else if url == nil {
                MacPreviewWindowManager.shared.close()
            }
        }
        .overlay {
            if isDownloadingPreview && previewWindowRequestID == nil {
                ZStack {
                    Color.black.opacity(0.4).edgesIgnoringSafeArea(.all)
                    VStack(spacing: 16) {
                        ProgressView(platformShellString("Downloading..."), value: previewDownloadProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 200)
                        Button(platformShellString("Cancel")) {
                            cancelPreviewDownload()
                        }
                    }
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor)))
                }
            }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if isGridView {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 20)], spacing: 20) {
                    ForEach(displayEntries, id: \.id) { file in
                        gridItem(for: file)
                    }
                }
                .padding(20)
            }
        } else {
            List(displayEntries, id: \.id) { file in
                listItem(for: file)
            }
        }
    }
    
    @ViewBuilder
    private func gridItem(for file: VideoFile) -> some View {
        Button {
            handleSelection(file)
        } label: {
            MacFileGridItemCard(file: file, server: currentServer, markers: markers(for: file), siblingFiles: displayEntries)
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenuItems(for: file)
        }
    }
    
    @ViewBuilder
    private func listItem(for file: VideoFile) -> some View {
        Button {
            handleSelection(file)
        } label: {
            MacFileListItem(file: file, server: currentServer, markers: markers(for: file), siblingFiles: displayEntries)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenuItems(for: file)
        }
    }
    
    @ViewBuilder
    private func contextMenuItems(for file: VideoFile) -> some View {
        if file.type == .video || file.type == .audio {
            Button(platformShellString("Play")) {
                let playableFile = downloadCenter.localPlaybackFile(for: file) ?? file
                MacPlayerWindowManager.shared.openPlayer(for: playableFile, playlist: entries.isEmpty ? nil : entries)
            }
            Divider()
        }

        if file.type != .folder {
            Button(platformShellString(downloadActionTitle(for: file))) {
                guard !currentLocationRequiresPrivacyAccess else { return }
                downloadCenter.reconcileMissingLocalFiles()
                downloadCenter.enqueueDownload(
                    server: currentServer,
                    remotePath: file.remoteDownloadPath,
                    fileName: file.name,
                    totalBytes: file.size > 0 ? file.size : nil
                )
            }
            .disabled(isDownloadTracked(file) || currentLocationRequiresPrivacyAccess)
            Divider()
        }
        
        let favoritePath = file.serverPath ?? file.url.path
        let isFav = favoriteService.isFavorite(file: file, folderPath: favoritePath)
        Button(platformShellString(isFav ? "Remove from Favorites" : "Add to Favorites")) {
            favoriteService.toggleFavorite(file: file, folderPath: favoritePath)
        }
        Divider()
        
        if file.type == .folder && securityService.isPrivacySpaceEnabled {
            let path = file.serverPath ?? file.url.path
            Button(platformShellString(privacySpace.isRemoteFolderMarkedPrivate(server: currentServer, path: path) ? "Remove from Privacy Space" : "Add to Privacy Space")) {
                let nextValue = !privacySpace.isRemoteFolderMarkedPrivate(server: currentServer, path: path)
                privacySpace.setRemoteFolderMarkedPrivate(nextValue, server: currentServer, path: path)
            }
            Divider()
        }
        
        if allowRemoteMutationOperations {
            Button(platformShellString("Rename")) {
                renameTargetFile = file
                renameInputName = file.name
                isShowingRenameAlert = true
            }
            
            Button(platformShellString("Delete")) {
                deleteTargetFile = file
                isShowingDeleteAlert = true
            }
        }
    }

    private func handleSelection(_ file: VideoFile) {
        if file.type == .folder {
            // Privacy Space check: intercept navigation into protected folders
            let folderPath = file.serverPath ?? file.url.path
            if securityService.isPrivacySpaceEnabled &&
               !securityService.isPrivacySpaceUnlocked &&
               privacySpace.isRemoteFolderMarkedPrivate(server: currentServer, path: folderPath) {
                pendingPrivacyFolder = file
                isShowingPrivacyUnlock = true
                return
            }
            stack.append((path: file.url.path, name: file.name))
            loadContents(at: file.url.path)
        } else if file.type == .video || file.type == .audio {
            let playableFile = downloadCenter.localPlaybackFile(for: file) ?? file
            MacPlayerWindowManager.shared.openPlayer(for: playableFile, playlist: entries.isEmpty ? nil : entries)
        } else {
            if file.type == .image || file.supportsTextPreview {
                openRemoteFileLocally(file)
            } else {
                confirmDownloadFile = file
                isShowingDownloadConfirmation = true
            }
        }
    }

    private func isDownloadTracked(_ file: VideoFile) -> Bool {
        switch downloadCenter.taskStatus(serverId: currentServer.id, remotePath: file.remoteDownloadPath) {
        case .queued, .downloading, .paused: return true
        case .completed:
            return downloadCenter.isDownloaded(serverId: currentServer.id, remotePath: file.remoteDownloadPath)
        case .failed, .canceled, .none: return false
        }
    }

    private func downloadActionTitle(for file: VideoFile) -> String {
        switch downloadCenter.taskStatus(serverId: currentServer.id, remotePath: file.remoteDownloadPath) {
        case .queued: return "Queued"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .completed: return isDownloadTracked(file) ? "Downloaded" : "Retry"
        case .failed, .canceled: return "Retry"
        case .none: return "Download"
        }
    }

    private func cancelPreviewDownload() {
        previewRequestID = nil
        previewDownloadTask?.cancel()
        previewDownloadTask = nil
        if let windowRequestID = previewWindowRequestID {
            _ = MacPreviewWindowManager.shared.finishLoadingPreview(windowRequestID)
        }
        previewWindowRequestID = nil
        isDownloadingPreview = false
    }

    private func openRemoteFileLocally(_ file: VideoFile, replacingPreviewURL: URL? = nil) {
        let windowRequestID: UUID?
        if let replacingPreviewURL {
            guard let id = MacPreviewWindowManager.shared.beginLoadingPreview(replacing: replacingPreviewURL) else { return }
            windowRequestID = id
        } else {
            windowRequestID = nil
        }
        cancelPreviewDownload()
        let requestID = UUID()
        previewRequestID = requestID
        previewWindowRequestID = windowRequestID
        let remotePath = file.serverPath ?? file.url.path
        let activeServer = networkService.hydratedServer(from: currentServer)
        isDownloadingPreview = true
        previewDownloadProgress = 0.0
        previewDownloadTask = Task {
            do {
                let localURL = try await networkService.downloadFile(server: activeServer, at: remotePath) { downloaded, total in
                    DispatchQueue.main.async {
                        guard self.previewRequestID == requestID else { return }
                        self.previewDownloadProgress = total > 0 ? Double(downloaded) / Double(total) : 0
                    }
                }
                await MainActor.run {
                    guard self.previewRequestID == requestID else { return }
                    self.previewRequestID = nil
                    self.previewDownloadTask = nil
                    self.previewWindowRequestID = nil
                    self.isDownloadingPreview = false
                    if let windowRequestID {
                        guard MacPreviewWindowManager.shared.finishLoadingPreview(windowRequestID) else { return }
                    }
                    self.previewFile = file
                    self.previewURL = localURL
                }
            } catch {
                print("Failed to open file: \(error)")
                await MainActor.run {
                    guard self.previewRequestID == requestID else { return }
                    self.previewRequestID = nil
                    self.previewDownloadTask = nil
                    self.previewWindowRequestID = nil
                    self.isDownloadingPreview = false
                    if let windowRequestID {
                        _ = MacPreviewWindowManager.shared.finishLoadingPreview(windowRequestID, error: error.localizedDescription)
                    } else {
                        self.errorMessage = "Failed to download for preview: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    private func markers(for file: VideoFile) -> [String] {
        var result: [String] = []
        if favoriteService.isFavorite(file: file, folderPath: file.serverPath ?? file.url.path) {
            result.append("star.fill")
        }
        if file.type == .folder &&
            securityService.isPrivacySpaceEnabled {
            let path = file.serverPath ?? file.url.path
            if privacySpace.isRemoteFolderDirectlyMarkedPrivate(server: currentServer, path: path) {
                result.append(securityService.isPrivacySpaceUnlocked ? "lock.open.fill" : "lock.fill")
            }
        }
        if file.type != .folder {
            let remotePath = file.remoteDownloadPath
            if downloadCenter.isDownloaded(serverId: currentServer.id, remotePath: remotePath) {
                result.append("arrow.down.circle.fill")
            }
        }
        return result
    }

    // MARK: - Target File Navigation (from History/Favorites)

    private func consumeTargetFileIfNeeded() {
        guard let targetFile = MacNavigationManager.shared.targetFileToResolve else { return }
        // Only consume if this file belongs to our server
        var belongsHere = false
        if let serverId = targetFile.jellyfinServerId, currentServer.id.uuidString == serverId {
            belongsHere = true
        } else if let host = targetFile.url.host, currentServer.address.lowercased() == host.lowercased() {
            belongsHere = true
        }
        guard belongsHere else { return }
        MacNavigationManager.shared.targetFileToResolve = nil

        // For playable files, navigate to the parent folder and start playback
        // For folders, navigate into them
        let remotePath = targetFile.serverPath ?? targetFile.url.path
        let isFolder = targetFile.type == .folder
        let targetDirectory: String
        if isFolder {
            targetDirectory = remotePath
        } else {
            targetDirectory = (remotePath as NSString).deletingLastPathComponent
        }

        // Build the navigation stack from the target directory path
        if targetDirectory != "/" && !targetDirectory.isEmpty {
            let components = targetDirectory.split(separator: "/").map(String.init)
            var builtPath = ""
            var newStack: [(path: String, name: String)] = []
            for component in components {
                builtPath += "/" + component
                newStack.append((path: builtPath, name: component))
            }
            stack = newStack
            loadContents(at: targetDirectory)
        }
    }

    private func loadContents(at path: String, isRefresh: Bool = false) {
        isLoading = true
        errorMessage = nil
        if !isRefresh {
            entries = []
        }
        let activeServer = networkService.hydratedServer(from: currentServer)
        Task {
            do {
                let fetched = try await networkService.fetchContents(for: activeServer, at: path)
                await MainActor.run {
                    var sortedResult = fetched
                    self.sortFiles(&sortedResult)
                    self.entries = sortedResult
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    private func mediaIconName(for file: VideoFile) -> String {
        switch file.type {
        case .folder: return "folder.fill"
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .document: return "doc.text"
        default: return "doc"
        }
    }
    
    private func updateSortField(_ option: String) {
        if smbSortOptionRaw != option {
            smbSortOptionRaw = option
            isSMBSortAscending = option == "name"
            applyRemoteSort()
        }
    }

    private func updateSortOrder(_ ascending: Bool) {
        if isSMBSortAscending != ascending {
            isSMBSortAscending = ascending
            applyRemoteSort()
        }
    }

    private func updateFoldersOnTop(_ onTop: Bool) {
        if showsFoldersOnTop != onTop {
            showsFoldersOnTop = onTop
            applyRemoteSort()
        }
    }

    private func applyRemoteSort() {
        var sortedFiles = entries
        sortFiles(&sortedFiles)
        entries = sortedFiles
    }

    private func sortFiles(_ filesToSort: inout [VideoFile]) {
         filesToSort.sort { file1, file2 in
            if showsFoldersOnTop {
                if file1.type == .folder && file2.type != .folder { return true }
                if file1.type != .folder && file2.type == .folder { return false }
            }
            
            switch smbSortOptionRaw {
            case "name":
                let result = file1.name.localizedStandardCompare(file2.name)
                return isSMBSortAscending ? (result == .orderedAscending) : (result == .orderedDescending)
            case "date":
                return isSMBSortAscending ? (file1.date < file2.date) : (file1.date > file2.date)
            case "size":
                return isSMBSortAscending ? (file1.size < file2.size) : (file1.size > file2.size)
            default:
                let result = file1.name.localizedStandardCompare(file2.name)
                return isSMBSortAscending ? (result == .orderedAscending) : (result == .orderedDescending)
            }
        }
    }
    
    // MARK: - File Operations
    
    private func createFolder(name: String) {
        let path = currentPath == "/" ? "/\(name)" : "\(currentPath)/\(name)"
        let activeServer = networkService.hydratedServer(from: currentServer)
        Task {
            do {
                try await networkService.createFolder(server: activeServer, at: path)
                loadContents(at: currentPath)
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }
    
    private func renameFile(_ file: VideoFile, newName: String) {
        let parentPath = currentPath == "/" ? "" : currentPath
        let fromPath = "\(parentPath)/\(file.name)"
        let toPath = "\(parentPath)/\(newName)"
        let activeServer = networkService.hydratedServer(from: currentServer)
        Task {
            do {
                try await networkService.moveFile(server: activeServer, fromPath: fromPath, toPath: toPath)
                loadContents(at: currentPath)
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }
    
    private func deleteFile(_ file: VideoFile) {
        let activeServer = networkService.hydratedServer(from: currentServer)
        let path = currentPath == "/" ? "/\(file.name)" : "\(currentPath)/\(file.name)"
        Task {
            do {
                try await networkService.deleteFile(server: activeServer, at: path)
                loadContents(at: currentPath)
            } catch {
                await MainActor.run { self.errorMessage = error.localizedDescription }
            }
        }
    }
}

struct MacRemoteSortMenuRow: View {
    let title: String
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 10) {
            if isSelected {
                Image(systemName: "checkmark")
                    .frame(width: 14, alignment: .leading)
            } else {
                Color.clear
                    .frame(width: 14, height: 14)
            }
            Text(title)
        }
    }
}

private struct MacRemoteSortMenuPopover: View {
    @Binding var sortOptionRaw: String
    @Binding var isSortAscending: Bool
    @Binding var showsFoldersOnTop: Bool
    var updateSortField: (String) -> Void
    var updateSortOrder: (Bool) -> Void
    var updateFoldersOnTop: (Bool) -> Void
    @State private var isPresented = false

    var body: some View {
        MacToolbarButton(
            systemImage: "line.3.horizontal.decrease.circle",
            title: platformShellString("Sort"),
            action: { isPresented.toggle() }
        )
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(platformShellString("Sort By"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                
                sortButton(title: platformShellString("Name"), option: "name")
                sortButton(title: platformShellString("Date Modified"), option: "date")
                sortButton(title: platformShellString("Size"), option: "size")
                
                Divider()
                
                Text(platformShellString("Order"))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                
                orderButton(title: platformShellString("Ascending"), ascending: true)
                orderButton(title: platformShellString("Descending"), ascending: false)
                
                Divider()
                
                MacRemoteSortPopoverRow(title: platformShellString("Folders on Top"), isSelected: showsFoldersOnTop) {
                    updateFoldersOnTop(!showsFoldersOnTop)
                    isPresented = false
                }
            }
            .padding(8)
            .frame(width: 170)
        }
    }
    
    @ViewBuilder
    private func sortButton(title: String, option: String) -> some View {
        MacRemoteSortPopoverRow(title: title, isSelected: sortOptionRaw == option) {
            updateSortField(option)
            isPresented = false
        }
    }
    
    @ViewBuilder
    private func orderButton(title: String, ascending: Bool) -> some View {
        MacRemoteSortPopoverRow(title: title, isSelected: isSortAscending == ascending) {
            updateSortOrder(ascending)
            isPresented = false
        }
    }
}

private struct MacRemoteSortPopoverRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false
    
    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : (isHovered ? Color.primary.opacity(0.05) : Color.clear))
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - macOS Privacy Protection Overlay

@ViewBuilder
func macPrivacyProtectionOverlay(title: String, onUnlock: @escaping () -> Void) -> some View {
    ZStack {
        Color(nsColor: .windowBackgroundColor)
            .opacity(0.94)

        VStack(spacing: 18) {
            Image(systemName: "lock.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundColor(.primary)

            VStack(spacing: 6) {
                Text(platformShellString("Privacy Space Locked"))
                    .font(.headline)
                    .multilineTextAlignment(.center)

                Text(
                    String(
                        format: platformShellString("Unlock Privacy Space to access \"%@\" and all protected content."),
                        title
                    )
                )
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            }

            Button(action: onUnlock) {
                Text(platformShellString("Unlock Privacy Space"))
                    .font(.body.weight(.semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .frame(minWidth: 220)
                    .background(Color.accentColor)
                    .cornerRadius(14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(18)
        .padding(.horizontal, 24)
    }
}
#endif
