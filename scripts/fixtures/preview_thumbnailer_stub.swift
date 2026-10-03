import Foundation
import CoreGraphics
import AppKit

public final class VLCMedia {
    public struct ParseOptions: OptionSet {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let fetchLocal = Self(rawValue: 1)
    }
    public final class Metadata {
        public var title: String?
        public var artist: String?
        public var album: String?
        public var artwork: NSImage?
        public var artworkURL: URL?
    }
    public let metaData = Metadata()
    public private(set) var parseCount = 0
    public func parse(options: ParseOptions) -> Int { parseCount += 1; return 0 }
}
public protocol VLCMediaThumbnailerDelegate: AnyObject {
    func mediaThumbnailerDidTimeOut(_ request: VLCMediaThumbnailer)
    func mediaThumbnailer(_ request: VLCMediaThumbnailer, didFinishThumbnail image: CGImage)
}
public final class VLCMediaThumbnailer: NSObject {
    public static var requests: [VLCMediaThumbnailer] = []
    public var thumbnailWidth: CGFloat = 0
    public var snapshotPosition: Float = 0
    public private(set) var cancelled = false
    public weak var delegate: (any VLCMediaThumbnailerDelegate)?
    public init(media: VLCMedia, andDelegate delegate: any VLCMediaThumbnailerDelegate) {
        self.delegate = delegate
    }
    public func fetchThumbnail() { Self.requests.append(self) }
    @objc public func cancelThumbnail() { cancelled = true; delegate?.mediaThumbnailerDidTimeOut(self) }
}
public func makePreviewTestMedia() -> VLCMedia { VLCMedia() }
