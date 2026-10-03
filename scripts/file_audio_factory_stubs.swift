import Foundation

// Service substitutes only for the standalone factory/lifecycle harness. Actual
// NAS/cloud services and linkage are checked by the platform builds, not these stubs.
public enum ServerType: String { case webdav, ftp, sftp, nfs, alist, pan115 = "115", onedrive, googledrive }
public struct ServerConfig {
    public let id: UUID
    public let type: ServerType
    public let address: String
    public var username: String? = nil, passwordSecret: String? = nil, accessToken: String? = nil
}
final class FactoryCalls: @unchecked Sendable {
    static let shared = FactoryCalls()
    private let lock = NSLock()
    private var entries: [String] = []
    func record(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
    func values() -> [String] { lock.lock(); defer { lock.unlock() }; return entries }
}
final class AppNetworkService {
    static let shared = AppNetworkService()
    var servers: [ServerConfig] = []
    func aListAudioRangeRequest(server: ServerConfig, path: String) async throws -> URLRequest {
        FactoryCalls.shared.record("alist"); return URLRequest(url: URL(string: server.address)!)
    }
}
struct WebDAVManager {
    func downloadRequest(server: ServerConfig, at path: String) -> URLRequest? {
        FactoryCalls.shared.record("webdav"); return URLRequest(url: URL(string: server.address)!)
    }
}
final class Pan115Manager {
    static let shared = Pan115Manager(), defaultUserAgent = "test"
    func rawDownloadURL(server: ServerConfig, at path: String, pickcode: String?, cookie: String, originalOnly: Bool) async throws -> URL {
        precondition(originalOnly, "115 audio must request original bytes")
        FactoryCalls.shared.record("115-original"); return URL(string: server.address)!
    }
}
final class OneDriveManager {
    static let shared = OneDriveManager()
    func rawDownloadURL(server: ServerConfig, at path: String, forceRefresh: Bool) async throws -> URL {
        FactoryCalls.shared.record("onedrive-\(forceRefresh)"); return URL(string: server.address)!
    }
}
final class GoogleDriveManager {
    static let shared = GoogleDriveManager()
    func audioRangeRequest(server: ServerConfig, path: String, fileID: String?, forceRefresh: Bool) async throws -> URLRequest {
        FactoryCalls.shared.record("googledrive-\(forceRefresh)"); return URLRequest(url: URL(string: server.address)!)
    }
}
final class SFTPBrowserService {
    static let shared = SFTPBrowserService()
    func audioRangeSource(server: ServerConfig, path: String) -> any AudioRangeSource { fatalError("Native SFTP is not simulated by HTTP fixtures") }
}
