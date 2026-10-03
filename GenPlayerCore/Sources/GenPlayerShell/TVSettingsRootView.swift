#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore
import VLCKitSPM

// Extracted from TVMainView.swift


enum TVSettingsRoute: Hashable, Identifiable {
    case theme
    case language
    case security
    case appLock
    case privacySpace
    case advanced
    case videoDecoder
    case playbackEngine
    case videoPlaybackSpeed
    case seekTime
    case subtitleDelay
    case audioPlaybackSpeed
    case audioDelay
    case storage
    case downloads
    case iCloudSync
    case about
    case openSourceLicenses
    case externalLink(TVExternalLinkDestination)

    var id: String {
        switch self {
        case .theme:
            return "theme"
        case .language:
            return "language"
        case .security:
            return "security"
        case .appLock:
            return "app-lock"
        case .privacySpace:
            return "privacy-space"
        case .advanced:
            return "advanced"
        case .playbackEngine: return "playback-engine"
        case .videoDecoder:
            return "video-decoder"
        case .videoPlaybackSpeed:
            return "video-playback-speed"
        case .seekTime:
            return "seek-time"
        case .subtitleDelay:
            return "subtitle-delay"
        case .audioPlaybackSpeed:
            return "audio-playback-speed"
        case .audioDelay:
            return "audio-delay"
        case .storage:
            return "storage"
        case .downloads:
            return "downloads"
        case .iCloudSync:
            return "icloud-sync"
        case .about:
            return "about"
        case .openSourceLicenses:
            return "open-source-licenses"
        case .externalLink(let destination):
            return "external-link-\(destination.id)"
        }
    }
}



struct TVSettingsInlinePresentationKey: EnvironmentKey {
    static let defaultValue = false
}



struct TVSettingsGoBackKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}



struct TVSettingsNavigationTransitionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}



struct TVSettingsRootView: View {
    @ObservedObject private var networkService = AppNetworkService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var securityService = TVSecurityService.shared
    @AppStorage("enableVideoHistory") private var enableVideoHistory = true
    @AppStorage("enableAudioHistory") private var enableAudioHistory = true
    @AppStorage("shouldPlayInBackground") private var shouldPlayInBackground = false
    @AppStorage("allowRemoteMutationOperations") private var allowRemoteMutationOperations = false
    @AppStorage("userTheme") private var userTheme = "System"
    @AppStorage("lastKnownSystemTheme") private var lastKnownSystemTheme = ""
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("appLanguage") private var appLanguage = "system"
    @AppStorage("onboardingForceReplay") private var onboardingForceReplay = false
    @AppStorage("defaultVideoDecoder") private var defaultVideoDecoder = "hw"
    @AppStorage("defaultPlaybackSpeed") private var defaultVideoPlaybackSpeed = 1.0
    @AppStorage("defaultAudioPlaybackSpeed") private var defaultAudioPlaybackSpeed = 1.0
    @AppStorage("subtitleDelaySeconds") private var subtitleDelaySeconds = 0.0
    @AppStorage("audioDelaySeconds") private var audioDelaySeconds = 0.0
    @AppStorage("doubleTapSeekDuration") private var doubleTapSeekDuration = 15.0
    @AppStorage("lastICloudServerListSyncAt") private var lastICloudServerListSyncAt: Double = 0
    @AppStorage("saved_servers_updated_at") private var localServerListUpdatedAt: Double = 0
    @State private var isICloudSyncEnabled = AppNetworkService.shared.isICloudServerListSyncEnabled
    @State private var isSyncingICloudNow = false
    @State private var iCloudSyncOutcome: ICloudSyncOutcome?
    @State private var pendingAction: PendingAction?
    @State private var imageCacheSize: Int64 = 0
    @Binding var selection: TVRootTab
    @Namespace private var settingsNavigationTransitionNamespace

    private var resolvedSystemThemeName: String {
        let isDark: Bool
        if userTheme == "System" {
            isDark = colorScheme == .dark
        } else if !lastKnownSystemTheme.isEmpty {
            isDark = lastKnownSystemTheme == "Dark"
        } else {
            isDark = colorScheme == .dark
        }
        return platformShellString(isDark ? "Dark" : "Light")
    }

    private enum ICloudSyncOutcome: Equatable {
        case syncedNoChanges
        case syncedChanged(previousCount: Int, latestCount: Int)
    }

    private enum ICloudSyncStatus {
        case disabled
        case unavailable
        case syncing
        case ready
        case upToDate
        case syncedNoChanges
        case syncedChanged(previousCount: Int, latestCount: Int)
    }

    private enum PendingAction: Identifiable {
        case clearDownloadedContent

        var id: String {
            switch self {
            case .clearDownloadedContent:
                return "clear-downloaded-content"
            }
        }

        var title: String {
            switch self {
            case .clearDownloadedContent:
                return platformShellString("Platform Shell TV Clear Downloaded Content")
            }
        }

        var message: String {
            switch self {
            case .clearDownloadedContent:
                return platformShellString("Platform Shell TV Clear Downloaded Content Confirm")
            }
        }

        var confirmTitle: String {
            switch self {
            case .clearDownloadedContent:
                return platformShellString("Clear All")
            }
        }
    }

    private var securitySummary: String {
        if securityService.isSecurityEnabled && securityService.isPrivacySpaceEnabled {
            return platformShellString("App Lock + Privacy")
        }
        if securityService.isSecurityEnabled {
            return platformShellString("App Lock")
        }
        if securityService.isPrivacySpaceEnabled {
            return platformShellString("Privacy Space")
        }
        return platformShellString("Off")
    }

    private var downloadedStorageSummary: DownloadCenterService.DownloadedStorageSummary {
        downloadCenter.downloadedStorageSummary()
    }

    private var downloadedContentValue: String {
        tvSettingsRootStorageValue(
            downloadedStorageSummary: downloadedStorageSummary,
            imageCacheSize: imageCacheSize
        )
    }

    private var settingsRootContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVSettingsSectionHeader(title: platformShellString("General"))

            TVSettingsNavigationRow(
                title: platformShellString("Theme"),
                value: userTheme == "System"
                    ? "\(platformShellString("System")) · \(resolvedSystemThemeName)"
                    : TVSettingsThemeOption.summary(for: userTheme),
                route: .theme,
                destination: TVSettingsThemePickerView(selection: $userTheme, systemThemeName: resolvedSystemThemeName)
            )

            TVSettingsNavigationRow(
                title: platformShellString("Language"),
                value: TVSettingsLanguageCatalog.summary(for: appLanguage),
                route: .language,
                destination: TVSettingsLanguagePickerView(selection: $appLanguage)
            )

            TVSettingsActionRow(
                title: platformShellString("Replay Onboarding"),
                subtitle: platformShellString("Platform Shell TV Replay Onboarding Settings Subtitle"),
                action: { onboardingForceReplay = true }
            )

            TVSettingsSectionHeader(title: platformShellString("Security"))
                .padding(.top, 12)

            TVSettingsNavigationRow(
                title: platformShellString("Security Settings"),
                value: securitySummary,
                route: .security,
                destination: TVSettingsSecurityView()
            )

            TVSettingsSectionHeader(title: platformShellString("Playback"))
                .padding(.top, 12)

            TVSettingsToggleRow(
                title: platformShellString("Background Playback"),
                isOn: $shouldPlayInBackground
            )

            TVSettingsToggleRow(
                title: platformShellString("Video Playback History"),
                isOn: $enableVideoHistory
            )

            TVSettingsToggleRow(
                title: platformShellString("Audio Playback History"),
                isOn: $enableAudioHistory
            )

            TVSettingsSectionHeader(title: platformShellString("More"))
                .padding(.top, 12)

            TVSettingsNavigationRow(
                title: platformShellString("Advanced Settings"),
                value: "",
                route: .advanced,
                destination: TVSettingsAdvancedView()
            )

            TVSettingsNavigationRow(
                title: platformShellString("Storage"),
                value: downloadedContentValue,
                route: .storage,
                destination: TVSettingsStorageView()
            )

            TVSettingsNavigationRow(
                title: platformShellString("iCloud Sync"),
                value: iCloudSyncStatusBadgeTitle,
                route: .iCloudSync,
                destination: TVSettingsICloudSyncView()
            )

