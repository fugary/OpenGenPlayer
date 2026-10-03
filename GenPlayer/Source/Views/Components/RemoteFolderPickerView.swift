import SwiftUI

@MainActor
struct RemoteFolderPickerView: View {
    let server: ServerConfig
    let networkService: AppNetworkService
    let onMoveHere: (String) -> Void
    let onCancel: () -> Void
    let initialPath: String
    
    init(
        server: ServerConfig,
        initialPath: String = "/",
        networkService: AppNetworkService,
        onMoveHere: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.server = server
        self.networkService = networkService
        self.onMoveHere = onMoveHere
        self.onCancel = onCancel
        self.initialPath = initialPath.isEmpty ? "/" : initialPath
    }
    
    var body: some View {
        NavigationView {
            RemoteFolderPickerChildView(
                server: server,
                networkService: networkService,
                currentPath: initialPath,
                onMoveHere: onMoveHere,
                onCancel: onCancel,
                isRootOfPicker: true
            )
        }
        .navigationViewStyle(.stack)
    }
}

@MainActor
struct RemoteFolderPickerChildView: View {
    let server: ServerConfig
    let networkService: AppNetworkService
    let currentPath: String
    let onMoveHere: (String) -> Void
    let onCancel: () -> Void
    let isRootOfPicker: Bool
    
    @State private var folders: [VideoFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        List {
            // "Up a Directory" allows ascending above the initial picker launch point
            if isRootOfPicker && currentPath != "/" && currentPath != "" {
                NavigationLink(destination: RemoteFolderPickerChildView(
                    server: server,
                    networkService: networkService,
                    currentPath: parentPath(for: currentPath),
                    onMoveHere: onMoveHere,
                    onCancel: onCancel,
                    isRootOfPicker: true
                )) {
                    HStack {
                        Image(systemName: "arrow.turn.left.up")
                            .foregroundColor(.accentColor)
                        Text(NSLocalizedString("Up a Directory", comment: ""))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
            }
            
            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
            } else {
                ForEach(folders) { folder in
                    NavigationLink(destination: RemoteFolderPickerChildView(
                        server: server,
                        networkService: networkService,
                        currentPath: resolvedPath(for: folder),
                        onMoveHere: onMoveHere,
                        onCancel: onCancel,
                        isRootOfPicker: false
                    )) {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.blue)
                            Text(folder.name)
                        }
                        .contentShape(Rectangle())
                    }
                }
            }
        }
        .navigationTitle(currentPath == "/" ? NSLocalizedString("Select Folder", comment: "") : URL(fileURLWithPath: currentPath).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .appErrorAlert(
            message: $errorMessage,
            title: NSLocalizedString("Couldn't load folder", comment: ""),
            retryTitle: NSLocalizedString("Retry", comment: ""),
            retryAction: {
                Task { await loadFolders() }
            }
        )
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if isRootOfPicker {
                    Button(NSLocalizedString("Cancel", comment: ""), action: onCancel)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(NSLocalizedString("Move Here", comment: "")) {
                    onMoveHere(currentPath)
                }
                .font(.headline)
                .disabled(isLoading)
            }
        }
        .onAppear {
            Task {
                await loadFolders()
            }
        }
    }
    
    private func loadFolders() async {
        isLoading = true
        errorMessage = nil
        
        do {
            let items = try await networkService.fetchContents(for: server, at: currentPath)
            folders = items
                .filter { $0.type == .folder }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            errorMessage = error.localizedDescription
            folders = []
        }
        
        isLoading = false
    }
    
    private func parentPath(for path: String) -> String {
        if path == "/" { return "/" }
        let pathURL = URL(fileURLWithPath: path)
        let parentURL = pathURL.deletingLastPathComponent()
        let parentPath = parentURL.path
        return parentPath.isEmpty ? "/" : parentPath
    }
    
    private func joinPath(base: String, name: String) -> String {
        if base == "/" {
            return "/\(name)"
        }
        return base.hasSuffix("/") ? base + name : base + "/" + name
    }

    private func resolvedPath(for folder: VideoFile) -> String {
        if let serverPath = folder.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serverPath.isEmpty {
            return serverPath
        }
        return joinPath(base: currentPath, name: folder.name)
    }
}
