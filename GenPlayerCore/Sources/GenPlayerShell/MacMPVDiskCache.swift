#if os(macOS) || os(iOS)
import Foundation

public enum MacMPVDiskCacheReason: String {
    case directory, space, option, statistics, limit
    public var localizationKey: String { "MPV.Cache.Reason." + rawValue }
}

public enum MacMPVDiskCacheMode: Equatable {
    case inactive, disk, memory
}

struct MacMPVDiskCacheMonitor {
    private var missingCount = 0
    mutating func fallbackReason(bytes: Int64?, free: Int64?, loaded: Bool) -> MacMPVDiskCacheReason? {
        guard let free else { return .statistics }
        if free <= MacMPVDiskCachePolicy.minimumFreeBytes { return .space }
        if let bytes, bytes >= MacMPVDiskCachePolicy.maximumFileBytes { return .limit }
        if loaded && (bytes == nil || bytes! < 0) { missingCount += 1 }
        else { missingCount = 0 }
        return missingCount >= 3 ? .statistics : nil
    }
}

/// A polling safeguard, not a filesystem quota. In-flight demux writes may overshoot.
enum MacMPVDiskCachePolicy {
    static let gib: Int64 = 1_073_741_824
    static let minimumStartFreeBytes = 6 * gib
    static let minimumFreeBytes = 2 * gib
    static let maximumFileBytes = 4 * gib

    static func canStart(freeBytes: Int64?) -> Bool {
        guard let freeBytes else { return false }
        return freeBytes >= minimumStartFreeBytes
    }

    static func mustFallBack(fileBytes: Int64?, freeBytes: Int64?) -> Bool {
        guard let fileBytes, let freeBytes, fileBytes >= 0 else { return true }
        return fileBytes >= maximumFileBytes || freeBytes <= minimumFreeBytes
    }

    static func freeBytes(at directory: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
              let bytes = attributes[.systemFreeSize] as? NSNumber else { return nil }
        return bytes.int64Value
    }

    static func prepareDirectory() -> URL? {
        guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let directory = root.appendingPathComponent("MPVPlaybackCache", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            return directory
        } catch { return nil }
    }
}
#endif