            TVSettingsNavigationRow(
                title: platformShellString("About"),
                value: TVAppVersionInfo.displayValue,
                route: .about,
                destination: TVSettingsAboutView()
            )
        }
    }

    private var settingsPaneContentWidth: CGFloat {
        900
    }

    private var settingsPaneFocusGutter: CGFloat {
        30
    }

    private var settingsPaneViewportWidth: CGFloat {
        settingsPaneContentWidth + settingsPaneFocusGutter * 2
    }

    private var settingsPane: some View {
        TVSettingsInlinePage(
            title: platformShellString("Settings"),
            systemImageName: "gearshape.fill",
            showsBackButton: false
        ) {
            settingsRootContent
        }
        .padding(.horizontal, settingsPaneFocusGutter)
        .frame(width: settingsPaneViewportWidth, alignment: .topLeading)
    }

    @ViewBuilder
    private func settingsRouteContent(for route: TVSettingsRoute) -> some View {
        switch route {
        case .theme:
            TVSettingsThemePickerView(selection: $userTheme, systemThemeName: resolvedSystemThemeName)
        case .language:
            TVSettingsLanguagePickerView(selection: $appLanguage)
        case .security:
            TVSettingsSecurityView()
        case .appLock:
            TVSettingsAppLockView()
        case .privacySpace:
            TVSettingsPrivacySpaceView()
        case .advanced:
            TVSettingsAdvancedView()
        case .playbackEngine:
            TVSettingsPlaybackEnginePickerView()
        case .videoDecoder:
            TVSettingsVideoDecoderPickerView(selection: $defaultVideoDecoder)
        case .videoPlaybackSpeed:
            TVSettingsPlaybackRatePickerView(
                title: platformShellString("Default Video Playback Speed"),
                selection: $defaultVideoPlaybackSpeed
            )
        case .seekTime:
            TVSettingsSeekDurationPickerView(selection: $doubleTapSeekDuration)
        case .subtitleDelay:
            TVSettingsDelayPickerView(
                title: platformShellString("Default Subtitle Delay"),
                selection: $subtitleDelaySeconds
            )
        case .audioPlaybackSpeed:
            TVSettingsPlaybackRatePickerView(
                title: platformShellString("Default Audio Playback Speed"),
                selection: $defaultAudioPlaybackSpeed
            )
        case .audioDelay:
            TVSettingsDelayPickerView(
                title: platformShellString("Default Audio Delay"),
                selection: $audioDelaySeconds
            )
        case .storage:
            TVSettingsStorageView()
        case .downloads:
            TVDownloadsDetailView()
        case .iCloudSync:
            TVSettingsICloudSyncView()
        case .about:
            TVSettingsAboutView()
        case .openSourceLicenses:
            TVOpenSourceLicensesView()
        case .externalLink(let destination):
            TVExternalLinkInfoView(destination: destination)
        }
    }

    var body: some View {
        TVRootPageScrollView {
            HStack(alignment: .top, spacing: 56) {
                TVSettingsIdentityPanel()
                    .frame(width: 360, alignment: .topLeading)
                    .padding(.top, 28)

                settingsPane
                    .frame(width: settingsPaneViewportWidth, alignment: .topLeading)
            }
            .frame(width: 1480, alignment: .leading)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(Text(platformShellString("Settings")))
        .environment(
            \.tvSettingsNavigationTransitionNamespace,
            settingsNavigationTransitionNamespace
        )
        .navigationDestination(for: TVSettingsRoute.self) { route in
            settingsRouteContent(for: route)
                .environment(
                    \.tvSettingsNavigationTransitionNamespace,
                    settingsNavigationTransitionNamespace
                )
                .tvSettingsNavigationZoomDestination(
                    sourceID: route.id,
                    in: settingsNavigationTransitionNamespace
                )
        }
        .onAppear {
            isICloudSyncEnabled = networkService.isICloudServerListSyncEnabled
            allowRemoteMutationOperations = false
            refreshStorageUsage()
            if userTheme == "System" {
                lastKnownSystemTheme = colorScheme == .dark ? "Dark" : "Light"
            }
        }
        .onChange(of: colorScheme) { newScheme in
            if userTheme == "System" {
                lastKnownSystemTheme = newScheme == .dark ? "Dark" : "Light"
            }
        }
        .alert(item: $pendingAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                primaryButton: .destructive(Text(action.confirmTitle)) {
                    confirm(action)
                },
                secondaryButton: .cancel(Text(platformShellString("Cancel")))
            )
        }
    }

    private var iCloudSyncStatus: ICloudSyncStatus {
        if !isICloudSyncEnabled {
            return .disabled
        }

        if isSyncingICloudNow {
            return .syncing
        }

        if !isICloudAccountAvailable {
            return .unavailable
        }

        if let iCloudSyncOutcome {
            switch iCloudSyncOutcome {
            case .syncedNoChanges:
                return .syncedNoChanges
            case .syncedChanged(let previousCount, let latestCount):
                return .syncedChanged(previousCount: previousCount, latestCount: latestCount)
            }
        }

        if isLatestLocalServerListSynced {
            return .upToDate
        }

        return .ready
    }

    private var iCloudSyncStatusTitle: String {
        switch iCloudSyncStatus {
        case .disabled:
            return platformShellString("iCloud Sync Off")
        case .unavailable:
            return platformShellString("iCloud Sign-In Required")
        case .syncing:
            return platformShellString("Syncing server list...")
        case .ready:
            return platformShellString("Ready to sync")
        case .upToDate, .syncedNoChanges:
            return platformShellString("Already up to date")
        case .syncedChanged:
            return platformShellString("Server list updated")
        }
    }

    private var iCloudSyncStatusDetail: String {
        switch iCloudSyncStatus {
        case .disabled:
            return platformShellString("Turn on iCloud sync to keep server profiles aligned.")
        case .unavailable:
            return platformShellString("Sign in to iCloud in Settings to sync this Apple TV.")
        case .syncing:
            return platformShellString("Checking iCloud for the latest server list.")
        case .ready, .upToDate:
            return platformShellString("Automatic sync is on for this Apple TV.")
        case .syncedNoChanges:
            return platformShellString("Sync completed. No server changes detected.")
        case .syncedChanged(let previousCount, let latestCount):
            return String(
                format: platformShellString("Sync completed. Server count changed from %d to %d."),
                previousCount,
                latestCount
            )
        }
    }

    private var iCloudSyncStatusBadgeTitle: String {
        switch iCloudSyncStatus {
        case .disabled:
            return platformShellString("Off")
        case .unavailable:
            return platformShellString("Sign In")
        case .syncing:
            return platformShellString("Syncing...")
        case .ready:
            return platformShellString("Ready")
        case .upToDate, .syncedNoChanges, .syncedChanged:
            return platformShellString("Updated")
        }
    }

    private var iCloudSyncMetaLine: String {
        if !isICloudSyncEnabled {
            return platformShellString("Turn on iCloud sync first.")
        }

        if !isICloudAccountAvailable {
            return platformShellString("Sign in to iCloud first.")
        }

        if lastICloudServerListSyncAt > 0 {
            return String(
                format: platformShellString("Last Sync: %@"),
                formattedICloudSyncTime(lastICloudServerListSyncAt)
            )
        }

        return platformShellString("Sensitive data stays on this Apple TV.")
    }

    private var isLatestLocalServerListSynced: Bool {
        guard lastICloudServerListSyncAt > 0 else { return false }
        guard localServerListUpdatedAt > 0 else { return true }
        return lastICloudServerListSyncAt >= localServerListUpdatedAt
    }

    private var isICloudAccountAvailable: Bool {
        TVICloudServerListSyncAvailability.isAvailable
    }

    private var canSyncICloudNow: Bool {
        isICloudSyncEnabled && isICloudAccountAvailable && !isSyncingICloudNow
    }

    private func syncServerListNow() {
        guard canSyncICloudNow else { return }
        isSyncingICloudNow = true
        iCloudSyncOutcome = nil

        let syncStartedAt = Date()
        let previousCount = networkService.savedServers.count
        networkService.syncServerListNow()
        let latestCount = networkService.savedServers.count
        let minimumFeedbackDuration: TimeInterval = 0.45
        let remainingDelay = max(0, minimumFeedbackDuration - Date().timeIntervalSince(syncStartedAt))

        DispatchQueue.main.asyncAfter(deadline: .now() + remainingDelay) {
            isSyncingICloudNow = false
            if latestCount == previousCount {
                iCloudSyncOutcome = .syncedNoChanges
            } else {
                iCloudSyncOutcome = .syncedChanged(previousCount: previousCount, latestCount: latestCount)
            }
        }
    }

    private func formattedICloudSyncTime(_ timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    private func systemStorageInfo() -> (free: Int64, total: Int64)? {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            guard
                let freeSize = attributes[.systemFreeSize] as? NSNumber,
                let totalSize = attributes[.systemSize] as? NSNumber
            else {
                return nil
            }
            return (freeSize.int64Value, totalSize.int64Value)
        } catch {
            return nil
        }
    }

    private func refreshStorageUsage() {
        TVImageCache.shared.calculateCacheSize { size in
            imageCacheSize = size
        }
    }

    private func confirm(_ action: PendingAction) {
        switch action {
        case .clearDownloadedContent:
            downloadCenter.clearDownloadedContent()
        }
    }
}



struct TVSettingsOrbitArtwork: View {
    private let nodes: [TVSettingsOrbitNodeDefinition] = [
        TVSettingsOrbitNodeDefinition(systemImageName: "lock.shield.fill", angle: -132, accent: Color(UIColor.systemRed)),
        TVSettingsOrbitNodeDefinition(systemImageName: "play.rectangle.fill", angle: -72, accent: Color(UIColor.systemBlue)),
        TVSettingsOrbitNodeDefinition(systemImageName: "icloud.fill", angle: -12, accent: Color(UIColor.systemPurple)),
        TVSettingsOrbitNodeDefinition(systemImageName: "slider.horizontal.3", angle: 48, accent: TVShellStyle.accentSoft),
        TVSettingsOrbitNodeDefinition(systemImageName: "externaldrive.fill", angle: 108, accent: Color(UIColor.systemGreen)),
        TVSettingsOrbitNodeDefinition(systemImageName: "globe", angle: 168, accent: Color(UIColor.systemOrange))
    ]

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let side = min(width, height)
            let center = CGPoint(x: width * 0.50, y: height * 0.50)
            let orbitRadius = side * 0.38

            ZStack {
                TVSettingsOrbitRing(scale: 0.94, opacity: 0.12)
                TVSettingsOrbitRing(scale: 0.68, opacity: 0.10)
                TVSettingsOrbitRing(scale: 0.40, opacity: 0.07)

                ForEach(nodes) { node in
                    TVSettingsOrbitIconNode(systemImageName: node.systemImageName, accent: node.accent)
                        .position(position(for: node, center: center, radius: orbitRadius))
                }

                TVSettingsOrbitCenter()
                    .position(center)
            }
            .frame(width: width, height: height)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func position(
        for node: TVSettingsOrbitNodeDefinition,
        center: CGPoint,
        radius: CGFloat
    ) -> CGPoint {
        let radians = node.angle * .pi / 180
        return CGPoint(
            x: center.x + CGFloat(cos(radians)) * radius,
            y: center.y + CGFloat(sin(radians)) * radius
        )
    }
}



struct TVSettingsOrbitRing: View {
    let scale: CGFloat
    let opacity: Double

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height) * scale

            Circle()
                .stroke(TVShellStyle.glassStroke.opacity(opacity), lineWidth: 1.4)
                .frame(width: side, height: side)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}



struct TVSettingsOrbitCenter: View {
    var body: some View {
        VStack(spacing: 7) {
            Circle()
                .fill(TVShellStyle.elevatedSurface.opacity(0.88))
                .frame(width: 174, height: 174)
                .overlay(
                    Circle()
                        .stroke(TVShellStyle.accentSoft.opacity(0.32), lineWidth: 3)
                        .padding(15)
                )
                .overlay(
                    VStack(spacing: 6) {
                        TVAppBrandMark(width: 96, height: 60)

                        Text(TVBrandIdentity.displayName)
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundColor(TVShellStyle.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)

                        Text(TVAppVersionInfo.displayValue)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(TVShellStyle.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 146)
                )
                .overlay(
                    Circle()
                        .stroke(TVShellStyle.glassStroke.opacity(0.46), lineWidth: 1)
                )
        }
        .shadow(color: Color.black.opacity(0.26), radius: 24, x: 0, y: 14)
    }
}



struct TVSettingsOrbitIconNode: View {
    let systemImageName: String
    let accent: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(TVShellStyle.surface.opacity(0.70))
                .frame(width: 64, height: 64)
                .overlay(
                    Circle()
                        .stroke(accent.opacity(0.30), lineWidth: 1.4)
                )

            Image(systemName: systemImageName)
                .font(.system(size: 24, weight: .heavy))
                .foregroundColor(accent.opacity(0.76))
        }
        .opacity(0.86)
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 7)
    }
}



struct TVSettingsOrbitNodeDefinition: Identifiable {
    let systemImageName: String
    let angle: Double
    let accent: Color

    var id: String {
        "\(systemImageName)-\(angle)"
    }
}



