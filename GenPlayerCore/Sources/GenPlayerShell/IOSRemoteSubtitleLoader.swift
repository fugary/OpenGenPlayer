#if os(iOS) || os(macOS)
import Foundation
import GenPlayerCore

/// Read-only adapter for iOS subtitle browsing/translation. One instance per playback attempt.
/// Transport closures use an independent range reader, never the active player connection.
public actor IOSRemoteSubtitleLoader {
    public struct Version: Hashable {
        public let size: UInt64
        public let stamp: String
        public init(size: UInt64, stamp: String) { self.size = size; self.stamp = stamp }
    }
    private struct Key: Hashable {
        let identity: String
        let version: Version
        let ordinal: Int
        let count: Int
        let numbers: [UInt64]
    }
    private var cache: [Key: SubtitleBrowserDocument] = [:]

    public init() {}

    public func load(identity: String, ordinal: Int, count: Int, trackNumbers: [UInt64],
                     metadata: () async throws -> Version,
                     read: @escaping (UInt64, Int) async throws -> Data) async throws -> SubtitleBrowserDocument {
        // Require exact container identities, not just a coincidentally matching menu count.
        guard count > 0, (0..<count).contains(ordinal), trackNumbers.count == count,
              trackNumbers.allSatisfy({ $0 > 0 }), Set(trackNumbers).count == count else {
            throw SubtitleBrowserError.unreadable
        }
        try Task.checkCancellation()
        let version = try await metadata()
        try Task.checkCancellation()
        let key = Key(identity: identity, version: version, ordinal: ordinal, count: count, numbers: trackNumbers)
        if let cached = cache[key] { return cached }
        do {
            let result = try await MacRemoteSubtitleReader(size: version.size, read: read)
                .load(subtitleOrdinal: ordinal, expectedSubtitleCount: count, expectedTrackNumbers: trackNumbers)
            guard try await metadata() == version else { throw URLError(.resourceUnavailable) }
            try Task.checkCancellation()
            let document = SubtitleBrowserDocument(parts: result.parts, isPartial: result.indexed, partialStatusKey: "SB.Indexed")
            if cache.count >= 4 { cache.removeAll() }
            cache[key] = document
            return document
        } catch MacRemoteSubtitleReader.Failure.bitmap { throw SubtitleBrowserError.bitmap }
        catch MacRemoteSubtitleReader.Failure.limit { throw SubtitleBrowserError.remoteLimit }
        catch is MacRemoteSubtitleReader.Failure { throw SubtitleBrowserError.unreadable }
    }
}
#endif
