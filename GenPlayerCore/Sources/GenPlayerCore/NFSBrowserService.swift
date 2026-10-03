import Foundation
import NFSKit

public enum NFSBrowserError: Error, LocalizedError {
    case invalidURL
    case exportRequired
    case connectionFailed
    case underlying(Error)
    
    public var errorDescription: String? {
        switch self {
        case .invalidURL: return NSLocalizedString("Invalid NFS Server Address. Need host or IP.", comment: "")
        case .exportRequired: return NSLocalizedString("NFS root did not expose any exports or failed to parse. Please check your NFS configuration.", comment: "")
        case .connectionFailed: return NSLocalizedString("NFS Client could not be initialized.", comment: "")
        case .underlying(let error): return error.localizedDescription
        }
    }
}

public final class NFSBrowserService {
    public static let shared = NFSBrowserService()
    
    private init() {}
    
    public func testConnection(server: ServerConfig) async throws {
        _ = try await listFiles(server: server, at: "/")
    }
    
    public func listFiles(server: ServerConfig, at path: String) async throws -> [VideoFile] {
        let rootAddress = server.address.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = rootAddress
        var serverExport = ""
        
        if rootAddress.contains("://"), let parsed = URLComponents(string: rootAddress) {
            host = parsed.host ?? rootAddress
            serverExport = parsed.path
        } else if let slashIndex = rootAddress.firstIndex(of: "/") {
            host = String(rootAddress[..<slashIndex])
            serverExport = String(rootAddress[slashIndex...])
        }
        
        guard !host.isEmpty, let url = URL(string: "nfs://\(host)") else {
            throw NFSBrowserError.invalidURL
        }
        
        guard let client = try? NFSClient(url: url) else {
            throw NFSBrowserError.connectionFailed
        }
        
        let requestedPath = path.isEmpty ? "/" : path
        var targetExport = serverExport
        var subPath = requestedPath
        
        // Auto-discover export if not provided in server address
        if targetExport.isEmpty || targetExport == "/" {
            if requestedPath == "/" {
                // List root exports
                let exports: [String] = try await withCheckedThrowingContinuation { continuation in
                    client.listExports { result in
                        switch result {
                        case .success(let exps):
                            continuation.resume(returning: exps)
                        case .failure(let error):
                            continuation.resume(throwing: NFSBrowserError.underlying(error))
                        }
                    }
                }
                
                return exports.map { exportName in
                    let name = exportName.hasPrefix("/") ? String(exportName.dropFirst()) : exportName
                    let safeExportName = exportName.hasPrefix("/") ? exportName : "/\(exportName)"
                    let fallbackURL = URL(string: "nfs://\(host)\(safeExportName)") ?? url
                    
                    var file = VideoFile(
                        name: name.isEmpty ? exportName : name,
                        url: fallbackURL,
                        type: VideoFile.FileType.folder,
                        size: 0,
                        date: Date(),
                        duration: nil
                    )
                    file.isRemote = true
                    file.serverType = .nfs
                    file.jellyfinServerId = server.id.uuidString
                    file.serverPath = safeExportName
                    return file
                }
            } else {
                // Find matching export for requested path
                let exports: [String] = try await withCheckedThrowingContinuation { continuation in
                    client.listExports { result in
                        switch result {
                        case .success(let exps):
                            continuation.resume(returning: exps)
                        case .failure(let err):
                            continuation.resume(throwing: NFSBrowserError.underlying(err))
                        }
                    }
                }
                
                for exp in exports.sorted(by: { $0.count > $1.count }) {
                    if requestedPath == exp || requestedPath.hasPrefix(exp + "/") {
                        targetExport = exp
                        let relative = String(requestedPath.dropFirst(exp.count))
                        subPath = relative.isEmpty ? "/" : relative
                        break
                    }
                }
                
                if targetExport.isEmpty || targetExport == "/" {
                    throw NFSBrowserError.exportRequired
                }
            }
        } else {
            // Validate and trim subpath based on configured export
            if requestedPath == targetExport || requestedPath.hasPrefix(targetExport + "/") {
                let relative = String(requestedPath.dropFirst(targetExport.count))
                subPath = relative.isEmpty ? "/" : relative
            }
        }
        
        // Connect to export
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.connect(export: targetExport) { error in
                if let error = error {
                    continuation.resume(throwing: NFSBrowserError.underlying(error))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        
        let pathToList = subPath.isEmpty ? "/" : (subPath.hasPrefix("/") ? subPath : "/\(subPath)")
        
        // List directory contents
        var resultFiles = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[VideoFile], Error>) in
            client.contentsOfDirectory(atPath: pathToList) { result in
                switch result {
                case .success(let items):
                    let files = items.compactMap { entry -> VideoFile? in
                        guard let name = entry[.nameKey] as? String else { return nil }
                        if name == "." || name == ".." { return nil }
                        
                        let isDir = (entry[.fileResourceTypeKey] as? URLFileResourceType) == .directory
                        let type: VideoFile.FileType = isDir ? VideoFile.FileType.folder : VideoFile.FileType.determineType(from: URL(fileURLWithPath: name))
                        
                        let absPath: String
                        if targetExport.hasSuffix("/") {
                            absPath = targetExport + (pathToList == "/" ? "" : String(pathToList.dropFirst())) + "/" + name
                        } else {
                            absPath = targetExport + (pathToList == "/" ? "" : pathToList) + "/" + name
                        }
                        
                        let safeServerPath = absPath.replacingOccurrences(of: "//", with: "/")
                        
                        var components = URLComponents()
                        components.scheme = "nfs"
                        components.host = host
                        components.path = safeServerPath.hasPrefix("/") ? safeServerPath : "/\(safeServerPath)"
                        
                        var videoFile = VideoFile(
                            name: name,
                            url: components.url ?? URL(fileURLWithPath: name),
                            type: type,
                            size: (entry[.fileSizeKey] as? Int64) ?? 0,
                            date: (entry[.contentModificationDateKey] as? Date) ?? Date(),
                            duration: nil
                        )
                        
                        videoFile.isRemote = true
                        videoFile.serverType = .nfs
                        videoFile.jellyfinServerId = server.id.uuidString
                        videoFile.serverPath = safeServerPath
                        return videoFile
                    }
                    continuation.resume(returning: files)
                case .failure(let error):
                    continuation.resume(throwing: NFSBrowserError.underlying(error))
                }
            }
        }
        
        resultFiles.sort { lhs, rhs in
            if lhs.type == VideoFile.FileType.folder && rhs.type != VideoFile.FileType.folder { return true }
            if lhs.type != VideoFile.FileType.folder && rhs.type == VideoFile.FileType.folder { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        
        return resultFiles
    }
    
    public func downloadFile(server: ServerConfig, at path: String, progress: ((Int64, Int64) -> Void)?) async throws -> URL {
        // Parse host and export from server address (same logic as listFiles)
        let rootAddress = server.address.trimmingCharacters(in: .whitespacesAndNewlines)
        var host = rootAddress
        var serverExport = ""
        
        if rootAddress.contains("://"), let parsed = URLComponents(string: rootAddress) {
            host = parsed.host ?? rootAddress
            serverExport = parsed.path
        } else if let slashIndex = rootAddress.firstIndex(of: "/") {
            host = String(rootAddress[..<slashIndex])
            serverExport = String(rootAddress[slashIndex...])
        }
        
        guard !host.isEmpty, let url = URL(string: "nfs://\(host)") else {
            throw NFSBrowserError.invalidURL
        }
        guard let client = try? NFSClient(url: url) else {
            throw NFSBrowserError.connectionFailed
        }
        
        var targetExport = serverExport
        var subPath = path
        
        // Ensure connection
        if !targetExport.isEmpty && targetExport != "/" {
            if path == targetExport || path.hasPrefix(targetExport + "/") {
                let relative = String(path.dropFirst(targetExport.count))
                subPath = relative.isEmpty ? "/" : relative
            }
        } else {
            // Must auto-discover export again if not set
            let exports: [String] = try await withCheckedThrowingContinuation { continuation in
                client.listExports { result in
                    switch result {
                    case .success(let exps):
                        continuation.resume(returning: exps)
                    case .failure(let err):
                        continuation.resume(throwing: NFSBrowserError.underlying(err))
                    }
                }
            }
            for exp in exports.sorted(by: { $0.count > $1.count }) {
                if path == exp || path.hasPrefix(exp + "/") {
                    targetExport = exp
                    let relative = String(path.dropFirst(exp.count))
                    subPath = relative.isEmpty ? "/" : relative
                    break
                }
            }
            if targetExport.isEmpty || targetExport == "/" {
                throw NFSBrowserError.exportRequired
            }
        }
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.connect(export: targetExport) { error in
                if let error = error {
                    continuation.resume(throwing: NFSBrowserError.underlying(error))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        
        let pathToDownload = subPath.isEmpty ? "/" : (subPath.hasPrefix("/") ? subPath : "/\(subPath)")
        
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        
        let fileName = URL(fileURLWithPath: path).lastPathComponent
        let destinationURL = tempDir.appendingPathComponent(fileName)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            client.downloadItem(atPath: pathToDownload, to: destinationURL) { bytes, total in
                progress?(bytes, total)
                return !Task.isCancelled
            } completionHandler: { error in
                if let error = error {
                    continuation.resume(throwing: NFSBrowserError.underlying(error))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
        
        return destinationURL
    }
}
