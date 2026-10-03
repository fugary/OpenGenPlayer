import SwiftUI
#if os(iOS)
import UIKit
#endif
import Combine

class AppLockManager: ObservableObject {
    static let shared = AppLockManager()
    
    private var lockWindow: UIWindow?
    private var cancellables = Set<AnyCancellable>()
    
    private init() {
        // Observe SecurityService to show/hide window
        SecurityService.shared.$isLocked
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isLocked in
                self?.handleLockStateChange(isLocked: isLocked)
            }
            .store(in: &cancellables)
            
        // Observe scene activation to ensure window is properly attached
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.ensureWindowVisibleIfNeeded()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIWindowScene.willConnectNotification)
            .sink { [weak self] notification in
                let scene = notification.object as? UIWindowScene
                DispatchQueue.main.async {
                    self?.ensureWindowVisibleIfNeeded(preferredScene: scene)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIScene.didActivateNotification)
            .sink { [weak self] notification in
                let scene = notification.object as? UIWindowScene
                self?.ensureWindowVisibleIfNeeded(preferredScene: scene)
            }
            .store(in: &cancellables)
    }
    
    func setup() {
        print("[AppLockManager] Setup called")
        if SecurityService.shared.isLocked {
            showLockWindow()
        }
    }
    
    private func handleLockStateChange(isLocked: Bool) {
        if isLocked {
            showLockWindow()
        } else {
            hideLockWindow()
        }
    }
    
    private func ensureWindowVisibleIfNeeded(preferredScene: UIWindowScene? = nil) {
        if SecurityService.shared.isLocked {
            // Force show if needed
            showLockWindow(preferredScene: preferredScene)
            if SecurityService.shared.useBiometrics {
                SecurityService.shared.autoAuthenticateIfNeeded()
            }
        }
    }
    
    private func showLockWindow(preferredScene: UIWindowScene? = nil) {
        // 1. Find the active window scene
        // We prioritize the first connected scene that is foreground
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windowScene = preferredScene
            ?? scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
        guard let scene = windowScene else {
            print("[AppLockManager] No window scene found!")
            return
        }
        
        // 2. Create window if needed
        if lockWindow == nil {
            let window = UIWindow(windowScene: scene)
            window.backgroundColor = .black // Ensure opaque background
            
            // 3. Set up the root view controller
            let lockView = LockScreenView(securityService: SecurityService.shared)
            let hostingController = UIHostingController(rootView: lockView)
            hostingController.view.backgroundColor = .black
            window.rootViewController = hostingController
            
            self.lockWindow = window
        }
        
        guard let window = lockWindow else { return }
        
        // 4. Ensure it's attached to the current scene
        if window.windowScene !== scene {
            window.windowScene = scene
        }
        
        // 5. Set EXTREMELY high window level to cover everything
        // Standard alert is 2000. We use 10000.
        // Status bar is 1000.
        window.windowLevel = UIWindow.Level(rawValue: 10000)
        
        // 6. Show and make key
        window.alpha = 1.0
        window.isHidden = false
        window.makeKeyAndVisible()
        
        print("[AppLockManager] Lock window SHOWN at level \(window.windowLevel.rawValue)")
    }
    
    private func hideLockWindow() {
        guard let window = lockWindow else { return }
        
        // Animate out
        UIView.animate(withDuration: 0.3, animations: {
            window.alpha = 0
        }) { _ in
            window.isHidden = true
            window.alpha = 1.0 // Reset for reuse
            window.resignKey() // Resign key status
            
            // Make the main window key again
            if let windowScene = window.windowScene {
                if let mainWindow = windowScene.windows.first(where: { $0 != window && !$0.isHidden && $0.windowLevel == .normal }) {
                    mainWindow.makeKey()
                }
            }
            
            print("[AppLockManager] Lock window HIDDEN")
        }
    }
}
