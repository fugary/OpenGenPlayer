import Foundation

/// Rendering capability is separate from text extraction/search capability.
/// mpv cannot select one bitmap track in both slots; text can mirror decoded cues.
public struct MPVSecondarySubtitleRendering: Equatable {
    public let trackID: Int
    public let isBitmap: Bool
    public let isASS: Bool

    public init?(trackID: Int, tracks: [MacMPVTrack]) {
        let matches = tracks.filter { $0.type == "sub" && $0.id == trackID }
        guard trackID >= 0, matches.count == 1, let track = matches.first else { return nil }
        self.trackID = trackID
        self.isBitmap = track.isBitmap
        self.isASS = ["ass", "ssa"].contains(track.codec.lowercased())
    }

    /// The bridge renders same-track ASS with a second libass renderer sharing
    /// the decoded events/fonts; it does not select the decoder in two slots.
    public func rendersASSNatively(primary: Int) -> Bool { isASS }

    /// Move the final native layer; never override the script's ASS styles.
    public static func assOverride(hasCustomPosition: Bool) -> String {
        "no" // Final bitmap geometry handles movement without changing ASS styles.
    }

    public static func adjustmentRect(bounds: CGRect?, viewport: CGRect, fallbackCenterY: CGFloat? = nil) -> CGRect {
        guard let bounds, !bounds.isEmpty, !bounds.isInfinite, !bounds.isNull else {
            return CGRect(x: viewport.midX - min(220, viewport.width) / 2,
                          y: (fallbackCenterY ?? (viewport.maxY - 68)) - 24,
                          width: min(220, viewport.width), height: 48)
        }
        let rect = CGRect(x: viewport.minX + bounds.minX * viewport.width,
                          y: viewport.minY + bounds.minY * viewport.height,
                          width: bounds.width * viewport.width, height: bounds.height * viewport.height)
        return rect.insetBy(dx: -8, dy: -6)
    }

    public func canSelect(primary: Int) -> Bool { !isBitmap || primary != trackID }

    public func isSelected(primary: Int, secondary: Int) -> Bool {
        secondary == trackID || (!isBitmap && primary == trackID)
    }

    /// Preserve the app's existing time + delay convention for the second slot.
    public static func nativeDelay(primary: Double, secondary: Double = 0) -> Double {
        -(primary.isFinite ? primary : 0) - (secondary.isFinite ? secondary : 0)
    }

    /// The legacy VLC second-subtitle timeline advances for positive delay.
    /// Native mpv and the same-track text mirror must query that same source time.
    public static func sourceTime(playbackTime: Double, primary: Double, secondary: Double = 0) -> Double {
        playbackTime - nativeDelay(primary: primary, secondary: secondary)
    }

    /// Percentage of the original bitmap position. Lower-half cues can move up;
    /// mpv deliberately keeps upper-half/full-screen graphics at authored positions.
    public static func nativePosition(ratio: Double) -> Double {
        min(100, max(0, (ratio.isFinite ? ratio : 1) * 100))
    }
}
