import Foundation

public enum RemotePlaybackQualityPreset: String, Codable, CaseIterable {
    case auto
    case original
    case p1080
    case p720
    case p480
}

public struct RemotePlaybackQualityOption: Identifiable, Equatable {
    public let preset: RemotePlaybackQualityPreset
    public let title: String
    public let subtitle: String?
    public let maxStreamingBitrate: Int?
    public let maxWidth: Int?
    public let maxHeight: Int?
    public let prefersDirectPlay: Bool
    public let allowsTranscoding: Bool

    public var id: String { preset.rawValue }

    public var prefersConstrainedPlayback: Bool {
        switch preset {
        case .p1080, .p720, .p480:
            return true
        case .auto, .original:
            return false
        }
    }

    public var allowsDirectPlay: Bool {
        switch preset {
        case .auto, .original:
            return true
        case .p1080, .p720, .p480:
            return false
        }
    }

    public var allowsDirectStream: Bool {
        switch preset {
        case .auto, .original:
            return true
        case .p1080, .p720, .p480:
            return false
        }
    }

    public static let auto = RemotePlaybackQualityOption(
        preset: .auto,
        title: NSLocalizedString("Auto", comment: ""),
        subtitle: NSLocalizedString("Prefer smooth playback", comment: ""),
        maxStreamingBitrate: nil,
        maxWidth: nil,
        maxHeight: nil,
        prefersDirectPlay: true,
        allowsTranscoding: true
    )

    public static let original = RemotePlaybackQualityOption(
        preset: .original,
        title: NSLocalizedString("Original", comment: ""),
        subtitle: NSLocalizedString("Prefer original quality", comment: ""),
        maxStreamingBitrate: nil,
        maxWidth: nil,
        maxHeight: nil,
        prefersDirectPlay: true,
        allowsTranscoding: false
    )

    public static let p1080 = RemotePlaybackQualityOption(
        preset: .p1080,
        title: "1080p",
        subtitle: NSLocalizedString("Up to 1080p", comment: ""),
        maxStreamingBitrate: 8_000_000,
        maxWidth: 1920,
        maxHeight: 1080,
        prefersDirectPlay: false,
        allowsTranscoding: true
    )

    public static let p720 = RemotePlaybackQualityOption(
        preset: .p720,
        title: "720p",
        subtitle: NSLocalizedString("Up to 720p", comment: ""),
        maxStreamingBitrate: 4_000_000,
        maxWidth: 1280,
        maxHeight: 720,
        prefersDirectPlay: false,
        allowsTranscoding: true
    )

    public static let p480 = RemotePlaybackQualityOption(
        preset: .p480,
        title: "480p",
        subtitle: NSLocalizedString("Up to 480p", comment: ""),
        maxStreamingBitrate: 1_500_000,
        maxWidth: 854,
        maxHeight: 480,
        prefersDirectPlay: false,
        allowsTranscoding: true
    )

    public static var allConstrainedPresets: [RemotePlaybackQualityOption] {
        [.p1080, .p720, .p480]
    }

    public static func option(for id: String?) -> RemotePlaybackQualityOption {
        guard let id else { return .auto }
        return option(forPresetID: id) ?? .auto
    }

    public static func option(forPresetID id: String) -> RemotePlaybackQualityOption? {
        switch id {
        case RemotePlaybackQualityPreset.auto.rawValue:
            return .auto
        case RemotePlaybackQualityPreset.original.rawValue:
            return .original
        case RemotePlaybackQualityPreset.p1080.rawValue:
            return .p1080
        case RemotePlaybackQualityPreset.p720.rawValue:
            return .p720
        case RemotePlaybackQualityPreset.p480.rawValue:
            return .p480
        default:
            return nil
        }
    }
}

public enum RemotePlaybackMethod: String, Codable {
    case directPlay = "DirectPlay"
    case directStream = "DirectStream"
    case transcode = "Transcode"
}

public enum RemotePlaybackQualityCatalog {
    public static var menuIconSystemName: String {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, *) {
            return "dial.medium"
        } else {
            return "slider.horizontal.3"
        }
    }

    public static var menuFilledIconSystemName: String {
        if #available(iOS 16.0, macOS 13.0, tvOS 16.0, *) {
            return "dial.medium.fill"
        } else {
            return "slider.horizontal.3"
        }
    }

    private static func sourceExceeds(maxWidth: Int, maxHeight: Int, targetWidth: Int, targetHeight: Int) -> Bool {
        maxWidth > targetWidth || maxHeight > targetHeight
    }

    public static func options(
        maxVideoWidth: Int?,
        maxVideoHeight: Int?,
        supportsTranscoding: Bool
    ) -> [RemotePlaybackQualityOption] {
        var result: [RemotePlaybackQualityOption] = [.auto]

        guard supportsTranscoding else {
            return result
        }

        result.append(.original)

        let width = maxVideoWidth ?? 0
        let height = maxVideoHeight ?? 0

        if sourceExceeds(maxWidth: width, maxHeight: height, targetWidth: 1920, targetHeight: 1080) {
            result.append(.p1080)
        }
        if sourceExceeds(maxWidth: width, maxHeight: height, targetWidth: 1280, targetHeight: 720) {
            result.append(.p720)
        }
        if sourceExceeds(maxWidth: width, maxHeight: height, targetWidth: 854, targetHeight: 480) {
            result.append(.p480)
        }

        return result
    }

    public static func currentOptionTitle(from optionID: String?) -> String {
        RemotePlaybackQualityOption.option(for: optionID).title
    }
}
