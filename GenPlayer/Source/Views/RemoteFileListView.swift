import SwiftUI
import UniformTypeIdentifiers

/// Unified file list view for remote servers (SMB, WebDAV, etc.)
/// Replaces the need for separate views per protocol
@MainActor
struct RemoteFileListView: View {
    private let largeFolderPreviewThumbnailLimit = 180

    private enum DeleteConfirmationTarget: Identifiable {
        case single(VideoFile)
        case selection(fileIDs: [String])

        var id: String {
            switch self {
            case .single(let file):
                return "single-\(file.id)"
            case .selection(let fileIDs):
                return "selection-\(fileIDs.sorted().joined(separator: ","))"
            }
        }
    }

    let server: ServerConfig
    let path: String
    let networkService: AppNetworkService
    
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    @Environment(\.presentationMode) private var presentationMode
    @State private var files: [VideoFile] = []
    @State private var searchText = ""
    @State private var browserViewportHeight: CGFloat = 0
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    private var filteredFiles: [VideoFile] {
        if searchText.isEmpty {
            return files
        } else {
            return files.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
    }

    private var shouldHideLockedFolders: Bool {
        securityService.isPrivacySpaceEnabled &&
        securityService.hideLockedItems &&
        !securityService.isPrivacySpaceUnlocked
    }

    private var displayedFiles: [VideoFile] {
        filteredFiles.filter { file in
            if file.type != .folder { return true }
            return !shouldHideLockedFolders || !privacySpace.isRemoteFolderMarkedPrivate(server: server, path: resolvedPath(for: file))
        }
    }

    private var supportsMutationOperations: Bool {
        settings.canMutateRemoteFiles(on: server.type)
    }

    private var supportsSelectionActions: Bool {
        supportsLocalDownload || supportsMutationOperations
    }

    private var supportsLocalDownload: Bool {
        server.type.supportsRemoteFileDownload
    }

    private var supportsPreviewDownload: Bool {
        supportsLocalDownload
    }

    @State private var fullScreenFile: VideoFile?
    @State private var previewFile: VideoFile?
    @State private var audioSheetFile: VideoFile?
    @State private var audioPlaylist: [VideoFile]?
    
    // UI States
    @State private var isSelectionMode = false
    @State private var selectedFileIDs = Set<String>()
    @State private var isShowingFolderPicker = false
    @State private var moveErrorMessage: String?
    @State private var isShowingMoveError = false
    @State private var operationErrorTitle = NSLocalizedString("Operation Failed", comment: "")
    @State private var isShowingNewFolderAlert = false
    @State private var newFolderName = ""
    @State private var isShowingRenameAlert = false
    @State private var renameTargetFile: VideoFile?
    @State private var renameInputName = ""
    @State private var deleteConfirmationTarget: DeleteConfirmationTarget?
    @State private var singleMoveTargetFile: VideoFile?
    @State private var selectedFolderNavigationPath: String?
    @State private var downloadToastMessage: String?
    @State private var isShowingDownloadCenter = false
    @State private var isShowingPrivacyUnlock = false
    @State private var isShowingEditServer = false
    @State private var pendingPrivateFolderPath: String?
    @State private var pendingUnmarkFolderPrivacy: String?
    @State private var privacyActionMessage: String?
    @State private var infoSheetFile: VideoFile? = nil
    @ObservedObject private var dragState = DragStateManager.shared

    
    var targetFileIdToResolve: String? = nil
    
    #if os(tvOS)
    @FocusState private var focusedFileID: String?
    #endif
    
    var onExit: (() -> Void)? = nil
    
    init(server: ServerConfig, path: String = "/", networkService: AppNetworkService, targetFileIdToResolve: String? = nil, onExit: (() -> Void)? = nil) {
        self.server = server
        self.path = path
        self.networkService = networkService
        self.targetFileIdToResolve = targetFileIdToResolve
        self.onExit = onExit
    }
    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        let isCompact = horizontalSizeClass != .regular
        return [
            GridItem(.adaptive(minimum: isCompact ? 96 : 120), spacing: isCompact ? 12 : 16, alignment: .top)
        ]
    }

    private var shouldShowCurrentFolderDropTarget: Bool {
        supportsMutationOperations &&
        dragState.isDragging &&
        dragState.hasDragFromDifferentDirectory(currentPath: path)
    }

    private var currentLocationRequiresPrivacyAccess: Bool {
        securityService.isPrivacySpaceEnabled &&
        !securityService.isPrivacySpaceUnlocked &&
        (privacySpace.isServerMarkedPrivate(server) || privacySpace.isRemoteFolderMarkedPrivate(server: server, path: path))
    }

    private var navigationTitleDisplayMode: NavigationBarItem.TitleDisplayMode {
        .inline
    }

    private var navigationTitleText: String {
        path == "/" ? server.name : URL(fileURLWithPath: path).lastPathComponent
    }

