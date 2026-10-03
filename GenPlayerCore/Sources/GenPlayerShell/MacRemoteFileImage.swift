#if os(macOS)
import SwiftUI
import AVFoundation
import GenPlayerCore

private actor MacThumbnailLimiter {
    static let shared = MacThumbnailLimiter(maxConcurrent: 3)
    
    private let maxConcurrent: Int
    private var activeCount = 0
    private var continuations: [CheckedContinuation<Void, Never>] = []
    
    init(maxConcurrent: Int) {
        self.maxConcurrent = maxConcurrent
    }
    
    func wait() async {
        if activeCount < maxConcurrent {
            activeCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }
    
    func signal() {
        if !continuations.isEmpty {
            let next = continuations.removeFirst()
            next.resume()
        } else {
            activeCount -= 1
        }
    }
}

public struct MacRemoteFileImage: View {
    public let file: VideoFile
    public let server: ServerConfig?
    public var siblingFiles: [VideoFile]? = nil
    public var contentMode: ContentMode = .fill

    public init(file: VideoFile, server: ServerConfig? = nil, siblingFiles: [VideoFile]? = nil, contentMode: ContentMode = .fill) {
        self.file = file
        self.server = server
        self.siblingFiles = siblingFiles
        self.contentMode = contentMode
    }

    public var body: some View {
        MacRemoteFileImageContent(file: file, server: server, siblingFiles: siblingFiles, contentMode: contentMode)
            // Own image/task state per source, not per reused SwiftUI slot. File.id
            // contains only the path, so it cannot distinguish different servers.
            .id([file.url.absoluteString, file.jellyfinServerId ?? server?.id.uuidString ?? "",
                 file.customArtworkURL?.absoluteString ?? ""])
    }
}

private struct MacRemoteFileImageContent: View {
    let file: VideoFile
    let server: ServerConfig?
    var siblingFiles: [VideoFile]? = nil
    var contentMode: ContentMode = .fill
    
    @State private var image: NSImage?
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?
    @State private var videoArtworkGenerator: IndependentMediaThumbnailGenerator?
    @State private var audioArtworkGenerator: IndependentMediaThumbnailGenerator?
    @AppStorage("extractRemoteAudioArtwork") private var extractRemoteAudioArtwork = false
    
    init(file: VideoFile, server: ServerConfig? = nil, siblingFiles: [VideoFile]? = nil, contentMode: ContentMode = .fill) {
        self.file = file
        self.server = server
        self.siblingFiles = siblingFiles
        self.contentMode = contentMode
    }
    
    public var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .clipped()
                    .contentShape(Rectangle())
            } else if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
            } else {
                fallbackIcon
            }
        }
        .onAppear {
            loadImage()
        }
        .onDisappear {
            loadTask?.cancel()
            videoArtworkGenerator?.cancel()
            audioArtworkGenerator?.cancel()
        }

    }
    
    @ViewBuilder
    private var fallbackIcon: some View {
        if file.usesStyledFormatTile {
            ZStack {
                Rectangle()
                    .fill(file.iconColor)
                
                VStack(spacing: 4) {
                    Image(systemName: file.iconName)
                        .font(.system(size: 24, weight: .regular))
                        .foregroundColor(.white)
                    
                    if let text = file.formatBadgeText {
                        Text(text)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
            }
        } else {
            Image(systemName: mediaIconName(for: file))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .scaleEffect(file.type == .folder ? 0.86 : 0.68)
                .foregroundColor(file.type == .folder ? .accentColor : .secondary)
        }
    }
    
    private func urlStringForCache() -> String {
        return file.url.absoluteString + "_thumb"
    }
    
    private func loadImage() {
        guard file.type == .image || file.type == .audio || file.type == .video || file.type == .folder else { return }
        let currentServerType = server?.type ?? file.serverType
        if (currentServerType?.requiresDynamicPlaybackURL == true) && (file.type == .audio || file.type == .video) && file.customArtworkURL == nil {
            return
        }
        
        let cacheKey = urlStringForCache()
        if let cacheURL = URL(string: cacheKey), let cached = MacImageCache.shared.getImage(for: cacheURL) {
            self.image = cached
            return
        }
        
        isLoading = true
        loadTask = Task {
            do {
                if let loaded = try await fetchImage() {
                    if !Task.isCancelled {
                        if let cacheURL = URL(string: cacheKey) {
                            MacImageCache.shared.saveImage(loaded, for: cacheURL)
                        }
                        await MainActor.run {
                            guard !Task.isCancelled else { return }
                            self.image = loaded
                        }
                    }
                }
            } catch {
                print("Failed to load thumbnail for \(file.name): \(error)")
            }
            if !Task.isCancelled {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    isLoading = false
                }
            }
        }
    }
    
    private func fetchImage() async throws -> NSImage? {
        try Task.checkCancellation()
        await MacThumbnailLimiter.shared.wait()
        defer {
            Task {
                await MacThumbnailLimiter.shared.signal()
            }
        }
        
        if Task.isCancelled { return nil }

        if let customArtworkURL = file.customArtworkURL {
            return try await fetchCustomArtwork(from: customArtworkURL)
        }
        
        if let siblingFiles = siblingFiles {
            if let sidecarImage = try await fetchSidecarImage(from: siblingFiles) {
                return sidecarImage
            }
        }
        
        let currentServerType = server?.type ?? file.serverType
        if currentServerType == .pan115 && file.type == .image {
            // For 115 images, avoid downloading full-size images in grid/list if no thumbnail URL is provided
            return nil
        }

        if file.type == .image {
            return try await downloadOrLoadImage(at: file.serverPath ?? file.url.path, url: file.url)
        }
        
        if file.type == .audio {
            return try await fetchAudioArtwork()
        }
        
        if file.type == .video {
            return await fetchVideoThumbnail()
        }
        
        return nil
    }

    private func fetchCustomArtwork(from url: URL) async throws -> NSImage? {
        var req = URLRequest(url: url)
        let currentServerType = server?.type ?? file.serverType
        if currentServerType == .pan115 {
            req.setValue(Pan115Manager.defaultUserAgent, forHTTPHeaderField: "User-Agent")
            if let server = server ?? file.resolvedServer, let cookie = server.passwordSecret ?? server.accessToken, !cookie.isEmpty {
                req.setValue(cookie, forHTTPHeaderField: "Cookie")
            }
            req.setValue("https://115.com", forHTTPHeaderField: "Referer")
        }
        let (data, _) = try await URLSession.shared.data(for: req)
        return NSImage(data: data)
    }
    
    private func fetchSidecarImage(from siblings: [VideoFile]) async throws -> NSImage? {
        let nameWithoutExt = (file.name as NSString).deletingPathExtension
        let targetNames = [
            "\(nameWithoutExt).jpg",
            "\(nameWithoutExt).png",
            "folder.jpg",
            "cover.jpg",
            "poster.jpg",
            "backdrop.jpg"
        ].map { $0.lowercased() }
        
        let images = siblings.filter { $0.type == .image }
        for targetName in targetNames {
            if let match = images.first(where: { $0.name.lowercased() == targetName }) {
                return try await downloadOrLoadImage(at: match.serverPath ?? match.url.path, url: match.url)
            }
        }
        return nil
    }
    
    private func downloadOrLoadImage(at path: String, url: URL) async throws -> NSImage? {
        if let server = server {
            let tempURL = try await AppNetworkService.shared.downloadFile(server: server, at: path)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            return NSImage(contentsOf: tempURL)
        } else {
            return NSImage(contentsOf: url)
        }
    }
    
    private func fetchAudioArtwork() async throws -> NSImage? {
        if let server = server {
            if extractRemoteAudioArtwork {
                let tempURL = try await AppNetworkService.shared.downloadFile(server: server, at: file.serverPath ?? file.url.path)
                defer { try? FileManager.default.removeItem(at: tempURL) }
                return extractID3Artwork(from: tempURL)
            }
            
            return await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    let generator = IndependentMediaThumbnailGenerator(completesOnCancel: true)
                    self.audioArtworkGenerator = generator
                    generator.generateThumbnail(for: self.file.url, provider: self.file.serverType?.rawValue, serverID: self.file.jellyfinServerId, path: self.file.serverPath, itemID: self.file.jellyfinItemId, isAudio: self.file.type == .audio) { image in
                        self.audioArtworkGenerator = nil
                        continuation.resume(returning: image)
                    }
                }
            }
        } else {
            return extractID3Artwork(from: file.url)
        }
    }
    
    private func extractID3Artwork(from url: URL) -> NSImage? {
        let asset = AVAsset(url: url)
        for metadata in asset.commonMetadata {
            if metadata.commonKey == .commonKeyArtwork, let data = metadata.dataValue {
                return NSImage(data: data)
            }
        }
        return nil
    }
    
    private func fetchVideoThumbnail() async -> NSImage? {
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let generator = IndependentMediaThumbnailGenerator(completesOnCancel: true)
                self.videoArtworkGenerator = generator
                generator.generateThumbnail(for: self.file.url, provider: self.file.serverType?.rawValue, serverID: self.file.jellyfinServerId, path: self.file.serverPath, itemID: self.file.jellyfinItemId, isAudio: self.file.type == .audio) { image in
                    self.videoArtworkGenerator = nil
                    continuation.resume(returning: image)
                }
            }
        }
    }
    
    private func mediaIconName(for file: VideoFile) -> String {
        switch file.type {
        case .folder: return "folder.fill"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .image: return "photo.fill"
        case .document: return "doc.text.fill"
        default: return "doc.fill"
        }
    }
}
#endif
