import SwiftUI
#if os(iOS)
#if os(iOS)
import UIKit
#endif
#endif

@main
struct GenPlayerApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) var appDelegate
    #endif

    @AppStorage("userTheme") private var userTheme: String = "System"
    @AppStorage("appLanguage") private var appLanguage: String = "system"

    init() {
        createDefaultDirectoriesIfNeeded()
        #if os(iOS) || os(tvOS)
        FontInterceptor.setup()
        #endif

        let storedLanguage = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        Bundle.setLanguage(storedLanguage)

        #if os(iOS)
        // Liquid Glass owns toolbar contrast on iOS 26+. Keep the original
        // monochrome tint only on systems without the native adaptive material.
        if #unavailable(iOS 26.0) {
            UINavigationBar.appearance().tintColor = UIColor.label
            UIBarButtonItem.appearance().tintColor = UIColor.label
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            PlatformRootView(appLanguage: appLanguage)
                .environment(\.locale, Locale(identifier: Bundle.resolvedAppLanguage(for: appLanguage)))
                .preferredColorScheme(userTheme == "Dark" ? .dark : (userTheme == "Light" ? .light : nil))
                .modifier(PlatformRootLifecycleModifier(appLanguage: appLanguage))
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif
    }

    private func createDefaultDirectoriesIfNeeded() {
        #if os(macOS)
        // Skip creating Welcome.txt on macOS to avoid prompting for Documents folder access on launch
        return
        #else
        let fileManager = FileManager.default
        guard let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }

        let readmeURL = documentsURL.appendingPathComponent("Welcome.txt")
        if !fileManager.fileExists(atPath: readmeURL.path) {
            let content = NSLocalizedString("Welcome to GenPlayer! Drop your media files here.", comment: "")
            try? content.write(to: readmeURL, atomically: true, encoding: .utf8)
        }
        #endif
    }
}

private struct PlatformRootLifecycleModifier: ViewModifier {
    let appLanguage: String

    #if os(iOS) || os(macOS)
    @Environment(\.scenePhase) private var scenePhase
    private let securityService = SecurityService.shared
    #endif
    #if os(iOS)
    @ObservedObject private var companionService = TVPairingCompanionService.shared
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .onAppear {
                _ = securityService.refreshBiometricAvailability(clearUnavailablePreference: true)
                securityService.autoAuthenticateIfNeeded()
                Bundle.setLanguage(appLanguage)
            }
            .onOpenURL { url in
                if TVPairingCompanionService.handleIncomingURL(url) {
                    return
                }
                AppDelegate.handleIncomingSharedFile(url)
            }
            .sheet(item: $companionService.activeSession, onDismiss: {
                companionService.dismissSession()
            }) { session in
                TVPairingCompanionSheet(session: session)
            }
            .onChange(of: appLanguage) { newLang in
                Bundle.setLanguage(newLang)
                UIApplication.refreshInterfaceChrome(delays: [0, 0.08, 0.2])
            }
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .background {
                    if securityService.isSecurityEnabled {
                        securityService.isLocked = true
                    }
                    securityService.lockPrivacySpace()
                } else if newPhase == .active {
                    _ = securityService.refreshBiometricAvailability(clearUnavailablePreference: true)
                    if securityService.isLocked && securityService.useBiometrics {
                        securityService.autoAuthenticateIfNeeded()
                    }
                }
            }
        #else
        content
            .onAppear {
                #if os(macOS)
                _ = securityService.refreshBiometricAvailability(clearUnavailablePreference: true)
                securityService.autoAuthenticateIfNeeded()
                #endif
                Bundle.setLanguage(appLanguage)
            }
            .onChange(of: appLanguage) { newLang in
                Bundle.setLanguage(newLang)
            }
            #if os(macOS)
            .onChange(of: scenePhase) { newPhase in
                if newPhase == .background {
                    if securityService.isSecurityEnabled {
                        securityService.isLocked = true
                    }
                    securityService.lockPrivacySpace()
                } else if newPhase == .active {
                    _ = securityService.refreshBiometricAvailability(clearUnavailablePreference: true)
                    if securityService.isLocked && securityService.useBiometrics {
                        securityService.autoAuthenticateIfNeeded()
                    }
                }
            }
            #endif
        #endif
    }
}

#if os(macOS)
import AppKit

class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let wc = GenPlayerCore.MacPlayerWindowManager.shared.currentPlayerWindowController {
            DispatchQueue.main.async {
                wc.window?.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}
#endif
