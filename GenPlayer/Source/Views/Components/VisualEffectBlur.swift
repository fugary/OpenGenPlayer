import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

#if os(iOS)
struct VisualEffectBlur: UIViewRepresentable {
    var blurStyle: UIBlurEffect.Style
    
    func makeUIView(context: Context) -> UIVisualEffectView {
        return UIVisualEffectView(effect: UIBlurEffect(style: blurStyle))
    }
    
    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {
        uiView.effect = UIBlurEffect(style: blurStyle)
    }
}
#else
struct VisualEffectBlur: View {
    // A placeholder for macOS if it is instantiated with an iOS blurStyle type in cross-platform code
    // However, if the calling code uses UIBlurEffect.Style, we can't compile. 
    // Wait, if calling code uses UIBlurEffect.Style, we must avoid it or typealias it.
    var body: some View {
        Color.black.opacity(0.5)
    }
}
#endif
