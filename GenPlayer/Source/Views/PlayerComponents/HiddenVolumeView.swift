import SwiftUI
import MediaPlayer

/// A hidden wrapper around MPVolumeView used solely to suppress the native iOS volume HUD.
/// When an MPVolumeView is present in the active view hierarchy, iOS assumes the app is
/// handling volume UI customly and hides its own system-wide volume banner.
struct HiddenVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        // Setting alpha to a very small non-zero value keeps it active but invisible.
        view.alpha = 0.001
        view.isHidden = false
        view.clipsToBounds = true
        return view
    }
    
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
