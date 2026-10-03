import SwiftUI
import AVFoundation
import GenPlayerShell
import GenPlayerCore

private actor RemoteImageRequestLimiter {
    static let shared = RemoteImageRequestLimiter(maxConcurrentRequests: 4)

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let maxConcurrentRequests: Int
    private var activeRequests = 0
    private var waiters: [Waiter] = []

    init(maxConcurrentRequests: Int) {
        self.maxConcurrentRequests = max(1, maxConcurrentRequests)
    }

    func acquire(requestID: UUID) async throws {
        if activeRequests < maxConcurrentRequests {
            activeRequests += 1
            return
        }

        let granted = await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: requestID, continuation: continuation))
            }
        }, onCancel: {
            Task { await self.cancelWaiter(requestID: requestID) }
        })

        guard granted else {
            throw CancellationError()
        }
    }

    func release() {
        if waiters.isEmpty {
            activeRequests = max(0, activeRequests - 1)
            return
        }

        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: true)
    }

    private func cancelWaiter(requestID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == requestID }) else {
            return
        }

        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }
}

private final class IndependentThumbnailContinuationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<UIImage?, Never>?

    func store(_ continuation: CheckedContinuation<UIImage?, Never>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func resume(with image: UIImage?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: image)
    }
}

class RemoteImageLoader: ObservableObject, @unchecked Sendable {
    @Published var image: UIImage?
    @Published var isLoading = false
    
    private var url: URL?
    private var currentTask: URLSessionDataTask?
    private var currentLoadTask: Task<Void, Never>?
    
