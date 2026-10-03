import SwiftUI

class AppSettings: ObservableObject {
    static let shared = AppSettings()
    static let secondarySubtitleMinimumPositionRatio: Double = 0.08
    static let secondarySubtitleMaximumPositionRatio: Double = 0.92
    
    enum SortOption {
        case name, date, size
    }

    enum SubtitleAutoSelectionMode: String, CaseIterable, Identifiable {
        case off = "off"
        case followAppLanguage = "followAppLanguage"
        case chinese = "chinese"
        case english = "english"

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .off:
                return NSLocalizedString("Off", comment: "")
            case .followAppLanguage:
                return NSLocalizedString("Follow App Language", comment: "")
            case .chinese:
                return NSLocalizedString("Chinese", comment: "")
            case .english:
                return NSLocalizedString("English", comment: "")
            }
        }
    }
    
    enum VideoDecoder: String, CaseIterable, Identifiable {
        case hardware = "hw"
        case software = "sw"
        
        var id: String { rawValue }
        
        var localizedName: String {
            switch self {
            case .hardware: return NSLocalizedString("Hardware (HW)", comment: "")
            case .software: return NSLocalizedString("Software (SW)", comment: "")
            }
        }
    }

    enum VideoAutoRotateMode: String, CaseIterable, Identifiable {
        case off = "off"
        case followVideoAspect = "followVideoAspect"
        case alwaysLandscape = "alwaysLandscape"

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .off:
                return NSLocalizedString("Off", comment: "")
            case .followVideoAspect:
                return NSLocalizedString("Follow Video Aspect", comment: "")
            case .alwaysLandscape:
                return NSLocalizedString("Always Landscape", comment: "")
            }
        }
    }

    enum SecondarySubtitlePlacement: String, CaseIterable, Identifiable {
        case nearBottom = "nearBottom"
        case middle = "middle"
        case top = "top"

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .nearBottom:
                return NSLocalizedString("Near Bottom", comment: "Secondary subtitle position")
            case .middle:
                return NSLocalizedString("Middle", comment: "Secondary subtitle position")
            case .top:
                return NSLocalizedString("Top", comment: "Secondary subtitle position")
            }
        }
    }

    enum SecondarySubtitleLayoutOrientation {
        case portrait
        case landscape

        static func resolved(for containerSize: CGSize) -> SecondarySubtitleLayoutOrientation {
            containerSize.width > containerSize.height ? .landscape : .portrait
        }
    }

    enum SecondarySubtitleSizeScale: Double, CaseIterable, Identifiable {
        case extraSmall = 0.6
        case small = 0.8
        case normal = 1.0
        case large = 1.2
        case extraLarge = 1.4

        var id: Double { rawValue }

        var localizedName: String {
            switch self {
            case .extraSmall:
                return NSLocalizedString("Extra Small", comment: "Secondary subtitle size")
            case .small:
                return NSLocalizedString("Small", comment: "Secondary subtitle size")
            case .normal:
                return NSLocalizedString("Normal", comment: "Secondary subtitle size")
            case .large:
                return NSLocalizedString("Large", comment: "Secondary subtitle size")
            case .extraLarge:
                return NSLocalizedString("Extra Large", comment: "Secondary subtitle size")
            }
        }
    }

    enum SnapshotSaveLocation: String, CaseIterable, Identifiable {
        case appFolder = "appFolder"
        case photos = "photos"

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .appFolder:
                return NSLocalizedString("GenPlayer Folder", comment: "")
            case .photos:
                return NSLocalizedString("Photos", comment: "")
            }
        }
    }
    
    // MARK: - Local Files Settings
    @AppStorage("localFileViewMode") var isLocalGridLayout: Bool = false
    @AppStorage("localFileSortOption") var localSortOptionRaw: String = "name"
    @AppStorage("localFileSortAscending") var isLocalSortAscending: Bool = true
    @AppStorage("localFileFoldersOnTop") var showLocalFoldersOnTop: Bool = true
    
    var localSortOption: FileManagerService.SortOption {
        get {
            switch localSortOptionRaw {
            case "name": return .name
            case "date": return .date
            case "size": return .size
            default: return .name
            }
        }
        set {
            switch newValue {
            case .name: localSortOptionRaw = "name"
            case .date: localSortOptionRaw = "date"
            case .size: localSortOptionRaw = "size"
            }
        }
    }
    
    // MARK: - SMB Files Settings
    @AppStorage("smbFileViewMode") var isSMBGridLayout: Bool = false
    @AppStorage("smbFileSortOption") var smbSortOptionRaw: String = "name"
    @AppStorage("smbFileSortAscending") var isSMBSortAscending: Bool = true
    
    // SMB Sort Option (using same enum for convenience, though strictly it belongs to FileManagerService)
    var smbSortOption: FileManagerService.SortOption {
        get {
            switch smbSortOptionRaw {
            case "name": return .name
            case "date": return .date
            case "size": return .size
            default: return .name
            }
        }
        set {
            switch newValue {
            case .name: smbSortOptionRaw = "name"
            case .date: smbSortOptionRaw = "date"
            case .size: smbSortOptionRaw = "size"
            }
        }
    }
    
    // MARK: - Global App Settings
    @AppStorage("userTheme") var userTheme: String = "System"
    @AppStorage("lastKnownSystemTheme") var lastKnownSystemTheme: String = ""
    @AppStorage("appLanguage") var appLanguage: String = "system"
    @AppStorage("enableVideoHistory") var enableVideoHistory: Bool = true
    @AppStorage("enableAudioHistory") var enableAudioHistory: Bool = true
    @AppStorage("shouldPlayInBackground") var shouldPlayInBackground: Bool = false
    @AppStorage("enableICloudServerListSync") var enableICloudServerListSync: Bool = false
    @AppStorage("allowRemoteMutationOperations") var allowRemoteMutationOperations: Bool = false
    @AppStorage("allowMediaServerDeletion") var allowMediaServerDeletion: Bool = false
    @AppStorage("enableRemoteFileCache") var enableRemoteFileCache: Bool = true
    @AppStorage("downloadOverWiFiOnly") var downloadOverWiFiOnly: Bool = false
    @AppStorage("pauseDownloadsInLowPowerMode") var pauseDownloadsInLowPowerMode: Bool = false
    @AppStorage("notifyWhenDownloadsFinish") var notifyWhenDownloadsFinish: Bool = false
    @AppStorage("maxConcurrentDownloads") var maxConcurrentDownloads: Int = 3
    @AppStorage("extractRemoteAudioArtwork") var extractRemoteAudioArtwork: Bool = false
    @AppStorage("enablePlaybackQualitySwitchingBeta") var enablePlaybackQualitySwitchingBeta: Bool = false
    @AppStorage("enableSecondarySubtitlesBeta") var enableSecondarySubtitlesBeta: Bool = false
    @AppStorage("defaultVideoDecoder") var defaultVideoDecoderRaw: String = "hw"
    @AppStorage("videoAutoRotateMode") var videoAutoRotateModeRaw: String = VideoAutoRotateMode.followVideoAspect.rawValue
    @AppStorage("snapshotSaveLocation") private var snapshotSaveLocationRaw: String = ""
    
    var defaultVideoDecoder: VideoDecoder {
        get { VideoDecoder(rawValue: defaultVideoDecoderRaw) ?? .hardware }
        set { defaultVideoDecoderRaw = newValue.rawValue }
    }

    var videoAutoRotateMode: VideoAutoRotateMode {
        get { VideoAutoRotateMode(rawValue: videoAutoRotateModeRaw) ?? .followVideoAspect }
        set { videoAutoRotateModeRaw = newValue.rawValue }
    }

    var snapshotSaveLocation: SnapshotSaveLocation {
        SnapshotSaveLocation(rawValue: snapshotSaveLocationRaw) ?? .appFolder
    }

    var hasConfiguredSnapshotSaveLocation: Bool {
        SnapshotSaveLocation(rawValue: snapshotSaveLocationRaw) != nil
    }

    func setSnapshotSaveLocation(_ location: SnapshotSaveLocation) {
        snapshotSaveLocationRaw = location.rawValue
    }

    func canMutateRemoteFiles(on serverType: ServerConfig.ServerType) -> Bool {
        allowRemoteMutationOperations && serverType.supportsRemoteMutationOperations
    }

    func canDeleteMediaServerFiles(on serverType: ServerConfig.ServerType) -> Bool {
        allowMediaServerDeletion && (serverType == .jellyfin || serverType == .emby || serverType == .plex)
    }

    var defaultRemotePlaybackQualityOption: RemotePlaybackQualityOption {
        enablePlaybackQualitySwitchingBeta ? .auto : .original
    }

    func resolvedRemotePlaybackQualityOption(for optionID: String?) -> RemotePlaybackQualityOption {
        guard enablePlaybackQualitySwitchingBeta else { return .original }
        return RemotePlaybackQualityOption.option(for: optionID)
    }

    func resolvedRemotePlaybackQualityID(for optionID: String?) -> String {
        resolvedRemotePlaybackQualityOption(for: optionID).id
    }

    func visibleRemotePlaybackQualityOptions(from options: [RemotePlaybackQualityOption]) -> [RemotePlaybackQualityOption] {
        guard enablePlaybackQualitySwitchingBeta, options.count > 1 else { return [] }
        return options
    }
    
    @AppStorage("defaultPlaybackSpeed") var defaultPlaybackSpeed: Double = 1.0
    @AppStorage("defaultAudioPlaybackSpeed") var defaultAudioPlaybackSpeed: Double = 1.0
    @AppStorage("pressAndHoldPlaybackSpeed") var pressAndHoldPlaybackSpeed: Double = 2.0
    @AppStorage("audioDelaySeconds") var audioDelaySeconds: Double = 0.0
    @AppStorage("doubleTapSeekDuration") var doubleTapSeekDuration: Double = 15.0
    @AppStorage("subtitleDelaySeconds") var subtitleDelaySeconds: Double = 0.0
    @AppStorage("subtitleAutoSelectionMode") var subtitleAutoSelectionModeRaw: String = SubtitleAutoSelectionMode.followAppLanguage.rawValue
    @AppStorage("secondarySubtitlePlacement") var secondarySubtitlePlacementRaw: String = SecondarySubtitlePlacement.nearBottom.rawValue
    @AppStorage("secondarySubtitleSizeScale") var secondarySubtitleSizeScaleRaw: Double = SecondarySubtitleSizeScale.normal.rawValue
    @AppStorage("secondarySubtitleVerticalPositionRatio") private var secondarySubtitleVerticalPositionRatioRaw: Double = -1.0
    @AppStorage("secondarySubtitleVerticalPositionRatio.portrait") private var secondarySubtitlePortraitVerticalPositionRatioRaw: Double = -1.0
    @AppStorage("secondarySubtitleVerticalPositionRatio.landscape") private var secondarySubtitleLandscapeVerticalPositionRatioRaw: Double = -1.0

    var subtitleAutoSelectionMode: SubtitleAutoSelectionMode {
        get { SubtitleAutoSelectionMode(rawValue: subtitleAutoSelectionModeRaw) ?? .followAppLanguage }
        set { subtitleAutoSelectionModeRaw = newValue.rawValue }
    }

    var secondarySubtitlePlacement: SecondarySubtitlePlacement {
        get { SecondarySubtitlePlacement(rawValue: secondarySubtitlePlacementRaw) ?? .nearBottom }
        set { secondarySubtitlePlacementRaw = newValue.rawValue }
    }

    var secondarySubtitleSizeScale: SecondarySubtitleSizeScale {
        get { SecondarySubtitleSizeScale(rawValue: secondarySubtitleSizeScaleRaw) ?? .normal }
        set { secondarySubtitleSizeScaleRaw = newValue.rawValue }
    }

    var secondarySubtitleVerticalPositionRatio: Double? {
        get {
            guard secondarySubtitleVerticalPositionRatioRaw >= 0 else { return nil }
            return Self.clampedSecondarySubtitlePositionRatio(secondarySubtitleVerticalPositionRatioRaw)
        }
        set {
            if let newValue {
                secondarySubtitleVerticalPositionRatioRaw = Self.clampedSecondarySubtitlePositionRatio(newValue)
            } else {
                secondarySubtitleVerticalPositionRatioRaw = -1.0
            }
        }
    }

    func secondarySubtitleVerticalPositionRatio(for orientation: SecondarySubtitleLayoutOrientation) -> Double? {
        switch orientation {
        case .portrait:
            if let ratio = secondarySubtitlePositionRatio(from: secondarySubtitlePortraitVerticalPositionRatioRaw) {
                return ratio
            }
        case .landscape:
            if let ratio = secondarySubtitlePositionRatio(from: secondarySubtitleLandscapeVerticalPositionRatioRaw) {
                return ratio
            }
        }

        return hasSecondarySubtitleOrientationSpecificPosition ? nil : secondarySubtitleVerticalPositionRatio
    }

    func setSecondarySubtitleVerticalPositionRatio(
        _ ratio: Double?,
        for orientation: SecondarySubtitleLayoutOrientation
    ) {
        let rawValue = ratio.map(Self.clampedSecondarySubtitlePositionRatio) ?? -1.0

        switch orientation {
        case .portrait:
            secondarySubtitlePortraitVerticalPositionRatioRaw = rawValue
        case .landscape:
            secondarySubtitleLandscapeVerticalPositionRatioRaw = rawValue
        }
    }

    func clearSecondarySubtitleVerticalPositionRatios() {
        secondarySubtitleVerticalPositionRatioRaw = -1.0
        secondarySubtitlePortraitVerticalPositionRatioRaw = -1.0
        secondarySubtitleLandscapeVerticalPositionRatioRaw = -1.0
    }

    private func secondarySubtitlePositionRatio(from rawValue: Double) -> Double? {
        guard rawValue >= 0 else { return nil }
        return Self.clampedSecondarySubtitlePositionRatio(rawValue)
    }

    private var hasSecondarySubtitleOrientationSpecificPosition: Bool {
        secondarySubtitlePortraitVerticalPositionRatioRaw >= 0 ||
            secondarySubtitleLandscapeVerticalPositionRatioRaw >= 0
    }

    static func clampedSecondarySubtitlePositionRatio(_ ratio: Double) -> Double {
        min(max(ratio, secondarySubtitleMinimumPositionRatio), secondarySubtitleMaximumPositionRatio)
    }

    // MARK: - Server Library Sort Persistence
    private let userDefaults = UserDefaults.standard

    func librarySortPreference(
        provider: String,
        serverId: String,
        libraryId: String,
        defaultSortBy: String,
        defaultSortOrder: String
    ) -> (sortBy: String, sortOrder: String) {
        let keyPrefix = "librarySort.\(provider).\(serverId).\(libraryId)"
        let sortBy = userDefaults.string(forKey: "\(keyPrefix).by") ?? defaultSortBy
        let sortOrder = userDefaults.string(forKey: "\(keyPrefix).order") ?? defaultSortOrder
        return (sortBy, sortOrder)
    }

    func saveLibrarySortPreference(
        provider: String,
        serverId: String,
        libraryId: String,
        sortBy: String,
        sortOrder: String
    ) {
        let keyPrefix = "librarySort.\(provider).\(serverId).\(libraryId)"
        userDefaults.set(sortBy, forKey: "\(keyPrefix).by")
        userDefaults.set(sortOrder, forKey: "\(keyPrefix).order")
    }

    // MARK: - Server Library Display Mode Persistence
    func libraryDisplayModeEnum(
        provider: String,
        serverId: String,
        libraryId: String,
        defaultMode: LibraryDisplayMode = .poster
    ) -> LibraryDisplayMode {
        let modeKey = "libraryDisplay.\(provider).\(serverId).\(libraryId).mode"
        if let storedString = userDefaults.string(forKey: modeKey),
           let mode = LibraryDisplayMode(rawValue: storedString) {
            return mode
        }
        // Legacy boolean fallback check
        let legacyKey = "libraryDisplay.\(provider).\(serverId).\(libraryId).grid"
        if let legacyBool = userDefaults.object(forKey: legacyKey) as? Bool {
            return legacyBool ? .poster : .list
        }
        return defaultMode
    }

    func saveLibraryDisplayMode(
        provider: String,
        serverId: String,
        libraryId: String,
        mode: LibraryDisplayMode
    ) {
        let modeKey = "libraryDisplay.\(provider).\(serverId).\(libraryId).mode"
        let legacyKey = "libraryDisplay.\(provider).\(serverId).\(libraryId).grid"
        userDefaults.set(mode.rawValue, forKey: modeKey)
        userDefaults.set(mode != .list, forKey: legacyKey)
    }

    func libraryDisplayMode(
        provider: String,
        serverId: String,
        libraryId: String,
        defaultIsGrid: Bool = true
    ) -> Bool {
        let mode = libraryDisplayModeEnum(
            provider: provider,
            serverId: serverId,
            libraryId: libraryId,
            defaultMode: defaultIsGrid ? .poster : .list
        )
        return mode != .list
    }

    func saveLibraryDisplayMode(
        provider: String,
        serverId: String,
        libraryId: String,
        isGrid: Bool
    ) {
        saveLibraryDisplayMode(
            provider: provider,
            serverId: serverId,
            libraryId: libraryId,
            mode: isGrid ? .poster : .list
        )
    }

    // MARK: - Series Track Preference
    func seriesTrackPreference(
        provider: String,
        serverId: String,
        seriesId: String
    ) -> (audio: Int?, subtitle: Int?) {
        let prefix = "seriesTrack.\(provider).\(serverId).\(seriesId)"
        let audioKey = "\(prefix).audio"
        let subtitleKey = "\(prefix).subtitle"

        let audio = userDefaults.object(forKey: audioKey) as? Int
        let subtitle = userDefaults.object(forKey: subtitleKey) as? Int
        return (audio, subtitle)
    }

    func saveSeriesTrackPreference(
        provider: String,
        serverId: String,
        seriesId: String,
        audio: Int?,
        subtitle: Int?
    ) {
        let prefix = "seriesTrack.\(provider).\(serverId).\(seriesId)"
        let audioKey = "\(prefix).audio"
        let subtitleKey = "\(prefix).subtitle"

        if let audio {
            userDefaults.set(audio, forKey: audioKey)
        } else {
            userDefaults.removeObject(forKey: audioKey)
        }

        if let subtitle {
            userDefaults.set(subtitle, forKey: subtitleKey)
        } else {
            userDefaults.removeObject(forKey: subtitleKey)
        }
    }

    func trackQueryPreference(
        provider: String,
        serverId: String,
        scopeKey: String
    ) -> (audioQuery: String?, subtitleQuery: String?, subtitlesDisabled: Bool?) {
        let prefix = "trackQuery.\(provider).\(serverId).\(scopeKey)"
        let audioKey = "\(prefix).audioQuery"
        let subtitleKey = "\(prefix).subtitleQuery"
        let disabledKey = "\(prefix).subtitlesDisabled"

        let audioQuery = userDefaults.string(forKey: audioKey)
        let subtitleQuery = userDefaults.string(forKey: subtitleKey)
        let subtitlesDisabled = userDefaults.object(forKey: disabledKey) as? Bool
        return (audioQuery, subtitleQuery, subtitlesDisabled)
    }

    func saveTrackQueryPreference(
        provider: String,
        serverId: String,
        scopeKey: String,
        audioQuery: String?,
        subtitleQuery: String?,
        subtitlesDisabled: Bool?
    ) {
        let prefix = "trackQuery.\(provider).\(serverId).\(scopeKey)"
        let audioKey = "\(prefix).audioQuery"
        let subtitleKey = "\(prefix).subtitleQuery"
        let disabledKey = "\(prefix).subtitlesDisabled"

        if let audioQuery, !audioQuery.isEmpty {
            userDefaults.set(audioQuery, forKey: audioKey)
        } else {
            userDefaults.removeObject(forKey: audioKey)
        }

        if let subtitleQuery, !subtitleQuery.isEmpty {
            userDefaults.set(subtitleQuery, forKey: subtitleKey)
        } else {
            userDefaults.removeObject(forKey: subtitleKey)
        }

        if let subtitlesDisabled {
            userDefaults.set(subtitlesDisabled, forKey: disabledKey)
        } else {
            userDefaults.removeObject(forKey: disabledKey)
        }
    }

    func secondarySubtitlePreference(
        provider: String,
        serverId: String,
        scopeKey: String
    ) -> (query: String?, ordinal: Int?) {
        let prefix = "trackQuery.\(provider).\(serverId).\(scopeKey)"
        return secondarySubtitlePreference(prefix: prefix)
    }

    func saveSecondarySubtitlePreference(
        provider: String,
        serverId: String,
        scopeKey: String,
        query: String?,
        ordinal: Int?
    ) {
        let prefix = "trackQuery.\(provider).\(serverId).\(scopeKey)"
        saveSecondarySubtitlePreference(prefix: prefix, query: query, ordinal: ordinal)
    }

    func secondarySubtitlePreference(mediaKey: String) -> (query: String?, ordinal: Int?) {
        let prefix = "secondarySubtitle.media.\(stablePreferenceKey(mediaKey))"
        return secondarySubtitlePreference(prefix: prefix)
    }

    func saveSecondarySubtitlePreference(
        mediaKey: String,
        query: String?,
        ordinal: Int?
    ) {
        let prefix = "secondarySubtitle.media.\(stablePreferenceKey(mediaKey))"
        saveSecondarySubtitlePreference(prefix: prefix, query: query, ordinal: ordinal)
    }

    private func secondarySubtitlePreference(prefix: String) -> (query: String?, ordinal: Int?) {
        let query = userDefaults.string(forKey: "\(prefix).secondarySubtitleQuery")
        let ordinal = userDefaults.object(forKey: "\(prefix).secondarySubtitleOrdinal") as? Int
        return (query, ordinal)
    }

    private func saveSecondarySubtitlePreference(
        prefix: String,
        query: String?,
        ordinal: Int?
    ) {
        let queryKey = "\(prefix).secondarySubtitleQuery"
        let ordinalKey = "\(prefix).secondarySubtitleOrdinal"

        if let query, !query.isEmpty {
            userDefaults.set(query, forKey: queryKey)
        } else {
            userDefaults.removeObject(forKey: queryKey)
        }

        if let ordinal {
            userDefaults.set(ordinal, forKey: ordinalKey)
        } else {
            userDefaults.removeObject(forKey: ordinalKey)
        }
    }

    private func stablePreferenceKey(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
