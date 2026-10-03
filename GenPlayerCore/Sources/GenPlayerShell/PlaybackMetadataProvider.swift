import Foundation
import GenPlayerCore

public struct PlaybackMetadataSnapshot {
    public let title: String?
    public let artist: String?
    public let album: String?
    public let artwork: AppImage?
    public let artworkURL: URL?
}

/// Metadata parsing does not create, start, seek, or replace a playback engine.
public protocol PlaybackMetadataProvider: AnyObject {
    func beginParsing()
    var metadata: PlaybackMetadataSnapshot { get }
}