struct TVSettingsAdvancedView: View {
    @AppStorage("tvPlaybackEngine") private var playbackEngine = "mpv"
    @AppStorage("defaultVideoDecoder") private var defaultVideoDecoder = "hw"
    @AppStorage("defaultPlaybackSpeed") private var defaultVideoPlaybackSpeed = 1.0
    @AppStorage("defaultAudioPlaybackSpeed") private var defaultAudioPlaybackSpeed = 1.0
    @AppStorage("subtitleDelaySeconds") private var subtitleDelaySeconds = 0.0
    @AppStorage("audioDelaySeconds") private var audioDelaySeconds = 0.0
    @AppStorage("doubleTapSeekDuration") private var doubleTapSeekDuration = 15.0
    @AppStorage("enableSecondarySubtitlesBeta") private var enableSecondarySubtitlesBeta = false

    var body: some View {
        TVSettingsGroupedPage(title: platformShellString("Advanced Settings")) {
            TVSettingsSectionHeader(title: platformShellString("MPV.Engine"))

            TVSettingsNavigationRow(
                title: platformShellString("MPV.Engine"),
                value: playbackEngine == "mpv" ? platformShellString("MPV.Name") : "VLC",
                route: .playbackEngine,
                destination: TVSettingsPlaybackEnginePickerView()
            )

            TVSettingsSectionHeader(title: platformShellString("Video Playback"))

            TVSettingsNavigationRow(
                title: platformShellString("Default Video Decoder"),
                value: TVSettingsVideoDecoderOption.summary(for: defaultVideoDecoder),
                route: .videoDecoder,
                destination: TVSettingsVideoDecoderPickerView(selection: $defaultVideoDecoder)
            )

            TVSettingsNavigationRow(
                title: platformShellString("Default Video Playback Speed"),
                value: TVSettingsPlaybackRateOption.summary(for: defaultVideoPlaybackSpeed),
                route: .videoPlaybackSpeed,
                destination: TVSettingsPlaybackRatePickerView(
                    title: platformShellString("Default Video Playback Speed"),
                    selection: $defaultVideoPlaybackSpeed
                )
            )

            TVSettingsNavigationRow(
                title: platformShellString("Seek Time"),
                value: TVSettingsSeekDurationOption.summary(for: doubleTapSeekDuration),
                route: .seekTime,
                destination: TVSettingsSeekDurationPickerView(selection: $doubleTapSeekDuration)
            )

            TVSettingsNavigationRow(
                title: platformShellString("Default Subtitle Delay"),
                value: TVSettingsDelayOption.summary(for: subtitleDelaySeconds),
                route: .subtitleDelay,
                destination: TVSettingsDelayPickerView(
                    title: platformShellString("Default Subtitle Delay"),
                    selection: $subtitleDelaySeconds
                )
            )

            TVSettingsToggleRow(
                title: platformShellString("Secondary Subtitles"),
                subtitle: platformShellString("Platform Shell TV Secondary Subtitles Subtitle"),
                isOn: $enableSecondarySubtitlesBeta
            )

            TVSettingsSectionHeader(title: platformShellString("Audio Playback"))
                .padding(.top, 12)

            TVSettingsNavigationRow(
                title: platformShellString("Default Audio Playback Speed"),
                value: TVSettingsPlaybackRateOption.summary(for: defaultAudioPlaybackSpeed),
                route: .audioPlaybackSpeed,
                destination: TVSettingsPlaybackRatePickerView(
                    title: platformShellString("Default Audio Playback Speed"),
                    selection: $defaultAudioPlaybackSpeed
                )
            )

            TVSettingsNavigationRow(
                title: platformShellString("Default Audio Delay"),
                value: TVSettingsDelayOption.summary(for: audioDelaySeconds),
                route: .audioDelay,
                destination: TVSettingsDelayPickerView(
                    title: platformShellString("Default Audio Delay"),
                    selection: $audioDelaySeconds
                )
            )
        }
    }
}



struct TVSettingsStorageView: View {
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @State private var imageCacheSize: Int64 = 0
    @State private var pendingAction: PendingAction?

    private enum PendingAction: Identifiable {
        case clearDownloadedContent
        case clearImageCache

        var id: String {
            switch self {
            case .clearDownloadedContent:
                return "clear-downloaded-content"
            case .clearImageCache:
                return "clear-image-cache"
            }
        }
    }

    private var downloadedStorageSummary: DownloadCenterService.DownloadedStorageSummary {
        downloadCenter.downloadedStorageSummary()
    }

    private var downloadedContentValue: String {
        let summary = downloadedStorageSummary
        let fileCount = String(format: platformShellString("%d files"), summary.fileCount)
        return "\(tvByteCountString(summary.totalBytes)) · \(fileCount)"
    }

    var body: some View {
        TVSettingsGroupedPage(title: platformShellString("Storage")) {
            TVSettingsStorageOverviewCard(
                downloadedBytes: downloadedStorageSummary.totalBytes,
                imageCacheBytes: imageCacheSize,
                storageInfo: systemStorageInfo()
            )

            TVSettingsSectionHeader(title: platformShellString("Storage Summary"))

            TVSettingsNavigationRow(
                title: platformShellString("Downloaded Content"),
                value: downloadedContentValue,
                route: .downloads,
                destination: TVDownloadsDetailView()
            )

            TVSettingsListRow(
                title: platformShellString("Image Cache"),
                subtitle: platformShellString("Platform Shell TV Image Cache Settings Subtitle"),
                value: tvByteCountString(imageCacheSize),
                showsChevron: false
            )

            TVSettingsActionRow(
                title: platformShellString("Clear Image Cache"),
                subtitle: platformShellString("Platform Shell TV Clear Image Cache Settings Subtitle"),
                isEnabled: imageCacheSize > 0,
                action: { pendingAction = .clearImageCache }
            )

            TVSettingsActionRow(
                title: platformShellString("Platform Shell TV Clear Downloaded Content"),
                subtitle: platformShellString("Platform Shell TV Clear Downloaded Content Settings Subtitle"),
                isDestructive: true,
                isEnabled: downloadedStorageSummary.recordCount > 0,
                action: { pendingAction = .clearDownloadedContent }
            )
        }
        .onAppear {
            refreshStorageUsage()
        }
        .alert(item: $pendingAction) { action in
            switch action {
            case .clearDownloadedContent:
                return Alert(
                    title: Text(platformShellString("Platform Shell TV Clear Downloaded Content")),
                    message: Text(platformShellString("Platform Shell TV Clear Downloaded Content Confirm")),
                    primaryButton: .destructive(Text(platformShellString("Clear All"))) {
                        downloadCenter.clearDownloadedContent()
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            case .clearImageCache:
                return Alert(
                    title: Text(platformShellString("Clear Image Cache")),
                    message: Text(platformShellString("Platform Shell TV Clear Image Cache Confirm")),
                    primaryButton: .destructive(Text(platformShellString("Clear All"))) {
                        clearImageCache()
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            }
        }
    }

    private func refreshStorageUsage() {
        TVImageCache.shared.calculateCacheSize { size in
            imageCacheSize = size
        }
    }

    private func clearImageCache() {
        TVImageCache.shared.clearCache {
            refreshStorageUsage()
        }
    }

    private func systemStorageInfo() -> (free: Int64, total: Int64)? {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            guard
                let freeSize = attributes[.systemFreeSize] as? NSNumber,
                let totalSize = attributes[.systemSize] as? NSNumber
            else {
                return nil
            }
            return (freeSize.int64Value, totalSize.int64Value)
        } catch {
            return nil
        }
    }
}



struct TVSettingsStorageOverviewCard: View {
    let downloadedBytes: Int64
    let imageCacheBytes: Int64
    let storageInfo: (free: Int64, total: Int64)?

    private var usedStorageRatio: CGFloat {
        guard let storageInfo, storageInfo.total > 0 else { return 0 }
        let used = max(storageInfo.total - storageInfo.free, 0)
        return CGFloat(min(max(Double(used) / Double(storageInfo.total), 0), 1))
    }

    private var deviceStorageValue: String {
        guard let storageInfo else { return "-" }
        return tvByteCountString(storageInfo.free)
    }

    private var deviceStorageSubtitle: String? {
        guard let storageInfo else { return nil }
        return String(
            format: platformShellString("Free Space: %@ / Total: %@"),
            tvByteCountString(storageInfo.free),
            tvByteCountString(storageInfo.total)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                TVSettingsStorageMetricBadge(
                    title: platformShellString("Downloaded Content"),
                    value: tvByteCountString(downloadedBytes),
                    systemImageName: "arrow.down.circle.fill",
                    accent: TVShellStyle.accentSoft
                )

                TVSettingsStorageMetricBadge(
                    title: platformShellString("Image Cache"),
                    value: tvByteCountString(imageCacheBytes),
                    systemImageName: "photo.stack.fill",
                    accent: Color(red: 0.62, green: 0.50, blue: 0.98)
                )

                TVSettingsStorageMetricBadge(
                    title: platformShellString("Device Storage"),
                    value: deviceStorageValue,
                    systemImageName: "internaldrive.fill",
                    accent: Color(red: 0.42, green: 0.76, blue: 0.48)
                )
            }

            if let deviceStorageSubtitle {
                VStack(alignment: .leading, spacing: 9) {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.12))

                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        gradient: Gradient(colors: [
                                            TVShellStyle.accentSoft.opacity(0.95),
                                            TVShellStyle.accent.opacity(0.95)
                                        ]),
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: proxy.size.width * usedStorageRatio)
                        }
                    }
                    .frame(height: 12)

                    Text(deviceStorageSubtitle)
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(TVShellStyle.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(TVShellStyle.elevatedSurface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(TVShellStyle.glassStroke, lineWidth: 1)
        )
    }
}



struct TVSettingsStorageMetricBadge: View {
    let title: String
    let value: String
    let systemImageName: String
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImageName)
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(accent)
                .frame(width: 46, height: 46)
                .background(
                    Circle()
                        .fill(accent.opacity(0.16))
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundColor(TVShellStyle.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.70)

                Text(value)
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 78)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(TVShellStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(TVShellStyle.separator, lineWidth: 1)
        )
    }
}



struct TVSettingsICloudSyncView: View {
    @ObservedObject private var networkService = AppNetworkService.shared
    @AppStorage("lastICloudServerListSyncAt") private var lastICloudServerListSyncAt: Double = 0
    @AppStorage("saved_servers_updated_at") private var localServerListUpdatedAt: Double = 0
    @State private var isICloudSyncEnabled = AppNetworkService.shared.isICloudServerListSyncEnabled
    @State private var isSyncingICloudNow = false
    @State private var iCloudSyncOutcome: ICloudSyncOutcome?

    private enum ICloudSyncOutcome: Equatable {
        case syncedNoChanges
        case syncedChanged(previousCount: Int, latestCount: Int)
    }

