#if os(iOS)
#if os(iOS)
import UIKit
#endif
import SwiftUI

class AppDelegate: NSObject, UIApplicationDelegate {
    
    static var orientationLock = UIInterfaceOrientationMask.all
    private static let incomingSharedFileQueue = DispatchQueue(label: "GenPlayer.AppDelegate.incomingSharedFileQueue")
    private static var recentlyHandledIncomingURLs: [String: Date] = [:]
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
        AppLockManager.shared.setup()
        _ = DownloadCenterService.shared
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return AppDelegate.orientationLock
    }

    func application(_ application: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
        if TVPairingCompanionService.handleIncomingURL(url) {
            return true
        }
        return AppDelegate.handleIncomingSharedFile(url)
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        _ = DownloadCenterService.shared
        BackgroundDownloadSessionManager.shared.registerBackgroundCompletionHandler(
            for: identifier,
            completionHandler: completionHandler
        )
    }

    @discardableResult
    static func handleIncomingSharedFile(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }

        let token = url.standardizedFileURL.absoluteString
        var shouldHandle = false

        incomingSharedFileQueue.sync {
            let now = Date()
            recentlyHandledIncomingURLs = recentlyHandledIncomingURLs.filter { now.timeIntervalSince($0.value) < 5.0 }
            if recentlyHandledIncomingURLs[token] == nil {
                recentlyHandledIncomingURLs[token] = now
                shouldHandle = true
            }
        }

        guard shouldHandle else { return true }
        FileManagerService.importExternalFiles(from: [url])
        return true
    }
}

#endif
