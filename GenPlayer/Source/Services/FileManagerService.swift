import Foundation
#if os(iOS)
import UIKit
#endif
import Combine

class FileManagerService: ObservableObject {
    static let didImportExternalFilesNotification = Notification.Name("FileManagerServiceDidImportExternalFiles")

    @Published var localFiles: [VideoFile] = []
    @Published var currentDirectory: URL
    
    // Sort options - delegated to AppSettings
    typealias SortOption = AppSettings.SortOption
    
    // Import progress
    @Published var isImporting: Bool = false
    @Published var importProgress: Double = 0.0
    @Published var currentImportFileName: String = ""
    
    private let fileManager = FileManager.default
    private var cancellables = Set<AnyCancellable>()
    private var settings = AppSettings.shared
    private let scanQueue = DispatchQueue(label: "com.genplayer.file-manager.scan", qos: .userInitiated)
    private var refreshGeneration = 0
    
    init(url: URL? = nil) {
        // Start at Documents directory or specified URL
        if let url = url {
            self.currentDirectory = url
        } else {
            self.currentDirectory = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        }
        
        setupScreenshotObserver()
        refreshFiles()
    }

    static func importExternalFiles(from urls: [URL]) {
        let incomingURLs = urls.filter { $0.isFileURL }
        guard !incomingURLs.isEmpty else { return }

        Task.detached(priority: .userInitiated) {
            guard let destinationDirectory = documentsDirectoryURL() else { return }
            let fileManager = FileManager.default
            var importedCount = 0

            for sourceURL in incomingURLs {
                let didAccess = sourceURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        sourceURL.stopAccessingSecurityScopedResource()
                    }
                }

                do {
                    let resolvedURL = try importExternalItem(at: sourceURL, to: destinationDirectory, fileManager: fileManager)
                    if resolvedURL != nil {
                        importedCount += 1
                    }
                } catch {
                    print("Error importing external shared file: \(error)")
                }
            }

            let completedImportCount = importedCount
            guard completedImportCount > 0 else { return }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: didImportExternalFilesNotification,
                    object: nil,
                    userInfo: ["count": completedImportCount]
                )
            }
        }
    }
    
    private func setupScreenshotObserver() {
#if os(iOS)
        NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)
            .receive(on: RunLoop.main)
            .delay(for: .seconds(1.0), scheduler: RunLoop.main) // Wait for FS changes
            .sink { [weak self] _ in
                print("Screenshot detected, refreshing files...")
                self?.refreshFiles()
            }
            .store(in: &cancellables)
