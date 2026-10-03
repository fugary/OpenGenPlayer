#if os(iOS) || os(macOS) || os(tvOS)
import Foundation
import GenPlayerCore

/// Independent original-file connection, shared authentication/version checks with
/// audio range reads. Never uses a live/transcoded media-server stream as a file.
public enum RemoteAudioArtworkReader {
    public static func supports(url: URL, provider: String?) -> Bool {
        url.scheme?.lowercased() == "smb" || FileAudioRangeReader.supports(provider: provider, url: url)
    }

    public static func read(url: URL, provider: String?, serverID: String?, path: String?, itemID: String?) async throws -> Data? {
        try await readMetadata(url: url, provider: provider, serverID: serverID, path: path, itemID: itemID)?.artwork
    }

    public static func readMetadata(url: URL, provider: String?, serverID: String?, path: String?, itemID: String?) async throws -> EmbeddedAudioArtworkReader.Metadata? {
        try Task.checkCancellation()
        if url.scheme?.lowercased() == "smb" {
            let reader = SMBAudioRangeReader(url: url)
            let size = try await reader.metadata().size
            try Task.checkCancellation()
            return try await EmbeddedAudioArtworkReader.readMetadata(size: size) {
                try await reader.read(offset: $0, count: $1)
            }
        }
        guard FileAudioRangeReader.supports(provider: provider, url: url) else { return nil }
        let reader = FileAudioRangeReader(url: url, provider: provider, serverID: serverID, path: path, itemID: itemID)
        let size = try await reader.metadata().size
        try Task.checkCancellation()
        return try await EmbeddedAudioArtworkReader.readMetadata(size: size) {
            try await reader.read(offset: $0, count: $1)
        }
    }
}
#endif
