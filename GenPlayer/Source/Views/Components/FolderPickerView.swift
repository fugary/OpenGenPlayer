import SwiftUI

struct FolderPickerView: View {
    let rootURL: URL
    let onMoveHere: (URL) -> Void
    let onCancel: () -> Void
    
    @State private var currentURL: URL
    @State private var folders: [VideoFile] = []
    @State private var navigationStack: [URL] = []
    
    private let fileManager = FileManager.default
    
    init(rootURL: URL, onMoveHere: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.rootURL = rootURL
        self.onMoveHere = onMoveHere
        self.onCancel = onCancel
        _currentURL = State(initialValue: rootURL)
    }
    
    var body: some View {
        NavigationView {
            List {
                if currentURL.path != rootURL.path {
                    Button(action: goBack) {
                        HStack {
                            Image(systemName: "folder.fill.badge.minus")
                            Text("..")
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                }
                
                ForEach(folders) { folder in
                    Button(action: { navigateInto(folder) }) {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.blue)
                            Text(folder.name)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
            .navigationTitle(currentURL.lastPathComponent == "Documents" ? NSLocalizedString("Select Folder", comment: "") : currentURL.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    if !navigationStack.isEmpty {
                        Button(action: goBack) {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.left")
                                Text(NSLocalizedString("Back", comment: ""))
                            }
                        }
                    } else {
                        Button(NSLocalizedString("Cancel", comment: ""), action: onCancel)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("Move Here", comment: "")) {
                        onMoveHere(currentURL)
                    }
                    .font(.headline)
                }
            }
            .onAppear(perform: loadFolders)
        }
    }
    
    private func loadFolders() {
        do {
            let contents = try fileManager.contentsOfDirectory(at: currentURL, includingPropertiesForKeys: [.isDirectoryKey])
            folders = contents.compactMap { url -> VideoFile? in
                let resources = try? url.resourceValues(forKeys: [.isDirectoryKey])
                guard resources?.isDirectory == true else { return nil }
                if url.lastPathComponent.hasPrefix(".") { return nil }
                
                return VideoFile(
                    name: url.lastPathComponent,
                    url: url,
                    type: .folder,
                    size: 0,
                    date: Date()
                )
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            print("Error loading folders: \(error)")
        }
    }
    
    private func navigateInto(_ folder: VideoFile) {
        navigationStack.append(currentURL)
        currentURL = folder.url
        loadFolders()
    }
    
    private func goBack() {
        if let previous = navigationStack.popLast() {
            currentURL = previous
            loadFolders()
        }
    }
}