    private enum ICloudSyncStatus {
        case disabled
        case unavailable
        case syncing
        case ready
        case upToDate
        case syncedNoChanges
        case syncedChanged(previousCount: Int, latestCount: Int)
    }

    var body: some View {
        TVSettingsGroupedPage(title: platformShellString("iCloud Sync")) {
            TVSettingsSectionHeader(title: platformShellString("Sync"))

            TVSettingsToggleRow(
                title: platformShellString("Sync Server List via iCloud"),
                isOn: Binding(
                    get: { isICloudSyncEnabled },
                    set: { newValue in
                        isICloudSyncEnabled = newValue
                        networkService.setICloudServerListSyncEnabled(newValue)
                        isSyncingICloudNow = false
                        iCloudSyncOutcome = nil
                    }
                )
            )

            TVSettingsListRow(
                title: iCloudSyncStatusTitle,
                subtitle: iCloudSyncStatusDetail,
                value: iCloudSyncStatusBadgeTitle,
                showsChevron: false
            )

            TVSettingsActionRow(
                title: isSyncingICloudNow ? platformShellString("Syncing...") : platformShellString("Sync Now"),
                subtitle: iCloudSyncMetaLine,
                isEnabled: canSyncICloudNow,
                action: syncServerListNow
            )
        }
        .onAppear {
            isICloudSyncEnabled = networkService.isICloudServerListSyncEnabled
        }
    }

    private var iCloudSyncStatus: ICloudSyncStatus {
        if !isICloudSyncEnabled {
            return .disabled
        }

        if isSyncingICloudNow {
            return .syncing
        }

        if !isICloudAccountAvailable {
            return .unavailable
        }

        if let iCloudSyncOutcome {
            switch iCloudSyncOutcome {
            case .syncedNoChanges:
                return .syncedNoChanges
            case .syncedChanged(let previousCount, let latestCount):
                return .syncedChanged(previousCount: previousCount, latestCount: latestCount)
            }
        }

        if isLatestLocalServerListSynced {
            return .upToDate
        }

        return .ready
    }

    private var iCloudSyncStatusTitle: String {
        switch iCloudSyncStatus {
        case .disabled:
            return platformShellString("iCloud Sync Off")
        case .unavailable:
            return platformShellString("iCloud Sign-In Required")
        case .syncing:
            return platformShellString("Syncing server list...")
        case .ready:
            return platformShellString("Ready to sync")
        case .upToDate, .syncedNoChanges:
            return platformShellString("Already up to date")
        case .syncedChanged:
            return platformShellString("Server list updated")
        }
    }

    private var iCloudSyncStatusDetail: String {
        switch iCloudSyncStatus {
        case .disabled:
            return platformShellString("Turn on iCloud sync to keep server profiles aligned.")
        case .unavailable:
            return platformShellString("Sign in to iCloud in Settings to sync this Apple TV.")
        case .syncing:
            return platformShellString("Checking iCloud for the latest server list.")
        case .ready, .upToDate:
            return platformShellString("Automatic sync is on for this Apple TV.")
        case .syncedNoChanges:
            return platformShellString("Sync completed. No server changes detected.")
        case .syncedChanged(let previousCount, let latestCount):
            return String(
                format: platformShellString("Sync completed. Server count changed from %d to %d."),
                previousCount,
                latestCount
            )
        }
    }

    private var iCloudSyncStatusBadgeTitle: String {
        switch iCloudSyncStatus {
        case .disabled:
            return platformShellString("Off")
        case .unavailable:
            return platformShellString("Sign In")
        case .syncing:
            return platformShellString("Syncing...")
        case .ready:
            return platformShellString("Ready")
        case .upToDate, .syncedNoChanges, .syncedChanged:
            return platformShellString("Updated")
        }
    }

    private var iCloudSyncMetaLine: String {
        if !isICloudSyncEnabled {
            return platformShellString("Turn on iCloud sync first.")
        }

        if !isICloudAccountAvailable {
            return platformShellString("Sign in to iCloud first.")
        }

        if lastICloudServerListSyncAt > 0 {
            return String(
                format: platformShellString("Last Sync: %@"),
                formattedICloudSyncTime(lastICloudServerListSyncAt)
            )
        }

        return platformShellString("Sensitive data stays on this Apple TV.")
    }

    private var isLatestLocalServerListSynced: Bool {
        guard lastICloudServerListSyncAt > 0 else { return false }
        guard localServerListUpdatedAt > 0 else { return true }
        return lastICloudServerListSyncAt >= localServerListUpdatedAt
    }

    private var isICloudAccountAvailable: Bool {
        TVICloudServerListSyncAvailability.isAvailable
    }

    private var canSyncICloudNow: Bool {
        isICloudSyncEnabled && isICloudAccountAvailable && !isSyncingICloudNow
    }

    private func syncServerListNow() {
        guard canSyncICloudNow else { return }
        isSyncingICloudNow = true
        iCloudSyncOutcome = nil

        let syncStartedAt = Date()
        let previousCount = networkService.savedServers.count
        networkService.syncServerListNow()
        let latestCount = networkService.savedServers.count
        let minimumFeedbackDuration: TimeInterval = 0.45
        let remainingDelay = max(0, minimumFeedbackDuration - Date().timeIntervalSince(syncStartedAt))

        DispatchQueue.main.asyncAfter(deadline: .now() + remainingDelay) {
            isSyncingICloudNow = false
            if latestCount == previousCount {
                iCloudSyncOutcome = .syncedNoChanges
            } else {
                iCloudSyncOutcome = .syncedChanged(previousCount: previousCount, latestCount: latestCount)
            }
        }
    }

    private func formattedICloudSyncTime(_ timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}



struct TVSettingsGroupedPage<Content: View>: View {
    let title: String
    let content: () -> Content
    @Environment(\.tvSettingsInlinePresentation) private var isInlineSettingsPresentation

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Group {
            if isInlineSettingsPresentation {
                TVSettingsInlinePage(title: title) {
                    content()
                }
            } else {
                TVPageScrollView(
                    title: title,
                    subtitle: nil,
                    handlesExitCommand: true,
                    showsTitle: false
                ) {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(title)
                            .font(.system(size: 48, weight: .heavy))
                            .foregroundColor(TVShellStyle.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)

                        VStack(alignment: .leading, spacing: 12) {
                            content()
                        }
                    }
                    .frame(width: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle(Text(title))
    }
}



struct TVSettingsInlinePage<Content: View>: View {
    let title: String
    var subtitle: String?
    var systemImageName: String?
    var showsBackButton = true
    let content: () -> Content

    @Environment(\.tvSettingsGoBack) private var goBack

    init(
        title: String,
        subtitle: String? = nil,
        systemImageName: String? = nil,
        showsBackButton: Bool = true,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName
        self.showsBackButton = showsBackButton
        self.content = content
    }

    var body: some View {
        Group {
            if showsBackButton, let goBack {
                baseContent
                    .onExitCommand(perform: goBack)
            } else {
                baseContent
            }
        }
    }

    private var baseContent: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 16) {
                if showsBackButton, let goBack {
                    Button(action: goBack) {
                        TVHeaderIconActionButton(
                            title: platformShellString("Back"),
                            systemImageName: "chevron.left",
                            onFocusChange: { _, _ in }
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }

                if let systemImageName {
                    Image(systemName: systemImageName)
                        .font(.system(size: 36, weight: .bold))
                        .foregroundColor(TVShellStyle.accentSoft)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 48, weight: .heavy))
                        .foregroundColor(TVShellStyle.primary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.72)

                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.headline.weight(.semibold))
                            .foregroundColor(TVShellStyle.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.74)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tvFocusSectionIfAvailable()

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
        }
        .padding(.top, showsBackButton ? 8 : 0)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}



enum TVPasswordSetupMode {
    case create
    case change
}



enum TVPasswordType: String, CaseIterable, Identifiable {
    case simple
    case complex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .simple:
            return platformShellString("Simple PIN")
        case .complex:
            return platformShellString("Complex Password")
        }
    }

    var subtitle: String {
        switch self {
        case .simple:
            return platformShellString("4-digit numeric code")
        case .complex:
            return platformShellString("Letters, numbers & symbols")
        }
    }

    var systemImageName: String {
        switch self {
        case .simple:
            return "circle.grid.2x2.fill"
        case .complex:
            return "key.fill"
        }
    }
}



struct TVSettingsSecurityView: View {
    @ObservedObject private var securityService = TVSecurityService.shared

    private var appLockSummary: String {
        securityService.isSecurityEnabled ? platformShellString("On") : platformShellString("Off")
    }

    private var privacySummary: String {
        securityService.isPrivacySpaceEnabled ? platformShellString("On") : platformShellString("Off")
    }

    var body: some View {
        TVSettingsGroupedPage(title: platformShellString("Security Settings")) {
            TVSettingsSectionHeader(title: platformShellString("App Lock"))

            TVSettingsNavigationRow(
                title: platformShellString("App Lock"),
                value: appLockSummary,
                route: .appLock,
                destination: TVSettingsAppLockView()
            )

            TVSettingsSectionHeader(title: platformShellString("Privacy Space"))
                .padding(.top, 12)

            TVSettingsNavigationRow(
                title: platformShellString("Privacy Space"),
                value: privacySummary,
                route: .privacySpace,
                destination: TVSettingsPrivacySpaceView()
            )
        }
    }
}



struct TVSettingsAppLockView: View {
    @ObservedObject private var securityService = TVSecurityService.shared
    @State private var isShowingPasswordSetup = false
    @State private var passwordSetupMode: TVPasswordSetupMode = .create

    var body: some View {
        TVSettingsGroupedPage(title: platformShellString("App Lock")) {
            TVInfoPanel(
                title: platformShellString("App Lock"),
                message: platformShellString("Require a password before opening Gen Player on this Apple TV."),
                systemImageName: "lock.fill",
                tintColor: TVShellStyle.accentSoft
            )

            TVSettingsSectionHeader(title: platformShellString("Password"))

            TVSettingsToggleRow(
                title: platformShellString("Enable App Lock"),
                subtitle: platformShellString("Use a simple PIN or complex password. Biometrics are not used on Apple TV."),
                isOn: Binding(
                    get: { securityService.isSecurityEnabled },
                    set: { enabled in
                        if enabled {
                            if securityService.hasPin {
                                securityService.toggleSecurity(true)
                            } else {
                                passwordSetupMode = .create
                                isShowingPasswordSetup = true
                            }
                        } else {
                            securityService.toggleSecurity(false)
                        }
                    }
                )
            )

            if securityService.hasPin {
                TVSettingsActionRow(
                    title: platformShellString("Change Password"),
                    subtitle: securityService.isSimplePin
                        ? platformShellString("Simple PIN")
                        : platformShellString("Complex Password"),
                    action: {
                        passwordSetupMode = .change
                        isShowingPasswordSetup = true
                    }
                )
            }

            if securityService.isSecurityEnabled && !securityService.isLocked {
                TVSettingsActionRow(
                    title: platformShellString("Lock Gen Player Now"),
                    subtitle: platformShellString("Require the app password before continuing."),
                    action: {
                        securityService.lock()
                    }
                )
            }
        }
        .sheet(isPresented: $isShowingPasswordSetup) {
            TVPasswordSetupSheet(
                mode: passwordSetupMode,
                title: platformShellString("App Lock"),
                isPresented: $isShowingPasswordSetup,
                existingPasswordIsSimple: securityService.isSimplePin,
                validateCurrentPassword: passwordSetupMode == .change ? securityService.checkPin : nil,
                onSave: { password in
                    securityService.setPin(password)
                    securityService.toggleSecurity(true)
                }
            )
        }
    }
}



