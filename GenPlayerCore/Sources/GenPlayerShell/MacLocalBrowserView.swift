#if os(macOS)
import SwiftUI
import AppKit
import GenPlayerCore

public struct MacLocalBrowserView: View {
    @AppStorage("appLanguage") private var appLanguage: String = "system"
    @ObservedObject private var bookmarkService = MacLocalFolderBookmarkService.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    @ObservedObject private var navManager = MacNavigationManager.shared

    @State private var stack: [(path: String, name: String)] = []
    @State private var entries: [MacLocalBrowserEntry] = []
    @State private var isLoading = false
    @State private var isDropTargeted = false

    @AppStorage("MacLocalBrowserIsGrid") private var isGridView = true
    @AppStorage("MacLocalSortOption") private var localSortOptionRaw = "name"
    @AppStorage("MacLocalSortAscending") private var isLocalSortAscending = true
    @AppStorage("MacLocalFoldersOnTop") private var showLocalFoldersOnTop = true

    @State private var searchText: String = ""

    // Privacy unlock states
    @State private var isShowingPrivacyUnlock = false
    @State private var pendingPrivacyFolder: MacLocalBrowserEntry?

    // File operation states
    @State private var isShowingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var isShowingRenameAlert = false
    @State private var renameTargetFile: MacLocalBrowserEntry?
    @State private var renameInputName = ""
    @State private var isShowingDeleteAlert = false
    @State private var deleteTargetFile: VideoFile?

    enum DirectoryLoadState: Equatable {
        case idle
        case success
        case needsReauthorization(folder: MacAuthorizedFolder)
        case notFound
        case permissionDenied
    }

    @State private var directoryLoadState: DirectoryLoadState = .idle

    // Authorized folder management states
    @State private var isShowingRemoveFolderAlert = false
    @State private var removeTargetFolder: MacAuthorizedFolder?

    // Preview states
    @State private var previewFile: VideoFile?
    @State private var previewURL: URL?

    public init(url: URL? = nil) {
        if let url = url {
            _stack = State(initialValue: [(path: url.path, name: url.lastPathComponent)])
        }
    }

    private var isRoot: Bool {
        stack.isEmpty
    }

    private var currentPath: String {
        stack.last?.path ?? ""
    }

    private var currentName: String {
        if isRoot {
            return platformShellString("Local")
        }
        return stack.last?.name ?? platformShellString("Local")
    }

    private var currentSubtitle: String {
        if isRoot {
            return platformShellString("Local Files")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if currentPath.hasPrefix(home) {
            return "~" + currentPath.dropFirst(home.count)
        }
        return currentPath
    }

    private var currentLocationRequiresPrivacyAccess: Bool {
        securityService.isPrivacySpaceEnabled &&
        !securityService.isPrivacySpaceUnlocked &&
        !isRoot &&
        privacySpace.isLocalFolderMarkedPrivate(URL(fileURLWithPath: currentPath))
    }

    private var shouldHidePrivateItems: Bool {
        securityService.isPrivacySpaceEnabled &&
        securityService.hideLockedItems &&
        !securityService.isPrivacySpaceUnlocked
    }

    private var visibleAuthorizedFolders: [MacAuthorizedFolder] {
        bookmarkService.authorizedFolders.filter { folder in
            if shouldHidePrivateItems {
                let url = URL(fileURLWithPath: folder.path)
                if privacySpace.isLocalFolderMarkedPrivate(url) {
                    return false
                }
            }
            return true
        }
    }

    private var displayEntries: [MacLocalBrowserEntry] {
        let baseFiles = entries.filter { entry in
            let file = entry.file
            if shouldHidePrivateItems && file.type == .folder && privacySpace.isLocalFolderMarkedPrivate(file.url) {
                return false
            }
            return true
        }
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return baseFiles
        } else {
            return baseFiles.filter { $0.file.name.localizedCaseInsensitiveContains(searchText) }
        }
    }

