import Foundation
import CryptoKit

/// Pending legacy name/ordinal preferences are retried when asynchronous tracks arrive.
/// Preserve the VLC precedence: a matching name wins over the ordinal fallback.
public enum IOSMPVTrackPreference {
    public static func resolve(query: String?, ordinal: Int?, tracks: [MacMPVTrack], displayNames: [String]? = nil) -> Int? {
        guard Set(tracks.map(\.id)).count == tracks.count,
              displayNames == nil || displayNames?.count == tracks.count else { return nil }
        let names = displayNames ?? tracks.map {
            [$0.title, $0.language, $0.codec].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        if let query = query?.trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty,
           let index = names.firstIndex(where: { $0.localizedCaseInsensitiveContains(query) }) {
            return tracks[index].id
        }
        guard let ordinal, tracks.indices.contains(ordinal) else { return nil }
        return tracks[ordinal].id
    }
}

/// A transient selection for reopening the SAME media with another engine.
/// Engine track IDs are never portable; sidecars are carried by their source URL.
public typealias IOSPlaybackTrackSelection = PlaybackTrackSelection

public enum PlaybackTrackSelection: Equatable, Sendable {
    case off
    case embedded(ordinal: Int, count: Int)

    public static func capture(id: Int, embeddedIDs: [Int]) -> Self? {
        if id == -1 { return .off }
        guard Set(embeddedIDs).count == embeddedIDs.count,
              let ordinal = embeddedIDs.firstIndex(of: id) else { return nil }
        return .embedded(ordinal: ordinal, count: embeddedIDs.count)
    }

    public func resolve(embeddedIDs: [Int]) -> Int? {
        switch self {
        case .off: return -1
        case let .embedded(ordinal, count):
            guard embeddedIDs.count == count, Set(embeddedIDs).count == count,
                  embeddedIDs.indices.contains(ordinal) else { return nil }
            return embeddedIDs[ordinal]
        }
    }

    /// Only real series IDs or file directories define an inheritance scope.
    /// HTTP playback endpoints (e.g. /Videos/id/stream) are not media directories.
    public static func scopeKey(url: URL, provider: String?, serverID: String?,
                                seriesID: String?, filePath: String?, libraryItemID: String?) -> String? {
        let identity: [String]
        if let serverID, let seriesID, !seriesID.isEmpty {
            identity = [provider ?? "", serverID, "series", seriesID]
        } else if url.isFileURL, libraryItemID == nil {
            identity = ["local-directory", url.standardizedFileURL.deletingLastPathComponent().path]
        } else if libraryItemID == nil, let provider, let serverID,
                  ["smb", "webdav", "ftp", "sftp", "nfs"].contains(provider.lowercased()),
                  let filePath, filePath.hasPrefix("/") {
            identity = [provider, serverID, "directory", (filePath as NSString).deletingLastPathComponent]
        } else { return nil }
        guard let data = try? JSONEncoder().encode(identity) else { return nil }
        return "ios.mpv.trackScope." + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Runtime-only second-subtitle handoff. A failed native mapping must never fall back to a reused menu ID.
public typealias IOSPlaybackSecondarySelection = PlaybackSecondarySelection

public struct PlaybackSecondarySelection: Equatable, Sendable {
    public struct Candidate {
        public let id: String
        public let sourceURL: URL?
        public let nativeID: Int?
        public init(id: String, sourceURL: URL?, nativeID: Int?) {
            self.id = id; self.sourceURL = sourceURL; self.nativeID = nativeID
        }
    }
    public let selection: IOSPlaybackTrackSelection?
    public let sourceURL: URL?
    public let descriptorID: String?
    public init(selection: IOSPlaybackTrackSelection?, sourceURL: URL?, descriptorID: String?) {
        self.selection = selection; self.sourceURL = sourceURL; self.descriptorID = descriptorID
    }
    public func resolve(candidates: [Candidate], embeddedIDs: [Int]) -> String? {
        if selection == .off { return nil }
        if let sourceURL, let match = candidates.first(where: { $0.sourceURL == sourceURL }) { return match.id }
        if let selection {
            guard let nativeID = selection.resolve(embeddedIDs: embeddedIDs) else { return nil }
            return candidates.first { $0.nativeID == nativeID }?.id
        }
        guard let descriptorID else { return nil }
        return candidates.first { $0.id == descriptorID }?.id
    }
}
