import SwiftUI
#if os(iOS)
import UIKit
#endif

struct PlayerMultiTouchGestureBridge: UIViewRepresentable {
    @ObservedObject var playbackService: VLCPlaybackService
    var onZoomChanged: ((CGFloat) -> Void)? = nil
    var onZoomEnded: ((CGFloat) -> Void)? = nil
    var onReset: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(
            playbackService: playbackService,
            onZoomChanged: onZoomChanged,
            onZoomEnded: onZoomEnded,
            onReset: onReset
        )
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.onResize = { [weak coordinator = context.coordinator] in
            coordinator?.cancelGesturesForLayoutChange()
        }
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.playbackService = playbackService
        context.coordinator.onZoomChanged = onZoomChanged
        context.coordinator.onZoomEnded = onZoomEnded
        context.coordinator.onReset = onReset
        context.coordinator.attachIfNeeded(from: uiView)
        DispatchQueue.main.async { [weak uiView] in
            guard let uiView else { return }
            context.coordinator.attachIfNeeded(from: uiView)
        }
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AttachmentView: UIView {
        var onResize: (() -> Void)?
        private var previousSize: CGSize = .zero

        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.size != previousSize else { return }
            previousSize = bounds.size
            DispatchQueue.main.async { [weak self] in self?.onResize?() }
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var targetView: UIView?
        weak var playbackService: VLCPlaybackService?
        var onZoomChanged: ((CGFloat) -> Void)?
        var onZoomEnded: ((CGFloat) -> Void)?
        var onReset: (() -> Void)?

        private let pinchGestureRecognizer = UIPinchGestureRecognizer()
        private let panGestureRecognizer = UIPanGestureRecognizer()
        private let resetGestureRecognizer = UITapGestureRecognizer()

        private var activeGestureKinds: Set<String> = []
        private var pinchInitialZoomScale: CGFloat = 1.0
        private var pinchInitialOffset: CGSize = .zero
        private var panInitialOffset: CGSize = .zero
        private var pendingDetachCleanupWorkItem: DispatchWorkItem?

        init(
            playbackService: VLCPlaybackService,
            onZoomChanged: ((CGFloat) -> Void)?,
            onZoomEnded: ((CGFloat) -> Void)?,
            onReset: (() -> Void)?
        ) {
            self.playbackService = playbackService
            self.onZoomChanged = onZoomChanged
            self.onZoomEnded = onZoomEnded
            self.onReset = onReset
            super.init()

            pinchGestureRecognizer.addTarget(self, action: #selector(handlePinch(_:)))
            pinchGestureRecognizer.delegate = self
            pinchGestureRecognizer.cancelsTouchesInView = true

            panGestureRecognizer.addTarget(self, action: #selector(handlePan(_:)))
            panGestureRecognizer.minimumNumberOfTouches = 2
            panGestureRecognizer.maximumNumberOfTouches = 2
            panGestureRecognizer.delegate = self
            panGestureRecognizer.cancelsTouchesInView = true

            resetGestureRecognizer.addTarget(self, action: #selector(handleResetGesture(_:)))
            resetGestureRecognizer.numberOfTouchesRequired = 2
            resetGestureRecognizer.numberOfTapsRequired = 2
            resetGestureRecognizer.delegate = self
            resetGestureRecognizer.cancelsTouchesInView = true

            NotificationCenter.default.addObserver(
                self, selector: #selector(cancelGesturesForDeactivation),
                name: UIApplication.willResignActiveNotification, object: nil
            )
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
            pendingDetachCleanupWorkItem?.cancel()
        }

        @objc private func cancelGesturesForDeactivation() {
            // Reset both UIKit recognizers and our bookkeeping. A cancelled
            // gesture may have lost valid bounds before its final callback.
            for recognizer in [pinchGestureRecognizer, panGestureRecognizer, resetGestureRecognizer] {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
            activeGestureKinds.removeAll()
            playbackService?.clearInteractiveVideoGestureActivity(source: self)
        }

        func cancelGesturesForLayoutChange() {
            guard !activeGestureKinds.isEmpty else { return }
            cancelGesturesForDeactivation()
        }

        func attachIfNeeded(from view: UIView) {
            guard let target = resolvedTargetView(from: view) else { return }
            guard target !== targetView else { return }

            detach()
            target.addGestureRecognizer(pinchGestureRecognizer)
            target.addGestureRecognizer(panGestureRecognizer)
            target.addGestureRecognizer(resetGestureRecognizer)
            targetView = target
        }

        func detach() {
            pendingDetachCleanupWorkItem?.cancel()
            pendingDetachCleanupWorkItem = nil
            if let targetView {
                targetView.removeGestureRecognizer(pinchGestureRecognizer)
                targetView.removeGestureRecognizer(panGestureRecognizer)
                targetView.removeGestureRecognizer(resetGestureRecognizer)
            }
            targetView = nil
            activeGestureKinds.removeAll()
            let sourceID = ObjectIdentifier(self)
            if let playbackService {
                let workItem = DispatchWorkItem { [weak playbackService] in
                    playbackService?.clearInteractiveVideoGestureActivity(sourceID: sourceID)
                }
                pendingDetachCleanupWorkItem = workItem
                DispatchQueue.main.async(execute: workItem)
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let playbackService else { return false }
            guard playbackService.playerView != nil else { return false }
            if playbackService.isMenuPresented { return false }
            guard isGestureInsidePlayerContent(gestureRecognizer) else { return false }

            if gestureRecognizer === panGestureRecognizer {
                return hasPannableContent()
            }

            if gestureRecognizer === resetGestureRecognizer {
                return playbackService.state.interactiveVideoZoomScale > 1.0001 ||
                    abs(playbackService.state.interactiveVideoOffset.width) > 0.5 ||
                    abs(playbackService.state.interactiveVideoOffset.height) > 0.5
            }

            return true
        }

        @objc
        private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                setGestureActive(false, kind: "pinch")
            }
            guard let playbackService else { return }
            let containerBounds = currentContainerBounds()
            guard containerBounds.width > 1, containerBounds.height > 1 else { return }

            switch gesture.state {
            case .began:
                pinchInitialZoomScale = playbackService.state.interactiveVideoZoomScale
                pinchInitialOffset = playbackService.state.interactiveVideoOffset
                setGestureActive(true, kind: "pinch")

            case .changed:
                let baseScale = currentBaseScale(containerSize: containerBounds.size)
                let initialZoomScale = VLCPlaybackService.clampedInteractiveVideoZoomScale(pinchInitialZoomScale)
                let proposedZoomScale = VLCPlaybackService.clampedInteractiveVideoZoomScale(
                    initialZoomScale * gesture.scale
                )
                let initialTotalScale = max(baseScale * initialZoomScale, 0.0001)
                let totalScale = baseScale * proposedZoomScale
                let offsetScaleRatio = totalScale / initialTotalScale
                let proposedOffset = CGSize(
                    width: pinchInitialOffset.width * offsetScaleRatio,
                    height: pinchInitialOffset.height * offsetScaleRatio
                )
                let clampedOffset = clampedOffset(
                    proposedOffset,
                    containerBounds: containerBounds,
                    totalScale: totalScale
                )
                playbackService.updateInteractiveVideoTransform(
                    zoomScale: proposedZoomScale,
                    offset: clampedOffset
                )
                onZoomChanged?(proposedZoomScale)

            case .ended, .cancelled, .failed:
                finalizeInteractiveTransformIfNeeded()
                onZoomEnded?(playbackService.state.interactiveVideoZoomScale)

            default:
                break
            }
        }

        @objc
        private func handlePan(_ gesture: UIPanGestureRecognizer) {
            if gesture.state == .ended || gesture.state == .cancelled || gesture.state == .failed {
                setGestureActive(false, kind: "pan")
            }
            guard let playbackService else { return }
            let containerBounds = currentContainerBounds()
            guard containerBounds.width > 1, containerBounds.height > 1 else { return }

            switch gesture.state {
            case .began:
                panInitialOffset = playbackService.state.interactiveVideoOffset
                setGestureActive(true, kind: "pan")

            case .changed:
                let translation = gesture.translation(in: gesture.view)
                let proposedOffset = CGSize(
                    width: panInitialOffset.width + translation.x,
                    height: panInitialOffset.height + translation.y
                )
                let totalScale = currentTotalScale(containerSize: containerBounds.size)
                let clampedOffset = clampedOffset(
                    proposedOffset,
                    containerBounds: containerBounds,
                    totalScale: totalScale
                )
                playbackService.updateInteractiveVideoTransform(
                    zoomScale: playbackService.state.interactiveVideoZoomScale,
                    offset: clampedOffset
                )

            case .ended, .cancelled, .failed:
                finalizeInteractiveTransformIfNeeded()

            default:
                break
            }
        }

        @objc
        private func handleResetGesture(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended else { return }
            playbackService?.resetInteractiveVideoTransform()
            onReset?()
        }

        private func finalizeInteractiveTransformIfNeeded() {
            guard let playbackService else { return }

            let currentScale = VLCPlaybackService.clampedInteractiveVideoZoomScale(
                playbackService.state.interactiveVideoZoomScale
            )
            let currentOffset = playbackService.state.interactiveVideoOffset

            if playbackService.state.videoDisplayMode == .fit &&
                currentScale <= 1.0001 &&
                abs(currentOffset.width) <= 0.5 &&
                abs(currentOffset.height) <= 0.5 {
                playbackService.resetInteractiveVideoTransform()
            }
        }

        private func setGestureActive(_ isActive: Bool, kind: String) {
            if isActive {
                pendingDetachCleanupWorkItem?.cancel()
                pendingDetachCleanupWorkItem = nil
            }
            if isActive {
                activeGestureKinds.insert(kind)
            } else {
                activeGestureKinds.remove(kind)
            }
            playbackService?.setInteractiveVideoGestureActive(
                !activeGestureKinds.isEmpty,
                sourceID: ObjectIdentifier(self)
            )
        }

        private func resolvedTargetView(from view: UIView) -> UIView? {
            if let window = view.window {
                return window
            }
            var candidate = view.superview
            while let current = candidate {
                if current.bounds.width > 1, current.bounds.height > 1 {
                    return current
                }
                candidate = current.superview
            }
            return view.superview
        }

        private func currentContainerBounds() -> CGRect {
            if let containerView = playbackService?.playerView?.superview {
                return containerView.bounds.integral
            }
            return targetView?.bounds.integral ?? .zero
        }

        private func isGestureInsidePlayerContent(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let targetView,
                  let containerView = playbackService?.playerView?.superview else {
                return false
            }

            let location = gestureRecognizer.location(in: targetView)
            let containerFrame = containerView.convert(containerView.bounds, to: targetView)
            return containerFrame.insetBy(dx: -8, dy: -8).contains(location)
        }

        private func currentFitRect(containerSize: CGSize) -> CGRect {
            guard let playbackService else { return .zero }
            return VLCPlaybackService.visibleVideoRect(
                containerSize: containerSize,
                naturalVideoSize: playbackService.videoNaturalSize,
                aspectRatioOverride: playbackService.state.aspectRatio,
                displayMode: .fit
            )
        }

        private func currentBaseScale(containerSize: CGSize) -> CGFloat {
            guard let playbackService else { return 1.0 }
            return VLCPlaybackService.interactiveVideoBaseScale(
                containerSize: containerSize,
                naturalVideoSize: playbackService.videoNaturalSize,
                aspectRatioOverride: playbackService.state.aspectRatio,
                displayMode: playbackService.state.videoDisplayMode
            )
        }

        private func currentTotalScale(containerSize: CGSize) -> CGFloat {
            let baseScale = currentBaseScale(containerSize: containerSize)
            let userScale = VLCPlaybackService.clampedInteractiveVideoZoomScale(
                playbackService?.state.interactiveVideoZoomScale ?? 1.0
            )
            return baseScale * userScale
        }

        private func clampedOffset(
            _ proposedOffset: CGSize,
            containerBounds: CGRect,
            totalScale: CGFloat
        ) -> CGSize {
            VLCPlaybackService.clampedInteractiveVideoOffset(
                containerBounds: containerBounds,
                baseVideoRect: currentFitRect(containerSize: containerBounds.size),
                totalScale: totalScale,
                proposedOffset: proposedOffset
            )
        }

        private func hasPannableContent() -> Bool {
            let containerBounds = currentContainerBounds()
            guard containerBounds.width > 1, containerBounds.height > 1 else { return false }
            let transformedRect = VLCPlaybackService.transformedVideoRect(
                baseVideoRect: currentFitRect(containerSize: containerBounds.size),
                containerBounds: containerBounds,
                totalScale: currentTotalScale(containerSize: containerBounds.size),
                offset: .zero
            )
            return transformedRect.width > containerBounds.width + 1 ||
                transformedRect.height > containerBounds.height + 1
        }
    }
}