    public var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 0) {
                // Breadcrumb path trail
                if !stack.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            MacBreadcrumbButton(action: {
                                stack.removeAll()
                                loadContents()
                            }, isCurrent: false) {
                                Image(systemName: "house")
                            }

                            ForEach(Array(stack.enumerated()), id: \.offset) { index, component in
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary.opacity(0.6))

                                MacBreadcrumbButton(action: {
                                    stack.removeLast(stack.count - 1 - index)
                                    loadContents()
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
                }

                // Main Content Area
                if isLoading && displayEntries.isEmpty {
                    Spacer()
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    Spacer()
                } else if displayEntries.isEmpty {
                    Spacer()
                    if case .needsReauthorization(let authFolder) = directoryLoadState {
                        VStack(spacing: 16) {
                            Image(systemName: "lock.trianglebadge.exclamationmark")
                                .font(.system(size: 48))
                                .foregroundColor(.orange)
                            Text(platformShellString("Folder Access Expired"))
                                .font(.title3.bold())
                                .foregroundColor(.primary)
                            Text(platformShellString("GenPlayer no longer has permission to access this folder. Please re-authorize access to continue."))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 420)
                            
                            Button(action: {
                                bookmarkService.promptReauthorizeFolder(authFolder) { _ in
                                    loadContents()
                                }
                            }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "key.fill")
                                    Text(platformShellString("Re-authorize Folder"))
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if case .notFound = directoryLoadState {
                        VStack(spacing: 16) {
                            Image(systemName: "folder.badge.questionmark")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary.opacity(0.6))
                            Text(platformShellString("Folder Not Found"))
                                .font(.title3.bold())
                                .foregroundColor(.primary)
                            Text(platformShellString("The folder could not be found at its original path."))
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "folder")
                                .font(.system(size: 48))
                                .foregroundColor(.secondary.opacity(0.4))
                            Text(platformShellString(entries.isEmpty ? "Folder is empty" : "No results found"))
                                .font(.headline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Spacer()
                } else {
                    fileListContentView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .disabled(currentLocationRequiresPrivacyAccess)
            .blur(radius: currentLocationRequiresPrivacyAccess ? 14 : 0)

            if currentLocationRequiresPrivacyAccess {
                macPrivacyProtectionOverlay(
                    title: currentName,
                    onUnlock: { isShowingPrivacyUnlock = true }
                )
            }
        }
        .macLocalToolbar(
            title: currentName,
            subtitle: currentSubtitle,
            canGoBack: !stack.isEmpty,
            searchText: $searchText,
            onBack: {
                _ = stack.popLast()
                loadContents()
            },
            onHome: {
                stack.removeAll()
                loadContents()
            }
        ) {
            HStack(spacing: 6) {
                // Grid / List Toggle
                MacToolbarButton(
                    systemImage: isGridView ? "list.bullet" : "square.grid.2x2",
                    title: platformShellString("Toggle View"),
                    action: { isGridView.toggle() }
                )

                // Sort Menu Popover
                MacLocalSortMenuPopover(
                    sortOptionRaw: $localSortOptionRaw,
                    isSortAscending: $isLocalSortAscending,
                    showsFoldersOnTop: $showLocalFoldersOnTop,
                    updateSortField: updateSortField,
                    updateSortOrder: updateSortOrder,
                    updateFoldersOnTop: toggleFoldersOnTop
                )

                // Refresh
                MacToolbarButton(
                    systemImage: "arrow.clockwise",
                    title: platformShellString("Refresh"),
                    action: { loadContents() }
                )
                .disabled(isLoading)

                if isRoot {
                    // Authorization adds an entry to the local root, not the current directory.
                    MacToolbarButton(
                        systemImage: "folder.badge.plus",
                        title: platformShellString("Add Local Folder")
                    ) {
                        bookmarkService.promptAddFolders { _ in
                            if isRoot {
                                loadContents()
                            }
                        }
                    }
                } else {
                    // Inside a directory, only offer creation in that directory.
                    MacToolbarButton(
                        systemImage: "plus.rectangle.on.folder",
                        title: platformShellString("New Folder")
                    ) {
                        newFolderName = ""
                        isShowingNewFolderAlert = true
                    }
                }
            }
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
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDropFolders(providers)
        }
        .onAppear {
            consumeNavigationTargetIfNeeded()
            loadContents()
        }
        .onChange(of: navManager.targetLocalFolderURL) { _ in
            consumeNavigationTargetIfNeeded()
        }
        .alert(platformShellString("New Folder"), isPresented: $isShowingNewFolderAlert) {
            TextField(platformShellString("Folder Name"), text: $newFolderName)
            Button(platformShellString("Create"), action: {
                if !newFolderName.isEmpty {
                    createDirectory(name: newFolderName)
                    loadContents()
                }
            })
            Button(platformShellString("Cancel"), role: .cancel, action: {})
        }
        .alert(platformShellString("Rename"), isPresented: $isShowingRenameAlert) {
            TextField(platformShellString("New Name"), text: $renameInputName)
            Button(platformShellString("Rename"), action: {
                if let target = renameTargetFile, !renameInputName.isEmpty {
                    if target.authorizedFolderID != nil {
                        // A removed/stale root entry must never become a disk rename.
                        if let authFolder = target.authorizedFolder(in: bookmarkService.authorizedFolders) {
                            bookmarkService.renameFolder(authFolder, newName: renameInputName)
                        }
                    } else {
                        renameFile(target.file, newName: renameInputName)
                    }
                    loadContents()
                }
            })
            Button(platformShellString("Cancel"), role: .cancel, action: {})
        }
        .alert(platformShellString("Delete File"), isPresented: $isShowingDeleteAlert) {
            Button(platformShellString("Delete"), role: .destructive, action: {
                if let target = deleteTargetFile {
                    deleteFile(target)
                    loadContents()
                }
            })
            Button(platformShellString("Cancel"), role: .cancel, action: {})
        } message: {
            if let file = deleteTargetFile {
                Text(String(format: platformShellString("Are you sure you want to delete \"%@\"?"), file.name))
            }
        }
        .alert(platformShellString("Remove Folder"), isPresented: $isShowingRemoveFolderAlert) {
            Button(platformShellString("Remove"), role: .destructive, action: {
                if let target = removeTargetFolder {
                    bookmarkService.removeFolder(target)
                    loadContents()
                }
            })
            Button(platformShellString("Cancel"), role: .cancel, action: {})
        } message: {
            if let folder = removeTargetFolder {
                Text(String(format: platformShellString("Remove \"%@\" from GenPlayer? The actual files on your disk will not be deleted."), folder.name))
            }
        }
        .onChange(of: previewURL) { url in
            if let file = previewFile, let u = url {
                let imagePlaylist = displayEntries.map(\.file).filter { $0.type == .image }
                let currentIndex = imagePlaylist.firstIndex(where: { $0.id == file.id })

                let onPrevious: (() -> Void)? = (currentIndex != nil && currentIndex! > 0) ? {
                    let nextFile = imagePlaylist[currentIndex! - 1]
                    previewFile = nextFile
                    previewURL = nextFile.url
                } : nil

                let onNext: (() -> Void)? = (currentIndex != nil && currentIndex! < imagePlaylist.count - 1) ? {
                    let nextFile = imagePlaylist[currentIndex! + 1]
                    previewFile = nextFile
                    previewURL = nextFile.url
                } : nil

                MacPreviewWindowManager.shared.openPreview(url: u, file: file, onPrevious: onPrevious, onNext: onNext) {
                    previewURL = nil
                    previewFile = nil
                }
            } else if url == nil {
                MacPreviewWindowManager.shared.close()
            }
        }
        .id("MacLocalBrowserView_\(appLanguage)")
    }

    // MARK: - Navigation Target Consumption

    private func consumeNavigationTargetIfNeeded() {
        guard let targetFolder = navManager.targetLocalFolderURL else { return }
        navManager.targetLocalFolderURL = nil

        let targetPath = targetFolder.resolvingSymlinksInPath().standardizedFileURL.path
        if let matchingAuth = bookmarkService.findMatchingAuthorizedFolder(for: targetFolder) {
            var newStack: [(path: String, name: String)] = []
            let rootURL = bookmarkService.resolveURL(for: matchingAuth).resolvingSymlinksInPath().standardizedFileURL
            newStack.append((path: rootURL.path, name: matchingAuth.name))

            if targetPath != rootURL.path && targetPath.hasPrefix(rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/") {
                let relative = String(targetPath.dropFirst(rootURL.path.count))
                let components = relative.split(separator: "/").map(String.init)
                var currentAccumulated = rootURL.path
                for comp in components {
                    currentAccumulated = (currentAccumulated as NSString).appendingPathComponent(comp)
                    newStack.append((path: currentAccumulated, name: comp))
                }
            }
            self.stack = newStack
        } else {
            // Unregistered path — add to bookmarks or push as direct stack
            if let added = bookmarkService.addFolder(url: targetFolder) {
                self.stack = [(path: bookmarkService.resolveURL(for: added).path, name: added.name)]
            } else {
                self.stack = [(path: targetFolder.path, name: targetFolder.lastPathComponent)]
            }
        }
        loadContents()
    }

    // MARK: - File List / Grid Content View

    @ViewBuilder
    private var fileListContentView: some View {
        let displayed = displayEntries
        let siblingFiles = displayed.map(\.file)
        if isGridView {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 20)], spacing: 20) {
                    ForEach(displayed) { entry in
                        gridItem(for: entry, siblingFiles: siblingFiles)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        } else {
            List(displayed) { entry in
                listItem(for: entry, siblingFiles: siblingFiles)
            }
            .padding(.horizontal, 16)
        }
    }

    private func markers(for entry: MacLocalBrowserEntry) -> [String] {
        let file = entry.file
        var result: [String] = []
        if favoriteService.isFavorite(file: file, folderPath: file.url.path) {
            result.append("star.fill")
        }
        if let authFolder = entry.authorizedFolder(in: bookmarkService.authorizedFolders) {
            let status = bookmarkService.checkAccessStatus(for: authFolder)
            if status != .accessible {
                result.append("exclamationmark.triangle.fill")
            }
        }
        if file.type == .folder && securityService.isPrivacySpaceEnabled {
            if privacySpace.isLocalFolderMarkedPrivate(file.url) {
                result.append(securityService.isPrivacySpaceUnlocked ? "lock.open.fill" : "lock.fill")
            }
        }
        return result
    }

    @ViewBuilder
    private func gridItem(for entry: MacLocalBrowserEntry, siblingFiles: [VideoFile]) -> some View {
        let file = entry.file
        Button {
            handleSelection(entry)
        } label: {
            MacFileGridItemCard(file: file, markers: markers(for: entry), siblingFiles: siblingFiles)
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenuItems(for: entry)
        }
    }

    @ViewBuilder
    private func listItem(for entry: MacLocalBrowserEntry, siblingFiles: [VideoFile]) -> some View {
        let file = entry.file
        Button {
            handleSelection(entry)
        } label: {
            MacFileListItem(file: file, markers: markers(for: entry), siblingFiles: siblingFiles)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            contextMenuItems(for: entry)
        }
    }

    @ViewBuilder
    private func contextMenuItems(for entry: MacLocalBrowserEntry) -> some View {
        let file = entry.file
        if file.type == .video || file.type == .audio {
            Button(platformShellString("Play")) {
                MacPlayerWindowManager.shared.openPlayer(for: file, playlist: entries.isEmpty ? nil : entries.map(\.file))
            }
            Divider()
        }

        let isFav = FavoriteService.shared.isFavorite(file: file, folderPath: file.url.path)
        Button(platformShellString(isFav ? "Remove from Favorites" : "Add to Favorites")) {
            FavoriteService.shared.toggleFavorite(file: file, folderPath: file.url.path)
        }
        Divider()

        if file.type == .folder && securityService.isPrivacySpaceEnabled {
            Button(platformShellString(privacySpace.isLocalFolderMarkedPrivate(file.url) ? "Remove from Privacy Space" : "Add to Privacy Space")) {
                let nextValue = !privacySpace.isLocalFolderMarkedPrivate(file.url)
                privacySpace.setLocalFolderMarkedPrivate(nextValue, for: file.url)
            }
            Divider()
        }

        Button(platformShellString("Rename")) {
            renameTargetFile = entry
            renameInputName = file.name
            isShowingRenameAlert = true
        }

        if isRoot {
            if let authFolder = entry.authorizedFolder(in: bookmarkService.authorizedFolders) {
                Button(platformShellString("Re-authorize Folder")) {
                    bookmarkService.promptReauthorizeFolder(authFolder) { _ in
                        loadContents()
                    }
                }
                Divider()

                Button(role: .destructive) {
                    removeTargetFolder = authFolder
                    isShowingRemoveFolderAlert = true
                } label: {
                    Text(platformShellString("Remove from GenPlayer"))
                }
            }
        } else {
            Button(platformShellString("Delete")) {
                deleteTargetFile = file
                isShowingDeleteAlert = true
            }
        }

        Divider()

        Button(platformShellString("Reveal in Finder")) {
            MacSharingService.revealInFinder(url: file.url)
        }

        if file.type != .folder {
            Button(platformShellString("Open in Another App")) {
                MacSharingService.openInAnotherApp(url: file.url)
            }

            Button(platformShellString("Share")) {
                MacSharingService.share(items: [file.url])
            }
        }
    }

    // MARK: - User Actions

    private func handleSelection(_ entry: MacLocalBrowserEntry) {
        let file = entry.file
        if entry.authorizedFolderID != nil && entry.authorizedFolder(in: bookmarkService.authorizedFolders) == nil {
            return
        }
        if file.type == .folder {
            if securityService.isPrivacySpaceEnabled && !securityService.isPrivacySpaceUnlocked && privacySpace.isLocalFolderMarkedPrivate(file.url) {
                pendingPrivacyFolder = entry
                isShowingPrivacyUnlock = true
                return
            }
            if let authFolder = entry.authorizedFolder(in: bookmarkService.authorizedFolders) {
                let status = bookmarkService.checkAccessStatus(for: authFolder)
                if status == .needsReauthorization {
                    bookmarkService.promptReauthorizeFolder(authFolder) { selectedURL in
                        stack.append((path: selectedURL.path, name: file.name))
                        loadContents()
                    }
                    return
                }
            }
            stack.append((path: file.url.path, name: file.name))
            loadContents()
        } else if file.type == .video || file.type == .audio {
            if securityService.isPrivacySpaceEnabled && !securityService.isPrivacySpaceUnlocked && privacySpace.isFileMarkedPrivate(file) {
                pendingPrivacyFolder = entry
                isShowingPrivacyUnlock = true
                return
            }
            bookmarkService.ensureAccess(for: file.url)
            MacPlayerWindowManager.shared.openPlayer(for: file, playlist: entries.isEmpty ? nil : entries.map(\.file))
        } else if file.canOpenInPreviewSheet || file.type == .image || file.supportsTextPreview {
            if securityService.isPrivacySpaceEnabled && !securityService.isPrivacySpaceUnlocked && privacySpace.isFileMarkedPrivate(file) {
                pendingPrivacyFolder = entry
                isShowingPrivacyUnlock = true
                return
            }
            bookmarkService.ensureAccess(for: file.url)
            previewFile = file
            previewURL = file.url
        } else {
            if securityService.isPrivacySpaceEnabled && !securityService.isPrivacySpaceUnlocked && privacySpace.isFileMarkedPrivate(file) {
                pendingPrivacyFolder = entry
                isShowingPrivacyUnlock = true
                return
            }
            bookmarkService.ensureAccess(for: file.url)
            NSWorkspace.shared.open(file.url)
        }
    }

    private func updateSortField(_ option: String) {
        if localSortOptionRaw != option {
            localSortOptionRaw = option
            isLocalSortAscending = option == "name"
            sortEntries()
        }
    }

    private func updateSortOrder(_ ascending: Bool) {
        if isLocalSortAscending != ascending {
            isLocalSortAscending = ascending
            sortEntries()
        }
    }

    private func toggleFoldersOnTop() {
        showLocalFoldersOnTop.toggle()
        sortEntries()
    }

    private func handleDropFolders(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url = url {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        DispatchQueue.main.async {
                            bookmarkService.addFolder(url: url)
                            if isRoot {
                                loadContents()
                            }
                        }
                    }
                }
            }
        }
        return true
    }

    // MARK: - Loading & File System Operations

    private func loadContents() {
        if isRoot {
            loadAuthorizedRootFolders()
        } else {
            loadDirectoryContents(at: URL(fileURLWithPath: currentPath))
        }
    }

    private func loadAuthorizedRootFolders() {
        let fileManager = FileManager.default
        var files: [MacLocalBrowserEntry] = []

        for folder in visibleAuthorizedFolders {
            let url = bookmarkService.resolveURL(for: folder)
            var count: Int? = nil
            if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                count = contents.count
            }

            let file = VideoFile(
                name: folder.name,
                url: url,
                type: .folder,
                size: 0,
                date: folder.dateAdded,
                isRemote: false,
                itemCount: count
            )
            files.append(MacLocalBrowserEntry(file: file, authorizedFolderID: folder.id))
        }

        self.entries = files
        self.directoryLoadState = .success
        sortEntries()
    }

    private func loadDirectoryContents(at directory: URL) {
        let fileManager = FileManager.default
        let matchingAuth = bookmarkService.findMatchingAuthorizedFolder(for: directory)
        if let matchingAuth {
            let status = bookmarkService.checkAccessStatus(for: matchingAuth)
            if status == .needsReauthorization {
                self.directoryLoadState = .needsReauthorization(folder: matchingAuth)
                self.entries = []
                return
            } else if status == .notFound {
                self.directoryLoadState = .notFound
                self.entries = []
                return
            }
        } else {
            bookmarkService.ensureAccess(for: directory)
        }

        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey, .contentModificationDateKey, .fileSizeKey]
        
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )

            var files = urls.compactMap { url -> VideoFile? in
                let resources = try? url.resourceValues(forKeys: Set(keys))
                let isDirectory = resources?.isDirectory ?? false
                let size = resources?.fileSize ?? 0
                let date = resources?.contentModificationDate ?? Date()
                let type: VideoFile.FileType = isDirectory ? .folder : VideoFile.FileType.determineType(from: url)

                var itemCount: Int? = nil
                if isDirectory {
                    if let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                        itemCount = contents.count
                    }
                }

                return VideoFile(
                    name: url.lastPathComponent,
                    url: url,
                    type: type,
                    size: Int64(size),
                    date: date,
                    isRemote: false,
                    itemCount: itemCount
                )
            }

            self.entries = files.map { MacLocalBrowserEntry(file: $0) }
            self.directoryLoadState = .success
            sortEntries()
        } catch {
            print("[MacLocalBrowserView] Error scanning directory \(directory.path): \(error)")
            if let matchingAuth {
                self.directoryLoadState = .needsReauthorization(folder: matchingAuth)
            } else {
                self.directoryLoadState = .permissionDenied
            }
            self.entries = []
        }
    }

    private func sortEntries() {
        var sorted = entries
        sorted.sort { entry1, entry2 in
            let file1 = entry1.file
            let file2 = entry2.file
            if showLocalFoldersOnTop {
                if file1.type == .folder && file2.type != .folder { return true }
                if file1.type != .folder && file2.type == .folder { return false }
            }

            switch localSortOptionRaw {
            case "name":
                let result = file1.name.localizedStandardCompare(file2.name)
                return isLocalSortAscending ? (result == .orderedAscending) : (result == .orderedDescending)
            case "date":
                return isLocalSortAscending ? (file1.date < file2.date) : (file1.date > file2.date)
            case "size":
                return isLocalSortAscending ? (file1.size < file2.size) : (file1.size > file2.size)
            default:
                let result = file1.name.localizedStandardCompare(file2.name)
                return isLocalSortAscending ? (result == .orderedAscending) : (result == .orderedDescending)
            }
        }
        self.entries = sorted
    }

    private func createDirectory(name: String) {
        guard !currentPath.isEmpty else { return }
        let parent = URL(fileURLWithPath: currentPath)
        let newDir = parent.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: newDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Failed to create folder: \(error)")
        }
    }

    private func renameFile(_ file: VideoFile, newName: String) {
        let newURL = file.url.deletingLastPathComponent().appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(at: file.url, to: newURL)
        } catch {
            print("Failed to rename file: \(error)")
        }
    }

    private func deleteFile(_ file: VideoFile) {
        do {
            try FileManager.default.removeItem(at: file.url)
        } catch {
            print("Failed to delete file: \(error)")
        }
    }
}

