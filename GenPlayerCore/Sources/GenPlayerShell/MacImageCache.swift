#if os(macOS)
import AppKit
import CryptoKit
import SwiftUI

class MacImageCache {
    static let shared = MacImageCache()
    
    private let memoryCache = NSCache<NSString, NSImage>()
    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    
    private init() {
        memoryCache.totalCostLimit = 1024 * 1024 * 50 // 50MB
        
        let paths = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)
        cacheDirectory = paths[0].appendingPathComponent("GenPlayerMacImageCache")
        
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true, attributes: nil)
        }
    }
    
    func getImage(for url: URL) -> NSImage? {
        let key = url.absoluteString
        if let image = memoryCache.object(forKey: key as NSString) {
            return image
        }
        
        let fileURL = getCacheFileURL(for: key)
        if let image = NSImage(contentsOf: fileURL) {
            let cost = Int(image.size.width * image.size.height * 4)
            memoryCache.setObject(image, forKey: key as NSString, cost: cost)
            return image
        }
        
        return nil
    }
    
    func saveImage(_ image: NSImage, for url: URL) {
        let key = url.absoluteString
        let cost = Int(image.size.width * image.size.height * 4)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)
        
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            let fileURL = self.getCacheFileURL(for: key)
            if let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) {
                let data = bitmap.representation(using: .png, properties: [:]) ?? bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8])
                try? data?.write(to: fileURL)
            }
        }
    }
    
    func clearCache(completion: (() -> Void)? = nil) {
        memoryCache.removeAllObjects()
        URLCache.shared.removeAllCachedResponses()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let fileURLs = try self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
                for fileURL in fileURLs {
                    try self.fileManager.removeItem(at: fileURL)
                }
            } catch {
                print("Error clearing disk cache: \(error)")
            }
            DispatchQueue.main.async {
                completion?()
            }
        }
    }
    
    func calculateSize(completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            var totalBytes: Int64 = Int64(URLCache.shared.currentDiskUsage)
            do {
                let fileURLs = try self.fileManager.contentsOfDirectory(at: self.cacheDirectory, includingPropertiesForKeys: [.fileSizeKey], options: .skipsHiddenFiles)
                for fileURL in fileURLs {
                    if let resources = try? fileURL.resourceValues(forKeys: [.fileSizeKey]), let fileSize = resources.fileSize {
                        totalBytes += Int64(fileSize)
                    }
                }
            } catch {
                print("Error calculating cache size: \(error)")
            }
            
            DispatchQueue.main.async {
                let formatter = ByteCountFormatter()
                formatter.countStyle = .file
                completion(formatter.string(fromByteCount: totalBytes))
            }
        }
    }
    
    private func getCacheFileURL(for key: String) -> URL {
        let hashedName = md5(key)
        return cacheDirectory.appendingPathComponent(hashedName)
    }
    
    private func md5(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum MacCachedImagePhase {
    case empty
    case success(Image)
    case failure(Error)
    
    var image: Image? {
        if case .success(let img) = self {
            return img
        }
        return nil
    }
    
    var error: Error? {
        if case .failure(let err) = self {
            return err
        }
        return nil
    }
}

@MainActor
class MacImageLoader: ObservableObject {
    @Published var phase: MacCachedImagePhase = .empty
    
    private var currentTask: Task<Void, Never>?
    
    func load(urls: [URL]) {
        currentTask?.cancel()
        currentTask = nil
        
        let validURLs = urls.filter { !$0.absoluteString.isEmpty }
        guard !validURLs.isEmpty else {
            self.phase = .empty
            return
        }
        
        for url in validURLs {
            if let cached = MacImageCache.shared.getImage(for: url) {
                self.phase = .success(Image(nsImage: cached))
                return
            }
        }
        
        self.phase = .empty
        
        currentTask = Task { @MainActor [weak self] in
            guard let self = self else { return }
            for url in validURLs {
                if Task.isCancelled { return }
                do {
                    print("MacImageLoader: trying \(url.absoluteString)")
                    if url.isFileURL {
                        if let img = NSImage(contentsOf: url) {
                            MacImageCache.shared.saveImage(img, for: url)
                            if !Task.isCancelled {
                                self.phase = .success(Image(nsImage: img))
                                print("MacImageLoader: success local \(url.absoluteString)")
                                return
                            }
                        }
                    } else {
                        let (data, response) = try await URLSession.shared.data(from: url)
                        if let http = response as? HTTPURLResponse {
                            print("MacImageLoader: HTTP \(http.statusCode) for \(url.absoluteString)")
                            if (200...299).contains(http.statusCode) {
                                if let img = NSImage(data: data) {
                                    MacImageCache.shared.saveImage(img, for: url)
                                    if !Task.isCancelled {
                                        self.phase = .success(Image(nsImage: img))
                                        print("MacImageLoader: success remote \(url.absoluteString)")
                                        return
                                    }
                                } else {
                                    print("MacImageLoader: failed to decode NSImage for \(url.absoluteString) data size \(data.count)")
                                }
                            }
                        }
                    }
                } catch {
                    print("MacImageLoader: network error \(error) for \(url.absoluteString)")
                    continue
                }
            }
            if !Task.isCancelled {
                self.phase = .failure(URLError(.cannotDecodeContentData))
                print("MacImageLoader: failed all candidates")
            }
        }
    }

    func load(url: URL?) {
        if let url = url {
            load(urls: [url])
        } else {
            load(urls: [])
        }
    }
    
    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }
}

struct MacCachedAsyncImage<Content: View>: View {
    let urls: [URL]
    @ViewBuilder let content: (MacCachedImagePhase) -> Content
    
    @StateObject private var loader = MacImageLoader()
    
    init(url: URL?, @ViewBuilder content: @escaping (MacCachedImagePhase) -> Content) {
        self.urls = url != nil ? [url!] : []
        self.content = content
    }

    init(urls: [URL], @ViewBuilder content: @escaping (MacCachedImagePhase) -> Content) {
        self.urls = urls
        self.content = content
    }
    
    var body: some View {
        content(loader.phase)
            .onAppear {
                loader.load(urls: urls)
            }
            .onChange(of: urls) { newUrls in
                loader.load(urls: newUrls)
            }
            .onDisappear {
                loader.cancel()
            }
    }
}
#endif
