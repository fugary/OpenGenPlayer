#if os(iOS)
import MessageUI
#endif
import SwiftUI
import GenPlayerShell
import UserNotifications

struct SettingsView: View {
    @ObservedObject private var securityService = SecurityService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var appIconService = AppIconService.shared
    @Environment(\.colorScheme) private var colorScheme
    
    @State private var isShowingPinSetup = false
    @State private var pinSetupMode: PinSetupMode = .create
    @State private var feedbackMailDraft: FeedbackDraft?
    @State private var feedbackAlert: FeedbackAlert?
    @State private var isShowingShareAppSheet = false
    @AppStorage("onboardingForceReplay") private var onboardingForceReplay: Bool = false
    
    enum PinSetupMode {
        case create, change
    }

    private enum FeedbackAlert: Identifiable {
        case message(title: String, message: String)

        var id: String {
            switch self {
            case .message(let title, let message):
                return "\(title)-\(message)"
            }
        }

        var title: String {
            switch self {
            case .message(let title, _):
                return title
            }
        }

        var message: String {
            switch self {
            case .message(_, let message):
                return message
            }
        }
    }
    
    var body: some View {
        List {
            generalSection
            securitySection
            quickPlaybackSection
            advancedEntrySection
        }
        .listStyle(InsetGroupedListStyle())
        .scrollContentBackgroundCompatHidden()
        .background(Color(UIColor.systemGroupedBackground))
        .navigationTitle(NSLocalizedString("Settings", comment: ""))
        .sheet(isPresented: $isShowingPinSetup) {
            SettingsPinSetupView(
                mode: pinSetupMode,
                navigationTitle: NSLocalizedString("App Lock", comment: ""),
                isPresented: $isShowingPinSetup,
                existingPasswordIsSimple: securityService.isSimplePin,
                validateCurrentPassword: pinSetupMode == .change ? securityService.checkPin : nil,
                onSave: { password in
                    securityService.setPin(password)
                    securityService.toggleSecurity(true)
                }
            )
        }
        .sheet(item: $feedbackMailDraft) { draft in
            MailComposeSheet(draft: draft, onFinish: handleMailComposeResult)
        }
        .sheet(isPresented: $isShowingShareAppSheet) {
            ActivityShareSheet(activityItems: shareAppActivityItems)
        }
        .alert(item: $feedbackAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
            )
        }
        .onAppear {
            _ = securityService.refreshBiometricAvailability(clearUnavailablePreference: true)
            if settings.userTheme == "System" {
                settings.lastKnownSystemTheme = colorScheme == .dark ? "Dark" : "Light"
            }
        }
        .onChange(of: colorScheme) { newScheme in
            if settings.userTheme == "System" {
                settings.lastKnownSystemTheme = newScheme == .dark ? "Dark" : "Light"
            }
        }
        .onChange(of: settings.userTheme) { _ in
            updateTheme()
        }
    }

    private var quickPlaybackSection: some View {
        Section(header: Text(NSLocalizedString("Playback", comment: ""))) {
            Toggle(isOn: settings.$shouldPlayInBackground) {
                HStack {
                    SettingsIcon(icon: "music.note", color: .purple)
                    Text(NSLocalizedString("Background Playback", comment: ""))
                }
            }

            HStack {
                SettingsIcon(icon: "play.rectangle.fill", color: .blue)
                Text(NSLocalizedString("Video Playback History", comment: ""))
                Spacer()
                Toggle("", isOn: settings.$enableVideoHistory)
                    .labelsHidden()
            }

            HStack {
                SettingsIcon(icon: "music.note.list", color: .pink)
                Text(NSLocalizedString("Audio Playback History", comment: ""))
                Spacer()
                Toggle("", isOn: settings.$enableAudioHistory)
                    .labelsHidden()
            }
        }
    }

    private var generalSection: some View {
        Section(header: Text(NSLocalizedString("General", comment: ""))) {
            NavigationLink(destination: SettingsThemeView()) {
                HStack {
                    SettingsIcon(icon: "paintbrush.fill", color: .blue)
                    Text(NSLocalizedString("Theme", comment: ""))
                    Spacer()
                    Text(currentThemeSummary)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.primary)

            NavigationLink(destination: SettingsLanguageView()) {
                HStack {
                    SettingsIcon(icon: "globe", color: Color(UIColor.systemTeal))
                    Text(NSLocalizedString("Language", comment: ""))
                    Spacer()
                    Text(Bundle.localizedAppLanguageSummary(for: settings.appLanguage))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .foregroundColor(.primary)

            Button(action: {
                onboardingForceReplay = true
            }) {
                HStack {
                    SettingsIcon(icon: "lightbulb.fill", color: Color(UIColor.systemYellow))
                    Text(NSLocalizedString("Replay Onboarding", comment: ""))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .foregroundColor(.primary)
        }
    }

    private var securitySection: some View {
        Section(header: Text(NSLocalizedString("Security", comment: ""))) {
            Toggle(isOn: Binding(
                get: { securityService.isSecurityEnabled },
                set: { enabled in
                    if enabled {
                        if securityService.hasPin {
                            securityService.toggleSecurity(true)
                        } else {
                            pinSetupMode = .create
                            isShowingPinSetup = true
                        }
                    } else {
                        securityService.toggleSecurity(false)
                    }
                }
            )) {
                HStack {
                    SettingsIcon(icon: "lock.fill", color: .green)
                    Text(NSLocalizedString("Enable App Lock", comment: ""))
                }
            }

            if securityService.isSecurityEnabled {
                Toggle(isOn: Binding(
                    get: { securityService.useBiometrics },
                    set: { enabled in
                        if enabled {
                            if !securityService.toggleBiometrics(true) {
                                feedbackAlert = .message(
                                    title: NSLocalizedString("Biometric Unlock Unavailable", comment: ""),
                                    message: securityService.biometricsUnavailableMessage()
                                )
                            }
                        } else {
                            _ = securityService.toggleBiometrics(false)
                        }
                    }
                )) {
                    HStack {
                        SettingsIcon(icon: securityService.biometricIconName, color: .purple)
                        Text(securityService.biometricsSettingTitle)
                    }
                }

                Button(action: {
                    pinSetupMode = .change
                    isShowingPinSetup = true
                }) {
                    HStack {
                        SettingsIcon(icon: "key.fill", color: .orange)
                        Text(NSLocalizedString("Change PIN", comment: ""))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
                .foregroundColor(.primary)
            }

            NavigationLink(destination: SettingsPrivacySpaceView()) {
                HStack {
                    SettingsIcon(icon: "lock.shield.fill", color: Color(UIColor.systemBlue))
                    Text(NSLocalizedString("Privacy Space", comment: ""))
                    Spacer()
                    Text(securityService.isPrivacySpaceEnabled
                        ? NSLocalizedString("On", comment: "")
                        : NSLocalizedString("Off", comment: ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var advancedEntrySection: some View {
        Section(header: Text(NSLocalizedString("Advanced", comment: ""))) {
            NavigationLink(destination: SettingsAdvancedView(appIconService: appIconService)) {
                HStack {
                    SettingsIcon(icon: "slider.horizontal.3", color: Color(UIColor.systemIndigo))
                    Text(NSLocalizedString("Advanced Settings", comment: ""))
                }
            }

            NavigationLink(destination: SettingsICloudSyncView()) {
                HStack {
                    SettingsIcon(icon: "icloud", color: .blue)
                    Text(NSLocalizedString("iCloud Sync", comment: ""))
                    Spacer()
                    Text(settings.enableICloudServerListSync
                        ? NSLocalizedString("On", comment: "")
                        : NSLocalizedString("Off", comment: ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            NavigationLink(destination: SettingsStorageView()) {
                HStack {
                    SettingsIcon(icon: "internaldrive.fill", color: Color(UIColor.systemGreen))
                    Text(NSLocalizedString("Storage", comment: ""))
                }
            }

            if DonationService.shared.isChinaStorefront {
                NavigationLink(destination: SettingsDonationView()) {
                    HStack {
                        SettingsIcon(icon: "heart.fill", color: Color(UIColor.systemPink))
                        Text(NSLocalizedString("Support GenPlayer", comment: ""))
                        Spacer()
                        if DonationService.shared.isLifetimeSupporter {
                            HStack(spacing: 4) {
                                Image(systemName: "crown.fill")
                                    .font(.caption2)
                                    .foregroundColor(Color(UIColor.systemYellow))
                                Text(NSLocalizedString("Lifetime Supporter", comment: ""))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Button(action: {
                isShowingShareAppSheet = true
            }) {
                HStack {
                    SettingsIcon(icon: "square.and.arrow.up.fill", color: Color(UIColor.systemTeal))
                    Text(NSLocalizedString("Share Gen Player", comment: ""))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .foregroundColor(.primary)

            Button(action: sendFeedbackEmail) {
                HStack {
                    SettingsIcon(icon: "envelope.fill", color: Color(UIColor.systemBlue))
                    Text(NSLocalizedString("Send Feedback", comment: ""))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.gray)
                }
            }
            .foregroundColor(.primary)

            NavigationLink(destination: SettingsAboutView()) {
                HStack {
                    SettingsIcon(icon: "info.circle.fill", color: .gray)
                    Text(NSLocalizedString("About", comment: ""))
                }
            }
        }
    }

    // MARK: - Helper Methods

    private var shareAppActivityItems: [Any] {
        var items: [Any] = [NSLocalizedString("Share Gen Player Message", comment: "")]
        if let appURL = URL(string: "https://apps.apple.com/app/id6760933333") {
            items.append(appURL)
        }
        return items
    }

    private var currentThemeSummary: String {
        switch settings.userTheme {
        case "Light":
            return NSLocalizedString("Light", comment: "")
        case "Dark":
            return NSLocalizedString("Dark", comment: "")
        default:
            let isSystemDark = settings.userTheme == "System" ? (colorScheme == .dark) : (settings.lastKnownSystemTheme == "Dark")
            let systemThemeStr = isSystemDark ? NSLocalizedString("Dark", comment: "") : NSLocalizedString("Light", comment: "")
            return "\(NSLocalizedString("System", comment: "")) · \(systemThemeStr)"
        }
    }

    private func updateTheme() {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        windowScene.windows.forEach { window in
            switch settings.userTheme {
            case "Light": window.overrideUserInterfaceStyle = .light
            case "Dark": window.overrideUserInterfaceStyle = .dark
            default: window.overrideUserInterfaceStyle = .unspecified
            }
        }
    }

    private func sendFeedbackEmail() {
        let draft = FeedbackSupport.makeDraft()

        if MailComposeSheet.canSendMail {
            feedbackMailDraft = draft
            return
        }

        if let mailtoURL = FeedbackSupport.mailtoURL(for: draft),
           UIApplication.shared.canOpenURL(mailtoURL) {
            UIApplication.shared.open(mailtoURL, options: [:], completionHandler: nil)
            return
        }

        feedbackAlert = .message(
            title: NSLocalizedString("No Email App Available", comment: ""),
            message: NSLocalizedString("Feedback Fallback Message", comment: "")
        )
    }

    #if os(iOS)
    private func handleMailComposeResult(_ result: Result<MFMailComposeResult, Error>) {
        switch result {
        case .success(let composeResult):
            guard composeResult == .failed else { return }
            feedbackAlert = .message(
                title: NSLocalizedString("Unable to Send Feedback", comment: ""),
                message: NSLocalizedString("Feedback Compose Failed Message", comment: "")
            )
        case .failure:
            feedbackAlert = .message(
                title: NSLocalizedString("Unable to Send Feedback", comment: ""),
                message: NSLocalizedString("Feedback Compose Failed Message", comment: "")
            )
        }
    }
    #endif
}

private struct SettingsThemeView: View {
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List {
            Section {
                themeRow(
                    title: NSLocalizedString("System", comment: ""),
                    subtitle: resolvedSystemThemeName,
                    tag: "System"
                )
                themeRow(
                    title: NSLocalizedString("Light", comment: ""),
                    subtitle: nil,
                    tag: "Light"
                )
                themeRow(
                    title: NSLocalizedString("Dark", comment: ""),
                    subtitle: nil,
                    tag: "Dark"
                )
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(NSLocalizedString("Theme", comment: ""))
    }

    private var resolvedSystemThemeName: String {
        let isSystemDark = settings.userTheme == "System" ? (colorScheme == .dark) : (settings.lastKnownSystemTheme == "Dark")
        return isSystemDark ? NSLocalizedString("Dark", comment: "") : NSLocalizedString("Light", comment: "")
    }

    private func themeRow(title: String, subtitle: String?, tag: String) -> some View {
        Button(action: {
            settings.userTheme = tag
            updateTheme(for: tag)
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundColor(.primary)

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                if settings.userTheme == tag {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Color(UIColor.systemBlue))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    private func updateTheme(for theme: String) {
        guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        windowScene.windows.forEach { window in
            switch theme {
            case "Light": window.overrideUserInterfaceStyle = .light
            case "Dark": window.overrideUserInterfaceStyle = .dark
            default: window.overrideUserInterfaceStyle = .unspecified
            }
        }
    }
}

private struct SettingsLanguageView: View {
    @ObservedObject private var settings = AppSettings.shared

    private var languageViewIdentity: String {
        Bundle.resolvedAppLanguage(for: settings.appLanguage)
    }

    var body: some View {
        List {
            Section {
                ForEach(Bundle.selectableAppLanguages, id: \.self) { language in
                    let secondaryName = Bundle.pickerSecondaryAppLanguageName(for: language)

                    Button(action: {
                        applyLanguage(language)
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Bundle.pickerPrimaryAppLanguageName(for: language))
                                    .foregroundColor(.primary)

                                Text(secondaryName ?? Bundle.englishAppLanguageName(for: language))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .opacity(secondaryName == nil ? 0 : 1)
                                    .accessibilityHidden(secondaryName == nil)
                            }

                            Spacer()

                            if settings.appLanguage == language {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(Color(UIColor.systemBlue))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainButtonStyle())
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(NSLocalizedString("Language", comment: ""))
        .id(languageViewIdentity)
    }

    private func applyLanguage(_ language: String) {
        guard settings.appLanguage != language else { return }
        Bundle.setLanguage(language)
        settings.appLanguage = language
    }
}

private struct SettingsPrivacySpaceView: View {
    @ObservedObject private var securityService = SecurityService.shared

    @State private var isShowingPrivacyPasswordSetup = false
    @State private var isShowingPrivacyUnlock = false
    @State private var pendingPrivacySpaceDisable = false
    @State private var pinSetupMode: SettingsView.PinSetupMode = .create
    @State private var feedbackAlert: FeedbackAlertItem?

    private struct FeedbackAlertItem: Identifiable {
        let title: String
        let message: String
        var id: String { "\(title)-\(message)" }
    }

    var body: some View {
        List {
            Section(
                footer: Text(NSLocalizedString("Privacy Space protects access inside Gen Player. It does not replace your device passcode or system-level storage encryption.", comment: ""))
            ) {
                privacySpaceOverviewCard
            }

            Section {
                Toggle(isOn: Binding(
                    get: { securityService.isPrivacySpaceEnabled },
                    set: { enabled in
                        if enabled {
                            if securityService.hasPrivacyPassword {
                                securityService.togglePrivacySpace(true)
                            } else {
                                pinSetupMode = .create
                                isShowingPrivacyPasswordSetup = true
                            }
                        } else {
                            if !securityService.isPrivacySpaceUnlocked && securityService.hasPrivacyPassword {
                                pendingPrivacySpaceDisable = true
                                isShowingPrivacyUnlock = true
                            } else {
                                securityService.togglePrivacySpace(false)
                            }
                        }
                    }
                )) {
                    HStack {
                        SettingsIcon(icon: "lock.shield.fill", color: Color(UIColor.systemBlue))
                        Text(NSLocalizedString("Enable Privacy Space", comment: ""))
                    }
                }

                if securityService.isPrivacySpaceEnabled {
                    Toggle(isOn: Binding(
                        get: { securityService.allowBiometricsForPrivacy },
                        set: { enabled in
                            if enabled {
                                if !securityService.togglePrivacyBiometrics(true) {
                                    feedbackAlert = FeedbackAlertItem(
                                        title: NSLocalizedString("Biometric Unlock Unavailable", comment: ""),
                                        message: securityService.biometricsUnavailableMessage()
                                    )
                                }
                            } else {
                                _ = securityService.togglePrivacyBiometrics(false)
                            }
                        }
                    )) {
                        HStack {
                            SettingsIcon(icon: securityService.biometricIconName, color: .purple)
                            Text(securityService.biometricsSettingTitle)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { securityService.hideLockedItems },
                        set: { securityService.setHideLockedItems($0) }
                    )) {
                        HStack {
                            SettingsIcon(icon: "eye.slash.fill", color: Color(UIColor.systemIndigo))
                            Text(NSLocalizedString("Hide Locked Items", comment: ""))
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { securityService.excludePrivacyFromHistory },
                        set: { securityService.setExcludePrivacyFromHistory($0) }
                    )) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                SettingsIcon(icon: "clock.badge.xmark.fill", color: Color(UIColor.systemOrange))
                                Text(NSLocalizedString("Exclude Private Content from History", comment: ""))
                            }
                            Text(NSLocalizedString("Playback progress for private items will not be saved.", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .padding(.leading, 36)
                        }
                    }

                    Button(action: {
                        pinSetupMode = .change
                        isShowingPrivacyPasswordSetup = true
                    }) {
                        HStack {
                            SettingsIcon(icon: "key.fill", color: .orange)
                            Text(NSLocalizedString("Change Privacy Password", comment: ""))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .foregroundColor(.primary)

                    Button(action: {
                        if securityService.isPrivacySpaceUnlocked {
                            securityService.lockPrivacySpace()
                        } else {
                            isShowingPrivacyUnlock = true
                        }
                    }) {
                        HStack {
                            SettingsIcon(
                                icon: securityService.isPrivacySpaceUnlocked ? "lock.open" : "lock",
                                color: securityService.isPrivacySpaceUnlocked ? .red : Color(UIColor.systemGreen)
                            )
                            Text(
                                securityService.isPrivacySpaceUnlocked
                                    ? NSLocalizedString("Lock Privacy Space Now", comment: "")
                                    : NSLocalizedString("Unlock Privacy Space", comment: "")
                            )
                            Spacer()
                        }
                    }
                    .foregroundColor(.primary)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(NSLocalizedString("Privacy Space", comment: ""))
        .sheet(isPresented: $isShowingPrivacyPasswordSetup) {
            SettingsPinSetupView(
                mode: pinSetupMode,
                navigationTitle: NSLocalizedString("Privacy Space", comment: ""),
                isPresented: $isShowingPrivacyPasswordSetup,
                existingPasswordIsSimple: securityService.isSimplePrivacyPassword,
                validateCurrentPassword: pinSetupMode == .change ? securityService.checkPrivacyPassword : nil,
                onSave: { password in
                    securityService.setPrivacyPassword(password)
                    securityService.togglePrivacySpace(true)
                    _ = securityService.unlockPrivacySpace(with: password)
                }
            )
        }
        .sheet(isPresented: $isShowingPrivacyUnlock, onDismiss: {
            if securityService.isPrivacySpaceUnlocked {
                if pendingPrivacySpaceDisable {
                    securityService.togglePrivacySpace(false)
                    pendingPrivacySpaceDisable = false
                }
            } else {
                pendingPrivacySpaceDisable = false
            }
        }) {
            PrivacySpaceUnlockView(
                isPresented: $isShowingPrivacyUnlock,
                title: NSLocalizedString("Privacy Space", comment: "")
            )
        }
        .alert(item: $feedbackAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
            )
        }
    }

    private var privacySpaceOverviewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Protect selected servers and folders behind a separate unlock inside Gen Player.", comment: ""))
                .font(.subheadline)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 10) {
                privacySpaceOverviewPoint(
                    icon: "1.circle.fill",
                    text: NSLocalizedString("Turn it on here and set a privacy password first.", comment: "")
                )
                privacySpaceOverviewPoint(
                    icon: "2.circle.fill",
                    text: NSLocalizedString("Then use Add to Privacy Space from a server or folder menu to lock content.", comment: "")
                )
                privacySpaceOverviewPoint(
                    icon: "3.circle.fill",
                    text: NSLocalizedString("Locked items can be hidden, unlocked with Face ID or Touch ID, and kept out of history.", comment: "")
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func privacySpaceOverviewPoint(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(Color(UIColor.systemBlue))
                .frame(width: 18, height: 18)
                .padding(.top, 1)

            Text(text)
                .font(.footnote)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsICloudSyncView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var networkService = AppNetworkService.shared

    @State private var isSyncingICloudNow = false
    @State private var iCloudSyncOutcome: ICloudSyncOutcome?
    @AppStorage("lastICloudServerListSyncAt") private var lastICloudServerListSyncAt: Double = 0
    @AppStorage("saved_servers_updated_at") private var localServerListUpdatedAt: Double = 0

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
        List {
            Section(
                header: Text(NSLocalizedString("Sync Options", comment: "")),
                footer: Text(NSLocalizedString("Only syncs non-sensitive server info. Passwords, tokens, history and favorites stay local.", comment: ""))
            ) {
                Toggle(isOn: iCloudSyncToggleBinding) {
                    HStack {
                        SettingsIcon(icon: "icloud", color: .blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("Sync Server List via iCloud", comment: ""))
                            Text(NSLocalizedString("Keep server profiles aligned across your signed-in devices.", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if settings.enableICloudServerListSync {
                    iCloudSyncStatusRow

                    Button(action: syncICloudNow) {
                        HStack {
                            SettingsIcon(
                                icon: isSyncingICloudNow ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath",
                                color: Color(UIColor.systemTeal)
                            )
                            Text(isSyncingICloudNow
                                ? NSLocalizedString("Syncing...", comment: "")
                                : NSLocalizedString("Sync Now", comment: ""))
                            Spacer()
                            if isSyncingICloudNow {
                                ProgressView()
                            } else if lastICloudServerListSyncAt > 0 {
                                Text(formattedICloudSyncTime(lastICloudServerListSyncAt))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .foregroundColor(.primary)
                    .disabled(isSyncingICloudNow || !isICloudAccountAvailable)
                }
            }

            Section(
                header: Text(NSLocalizedString("Synced Data", comment: "")),
                footer: Text(NSLocalizedString("Additional sync categories can be added here in future updates.", comment: ""))
            ) {
                HStack {
                    SettingsIcon(icon: "externaldrive.fill", color: Color(UIColor.systemBlue))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(NSLocalizedString("Server List", comment: ""))
                        Text(NSLocalizedString("Currently the only data type synced via iCloud.", comment: ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Text(settings.enableICloudServerListSync
                        ? NSLocalizedString("On", comment: "")
                        : NSLocalizedString("Off", comment: ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(NSLocalizedString("iCloud Sync", comment: ""))
    }

    private var iCloudSyncToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.enableICloudServerListSync },
            set: { enabled in
                settings.enableICloudServerListSync = enabled
                networkService.setICloudServerListSyncEnabled(enabled)
                isSyncingICloudNow = false
                iCloudSyncOutcome = nil
            }
        )
    }

    private var iCloudSyncStatus: ICloudSyncStatus {
        if !settings.enableICloudServerListSync {
            return .disabled
        }

        if isSyncingICloudNow {
            return .syncing
        }

        if !isICloudAccountAvailable {
            return .unavailable
        }

        if let outcome = iCloudSyncOutcome {
            switch outcome {
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

    private var iCloudSyncStatusRow: some View {
        HStack(alignment: .top, spacing: 12) {
            SettingsIcon(icon: iCloudSyncStatusIconName, color: iCloudSyncStatusColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(iCloudSyncStatusTitle)
                    .foregroundColor(.primary)

                Text(iCloudSyncStatusDetail)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(iCloudSyncMetaLine)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            if isSyncingICloudNow {
                ProgressView()
            } else {
                Text(iCloudSyncStatusBadgeTitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(iCloudSyncStatusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(iCloudSyncStatusColor.opacity(0.12))
                    )
            }
        }
    }

    private var iCloudSyncStatusTitle: String {
        switch iCloudSyncStatus {
        case .disabled:
            return NSLocalizedString("Sync is turned off.", comment: "")
        case .unavailable:
            return NSLocalizedString("Sign in to iCloud to sync.", comment: "")
        case .syncing:
            return NSLocalizedString("Syncing server list...", comment: "")
        case .ready:
            return NSLocalizedString("Ready to sync.", comment: "")
        case .upToDate:
            return NSLocalizedString("Already up to date.", comment: "")
        case .syncedNoChanges:
            return NSLocalizedString("Already up to date.", comment: "")
        case .syncedChanged:
            return NSLocalizedString("Server list updated.", comment: "")
        }
    }

    private var iCloudSyncStatusDetail: String {
        switch iCloudSyncStatus {
        case .unavailable:
            return NSLocalizedString("Sign in to iCloud in system Settings to sync this device.", comment: "")
        case .syncing:
            return NSLocalizedString("Checking iCloud for the latest server list.", comment: "")
        case .ready:
            return NSLocalizedString("Automatic sync is on for this device.", comment: "")
        case .upToDate:
            return NSLocalizedString("Automatic sync is on for this device.", comment: "")
        case .syncedNoChanges:
            return NSLocalizedString("Sync completed. No server list changes detected.", comment: "")
        case .syncedChanged(let previousCount, let latestCount):
            return String(
                format: NSLocalizedString("Sync completed. Server count changed from %d to %d.", comment: ""),
                previousCount,
                latestCount
            )
        case .disabled:
            return ""
        }
    }

    private var iCloudSyncMetaLine: String {
        let lastSyncText = lastICloudServerListSyncAt > 0
            ? String(
                format: NSLocalizedString("Last Sync: %@", comment: ""),
                formattedICloudSyncTime(lastICloudServerListSyncAt)
            )
            : NSLocalizedString("Sensitive data stays on this device.", comment: "")

        if !isICloudAccountAvailable {
            return NSLocalizedString("Only server profiles sync. Passwords, tokens, history, and favorites stay local.", comment: "")
        }

        return lastSyncText
    }

    private var iCloudSyncStatusBadgeTitle: String {
        switch iCloudSyncStatus {
        case .unavailable:
            return NSLocalizedString("Issue", comment: "")
        case .syncing:
            return NSLocalizedString("Syncing...", comment: "")
        case .ready:
            return NSLocalizedString("Ready", comment: "")
        case .upToDate, .syncedNoChanges, .syncedChanged:
            return NSLocalizedString("Updated", comment: "")
        case .disabled:
            return ""
        }
    }

    private var iCloudSyncStatusIconName: String {
        switch iCloudSyncStatus {
        case .disabled:
            return "icloud.slash"
        case .unavailable:
            return "exclamationmark.triangle.fill"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .ready:
            return "icloud.fill"
        case .upToDate, .syncedNoChanges, .syncedChanged:
            return "checkmark.circle.fill"
        }
    }

    private var iCloudSyncStatusColor: Color {
        switch iCloudSyncStatus {
        case .disabled:
            return .gray
        case .unavailable:
            return .orange
        case .syncing, .ready:
            return Color(UIColor.systemBlue)
        case .upToDate, .syncedNoChanges, .syncedChanged:
            return .green
        }
    }


    private var isLatestLocalServerListSynced: Bool {
        guard lastICloudServerListSyncAt > 0 else { return false }
        guard localServerListUpdatedAt > 0 else { return true }
        return lastICloudServerListSyncAt >= localServerListUpdatedAt
    }

    private var isICloudAccountAvailable: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    private func syncICloudNow() {
        guard isICloudAccountAvailable else { return }
        guard !isSyncingICloudNow else { return }

        isSyncingICloudNow = true
        iCloudSyncOutcome = nil

        let syncStartedAt = Date()
        DispatchQueue.main.async {
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
    }

    private func formattedICloudSyncTime(_ timestamp: Double) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}

struct SettingsAdvancedView: View {
    @AppStorage("iosPlaybackEngine") private var playbackEngine = "mpv"
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject var appIconService: AppIconService

    var body: some View {
        List {
            Section(header: Text(NSLocalizedString("MPV.Engine", comment: ""))) {
                Picker(NSLocalizedString("MPV.Engine", comment: ""), selection: $playbackEngine) {
                    Text("VLC").tag("vlc")
                    Text(NSLocalizedString("MPV.Name", comment: "")).tag("mpv")
                }
                #if targetEnvironment(simulator)
                Text(NSLocalizedString("MPV.SimulatorSoftware", comment: ""))
                    .font(.footnote).foregroundColor(.secondary)
                #endif
            }
            Section(header: Text(NSLocalizedString("Video Playback", comment: ""))) {
                HStack {
                    SettingsIcon(icon: "cpu", color: Color(red: 88/255, green: 86/255, blue: 214/255))
                    Text(NSLocalizedString("Default Video Decoder", comment: ""))
                    Spacer()
                    Picker("", selection: settings.$defaultVideoDecoderRaw) {
                        Text(NSLocalizedString("Hardware (HW)", comment: "")).tag("hw")
                        Text(NSLocalizedString("Software (SW)", comment: "")).tag("sw")
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                }

                HStack {
                    SettingsIcon(icon: "speedometer", color: .blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("Default Video Playback Speed", comment: ""))
                        Text(NSLocalizedString("Playback.RemembersSpeed", comment: ""))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: settings.$defaultPlaybackSpeed) {
                        ForEach(playbackEngine == "mpv" ? MPVPlaybackSpeed.rates : VLCPlaybackService.availablePlaybackRates, id: \.self) { rate in
                            Text("\(String(format: "%g", rate))x").tag(Double(rate))
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                }

                Toggle(isOn: settings.$enablePlaybackQualitySwitchingBeta) {
                    HStack {
                        SettingsIcon(icon: RemotePlaybackQualityCatalog.menuFilledIconSystemName, color: .blue)
                        Text(NSLocalizedString("Playback Quality Switching (Beta)", comment: ""))
                    }
                }

                HStack {
                    SettingsIcon(icon: "rotate.right.fill", color: Color(UIColor.systemTeal))
                    Text(NSLocalizedString("Video Auto-Rotate", comment: ""))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.videoAutoRotateMode },
                        set: { settings.videoAutoRotateMode = $0 }
                    )) {
                        ForEach(AppSettings.VideoAutoRotateMode.allCases) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                }

                HStack {
                    SettingsIcon(icon: "captions.bubble.fill", color: .orange)
                    Text(NSLocalizedString("Auto Subtitle Selection", comment: ""))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.subtitleAutoSelectionMode },
                        set: { settings.subtitleAutoSelectionMode = $0 }
                    )) {
                        ForEach(AppSettings.SubtitleAutoSelectionMode.allCases) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                }

                Toggle(isOn: settings.$enableSecondarySubtitlesBeta) {
                    HStack {
                        SettingsIcon(icon: "captions.bubble", color: .orange)
                        Text(NSLocalizedString("Secondary Subtitles", comment: ""))
                    }
                }

                HStack {
                    SettingsIcon(icon: "clock.arrow.2.circlepath", color: Color(UIColor.systemTeal))
                    Text(NSLocalizedString("Default Subtitle Delay", comment: ""))
                    Spacer()
                    Picker("", selection: settings.$subtitleDelaySeconds) {
                        delayOptions
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                }
            }

            Section(header: Text(NSLocalizedString("Audio Playback", comment: ""))) {
                HStack {
                    SettingsIcon(icon: RemotePlaybackQualityCatalog.menuFilledIconSystemName, color: .blue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(NSLocalizedString("Default Audio Playback Speed", comment: ""))
                        Text(NSLocalizedString("Playback.RemembersSpeed", comment: ""))
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Picker("", selection: settings.$defaultAudioPlaybackSpeed) {
                        ForEach(playbackEngine == "mpv" ? MPVPlaybackSpeed.rates : VLCPlaybackService.availablePlaybackRates, id: \.self) { rate in
                            Text("\(String(format: "%g", rate))x").tag(Double(rate))
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                }

                HStack {
                    SettingsIcon(icon: "waveform.path.badge.minus", color: Color(red: 50/255, green: 173/255, blue: 230/255))
                    Text(NSLocalizedString("Default Audio Delay", comment: ""))
                    Spacer()
                    Picker("", selection: settings.$audioDelaySeconds) {
                        delayOptions
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                }

            }

            Section(
                header: Text(NSLocalizedString("Gestures", comment: "")),
                footer: Text(NSLocalizedString("Press and hold the center area in the video player to temporarily speed up playback. Release to return to the current speed.", comment: ""))
            ) {
                HStack {
                    SettingsIcon(icon: "forward.fill", color: Color(UIColor.systemGreen))
                    Text(NSLocalizedString("Press-and-Hold Quick Play Speed", comment: ""))
                    Spacer()
                    Picker("", selection: settings.$pressAndHoldPlaybackSpeed) {
                        Text(NSLocalizedString("Off", comment: "")).tag(0.0)
                        ForEach(VLCPlaybackService.availablePlaybackRates.filter { $0 > 1.0 }, id: \.self) { rate in
                            Text("\(String(format: "%g", rate))x").tag(Double(rate))
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                }

                HStack {
                    SettingsIcon(icon: "hand.tap.fill", color: .purple)
                    Text(NSLocalizedString("Double-Tap Seek Time", comment: ""))
                    Spacer()
                    Picker("", selection: settings.$doubleTapSeekDuration) {
                        Text("5s").tag(5.0)
                        Text("10s").tag(10.0)
                        Text("15s").tag(15.0)
                        Text("30s").tag(30.0)
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                }
            }

            Section(
                header: Text(NSLocalizedString("Screenshots", comment: "")),
                footer: Text(NSLocalizedString("Gen Player asks the first time you take a screenshot. Saving to Photos requires photo access and falls back to the built-in screenshot folder if unavailable.", comment: ""))
            ) {
                HStack {
                    SettingsIcon(icon: "camera.viewfinder", color: Color(UIColor.systemBlue))
                    Text(NSLocalizedString("Screenshot Save Location", comment: ""))
                    Spacer()
                    Picker("", selection: Binding(
                        get: { settings.snapshotSaveLocation },
                        set: { settings.setSnapshotSaveLocation($0) }
                    )) {
                        ForEach(AppSettings.SnapshotSaveLocation.allCases) { location in
                            Text(location.localizedName).tag(location)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                }
            }

            Section(
                header: Text(NSLocalizedString("Remote File Safety", comment: "")),
                footer: Text(NSLocalizedString("When off, remote servers can't move, rename, delete files, or create folders. Local files are not affected.", comment: ""))
            ) {
                Toggle(isOn: settings.$allowRemoteMutationOperations) {
                    HStack {
                        SettingsIcon(icon: "lock.open", color: Color(UIColor.systemOrange))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("Allow Remote File Modifications", comment: ""))
                            Text(NSLocalizedString("SMB and WebDAV only", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Toggle(isOn: settings.$allowMediaServerDeletion) {
                    HStack {
                        SettingsIcon(icon: "trash.slash", color: Color(UIColor.systemRed))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(NSLocalizedString("Allow Media Server Deletion", comment: ""))
                            Text(NSLocalizedString("Jellyfin, Emby, Plex", comment: ""))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Section(header: Text(NSLocalizedString("Customization", comment: ""))) {
                NavigationLink(destination: SettingsAppIconView(appIconService: appIconService)) {
                    HStack {
                        SettingsIcon(icon: "app.fill", color: Color(UIColor.systemBlue))
                        Text(NSLocalizedString("App Icon", comment: ""))
                    }
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(NSLocalizedString("Advanced", comment: ""))
    }

    @ViewBuilder
    private var delayOptions: some View {
        ForEach([-3.0, -2.0, -1.0, -0.5, 0.0, 0.5, 1.0, 2.0, 3.0], id: \.self) { delay in
            let sign = delay > 0 ? "+" : ""
            let label = abs(delay) < 0.001 ? "0s" : "\(sign)\(String(format: "%.1f", delay))s"
            Text(label).tag(delay)
        }
    }
}

private struct SettingsStorageView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared

    private enum StorageAlertType {
        case image
        case remoteFiles
        case downloads
        case notificationPermission
    }

    private struct StorageAlertItem: Identifiable {
        let type: StorageAlertType

        var id: String {
            switch type {
            case .image:
                return "image"
            case .remoteFiles:
                return "remoteFiles"
            case .downloads:
                return "downloads"
            case .notificationPermission:
                return "notificationPermission"
            }
        }
    }

    @State private var imageCacheSize: Int64 = 0
    @State private var remoteFileCacheSize: Int64 = 0
    @State private var activeStorageAlert: StorageAlertType?

    private var downloadedStorageSummary: DownloadCenterService.DownloadedStorageSummary {
        downloadCenter.downloadedStorageSummary()
    }

    var body: some View {
        List {
            Section(
                header: Text(NSLocalizedString("Downloads", comment: "")),
                footer: Text(NSLocalizedString("Downloaded files and their Download Center records are removed together to keep storage state consistent.", comment: ""))
            ) {
                downloadContentRow
            }

            Section(
                header: Text(NSLocalizedString("Download Behavior", comment: "")),
                footer: Text(NSLocalizedString("Wi-Fi and Low Power Mode rules pause downloads without deleting progress. Completion alerts are sent only when Gen Player is not active.", comment: ""))
            ) {
                Toggle(isOn: settings.$downloadOverWiFiOnly) {
                    HStack {
                        SettingsIcon(icon: "wifi", color: Color(UIColor.systemBlue))
                        Text(NSLocalizedString("Download over Wi-Fi Only", comment: ""))
                    }
                }

                Toggle(isOn: settings.$pauseDownloadsInLowPowerMode) {
                    HStack {
                        SettingsIcon(icon: "battery.25", color: Color(UIColor.systemOrange))
                        Text(NSLocalizedString("Pause Downloads in Low Power Mode", comment: ""))
                    }
                }

                Toggle(
                    isOn: Binding(
                        get: { settings.notifyWhenDownloadsFinish },
                        set: setDownloadCompletionNotificationsEnabled
                    )
                ) {
                    HStack {
                        SettingsIcon(icon: "bell.badge.fill", color: Color(UIColor.systemPurple))
                        Text(NSLocalizedString("Notify When Downloads Finish", comment: ""))
                    }
                }

                HStack {
                    SettingsIcon(icon: "arrow.down.circle.fill", color: Color(UIColor.systemIndigo))
                    Text(NSLocalizedString("Maximum Concurrent Downloads", comment: ""))
                    Spacer()
                    Picker("", selection: settings.$maxConcurrentDownloads) {
                        ForEach(1...5, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    .pickerStyle(MenuPickerStyle())
                    .labelsHidden()
                }
            }

            Section(
                header: Text(NSLocalizedString("Cache", comment: "")),
                footer: Text(NSLocalizedString("Image cache stores posters and artwork. Remote file cache stores reusable local copies for remote preview and Open in Another App. Neither affects your downloaded media.", comment: ""))
            ) {
                Toggle(isOn: settings.$enableRemoteFileCache) {
                    HStack {
                        SettingsIcon(icon: "internaldrive.fill", color: Color(UIColor.systemGreen))
                        Text(NSLocalizedString("Cache Remote File Opens", comment: ""))
                    }
                }

                storageMetricRow(
                    icon: "internaldrive.fill",
                    color: .purple,
                    title: NSLocalizedString("Image Cache", comment: ""),
                    value: formatBytes(imageCacheSize),
                    alertType: .image
                )

                storageMetricRow(
                    icon: "externaldrive.fill",
                    color: Color(UIColor.systemTeal),
                    title: NSLocalizedString("Remote File Cache", comment: ""),
                    value: formatBytes(remoteFileCacheSize),
                    alertType: .remoteFiles
                )
            }

            if let storageInfo = systemStorageInfo() {
                Section {
                    StorageUsageCard(free: storageInfo.free, total: storageInfo.total)
                        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(InsetGroupedListStyle())
        .navigationTitle(NSLocalizedString("Storage", comment: ""))
        .onAppear {
            refreshStorageUsage()
            downloadCenter.reconcileMissingLocalFiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            refreshStorageUsage()
            downloadCenter.reconcileMissingLocalFiles()
        }
        .alert(item: Binding<StorageAlertItem?>(
            get: {
                guard let activeStorageAlert else { return nil }
                return StorageAlertItem(type: activeStorageAlert)
            },
            set: { newValue in
                activeStorageAlert = newValue?.type
            }
        )) { item in
            switch item.type {
            case .image:
                return Alert(
                    title: Text(NSLocalizedString("Clear Image Cache", comment: "")),
                    message: Text(NSLocalizedString("Are you sure you want to clear the downloaded image cache? This will not affect your downloaded media.", comment: "")),
                    primaryButton: .destructive(Text(NSLocalizedString("Clear", comment: ""))) {
                        clearImageCache()
                    },
                    secondaryButton: .cancel()
                )
            case .remoteFiles:
                return Alert(
                    title: Text(NSLocalizedString("Clear Remote File Cache", comment: "")),
                    message: Text(NSLocalizedString("Are you sure you want to clear the remote file cache? This will not affect your downloaded media.", comment: "")),
                    primaryButton: .destructive(Text(NSLocalizedString("Clear", comment: ""))) {
                        clearRemoteFileCache()
                    },
                    secondaryButton: .cancel()
                )
            case .downloads:
                return Alert(
                    title: Text(NSLocalizedString("Clear Downloaded Content", comment: "")),
                    message: Text(NSLocalizedString("Are you sure you want to delete all downloaded files and records managed by Download Center?", comment: "")),
                    primaryButton: .destructive(Text(NSLocalizedString("Clear", comment: ""))) {
                        downloadCenter.clearDownloadedContent()
                    },
                    secondaryButton: .cancel()
                )
            case .notificationPermission:
                return Alert(
                    title: Text(NSLocalizedString("Notifications Disabled", comment: "")),
                    message: Text(NSLocalizedString("Enable notifications in iOS Settings to get download completion alerts.", comment: "")),
                    dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
                )
            }
        }
    }

    private func setDownloadCompletionNotificationsEnabled(_ enabled: Bool) {
        guard enabled else {
            settings.notifyWhenDownloadsFinish = false
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                settings.notifyWhenDownloadsFinish = granted
                if !granted {
                    activeStorageAlert = .notificationPermission
                }
            }
        }
    }

    private func refreshStorageUsage() {
        ImageCacheManager.shared.calculateCacheSize { size in
            imageCacheSize = size
        }
        RemoteFileCacheService.shared.calculateCacheSize { size in
            remoteFileCacheSize = size
        }
    }

    private func clearImageCache() {
        ImageCacheManager.shared.clearCache()
        refreshStorageUsage()
    }

    private func clearRemoteFileCache() {
        RemoteFileCacheService.shared.clearCache()
        refreshStorageUsage()
    }

    @ViewBuilder
    private func storageMetricRow(
        icon: String,
        color: Color,
        title: String,
        value: String,
        alertType: StorageAlertType
    ) -> some View {
        let row = storageValueRow(
            icon: icon,
            color: color,
            title: title,
            value: value,
            detail: nil
        )

        if #available(iOS 15.0, *) {
            row
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        activeStorageAlert = alertType
                    } label: {
                        Text(NSLocalizedString("Clear", comment: ""))
                    }
                }
        } else {
            row
                .contextMenu {
                    Button(action: {
                        activeStorageAlert = alertType
                    }) {
                        Label(NSLocalizedString("Clear", comment: ""), systemImage: "trash")
                    }
                }
        }
    }

    @ViewBuilder
    private var downloadContentRow: some View {
        let row = NavigationLink(destination: DownloadCenterView()) {
            storageValueRow(
                icon: "arrow.down.circle.fill",
                color: .blue,
                title: NSLocalizedString("Downloaded Content", comment: ""),
                value: formatBytes(downloadedStorageSummary.totalBytes),
                detail: String(
                    format: NSLocalizedString("%d files", comment: ""),
                    downloadedStorageSummary.fileCount
                )
            )
        }

        if #available(iOS 15.0, *) {
            row
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        activeStorageAlert = .downloads
                    } label: {
                        Text(NSLocalizedString("Clear", comment: ""))
                    }
                    .disabled(downloadedStorageSummary.recordCount == 0)
                }
        } else {
            row
                .contextMenu {
                    Button(action: {
                        activeStorageAlert = .downloads
                    }) {
                        Label(NSLocalizedString("Clear", comment: ""), systemImage: "trash")
                    }
                    .disabled(downloadedStorageSummary.recordCount == 0)
                }
        }
    }

    private func storageValueRow(
        icon: String,
        color: Color,
        title: String,
        value: String,
        detail: String?
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            SettingsIcon(icon: icon, color: color)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)

                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(value)
                .foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func systemStorageInfo() -> (free: Int64, total: Int64)? {
        do {
            let attributes = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            if let freeSize = attributes[.systemFreeSize] as? NSNumber,
               let totalSize = attributes[.systemSize] as? NSNumber {
                return (free: freeSize.int64Value, total: totalSize.int64Value)
            }
        } catch {
            print("Error getting system storage info: \(error)")
        }
        return nil
    }
}

private struct StorageUsageCard: View {
    let free: Int64
    let total: Int64

    var body: some View {
        let used = max(0, total - free)
        let usedRatio = total > 0 ? Double(used) / Double(total) : 0
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file

        let freeStr = formatter.string(fromByteCount: free)
        let totalStr = formatter.string(fromByteCount: total)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                SettingsIcon(icon: "internaldrive.fill", color: Color(UIColor.systemBlue))

                VStack(alignment: .leading, spacing: 3) {
                    Text(NSLocalizedString("Device Storage", comment: ""))
                        .font(.body)
                        .foregroundColor(.primary)

                    Text(String(format: NSLocalizedString("Free Space: %@ / Total: %@", comment: ""), freeStr, totalStr))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(UIColor.tertiarySystemFill))
                        .frame(height: 8)

                    Capsule()
                        .fill(usedRatio > 0.9 ? Color.red : Color.blue)
                        .frame(width: geo.size.width * CGFloat(usedRatio), height: 8)
                }
            }
            .frame(height: 8)
        }
        .padding(16)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(14)
        .padding(.horizontal)
    }
}

struct SettingsAppIconView: View {
    @ObservedObject var appIconService: AppIconService
    @ObservedObject private var donationService = DonationService.shared

    init(appIconService: AppIconService = .shared) {
        self.appIconService = appIconService
    }

    private enum IconChangeAlert: Identifiable {
        case failure(String)

        var id: String {
            switch self {
            case .failure(let message):
                return "failure-\(message)"
            }
        }
    }

    @State private var activeAlert: IconChangeAlert?
    @State private var isApplyingIcon = false
    @State private var isShowingDonationSheet = false

    private let previewSize: CGFloat = 60
    private let previewCornerRadius: CGFloat = 14
    private let gridSpacing: CGFloat = 12

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Supporter Exclusive Section
                if !appIconService.exclusiveOptions.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Image(systemName: "crown.fill")
                                .foregroundColor(Color(UIColor.systemYellow))
                            Text(NSLocalizedString("Supporter Exclusive", comment: ""))
                                .font(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            if donationService.isLifetimeSupporter {
                                Text(NSLocalizedString("Unlocked", comment: ""))
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundColor(Color(UIColor.systemGreen))
                            }
                        }

                        Text(NSLocalizedString("Exclusive black and white gold edition icons. Unlocked by supporting GenPlayer.", comment: ""))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Divider()

                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 60, maximum: 72), spacing: gridSpacing, alignment: .top)
                            ],
                            alignment: .center,
                            spacing: gridSpacing
                        ) {
                            ForEach(appIconService.exclusiveOptions) { option in
                                Button(action: {
                                    handleIconTap(option)
                                }) {
                                    exclusiveIconCard(option)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(isApplyingIcon)
                            }
                        }
                    }
                    .padding(16)
                    .background(Color(UIColor.secondarySystemGroupedBackground))
                    .cornerRadius(24)
                }

                // Regular Icons Section
                VStack(alignment: .leading, spacing: 14) {
                    Text(NSLocalizedString("Choose a launcher icon style. Changes apply immediately after selection.", comment: ""))
                        .font(.body)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(NSLocalizedString("If iOS Home Screen icon style is set to Tinted, all app icons become monochrome and visual differences between icon variants may be reduced.", comment: ""))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Divider()

                    LazyVGrid(
                        columns: [
                            GridItem(.adaptive(minimum: 60, maximum: 72), spacing: gridSpacing, alignment: .top)
                        ],
                        alignment: .center,
                        spacing: gridSpacing
                    ) {
                        ForEach(appIconService.regularOptions) { option in
                            Button(action: {
                                applyIcon(option)
                            }) {
                                iconOptionCard(option)
                            }
                            .buttonStyle(PlainButtonStyle())
                            .disabled(isApplyingIcon)
                        }
                    }
                }
                .padding(16)
                .background(Color(UIColor.secondarySystemGroupedBackground))
                .cornerRadius(24)
            }
            .padding(16)
        }
        .background(Color(UIColor.systemGroupedBackground).edgesIgnoringSafeArea(.all))
        .navigationTitle(NSLocalizedString("App Icon", comment: ""))
        .sheet(isPresented: $isShowingDonationSheet) {
            NavigationView {
                SettingsDonationView(isPresentedModally: true)
                    .navigationBarItems(
                        leading: Button(action: {
                            isShowingDonationSheet = false
                        }) {
                            AppToolbarIcon(systemName: "xmark", style: .secondary)
                        }
                    )
            }
        }
        .alert(item: $activeAlert) { alert in
            switch alert {
            case .failure(let message):
                return Alert(
                    title: Text(NSLocalizedString("Unable to Change App Icon", comment: "")),
                    message: Text(message),
                    dismissButton: .default(Text(NSLocalizedString("OK", comment: "")))
                )
            }
        }
        .onAppear {
            appIconService.refresh()
        }
    }

    private func handleIconTap(_ option: AppIconOption) {
        if appIconService.isUnlocked(option) {
            applyIcon(option)
        } else if DonationService.shared.isChinaStorefront {
            isShowingDonationSheet = true
        }
    }

    private func exclusiveIconCard(_ option: AppIconOption) -> some View {
        let isSelected = appIconService.isSelected(option)
        let isUnlocked = appIconService.isUnlocked(option)

        return ZStack(alignment: .topTrailing) {
            Image(uiImage: UIImage(named: option.previewAssetName) ?? UIImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: previewSize, height: previewSize)
                .cornerRadius(previewCornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: previewCornerRadius)
                        .stroke(
                            isSelected ? Color(UIColor.systemBlue) : Color.clear,
                            lineWidth: 3
                        )
                )
                .shadow(color: Color.black.opacity(0.08), radius: 2)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Color(UIColor.systemBlue))
                    .background(
                        Circle()
                            .fill(Color(UIColor.systemBackground))
                            .frame(width: 16, height: 16)
                    )
                    .offset(x: 4, y: -4)
            } else if !isUnlocked {
                Image(systemName: "crown.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .frame(width: 18, height: 18)
                    .background(
                        Circle()
                            .fill(Color(UIColor.systemOrange))
                    )
                    .offset(x: 4, y: -4)
            }
        }
        .frame(width: previewSize, height: previewSize)
    }

    private func iconOptionCard(_ option: AppIconOption) -> some View {
        let isSelected = appIconService.isSelected(option)

        return ZStack(alignment: .topTrailing) {
            Image(uiImage: UIImage(named: option.previewAssetName) ?? UIImage())
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: previewSize, height: previewSize)
                .cornerRadius(previewCornerRadius)
                .overlay(
                    RoundedRectangle(cornerRadius: previewCornerRadius)
                        .stroke(
                            isSelected ? Color(UIColor.systemBlue) : Color.clear,
                            lineWidth: 3
                        )
                )
                .shadow(color: Color.black.opacity(0.08), radius: 2)

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(Color(UIColor.systemBlue))
                    .background(
                        Circle()
                            .fill(Color(UIColor.systemBackground))
                            .frame(width: 16, height: 16)
                    )
                    .offset(x: 4, y: -4)
            }
        }
        .frame(width: previewSize, height: previewSize)
    }

    private func applyIcon(_ option: AppIconOption) {
        guard !isApplyingIcon else { return }
        isApplyingIcon = true
        appIconService.apply(option) { error in
            isApplyingIcon = false
            if let error = error {
                let nsError = error as NSError
                let message: String
                if nsError.code == AppIconServiceErrorCode.unsupported {
                    message = NSLocalizedString("Alternate app icons are not supported on this device.", comment: "")
                } else if nsError.code == AppIconServiceErrorCode.iconNotRegistered {
                    message = NSLocalizedString("The selected icon is not available in the current app build. Please reinstall after a full build.", comment: "")
                } else if nsError.code == AppIconServiceErrorCode.changeInProgress {
                    message = NSLocalizedString("Another icon change is still in progress. Please wait a moment and try again.", comment: "")
                } else if nsError.code == AppIconServiceErrorCode.systemBusy {
                    message = NSLocalizedString("The system is temporarily busy changing the app icon. Please try again in a moment.", comment: "")
                } else {
                    message = error.localizedDescription.isEmpty
                        ? NSLocalizedString("App icon could not be updated on this device.", comment: "")
                        : error.localizedDescription
                }
                activeAlert = .failure(message)
            }
        }
    }
}

struct SettingsIcon: View {
    let icon: String
    let color: Color
    
    var body: some View {
        Image(systemName: icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 16, height: 16)
            .padding(6)
            .background(color)
            .foregroundColor(.white)
            .cornerRadius(6)
            .padding(.trailing, 8)
    }
}

struct SettingsPinSetupView: View {
    let mode: SettingsView.PinSetupMode
    let navigationTitle: String
    @Binding var isPresented: Bool
    let existingPasswordIsSimple: Bool
    let validateCurrentPassword: ((String) -> Bool)?
    let onSave: (String) -> Void
    
    enum PasswordType: String, CaseIterable, Identifiable {
        case simple
        case complex
        
        var id: String { self.rawValue }
        
        var title: String {
            switch self {
            case .simple: return NSLocalizedString("Simple PIN", comment: "")
            case .complex: return NSLocalizedString("Complex Password", comment: "")
            }
        }
        
        var subtitle: String {
            switch self {
            case .simple: return NSLocalizedString("4-digit numeric code", comment: "")
            case .complex: return NSLocalizedString("Letters, numbers & symbols", comment: "")
            }
        }
        
        var icon: String {
            switch self {
            case .simple: return "circle.grid.2x2.fill"
            case .complex: return "key.fill"
            }
        }
        
        var color: Color {
            switch self {
            case .simple: return .blue
            case .complex: return .orange
            }
        }
    }
    
    @State private var passwordType: PasswordType = .simple
    @State private var currentPassword: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var errorMessage = ""
    
    var body: some View {
        NavigationView {
            Form {
                // Security Type Selection — custom vibrant tabs
                Section(
                    header: Text(NSLocalizedString("Security Type", comment: "")),
                    footer: Text(passwordType.subtitle)
                ) {
                    SecurityTypePicker(selection: $passwordType)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .onChange(of: passwordType) { _ in
                            password = ""
                            confirmPassword = ""
                            errorMessage = ""
                        }
                }
                
                if mode == .change {
                    Section(
                        header: Text(
                            existingPasswordIsSimple
                                ? NSLocalizedString("Current PIN", comment: "")
                                : NSLocalizedString("Current Password", comment: "")
                        )
                    ) {
                        if existingPasswordIsSimple {
                            SecureField(NSLocalizedString("Enter Current PIN", comment: ""), text: $currentPassword)
                                .keyboardType(.numberPad)
                                .onChange(of: currentPassword) { newValue in
                                    let filtered = newValue.filter { "0123456789".contains($0) }
                                    if filtered.count > 4 {
                                        currentPassword = String(filtered.prefix(4))
                                    } else if filtered != newValue {
                                        currentPassword = filtered
                                    }
                                }
                        } else {
                            SecureField(NSLocalizedString("Enter Current Password", comment: ""), text: $currentPassword)
                                .keyboardType(.default)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }
                    }
                }

                // New Password Input
                Section(header: Text(mode == .create ? NSLocalizedString("Create Password", comment: "") : NSLocalizedString("Change Password", comment: ""))) {
                    if passwordType == .simple {
                        SecureField(NSLocalizedString("Enter 4-digit PIN", comment: ""), text: $password)
                            .keyboardType(.numberPad)
                            .onChange(of: password) { newValue in
                                let filtered = newValue.filter { "0123456789".contains($0) }
                                if filtered.count > 4 {
                                    password = String(filtered.prefix(4))
                                } else if filtered != newValue {
                                    password = filtered
                                }
                            }
                        
                        SecureField(NSLocalizedString("Confirm PIN", comment: ""), text: $confirmPassword)
                            .keyboardType(.numberPad)
                            .onChange(of: confirmPassword) { newValue in
                                let filtered = newValue.filter { "0123456789".contains($0) }
                                if filtered.count > 4 {
                                    confirmPassword = String(filtered.prefix(4))
                                } else if filtered != newValue {
                                    confirmPassword = filtered
                                }
                            }
                    } else {
                        SecureField(NSLocalizedString("Enter Password", comment: ""), text: $password)
                            .keyboardType(.default)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        
                        SecureField(NSLocalizedString("Confirm Password", comment: ""), text: $confirmPassword)
                            .keyboardType(.default)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                    }
                }
                
                if !errorMessage.isEmpty {
                    Text(errorMessage)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                Section {
                    Button(action: save) {
                        HStack {
                            Spacer()
                            Text(NSLocalizedString("Save", comment: ""))
                                .fontWeight(.semibold)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarItems(
                leading: Button(action: {
                    isPresented = false
                }) {
                    AppToolbarIcon(systemName: "xmark", style: .secondary)
                }
            )
        }
    }
    
    private func save() {
        if mode == .change && !validateCurrentPasswordInput() {
            return
        }
        if !validatePassword(password) { return }
        
        if confirmPassword == password {
            onSave(password)
            isPresented = false
        } else {
            errorMessage = NSLocalizedString("Passwords do not match", comment: "")
        }
    }
    
    private func validatePassword(_ input: String) -> Bool {
        if passwordType == .simple {
            if input.count != 4 {
                errorMessage = NSLocalizedString("PIN must be 4 digits", comment: "")
                return false
            }
        } else {
            if input.count < 4 {
                errorMessage = NSLocalizedString("Password must be at least 4 characters", comment: "")
                return false
            }
        }
        return true
    }

    private func validateCurrentPasswordInput() -> Bool {
        guard let validateCurrentPassword else { return true }
        guard validateCurrentPassword(currentPassword) else {
            errorMessage = existingPasswordIsSimple
                ? NSLocalizedString("Current PIN is incorrect.", comment: "")
                : NSLocalizedString("Current password is incorrect.", comment: "")
            return false
        }
        return true
    }
}

/// Horizontal pill-style vibrant security type picker (compact single line).
/// Uses the same `SettingsPinSetupView.PasswordType` enum.
struct SecurityTypePicker: View {
    @Binding var selection: SettingsPinSetupView.PasswordType

    var body: some View {
        HStack(spacing: 8) {
            ForEach(SettingsPinSetupView.PasswordType.allCases) { type in
                Button(action: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selection = type
                    }
                }) {
                    HStack(spacing: 6) {
                        Image(systemName: type.icon)
                            .font(.system(size: 14, weight: .semibold))
                        Text(type.title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .foregroundColor(selection == type ? .white : type.color)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(selection == type ? type.color : type.color.opacity(0.12))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(selection == type ? type.color : type.color.opacity(0.25), lineWidth: 1.5)
                    )
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct SettingsAboutView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var selectedExternalURL: URL?
    let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    private let websiteURL = URL(string: "https://genplayer.fugary.com/")!
    private let releaseNotesURL = URL(string: "https://genplayer.fugary.com/changelog.html")!
    private let privacyPolicyURL = URL(string: "https://genplayer.fugary.com/privacy.html")!
    
    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                VStack(spacing: 16) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.blue)
                        .padding()
                        .background(Color(UIColor.secondarySystemBackground))
                        .cornerRadius(20)
                    
                    Text(NSLocalizedString("Gen Player", comment: ""))
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text("\(NSLocalizedString("Version", comment: "")) \(appVersion) (\(buildNumber))")
                        .foregroundColor(.secondary)
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
                
                VStack(alignment: .leading, spacing: 10) {
                    Text(NSLocalizedString("Description", comment: ""))
                        .font(.headline)
                        .foregroundColor(.secondary)
                    
                    Text(NSLocalizedString("AppDescription", comment: ""))
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal)
                .frame(maxWidth: .infinity, alignment: .leading)
                
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(NSLocalizedString("Copyright", comment: ""))
                        Spacer()
                        Text("© 2026 Gary Fu")
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 4)
                    
                    aboutLinkRow(
                        title: NSLocalizedString("Website", comment: ""),
                        icon: "globe",
                        destination: websiteURL
                    )

                    aboutLinkRow(
                        title: NSLocalizedString("Privacy Policy", comment: ""),
                        icon: "hand.raised.fill",
                        destination: privacyPolicyURL
                    )

                    aboutLinkRow(
                        title: NSLocalizedString("Release Notes", comment: ""),
                        icon: "doc.text",
                        destination: releaseNotesURL
                    )

                    #if os(macOS)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
                    } label: {
                        aboutRowContent(
                            title: NSLocalizedString("Show in Finder", comment: ""),
                            icon: "folder",
                            trailingSymbol: "arrow.up.right.square"
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(.primary)
                    #endif

                    if DonationService.shared.isChinaStorefront {
                        NavigationLink(destination: SettingsDonationView()) {
                            aboutRowContent(
                                title: NSLocalizedString("Support GenPlayer", comment: ""),
                                subtitle: NSLocalizedString("Tip the developer & unlock exclusive gold icons", comment: ""),
                                icon: "heart.fill",
                                trailingSymbol: "chevron.right"
                            )
                        }
                        .buttonStyle(PlainButtonStyle())
                        .foregroundColor(.primary)
                    }

                    NavigationLink(destination: OpenSourceLicensesView()) {
                        aboutRowContent(
                            title: NSLocalizedString("Open Source Licenses", comment: ""),
                            subtitle: "MobileVLCKit · Kingfisher · SnapKit",
                            icon: "doc.text.magnifyingglass",
                            trailingSymbol: "chevron.right"
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .foregroundColor(.primary)
                }
                .padding(.horizontal)
                
                Spacer()
                Spacer()
            }
        }
        .navigationTitle(NSLocalizedString("About", comment: ""))
        .sheet(item: Binding<URLWrapper?>(
            get: { selectedExternalURL != nil ? URLWrapper(url: selectedExternalURL!) : nil },
            set: { selectedExternalURL = $0?.url }
        )) { wrapper in
            SafariView(url: wrapper.url)
                .edgesIgnoringSafeArea(.all)
        }
    }

    private func aboutLinkRow(title: String, icon: String, destination: URL) -> some View {
        Button(action: {
            selectedExternalURL = configuredWebsiteURL(from: destination)
        }) {
            aboutRowContent(
                title: title,
                subtitle: externalLinkSubtitle(for: destination),
                icon: icon,
                trailingSymbol: "arrow.up.right.square"
            )
        }
        .buttonStyle(PlainButtonStyle())
        .foregroundColor(.primary)
    }

    private func aboutRowContent(
        title: String,
        subtitle: String,
        icon: String,
        trailingSymbol: String
    ) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.opacity(0.12))
                    .frame(width: 34, height: 34)
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.blue)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Image(systemName: trailingSymbol)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color(UIColor.secondarySystemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(UIColor.separator).opacity(0.24), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func externalLinkSubtitle(for destination: URL) -> String {
        let host = destination.host ?? destination.absoluteString
        let path = destination.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty ? host : "\(host)/\(path)"
    }

    private func configuredWebsiteURL(from baseURL: URL) -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            return baseURL
        }

        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "theme" || $0.name == "lang" }
        queryItems.append(URLQueryItem(name: "theme", value: resolvedWebsiteTheme()))
        queryItems.append(URLQueryItem(name: "lang", value: resolvedWebsiteLanguage()))
        components.queryItems = queryItems
        return components.url ?? baseURL
    }

    private func resolvedWebsiteTheme() -> String {
        switch settings.userTheme {
        case "Dark":
            return "dark"
        case "Light":
            return "light"
        default:
            #if os(iOS)
            return currentInterfaceStyle() == .dark ? "dark" : "light"
            #else
            return "dark"
            #endif
        }
    }

    private func resolvedWebsiteLanguage() -> String {
        switch Bundle.resolvedAppLanguage(for: settings.appLanguage) {
        case "zh-Hans":
            return "zh-CN"
        case "zh-Hant":
            return "zh-TW"
        default:
            return "en"
        }
    }

    #if os(iOS)
    private func currentInterfaceStyle() -> UIUserInterfaceStyle {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let keyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return keyWindow.traitCollection.userInterfaceStyle
        }
        if let firstWindow = scenes.flatMap(\.windows).first {
            return firstWindow.traitCollection.userInterfaceStyle
        }
        return .unspecified
    }
    #endif
}
