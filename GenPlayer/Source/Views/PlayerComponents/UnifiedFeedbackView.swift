import SwiftUI

struct UnifiedFeedbackView: View {
    let icon: String
    let text: String
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
            
            if !text.isEmpty {
                Text(text)
                    .font(.system(.subheadline, design: .rounded).weight(.medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            VisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        )
        .clipShape(Capsule())
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.15), radius: 5, x: 0, y: 3)
    }
}
