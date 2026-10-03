import Foundation
import CoreGraphics

/// Independent preview work; never seeks or replaces the primary playback session.
/// Call generate/cancel on the presentation queue. Results return on the main queue.
public protocol PlaybackPreviewProvider: AnyObject {
    func generate(snapshotPosition: Float, completion: @escaping (CGImage?) -> Void)
    func cancel()
}
