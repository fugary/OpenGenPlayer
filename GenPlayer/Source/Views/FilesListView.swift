import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

struct FilesListView: View {
    private let largeFolderPreviewThumbnailLimit = 180
    @StateObject private var fileManager: FileManagerService
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var privacySpace = PrivacySpaceService.shared
    @Environment(\.presentationMode) private var presentationMode
    @State private var fullScreenFile: VideoFile?
    @State private var previewFile: VideoFile?
    @State private var audioSheetFile: VideoFile?
    
    // UI States
    @State private var isSelectionMode = false
    @State private var selectedFileIDs = Set<String>()
    
    // Search state
    @State private var searchText = ""
    @State private var browserViewportHeight: CGFloat = 0
    @ObservedObject private var dragState = DragStateManager.shared
    
    private var filteredFiles: [VideoFile] {
        if searchText.isEmpty {
            return fileManager.localFiles
        } else {
            return fileManager.localFiles.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
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
            return !shouldHideLockedFolders || !privacySpace.isLocalFolderMarkedPrivate(file.url)
        }
    }
    
    // Import states (Files App & Photos)
    @State private var isImportingFiles = false
    @State private var isShowingPhotoPicker = false
    @State private var sharePayload: ShareSheetPayload?
    
    // Folder creation states
    @State private var isShowingNewFolderAlert = false
    @State private var newFolderName = ""
    
    // Move states
    @State private var isShowingFolderPicker = false
    @State private var selectedFolderURL: URL?
    
    // Delete confirmation states
    enum DeleteAlertSource {
        case selection
        case swipe
    }
    @State private var deleteAlertSource: DeleteAlertSource?
    @State private var isShowingDeleteAlert = false
    @State private var deleteOffsets: IndexSet?
    
    // Rename states
    @State private var isShowingRenameAlert = false
    @State private var renameTargetFile: VideoFile?
    @State private var renameInputName = ""
    @State private var isShowingPrivacyUnlock = false
    @State private var pendingPrivateFolderURL: URL?
    @State private var pendingUnmarkFolderPrivacy: URL?
    @State private var privacyActionMessage: String?
    @State private var infoSheetFile: VideoFile? = nil

    
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var columns: [GridItem] {
        let isCompact = horizontalSizeClass != .regular
        return [
            GridItem(.adaptive(minimum: isCompact ? 96 : 120), spacing: isCompact ? 12 : 16, alignment: .top)
        ]
    }

    private var shouldShowCurrentFolderDropTarget: Bool {
        dragState.isDragging &&
        dragState.hasDragFromDifferentDirectory(currentPath: fileManager.currentDirectory.path)
    }

    private var currentFolderRequiresPrivacyAccess: Bool {
        securityService.isPrivacySpaceEnabled &&
        !securityService.isPrivacySpaceUnlocked &&
        privacySpace.isLocalFolderMarkedPrivate(fileManager.currentDirectory)
    }

    private var selectedFilesForSharing: [VideoFile] {
        fileManager.localFiles.filter { selectedFileIDs.contains($0.id) }
    }

    private var canShareSelectedItems: Bool {
        !selectedFilesForSharing.isEmpty && selectedFilesForSharing.allSatisfy { $0.type != .folder }
    }

    private var navigationTitleDisplayMode: NavigationBarItem.TitleDisplayMode {
        .automatic
    }

