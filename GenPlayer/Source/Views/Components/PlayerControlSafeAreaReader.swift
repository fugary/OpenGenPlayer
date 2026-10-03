import SwiftUI
import UIKit

// iOS 27.1 SDK ships SwiftUI 8.0.85.27. Xcode 27.0 uses the same Swift
// compiler, so gate these SDK-only APIs by module version as well as runtime OS.
#if canImport(SwiftUI, _version: 8.0.85.27)
/// Used only for custom controls inside the full-screen video player, which has
/// no native navigation or tab bar. Do not use to bypass a library's toolbar.
@available(iOS 27.1, *)
struct PlayerControlSafeAreaReader: UIViewRepresentable {
    var onChange: (UIEdgeInsets?) -> Void

    func makeUIView(context: Context) -> PlayerControlSafeAreaObservingView {
        let view = PlayerControlSafeAreaObservingView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: PlayerControlSafeAreaObservingView, context: Context) {
        uiView.onChange = onChange
        uiView.scheduleReport()
    }
}

@available(iOS 27.1, *)
final class PlayerControlSafeAreaObservingView: UIView {
    var onChange: ((UIEdgeInsets?) -> Void)?
    private var reportPending = false
    private var hasReported = false
    private var lastInsets: UIEdgeInsets?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForTraitChanges(UITraitCollection.systemTraitsAffectingVerticalBarEdge) {
            (view: PlayerControlSafeAreaObservingView, _: UITraitCollection) in
            view.scheduleReport()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        scheduleReport()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        scheduleReport()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        scheduleReport()
    }

    func scheduleReport() {
        guard !reportPending else { return }
        reportPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reportPending = false
            let insets = self.controlInsets()
            guard !self.hasReported || self.lastInsets != insets else { return }
            self.hasReported = true
            self.lastInsets = insets
            self.onChange?(insets)
        }
    }

    private func controlInsets() -> UIEdgeInsets? {
        guard let window, let scene = window.windowScene,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let isLeftToRight = effectiveUserInterfaceLayoutDirection == .leftToRight
        let sidebarOnLeft: Bool
        switch traitCollection.verticalBarEdge {
        case .leading: sidebarOnLeft = isLeftToRight
        case .trailing: sidebarOnLeft = !isLeftToRight
        default: return nil
        }

        // Reserved-region frames already include their interactive margins.
        var obstructions = window.reservedRegions(kind: .occlusion).map(\.frame)
        if let statusFrame = scene.statusBarManager?.statusBarFrame, !statusFrame.isEmpty {
            obstructions.append(window.convert(statusFrame, from: scene.coordinateSpace).insetBy(dx: -8, dy: -8))
        }
        let result = AdaptiveMediaLayout.controlHorizontalInsets(
            controlFrame: convert(bounds, to: window),
            left: window.safeAreaInsets.left,
            right: window.safeAreaInsets.right,
            sidebarOnLeft: sidebarOnLeft,
            obstructions: obstructions,
            hasActiveDivision: !window.reservedRegions(kind: .division).isEmpty
        )
        return UIEdgeInsets(top: 0, left: result.left, bottom: 0, right: result.right)
    }
}

#endif

extension View {
    @ViewBuilder
    func onPlayerControlSafeAreaChange(_ action: @escaping (UIEdgeInsets?) -> Void) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85.27)
        if #available(iOS 27.1, *) {
            background(PlayerControlSafeAreaReader(onChange: action).allowsHitTesting(false))
        } else {
            self
        }
        #else
        self
        #endif
    }
}