// MARK: - Mac Local Toolbar Modifier & Popovers

private struct MacLocalToolbarModifier<RightActions: View>: ViewModifier {
    let title: String
    var subtitle: String? = nil
    let canGoBack: Bool
    @Binding var searchText: String
    let onBack: () -> Void
    let onHome: () -> Void
    let rightActions: RightActions

    @State private var isSearchExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            Color.clear
                .frame(height: MacBrowserToolbarMetrics.totalHeight)
            content
                // Keep safe-area-ignoring backgrounds below the reserved toolbar.
                .clipped()
        }
        .ignoresSafeArea(.container, edges: .top)
        .overlay(alignment: .top) {
            headerOverlayView
                .frame(height: MacBrowserToolbarMetrics.rowHeight)
                .padding(.top, MacBrowserToolbarMetrics.topInset)
                .padding(.bottom, MacBrowserToolbarMetrics.bottomInset)
        }
        .onDisappear { isSearchExpanded = false }
    }

    @ViewBuilder
    private var headerOverlayView: some View {
        HStack(alignment: .center, spacing: 0) {
            // Left Navigation Actions (Back / Home)
            if canGoBack {
                HStack(spacing: 6) {
                    MacToolbarButton(
                        systemImage: "chevron.left",
                        title: platformShellString("Back"),
                        action: onBack
                    )

                    MacToolbarButton(
                        systemImage: "house",
                        title: platformShellString("Home"),
                        action: onHome
                    )
                }
                .padding(4)
                .modifier(MacToolbarGlass())
                .padding(.leading, 24)
                .anchorPreference(key: MacToolbarControlBoundsKey.self, value: .bounds) { [.leading: $0] }
            }

            Spacer(minLength: 16)

            // Right Actions (Search + View Mode/Sort/Refresh/Add Folder)
            HStack(spacing: 6) {
                MacExpandableToolbarSearch(text: $searchText, isExpanded: $isSearchExpanded)

                rightActions
            }
            .padding(4)
            .modifier(MacToolbarGlass())
            .padding(.trailing, 24)
            .anchorPreference(key: MacToolbarControlBoundsKey.self, value: .bounds) { [.trailing: $0] }
        }
        .frame(maxWidth: .infinity)
        .modifier(MacToolbarTitlePlacement(title: localInfoView))
        .padding(.vertical, 4)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: isSearchExpanded)
    }

    @ViewBuilder
    private var localInfoView: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.blue)
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .foregroundColor(.primary)

                HStack(spacing: 4) {
                    Text(platformShellString("Local"))
                        .font(.system(size: 11, weight: .semibold))
                    if let sub = subtitle, !sub.isEmpty {
                        Circle()
                            .fill(Color.secondary.opacity(0.42))
                            .frame(width: 2, height: 2)
                        Text(sub)
                            .font(.system(size: 11))
                            .truncationMode(.middle)
                            .lineLimit(1)
                    }
                }
                .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

