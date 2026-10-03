import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Helper for programmatic navigation in SwiftUI deep stacks
struct NavigationUtil {
    /// Pops the current most visible UINavigationController to its root.
    /// This is especially useful for iOS 14 where SwiftUI infinite-depth navigation states are complex to bind.
    static func popToRootView() {
        // Find the active window scene
        guard let windowScene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene else {
            return
        }
        
        // Find the main window - either the key window, or the first normal-level window if key window was lost
        let window = windowScene.windows.first(where: { $0.isKeyWindow }) ?? windowScene.windows.first(where: { $0.windowLevel == .normal && !$0.isHidden })
        
        guard let rootViewController = window?.rootViewController else {
            return
        }
        
        let navigationController = findNavigationController(viewController: rootViewController)
        navigationController?.popToRootViewController(animated: true)
    }
    
    /// Recursively find the active UINavigationController
    static func findNavigationController(viewController: UIViewController?) -> UINavigationController? {
        guard let viewController = viewController else {
            return nil
        }
        
        // Prioritize deeply presented view controllers (the active modal)
        if let presentedViewController = viewController.presentedViewController {
             if let found = findNavigationController(viewController: presentedViewController) {
                 return found
             }
        }
        
        // Prioritize the selected tab in a UITabBarController
        if let tabBarController = viewController as? UITabBarController {
            if let selected = tabBarController.selectedViewController {
                if let found = findNavigationController(viewController: selected) {
                    return found
                }
            }
        }
        
        // Prioritize the detail pane (last view controller) in a UISplitViewController
        if let splitViewController = viewController as? UISplitViewController {
            if let detailOrSecondary = splitViewController.viewControllers.last {
                if let found = findNavigationController(viewController: detailOrSecondary) {
                    return found
                }
            }
        }
        
        if let navigationController = viewController as? UINavigationController {
            return navigationController
        }
        
        // Look within children, reverse order to prioritize top-most views
        for childViewController in viewController.children.reversed() {
            if let found = findNavigationController(viewController: childViewController) {
                return found
            }
        }
        
        return nil
    }
    
    /// Re-enables the swipe-back (interactive pop) gesture on the current navigation controller.
    /// Use after `.navigationBarBackButtonHidden(true)` to keep swipe-back working.
    static func enableSwipeBack() {
        guard let nav = findNavigationController(viewController: UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) })
            .first?.rootViewController) else { return }
        nav.interactivePopGestureRecognizer?.delegate = nil
        nav.interactivePopGestureRecognizer?.isEnabled = true
    }
}

// MARK: - SwiftUI View Extensions

extension View {
    /// Hides the system back button and re-enables swipe-back gesture.
    /// Use with a custom leading ToolbarItemGroup containing back + house buttons.
    @ViewBuilder
    func customBackButton() -> some View {
        self
            .navigationBarBackButtonHidden(true)
            .onAppear {
                NavigationUtil.enableSwipeBack()
            }
    }

    /// Conditionally applies a transform to the view.
    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
