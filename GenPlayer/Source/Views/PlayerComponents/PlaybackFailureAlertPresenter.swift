import SwiftUI
import UIKit

/// A presenter inside the player, rather than the covered library/root controller.
/// Keep the failure pending until this hierarchy can present a native alert.
struct PlaybackFailureAlertPresenter: UIViewControllerRepresentable {
    let failure: VLCPlaybackService.PlaybackFailure?
    let onRetry: () -> Void
    let onClose: () -> Void
    var onUseVLC: (() -> Void)? = nil

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.failure = failure
        controller.onRetry = onRetry
        controller.onClose = onClose
        controller.onUseVLC = onUseVLC
        controller.reconcile()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.invalidate()
    }

    final class Controller: UIViewController {
        var failure: VLCPlaybackService.PlaybackFailure?
        var onRetry: (() -> Void)?
        var onClose: (() -> Void)?
        var onUseVLC: (() -> Void)?
        private var isVisible = false
        private var retryPresentation: DispatchWorkItem?
        private var alert: UIAlertController?
        private var presentedFailureID: UUID?
        private var handledFailureID: UUID?
        private var isDismissingAlert = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            reconcile()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            isVisible = false
            retryPresentation?.cancel()
            retryPresentation = nil
        }

        func invalidate() {
            isVisible = false
            failure = nil
            retryPresentation?.cancel()
            retryPresentation = nil
            alert?.dismiss(animated: false)
            alert = nil
        }

        func reconcile() {
            retryPresentation?.cancel()
            retryPresentation = nil
            guard !isDismissingAlert else { return }

            if let alert, presentedFailureID != failure?.id {
                if alert.isBeingPresented || alert.isBeingDismissed {
                    scheduleReconciliation()
                    return
                }
                isDismissingAlert = true
                alert.dismiss(animated: true) { [weak self] in
                    guard let self else { return }
                    self.alert = nil
                    self.presentedFailureID = nil
                    self.isDismissingAlert = false
                    self.reconcile()
                }
                return
            }
            guard let failure, failure.id != handledFailureID, alert == nil,
                  isVisible, let window = viewIfLoaded?.window else { return }

            var presenter: UIViewController = self
            while let parent = presenter.parent { presenter = parent }
            guard window.windowScene?.activationState == .foregroundActive,
                  presenter.presentedViewController == nil,
                  presenter.transitionCoordinator == nil,
                  !presenter.isBeingPresented, !presenter.isBeingDismissed else {
                // Includes fullScreenCover transitions, info/playlist sheets and file importers.
                // No root-window lookup and no attempt to present over another modal.
                scheduleReconciliation()
                return
            }

            let controller = UIAlertController(
                title: NSLocalizedString("Unable to Play", comment: ""),
                message: failure.message,
                preferredStyle: .alert
            )
            controller.addAction(UIAlertAction(title: NSLocalizedString("Close", comment: ""), style: .cancel) { [weak self] _ in
                self?.handleAction(for: failure.id, retry: false)
            })
            let retry = UIAlertAction(title: NSLocalizedString("Retry", comment: ""), style: .default) { [weak self] _ in
                self?.handleAction(for: failure.id, retry: true)
            }
            controller.addAction(retry)
            if onUseVLC != nil {
                controller.addAction(UIAlertAction(title: NSLocalizedString("MPV.UseVLC", comment: ""), style: .default) { [weak self] _ in
                    guard let self, self.failure?.id == failure.id, self.handledFailureID != failure.id else { return }
                    self.handledFailureID = failure.id
                    self.onUseVLC?()
                })
            }
            controller.preferredAction = retry
            alert = controller
            presentedFailureID = failure.id
            presenter.present(controller, animated: true)
        }

        private func scheduleReconciliation() {
            let work = DispatchWorkItem { [weak self] in self?.reconcile() }
            retryPresentation = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }

        private func handleAction(for id: UUID, retry: Bool) {
            guard failure?.id == id, handledFailureID != id else { return }
            handledFailureID = id
            if retry { onRetry?() } else { onClose?() }
        }
    }
}
