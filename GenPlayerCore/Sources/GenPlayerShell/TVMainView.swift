#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

enum TVShellStyle {
    static let accent = dynamicColor(
        light: UIColor(red: 0.10, green: 0.44, blue: 0.78, alpha: 1),
        dark: UIColor(red: 0.20, green: 0.56, blue: 0.92, alpha: 1)
    )
    static let accentSoft = dynamicColor(
        light: UIColor(red: 0.11, green: 0.68, blue: 0.69, alpha: 1),
        dark: UIColor(red: 0.34, green: 0.78, blue: 1.0, alpha: 1)
    )
    static let background = dynamicColor(
        light: UIColor(red: 0.91, green: 0.94, blue: 0.97, alpha: 1),
        dark: UIColor(red: 0.018, green: 0.020, blue: 0.026, alpha: 1)
    )
    static let surface = dynamicColor(
        light: UIColor.white.withAlphaComponent(0.74),
        dark: UIColor.white.withAlphaComponent(0.062)
    )
    static let elevatedSurface = dynamicColor(
        light: UIColor.white.withAlphaComponent(0.90),
        dark: UIColor.white.withAlphaComponent(0.095)
    )
    static let subtleFill = dynamicColor(
        light: UIColor.black.withAlphaComponent(0.060),
        dark: UIColor.white.withAlphaComponent(0.090)
    )
    static let separator = dynamicColor(
        light: UIColor.black.withAlphaComponent(0.095),
        dark: UIColor.white.withAlphaComponent(0.095)
    )
    static let glassStroke = dynamicColor(
        light: UIColor.black.withAlphaComponent(0.130),
        dark: UIColor.white.withAlphaComponent(0.130)
    )
    static let focusStroke = dynamicColor(
        light: UIColor(red: 0.10, green: 0.13, blue: 0.18, alpha: 0.86),
        dark: UIColor.white.withAlphaComponent(0.92)
    )
    static let primary = dynamicColor(
        light: UIColor(red: 0.070, green: 0.085, blue: 0.115, alpha: 1),
        dark: UIColor.white.withAlphaComponent(0.96)
    )
    static let secondary = dynamicColor(
        light: UIColor(red: 0.31, green: 0.36, blue: 0.43, alpha: 1),
        dark: UIColor.white.withAlphaComponent(0.62)
    )

    private static func dynamicColor(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? dark : light
        })
    }
}

enum TVBrandIdentity {
    static let displayName = "Gen Player"
}

enum TVRootTab: String, Hashable, CaseIterable {
    case servers
    case profile
    case settings

    var title: String {
        switch self {
        case .servers:
            return platformShellString("Network")
        case .profile:
            return platformShellString("My")
        case .settings:
            return platformShellString("Settings")
        }
    }

    var systemImageName: String {
        switch self {
        case .servers:
            return "network"
        case .profile:
            return "person.crop.circle.fill"
        case .settings:
            return "gearshape"
        }
    }

}

public struct TVMainView: View {
    private static let onboardingVersion = "2026.06.tv-guide"

    @AppStorage("appLanguage") private var appLanguage: String = "system"
    private let historyService = HistoryService.shared
    private let favoriteService = FavoriteService.shared
    private let downloadCenter = DownloadCenterService.shared
    @AppStorage("onboardingCompletedVersion") private var onboardingCompletedVersion = ""
    @AppStorage("onboardingForceReplay") private var onboardingForceReplay = false
    @SceneStorage("tvRootTabSelection") private var selection: TVRootTab = .servers
    @State private var isSplashVisible = true
    @State private var isOnboardingVisible = false
    @State private var hasResolvedOnboarding = false

    public init() {}

    private var rootSelection: Binding<TVRootTab> {
        Binding(
            get: { selection },
            set: { updateSelection($0) }
        )
    }

    @ViewBuilder
    private func rootTabContent(for tab: TVRootTab) -> some View {
        switch tab {
        case .servers:
            NavigationStack {
                TVServersRootView(selection: rootSelection)
            }
        case .profile:
            NavigationStack {
                TVProfileRootView(selection: rootSelection)
            }
        case .settings:
            NavigationStack {
                TVSettingsRootView(selection: rootSelection)
            }
        }
    }

    @ViewBuilder
    private var rootTabView: some View {
        TabView(selection: rootSelection) {
            ForEach(TVRootTab.allCases, id: \.self) { tab in
                rootTabContent(for: tab)
                    .tag(tab)
                    .tabItem {
                        Label {
                            Text(tab.title)
                        } icon: {
                            Image(systemName: tab.systemImageName)
                        }
                    }
            }
        }
        .id("TVMainView_\(appLanguage)")
    }