    private var usesInlineSearchBar: Bool {
        if #available(iOS 15.0, *) {
            return false
        }
        return UIDevice.current.userInterfaceIdiom == .pad
    }

    private var selectedItems: [VideoFile] {
        files.filter { selectedFileIDs.contains($0.id) }
    }

    private var selectedDownloadableItems: [VideoFile] {
        selectedItems.filter { $0.type != .folder }
    }

    private var hasSelectedFolders: Bool {
        selectedItems.contains { $0.type == .folder }
    }

    private var canBatchDownloadSelection: Bool {
        supportsLocalDownload && !selectedDownloadableItems.isEmpty && !hasSelectedFolders
    }

    private var selectionHelperText: String? {
        if hasSelectedFolders {
            return NSLocalizedString("Folders can't be batch-downloaded yet.", comment: "")
        }
        return nil
    }
    
    var body: some View {
        let visibleFiles = displayedFiles
        let loadsPreviewThumbnails = visibleFiles.count <= largeFolderPreviewThumbnailLimit

        ZStack {
            folderNavigationLink

            VStack(spacing: 0) {
                if usesInlineSearchBar {
                    UnifiedSearchBar(text: $searchText, placeholder: NSLocalizedString("Search", comment: ""))
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }

                // Content View always in visual hierarchy for searchable stability
                Group {
                    if settings.isSMBGridLayout {
                        ScrollViewReader { scrollViewProxy in
                            ScrollView {
                                VStack(spacing: 0) {
                                    Group {
#if os(tvOS)
                                        TVFocusableRowGrid(
                                            data: visibleFiles,
                                            minimumItemWidth: 160,
                                            spacing: 32
                                        ) { file in
                                            gridItemView(for: file, loadsPreviewThumbnails: loadsPreviewThumbnails)
                                        }
#else
                                        LazyVGrid(columns: columns, spacing: 16) {
                                            ForEach(visibleFiles) { file in
                                                gridItemView(for: file, loadsPreviewThumbnails: loadsPreviewThumbnails)
                                            }
                                        }
#endif
                                    }
                                    .padding()
                                    
                                    // Fill remaining empty space in ScrollView
                                    if shouldShowCurrentFolderDropTarget {
                                        Color.clear
                                            .fileGridDropTargetFrame(viewportHeight: browserViewportHeight)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .top)
                                .contentShape(Rectangle())
#if os(iOS)
                                .onGridCurrentFolderDropTarget(isEnabled: shouldShowCurrentFolderDropTarget) { payload in
                                    handleDropPayloadToCurrentFolder(payload)
                                }
#else
                                .onCurrentFolderDropTarget { payload in
                                    if shouldShowCurrentFolderDropTarget {
                                        handleDropPayloadToCurrentFolder(payload)
                                    }
                                }
#endif
                            }
#if os(tvOS)
                            .onChange(of: focusedFileID) { targetId in
                                if let targetId = targetId {
                                    withAnimation {
                                        scrollViewProxy.scrollTo(targetId, anchor: .center)
                                    }
                                }
                            }
#endif
                        }
                        .refreshableCompat {
                            await loadContents()
                        }
                    } else {
                        ScrollViewReader { scrollViewProxy in
                            List {
                                ForEach(visibleFiles) { file in
                                    listItemView(for: file, loadsPreviewThumbnails: loadsPreviewThumbnails)
                                }
                                if shouldShowCurrentFolderDropTarget {
                                    if #available(iOS 15.0, *) {
                                        Color.clear
                                            .frame(height: 200)
                                            .listRowSeparator(.hidden)
                                            .listRowBackground(Color.clear)
                                            .listRowInsets(EdgeInsets())
                                            .onCurrentFolderDropTarget { payload in
                                                handleDropPayloadToCurrentFolder(payload)
                                            }
                                    } else {
                                        Color.clear
                                            .frame(height: 200)
                                            .listRowBackground(Color.clear)
                                            .listRowInsets(EdgeInsets())
                                            .onCurrentFolderDropTarget { payload in
                                                handleDropPayloadToCurrentFolder(payload)
                                            }
                                    }
                                }
                            }
#if os(tvOS)
                            .onChange(of: focusedFileID) { targetId in
                                if let targetId = targetId {
                                    withAnimation {
                                        scrollViewProxy.scrollTo(targetId, anchor: .center)
                                    }
                                }
                            }
#endif
                        }
                        .listStyle(PlainListStyle())
                        .refreshableCompat {
                            await loadContents()
                        }
                    }
                }
                .overlay(
                    Group {
                        if isLoading && files.isEmpty {
                            ProgressView(NSLocalizedString("Loading...", comment: ""))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(UIColor.systemBackground))
                        } else if let error = errorMessage, files.isEmpty && !isLoading {
                            errorOverlayView(error: error)
                        } else if files.isEmpty && !isLoading {
                            emptyFolderOverlayView
                        }
                    }
                )
                
                // Bottom Toolbar (Selection Mode)
                if isSelectionMode && supportsSelectionActions {
                    VStack(spacing: 8) {
                        Text(String(format: NSLocalizedString("%d Selected", comment: ""), selectedFileIDs.count))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if let helperText = selectionHelperText {
                            Text(helperText)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        HStack {
                            if supportsLocalDownload {
                                Button(action: {
                                    batchDownloadSelectedFiles()
                                }) {
                                    VStack {
                                        Image(systemName: "arrow.down.circle")
                                        Text(NSLocalizedString("Download", comment: ""))
                                            .font(.caption)
                                    }
                                }
                                .disabled(!canBatchDownloadSelection)
                                .foregroundColor(canBatchDownloadSelection ? Color(UIColor.systemBlue) : .gray)
                            }

                            if supportsLocalDownload && supportsMutationOperations {
                                Spacer()
                            }

                            if supportsMutationOperations {
                                Button(action: {
                                    isShowingFolderPicker = true
                                }) {
                                    VStack {
                                        Image(systemName: "folder")
                                        Text(NSLocalizedString("Move", comment: ""))
                                            .font(.caption)
                                    }
                                }
                                .disabled(selectedFileIDs.isEmpty)
                                .foregroundColor(selectedFileIDs.isEmpty ? .gray : .blue)

                                Spacer()

                                Button(action: {
                                    requestDeleteSelectedFiles()
                                }) {
                                    VStack {
                                        Image(systemName: "trash")
                                        Text(NSLocalizedString("Delete", comment: ""))
                                            .font(.caption)
                                    }
                                }
                                .disabled(selectedFileIDs.isEmpty)
                                .foregroundColor(selectedFileIDs.isEmpty ? .gray : .red)
                            }
                        }
                    }
                    .padding()
                    .background(Color(UIColor.systemBackground))
                    .shadow(radius: 2)
                }
            }
            .onHeightChange { browserViewportHeight = $0 }
            .navigationBarTitle(Text(""), displayMode: navigationTitleDisplayMode)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 6) {
                        ServerTypeIconMark(type: server.type, size: 18)
                        Text(navigationTitleText)
                            .lineLimit(1)
                    }
                }
            }
            .searchableCompat(
                text: $searchText,
                prompt: NSLocalizedString("Search", comment: ""),
                preferUIKitOnPad: true
            )
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    
                        if isSelectionMode {
                            Button(selectedFileIDs.count == visibleFiles.count && !visibleFiles.isEmpty ? NSLocalizedString("Clear", comment: "") : NSLocalizedString("Select All", comment: "")) {
                                if selectedFileIDs.count == visibleFiles.count && !visibleFiles.isEmpty {
                                    selectedFileIDs.removeAll()
                                } else {
                                    selectedFileIDs = Set(visibleFiles.map(\.id))
                                }
                            }
                        }
                        
                        if !isSelectionMode && path != "/" {
                            Button(action: { presentationMode.wrappedValue.dismiss() }) {
                                AppToolbarIcon(systemName: "chevron.left")
                            }
                            Button(action: { popToServerRoot() }) {
                                AppToolbarIcon(systemName: "house")
                            }
                        } else if !isSelectionMode && path == "/" {
                            Button(action: { onExit?() }) {
                                AppToolbarIcon.serverExit()
                            }
                        }
                    
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    
                        if isSelectionMode {
                            Button(NSLocalizedString("Done", comment: "")) {
                                isSelectionMode = false
                                selectedFileIDs.removeAll()
                            }
                        } else {
                            Button(action: {
                                settings.isSMBGridLayout.toggle()
                            }) {
                                AppToolbarIcon(systemName: settings.isSMBGridLayout ? "list.bullet" : "square.grid.2x2")
                            }

                            Menu {
                                Section(header: Text(NSLocalizedString("Sort By", comment: ""))) {
                                    ForEach(["name", "date", "size"], id: \.self) { option in
                                        Button(action: {
                                            updateRemoteSortField(option)
                                        }) {
                                            remoteSortMenuRow(
                                                title: remoteSortTitle(for: option),
                                                isSelected: settings.smbSortOptionRaw == option
                                            )
                                        }
                                    }
                                }

                                Section(header: Text(NSLocalizedString("Sort Order", comment: ""))) {
                                    Button(action: {
                                        updateRemoteSortOrder(true)
                                    }) {
                                        remoteSortMenuRow(
                                            title: NSLocalizedString("Ascending", comment: ""),
                                            isSelected: settings.isSMBSortAscending
                                        )
                                    }
                                    Button(action: {
                                        updateRemoteSortOrder(false)
                                    }) {
                                        remoteSortMenuRow(
                                            title: NSLocalizedString("Descending", comment: ""),
                                            isSelected: !settings.isSMBSortAscending
                                        )
                                    }
                                }
                            } label: {
                                AppToolbarIcon(systemName: "line.3.horizontal.decrease.circle")
                            }

                            if PlatformHelper.isRunningOnMac {
                                Button(action: {
                                    Task { await loadContents() }
                                }) {
                                    AppToolbarIcon(systemName: "arrow.clockwise")
                                }
                            }
                            
                            Menu {
                                if supportsSelectionActions {
                                    Button(action: {
                                        isSelectionMode = true
                                    }) {
                                        Label(NSLocalizedString("Select", comment: ""), systemImage: "checkmark.circle")
                                    }
                                }

                                if supportsMutationOperations {
                                    Button(action: {
                                        newFolderName = ""
                                        isShowingNewFolderAlert = true
                                    }) {
                                        Label(NSLocalizedString("New Folder", comment: ""), systemImage: "folder.badge.plus")
                                    }
                                }

                                Button(action: {
                                    isShowingDownloadCenter = true
                                }) {
                                    Label(NSLocalizedString("Downloads", comment: ""), systemImage: "arrow.down.circle")
                                }

                                Button(action: {
                                    Task { await loadContents() }
                                }) {
                                    Label(NSLocalizedString("Refresh", comment: ""), systemImage: "arrow.clockwise")
                                }
                            } label: {
                                AppToolbarIcon(systemName: "ellipsis.circle")
                            }
                        }
                    
                }
            }

            if isShowingNewFolderAlert {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { isShowingNewFolderAlert = false }
                CustomInputAlert(
                    title: NSLocalizedString("New Folder", comment: ""),
                    message: NSLocalizedString("Name your new folder", comment: ""),
                    text: $newFolderName,
                    onCancel: { isShowingNewFolderAlert = false },
                    onConfirm: { createFolder() }
                )
            }

            if isShowingRenameAlert {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { isShowingRenameAlert = false }
                CustomInputAlert(
                    title: NSLocalizedString("Rename", comment: ""),
                    message: NSLocalizedString("Enter a new name", comment: ""),
                    text: $renameInputName,
                    onCancel: {
                        isShowingRenameAlert = false
                        renameTargetFile = nil
                    },
                    onConfirm: { renameSelectedFile() }
                )
            }
        }
        .privacyProtectedContent(
            title: navigationTitleText,
            isProtected: currentLocationRequiresPrivacyAccess
        )
        .floatingToast(message: $downloadToastMessage)
        .onAppear {
            if files.isEmpty {
                Task {
                    await loadContents()
                }
            }
        }
        .onChange(of: settings.smbSortOptionRaw) { _ in 
            var currentFiles = files
            sortFiles(&currentFiles)
            files = currentFiles
        }
        .onChange(of: settings.isSMBSortAscending) { _ in 
            var currentFiles = files
            sortFiles(&currentFiles)
            files = currentFiles
        }
        .fullScreenCover(item: $fullScreenFile, onDismiss: {
            UIApplication.refreshInterfaceChrome()
        }) { file in
            fullScreenContent(for: file)
                .privacyProtectedContent(
                    title: file.name,
                    isProtected: requiresPrivacyAccess(for: file)
                )
        }
        .sheet(item: $audioSheetFile) { file in
            NavigationView {
                AudioPlayerView(initialFile: file, playlist: audioPlaylist ?? displayedFiles)
            }
            .navigationViewStyle(.stack)
            .privacyProtectedContent(
                title: file.name,
                isProtected: requiresPrivacyAccess(for: file)
            )
        }
        .sheet(item: $previewFile, onDismiss: { Task { await loadContents() } }) { file in
            previewSheetContent(for: file)
                .privacyProtectedContent(
                    title: file.name,
                    isProtected: requiresPrivacyAccess(for: file)
                )
        }
        .sheet(item: $infoSheetFile) { file in
            FileInfoSheet(file: file, serverName: server.name)
        }
        .background(
            NavigationLink(
                destination: DownloadCenterView(),
                isActive: $isShowingDownloadCenter,
                label: { EmptyView() }
            )
        )
        .sheet(isPresented: $isShowingFolderPicker) {
            RemoteFolderPickerView(
                server: server,
                initialPath: path,
                networkService: networkService,
                onMoveHere: { destinationPath in
                    if let target = singleMoveTargetFile {
                        performSingleMove(file: target, to: destinationPath)
                        singleMoveTargetFile = nil
                    } else {
                        performMove(to: destinationPath)
                    }
                    isShowingFolderPicker = false
                },
                onCancel: {
                    singleMoveTargetFile = nil
                    isShowingFolderPicker = false
                }
            )
        }
        .sheet(isPresented: $isShowingPrivacyUnlock, onDismiss: {
            if securityService.isPrivacySpaceUnlocked {
                if let path = pendingUnmarkFolderPrivacy {
                    privacySpace.setRemoteFolderMarkedPrivate(false, server: server, path: path)
                    pendingUnmarkFolderPrivacy = nil
                } else if let path = pendingPrivateFolderPath {
                    pendingPrivateFolderPath = nil
                    selectedFolderNavigationPath = path
                }
            } else {
                pendingUnmarkFolderPrivacy = nil
                pendingPrivateFolderPath = nil
            }
        }) {
            PrivacySpaceUnlockView(
                isPresented: $isShowingPrivacyUnlock,
                title: pendingPrivateFolderPath.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? pendingUnmarkFolderPrivacy.map { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? navigationTitleText
            )
        }
        .sheet(isPresented: $isShowingEditServer, onDismiss: {
            Task { await loadContents() }
        }) {
            editServerSheetContent
        }
        .alert(isPresented: $isShowingMoveError) {
            Alert(
                title: Text(operationErrorTitle),
                message: Text(moveErrorMessage ?? NSLocalizedString("Failed to move selected files.", comment: "")),
                dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
            )
        }
        .appErrorAlert(
            message: $errorMessage,
            title: NSLocalizedString("Couldn't load folder", comment: ""),
            retryTitle: NSLocalizedString("Retry", comment: ""),
            retryAction: {
                Task { await loadContents() }
            }
        )
        .appErrorAlert(
            message: $privacyActionMessage,
            title: NSLocalizedString("Privacy Space", comment: "")
        )
        .alert(item: $deleteConfirmationTarget) { target in
            switch target {
            case .single(let file):
                return Alert(
                    title: Text(NSLocalizedString("Delete File", comment: "")),
                    message: Text(String(format: NSLocalizedString("Are you sure you want to delete \"%@\"?", comment: ""), file.name)),
                    primaryButton: .destructive(Text(NSLocalizedString("Delete", comment: ""))) {
                        deleteFile(file)
                    },
                    secondaryButton: .cancel(Text(NSLocalizedString("Cancel", comment: "")))
                )
            case .selection(let fileIDs):
                return Alert(
                    title: Text(NSLocalizedString("Delete Files", comment: "")),
                    message: Text(NSLocalizedString("Are you sure you want to delete the selected files?", comment: "")),
                    primaryButton: .destructive(Text(NSLocalizedString("Delete", comment: ""))) {
                        deleteSelectedFiles(fileIDs: Set(fileIDs))
                    },
                    secondaryButton: .cancel(Text(NSLocalizedString("Cancel", comment: "")))
                )
            }
        }
        .edgeSwipeToDismiss(action: path == "/" ? onExit : nil)
        .if(path != "/") { $0.customBackButton() }
    }
    
    // MARK: - View Builders
    
    // Grid Item View
    @ViewBuilder
    private func gridItemView(for file: VideoFile, loadsPreviewThumbnails: Bool) -> some View {
        let isSelected = selectedFileIDs.contains(file.id)
        
        let content = Group {
            if isSelectionMode {
                Button(action: {
                    handleSelectionTap(file)
                }) {
                    FileGridItemView(file: file, isSelected: isSelected, isSelectionMode: isSelectionMode, markers: markers(for: file), loadsPreviewThumbnails: loadsPreviewThumbnails)
                }
                .buttonStyle(PlainButtonStyle())
            } else if file.type == .folder {
                Button(action: {
                    openFolder(file)
                }) {
                    FileGridItemView(file: file, isSelected: isSelected, isSelectionMode: isSelectionMode, markers: markers(for: file), loadsPreviewThumbnails: loadsPreviewThumbnails)
                }
                .buttonStyle(PlainButtonStyle())
                .contextMenu {
                    remoteContextMenu(for: file)
                }
            } else {
                Button(action: { openFile(file) }) {
                    FileGridItemView(file: file, isSelected: isSelected, isSelectionMode: isSelectionMode, markers: markers(for: file), loadsPreviewThumbnails: loadsPreviewThumbnails)
                }
                .buttonStyle(PlainButtonStyle())
                .contentShape(Rectangle())
                .contextMenu {
                    remoteContextMenu(for: file)
                }
            }
        }
        .applyIf(supportsMutationOperations) { view in
            view
                .nativeMultiDrag(file: file, isSelectionMode: isSelectionMode, selectedFileIDs: selectedFileIDs)
                .onFileDropTarget(file: file) { payload in
                    handleMutationDrop(payload, onto: file)
                }
        }
        
        #if os(tvOS)
        content.focused($focusedFileID, equals: file.id)
        #else
        content
        #endif
    }
    
    @ViewBuilder
    private func listItemView(for file: VideoFile, loadsPreviewThumbnails: Bool) -> some View {
        let baseRow = AnyView(
            Group {
                if isSelectionMode {
                    Button(action: {
                        handleSelectionTap(file)
                    }) {
                        listItemContent(for: file, loadsPreviewThumbnails: loadsPreviewThumbnails)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else if file.type == .folder {
                    Button(action: {
                        openFolder(file)
                    }) {
                        folderListButtonLabel(for: file, loadsPreviewThumbnails: loadsPreviewThumbnails)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contextMenu {
                        remoteContextMenu(for: file)
                    }
#if !os(iOS)
                    .applyIf(supportsMutationOperations) { view in
                        view.nativeListDropTarget(isFolder: true) { payload in
                            handleMutationDrop(payload, onto: file)
                        }
                    }
#endif
                } else {
                    Button(action: { openFile(file) }) {
                        HStack {
                            listItemContent(for: file, loadsPreviewThumbnails: loadsPreviewThumbnails)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Color(.tertiaryLabel))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                    .contextMenu {
                        remoteContextMenu(for: file)
                    }
                }
            }
            .contentShape(Rectangle())
            .applyIf(supportsMutationOperations) { view in
                view
                    .nativeMultiDrag(file: file, isSelectionMode: isSelectionMode, selectedFileIDs: selectedFileIDs)
#if os(iOS)
                    .nativeListDropTarget(isFolder: file.type == .folder) { payload in
                        handleMutationDrop(payload, onto: file)
                    }
#else
                    .onFileDropTarget(file: file) { payload in
                        handleMutationDrop(payload, onto: file)
                    }
#endif
            }
        )

        let content = Group {
            if #available(iOS 15.0, *) {
                baseRow
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                baseRow
            }
        }
        
        #if os(tvOS)
        content.focused($focusedFileID, equals: file.id)
        #else
        content
        #endif
    }

    @ViewBuilder
    private var folderNavigationLink: some View {
        NavigationLink(
            destination: folderNavigationDestination(),
            isActive: Binding(
                get: { selectedFolderNavigationPath != nil },
                set: { isActive in
                    if !isActive {
                        selectedFolderNavigationPath = nil
                    }
                }
            )
        ) {
            EmptyView()
        }
        .hidden()
    }

    @ViewBuilder
    private func folderNavigationDestination() -> some View {
        if let selectedFolderNavigationPath {
            RemoteFileListView(server: server, path: selectedFolderNavigationPath, networkService: networkService, onExit: self.onExit)
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private func folderListButtonLabel(for file: VideoFile, loadsPreviewThumbnails: Bool) -> some View {
        HStack {
            listItemContent(for: file, loadsPreviewThumbnails: loadsPreviewThumbnails)
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color(.tertiaryLabel))
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func listItemContent(for file: VideoFile, loadsPreviewThumbnails: Bool) -> some View {
        let isSelected = selectedFileIDs.contains(file.id)
        FileListItemView(file: file, isSelected: isSelected, isSelectionMode: isSelectionMode, markers: markers(for: file), loadsPreviewThumbnails: loadsPreviewThumbnails)
    }

    @ViewBuilder
    private func remoteContextMenu(for file: VideoFile) -> some View {
        Button(action: { infoSheetFile = file }) {
            Label(NSLocalizedString("File Info", comment: ""), systemImage: "info.circle")
        }

        if supportsMutationOperations {

            Button(action: { beginRename(file) }) {
                Label(NSLocalizedString("Rename", comment: ""), systemImage: "pencil")
            }
            Button(action: { beginSingleMove(file) }) {
                Label(NSLocalizedString("Move", comment: ""), systemImage: "folder")
            }
        }

        Button(action: { toggleFavorite(file) }) {
            Label(
                isFavorite(file) ? NSLocalizedString("Remove Favorite", comment: "") : NSLocalizedString("Add Favorite", comment: ""),
                systemImage: isFavorite(file) ? "star.slash" : "star"
            )
        }

        if file.type == .folder && securityService.isPrivacySpaceEnabled {
            let targetPath = resolvedPath(for: file)
            let isDirectlyPrivate = privacySpace.isRemoteFolderDirectlyMarkedPrivate(server: server, path: targetPath)
            Button(action: {
                toggleRemoteFolderPrivacy(file)
            }) {
                Label(
                    isDirectlyPrivate
                        ? NSLocalizedString("Remove from Privacy Space", comment: "")
                        : NSLocalizedString("Add to Privacy Space", comment: ""),
                    systemImage: isDirectlyPrivate ? "lock.open" : "lock"
                )
            }
        }

        if file.type != .folder && supportsLocalDownload {
            Button(action: { saveFileToLocal(file) }) {
                Label(NSLocalizedString("Save to Local", comment: ""), systemImage: "square.and.arrow.down")
            }
        }

        if supportsMutationOperations {
            if #available(iOS 15.0, *) {
                Button(role: .destructive, action: { requestDelete(file) }) {
                    Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                }
            } else {
                Button(action: { requestDelete(file) }) {
                    Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
                }
            }
        }
    }

    @ViewBuilder
    private func errorOverlayView(error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundColor(.red)
            Text(NSLocalizedString("Couldn't load folder", comment: ""))
                .font(.headline)
            Text(error)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button(action: {
                    Task { await loadContents() }
                }) {
                    Text(NSLocalizedString("Retry", comment: ""))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(8)
                }
                Button(action: {
                    isShowingEditServer = true
                }) {
                    Text(NSLocalizedString("Edit Server", comment: ""))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .foregroundColor(.white)
                        .background(Color.accentColor)
                        .cornerRadius(8)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
    }

    @ViewBuilder
    private var emptyFolderOverlayView: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.questionmark")
                .font(.largeTitle)
                .foregroundColor(.secondary)
            Text(NSLocalizedString("Empty folder", comment: ""))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor.systemBackground))
    }

    @ViewBuilder
    private var editServerSheetContent: some View {
        if #available(iOS 16.0, *) {
            NavigationStack {
                AddServerView(networkService: networkService, existingServer: server)
            }
        } else {
            NavigationView {
                AddServerView(networkService: networkService, existingServer: server)
            }
            .navigationViewStyle(.stack)
        }
    }

    @ViewBuilder
    private func fullScreenContent(for file: VideoFile) -> some View {
        if file.type == .video {
            PlayerView(initialFile: file, playlist: displayedFiles)
        } else {
            Text(NSLocalizedString("Unsupported file type", comment: ""))
        }
    }
    
    @ViewBuilder
    private func previewSheetContent(for file: VideoFile) -> some View {
        PreviewSheetContainer {
            RemoteFilePreviewLoader(networkService: networkService, server: server, path: path, file: file, files: displayedFiles)
        }
    }
    
    private func openFile(_ file: VideoFile) {
        if file.type != .video && file.type != .audio {
            if !supportsPreviewDownload && file.isRemote {
                operationErrorTitle = NSLocalizedString("Unable to Open", comment: "")
                moveErrorMessage = NSLocalizedString("Preview is not supported for this server type yet.", comment: "")
                isShowingMoveError = true
            } else {
                previewFile = file
            }
            return
        }

        Task {
            do {
                let playbackFile = try await networkService.resolvedPlaybackFile(file)
                await MainActor.run {
                    if playbackFile.type == .video {
                        fullScreenFile = playbackFile
                    } else if playbackFile.type == .audio {
                        var playlist = displayedFiles.filter { $0.type == .audio }
                        if let index = playlist.firstIndex(where: { $0.id == playbackFile.id }) {
                            playlist[index] = playbackFile
                        }
                        audioPlaylist = playlist
                        audioSheetFile = playbackFile
                    }
                }
            } catch {
                await MainActor.run {
                    operationErrorTitle = NSLocalizedString("Unable to Play", comment: "")
                    moveErrorMessage = error.localizedDescription
                    isShowingMoveError = true
                }
            }
        }
    }

    private func openFolder(_ file: VideoFile) {
        guard file.type == .folder else { return }
        let targetPath = resolvedPath(for: file)
        guard !requiresPrivacyAccess(toRemoteFolderPath: targetPath) else {
            pendingPrivateFolderPath = targetPath
            isShowingPrivacyUnlock = true
            return
        }
        selectedFolderNavigationPath = targetPath
    }
    
    private func smartPlay() {
        if let video = displayedFiles.first(where: { $0.type == .video }) {
            fullScreenFile = video
        } else if let audio = displayedFiles.first(where: { $0.type == .audio }) {
            audioSheetFile = audio
        } else if let image = displayedFiles.first(where: { $0.type == .image }) {
            previewFile = image
        }
    }
    
    // MARK: - Logic
    
    private func loadContents() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let result = try await networkService.fetchContents(for: server, at: path)
            networkService.recordServerAccess(server.id)
            var newFiles = result
            sortFiles(&newFiles)
            files = newFiles
            
            #if os(tvOS)
            if let targetFileId = targetFileIdToResolve, !newFiles.isEmpty {
                try? await Task.sleep(nanoseconds: 100_000_000)
                focusedFileID = targetFileId
                targetFileIdToResolve = nil
            }
            #endif
            
            isLoading = false
        } catch {
            if isCancellation(error) {
                isLoading = false
                return
            }
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
    
    
    private func remoteSortTitle(for option: String) -> String {
        switch option {
        case "name": return NSLocalizedString("Name", comment: "")
        case "date": return NSLocalizedString("Date", comment: "")
        case "size": return NSLocalizedString("Size", comment: "")
        default: return NSLocalizedString("Name", comment: "")
        }
    }

    @ViewBuilder
    private func remoteSortMenuRow(title: String, isSelected: Bool) -> some View {
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

    private func updateRemoteSortField(_ option: String) {
        if settings.smbSortOptionRaw != option {
            settings.objectWillChange.send()
            settings.smbSortOptionRaw = option
            settings.isSMBSortAscending = option == "name"
            applyRemoteSort()
        }
    }

    private func updateRemoteSortOrder(_ ascending: Bool) {
        if settings.isSMBSortAscending != ascending {
            settings.objectWillChange.send()
            settings.isSMBSortAscending = ascending
            applyRemoteSort()
        }
    }

    private func applyRemoteSort() {
        var sortedFiles = files
        sortFiles(&sortedFiles)
        files = sortedFiles
    }

    private func sortFiles(_ filesToSort: inout [VideoFile]) {
         filesToSort.sort { file1, file2 in
            if file1.type == .folder && file2.type != .folder { return true }
            if file1.type != .folder && file2.type == .folder { return false }
            
            switch settings.smbSortOption {
            case .name:
                let result = file1.name.localizedStandardCompare(file2.name)
                return settings.isSMBSortAscending ? (result == .orderedAscending) : (result == .orderedDescending)
            case .date:
                return settings.isSMBSortAscending ? (file1.date < file2.date) : (file1.date > file2.date)
            case .size:
                return settings.isSMBSortAscending ? (file1.size < file2.size) : (file1.size > file2.size)
            }
        }
    }
    
    private func favoritePath(for file: VideoFile) -> String? {
        guard file.type == .folder else { return nil }
        return resolvedPath(for: file)
    }

    private func isFavorite(_ file: VideoFile) -> Bool {
        favoriteService.isFavorite(file: file, folderPath: favoritePath(for: file))
    }

    private func toggleFavorite(_ file: VideoFile) {
        favoriteService.toggleFavorite(file: file, folderPath: favoritePath(for: file))
    }

    private func markers(for file: VideoFile) -> [String] {
        var result: [String] = []
        if isFavorite(file) {
            result.append("star.fill")
        }
        if file.type == .folder &&
            securityService.isPrivacySpaceEnabled &&
            privacySpace.isRemoteFolderDirectlyMarkedPrivate(server: server, path: resolvedPath(for: file)) {
            result.append(securityService.isPrivacySpaceUnlocked ? "lock.open" : "lock")
        }
        if file.type != .folder {
            let remotePath = resolvedPath(for: file)
            if downloadCenter.isDownloaded(serverId: server.id, remotePath: remotePath) {
                result.append("arrow.down.circle.fill")
            }
        }
        return result
    }

    private func requiresPrivacyAccess(toRemoteFolderPath remotePath: String) -> Bool {
        securityService.isPrivacySpaceEnabled &&
        !securityService.isPrivacySpaceUnlocked &&
        (privacySpace.isServerMarkedPrivate(server) || privacySpace.isRemoteFolderMarkedPrivate(server: server, path: remotePath))
    }

    private func requiresPrivacyAccess(for file: VideoFile) -> Bool {
        securityService.isPrivacySpaceEnabled &&
        !securityService.isPrivacySpaceUnlocked &&
        privacySpace.isFileMarkedPrivate(file)
    }

    private func toggleRemoteFolderPrivacy(_ file: VideoFile) {
        guard securityService.hasPrivacyPassword else {
            privacyActionMessage = NSLocalizedString("Set up Privacy Space in Settings before locking items.", comment: "")
            return
        }

        let targetPath = resolvedPath(for: file)
        let isDirectlyPrivate = privacySpace.isRemoteFolderDirectlyMarkedPrivate(server: server, path: targetPath)

        if isDirectlyPrivate && !securityService.isPrivacySpaceUnlocked {
            pendingUnmarkFolderPrivacy = targetPath
            isShowingPrivacyUnlock = true
        } else {
            privacySpace.setRemoteFolderMarkedPrivate(!isDirectlyPrivate, server: server, path: targetPath)
        }
    }

    private func handleSelectionTap(_ file: VideoFile) {
        if selectedFileIDs.contains(file.id) {
            selectedFileIDs.remove(file.id)
        } else {
            selectedFileIDs.insert(file.id)
        }
    }

    private func handleMutationDrop(_ payload: String, onto file: VideoFile) {
        guard supportsMutationOperations else { return }
        let ids = payload.split(separator: "\n").map { String($0) }
        guard !ids.isEmpty else { return }

        let targetPath = resolvedPath(for: file)
        performBatchMove(sourcePaths: ids, to: targetPath)
    }
    
    private func handleDropPayloadToCurrentFolder(_ payload: String) {
        guard supportsMutationOperations else { return }
        let normalizePath: (String) -> String = { raw in
            var p = raw
            while p.count > 1 && p.hasSuffix("/") {
                p = String(p.dropLast())
            }
            return p
        }
        let sourcePaths = payload.split(separator: "\n").map(String.init)
        let validPaths = Array(Dictionary(
            sourcePaths
                .filter { sourcePath in
                    let normalizedSource = normalizePath(sourcePath)
                    let normalizedCurrent = normalizePath(path)
                    if normalizedSource == normalizedCurrent { return false }
                    let parent = normalizePath((sourcePath as NSString).deletingLastPathComponent)
                    return parent != normalizedCurrent
                }
                .map { (normalizePath($0), $0) },
            uniquingKeysWith: { first, _ in first }
        ).values)
        guard !validPaths.isEmpty else { return }
        performBatchMove(sourcePaths: validPaths, to: path)
    }
    
    private func deleteSelectedFiles(fileIDs: Set<String>? = nil) {
        guard supportsMutationOperations else { return }
        let targetIDs = fileIDs ?? selectedFileIDs
        let filesToDelete = files.filter { targetIDs.contains($0.id) }
        
        Task {
            for file in filesToDelete {
                await deleteFileAsync(file, refresh: false)
            }
            selectedFileIDs.removeAll()
            isSelectionMode = false
            await loadContents()
        }
    }

    private func batchDownloadSelectedFiles() {
        guard canBatchDownloadSelection else { return }
        let jobTitle = String(
            format: NSLocalizedString("Batch Download (%d items)", comment: ""),
            selectedDownloadableItems.count
        )
        let items = selectedDownloadableItems.enumerated().map { index, file in
            DownloadRemoteFileBatchItem(
                remotePath: resolvedPath(for: file),
                fileName: file.name,
                displayTitle: file.name,
                totalBytes: file.size > 0 ? file.size : nil,
                groupIndex: index
            )
        }
        let job = DownloadJobDescriptor(
            kind: .fileBatch,
            sourceType: DownloadSourceType(serverType: server.type),
            title: jobTitle,
            groupTitle: jobTitle
        )
        let enqueuedCount = downloadCenter.enqueueRemoteFileBatch(server: server, items: items, job: job)
        if enqueuedCount > 0 {
            downloadToastMessage = String(
                format: NSLocalizedString("Added %d items to Download Queue", comment: ""),
                enqueuedCount
            )
        } else {
            downloadToastMessage = NSLocalizedString("Already in Download Queue", comment: "")
        }
        selectedFileIDs.removeAll()
        isSelectionMode = false
    }
    
    private func performBatchMove(sourcePaths: [String], to destinationPath: String) {
        guard supportsMutationOperations else { return }
        DragStateManager.shared.endDrag()
        Task {
            var firstError: String?
            
            for sourcePath in sourcePaths {
                let name = NSString(string: sourcePath).lastPathComponent
                let targetPath = joinPath(base: destinationPath, name: name)
                
                if sourcePath == targetPath {
                    continue
                }
                
                do {
                    try await networkService.moveFile(server: server, fromPath: sourcePath, toPath: targetPath)
                } catch {
                    if firstError == nil {
                        firstError = error.localizedDescription
                    }
                }
            }
            
            await MainActor.run {
                selectedFileIDs.removeAll()
                isSelectionMode = false
                if let errorMsg = firstError {
                    moveErrorMessage = errorMsg
                    isShowingMoveError = true
                }
            }
            await loadContents()
        }
    }
    
    private func performMove(to destinationPath: String) {
        guard supportsMutationOperations else { return }
        let filesToMove = files.filter { selectedFileIDs.contains($0.id) }
        guard !filesToMove.isEmpty else { return }
        
        Task {
            var firstError: String?
            
            for file in filesToMove {
                let sourcePath = resolvedPath(for: file)
                let targetPath = joinPath(base: destinationPath, name: file.name)
                
                if sourcePath == targetPath {
                    continue
                }
                
                do {
                    try await networkService.moveFile(server: server, fromPath: sourcePath, toPath: targetPath)
                } catch {
                    if firstError == nil {
                        firstError = error.localizedDescription
                    }
                }
            }
            
            selectedFileIDs.removeAll()
            isSelectionMode = false
            await loadContents()
            
            if let firstError {
                operationErrorTitle = NSLocalizedString("Move Failed", comment: "")
                moveErrorMessage = firstError
                isShowingMoveError = true
            }
        }
    }
    
    private func createFolder() {
        guard supportsMutationOperations else { return }
        let folderName = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folderName.isEmpty else { return }
        
        let destinationPath = joinPath(base: path, name: folderName)
        Task {
            do {
                try await networkService.createFolder(server: server, at: destinationPath)
                newFolderName = ""
                isShowingNewFolderAlert = false
                await loadContents()
            } catch {
                newFolderName = ""
                isShowingNewFolderAlert = false
                operationErrorTitle = NSLocalizedString("Create Folder Failed", comment: "")
                moveErrorMessage = error.localizedDescription
                isShowingMoveError = true
            }
        }
    }
    
    private func beginRename(_ file: VideoFile) {
        guard supportsMutationOperations else { return }
        renameTargetFile = file
        renameInputName = file.name
        isShowingRenameAlert = true
    }

    private func renameSelectedFile() {
        guard supportsMutationOperations else { return }
        guard let target = renameTargetFile else { return }
        let newName = renameInputName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty else { return }
        guard !newName.contains("/") && !newName.contains("\\") else {
            operationErrorTitle = NSLocalizedString("Rename Failed", comment: "")
            moveErrorMessage = NSLocalizedString("Name cannot contain slash characters.", comment: "")
            isShowingMoveError = true
            return
        }

        let sourcePath = resolvedPath(for: target)
        let destinationPath = joinPath(base: path, name: newName)
        if sourcePath == destinationPath {
            isShowingRenameAlert = false
            renameTargetFile = nil
            return
        }

        Task {
            do {
                try await networkService.moveFile(server: server, fromPath: sourcePath, toPath: destinationPath)
                renameInputName = ""
                isShowingRenameAlert = false
                renameTargetFile = nil
                await loadContents()
            } catch {
                renameInputName = ""
                isShowingRenameAlert = false
                renameTargetFile = nil
                operationErrorTitle = NSLocalizedString("Rename Failed", comment: "")
                moveErrorMessage = error.localizedDescription
                isShowingMoveError = true
            }
        }
    }

    private func requestDelete(_ file: VideoFile) {
        guard supportsMutationOperations else { return }
        deleteConfirmationTarget = .single(file)
    }

    private func requestDeleteSelectedFiles() {
        guard supportsMutationOperations, !selectedFileIDs.isEmpty else { return }
        deleteConfirmationTarget = .selection(fileIDs: Array(selectedFileIDs))
    }

    private func beginSingleMove(_ file: VideoFile) {
        guard supportsMutationOperations else { return }
        singleMoveTargetFile = file
        isShowingFolderPicker = true
    }

    private func performSingleMove(file: VideoFile, to destinationPath: String) {
        guard supportsMutationOperations else { return }
        let sourcePath = resolvedPath(for: file)
        let targetPath = joinPath(base: destinationPath, name: file.name)
        guard sourcePath != targetPath else { return }

        Task {
            do {
                try await networkService.moveFile(server: server, fromPath: sourcePath, toPath: targetPath)
                await loadContents()
            } catch {
                operationErrorTitle = NSLocalizedString("Move Failed", comment: "")
                moveErrorMessage = error.localizedDescription
                isShowingMoveError = true
            }
        }
    }

    private func saveFileToLocal(_ file: VideoFile) {
        let fullPath = resolvedPath(for: file)
        switch downloadCenter.taskStatus(serverId: server.id, remotePath: fullPath) {
        case .queued, .downloading, .paused, .completed:
            downloadToastMessage = NSLocalizedString("Already in Download Queue", comment: "")
            return
        default:
            break
        }

        DownloadCenterService.shared.enqueueDownload(
            server: server,
            remotePath: fullPath,
            fileName: file.name,
            totalBytes: file.size > 0 ? file.size : nil
        )
        downloadToastMessage = NSLocalizedString("Added to Download Queue", comment: "")
    }

    private func persistDownloadedFile(from tempURL: URL, originalName: String) throws -> URL {
        let fileManager = FileManager.default
        let documentsDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        let downloadsDirectory = documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)

        let sanitizedName = originalName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
        let sourceURL = URL(fileURLWithPath: sanitizedName)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension

        var destinationURL = downloadsDirectory.appendingPathComponent(sanitizedName)
        var counter = 1
        while fileManager.fileExists(atPath: destinationURL.path) {
            let nextName = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            destinationURL = downloadsDirectory.appendingPathComponent(nextName)
            counter += 1
        }

        do {
            try fileManager.moveItem(at: tempURL, to: destinationURL)
        } catch {
            try fileManager.copyItem(at: tempURL, to: destinationURL)
            try? fileManager.removeItem(at: tempURL)
        }
        return destinationURL
    }
    
    private func deleteFileAsync(_ file: VideoFile, refresh: Bool = true) async {
        let fullPath = resolvedPath(for: file)
        
        do {
            try await networkService.deleteFile(server: server, at: fullPath)
            if refresh {
                if let index = files.firstIndex(where: { $0.id == file.id }) {
                    files.remove(at: index)
                }
            }
        } catch {
            print("Delete error: \(error)")
        }
    }

    private func deleteFile(_ file: VideoFile) {
        Task {
            await deleteFileAsync(file)
        }
    }
    
    private func joinPath(base: String, name: String) -> String {
        if base == "/" {
            return "/\(name)"
        }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    private func resolvedPath(for file: VideoFile) -> String {
        if let serverPath = file.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serverPath.isEmpty {
            return serverPath
        }
        return joinPath(base: path, name: file.name)
    }
}

// Helper View for Async Preview Loading
@MainActor
struct RemoteFilePreviewLoader: View {
    let networkService: AppNetworkService
    let server: ServerConfig
    let path: String
    let file: VideoFile
    let files: [VideoFile] // Context for swiping
    @ObservedObject private var settings = AppSettings.shared
    
    @State private var downloadedURL: URL?
    @State private var isDownloading: Bool
    @State private var errorMsg: String?
    @State private var downloadTask: Task<Void, Never>?

    init(networkService: AppNetworkService, server: ServerConfig, path: String, file: VideoFile, files: [VideoFile]) {
        self.networkService = networkService
        self.server = server
        self.path = path
        self.file = file
        self.files = files
        _isDownloading = State(initialValue: file.previewRoute != .openElsewhere)
    }
    
    var body: some View {
        Group {
            if requiresExplicitUserDownload {
                DeferredExternalOpenPromptView(
                    file: file,
                    downloadedURL: downloadedURL,
                    isDownloading: isDownloading,
                    startDownload: startDownloadIfNeeded
                )
            } else if let url = downloadedURL {
                FilePreviewContentView(
                    file: VideoFile(name: file.name, url: url, type: file.type, size: file.size, date: file.date),
                    imageContextFiles: files,
                    networkService: networkService,
                    server: server
                )
            } else {
                Group {
                    if errorMsg == nil && isDownloading {
                        VStack {
                            ProgressView()
                            Text(NSLocalizedString("Downloading...", comment: ""))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Color(UIColor.systemBackground).ignoresSafeArea()
                    }
                }
                .onAppear {
                    if downloadedURL == nil && errorMsg == nil && isDownloading {
                        startDownloadIfNeeded()
                    }
                }
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear(perform: cancelDownload)
        .appErrorAlert(
            message: $errorMsg,
            title: NSLocalizedString("Couldn't open preview", comment: "")
        )
    }

    private var requiresExplicitUserDownload: Bool {
        file.previewRoute == .openElsewhere
    }

    private func startDownloadIfNeeded() {
        guard downloadTask == nil else { return }
        downloadFile()
    }

    private func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
    
    private func downloadFile() {
        let fullPath = file.remoteDownloadPath
        isDownloading = true
        downloadTask = Task {
            do {
                let localURL: URL
                if settings.enableRemoteFileCache {
                    localURL = try await RemoteFileCacheService.shared.fetchFile(
                        server: server,
                        remotePath: fullPath,
                        fileName: file.name
                    )
                } else {
                    localURL = try await networkService.downloadFile(server: server, at: fullPath)
                }
                await MainActor.run {
                    self.downloadedURL = localURL
                    self.isDownloading = false
                    self.downloadTask = nil
                }
            } catch {
                await MainActor.run {
                    self.isDownloading = false
                    self.downloadTask = nil
                    guard !isCancellation(error), !Task.isCancelled else { return }
                    self.errorMsg = error.localizedDescription
                }
            }
        }
    }
}

#if os(iOS)
/// Each presentation owns a server-root navigation stack and its initial folder destination.
struct RemoteFolderPresentation: Identifiable {
    let id = UUID()
    let server: ServerConfig
    var path: String = "/"
    var targetFileId: String? = nil
}

struct RemoteFolderPresentationView: View {
    let target: RemoteFolderPresentation
    let onExit: () -> Void
    @State private var isShowingInitialFolder = false
    @State private var didResolveInitialFolder = false
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared

    var body: some View {
        NavigationView {
            RemoteFileListView(
                server: target.server,
                networkService: AppNetworkService.shared,
                targetFileIdToResolve: target.path == "/" ? target.targetFileId : nil,
                onExit: onExit
            )
            .background(
                NavigationLink(
                    destination: RemoteFileListView(
                        server: target.server,
                        path: target.path,
                        networkService: AppNetworkService.shared,
                        targetFileIdToResolve: target.targetFileId,
                        onExit: onExit
                    ),
                    isActive: $isShowingInitialFolder,
                    label: { EmptyView() }
                )
                .hidden()
            )
            .onAppear {
                guard !didResolveInitialFolder else { return }
                didResolveInitialFolder = true
                isShowingInitialFolder = target.path != "/"
            }
        }
        .navigationViewStyle(.stack)
        .serverFloatingAudioOverlay()
        .privacyProtectedContent(
            title: target.server.name,
            isProtected: securityService.isPrivacySpaceEnabled &&
                !securityService.isPrivacySpaceUnlocked &&
                privacySpace.isServerMarkedPrivate(target.server)
        )
    }
}
#endif