    func load(url: URL?, sourceFile: VideoFile? = nil, permitNetworkForAudioArtwork: Bool = false, permitNetworkForVideoArtwork: Bool = false) {
        // Cancel any pending task if url changes or we reload
        currentTask?.cancel()
        currentTask = nil
        currentLoadTask?.cancel()
        currentLoadTask = nil

        if shouldSuppressAutomaticArtwork(for: sourceFile) {
            self.image = nil
            self.isLoading = false
            return
        }
        
        guard let url = url else {
            self.image = nil
            self.isLoading = false
            return
        }
        self.url = url
        
        // 1. Check Cache (Memory & Disk via ImageCacheManager)
        // For local files we use the URL absolute string as cache key too
        if let cached = ImageCacheManager.shared.getImage(for: url) {
            self.image = cached
            self.isLoading = false
            return
        }

        if let remoteArtworkKey = remoteAudioArtworkCacheKey(for: url, sourceFile: sourceFile),
           let cached = ImageCacheManager.shared.getImage(forKey: remoteArtworkKey) {
            self.image = cached
            self.isLoading = false
            return
        }

        if let remotePreviewKey = remoteFilePreviewCacheKey(for: url, sourceFile: sourceFile),
           let cached = ImageCacheManager.shared.getImage(forKey: remotePreviewKey) {
            self.image = cached
            self.isLoading = false
            return
        }
        
        self.image = nil
        isLoading = true
        
        // 2. Branch: Local File vs Remote URL
        if url.isFileURL {
            loadLocalAsset(for: url)
        } else if shouldLoadRemoteAudioArtwork(for: url, sourceFile: sourceFile) {
            if permitNetworkForAudioArtwork {
                loadRemoteAudioArtwork(for: url, sourceFile: sourceFile)
            } else {
                // Remote audio artwork lookup is cache-only by default to avoid large
                // fan-out requests in folders with many files.
                self.isLoading = false
            }
        } else if shouldLoadRemoteFileImage(url) {
            loadRemoteFileImage(for: url, sourceFile: sourceFile)
        } else if isRemoteFileProtocol(url) && !(permitNetworkForVideoArtwork && isRemoteVideoStream(url)) {
            // For other remote file protocol types (like videos), we don't attempt network previews/thumbnails
            // to prevent connection hangs and slow directory loading.
            self.isLoading = false
            return
        } else if isRemoteVideoStream(url) {
            fallbackToIndependentThumbnailer(url: url, sourceFile: sourceFile)
        } else {
            loadRemoteImage(for: url, sourceFile: sourceFile)
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        currentLoadTask?.cancel()
        currentLoadTask = nil
        independentThumbnailGenerator?.cancel()
        independentThumbnailGenerator = nil
        isLoading = false
    }
    
    // Identifies if an HTTP URL is a video stream or a remote file stream
    private func isRemoteVideoStream(_ url: URL) -> Bool {
        let ext = URL(fileURLWithPath: url.path).pathExtension.lowercased()
        let audioExts = ["mp3", "m4a", "flac", "wav", "aac", "ogg", "wma", "ape"]
        let imageExts = VideoFile.FileType.imageExtensions
        
        // Prevent VLCThumbnailer from aggressively scanning audio files over sluggish network protocols, which can cause connection hangs
        if audioExts.contains(ext) || imageExts.contains(ext) {
            return false
        }
        
        let remoteSchemes = ["smb", "ftp", "sftp", "nfs"]
        let videoExts = ["mkv", "mp4", "mov", "avi", "wmv", "flv", "ts", "rmvb", "webm", "m4v", "iso", "mpg"]
        if let scheme = url.scheme?.lowercased(), remoteSchemes.contains(scheme) {
            return videoExts.contains(ext)
        }
        
        return videoExts.contains(ext)
    }

    private func isRemoteFileProtocol(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["smb", "ftp", "sftp", "nfs", "webdav"].contains(scheme)
    }

    private func shouldLoadRemoteFileImage(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        let remoteFileSchemes = ["smb", "ftp", "sftp", "nfs"]
        guard remoteFileSchemes.contains(scheme) else {
            return false
        }
        let ext = URL(fileURLWithPath: url.path).pathExtension.lowercased()
        return VideoFile.FileType.imageExtensions.contains(ext)
    }

    private func shouldLoadRemoteAudioArtwork(for url: URL, sourceFile: VideoFile?) -> Bool {
        guard let sourceFile, sourceFile.isRemote else {
            return false
        }
        guard sourceFile.type == .audio else {
            return false
        }

        let serverType = sourceFile.resolvedServer?.type ?? sourceFile.serverType
        switch serverType {
        case .smb, .webdav, .ftp, .sftp, .nfs:
            return true
        case .alist, .pan115, .onedrive, .googledrive, .jellyfin, .emby, .plex, .iptv, .vod, .none:
            return false
        }
    }

    private func shouldSuppressAutomaticArtwork(for sourceFile: VideoFile?) -> Bool {
        guard let sourceFile,
              sourceFile.isRemote,
              sourceFile.type == .audio || sourceFile.type == .video else {
            return false
        }

        let st = sourceFile.resolvedServer?.type ?? sourceFile.serverType
        return st?.requiresDynamicPlaybackURL == true
    }

    private func shouldUseStableRemoteFilePreviewCache(for url: URL, sourceFile: VideoFile?) -> Bool {
        guard let sourceFile, sourceFile.isRemote else {
            return false
        }

        guard sourceFile.type == .video || sourceFile.type == .image else {
            return false
        }

        let serverType = sourceFile.resolvedServer?.type ?? sourceFile.serverType
        switch serverType {
        case .smb, .webdav, .ftp, .sftp, .nfs:
            return true
        case .alist, .pan115, .onedrive, .googledrive, .jellyfin, .emby, .plex, .iptv, .vod, .none:
            return false
        }
    }

    private func remoteAudioArtworkCacheKey(for url: URL, sourceFile: VideoFile?) -> String? {
        guard shouldLoadRemoteAudioArtwork(for: url, sourceFile: sourceFile) else {
            return nil
        }

        let resolvedServerType = sourceFile?.resolvedServer?.type ?? sourceFile?.serverType
        let resolvedServerId = sourceFile?.jellyfinServerId
        let resolvedServerPath = sourceFile?.serverPath

        return ArtworkCacheKey.remoteAudioArtwork(
            serverType: resolvedServerType,
            serverId: resolvedServerId,
            serverPath: resolvedServerPath,
            fallbackURL: url
        )
    }

    private func remoteFilePreviewCacheKey(for url: URL, sourceFile: VideoFile?) -> String? {
        guard shouldUseStableRemoteFilePreviewCache(for: url, sourceFile: sourceFile) else {
            return nil
        }

        let resolvedServerType = sourceFile?.resolvedServer?.type ?? sourceFile?.serverType
        let resolvedServerId = sourceFile?.jellyfinServerId
        let resolvedServerPath = sourceFile?.serverPath
        let resolvedFileType = sourceFile?.type ?? .unknown

        return RemotePreviewCacheKey.filePreview(
            serverType: resolvedServerType,
            serverId: resolvedServerId,
            serverPath: resolvedServerPath,
            fileType: resolvedFileType,
            fallbackURL: url
        )
    }

    private func resolvedRemotePath(for url: URL, sourceFile: VideoFile?) -> String {
        if let sourceFile,
           let serverPath = sourceFile.serverPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !serverPath.isEmpty {
            return serverPath
        }
        return url.path.isEmpty ? "/" : url.path
    }
    
    // MARK: - Local Thumbnail Generation
    private func loadLocalAsset(for url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let imageExtensions = Set(VideoFile.FileType.imageExtensions)
            if imageExtensions.contains(url.pathExtension.lowercased()) {
                let localImage = UIImage(contentsOfFile: url.path)
                DispatchQueue.main.async {
                    if self.url == url {
                        if let localImage {
                            ImageCacheManager.shared.saveImage(localImage, for: url)
                            self.image = localImage
                        }
                        self.isLoading = false
                    }
                }
                return
            }
            
            let asset = AVAsset(url: url)
            var generatedImage: UIImage? = nil
            
            // Check if Audio (look for artwork metadata)
            let commonMetadata = asset.commonMetadata
            if let artworkItem = commonMetadata.first(where: { $0.commonKey == .commonKeyArtwork }),
               let data = artworkItem.dataValue,
               let image = UIImage(data: data) {
                generatedImage = image
            }
            // If not audio artwork, try Video Frame Generation
            else {
                // If it's an MKV file, AVAsset native extraction will fail outright
                if url.pathExtension.lowercased() == "mkv" {
                    self.fallbackToIndependentThumbnailer(url: url, sourceFile: nil)
                    return // Independent thumbnail reader takes over
                }
                
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 400, height: 400) // Optimization limit
                
                // Pick a timestamp slightly into the video
                let durationSeconds = CMTimeGetSeconds(asset.duration)
                let targetTime = durationSeconds > 0 ? min(durationSeconds * 0.05, 10.0) : 0
                let time = CMTime(seconds: targetTime, preferredTimescale: 600)
                
                do {
                    let cgImage = try generator.copyCGImage(at: time, actualTime: nil)
                    generatedImage = UIImage(cgImage: cgImage)
                } catch {
                    print("[RemoteImage] AVAsset failed for \(url.lastPathComponent), using independent thumbnail reader. Error: \(error.localizedDescription)")
                    self.fallbackToIndependentThumbnailer(url: url, sourceFile: nil)
                    return // Independent thumbnail reader takes over
                }
            }
            
            // Finish Up natively
            DispatchQueue.main.async {
                if self.url == url {
                    if let img = generatedImage {
                        ImageCacheManager.shared.saveImage(img, for: url)
                        self.image = img
                    }
                    self.isLoading = false
                }
            }
        }
    }
    
    // Hold a strong reference to the delegate while generating
    private var independentThumbnailGenerator: IndependentMediaThumbnailGenerator?
    
    private func fallbackToIndependentThumbnailer(url: URL, sourceFile: VideoFile? = nil) {
        currentLoadTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let generatedImage: UIImage?
                if url.isFileURL {
                    generatedImage = await self.generateIndependentThumbnail(for: url, sourceFile: sourceFile)
                } else {
                    generatedImage = try await self.runRemoteRequest {
                        await self.generateIndependentThumbnail(for: url, sourceFile: sourceFile)
                    }
                }

                if Task.isCancelled {
                    return
                }

                await MainActor.run {
                    guard self.url == url else { return }

                    if let generatedImage {
                        ImageCacheManager.shared.saveImage(generatedImage, for: url)
                        if let remotePreviewKey = self.remoteFilePreviewCacheKey(for: url, sourceFile: sourceFile) {
                            ImageCacheManager.shared.saveImage(generatedImage, forKey: remotePreviewKey)
                        }
                        self.image = generatedImage
                    }
                    self.isLoading = false
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    if self.url == url {
                        self.isLoading = false
                    }
                }
            }
        }
    }

    private func loadRemoteAudioArtwork(for url: URL, sourceFile: VideoFile?) {
        guard let sourceFile else {
            fallbackToIndependentThumbnailer(url: url)
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let generator = IndependentMediaThumbnailGenerator()
            self.independentThumbnailGenerator = generator

            generator.generateThumbnail(for: url, provider: sourceFile.serverType?.rawValue, serverID: sourceFile.jellyfinServerId, path: sourceFile.serverPath, itemID: sourceFile.jellyfinItemId, isAudio: sourceFile.type == .audio) { [weak self] image in
                guard let self = self else { return }
                guard self.url == url else {
                    self.independentThumbnailGenerator = nil
                    return
                }

                if let image {
                    ImageCacheManager.shared.saveImage(image, for: url)
                    if let remoteArtworkKey = self.remoteAudioArtworkCacheKey(for: url, sourceFile: sourceFile) {
                        ImageCacheManager.shared.saveImage(image, forKey: remoteArtworkKey)
                    }
                    self.image = image
                    self.isLoading = false
                    self.independentThumbnailGenerator = nil
                    return
                }

                self.independentThumbnailGenerator = nil
                self.loadRemoteAudioArtworkViaDownload(for: url, sourceFile: sourceFile)
            }
        }
    }

    private func loadRemoteAudioArtworkViaDownload(for url: URL, sourceFile: VideoFile) {
        currentLoadTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let loadedImage = try await self.runRemoteRequest {
                    await self.fetchRemoteAudioArtwork(for: url, sourceFile: sourceFile)
                }
                if Task.isCancelled {
                    return
                }

                await MainActor.run {
                    guard self.url == url else { return }
                    if let loadedImage {
                        ImageCacheManager.shared.saveImage(loadedImage, for: url)
                        if let remoteArtworkKey = self.remoteAudioArtworkCacheKey(for: url, sourceFile: sourceFile) {
                            ImageCacheManager.shared.saveImage(loadedImage, forKey: remoteArtworkKey)
                        }
                        self.image = loadedImage
                    }
                    self.isLoading = false
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    if self.url == url {
                        self.isLoading = false
                    }
                }
            }
        }
    }

    private func fetchRemoteAudioArtwork(for url: URL, sourceFile: VideoFile) async -> UIImage? {
        guard let server = sourceFile.resolvedServer else {
            return nil
        }

        let remotePath = resolvedRemotePath(for: url, sourceFile: sourceFile)

        do {
            let tempURL = try await AppNetworkService.shared.downloadFile(server: server, at: remotePath)
            defer { cleanupTemporaryDownload(at: tempURL) }

            if Task.isCancelled {
                return nil
            }

            return extractAudioArtwork(from: tempURL)
        } catch {
            return nil
        }
    }

    private func extractAudioArtwork(from fileURL: URL) -> UIImage? {
        let asset = AVURLAsset(url: fileURL)

        if let image = extractArtwork(from: asset.commonMetadata) {
            return image
        }

        for format in asset.availableMetadataFormats {
            let metadata = asset.metadata(forFormat: format)
            if let image = extractArtwork(from: metadata) {
                return image
            }
        }

        return nil
    }

    private func extractArtwork(from metadataItems: [AVMetadataItem]) -> UIImage? {
        if let commonArtwork = metadataItems.first(where: { $0.commonKey == .commonKeyArtwork }),
           let image = decodeArtworkImage(from: commonArtwork) {
            return image
        }

        for item in metadataItems {
            let identifier = item.identifier?.rawValue.lowercased() ?? ""
            let isArtworkIdentifier = identifier.contains("artwork")
                || identifier.contains("cover")
                || identifier.contains("covr")
                || identifier.contains("apic")
            if isArtworkIdentifier, let image = decodeArtworkImage(from: item) {
                return image
            }
        }

        return nil
    }

    private func decodeArtworkImage(from item: AVMetadataItem) -> UIImage? {
        if let data = item.dataValue, let image = UIImage(data: data) {
            return image
        }
        if let data = item.value as? Data, let image = UIImage(data: data) {
            return image
        }
        if let image = item.value as? UIImage {
            return image
        }
        return nil
    }

    private func loadRemoteFileImage(for url: URL, sourceFile: VideoFile?) {
        currentLoadTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let loadedImage = try await self.runRemoteRequest {
                    await self.fetchRemoteFileImage(for: url, sourceFile: sourceFile)
                }
                if Task.isCancelled {
                    return
                }

                await MainActor.run {
                    guard self.url == url else { return }
                    if let loadedImage {
                        ImageCacheManager.shared.saveImage(loadedImage, for: url)
                        if let remotePreviewKey = self.remoteFilePreviewCacheKey(for: url, sourceFile: sourceFile) {
                            ImageCacheManager.shared.saveImage(loadedImage, forKey: remotePreviewKey)
                        }
                        self.image = loadedImage
                    }
                    self.isLoading = false
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    if self.url == url {
                        self.isLoading = false
                    }
                }
            }
        }
    }

    private func fetchRemoteFileImage(for url: URL, sourceFile: VideoFile?) async -> UIImage? {
        let probeFile = sourceFile ?? VideoFile(
            name: url.lastPathComponent,
            url: url,
            type: .image,
            size: 0,
            date: Date(),
            isRemote: true
        )
        guard let server = probeFile.resolvedServer else {
            return nil
        }

        let remotePath = resolvedRemotePath(for: url, sourceFile: probeFile)

        do {
            let tempURL = try await AppNetworkService.shared.downloadFile(server: server, at: remotePath)
            defer { cleanupTemporaryDownload(at: tempURL) }

            if Task.isCancelled {
                return nil
            }

            if let decodedImage = UIImage(contentsOfFile: tempURL.path) {
                return decodedImage
            }

            guard let data = try? Data(contentsOf: tempURL),
                  let decodedImage = UIImage(data: data) else {
                return nil
            }
            return decodedImage
        } catch {
            return nil
        }
    }

    private func cleanupTemporaryDownload(at fileURL: URL) {
        let containerURL = fileURL.deletingLastPathComponent()
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: containerURL)
    }
    
    // MARK: - Remote URL Fetching
    private func loadRemoteImage(for url: URL, sourceFile: VideoFile?) {
        currentLoadTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                let loadedImage = try await self.runRemoteRequest {
                    try await self.fetchRemoteImage(for: url, sourceFile: sourceFile)
                }
                if Task.isCancelled {
                    return
                }

                await MainActor.run {
                    guard self.url == url else { return }

                    if let loadedImage {
                        ImageCacheManager.shared.saveImage(loadedImage, for: url)
                        if let remotePreviewKey = self.remoteFilePreviewCacheKey(for: url, sourceFile: sourceFile) {
                            ImageCacheManager.shared.saveImage(loadedImage, forKey: remotePreviewKey)
                        }
                        self.image = loadedImage
                    }
                    self.isLoading = false
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    if self.url == url {
                        self.isLoading = false
                    }
                }
            }
        }
    }

    private func fetchRemoteImage(for url: URL, sourceFile: VideoFile?) async throws -> UIImage? {
        let request: URLRequest

        if let sourceFile,
           let server = sourceFile.resolvedServer,
           server.type == .webdav {
            let remotePath = resolvedRemotePath(for: url, sourceFile: sourceFile)
            if let downloadRequest = AppNetworkService.shared.downloadRequest(server: server, at: remotePath) {
                request = downloadRequest
            } else {
                return nil
            }
        } else {
            request = URLRequest(url: MediaImageCacheIdentity.requestURL(from: url))
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                    self?.currentTask = nil

                    if let error = error as NSError? {
                        if error.code == URLError.cancelled.rawValue {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            continuation.resume(throwing: error)
                        }
                        return
                    }

                    guard let data, let image = UIImage(data: data) else {
                        continuation.resume(returning: nil)
                        return
                    }

                    continuation.resume(returning: image)
                }

                self.currentTask = task
                task.resume()
            }
        }, onCancel: { [weak self] in
            self?.currentTask?.cancel()
            self?.currentTask = nil
        })
    }

    private func runRemoteRequest<T>(operation: @escaping () async throws -> T) async throws -> T {
        let requestID = UUID()
        try await RemoteImageRequestLimiter.shared.acquire(requestID: requestID)
        defer {
            Task {
                await RemoteImageRequestLimiter.shared.release()
            }
        }

        try Task.checkCancellation()
        return try await operation()
    }

    private func generateIndependentThumbnail(for url: URL, sourceFile: VideoFile?) async -> UIImage? {
        let continuationBox = IndependentThumbnailContinuationBox()

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
                continuationBox.store(continuation)

                DispatchQueue.main.async { [weak self] in
                    guard let self = self else {
                        continuationBox.resume(with: nil)
                        return
                    }

                    var finalURL = url
                    if url.scheme?.lowercased() == "smb",
                       let server = sourceFile?.resolvedServer ?? AppNetworkService.shared.servers.first(where: { $0.address.lowercased() == url.host?.lowercased() }),
                       let user = server.username,
                       let pwd = KeychainService.get(for: server.id.uuidString),
                       var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                        components.user = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed)
                        components.password = pwd.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed)
                        if let newURL = components.url {
                            finalURL = newURL
                        }
                    }

                    let generator = IndependentMediaThumbnailGenerator()
                    self.independentThumbnailGenerator = generator
                    generator.generateThumbnail(for: finalURL, provider: sourceFile?.serverType?.rawValue, serverID: sourceFile?.jellyfinServerId, path: sourceFile?.serverPath, itemID: sourceFile?.jellyfinItemId, isAudio: sourceFile.map { $0.type == .audio }) { [weak self] image in
                        self?.independentThumbnailGenerator = nil
                        continuationBox.resume(with: image)
                    }
                }
            }
        }, onCancel: { [weak self] in
            DispatchQueue.main.async {
                self?.independentThumbnailGenerator?.cancel()
                self?.independentThumbnailGenerator = nil
                continuationBox.resume(with: nil)
            }
        })
    }
}

