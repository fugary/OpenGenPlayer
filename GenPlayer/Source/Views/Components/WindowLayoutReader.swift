import SwiftUI
import UIKit

struct WindowLayoutMetrics: Equatable {
    var size: CGSize = .zero
    var safeAreaInsets: UIEdgeInsets = .zero
}

/// Read the window hosting this view, including when it moves between displays.
/// Never select a different scene through UIApplication's global key window.
struct WindowLayoutReader: UIViewRepresentable {
    var onChange: (WindowLayoutMetrics) -> Void

    func makeUIView(context: Context) -> WindowLayoutObservingView {
        let view = WindowLayoutObservingView()
        view.isUserInteractionEnabled = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: WindowLayoutObservingView, context: Context) {
        uiView.onChange = onChange
        uiView.scheduleReport()
    }
}

final class WindowLayoutObservingView: UIView {
    var onChange: ((WindowLayoutMetrics) -> Void)?
    private var lastMetrics: WindowLayoutMetrics?
    private var reportPending = false

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
        // Coalesce layout callbacks and publish outside SwiftUI's update pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.reportPending = false
            guard let window = self.window, window.bounds.width > 0, window.bounds.height > 0 else { return }
            let metrics = WindowLayoutMetrics(size: window.bounds.size, safeAreaInsets: window.safeAreaInsets)
            guard metrics != self.lastMetrics else { return }
            self.lastMetrics = metrics
            self.onChange?(metrics)
        }
    }
}

/// Restore only the horizontal safe area intentionally ignored by a full-bleed
/// library page. The carousel/backdrop stays outside this padded content.
private struct MediaLibraryHorizontalSafeAreaPadding: ViewModifier {
    var isEnabled: Bool
    var underlappingToolbarEdge: HorizontalEdge? = nil
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var windowLayout = WindowLayoutMetrics()

    func body(content: Content) -> some View {
        let insets = isEnabled ? windowLayout.safeAreaInsets : .zero
        let isLeftToRight = layoutDirection == .leftToRight
        let horizontalInsets = EdgeInsets(
            top: 0,
            leading: isLeftToRight ? insets.left : insets.right,
            bottom: 0,
            trailing: isLeftToRight ? insets.right : insets.left
        )
        let restoredInsets = EdgeInsets(
            top: 0,
            leading: underlappingToolbarEdge == .leading ? 0 : horizontalInsets.leading,
            bottom: 0,
            trailing: underlappingToolbarEdge == .trailing ? 0 : horizontalInsets.trailing
        )
        content
            .environment(\.mediaLibraryRestoredInsets, restoredInsets)
            .environment(\.mediaLibraryScrollInsets, horizontalInsets)
            .padding(restoredInsets)
            .background(WindowLayoutReader { windowLayout = $0 })
    }
}

private struct MediaLibraryRestoredInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

private struct MediaLibraryScrollInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

private extension EnvironmentValues {
    var mediaLibraryRestoredInsets: EdgeInsets {
        get { self[MediaLibraryRestoredInsetsKey.self] }
        set { self[MediaLibraryRestoredInsetsKey.self] = newValue }
    }

    var mediaLibraryScrollInsets: EdgeInsets {
        get { self[MediaLibraryScrollInsetsKey.self] }
        set { self[MediaLibraryScrollInsetsKey.self] = newValue }
    }
}

// iOS 27.1 SDK ships SwiftUI 8.0.85.27. Xcode 27.0 uses the same Swift
// compiler, so gate these SDK-only APIs by module version as well as runtime OS.
#if canImport(SwiftUI, _version: 8.0.85.27)
@available(iOS 27.1, *)
private struct DuoMediaDetailHorizontalSafeAreaPadding: ViewModifier {
    var usesWideLayout: Bool
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    func body(content: Content) -> some View {
        // The compact hero is centered above its full-width body. Keep the
        // native toolbar floating over that canvas rather than reserving an
        // empty strip for the entire page. Wide heroes and iPad retain padding.
        let usesCompactPhoneLayout = UIDevice.current.userInterfaceIdiom == .phone
            && horizontalSizeClass == .compact
            && !usesWideLayout
        content.modifier(MediaLibraryHorizontalSafeAreaPadding(
            isEnabled: true,
            underlappingToolbarEdge: usesCompactPhoneLayout ? verticalEdge : nil
        ))
    }
}

@available(iOS 27.1, *)
private struct DuoMediaShelfViewport: ViewModifier {
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @Environment(\.mediaLibraryRestoredInsets) private var restoredInsets
    @Environment(\.mediaLibraryScrollInsets) private var scrollInsets

    func body(content: Content) -> some View {
        if verticalEdge != nil {
            // Expand the scroll view itself, including its hit area. Keep its
            // resting content inside the safe area without clipping the overflow
            // at that inset. A full-width detail body has no sidebar padding to
            // undo, but its last card must still scroll clear of the toolbar.
            content
                .contentMargins(.leading, scrollInsets.leading, for: .scrollContent)
                .contentMargins(.trailing, scrollInsets.trailing, for: .scrollContent)
                .padding(.leading, -restoredInsets.leading)
                .padding(.trailing, -restoredInsets.trailing)
        } else {
            content
        }
    }
}

#endif

extension View {
    @ViewBuilder
    func mediaDetailHorizontalSafeAreaPadding(usesWideLayout: Bool = false) -> some View {
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85.27)
        if #available(iOS 27.1, *) {
            modifier(DuoMediaDetailHorizontalSafeAreaPadding(usesWideLayout: usesWideLayout))
        } else {
            mediaLibraryHorizontalSafeAreaPadding()
        }
        #else
        mediaLibraryHorizontalSafeAreaPadding()
        #endif
    }

    @ViewBuilder
    func duoMediaShelfViewport() -> some View {
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85.27)
        if #available(iOS 27.1, *) {
            modifier(DuoMediaShelfViewport())
        } else {
            self
        }
        #else
        self
        #endif
    }

    func mediaLibraryHorizontalSafeAreaPadding(isEnabled: Bool = true) -> some View {
        #if os(iOS)
        modifier(MediaLibraryHorizontalSafeAreaPadding(isEnabled: isEnabled))
        #else
        self
        #endif
    }
}

#if canImport(SwiftUI, _version: 8.0.85.27)
@available(iOS 27.1, *)
private struct DuoLibraryHorizontalMargins: ViewModifier {
    let legacyPadding: CGFloat
    let minimumPadding: CGFloat
    @Environment(\.toolbarVerticalEdge) private var verticalEdge
    @Environment(\.layoutDirection) private var layoutDirection
    @State private var windowLayout = WindowLayoutMetrics()

    func body(content: Content) -> some View {
        let insets = windowLayout.safeAreaInsets
        let leadingInset = layoutDirection == .leftToRight ? insets.left : insets.right
        let trailingInset = layoutDirection == .leftToRight ? insets.right : insets.left
        content
            .padding(.leading, verticalEdge == nil ? legacyPadding : max(minimumPadding, leadingInset))
            .padding(.trailing, verticalEdge == nil ? legacyPadding : max(minimumPadding, trailingInset))
            .background(WindowLayoutReader { windowLayout = $0 })
    }
}

#endif

extension View {
    @ViewBuilder
    func duoLibraryHorizontalMargins(legacyPadding: CGFloat, minimumPadding: CGFloat) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85.27)
        if #available(iOS 27.1, *) {
            modifier(DuoLibraryHorizontalMargins(legacyPadding: legacyPadding, minimumPadding: minimumPadding))
        } else {
            padding(.horizontal, legacyPadding)
        }
        #else
        padding(.horizontal, legacyPadding)
        #endif
    }
}
