import Foundation
import Combine

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

public final class IPTVArtworkService: ObservableObject {
    public static let shared = IPTVArtworkService()
    
    @Published public private(set) var updateToken: UUID = UUID()
    
    private let fileManager = FileManager.default
    private let lock = NSLock()
    
    private var baseStorageURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("IPTV", isDirectory: true).appendingPathComponent("Thumbnails", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true, attributes: nil)
        }
        return dir
    }
    
    private init() {}
    
    // MARK: - Snapshot File Path Helper
    
    public func snapshotURL(for channelId: String, in serverId: UUID) -> URL? {
        let name = filename(for: channelId, in: serverId)
        let fileURL = baseStorageURL.appendingPathComponent(name)
        if fileManager.fileExists(atPath: fileURL.path) {
            return fileURL
        }
        return nil
    }
    
    public func snapshotURL(for channel: IPTVChannel, in server: ServerConfig) -> URL? {
        snapshotURL(for: channel.id, in: server.id)
    }
    
    public func snapshotPath(for channelId: String, in serverId: UUID) -> String {
        let name = filename(for: channelId, in: serverId)
        return baseStorageURL.appendingPathComponent(name).path
    }
    
    // MARK: - Save Snapshot
    
    @discardableResult
    public func saveSnapshot(data: Data, for channelId: String, in serverId: UUID) -> URL? {
        let name = filename(for: channelId, in: serverId)
        let targetURL = baseStorageURL.appendingPathComponent(name)
        
        lock.lock()
        defer { lock.unlock() }
        
        do {
            try data.write(to: targetURL, options: .atomic)
            DispatchQueue.main.async { [weak self] in
                self?.updateToken = UUID()
            }
            return targetURL
        } catch {
            NSLog("[IPTVArtworkService] Failed to save snapshot for %@: %@", channelId, error.localizedDescription)
            return nil
        }
    }
    
    @discardableResult
    public func saveSnapshot(from sourceURL: URL, for channelId: String, in serverId: UUID) -> URL? {
        let name = filename(for: channelId, in: serverId)
        let targetURL = baseStorageURL.appendingPathComponent(name)
        
        lock.lock()
        defer { lock.unlock() }
        
        do {
            if fileManager.fileExists(atPath: targetURL.path) {
                try? fileManager.removeItem(at: targetURL)
            }
            try fileManager.copyItem(at: sourceURL, to: targetURL)
            DispatchQueue.main.async { [weak self] in
                self?.updateToken = UUID()
            }
            return targetURL
        } catch {
            NSLog("[IPTVArtworkService] Failed to copy snapshot for %@: %@", channelId, error.localizedDescription)
            return nil
        }
    }
    
    public func notifySnapshotSaved() {
        DispatchQueue.main.async { [weak self] in
            self?.updateToken = UUID()
        }
    }
    
    // MARK: - Cleanup
    
    public func clearSnapshots(for serverId: UUID) {
        let prefix = "\(serverId.uuidString)_"
        lock.lock()
        defer { lock.unlock() }
        
        guard let files = try? fileManager.contentsOfDirectory(atPath: baseStorageURL.path) else { return }
        for file in files where file.hasPrefix(prefix) {
            let fullPath = baseStorageURL.appendingPathComponent(file)
            try? fileManager.removeItem(at: fullPath)
        }
        DispatchQueue.main.async { [weak self] in
            self?.updateToken = UUID()
        }
    }
    
    // MARK: - Private Helpers
    
    private func filename(for channelId: String, in serverId: UUID) -> String {
        let cleanId = channelId.replacingOccurrences(of: "[^a-zA-Z0-9_-]", with: "_", options: .regularExpression)
        let safeSuffix = String(cleanId.prefix(40))
        let hash = String(format: "%08x", channelId.hashValue)
        return "\(serverId.uuidString)_\(safeSuffix)_\(hash).jpg"
    }
}