struct TVSettingsPrivacySpaceView: View {
    private enum PendingAction: Identifiable {
        case clearPrivacyMarks

        var id: String {
            switch self {
            case .clearPrivacyMarks:
                return "clear-privacy-marks"
            }
        }
    }

    @ObservedObject private var securityService = TVSecurityService.shared
    @ObservedObject private var privacySpaceService = PrivacySpaceService.shared
    @State private var isShowingPasswordSetup = false
    @State private var isShowingPrivacyUnlock = false
    @State private var passwordSetupMode: TVPasswordSetupMode = .create
    @State private var pendingDisablePrivacySpace = false
    @State private var pendingAction: PendingAction?

    private var privacyMarkCount: Int {
        privacySpaceService.lockedServerIDs.count +
        privacySpaceService.lockedLocalPaths.count +
        privacySpaceService.lockedRemotePaths.count
    }

    var body: some View {
        TVSettingsGroupedPage(title: platformShellString("Privacy Space")) {
                TVInfoPanel(
                    title: platformShellString("Privacy Space"),
                    message: platformShellString("Protect selected servers and folders behind a separate password on Apple TV."),
                    systemImageName: "lock",
                    tintColor: TVShellStyle.accentSoft
                )

            TVSettingsSectionHeader(title: platformShellString("Access"))

            TVSettingsToggleRow(
                title: platformShellString("Enable Privacy Space"),
                subtitle: platformShellString("Uses a simple PIN or complex password. Biometrics are not used on Apple TV."),
                isOn: Binding(
                    get: { securityService.isPrivacySpaceEnabled },
                    set: { enabled in
                        if enabled {
                            if securityService.hasPrivacyPassword {
                                securityService.togglePrivacySpace(true)
                            } else {
                                passwordSetupMode = .create
                                isShowingPasswordSetup = true
                            }
                        } else if securityService.hasPrivacyPassword && !securityService.isPrivacySpaceUnlocked {
                            pendingDisablePrivacySpace = true
                            isShowingPrivacyUnlock = true
                        } else {
                            securityService.togglePrivacySpace(false)
                        }
                    }
                )
            )

            if !securityService.hasPrivacyPassword {
                TVSettingsActionRow(
                    title: platformShellString("Create Password"),
                    subtitle: platformShellString("Uses a simple PIN or complex password. Biometrics are not used on Apple TV."),
                    action: {
                        passwordSetupMode = .create
                        isShowingPasswordSetup = true
                    }
                )
            }

            if securityService.hasPrivacyPassword {
                TVSettingsActionRow(
                    title: platformShellString("Change Privacy Password"),
                    subtitle: securityService.isSimplePrivacyPassword
                        ? platformShellString("Simple PIN")
                        : platformShellString("Complex Password"),
                    action: {
                        passwordSetupMode = .change
                        isShowingPasswordSetup = true
                    }
                )
            }

            if securityService.isPrivacySpaceEnabled {
                TVSettingsActionRow(
                    title: securityService.isPrivacySpaceUnlocked
                        ? platformShellString("Lock Privacy Space Now")
                        : platformShellString("Unlock Privacy Space"),
                    subtitle: platformShellString("Controls access to protected servers and folders."),
                    action: {
                        if securityService.isPrivacySpaceUnlocked {
                            securityService.lockPrivacySpace()
                        } else {
                            isShowingPrivacyUnlock = true
                        }
                    }
                )

                TVSettingsSectionHeader(title: platformShellString("Visibility"))
                    .padding(.top, 12)

                TVSettingsToggleRow(
                    title: platformShellString("Hide Locked Items"),
                    subtitle: platformShellString("Hide protected items until Privacy Space is unlocked."),
                    isOn: Binding(
                        get: { securityService.hideLockedItems },
                        set: { securityService.setHideLockedItems($0) }
                    )
                )

                TVSettingsToggleRow(
                    title: platformShellString("Exclude Private Content from History"),
                    subtitle: platformShellString("Playback progress for private items will not be saved."),
                    isOn: Binding(
                        get: { securityService.excludePrivacyFromHistory },
                        set: { securityService.setExcludePrivacyFromHistory($0) }
                    )
                )

                TVSettingsSectionHeader(title: platformShellString("Private Marks"))
                    .padding(.top, 12)

                TVSettingsStaticInfoRow(
                    title: platformShellString("Platform Shell TV Privacy Mark Count"),
                    subtitle: platformShellString("Servers and folders marked as private on this Apple TV."),
                    value: "\(privacyMarkCount)"
                )

                if privacyMarkCount > 0 {
                    TVSettingsActionRow(
                        title: platformShellString("Platform Shell TV Clear Privacy Marks"),
                        subtitle: platformShellString("Remove all Privacy Space marks from this Apple TV."),
                        isDestructive: true,
                        action: {
                            pendingAction = .clearPrivacyMarks
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $isShowingPasswordSetup) {
            TVPasswordSetupSheet(
                mode: passwordSetupMode,
                title: platformShellString("Privacy Space"),
                isPresented: $isShowingPasswordSetup,
                existingPasswordIsSimple: securityService.isSimplePrivacyPassword,
                validateCurrentPassword: passwordSetupMode == .change ? securityService.checkPrivacyPassword : nil,
                onSave: { password in
                    securityService.setPrivacyPassword(password)
                    securityService.togglePrivacySpace(true)
                    _ = securityService.unlockPrivacySpace(with: password)
                }
            )
        }
        .sheet(isPresented: $isShowingPrivacyUnlock, onDismiss: {
            if securityService.isPrivacySpaceUnlocked {
                if pendingDisablePrivacySpace {
                    securityService.togglePrivacySpace(false)
                    pendingDisablePrivacySpace = false
                }
            } else {
                pendingDisablePrivacySpace = false
            }
        }) {
            TVPrivacyUnlockSheet(
                title: platformShellString("Privacy Space"),
                isPresented: $isShowingPrivacyUnlock
            )
        }
        .alert(item: $pendingAction) { action in
            switch action {
            case .clearPrivacyMarks:
                return Alert(
                    title: Text(platformShellString("Platform Shell TV Clear Privacy Marks")),
                    message: Text(platformShellString("Platform Shell TV Clear Privacy Marks Confirm")),
                    primaryButton: .destructive(Text(platformShellString("Clear All"))) {
                        privacySpaceService.clearAll()
                    },
                    secondaryButton: .cancel(Text(platformShellString("Cancel")))
                )
            }
        }
    }
}



struct TVPasswordSetupSheet: View {
    let mode: TVPasswordSetupMode
    let title: String
    @Binding var isPresented: Bool
    let existingPasswordIsSimple: Bool
    let validateCurrentPassword: ((String) -> Bool)?
    let onSave: (String) -> Void

    @State private var passwordType: TVPasswordType = .simple
    @State private var currentPassword = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var errorMessage = ""

    var body: some View {
        TVPageScrollView(
            title: title,
            subtitle: nil,
            handlesExitCommand: true
        ) {
            VStack(alignment: .leading, spacing: 18) {
                TVSettingsSectionHeader(title: platformShellString("Security Type"))

                HStack(spacing: 18) {
                    ForEach(TVPasswordType.allCases) { type in
                        Button(action: {
                            passwordType = type
                            password = ""
                            confirmPassword = ""
                            errorMessage = ""
                        }) {
                            TVPasswordTypeCard(
                                type: type,
                                isSelected: passwordType == type
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                    }
                }
                .tvFocusSectionIfAvailable()

                if mode == .change {
                    TVPasswordFieldPanel(
                        title: existingPasswordIsSimple
                            ? platformShellString("Current PIN")
                            : platformShellString("Current Password"),
                        placeholder: existingPasswordIsSimple
                            ? platformShellString("Enter Current PIN")
                            : platformShellString("Enter Current Password"),
                        isSimple: existingPasswordIsSimple,
                        text: $currentPassword
                    )
                }

                TVSettingsSectionHeader(
                    title: mode == .create
                        ? platformShellString("Create Password")
                        : platformShellString("Change Password")
                )
                .padding(.top, 4)

                TVPasswordFieldPanel(
                    title: passwordType == .simple
                        ? platformShellString("PIN")
                        : platformShellString("Password"),
                    placeholder: passwordType == .simple
                        ? platformShellString("Enter 4-digit PIN")
                        : platformShellString("Enter Password"),
                    isSimple: passwordType == .simple,
                    text: $password
                )

                TVPasswordFieldPanel(
                    title: passwordType == .simple
                        ? platformShellString("Confirm PIN")
                        : platformShellString("Confirm Password"),
                    placeholder: passwordType == .simple
                        ? platformShellString("Confirm PIN")
                        : platformShellString("Confirm Password"),
                    isSimple: passwordType == .simple,
                    text: $confirmPassword
                )

                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.headline.weight(.semibold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 8)
                }

                HStack(spacing: 18) {
                    Button(action: save) {
                        TVMaintenanceButtonLabel(
                            title: platformShellString("Save"),
                            systemImageName: "checkmark.circle.fill"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()

                    Button(action: { isPresented = false }) {
                        TVMaintenanceButtonLabel(
                            title: platformShellString("Cancel"),
                            systemImageName: "xmark.circle"
                        )
                    }
                    .buttonStyle(TVPlainButtonStyle())
                    .tvDisableSystemFocusEffect()
                }
            }
            .frame(width: 880, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private func save() {
        errorMessage = ""
        if mode == .change, !validateCurrentPasswordInput() {
            return
        }
        guard validatePassword(password) else { return }
        guard confirmPassword == password else {
            errorMessage = platformShellString("Passwords do not match")
            return
        }

        onSave(password)
        isPresented = false
    }

    private func validatePassword(_ input: String) -> Bool {
        if passwordType == .simple {
            guard input.count == 4 else {
                errorMessage = platformShellString("PIN must be 4 digits")
                return false
            }
            return true
        }

        guard input.count >= 4 else {
            errorMessage = platformShellString("Password must be at least 4 characters")
            return false
        }
        return true
    }

    private func validateCurrentPasswordInput() -> Bool {
        guard let validateCurrentPassword else { return true }
        guard validateCurrentPassword(currentPassword) else {
            errorMessage = existingPasswordIsSimple
                ? platformShellString("Current PIN is incorrect.")
                : platformShellString("Current password is incorrect.")
            return false
        }
        return true
    }
}



struct TVPrivacyUnlockSheet: View {
    let title: String
    @Binding var isPresented: Bool
    var onSuccess: (() -> Void)? = nil

    @ObservedObject private var securityService = TVSecurityService.shared
    @State private var password = ""
    @State private var errorMessage = ""

    var body: some View {
        TVSecurityBackdrop {
            TVPrivacyUnlockPanel(
                title: platformShellString("Privacy Space Locked"),
                message: String(
                    format: platformShellString("Unlock Privacy Space to access \"%@\" and all protected content."),
                    title
                ),
                passwordTitle: platformShellString("Privacy Password"),
                placeholder: securityService.isSimplePrivacyPassword
                    ? platformShellString("Enter 4-digit PIN")
                    : platformShellString("Enter Password"),
                isSimplePassword: securityService.isSimplePrivacyPassword,
                password: $password,
                errorMessage: errorMessage,
                primaryTitle: platformShellString("Unlock Privacy Space"),
                primarySystemImageName: "lock.open",
                cancelTitle: platformShellString("Cancel"),
                onSubmit: submit,
                onCancel: { isPresented = false }
            )
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onExitCommand {
            isPresented = false
        }
    }

    private func submit() {
        errorMessage = ""
        guard securityService.unlockPrivacySpace(with: password) else {
            errorMessage = platformShellString("Incorrect privacy password. Try again.")
            password = ""
            return
        }

        isPresented = false
        onSuccess?()
    }
}



struct TVPasswordTypeCard: View {
    let type: TVPasswordType
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    private var showsFocus: Bool {
        isFocused
    }

    private var primaryColor: Color {
        if showsFocus {
            return colorScheme == .dark ? Color.black.opacity(0.88) : TVShellStyle.primary
        }
        return isSelected ? TVShellStyle.accentSoft : TVShellStyle.primary
    }

    private var secondaryColor: Color {
        if showsFocus {
            return colorScheme == .dark ? Color.black.opacity(0.62) : TVShellStyle.secondary
        }
        return TVShellStyle.secondary
    }

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: type.systemImageName)
                .font(.system(size: 31, weight: .bold))
                .foregroundColor(primaryColor)
                .frame(width: 54, height: 54)
                .background(
                    Circle()
                        .fill((showsFocus ? Color.black : TVShellStyle.accentSoft).opacity(showsFocus ? 0.08 : 0.14))
                )

            VStack(alignment: .leading, spacing: 5) {
                Text(type.title)
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundColor(primaryColor)
                    .lineLimit(1)

                Text(type.subtitle)
                    .font(.headline.weight(.semibold))
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2.weight(.bold))
                    .foregroundColor(primaryColor)
            }
        }
        .padding(.horizontal, 24)
        .frame(width: 430, height: 112)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(showsFocus ? TVRowFocusStyle.focusedFill(for: colorScheme) : TVShellStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(isSelected ? TVShellStyle.accentSoft : TVShellStyle.glassStroke, lineWidth: isSelected ? 2 : 1)
        )
    }
}



struct TVPasswordFieldPanel: View {
    let title: String
    let placeholder: String
    let isSimple: Bool
    @Binding var text: String
    var onCommit: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title3.weight(.semibold))

            SecureField(placeholder, text: $text, onCommit: {
                onCommit?()
            })
            .textContentType(.password)
            .onChange(of: text, perform: normalizeText)
        }
        .tvDetailPanel()
    }

    private func normalizeText(_ newValue: String) {
        guard isSimple else { return }
        let normalized = String(newValue.filter { "0123456789".contains($0) }.prefix(4))
        if normalized != newValue {
            text = normalized
        }
    }
}



enum TVAppVersionInfo {
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    static var displayValue: String {
        "\(shortVersion) (\(buildNumber))"
    }

    static var localizedVersionLine: String {
        String(format: platformShellString("Version %@ (%@)"), shortVersion, buildNumber)
    }
}



struct TVExternalLinkDestination: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let urlString: String
    let symbolName: String
    let kindTitle: String

    private var components: URLComponents? {
        URLComponents(string: urlString)
    }

    var host: String {
        components?.host ?? urlString
    }

    var path: String {
        let trimmedPath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        return trimmedPath.isEmpty ? "/" : "/\(trimmedPath)"
    }

    var compactURLString: String {
        let trimmedPath = path == "/" ? "" : path
        return "\(host)\(trimmedPath)"
    }
}



struct TVExternalLinkInfoView: View {
    @Environment(\.presentationMode) private var presentationMode
    @Environment(\.tvSettingsInlinePresentation) private var isInlineSettingsPresentation
    @Environment(\.tvSettingsGoBack) private var goBack

    let destination: TVExternalLinkDestination

    private var qrImage: UIImage? {
        TVQRCodeGenerator.image(from: destination.urlString)
    }

    var body: some View {
        Group {
            if isInlineSettingsPresentation {
                TVSettingsInlinePage(
                    title: destination.title,
                    subtitle: destination.compactURLString,
                    systemImageName: destination.symbolName
                ) {
                    externalLinkCard(width: 900, qrSize: 252)
                }
            } else {
                TVPageScrollView(
                    title: destination.title,
                    subtitle: platformShellString("Platform Shell TV External Link Page Subtitle"),
                    handlesExitCommand: true,
                    customExitCommand: {
                        close()
                        return true
                    },
                    showsTitle: false,
                    topPadding: 118
                ) {
                    externalLinkCard(width: 1320, qrSize: 330)
                        .frame(width: 1320, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle(Text(destination.title))
    }

    private func externalLinkCard(width: CGFloat, qrSize: CGFloat) -> some View {
        HStack(alignment: .center, spacing: isInlineSettingsPresentation ? 30 : 42) {
            qrCodeArtwork
                .frame(width: qrSize, height: qrSize)

            linkSummary
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 32)
        .frame(width: width, alignment: .leading)
        .frame(minHeight: isInlineSettingsPresentation ? 332 : 394, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(TVShellStyle.surface.opacity(0.90))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(TVShellStyle.glassStroke, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.28), radius: 32, x: 0, y: 18)
    }

    private var qrCodeArtwork: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white)

            if let qrImage {
                Image(uiImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .padding(28)
            } else {
                Image(systemName: "qrcode")
                    .font(.system(size: 116, weight: .bold))
                    .foregroundColor(Color.black.opacity(0.80))
            }
        }
    }

    private var linkSummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 42, weight: .heavy))
                    .foregroundColor(TVShellStyle.accentSoft)

                Text(platformShellString("Scan QR Code"))
                    .font(.system(size: 46, weight: .heavy))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(platformShellString("Platform Shell TV External Link QR Hint"))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(TVShellStyle.secondary)
                    .lineSpacing(3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Text(platformShellString("Platform Shell TV External Link Page Subtitle"))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(TVShellStyle.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Image(systemName: "link")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(TVShellStyle.accentSoft)

                Text(destination.compactURLString)
                    .font(.system(size: 31, weight: .heavy, design: .rounded))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(2)
                    .minimumScaleFactor(0.66)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: 580, alignment: .leading)
            .background(
                Capsule(style: .continuous)
                    .fill(TVShellStyle.subtleFill)
            )

            Button(action: close) {
                TVHeaderActionPill(
                    title: platformShellString("Close"),
                    systemImageName: "checkmark",
                    width: 170
                )
            }
            .buttonStyle(TVPlainButtonStyle())
            .tvDisableSystemFocusEffect()
            .tvFocusSectionIfAvailable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func close() {
        if isInlineSettingsPresentation, let goBack {
            goBack()
        } else {
            presentationMode.wrappedValue.dismiss()
        }
    }
}



struct TVOpenSourceLibrary: Identifiable {
    let name: String
    let licenseType: String
    let urlString: String

    var id: String { name }

    var externalLinkDestination: TVExternalLinkDestination {
        TVExternalLinkDestination(
            id: "license-\(name)",
            title: name,
            subtitle: licenseType,
            urlString: urlString,
            symbolName: "doc.text.magnifyingglass",
            kindTitle: platformShellString("Open Source Licenses")
        )
    }

    static let catalog: [TVOpenSourceLibrary] = [
        TVOpenSourceLibrary(
            name: "MPVKit / libmpv / FFmpeg",
            licenseType: "LGPL-3.0",
            urlString: "https://github.com/mpvkit/MPVKit/blob/1.0.0/LICENSE"
        ),
        TVOpenSourceLibrary(
            name: "VLCKitSPM / MobileVLCKit",
            licenseType: "LGPL-2.1",
            urlString: "https://github.com/fugary/vlckit-spm/blob/main/LICENSE"
        ),
        TVOpenSourceLibrary(
            name: "AMSMB2 (+ libsmb2)",
            licenseType: "LGPL-2.1",
            urlString: "https://github.com/amosavian/AMSMB2/blob/master/LICENSE"
        ),
        TVOpenSourceLibrary(
            name: "FilesProvider",
            licenseType: "MIT",
            urlString: "https://github.com/amosavian/FileProvider/blob/master/LICENSE"
        ),
        TVOpenSourceLibrary(
            name: "libssh2",
            licenseType: "BSD 3-Clause",
            urlString: "https://github.com/libssh2/libssh2/blob/master/COPYING"
        ),
        TVOpenSourceLibrary(
            name: "NFSKit",
            licenseType: "MIT",
            urlString: "https://github.com/alexiscn/NFSKit/blob/main/LICENSE"
        ),
        TVOpenSourceLibrary(
            name: "fishhook",
            licenseType: "BSD 3-Clause",
            urlString: "https://github.com/facebook/fishhook/blob/main/LICENSE"
        ),
        TVOpenSourceLibrary(
            name: "Source Han Sans SC",
            licenseType: "OFL-1.1",
            urlString: "https://github.com/adobe-fonts/source-han-sans/blob/master/LICENSE.txt"
        )
    ]
}



struct TVSettingsAboutView: View {
    @Environment(\.tvSettingsInlinePresentation) private var isInlineSettingsPresentation
    @Environment(\.tvSettingsNavigationTransitionNamespace) private var transitionNamespace

    private let websiteURL = "https://genplayer.fugary.com/"
    private let releaseNotesURL = "https://genplayer.fugary.com/changelog.html"
    private let privacyPolicyURL = "https://genplayer.fugary.com/privacy.html"

    private var websiteDestination: TVExternalLinkDestination {
        TVExternalLinkDestination(
            id: "genplayer-website",
            title: platformShellString("Website"),
            subtitle: TVBrandIdentity.displayName,
            urlString: websiteURL,
            symbolName: "globe",
            kindTitle: platformShellString("Website")
        )
    }

    private var privacyPolicyDestination: TVExternalLinkDestination {
        TVExternalLinkDestination(
            id: "genplayer-privacy-policy",
            title: platformShellString("Privacy Policy"),
            subtitle: TVBrandIdentity.displayName,
            urlString: privacyPolicyURL,
            symbolName: "hand.raised.fill",
            kindTitle: platformShellString("Privacy Policy")
        )
    }

    private var releaseNotesDestination: TVExternalLinkDestination {
        TVExternalLinkDestination(
            id: "genplayer-release-notes",
            title: platformShellString("Release Notes"),
            subtitle: TVBrandIdentity.displayName,
            urlString: releaseNotesURL,
            symbolName: "doc.text.fill",
            kindTitle: platformShellString("Release Notes")
        )
    }

    var body: some View {
        Group {
            if isInlineSettingsPresentation {
                TVSettingsInlinePage(
                    title: platformShellString("About"),
                    subtitle: platformShellString("Platform Shell TV About Subtitle"),
                    systemImageName: "info.circle.fill"
                ) {
                    aboutContent
                }
            } else {
                TVPageScrollView(
                    title: platformShellString("About"),
                    subtitle: platformShellString("Platform Shell TV About Subtitle"),
                    handlesExitCommand: true
                ) {
                    aboutContent
                        .frame(width: 920, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle(Text(platformShellString("About")))
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            aboutHero

            VStack(alignment: .leading, spacing: 12) {
                TVSettingsSectionHeader(title: platformShellString("Details"))

                TVSettingsStaticInfoRow(
                    title: platformShellString("Copyright"),
                    subtitle: "© 2026 Gary Fu"
                )

                externalLinkRow(websiteDestination)

                externalLinkRow(privacyPolicyDestination)

                externalLinkRow(releaseNotesDestination)

                openSourceLicensesRow
            }
        }
    }

    @ViewBuilder
    private func externalLinkRow(_ destination: TVExternalLinkDestination) -> some View {
        let route = TVSettingsRoute.externalLink(destination)
        let row = TVSettingsListRow(
            title: destination.title,
            subtitle: destination.compactURLString,
            showsChevron: true,
            zoomSourceID: route.id,
            transitionNamespace: transitionNamespace
        )

        NavigationLink(value: route) {
            row
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
    }

    private var openSourceLicensesRow: some View {
        let route = TVSettingsRoute.openSourceLicenses
        let row = TVSettingsListRow(
            title: platformShellString("Open Source Licenses"),
            subtitle: "VLCKitSPM · AMSMB2 · FilesProvider",
            value: "\(TVOpenSourceLibrary.catalog.count)",
            showsChevron: true,
            zoomSourceID: route.id,
            transitionNamespace: transitionNamespace
        )

        return NavigationLink(value: route) {
            row
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
    }

    private var aboutHero: some View {
        HStack(alignment: .center, spacing: 28) {
            TVAppBrandMark(width: 172, height: 106)

            VStack(alignment: .leading, spacing: 10) {
                Text(TVBrandIdentity.displayName)
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(1)

                Text(TVAppVersionInfo.localizedVersionLine)
                    .font(.title3.weight(.semibold))
                    .foregroundColor(TVShellStyle.secondary)
                    .lineLimit(1)

                Text(platformShellString("Platform Shell TV About Description"))
                    .font(.headline.weight(.medium))
                    .foregroundColor(TVShellStyle.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(30)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(TVShellStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(TVShellStyle.glassStroke, lineWidth: 1)
        )
    }
}



struct TVOpenSourceLicensesView: View {
    @Environment(\.tvSettingsInlinePresentation) private var isInlineSettingsPresentation
    @Environment(\.tvSettingsNavigationTransitionNamespace) private var transitionNamespace

    var body: some View {
        Group {
            if isInlineSettingsPresentation {
                TVSettingsInlinePage(
                    title: platformShellString("Open Source Licenses"),
                    subtitle: platformShellString("Platform Shell TV Open Source Footer"),
                    systemImageName: "doc.text.magnifyingglass"
                ) {
                    openSourceContent
                }
            } else {
                TVPageScrollView(
                    title: platformShellString("Open Source Licenses"),
                    subtitle: platformShellString("Platform Shell TV Open Source Footer"),
                    handlesExitCommand: true
                ) {
                    openSourceContent
                        .frame(width: 980, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle(Text(platformShellString("Open Source Licenses")))
    }

    private var openSourceContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(TVOpenSourceLibrary.catalog) { library in
                openSourceRow(for: library)
            }
        }
    }

    @ViewBuilder
    private func openSourceRow(for library: TVOpenSourceLibrary) -> some View {
        let route = TVSettingsRoute.externalLink(library.externalLinkDestination)

        NavigationLink(value: route) {
            TVOpenSourceLibraryRow(library: library)
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
    }
}



struct TVOpenSourceLibraryRow: View {
    let library: TVOpenSourceLibrary

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var primaryColor: Color {
        TVRowFocusStyle.primary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var secondaryColor: Color {
        TVRowFocusStyle.secondary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var accentColor: Color {
        showsFocus ? Color.black.opacity(0.78) : TVShellStyle.accentSoft
    }

    private var accentFillColor: Color {
        showsFocus ? Color.black.opacity(0.10) : TVShellStyle.accentSoft.opacity(0.14)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(accentColor)
                .frame(width: 50, height: 50)
                .background(
                    Circle()
                        .fill(accentFillColor)
                )

            VStack(alignment: .leading, spacing: 8) {
                Text(library.name)
                    .font(.system(size: 29, weight: .heavy))
                    .foregroundColor(primaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)

                Text(library.urlString)
                    .font(.headline.weight(.medium))
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
            }

            Spacer(minLength: 16)

            Text(library.licenseType)
                .font(.system(size: 20, weight: .heavy))
                .foregroundColor(accentColor)
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(
                    Capsule(style: .continuous)
                        .fill(accentFillColor)
                )
        }
        .tvInteractiveRowPanel()
        .animation(.easeOut(duration: 0.16), value: showsFocus)
    }
}



struct TVSettingsIdentityPanel: View {
    var body: some View {
        VStack(alignment: .leading) {
            TVSettingsOrbitArtwork()
                .frame(width: 360, height: 360)
        }
        .frame(width: 360, alignment: .leading)
        .padding(.top, 150)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}



struct TVSettingsRailMarker: View {
    let title: String
    let systemImageName: String
    let accent: Color

    var body: some View {
        HStack(spacing: 12) {
            Capsule(style: .continuous)
                .fill(accent.opacity(0.68))
                .frame(width: 4, height: 24)

            Text(title)
                .font(.system(size: 19, weight: .bold))
                .foregroundColor(TVShellStyle.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}



struct TVSettingsToggleRow: View {
    let title: String
    var subtitle: String?
    @Binding var isOn: Bool

    var body: some View {
        Button(action: { isOn.toggle() }) {
            TVSettingsListRow(
                title: title,
                subtitle: subtitle,
                value: platformShellString(isOn ? "On" : "Off"),
                showsChevron: false
            )
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
    }
}



struct TVSettingsStaticInfoRow: View {
    let title: String
    var subtitle: String?
    var value: String?

    var body: some View {
        Button(action: {}) {
            TVSettingsListRow(
                title: title,
                subtitle: subtitle,
                value: value,
                showsChevron: false
            )
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
    }
}



struct TVSettingsActionRow: View {
    let title: String
    var subtitle: String?
    var isDestructive = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TVSettingsListRow(
                title: title,
                subtitle: subtitle,
                showsChevron: true,
                isDestructive: isDestructive
            )
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
        .disabled(!isEnabled)
    }
}



struct TVSettingsNavigationRow<Destination: View>: View {
    let title: String
    let value: String
    var route: TVSettingsRoute?
    let destination: Destination
    @Environment(\.tvSettingsNavigationTransitionNamespace) private var transitionNamespace

    @State private var isActive = false

    init(
        title: String,
        value: String,
        route: TVSettingsRoute? = nil,
        destination: Destination
    ) {
        self.title = title
        self.value = value
        self.route = route
        self.destination = destination
    }

    var body: some View {
        Button(action: { isActive = true }) {
            rowLabel
        }
        .buttonStyle(TVPlainButtonStyle())
        .tvDisableSystemFocusEffect()
        .navigationDestination(isPresented: $isActive) {
            if let route {
                destination
                    .environment(
                        \.tvSettingsNavigationTransitionNamespace,
                        transitionNamespace
                    )
                    .tvSettingsNavigationZoomDestination(
                        sourceID: route.id,
                        in: transitionNamespace
                    )
            } else {
                destination
            }
        }
    }

    private var rowLabel: some View {
        TVSettingsListRow(
            title: title,
            value: value,
            showsChevron: true,
            zoomSourceID: route?.id,
            transitionNamespace: transitionNamespace
        )
    }
}



enum TVSettingsThemeOption: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }
    var title: String { platformShellString(rawValue) }

    static func summary(for value: String) -> String {
        (Self(rawValue: value) ?? .system).title
    }
}



struct TVSettingsPlaybackEnginePickerView: View {
    @AppStorage("tvPlaybackEngine") private var selection = "mpv"
    var body: some View {
        TVSettingsChoicePage(title: platformShellString("MPV.Engine")) {
            ForEach(["vlc", "mpv"], id: \.self) { engine in
                Button(action: { selection = engine }) {
                    TVSettingsChoiceRow(title: engine == "mpv" ? platformShellString("MPV.Name") : "VLC",
                        subtitle: nil,
                        isSelected: selection == engine)
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
        }
    }
}

enum TVSettingsVideoDecoderOption: String, CaseIterable, Identifiable {
    case hardware = "hw"
    case software = "sw"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hardware:
            return platformShellString("Hardware (HW)")
        case .software:
            return platformShellString("Software (SW)")
        }
    }

    static func summary(for value: String) -> String {
        (Self(rawValue: value) ?? .hardware).title
    }
}



struct TVSettingsVideoDecoderPickerView: View {
    @Binding var selection: String

    var body: some View {
        TVSettingsChoicePage(title: platformShellString("Default Video Decoder")) {
            ForEach(TVSettingsVideoDecoderOption.allCases) { option in
                Button(action: {
                    selection = option.rawValue
                }) {
                    TVSettingsChoiceRow(
                        title: option.title,
                        subtitle: nil,
                        isSelected: selection == option.rawValue
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
        }
    }
}



enum TVSettingsPlaybackRateOption {
    static let values: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    static func title(for value: Double) -> String {
        "\(String(format: "%g", value))x"
    }

    static func summary(for value: Double) -> String {
        let matched = (values + MPVPlaybackSpeed.rates.map(Double.init)).first { abs($0 - value) < 0.01 } ?? 1.0
        return title(for: matched)
    }
}



struct TVSettingsPlaybackRatePickerView: View {
    @AppStorage("tvPlaybackEngine") private var playbackEngine = "mpv"
    let title: String
    @Binding var selection: Double

    var body: some View {
        TVSettingsChoicePage(title: title) {
            ForEach(playbackEngine == "mpv" ? MPVPlaybackSpeed.rates.map(Double.init) : TVSettingsPlaybackRateOption.values, id: \.self) { value in
                Button(action: {
                    selection = value
                }) {
                    TVSettingsChoiceRow(
                        title: TVSettingsPlaybackRateOption.title(for: value),
                        subtitle: nil,
                        isSelected: abs(selection - value) < 0.01
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
        }
    }
}



enum TVSettingsDelayOption {
    static let values: [Double] = [-3.0, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 3.0]

    static func title(for value: Double) -> String {
        if abs(value) < 0.001 {
            return platformShellString("Off")
        }
        let prefix = value > 0 ? "+" : ""
        return "\(prefix)\(String(format: "%g", value))s"
    }

    static func summary(for value: Double) -> String {
        let matched = values.first { abs($0 - value) < 0.01 } ?? 0.0
        return title(for: matched)
    }
}



struct TVSettingsDelayPickerView: View {
    let title: String
    @Binding var selection: Double

    var body: some View {
        TVSettingsChoicePage(title: title) {
            ForEach(TVSettingsDelayOption.values, id: \.self) { value in
                Button(action: {
                    selection = value
                }) {
                    TVSettingsChoiceRow(
                        title: TVSettingsDelayOption.title(for: value),
                        subtitle: nil,
                        isSelected: abs(selection - value) < 0.01
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
        }
    }
}



struct TVSettingsChoicePage<Content: View>: View {
    let title: String
    let content: () -> Content
    @Environment(\.tvSettingsInlinePresentation) private var isInlineSettingsPresentation

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        Group {
            if isInlineSettingsPresentation {
                TVSettingsInlinePage(title: title) {
                    content()
                }
            } else {
                TVPageScrollView(
                    title: title,
                    subtitle: nil,
                    handlesExitCommand: true,
                    showsTitle: false
                ) {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(title)
                            .font(.system(size: 48, weight: .heavy))
                            .foregroundColor(TVShellStyle.primary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.72)

                        VStack(alignment: .leading, spacing: 12) {
                            content()
                        }
                    }
                    .frame(width: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .navigationTitle(Text(title))
    }
}



struct TVSettingsSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.headline.weight(.bold))
            .foregroundColor(TVShellStyle.secondary)
            .textCase(.uppercase)
            .lineLimit(1)
    }
}



struct TVSettingsThemePickerView: View {
    @Binding var selection: String
    let systemThemeName: String

    var body: some View {
        TVSettingsChoicePage(title: platformShellString("Theme")) {
            ForEach(TVSettingsThemeOption.allCases) { option in
                Button(action: {
                    selection = option.rawValue
                }) {
                    TVSettingsChoiceRow(
                        title: option == .system
                            ? "\(platformShellString("System")) · \(systemThemeName)"
                            : option.title,
                        subtitle: nil,
                        isSelected: selection == option.rawValue
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
        }
    }
}



enum TVSettingsSeekDurationOption {
    static let values: [Double] = [5, 10, 15, 30]

    static func title(for value: Double) -> String {
        "\(Int(value.rounded()))s"
    }

    static func summary(for value: Double) -> String {
        let matched = values.first { abs($0 - value) < 0.5 } ?? 15
        return title(for: matched)
    }
}



struct TVSettingsSeekDurationPickerView: View {
    @Binding var selection: Double

    var body: some View {
        TVSettingsChoicePage(title: platformShellString("Seek Time")) {
            ForEach(TVSettingsSeekDurationOption.values, id: \.self) { value in
                Button(action: {
                    selection = value
                }) {
                    TVSettingsChoiceRow(
                        title: TVSettingsSeekDurationOption.title(for: value),
                        subtitle: nil,
                        isSelected: abs(selection - value) < 0.5
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
        }
    }
}



struct TVSettingsLanguageOption: Identifiable {
    let code: String
    let title: String
    let subtitle: String?

    var id: String { code }
}



enum TVSettingsLanguageCatalog {
    static let supportedLanguages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es"]
    static let selectableLanguages = ["system"] + supportedLanguages

    static var options: [TVSettingsLanguageOption] {
        selectableLanguages.map { code in
            TVSettingsLanguageOption(
                code: code,
                title: primaryName(for: code),
                subtitle: secondaryName(for: code)
            )
        }
    }

    static func summary(for code: String) -> String {
        if code == "system" {
            return "\(platformShellString("System")) · \(autonym(for: resolvedSystemLanguage()))"
        }

        return autonym(for: normalizedLanguage(from: code) ?? "en")
    }

    static func primaryName(for code: String) -> String {
        if code == "system" {
            return platformShellString("System")
        }

        return autonym(for: code)
    }

    static func secondaryName(for code: String) -> String? {
        if code == "system" {
            return autonym(for: resolvedSystemLanguage())
        }

        let english = englishName(for: code)
        let autonym = autonym(for: code)
        return english == autonym ? nil : english
    }

    private static func autonym(for code: String) -> String {
        switch normalizedLanguage(from: code) ?? "en" {
        case "en": return "English"
        case "zh-Hans": return "简体中文"
        case "zh-Hant": return "繁體中文"
        case "ja": return "日本語"
        case "ko": return "한국어"
        case "fr": return "Français"
        case "de": return "Deutsch"
        case "es": return "Español"
        default: return "English"
        }
    }

    private static func englishName(for code: String) -> String {
        switch normalizedLanguage(from: code) ?? "en" {
        case "en": return "English"
        case "zh-Hans": return "Chinese (Simplified)"
        case "zh-Hant": return "Chinese (Traditional)"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        case "fr": return "French"
        case "de": return "German"
        case "es": return "Spanish"
        default: return "English"
        }
    }

    private static func resolvedSystemLanguage() -> String {
        for preferred in systemPreferredLanguages() {
            if let normalized = normalizedLanguage(from: preferred) {
                return normalized
            }
        }

        return "en"
    }

    private static func normalizedLanguage(from identifier: String) -> String? {
        let normalized = identifier.replacingOccurrences(of: "_", with: "-").lowercased()

        if normalized.hasPrefix("zh") {
            if normalized.contains("hant") || normalized.contains("tw") || normalized.contains("hk") || normalized.contains("mo") {
                return "zh-Hant"
            }
            return "zh-Hans"
        }

        if normalized.hasPrefix("en") {
            return "en"
        }

        for language in supportedLanguages where !language.hasPrefix("zh") {
            let lowercased = language.lowercased()
            if normalized == lowercased || normalized.hasPrefix(lowercased + "-") {
                return language
            }
        }

        return nil
    }

    private static func systemPreferredLanguages() -> [String] {
        if let languages = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String],
           !languages.isEmpty {
            return languages
        }

        if let languages = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String], !languages.isEmpty {
            return languages
        }

        let identifier = Locale.autoupdatingCurrent.identifier
        if !identifier.isEmpty {
            return [identifier]
        }

        return Locale.preferredLanguages
    }
}



struct TVSettingsLanguagePickerView: View {
    @Binding var selection: String

    var body: some View {
        TVSettingsChoicePage(title: platformShellString("Language")) {
            ForEach(TVSettingsLanguageCatalog.options) { option in
                Button(action: {
                    selection = option.code
                }) {
                    TVSettingsChoiceRow(
                        title: option.title,
                        subtitle: option.subtitle,
                        isSelected: selection == option.code
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }
        }
    }
}



struct TVSettingsChoiceRow: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool

    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorScheme) private var colorScheme

    private var foregroundColor: Color {
        TVRowFocusStyle.primary(showsFocus: isFocused, isEnabled: true, colorScheme: colorScheme)
    }

    private var secondaryColor: Color {
        TVRowFocusStyle.secondary(showsFocus: isFocused, isEnabled: true, colorScheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(foregroundColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(secondaryColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                }
            }

            Spacer(minLength: 16)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(
                        isFocused
                        ? TVRowFocusStyle.primary(showsFocus: true, isEnabled: true, colorScheme: colorScheme)
                        : TVShellStyle.accentSoft
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 76, alignment: .leading)
        .padding(.horizontal, 28)
        .padding(.vertical, 4)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(isFocused ? TVRowFocusStyle.focusedFill(for: colorScheme) : TVShellStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(isFocused ? Color.clear : TVShellStyle.glassStroke, lineWidth: 1)
        )
        .scaleEffect(isFocused ? 1.025 : 1.0)
        .shadow(color: isFocused ? Color.black.opacity(0.26) : .clear, radius: isFocused ? 16 : 0, x: 0, y: isFocused ? 8 : 0)
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .animation(.easeOut(duration: 0.16), value: isSelected)
    }
}



struct TVSettingsListRow: View {
    let title: String
    var subtitle: String?
    var value: String?
    var showsChevron = true
    var isDestructive = false
    var zoomSourceID: String? = nil
    var transitionNamespace: Namespace.ID? = nil

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var titleColor: Color {
        TVRowFocusStyle.primary(
            showsFocus: showsFocus,
            isEnabled: isEnabled,
            colorScheme: colorScheme,
            isDestructive: isDestructive
        )
    }

    private var secondaryColor: Color {
        TVRowFocusStyle.secondary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 27, weight: .semibold))
                    .foregroundColor(titleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(secondaryColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                }
            }

            Spacer(minLength: 16)

            if let value, !value.isEmpty {
                Text(value)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
            }

            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(secondaryColor)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: subtitle == nil ? 72 : 84)
        .padding(.horizontal, 28)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            Group {
                if let zoomSourceID {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(showsFocus ? TVRowFocusStyle.focusedFill(for: colorScheme) : TVShellStyle.surface)
                        .tvSettingsNavigationZoomSource(sourceID: zoomSourceID, in: transitionNamespace)
                } else {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(showsFocus ? TVRowFocusStyle.focusedFill(for: colorScheme) : TVShellStyle.surface)
                }
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(showsFocus ? Color.clear : TVShellStyle.glassStroke, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.14), value: showsFocus)
        .scaleEffect(showsFocus ? 1.025 : 1.0)
        .shadow(
            color: showsFocus ? Color.black.opacity(0.26) : .clear,
            radius: showsFocus ? 16 : 0,
            x: 0,
            y: showsFocus ? 8 : 0
        )
        .modifier(TVFocusedCardLayerModifier())
    }
}

#endif
