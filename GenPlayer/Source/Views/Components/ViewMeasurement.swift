import SwiftUI

private struct ViewWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 {
            value = next
        }
    }
}

private struct ViewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

extension View {
    func onHeightChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geometry in
                Color.clear.preference(key: ViewHeightPreferenceKey.self, value: geometry.size.height)
            }
        )
        .onPreferenceChange(ViewHeightPreferenceKey.self, perform: action)
    }

    func onWidthChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        self.background(
            GeometryReader { geometry in
                Color.clear
                    .preference(key: ViewWidthPreferenceKey.self, value: geometry.size.width)
            }
        )
        .onPreferenceChange(ViewWidthPreferenceKey.self, perform: action)
    }
}

// iOS 27.1 SDK ships SwiftUI 8.0.85.27. Xcode 27.0 uses the same Swift
// compiler, so gate these SDK-only APIs by module version as well as runtime OS.
#if canImport(SwiftUI, _version: 8.0.85.27)
@available(iOS 27.1, *)
private struct DuoFileGridDropTargetFrame: ViewModifier {
    let viewportHeight: CGFloat
    @Environment(\.toolbarVerticalEdge) private var verticalEdge

    func body(content: Content) -> some View {
        content.frame(
            maxWidth: .infinity,
            minHeight: verticalEdge != nil && viewportHeight > 0 ? viewportHeight : UIScreen.main.bounds.height
        )
    }
}

#endif

extension View {
    @ViewBuilder
    func fileGridDropTargetFrame(viewportHeight: CGFloat) -> some View {
        #if canImport(SwiftUI, _version: 8.0.85.27)
        if #available(iOS 27.1, *) {
            modifier(DuoFileGridDropTargetFrame(viewportHeight: viewportHeight))
        } else {
            frame(maxWidth: .infinity, minHeight: UIScreen.main.bounds.height)
        }
        #else
        frame(maxWidth: .infinity, minHeight: UIScreen.main.bounds.height)
        #endif
    }
}
