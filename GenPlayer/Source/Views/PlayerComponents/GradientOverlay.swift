import SwiftUI

struct GradientOverlay: View {
    let position: VerticalAlignment // .top or .bottom
    
    var body: some View {
        LinearGradient(
            gradient: Gradient(colors: [.black.opacity(0.8), .clear]),
            startPoint: position == .top ? .top : .bottom,
            endPoint: position == .top ? .bottom : .top
        )
            .allowsHitTesting(false)
    }
}