    private var usesInlineSearchBar: Bool {
        if #available(iOS 15.0, *) {
            return false
        }
        return UIDevice.current.userInterfaceIdiom == .pad
    }
    
    init(url: URL? = nil) {
        _fileManager = StateObject(wrappedValue: FileManagerService(url: url))
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

                 // Main Content (Grid or List)
                 Group {
                 if settings.isLocalGridLayout {
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
                     .refreshableCompat {
                         await fileManager.refreshFilesAsync()
                     }
                 } else {
                     List {
                         ForEach(visibleFiles) { file in
                             listItemView(for: file, loadsPreviewThumbnails: loadsPreviewThumbnails)
                         }
                         .onDelete { offsets in
                             deleteOffsets = offsets
                             deleteAlertSource = .swipe
                             isShowingDeleteAlert = true
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
                     .listStyle(PlainListStyle())
                     .refreshableCompat {
                         await fileManager.refreshFilesAsync()
                     }
                 }
                 }
                 
                // Bottom Toolkit (Selection Mode)
                  if isSelectionMode {
                      VStack(spacing: 8) {
                          Text(String(format: NSLocalizedString("%d Selected", comment: ""), selectedFileIDs.count))
                              .font(.caption)
                              .foregroundColor(.secondary)

                          HStack {
                              Button(action: {
                                  deleteAlertSource = .selection
                                  isShowingDeleteAlert = true
                             }) {
                                 VStack {
                                     Image(systemName: "trash")
                                     Text(NSLocalizedString("Delete", comment: ""))
                                         .font(.caption)
                                 }
                             }
                              .disabled(selectedFileIDs.isEmpty)
                              .foregroundColor(selectedFileIDs.isEmpty ? .gray : .red)

                              Spacer()

                              Button(action: {
                                  shareSelectedFiles()
                              }) {
                                  VStack {
                                      Image(systemName: "square.and.arrow.up")
                                      Text(NSLocalizedString("Share", comment: ""))
                                          .font(.caption)
                                  }
                              }
                              .disabled(!canShareSelectedItems)
                              .foregroundColor(canShareSelectedItems ? .blue : .gray)

                             Spacer()

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
                          }
                      }
                     .padding()
                     .background(Color(UIColor.systemBackground))
                     .shadow(radius: 2)
                 }
            }
            .showTabBarCompat()
            .onHeightChange { browserViewportHeight = $0 }
            .navigationBarTitle(Text(fileManager.currentDirectory.lastPathComponent == "Documents" ? NSLocalizedString("Local", comment: "root") : fileManager.currentDirectory.lastPathComponent), displayMode: navigationTitleDisplayMode)
            .searchableCompat(
                text: $searchText,
                prompt: NSLocalizedString("Search", comment: ""),
                preferUIKitOnPad: true
            )
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    if !isSelectionMode && fileManager.currentDirectory.lastPathComponent != "Documents" {
                        Button(action: { presentationMode.wrappedValue.dismiss() }) {
                            AppToolbarIcon(systemName: "chevron.left")
                        }
                        Button(action: { popToRoot() }) {
                            AppToolbarIcon(systemName: "house")
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
                              // Plus Menu (Imports & New Folder)
                              Menu {
                                   Button(action: { isImportingFiles = true }) {
                                       Label(NSLocalizedString("File Manager Import", comment: ""), systemImage: "folder")
                                   }

                                   #if os(iOS)
                                   Button(action: { isShowingPhotoPicker = true }) {
                                       Label(NSLocalizedString("Import from Photos", comment: ""), systemImage: "photo.on.rectangle")
                                   }
                                   #endif
                                   
                                   Button(action: { isShowingNewFolderAlert = true }) {
                                       Label(NSLocalizedString("New Folder", comment: ""), systemImage: "folder.badge.plus")
                                   }
                              } label: {
                                  AppToolbarIcon(systemName: "plus")
                              }
                             
                            // Layout Toggle Button
                            Button(action: {
                                settings.isLocalGridLayout.toggle()
                            }) {
                                AppToolbarIcon(systemName: settings.isLocalGridLayout ? "list.bullet" : "square.grid.2x2")
                            }
                            
                            // Ellipsis Menu
                            Menu {
                                Button(action: {
                                    isSelectionMode = true
                                }) {
                                    Label(NSLocalizedString("Select", comment: ""), systemImage: "checkmark.circle")
                                }

                                Section(header: Text(NSLocalizedString("Sort By", comment: ""))) {
                                    ForEach(["name", "date", "size"], id: \.self) { option in
                                        Button(action: {
                                            updateLocalSortField(option)
                                        }) {
                                            localSortMenuRow(
                                                title: localSortTitle(for: option),
                                                isSelected: settings.localSortOptionRaw == option
                                            )
                                        }
                                    }
                                }

                                Section(header: Text(NSLocalizedString("Sort Order", comment: ""))) {
                                    Button(action: {
                                        updateLocalSortOrder(true)
                                    }) {
                                        localSortMenuRow(
                                            title: NSLocalizedString("Ascending", comment: ""),
                                            isSelected: settings.isLocalSortAscending
                                        )
                                    }
                                    Button(action: {
                                        updateLocalSortOrder(false)
                                    }) {
                                        localSortMenuRow(
                                            title: NSLocalizedString("Descending", comment: ""),
                                            isSelected: !settings.isLocalSortAscending
                                        )
                                    }
                                }

                                Button(action: {
                                    toggleLocalFoldersOnTop()
                                }) {
                                    localSortMenuRow(
                                        title: NSLocalizedString("Folder Top", comment: ""),
                                        isSelected: settings.showLocalFoldersOnTop
                                    )
                                }
                            } label: {
                                AppToolbarIcon(systemName: "ellipsis.circle")
                            }
                         }
                     
                 }
            }
            .onAppear {
                downloadCenter.reconcileMissingLocalFiles()
                fileManager.refreshFiles()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                downloadCenter.reconcileMissingLocalFiles()
                fileManager.refreshFiles()
            }
            .onReceive(NotificationCenter.default.publisher(for: FileManagerService.didImportExternalFilesNotification)) { _ in
                fileManager.refreshFiles()
            }
            .onChange(of: settings.localSortOptionRaw) { _ in fileManager.refreshFiles() }
            .onChange(of: settings.isLocalSortAscending) { _ in fileManager.refreshFiles() }
            .onChange(of: settings.showLocalFoldersOnTop) { _ in fileManager.refreshFiles() }
            .fileImporter(
                isPresented: $isImportingFiles,
                allowedContentTypes: [.movie, .video, .quickTimeMovie, .folder, .data, UTType("org.matroska.mkv") ?? .data],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task {
                        for url in urls {
                            if url.startAccessingSecurityScopedResource() {
                                await fileManager.importFile(from: url)
                                url.stopAccessingSecurityScopedResource()
                            }
                        }
                    }
                case .failure(let error):
                    print("Error importing: \(error.localizedDescription)")
                }
            }
            #if os(iOS)
            .sheet(isPresented: $isShowingPhotoPicker) {
                PhotoPickerView(targetDirectory: fileManager.currentDirectory) { importedCount in
                    if importedCount > 0 {
                        fileManager.refreshFiles()
                    }
                }
            }
            #endif
            
            if isShowingNewFolderAlert {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { isShowingNewFolderAlert = false }
                CustomInputAlert(
                    title: "New Folder",
                    message: "Name your new folder",
                    text: $newFolderName,
                    onCancel: { isShowingNewFolderAlert = false },
                    onConfirm: {
                        if !newFolderName.isEmpty {
                            fileManager.createDirectory(name: newFolderName)
                            newFolderName = ""
                            isShowingNewFolderAlert = false
                        }
                    }
                )
            }
            
            if isShowingRenameAlert {
                Color.black.opacity(0.4).ignoresSafeArea()
                    .onTapGesture { isShowingRenameAlert = false }
                CustomInputAlert(
                    title: "Rename",
                    message: "Enter a new name",
                    text: $renameInputName,
                    confirmTitle: "Rename",
                    onCancel: {
                        isShowingRenameAlert = false
                        renameTargetFile = nil
                    },
                    onConfirm: {
                        if let target = renameTargetFile {
                            fileManager.renameFile(target, newName: renameInputName)
                        }
                        renameInputName = ""
                        isShowingRenameAlert = false
                        renameTargetFile = nil
                    }
                )
            }
            
            if fileManager.isImporting {
                Color.black.opacity(0.4).ignoresSafeArea()
                
                VStack(spacing: 20) {
                    Text(NSLocalizedString("Importing...", comment: ""))
                        .font(.headline)
                    
                    Text(fileManager.currentImportFileName)
                        .font(.subheadline)
                        .lineLimit(1)
                    
                    ProgressView(value: fileManager.importProgress)
                        .padding(.horizontal)
                    
                    Text("\(Int(fileManager.importProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(24)
                .frame(width: 300)
                .background(Color(UIColor.secondarySystemBackground))
                .cornerRadius(16)
                .shadow(radius: 10)
            }
        }
        .privacyProtectedContent(
            title: fileManager.currentDirectory.lastPathComponent == "Documents"
                ? NSLocalizedString("Local", comment: "")
                : fileManager.currentDirectory.lastPathComponent,
            isProtected: currentFolderRequiresPrivacyAccess
        )
        .sheet(isPresented: $isShowingFolderPicker) {
            FolderPickerView(
                rootURL: fileManager.currentDirectory.path.contains("Documents") ? 
                   FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first! : 
                   fileManager.currentDirectory,
                onMoveHere: { destinationURL in
                    performMove(to: destinationURL)
                    isShowingFolderPicker = false
                },
                onCancel: {
                    isShowingFolderPicker = false
                }
            )
        }
        .sheet(item: $sharePayload, onDismiss: {
            sharePayload = nil
        }) { payload in
            ShareSheet(activityItems: payload.urls.map { $0 as Any })
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
                AudioPlayerView(initialFile: file, playlist: displayedFiles)
            }
            .navigationViewStyle(.stack)
            .privacyProtectedContent(
                title: file.name,
                isProtected: requiresPrivacyAccess(for: file)
            )
        }
        .sheet(item: $previewFile, onDismiss: { fileManager.refreshFiles() }) { file in
            previewSheetContent(for: file)
                .privacyProtectedContent(
                    title: file.name,
                    isProtected: requiresPrivacyAccess(for: file)
                )
        }
        .sheet(item: $infoSheetFile) { file in
            FileInfoSheet(file: file)
        }
        .sheet(isPresented: $isShowingPrivacyUnlock, onDismiss: {
            if securityService.isPrivacySpaceUnlocked {
                if let url = pendingUnmarkFolderPrivacy {
                    _ = privacySpace.toggleLocalFolderMarkedPrivate(url)
                    pendingUnmarkFolderPrivacy = nil
                } else if let url = pendingPrivateFolderURL {
                    pendingPrivateFolderURL = nil
                    selectedFolderURL = url
                }
            } else {
                pendingUnmarkFolderPrivacy = nil
                pendingPrivateFolderURL = nil
            }
        }) {
            PrivacySpaceUnlockView(
                isPresented: $isShowingPrivacyUnlock,
                title: pendingPrivateFolderURL?.lastPathComponent ?? pendingUnmarkFolderPrivacy?.lastPathComponent ?? NSLocalizedString("Privacy Space", comment: "")
            )
        }
        .appErrorAlert(
            message: $privacyActionMessage,
            title: NSLocalizedString("Privacy Space", comment: "")
        )
        .alert(isPresented: $isShowingDeleteAlert) {
            switch deleteAlertSource {
            case .selection:
                return Alert(
                    title: Text(NSLocalizedString("Delete Files", comment: "")),
                    message: Text(NSLocalizedString("Are you sure you want to delete the selected files?", comment: "")),
                    primaryButton: .destructive(Text(NSLocalizedString("Delete", comment: ""))) {
                        deleteSelectedFiles()
                    },
                    secondaryButton: .cancel()
                )
            case .swipe, .none:
                return Alert(
                    title: Text(NSLocalizedString("Delete File", comment: "")),
                    message: Text(NSLocalizedString("Are you sure you want to delete this file?", comment: "")),
                    primaryButton: .destructive(Text(NSLocalizedString("Delete", comment: ""))) {
                        if let offsets = deleteOffsets {
                            fileManager.deleteFiles(at: offsets)
                            deleteOffsets = nil
                        } else if !selectedFileIDs.isEmpty {
                            deleteSelectedFiles()
                        }
                    },
                    secondaryButton: .cancel {
                        deleteOffsets = nil
                        if deleteAlertSource != .selection && !isSelectionMode {
                            selectedFileIDs.removeAll()
                        }
                    }
                )
            }
        }
        .if(fileManager.currentDirectory.lastPathComponent != "Documents") { $0.customBackButton() }
    }
    
    // Grid Item View
    @ViewBuilder
    private func gridItemView(for file: VideoFile, loadsPreviewThumbnails: Bool) -> some View {
        let isSelected = selectedFileIDs.contains(file.id)
        
        Group {
            if isSelectionMode {
                Button(action: {
                    handleSelectionTap(file)
                }) {
                    FileGridItemView(file: file, isSelected: isSelected, isSelectionMode: isSelectionMode, markers: markers(for: file), loadsPreviewThumbnails: loadsPreviewThumbnails)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            } else if file.type == .folder {
                Button(action: {
                    openFolder(file)
                }) {
                    FileGridItemView(file: file, isSelected: isSelected, isSelectionMode: isSelectionMode, markers: markers(for: file), loadsPreviewThumbnails: loadsPreviewThumbnails)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .contextMenu {
                    contextMenuFor(file)
                }
            } else {
                Button(action: { openFile(file) }) {
                    FileGridItemView(file: file, isSelected: isSelected, isSelectionMode: isSelectionMode, markers: markers(for: file), loadsPreviewThumbnails: loadsPreviewThumbnails)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .contentShape(Rectangle())
                .contextMenu {
                    contextMenuFor(file)
                }
            }
        }
        .nativeMultiDrag(file: file, isSelectionMode: isSelectionMode, selectedFileIDs: selectedFileIDs, isLocalFile: true)
        .onFileDropTarget(file: file) { payload in
            let paths = payload.split(separator: "\n").map { String($0) }
            let sourceURLs = paths.map { URL(fileURLWithPath: $0) }
            let validSources = sourceURLs.filter { $0 != file.url }
            guard !validSources.isEmpty else { return }
            
            Task {
                await fileManager.moveFiles(validSources, to: file.url)
                if isSelectionMode {
                    isSelectionMode = false
                    selectedFileIDs.removeAll()
                }
            }
        }
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
                        contextMenuFor(file)
                    }
                    .nativeListDropTarget(isFolder: true) { payload in
                        let paths = payload.split(separator: "\n").map { String($0) }
                        let sourceURLs = paths.map { URL(fileURLWithPath: $0) }
                        let validSources = sourceURLs.filter { $0 != file.url }
                        guard !validSources.isEmpty else { return }

                        Task {
                            await fileManager.moveFiles(validSources, to: file.url)
                            if isSelectionMode {
                                isSelectionMode = false
                                selectedFileIDs.removeAll()
                            }
                        }
                    }
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
                        contextMenuFor(file)
                    }
                }
            }
            .contentShape(Rectangle())
            .nativeMultiDrag(file: file, isSelectionMode: isSelectionMode, selectedFileIDs: selectedFileIDs, isLocalFile: true)
        )

        if #available(iOS 15.0, *) {
            baseRow
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        } else {
            baseRow
        }
    }

    @ViewBuilder
    private var folderNavigationLink: some View {
        NavigationLink(
            destination: folderNavigationDestination(),
            isActive: Binding(
                get: { selectedFolderURL != nil },
                set: { isActive in
                    if !isActive {
                        selectedFolderURL = nil
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
        if let selectedFolderURL {
            FilesListView(url: selectedFolderURL)
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
    private func fullScreenContent(for file: VideoFile) -> some View {
        if file.type == .video {
            PlayerView(initialFile: file, playlist: displayedFiles)
                .onDisappear { fileManager.refreshFiles() }
        } else {
            Text(NSLocalizedString("Unsupported file type", comment: ""))
        }
    }
    
    @ViewBuilder
    private func previewSheetContent(for file: VideoFile) -> some View {
        PreviewSheetContainer {
            FilePreviewContentView(
                file: file,
                imagePlaylist: displayedFiles.filter { $0.type == .image }
            )
        }
    }

    @ViewBuilder
    private func listItemContent(for file: VideoFile, loadsPreviewThumbnails: Bool) -> some View {
        let isSelected = selectedFileIDs.contains(file.id)
        FileListItemView(file: file, isSelected: isSelected, isSelectionMode: isSelectionMode, markers: markers(for: file), loadsPreviewThumbnails: loadsPreviewThumbnails)
    }

    @ViewBuilder
    private func contextMenuFor(_ file: VideoFile) -> some View {
        Button(action: {
            infoSheetFile = file
        }) {
            Label(NSLocalizedString("File Info", comment: ""), systemImage: "info.circle")
        }

        if file.type != .folder {

            Button(action: {
                shareFiles([file.url])
            }) {
                Label(NSLocalizedString("Share", comment: ""), systemImage: "square.and.arrow.up")
            }
        }

        Button(action: {
            renameTargetFile = file
            renameInputName = file.name
            isShowingRenameAlert = true
        }) {
            Label(NSLocalizedString("Rename", comment: ""), systemImage: "pencil")
        }

        Button(action: {
            selectedFileIDs = [file.id]
            isShowingFolderPicker = true
        }) {
            Label(NSLocalizedString("Move", comment: ""), systemImage: "folder")
        }

        Button(action: {
            favoriteService.toggleFavorite(file: file, folderPath: file.type == .folder ? file.url.path : nil)
        }) {
            Label(
                favoriteService.isFavorite(file: file, folderPath: file.type == .folder ? file.url.path : nil)
                    ? NSLocalizedString("Remove Favorite", comment: "")
                    : NSLocalizedString("Add Favorite", comment: ""),
                systemImage: favoriteService.isFavorite(file: file, folderPath: file.type == .folder ? file.url.path : nil)
                    ? "star.slash"
                    : "star"
            )
        }

        if file.type == .folder && securityService.isPrivacySpaceEnabled {
            Button(action: {
                toggleLocalFolderPrivacy(file.url)
            }) {
                Label(
                    privacySpace.isLocalFolderMarkedPrivate(file.url)
                        ? NSLocalizedString("Remove from Privacy Space", comment: "")
                        : NSLocalizedString("Add to Privacy Space", comment: ""),
                    systemImage: privacySpace.isLocalFolderMarkedPrivate(file.url) ? "lock.open" : "lock"
                )
            }
        }

        if #available(iOS 15.0, *) {
            Button(role: .destructive, action: {
                deleteTargetFile(file)
            }) {
                Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
            }
        } else {
            Button(action: {
                deleteTargetFile(file)
            }) {
                Label(NSLocalizedString("Delete", comment: ""), systemImage: "trash")
            }
        }
    }
    
    private func markers(for file: VideoFile) -> [String] {
        var result: [String] = []
        if favoriteService.isFavorite(file: file, folderPath: file.type == .folder ? file.url.path : nil) {
            result.append("star.fill")
        }
        if file.type == .folder && securityService.isPrivacySpaceEnabled && privacySpace.isLocalFolderMarkedPrivate(file.url) {
            result.append(securityService.isPrivacySpaceUnlocked ? "lock.open" : "lock")
        }
        if file.type != .folder && downloadCenter.isTrackedLocalDownload(file.url) {
            result.append("arrow.down.circle.fill")
        }
        return result
    }
    
    private func deleteTargetFile(_ file: VideoFile) {
        deleteOffsets = nil
        deleteAlertSource = .swipe // Using same alert style
        selectedFileIDs = [file.id] // Temporarily select for deletion
        isShowingDeleteAlert = true
    }
    
    private func handleSelectionTap(_ file: VideoFile) {
        if selectedFileIDs.contains(file.id) {
            selectedFileIDs.remove(file.id)
        } else {
            selectedFileIDs.insert(file.id)
        }
    }

    private func shareSelectedFiles() {
        guard canShareSelectedItems else { return }
        let filesToShare = selectedFilesForSharing.map(\.url)
        shareFiles(filesToShare)
    }

    private func shareFiles(_ urls: [URL]) {
        let items = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !items.isEmpty else { return }
        sharePayload = ShareSheetPayload(urls: items)
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

    private func openFolder(_ file: VideoFile) {
        guard file.type == .folder else { return }
        guard !requiresPrivacyAccess(toLocalFolder: file.url) else {
            pendingPrivateFolderURL = file.url
            isShowingPrivacyUnlock = true
            return
        }
        selectedFolderURL = file.url
    }
    
    private func openFile(_ file: VideoFile) {
        if file.type == .video {
            fullScreenFile = file
        } else if file.type == .audio {
            audioSheetFile = file
        } else {
            previewFile = file
        }
    }
    
    // Adjusted delete Selected Files to handle context menu single deletions
    private func deleteSelectedFiles() {
        let filesToDelete = fileManager.localFiles.filter { selectedFileIDs.contains($0.id) }
        for file in filesToDelete {
            fileManager.deleteFile(file)
        }
        selectedFileIDs.removeAll()
        isSelectionMode = false
    }
    
    private func performMove(to destinationURL: URL) {
        let filesToMove = fileManager.localFiles.filter { selectedFileIDs.contains($0.id) }
        Task {
            await fileManager.moveFiles(filesToMove.map { $0.url }, to: destinationURL)
            await MainActor.run {
                selectedFileIDs.removeAll()
                isSelectionMode = false
            }
        }
    }
    
    private func handleDropPayloadToCurrentFolder(_ payload: String) {
        let currentURL = fileManager.currentDirectory
        let paths = payload.split(separator: "\n").map(String.init)
        let sourceURLs = paths.map { URL(fileURLWithPath: $0) }
        let validSources = Array(Dictionary(
            sourceURLs
                .filter { $0.deletingLastPathComponent() != currentURL && $0 != currentURL }
                .map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        ).values)
        guard !validSources.isEmpty else { return }
        
        Task {
            await fileManager.moveFiles(validSources, to: currentURL)
            DragStateManager.shared.endDrag()
            if isSelectionMode {
                isSelectionMode = false
                selectedFileIDs.removeAll()
            }
        }
    }
    
    private func handlePaste() {
        // Try to get URLs from pasteboard
        if let urls = UIPasteboard.general.urls {
            Task {
                for url in urls {
                   await fileManager.importFile(from: url)
                }
            }
            return
        }
        
        // Try as string
        if let string = UIPasteboard.general.string, let url = URL(string: string) {
            Task {
                await fileManager.importFile(from: url)
            }
        }
    }

    private func localSortTitle(for option: String) -> String {
        switch option {
        case "name": return NSLocalizedString("Name", comment: "")
        case "date": return NSLocalizedString("Date", comment: "")
        case "size": return NSLocalizedString("Size", comment: "")
        default: return NSLocalizedString("Name", comment: "")
        }
    }

    @ViewBuilder
    private func localSortMenuRow(title: String, isSelected: Bool) -> some View {
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

    private func updateLocalSortField(_ option: String) {
        if settings.localSortOptionRaw != option {
            settings.objectWillChange.send()
            settings.localSortOptionRaw = option
            settings.isLocalSortAscending = option == "name"
            fileManager.refreshFiles()
        }
    }

    private func updateLocalSortOrder(_ ascending: Bool) {
        if settings.isLocalSortAscending != ascending {
            settings.objectWillChange.send()
            settings.isLocalSortAscending = ascending
            fileManager.refreshFiles()
        }
    }

    private func toggleLocalFoldersOnTop() {
        settings.objectWillChange.send()
        settings.showLocalFoldersOnTop.toggle()
        fileManager.refreshFiles()
    }

    private func requiresPrivacyAccess(toLocalFolder folderURL: URL) -> Bool {
        securityService.isPrivacySpaceEnabled &&
        !securityService.isPrivacySpaceUnlocked &&
        privacySpace.isLocalFolderMarkedPrivate(folderURL)
    }

    private func requiresPrivacyAccess(for file: VideoFile) -> Bool {
        securityService.isPrivacySpaceEnabled &&
        !securityService.isPrivacySpaceUnlocked &&
        privacySpace.isFileMarkedPrivate(file)
    }

    private func toggleLocalFolderPrivacy(_ folderURL: URL) {
        guard securityService.hasPrivacyPassword else {
            privacyActionMessage = NSLocalizedString("Set up Privacy Space in Settings before locking items.", comment: "")
            return
        }

        if privacySpace.isLocalFolderMarkedPrivate(folderURL) && !securityService.isPrivacySpaceUnlocked {
            pendingUnmarkFolderPrivacy = folderURL
            isShowingPrivacyUnlock = true
        } else {
            _ = privacySpace.toggleLocalFolderMarkedPrivate(folderURL)
        }
    }
}

struct CustomInputAlert: View {
    let title: String
    let message: String
    @Binding var text: String
    var confirmTitle: String = "Create"
    var confirmColor: Color = .blue
    let onCancel: () -> Void
    let onConfirm: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            Text(NSLocalizedString(title, comment: "")).font(.headline)
            Text(NSLocalizedString(message, comment: "")).font(.subheadline)
            TextField(NSLocalizedString("Name", comment: ""), text: $text)
                .textFieldStyle(RoundedBorderTextFieldStyle())
            HStack(spacing: 20) {
                Button(NSLocalizedString("Cancel", comment: ""), action: onCancel)
                Button(action: onConfirm) {
                    Text(NSLocalizedString(confirmTitle, comment: ""))
                        .foregroundColor(confirmColor)
                }
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(12)
        .shadow(radius: 10)
        .padding(.horizontal, 40)
        .frame(maxWidth: 400)
    }
}

private struct ShareSheetPayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

@available(iOS 16.0, *)
struct PhotoImporterView: View {
    @ObservedObject var fileManager: FileManagerService
    @State private var selectedItem: PhotosPickerItem?
    
    var body: some View {
        PhotosPicker(selection: $selectedItem, matching: .videos) {
            Label(NSLocalizedString("Fetch from Photos", comment: ""), systemImage: "photo.on.rectangle")
        }
        .onChange(of: selectedItem) { newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self) {
                    let name = "Video_\(Int(Date().timeIntervalSince1970)).mp4"
                    if let url = try? saveToTemp(data: data, name: name) {
                        await fileManager.importFile(from: url)
                    }
                }
            }
        }
    }
    
    private func saveToTemp(data: Data, name: String) throws -> URL {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: tempURL)
        return tempURL
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
    }
}
