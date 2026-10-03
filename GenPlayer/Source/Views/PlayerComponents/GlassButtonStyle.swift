import SwiftUI

struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .font(.system(size: 16)) // Slightly smaller icon
            .frame(width: 38, height: 38) // Reduced bulk
            .background(
                VisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
                    .opacity(0.8)
                    .clipShape(Circle())
            )
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}

/// A lightweight style for top/bottom bar buttons that removes the blurry background
/// but keeps a large invisible hit target (44x44) to ensure easy tapping.
struct OverlayButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(.white)
            .font(.system(size: 20)) // Standard elegant icon size
            .frame(width: 44, height: 44) // Generous invisible hit target
            .contentShape(Rectangle()) // Ensure the whole 44x44 area is tappable
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1) // Shadow for readability on white backgrounds
    }
}

struct CircleCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if #available(iOS 15.0, *) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Circle().fill(Color(UIColor.lightGray).opacity(0.4)))
            } else {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .padding(8)
                    .background(Circle().fill(Color(UIColor.lightGray).opacity(0.4)))
            }
        }
        .buttonStyle(CircleCloseButtonStyle()) // Apply a custom button style if needed for press effects
    }
}

struct CircleCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}
