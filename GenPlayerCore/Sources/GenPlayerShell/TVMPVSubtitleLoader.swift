import Foundation

/// Bounded, cancellable sidecar reads, independent of the TV playback connection.
enum TVMPVSubtitleLoader {
    static let maximumBytes: UInt64 = 8 * 1024 * 1024
    private static let chunkBytes = 1024 * 1024

    enum Failure: Error { case sizeLimit, incompleteRead }

    static func fileExtension(forCodec codec: String?) -> String {
        let value = codec?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        switch value {
        case "subrip": return "srt"
        case "webvtt": return "vtt"
        case "": return "srt"
        default: return value
        }
    }

    static func requiresDownload(_ url: URL) -> Bool {
        ["smb", "ftp", "ftps", "sftp", "nfs"].contains(url.scheme?.lowercased() ?? "")
    }

    static func load(size: UInt64, read: (UInt64, Int) async throws -> Data) async throws -> Data {
        try Task.checkCancellation()
        guard size > 0, size <= maximumBytes else { throw Failure.sizeLimit }
        var data = Data()
        while UInt64(data.count) < size {
            try Task.checkCancellation()
            let count = Int(min(UInt64(chunkBytes), size - UInt64(data.count)))
            let chunk = try await read(UInt64(data.count), count)
            try Task.checkCancellation()
            guard chunk.count == count else { throw Failure.incompleteRead }
            data.append(chunk)
        }
        return data
    }
}
