#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// Present on the owning player window, including the mini audio player.
struct MacPlaybackFailureAlertPresenter: NSViewRepresentable {
    let failureID: UUID?
    let message: String?
    let isCurrentFailure: (UUID) -> Bool
    let onRetry: () -> Void
    let onClose: () -> Void
    var onSwitchSource: (() -> Void)? = nil
    var onUseVLC: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WindowAnchor {
        let view = WindowAnchor()
        view.onWindowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowAnchor, context: Context) {
        context.coordinator.update(self)
        context.coordinator.attach(to: nsView.window)
    }

    static func dismantleNSView(_ nsView: WindowAnchor, coordinator: Coordinator) {
        nsView.onWindowChanged = nil
        coordinator.invalidate()
    }

    final class WindowAnchor: NSView {
        var onWindowChanged: ((NSWindow?) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChanged?(window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var request: MacPlaybackFailureAlertPresenter?
        private var subscriptions: [AnyCancellable] = []
        private var activeAlert: NSAlert?
        private var shownFailureID: UUID?
        private var isChangingFullScreen = false
        private var isClosing = false

        func update(_ request: MacPlaybackFailureAlertPresenter) {
            if self.request?.failureID != request.failureID {
                dismissAlert()
                shownFailureID = nil
            }
            self.request = request
            schedulePresentation()
        }

        func attach(to window: NSWindow?) {
            guard self.window !== window else { return }
            dismissAlert()
            shownFailureID = nil
            subscriptions.removeAll()
            self.window = window
            isChangingFullScreen = false
            isClosing = false
            guard let window else { return }

            for name in [NSWindow.willEnterFullScreenNotification, NSWindow.willExitFullScreenNotification] {
                observe(name, object: window) { $0.isChangingFullScreen = true }
            }
            for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification] {
                observe(name, object: window) {
                    $0.isChangingFullScreen = false
                    $0.schedulePresentation()
                }
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didEndSheetNotification,
                         NSWindow.didDeminiaturizeNotification] {
                observe(name, object: window) { $0.schedulePresentation() }
            }
            observe(NSApplication.didBecomeActiveNotification, object: NSApp) { $0.schedulePresentation() }
            observe(NSWindow.willCloseNotification, object: window) {
                $0.isClosing = true
                $0.dismissAlert()
                $0.subscriptions.removeAll()
            }
            schedulePresentation()
        }

        func invalidate() {
            request = nil
            subscriptions.removeAll()
            dismissAlert()
            window = nil
        }

        private func observe(_ name: Notification.Name, object: AnyObject, action: @escaping (Coordinator) -> Void) {
            subscriptions.append(NotificationCenter.default.publisher(for: name, object: object)
                .sink { [weak self] _ in
                    guard let self else { return }
                    action(self)
                })
        }

        private func schedulePresentation() {
            DispatchQueue.main.async { [weak self] in self?.presentIfReady() }
        }

        private func presentIfReady() {
            guard let request, let failureID = request.failureID, let message = request.message,
                  request.isCurrentFailure(failureID),
                  shownFailureID != failureID, activeAlert == nil,
                  let window, window.isVisible, !window.isMiniaturized, window.isKeyWindow,
                  NSApp.isActive, !isClosing, !isChangingFullScreen,
                  window.attachedSheet == nil, NSApp.modalWindow == nil else { return }

            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = platformShellString("Unable to Play")
            alert.informativeText = message
            alert.addButton(withTitle: platformShellString("Retry"))
            alert.addButton(withTitle: platformShellString("Close")).keyEquivalent = "\u{1b}"
            if request.onSwitchSource != nil { alert.addButton(withTitle: platformShellString("VOD Check and Switch")) }
            let useVLCResponse = NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + alert.buttons.count
            if request.onUseVLC != nil { alert.addButton(withTitle: platformShellString("MPV.UseVLC")) }
            activeAlert = alert
            shownFailureID = failureID
            alert.beginSheetModal(for: window) { [weak self, weak alert] response in
                guard let self, let alert, self.activeAlert === alert else { return }
                self.activeAlert = nil
                guard let current = self.request, current.failureID == failureID,
                      current.isCurrentFailure(failureID) else { return }
                if response == .alertFirstButtonReturn {
                    current.onRetry()
                } else if response == .alertSecondButtonReturn {
                    current.onClose()
                } else if current.onUseVLC != nil && response.rawValue == useVLCResponse {
                    DispatchQueue.main.async {
                        guard current.isCurrentFailure(failureID) else { return }
                        current.onUseVLC?()
                    }
                } else if response == .alertThirdButtonReturn {
                    DispatchQueue.main.async {
                        guard current.isCurrentFailure(failureID) else { return }
                        current.onSwitchSource?()
                    }
                }
            }
        }

        private func dismissAlert() {
            guard let alert = activeAlert else { return }
            activeAlert = nil
            if let parent = alert.window.sheetParent {
                parent.endSheet(alert.window, returnCode: .abort)
            }
            alert.window.orderOut(nil)
        }
    }
}
#endif
