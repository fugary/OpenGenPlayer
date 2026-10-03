#if os(tvOS)
import SwiftUI
import UIKit
import GenPlayerCore
import GenPlayerShell

struct GenPlayerTVRootView: View {
    @ObservedObject private var playbackCoordinator = TVPlaybackCoordinator.shared
    @ObservedObject private var securityService = TVSecurityService.shared
    @AppStorage("userTheme") private var userTheme = "System"
    @AppStorage("appLanguage") private var appLanguage = "system"

    var body: some View {
        ZStack {
            if securityService.isSecurityEnabled && securityService.isLocked {
                TVAppUnlockView()
            } else {
                TVMainView()
            }

            if !(securityService.isSecurityEnabled && securityService.isLocked) {
                TVPlaybackWindowPresenter(
                    request: playbackCoordinator.activeRequest,
                    userTheme: userTheme,
                    appLanguage: appLanguage
                )
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        }
        .environment(\.locale, Locale(identifier: TVAppLanguageResolver.resolvedLanguage(for: appLanguage)))
        .preferredColorScheme(userTheme == "Dark" ? .dark : (userTheme == "Light" ? .light : nil))
        .onAppear {
            seedPlaybackHistoryDefaultsIfNeeded()
        }
    }

    private func seedPlaybackHistoryDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "enableVideoHistory": true,
            "enableAudioHistory": true
        ])

        if defaults.object(forKey: "enableVideoHistory") == nil {
            defaults.set(true, forKey: "enableVideoHistory")
        }
        if defaults.object(forKey: "enableAudioHistory") == nil {
            defaults.set(true, forKey: "enableAudioHistory")
        }

        let migrationKey = "tvPlaybackHistoryDefaultOnMigrationApplied"
        if !defaults.bool(forKey: migrationKey) {
            defaults.set(true, forKey: "enableVideoHistory")
            defaults.set(true, forKey: "enableAudioHistory")
            defaults.set(true, forKey: migrationKey)
        }
    }
}

private struct TVPlaybackWindowPresenter: UIViewControllerRepresentable {
    let request: TVPlaybackCoordinator.Request?
    let userTheme: String
    let appLanguage: String

    func makeUIViewController(context: Context) -> UIViewController {
        let viewController = UIViewController()
        viewController.view.backgroundColor = .clear
        return viewController
    }

    func updateUIViewController(_ viewController: UIViewController, context: Context) {
        context.coordinator.update(
            request: request,
            userTheme: userTheme,
            appLanguage: appLanguage,
            presenter: viewController
        )
    }

    static func dismantleUIViewController(_ viewController: UIViewController, coordinator: Coordinator) {
        TVPlaybackCoordinator.shared.traceExit("window-presenter-dismantle", includeStack: true)
        coordinator.closePlaybackWindow()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        private var playbackWindow: UIWindow?
        private weak var previousKeyWindow: UIWindow?
        private var hostingController: TVPlaybackHostingController?
        private var pendingRequestID: UUID?

        func update(request: TVPlaybackCoordinator.Request?, userTheme: String,
                    appLanguage: String, presenter: UIViewController) {
            pendingRequestID = request?.id
            guard let request else {
                closePlaybackWindow()
                return
            }
            let rootView = AnyView(
                TVPlaybackPresentationView(request: request)
                    .id(request.id)
                    .ignoresSafeArea()
                    .environment(\.locale, Locale(identifier: TVAppLanguageResolver.resolvedLanguage(for: appLanguage)))
                    .preferredColorScheme(userTheme == "Dark" ? .dark : (userTheme == "Light" ? .light : nil))
            )
            if let hostingController {
                hostingController.rootView = rootView
                return
            }
            guard let sourceWindow = presenter.view.window, let scene = sourceWindow.windowScene else {
                DispatchQueue.main.async { [weak self, weak presenter] in
                    guard let self, let presenter, self.pendingRequestID == request.id,
                          TVPlaybackCoordinator.shared.activeRequest?.id == request.id else { return }
                    self.update(request: request, userTheme: userTheme, appLanguage: appLanguage, presenter: presenter)
                }
                return
            }

            // A presented full-screen controller can be dismissed by tvOS before
            // Menu reaches onExitCommand, pressesEnded or even dismiss overrides.
            // A window root has no presentation to dismiss. Existing library covers
            // remain in the original window, with their navigation/focus untouched.
            let host = TVPlaybackHostingController(rootView: rootView)
            host.view.backgroundColor = .black
            let window = UIWindow(windowScene: scene)
            window.windowLevel = UIWindow.Level(rawValue: sourceWindow.windowLevel.rawValue + 1)
            window.backgroundColor = .black
            window.rootViewController = host
            previousKeyWindow = scene.windows.first(where: \.isKeyWindow) ?? sourceWindow
            hostingController = host
            playbackWindow = window
            TVPlaybackCoordinator.shared.traceExit("playback-window-open")
            window.makeKeyAndVisible()
        }

        func closePlaybackWindow() {
            pendingRequestID = nil
            guard let window = playbackWindow else { return }
            let restoreKeyWindow = window.isKeyWindow
            TVPlaybackCoordinator.shared.traceExit("playback-window-close", includeStack: true)
            // Release menu presentations before removing the window's root.
            hostingController?.dismiss(animated: false)
            window.isHidden = true
            window.rootViewController = nil
            hostingController = nil
            playbackWindow = nil
            if restoreKeyWindow, let previousKeyWindow, !previousKeyWindow.isHidden {
                previousKeyWindow.makeKey()
            }
            previousKeyWindow = nil
        }
    }
}

private final class TVPlaybackHostingController: UIHostingController<AnyView>, UIGestureRecognizerDelegate {
    private lazy var backPress = UITapGestureRecognizer(target: self, action: #selector(handleBackPress))

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Native UIMenu focus lives outside the SwiftUI subtree. Observe Menu
        // at this window only while playback is visible, before responder fallback.
        backPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
        backPress.allowedTouchTypes = []
        backPress.cancelsTouchesInView = true
        backPress.delegate = self
        view.window?.addGestureRecognizer(backPress)
    }

    override func viewWillDisappear(_ animated: Bool) {
        TVPlaybackCoordinator.shared.traceExit("host-will-disappear dismissing=\(isBeingDismissed)", includeStack: true)
        backPress.view?.removeGestureRecognizer(backPress)
        super.viewWillDisappear(animated)
    }

    @objc private func handleBackPress() {
        TVPlaybackCoordinator.shared.requestExitCommand(source: "window-menu-gesture")
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // Consume one Menu press before UIKit/SwiftUI can dismiss the presentation.
        gestureRecognizer === backPress
    }

    // A Menu press that reaches the host must follow the player's layer order,
    // rather than UIKit's default dismissal of the full-screen presentation.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { $0.type != .menu }
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { $0.type != .menu }
        if remaining.count != presses.count {
            TVPlaybackCoordinator.shared.requestExitCommand(source: "host-press-ended")
        }
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { $0.type != .menu }
        if !remaining.isEmpty { super.pressesCancelled(remaining, with: event) }
    }


}

private enum TVAppLanguageResolver {
    private static let supportedLanguages = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "fr", "de", "es"]

    static func resolvedLanguage(for language: String) -> String {
        if language != "system" {
            return normalizedLanguage(from: language) ?? "en"
        }

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
#endif