private extension View {
    func macLocalToolbar<RightActions: View>(
        title: String,
        subtitle: String? = nil,
        canGoBack: Bool = false,
        searchText: Binding<String>,
        onBack: @escaping () -> Void = {},
        onHome: @escaping () -> Void = {},
        @ViewBuilder rightActions: () -> RightActions = { EmptyView() }
    ) -> some View {
        modifier(MacLocalToolbarModifier(
            title: title,
            subtitle: subtitle,
            canGoBack: canGoBack,
            searchText: searchText,
            onBack: onBack,
            onHome: onHome,
            rightActions: rightActions()
        ))
    }
}

// MARK: - Sort Popover Helper Components

private struct MacLocalSortMenuPopover: View {
    @Binding var sortOptionRaw: String
    @Binding var isSortAscending: Bool
    @Binding var showsFoldersOnTop: Bool
    var updateSortField: (String) -> Void
    var updateSortOrder: (Bool) -> Void
    var updateFoldersOnTop: () -> Void
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

                MacLocalSortPopoverRow(title: platformShellString("Folders on Top"), isSelected: showsFoldersOnTop) {
                    updateFoldersOnTop()
                    isPresented = false
                }
            }
            .padding(8)
            .frame(width: 170)
        }
    }

    @ViewBuilder
    private func sortButton(title: String, option: String) -> some View {
        MacLocalSortPopoverRow(title: title, isSelected: sortOptionRaw == option) {
            updateSortField(option)
            isPresented = false
        }
    }

    @ViewBuilder
    private func orderButton(title: String, ascending: Bool) -> some View {
        MacLocalSortPopoverRow(title: title, isSelected: isSortAscending == ascending) {
            updateSortOrder(ascending)
            isPresented = false
        }
    }
}

private struct MacLocalSortPopoverRow: View {
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
#endif
