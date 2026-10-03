import Foundation

// Host-side transport substitute. Production SMB code is compiled separately by Xcode;
// these checks exercise the iOS adapter and real MP4 parser without a NAS or credentials.
public actor IOSSMBAudioTestTransport {
    public static let shared = IOSSMBAudioTestTransport()
    private var bytes = Data()
    private var fails = false
    private var delay: UInt64 = 0
    private var metadataCalls = 0
    private var reads = 0
    private var transferred = 0
    public func configure(bytes: Data, fails: Bool = false, delay: UInt64 = 0) {
        self.bytes = bytes; self.fails = fails; self.delay = delay
        metadataCalls = 0; reads = 0; transferred = 0
    }
    public func stats() -> (metadata: Int, reads: Int, transferred: Int) {
        (metadataCalls, reads, transferred)
    }
    func metadata() async throws -> SMBAudioRangeReader.Metadata {
        metadataCalls += 1
        let size = UInt64(bytes.count), fails = fails, delay = delay
        // Intentionally finish after cancellation to test rejection of stale callbacks.
        if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
        if fails { throw URLError(.cannotConnectToHost) }
        return .init(size: size, version: "fixture-v1")
    }
    func read(offset: UInt64, count: Int) throws -> Data {
        reads += 1
        guard offset <= UInt64(bytes.count), count >= 0, count <= bytes.count - Int(offset) else {
            throw URLError(.cannotDecodeContentData)
        }
        transferred += count
        return bytes.subdata(in: Int(offset)..<(Int(offset) + count))
    }
}

public final class SMBAudioRangeReader: Sendable {
    public struct Metadata: Sendable {
        public let size: UInt64
        public let version: String
    }
    public init(url: URL) {}
    public func metadata() async throws -> Metadata { try await IOSSMBAudioTestTransport.shared.metadata() }
    public func read(offset: UInt64, count: Int) async throws -> Data {
        try await IOSSMBAudioTestTransport.shared.read(offset: offset, count: count)
    }
}

public struct AudioFileVersion: Sendable { public let size: UInt64; public let stamp: String }
public struct FileAudioRangeReader: Sendable {
    public init(url: URL, provider: String?, serverID: String?, path: String?, itemID: String?) {}
    public static func supports(provider: String?, url: URL) -> Bool {
        switch provider {
        case "webdav", "alist", "115", "onedrive", "googledrive", nil: return ["http", "https"].contains(url.scheme ?? "")
        case "ftp": return ["ftp", "ftps"].contains(url.scheme ?? "")
        case "sftp": return url.scheme == "sftp"
        case "nfs": return url.scheme == "nfs"
        default: return false
        }
    }
    public func metadata() async throws -> AudioFileVersion {
        let value = try await IOSSMBAudioTestTransport.shared.metadata()
        return .init(size: value.size, stamp: value.version)
    }
    public func read(offset: UInt64, count: Int) async throws -> Data {
        try await IOSSMBAudioTestTransport.shared.read(offset: offset, count: count)
    }
}
