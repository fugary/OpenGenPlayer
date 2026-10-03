#if (os(macOS) || os(iOS) || os(tvOS)) && canImport(NFSKit)
import Foundation
import NFSKit
import nfs

enum NFSAudioRangeSource {
    static func make(url: URL, server: ServerConfig?) async throws -> any AudioRangeSource {
        guard let host = url.host, url.scheme == "nfs", !url.path.isEmpty,
              !url.path.contains("\0") else { throw URLError(.badURL) }
        let address = server?.address ?? ""
        let configuredPath = URLComponents(string: address.contains("://") ? address : "nfs://" + address)?.path ?? ""
        let configured = "/" + configuredPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = url.path
        let export: String
        if configured != "/", path.hasPrefix(configured + "/") {
            export = configured
        } else {
            var endpoint = URLComponents(); endpoint.scheme = "nfs"; endpoint.host = host
            guard let endpoint = endpoint.url, let client = try NFSClient(url: endpoint) else { throw URLError(.badURL) }
            client.timeout = 15
            let exports = try await client.listExports().get()
            try Task.checkCancellation()
            guard let match = exports.filter({ $0 != "/" && path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") || $0 == "/" })
                .sorted(by: { $0.count > $1.count }).first else { throw AudioRangeFailure.unsupported }
            export = match.hasSuffix("/") && match != "/" ? String(match.dropLast()) : match
        }
        let relative = export == "/" ? path : String(path.dropFirst(export.count))
        guard relative.hasPrefix("/"), relative.count > 1 else { throw AudioRangeFailure.invalidResponse }
        return BlockingAudioRangeSource { try NFSRangeFile(host: host, export: export, path: relative, port: url.port) }
    }
}

private final class NFSRangeFile: BlockingAudioFile {
    private let context: UnsafeMutablePointer<nfs_context>
    private let file: UnsafeMutablePointer<nfsfh>
    init(host: String, export: String, path: String, port: Int?) throws {
        guard let context = nfs_init_context() else { throw AudioRangeFailure.invalidResponse }
        self.context = context
        nfs_set_timeout(context, 15_000)
        // Audio offsets skip video packets; sequential read-ahead would fetch
        // unrelated media and defeat the MP4 reader's transfer budget.
        nfs_set_readahead(context, 0)
        nfs_set_pagecache(context, 0)
        if let port, let value = Int32(exactly: port) { nfs_set_nfsport(context, value) }
        guard nfs_mount(context, host, export) == 0 else { nfs_destroy_context(context); throw URLError(.cannotConnectToHost) }
        // Match NFSKit's existing export-owner authentication convention.
        var root = nfs_stat_64()
        if nfs_stat64(context, "/", &root) == 0,
           let uid = Int32(exactly: root.nfs_uid), let gid = Int32(exactly: root.nfs_gid) {
            nfs_set_uid(context, uid); nfs_set_gid(context, gid)
        }
        var handle: UnsafeMutablePointer<nfsfh>?
        guard nfs_open(context, path, O_RDONLY, &handle) == 0, let handle else {
            nfs_destroy_context(context); throw AudioRangeFailure.invalidResponse
        }
        file = handle
    }
    deinit { _ = nfs_close(context, file); nfs_destroy_context(context) }
    func metadata() throws -> AudioFileVersion {
        var info = nfs_stat_64()
        guard nfs_fstat64(context, file, &info) == 0, info.nfs_size > 0 else { throw AudioRangeFailure.invalidResponse }
        return .init(size: info.nfs_size, stamp: "\(info.nfs_ino):\(info.nfs_mtime):\(info.nfs_mtime_nsec)")
    }
    func read(offset: UInt64, count: Int, cancellation: AudioReadCancellation) throws -> Data {
        var result = Data()
        while result.count < count {
            try cancellation.check()
            var buffer = [UInt8](repeating: 0, count: min(64 * 1024, count - result.count))
            let read = nfs_pread(context, file, offset + UInt64(result.count), UInt64(buffer.count), &buffer)
            guard read > 0, read <= buffer.count else { throw AudioRangeFailure.invalidResponse }
            result.append(contentsOf: buffer.prefix(Int(read)))
        }
        return result
    }
}
#endif
