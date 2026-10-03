#if os(iOS) || os(macOS)
import Foundation

/// The remote reader indexes original Matroska subtitle tracks, not player menu rows.
public struct IOSMPVRemoteSubtitleSelection: Equatable {
    public let trackID: Int
    public let ordinal: Int
    public let trackNumbers: [UInt64]
    public var count: Int { trackNumbers.count }

    public init?(selectedID: Int, tracks: [MacMPVTrack]) {
        let native = Self.nativeTracks(in: tracks)
        guard let ordinal = native.firstIndex(where: { $0.id == selectedID }) else { return nil }
        self.trackID = selectedID
        self.ordinal = ordinal
        self.trackNumbers = native.compactMap(\.sourceID)
    }

    public static func nativeTracks(in tracks: [MacMPVTrack]) -> [MacMPVTrack] {
        let native = tracks.filter { $0.type == "sub" && !$0.external }
        let numbers = native.compactMap(\.sourceID)
        guard !native.isEmpty, native.allSatisfy({ menuID(trackID: $0.id) != nil }),
              Set(native.map(\.id)).count == native.count,
              numbers.count == native.count, numbers.allSatisfy({ $0 > 0 }),
              Set(numbers).count == numbers.count else { return [] }
        return native
    }

    /// Native decoding uses the player's own IDs; it does not need Matroska source IDs.
    public static func playbackTracks(in tracks: [MacMPVTrack]) -> [MacMPVTrack] {
        let native = tracks.filter { $0.type == "sub" && !$0.external }
        guard native.allSatisfy({ menuID(trackID: $0.id) != nil }),
              Set(native.map(\.id)).count == native.count else { return [] }
        return native
    }

    public static func supportsText(codec: String) -> Bool {
        ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "tx3g", "text", "microdvd", "subviewer", "sami"].contains(codec.lowercased())
    }

    /// A disjoint menu namespace keeps late-arriving sidecars from shifting these menu identities.
    public static func menuID(trackID: Int) -> Int? {
        guard trackID >= 0, trackID <= Int(Int32.max) else { return nil }
        return -1_000_000 - trackID
    }
    public static func trackID(menuID: Int) -> Int? {
        guard menuID <= -1_000_000, menuID >= -1_000_000 - Int(Int32.max) else { return nil }
        return -1_000_000 - menuID
    }
}
#endif