    @ObservedObject private var presentationManager = TVStoredMediaPresentationManager.shared

    private var shouldShowOnboarding: Bool {
        isOnboardingVisible || onboardingCompletedVersion != Self.onboardingVersion
    }

    public var body: some View {
        ZStack {
            TVCinematicBackground()

            if isSplashVisible {
                TVLaunchSplashView()
                    .transition(.opacity)
                    .zIndex(200)
            } else if shouldShowOnboarding {
                TVFirstLaunchOnboardingView(onClose: completeOnboarding)
                    .transition(.opacity)
                    .zIndex(100)
            } else {
                rootTabView
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .disabled(presentationManager.isBrowsing)
                    .allowsHitTesting(!presentationManager.isBrowsing)
                    .accessibilityHidden(presentationManager.isBrowsing)
                    .opacity(presentationManager.isBrowsing ? 0 : 1)
            }

            browsingPresentation
                .zIndex(300)
        }
        .onAppear {
            historyService.refresh()
            favoriteService.refresh()
            downloadCenter.reconcileMissingLocalFiles()
            resolveOnboardingIfNeeded()
        }
        .onChange(of: onboardingForceReplay) { shouldReplay in
            guard shouldReplay else { return }
            onboardingForceReplay = false
            presentOnboarding()
        }
    }

    @ViewBuilder
    private var browsingPresentation: some View {
        if let server = presentationManager.server {
            TVBrowsingContainer(onExit: {
                guard presentationManager.server?.id == server.id else { return }
                presentationManager.closeBrowsing()
            }) {
                TVPrivacyProtectedContent(
                    title: server.name,
                    isProtected: tvRequiresPrivacyAccess(server: server)
                ) {
                    if server.type == .iptv {
                        TVIPTVPresentationRoot(server: server, onExit: { presentationManager.closeBrowsing() })
                    } else if server.type.tvIsMediaLibraryServer {
                        TVMediaServerPresentationRoot(server: server)
                    } else {
                        TVFileServerPresentationRoot(server: server)
                    }
                }
            }
            .id(server.id)
            .tvApplyAppTheme()
        } else if let presentation = presentationManager.presentation {
            TVBrowsingContainer(onExit: {
                guard presentationManager.presentation?.id == presentation.id else { return }
                presentationManager.closeBrowsing()
            }) {
                TVStoredMediaPresentationRoot(file: presentation.file, intent: presentation.intent)
            }
            .id(presentation.id)
            .tvApplyAppTheme()
        }
    }

    private func updateSelection(_ newSelection: TVRootTab) {
        guard selection != newSelection else { return }
        selection = newSelection
    }

    private func resolveOnboardingIfNeeded() {
        guard !hasResolvedOnboarding else { return }
        hasResolvedOnboarding = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) {
            withAnimation(.easeOut(duration: 0.35)) {
                isSplashVisible = false
            }
        }

        if onboardingForceReplay {
            onboardingForceReplay = false
            presentOnboarding()
            return
        }
    }

    private func presentOnboarding() {
        withAnimation(.easeInOut(duration: 0.22)) {
            isOnboardingVisible = true
        }
    }

    private func completeOnboarding() {
        onboardingCompletedVersion = Self.onboardingVersion
        withAnimation(.easeInOut(duration: 0.22)) {
            isOnboardingVisible = false
        }
    }
}

/// A button style for non-interactive focusable sections (e.g. text-only panels
/// on a detail page). Provides a very subtle focus indicator so tvOS scroll works
/// without introducing a large system focus rectangle.


// MARK: - Tab 1: Servers


// MARK: - Tab 2: My (Profile)


// MARK: - Media Library Networking

#endif

#if os(tvOS)
private struct TVLaunchSplashView: View {
    @State private var animatePulse = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            VStack(spacing: 32) {
                if #available(tvOS 17.0, *) {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 140))
                        .foregroundColor(TVShellStyle.accent)
                        .symbolEffect(.pulse, options: .repeating, isActive: animatePulse)
                } else {
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 140))
                        .foregroundColor(TVShellStyle.accent)
                        .opacity(animatePulse ? 1.0 : 0.6)
                        .animation(.easeInOut(duration: 1.0).repeatForever(), value: animatePulse)
                }
                
                Text(TVBrandIdentity.displayName)
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
        }
        .onAppear {
            animatePulse = true
        }
    }
}
#endif