#endif
    }
    
    // Legacy navigation methods removed as we use NavigationLink
    
    func refreshFiles() {
        refreshFiles(completion: nil)
    }

    private func refreshFiles(completion: (() -> Void)?) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.refreshFiles(completion: completion)
            }
            return
        }

        let directory = currentDirectory
        let sortOption = settings.localSortOption
        let isSortAscending = settings.isLocalSortAscending
        let showsFoldersOnTop = settings.showLocalFoldersOnTop
        refreshGeneration += 1
        let generation = refreshGeneration

        scanQueue.async {
            let result = Self.scanDirectory(
                at: directory,
                sortOption: sortOption,
                isSortAscending: isSortAscending,
                showsFoldersOnTop: showsFoldersOnTop
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    completion?()
                    return
                }

                guard self.refreshGeneration == generation,
                      self.currentDirectory.standardizedFileURL.path == directory.standardizedFileURL.path else {
                    completion?()
                    return
                }

                switch result {
                case .success(let files):
                    self.localFiles = files
                case .failure(let error):
                    print("Error scanning directory: \(error)")
                    self.localFiles = []
                }
                completion?()
            }
        }
    }

    private static func scanDirectory(
        at directory: URL,
        sortOption: SortOption,
        isSortAscending: Bool,
        showsFoldersOnTop: Bool
    ) -> Result<[VideoFile], Error> {
        do {
            let fileManager = FileManager.default
            let contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey],
                options: []
            )
            
            var files = contents.compactMap { url -> VideoFile? in
                let resources = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
                let isDirectory = resources?.isDirectory ?? false
                
                // Filter out hidden files or system files if needed
                if url.lastPathComponent.hasPrefix(".") { return nil }
                
                let size = (resources?.fileSize ?? 0)
                let date = (resources?.contentModificationDate ?? Date())
                let type: VideoFile.FileType = isDirectory ? .folder : VideoFile.FileType.determineType(from: url)
                
                var itemCount: Int? = nil
                if isDirectory {
                    itemCount = calculateItemCount(at: url, fileManager: fileManager)
                }
                
                return VideoFile(
                    name: url.lastPathComponent,
                    url: url,
                    type: type,
                    size: Int64(size),
                    date: date,
                    itemCount: itemCount
                )
            }
            
            // Sort
            files.sort { file1, file2 in
                if showsFoldersOnTop {
                    if file1.type == .folder && file2.type != .folder { return true }
                    if file1.type != .folder && file2.type == .folder { return false }
                }
                
                switch sortOption {
                case .name:
                    let result = file1.name.localizedStandardCompare(file2.name)
                    return isSortAscending ? (result == .orderedAscending) : (result == .orderedDescending)
                case .date:
                    return isSortAscending ? (file1.date < file2.date) : (file1.date > file2.date)
                case .size:
                    return isSortAscending ? (file1.size < file2.size) : (file1.size > file2.size)
                }
            }
            
            return .success(files)
        } catch {
            return .failure(error)
        }
    }

    func refreshFilesAsync() async {
        await withCheckedContinuation { continuation in
            refreshFiles {
                continuation.resume()
            }
        }
    }

    static func documentsDirectoryURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    private static func importExternalItem(at sourceURL: URL, to destinationDirectory: URL, fileManager: FileManager) throws -> URL? {
        let standardizedSourceURL = sourceURL.standardizedFileURL
        let standardizedDestinationDirectory = destinationDirectory.standardizedFileURL

        if standardizedSourceURL.deletingLastPathComponent() == standardizedDestinationDirectory {
            return standardizedSourceURL
        }

        let destinationURL = uniqueDestinationURL(for: standardizedSourceURL, in: standardizedDestinationDirectory, fileManager: fileManager)
        try fileManager.copyItem(at: standardizedSourceURL, to: destinationURL)
        return destinationURL
    }

    private static func uniqueDestinationURL(for sourceURL: URL, in directory: URL, fileManager: FileManager) -> URL {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension
        var candidateURL = directory.appendingPathComponent(sourceURL.lastPathComponent)
        var counter = 1

        while fileManager.fileExists(atPath: candidateURL.path) {
            let nextName = "\(baseName) (\(counter))"
            if fileExtension.isEmpty {
                candidateURL = directory.appendingPathComponent(nextName)
            } else {
                candidateURL = directory.appendingPathComponent(nextName).appendingPathExtension(fileExtension)
            }
            counter += 1
        }

        return candidateURL
    }
    
    private func determineFileType(from url: URL) -> VideoFile.FileType {
        return VideoFile.FileType.determineType(from: url)
    }

    private static func calculateItemCount(at url: URL, fileManager: FileManager) -> Int {
        let contents = try? fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        return contents?.count ?? 0
    }

    
    func deleteFile(_ file: VideoFile) {
        try? fileManager.removeItem(at: file.url)
        Task { @MainActor in
            DownloadCenterService.shared.reconcileMissingLocalFiles()
        }
        refreshFiles()
    }
    
    func deleteFiles(at offsets: IndexSet) {
        let filesToDelete = offsets.map { localFiles[$0] }
        for file in filesToDelete {
            deleteFile(file)
        }
    }
    
    func renameFile(_ file: VideoFile, newName: String) {
        guard !newName.isEmpty else { return }
        
        // Construct the new URL in the same directory
        let newURL = file.url.deletingLastPathComponent().appendingPathComponent(newName)
        
        // Prevent renaming if it's the exact same name or empty
        guard file.url != newURL else { return }
        
        do {
            try fileManager.moveItem(at: file.url, to: newURL)
            Task { @MainActor in
                DownloadCenterService.shared.updateTrackedLocalFileLocation(from: file.url, to: newURL)
            }
            refreshFiles()
        } catch {
            print("Error renaming file: \(error)")
        }
    }
    
    func toggleSort(by option: SortOption) {
        if settings.localSortOption == option {
            settings.isLocalSortAscending.toggle()
        } else {
            settings.localSortOption = option
            settings.isLocalSortAscending = true // Reset to ascending for new sort type
        }
        refreshFiles()
    }
    
    func createDirectory(name: String) {
        let newDirURL = currentDirectory.appendingPathComponent(name)
        
        do {
            try fileManager.createDirectory(at: newDirURL, withIntermediateDirectories: true)
            refreshFiles()
        } catch {
            print("Error creating directory: \(error)")
        }
    }
    
    func importFile(from url: URL) async {
         let fileName = url.deletingPathExtension().lastPathComponent
         let fileExtension = url.pathExtension
         var destinationURL = currentDirectory.appendingPathComponent(url.lastPathComponent)
         
         // Handle duplicates
         var counter = 1
         while fileManager.fileExists(atPath: destinationURL.path) {
             let newName = "\(fileName) (\(counter))\(fileExtension.isEmpty ? "" : ".\(fileExtension)")"
             destinationURL = currentDirectory.appendingPathComponent(newName)
             counter += 1
         }
         
         await MainActor.run {
             self.isImporting = true
             self.importProgress = 0.0
             self.currentImportFileName = url.lastPathComponent
         }
         
         defer {
             Task { @MainActor in
                 self.isImporting = false
                 self.importProgress = 0.0
                 self.currentImportFileName = ""
             }
         }
         
         do {
             // Get file size for progress
             let resources = try url.resourceValues(forKeys: [.fileSizeKey])
             let fileSize = Double(resources.fileSize ?? 0)
             
             // If we can't determine size or it's small (< 10MB), just copy normally
             if fileSize == 0 || fileSize < 10 * 1024 * 1024 {
                 try fileManager.copyItem(at: url, to: destinationURL)
             } else {
                 try copyFileWithProgress(from: url, to: destinationURL, totalSize: fileSize)
             }
             
             await MainActor.run {
                 refreshFiles()
             }
         } catch {
             print("Error importing file: \(error)")
             // Clean up partial file if needed
             if fileManager.fileExists(atPath: destinationURL.path) {
                 try? fileManager.removeItem(at: destinationURL)
             }
         }
     }
     
    
     private func copyFileWithProgress(from source: URL, to destination: URL, totalSize: Double) throws {
         // Create empty file at destination
         fileManager.createFile(atPath: destination.path, contents: nil, attributes: nil)
         
         let readHandle = try FileHandle(forReadingFrom: source)
         let writeHandle = try FileHandle(forWritingTo: destination)
         
         defer {
             try? readHandle.close()
             try? writeHandle.close()
         }
         
         let bufferSize = 1024 * 1024 // 1MB chunks
         var bytesWritten: Double = 0
         
         while true {
             guard let data = try readHandle.read(upToCount: bufferSize), !data.isEmpty else {
                 break
             }
             
             try writeHandle.write(contentsOf: data)
             bytesWritten += Double(data.count)
             
             // Update progress
             let progress = bytesWritten / totalSize
             Task { @MainActor in
                 self.importProgress = progress
             }
         }
     }

    func moveFiles(_ fileURLs: [URL], to destinationURL: URL) async {
        for fileURL in fileURLs {
            let destination = destinationURL.appendingPathComponent(fileURL.lastPathComponent)
            var finalDestinationURL: URL?
            
            // Don't move if destination is the same as source
            if fileURL.standardizedFileURL.path == destination.standardizedFileURL.path { continue }
            
            do {
                if fileManager.fileExists(atPath: destination.path) {
                    var uniqueDestination = destination
                    var counter = 1
                    let fileName = destination.deletingPathExtension().lastPathComponent
                    let fileExtension = destination.pathExtension
                    
                    while fileManager.fileExists(atPath: uniqueDestination.path) {
                        let newName = "\(fileName) (\(counter))\(fileExtension.isEmpty ? "" : ".\(fileExtension)")"
                        uniqueDestination = destinationURL.appendingPathComponent(newName)
                        counter += 1
                    }
                    try fileManager.moveItem(at: fileURL, to: uniqueDestination)
                    finalDestinationURL = uniqueDestination
                } else {
                    try fileManager.moveItem(at: fileURL, to: destination)
                    finalDestinationURL = destination
                }

                if let finalDestinationURL {
                    await MainActor.run {
                        DownloadCenterService.shared.updateTrackedLocalFileLocation(from: fileURL, to: finalDestinationURL)
                    }
                }
            } catch {
                print("Error moving file \(fileURL.lastPathComponent): \(error)")
            }
        }
        
        await MainActor.run {
            refreshFiles()
        }
    }
}
