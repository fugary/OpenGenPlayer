import Foundation
import VLCKitSPM

public final class VLCPlaybackMetadataProvider: PlaybackMetadataProvider {
    private let media: VLCMedia
    public init(media: VLCMedia) { self.media = media }
    public func beginParsing() { _ = media.parse(options: .fetchLocal) }
    public var metadata: PlaybackMetadataSnapshot {
        let value = media.metaData
        return .init(title: value.title, artist: value.artist, album: value.album,
                     artwork: value.artwork, artworkURL: value.artworkURL)
    }
}