// MARK: - Independent Thumbnail Fallback
struct RemoteImage: View {
    let url: URL?
    var sourceFile: VideoFile? = nil
    var placeholderSystemImage: String = "film"
    var placeholderTint: Color = .gray
    var contentMode: ContentMode = .fill
    var isActive: Bool = true
    var permitNetworkForAudioArtwork: Bool = false
    var permitNetworkForVideoArtwork: Bool = false
    var onImageLoaded: ((UIImage) -> Void)? = nil
    
    @StateObject private var loader = RemoteImageLoader()
    
    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .id(url?.absoluteString ?? "remote-image")
                    .onAppear {
                        onImageLoaded?(image)
                    }
            } else if loader.isLoading {
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .overlay(ProgressView())
            } else {
                Rectangle()
                    .fill(Color.gray.opacity(0.3))
                    .overlay(
                        Image(systemName: placeholderSystemImage)
                            .font(.title)
                            .foregroundColor(placeholderTint)
                    )
            }
        }
        .onAppear {
            if isActive {
                loader.load(url: url, sourceFile: sourceFile, permitNetworkForAudioArtwork: permitNetworkForAudioArtwork, permitNetworkForVideoArtwork: permitNetworkForVideoArtwork)
            }
        }
        .onChange(of: url) { newUrl in
            if isActive {
                loader.load(url: newUrl, sourceFile: sourceFile, permitNetworkForAudioArtwork: permitNetworkForAudioArtwork, permitNetworkForVideoArtwork: permitNetworkForVideoArtwork)
            } else {
                loader.cancel()
            }
        }
        .onChange(of: isActive) { newValue in
            if newValue {
                loader.load(url: url, sourceFile: sourceFile, permitNetworkForAudioArtwork: permitNetworkForAudioArtwork, permitNetworkForVideoArtwork: permitNetworkForVideoArtwork)
            } else {
                loader.cancel()
            }
        }
        .onDisappear {
            loader.cancel()
        }
    }
}

struct RemoteLogoImage: View {
    let url: URL?
    var maxHeight: CGFloat = 80
    
    @StateObject private var loader = RemoteImageLoader()
    
    var body: some View {
        Group {
            if let image = loader.image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: maxHeight)
                    .id(url?.absoluteString ?? "remote-logo-image")
            } else {
                Color.clear
                    .frame(width: 1, height: maxHeight)
            }
        }
        .onAppear {
            loader.load(url: url)
        }
        .onChange(of: url) { newUrl in
            loader.load(url: newUrl)
        }
        .onDisappear {
            loader.cancel()
        }
    }
}

