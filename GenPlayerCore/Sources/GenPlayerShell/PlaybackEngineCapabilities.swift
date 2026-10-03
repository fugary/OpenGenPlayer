import Foundation

public enum PlaybackEngineID: String, CaseIterable, Sendable {
    case vlc, mpv
}

public enum PlaybackPlatform: Sendable {
    case iOS, macOS, tvOS
}

/// Describes the application's integration, not everything an upstream engine can do.
public struct PlaybackEngineCapabilities: Sendable {
    public enum Unavailability: Equatable, Sendable {
        case unsupportedMedia, unsupportedProtocol, requiresVLCBridge, virtualGPU
        case preparing, stopped, failed, pictureInPicture, live, notSeekable
    }

    public let platform: PlaybackPlatform
    public let engine: PlaybackEngineID

    public init(platform: PlaybackPlatform, engine: PlaybackEngineID) {
        self.platform = platform
        self.engine = engine
    }

    public func routingRestriction(url: URL, isVideo: Bool, isAudio: Bool,
                                   requiresVLCBridge: Bool = false,
                                   isVirtualMachine: Bool = false) -> Unavailability? {
        guard isVideo || isAudio else { return .unsupportedMedia }
        // VLC source validation remains owned by its existing source resolver.
        guard engine == .mpv else { return nil }
        guard !requiresVLCBridge else { return .requiresVLCBridge }
        if platform == .macOS && isVideo && isVirtualMachine { return .virtualGPU }
        let schemes = ["http", "https", "smb", "ftp", "ftps", "sftp", "nfs", "rtsp", "rtp", "udp"]
        let scheme = url.scheme?.lowercased() ?? ""
        guard url.isFileURL || schemes.contains(scheme) || (platform == .macOS && scheme == "rtsps") else {
            return .unsupportedProtocol
        }
        return nil
    }

    public enum Feature: CaseIterable, Sendable {
        case pictureInPicture, subtitleBrowser, subtitleTranslation, audioSubtitleGeneration, secondaryBitmap
    }

    /// Product/platform boundary only. Runtime OS availability, permissions, readable
    /// tracks and source restrictions must still be checked by the platform adapter.
    public func supports(_ feature: Feature, isVideo: Bool) -> Bool {
        switch feature {
        case .pictureInPicture, .subtitleBrowser, .subtitleTranslation, .audioSubtitleGeneration:
            return isVideo && platform != .tvOS
        case .secondaryBitmap:
            return isVideo && engine == .mpv
        }
    }

    public enum AuxiliaryBackend: Sendable { case vlc, independent }
    public var metadataBackend: AuxiliaryBackend { engine == .mpv ? .independent : .vlc }
    public var previewBackend: AuxiliaryBackend { engine == .mpv ? .independent : .vlc }

    /// Failure recovery is a separate explicit action; normal switching needs a stable VOD clock.
    public static func switchingRestriction(isPreparing: Bool, isStopped: Bool, hasFailed: Bool,
                                            isPictureInPicture: Bool, isLive: Bool,
                                            isSeekable: Bool, duration: Double) -> Unavailability? {
        if isStopped { return .stopped }
        if isPreparing { return .preparing }
        if isPictureInPicture { return .pictureInPicture }
        if hasFailed { return .failed }
        if isLive { return .live }
        if !isSeekable || !duration.isFinite || duration <= 0 { return .notSeekable }
        return nil
    }
}

/// Frozen at process startup: changing the persisted value takes effect after restart,
/// so live sessions and queued cleanup never outlive an engine's permission.
public struct PlaybackEngineAvailability: Equatable, Sendable {
    public let vlc: Bool
    public let mpv: Bool
    public init(vlc: Bool = true, mpv: Bool = true) { self.vlc = vlc; self.mpv = mpv }
    public static let current: Self = {
        let environment = ProcessInfo.processInfo.environment["GENPLAYER_DISABLED_ENGINES"]
        let saved = UserDefaults.standard.string(forKey: "disabledPlaybackEngines")
        let disabled = Set((environment ?? saved ?? "").lowercased()
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        return Self(vlc: !disabled.contains("vlc"), mpv: !disabled.contains("mpv"))
    }()
    public func allows(_ engine: PlaybackEngineID) -> Bool { engine == .vlc ? vlc : mpv }
    public func resolve(preferred: String?, supportsMPV: Bool) -> PlaybackEngineID? {
        if preferred == "mpv", mpv, supportsMPV { return .mpv }
        if preferred == "vlc", vlc { return .vlc }
        if mpv, supportsMPV { return .mpv }
        if vlc { return .vlc }
        return nil
    }
    public static var unavailableMessage: String {
        #if SWIFT_PACKAGE
        return platformShellString("Playback.EngineDisabled")
        #else
        return NSLocalizedString("Playback.EngineDisabled", value: "The required playback engine is disabled.", comment: "")
        #endif
    }
}
