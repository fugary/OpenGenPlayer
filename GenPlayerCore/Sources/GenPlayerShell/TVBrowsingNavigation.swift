#if os(tvOS)
import SwiftUI
import UIKit

/// The navigation stack owned by one full-screen browsing session, never a
/// navigation controller guessed from the application's current key window.
final class TVBrowsingNavigation: ObservableObject {
    weak var controller: UINavigationController?
    var onExit: () -> Void = {}
    private var isHandlingBack = false

    func back(custom: (() -> Bool)? = nil) {
        guard !isHandlingBack else { return }
        isHandlingBack = true
        DispatchQueue.main.async { [weak self] in self?.isHandlingBack = false }
        guard controller != nil else {
            trace("waiting-for-stack")
            return
        }
        if controller?.transitionCoordinator != nil { return }
        if custom?() == true {
            trace("custom-page-back")
            return
        }
        if pop() { return }
        guard controller?.viewControllers.count == 1 else { return }
        trace("exit-browsing-root")
        onExit()
    }

    @discardableResult
    func pop(toRoot: Bool = false) -> Bool {
        guard let controller else { return false }
        // A second callback during the same transition must not exit the root.
        if controller.transitionCoordinator != nil { return true }
        guard controller.viewControllers.count > 1 else { return false }
        if toRoot {
            controller.popToRootViewController(animated: true)
        } else {
            controller.popViewController(animated: true)
        }
        trace(toRoot ? "pop-to-browsing-root" : "pop-browsing-page")
        return true
    }

    private func trace(_ action: String) {
        #if DEBUG
        NSLog("[TVNavigationExit] %@ depth=%ld", action, controller?.viewControllers.count ?? 0)
        #endif
    }
}

private struct TVBrowsingNavigationKey: EnvironmentKey {
    static let defaultValue: TVBrowsingNavigation? = nil
}

extension EnvironmentValues {
    var tvBrowsingNavigation: TVBrowsingNavigation? {
        get { self[TVBrowsingNavigationKey.self] }
        set { self[TVBrowsingNavigationKey.self] = newValue }
    }
}

struct TVBrowsingContainer<Content: View>: View {
    let onExit: () -> Void
    @ViewBuilder let content: () -> Content
    @StateObject private var navigation = TVBrowsingNavigation()

    var body: some View {
        NavigationStack {
            content()
                .background(TVBrowsingStackAnchor(navigation: navigation).frame(width: 0, height: 0))
        }
        .environment(\.tvBrowsingNavigation, navigation)
        .background(TVShellStyle.background.ignoresSafeArea())
        .onAppear { navigation.onExit = onExit }
        .onDisappear {
            navigation.onExit = {}
            navigation.controller = nil
        }
    }
}

private struct TVBrowsingStackAnchor: UIViewControllerRepresentable {
    let navigation: TVBrowsingNavigation

    func makeUIViewController(context: Context) -> Anchor {
        Anchor(navigation: navigation)
    }

    func updateUIViewController(_ controller: Anchor, context: Context) {
        controller.captureStack()
    }

    final class Anchor: UIViewController {
        let navigation: TVBrowsingNavigation

        init(navigation: TVBrowsingNavigation) {
            self.navigation = navigation
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            view.isUserInteractionEnabled = false
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            captureStack()
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            captureStack()
        }

        func captureStack() {
            if let navigationController { navigation.controller = navigationController }
        }
    }
}
#endif
