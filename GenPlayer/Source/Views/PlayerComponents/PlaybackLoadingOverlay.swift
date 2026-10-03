import SwiftUI

struct PlaybackLoadingOverlay: View {
    let phase: PlaybackLoadingMonitor.Phase
    let onContinueWaiting: () -> Void
    let onRetry: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 10) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                Text(NSLocalizedString(
                    phase == .loading ? "Loading..." : "Loading is taking longer than usual…",
                    comment: ""
                ))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundColor(.white)
            }
            if phase == .waitingForChoice {
                VStack(spacing: 12) {
                    Button(action: onContinueWaiting) {
                        Text(NSLocalizedString("Continue Waiting", comment: ""))
                    }
                    HStack(spacing: 28) {
                        Button(action: onRetry) { Text(NSLocalizedString("Retry", comment: "")) }
                        Button(action: onClose) { Text(NSLocalizedString("Close", comment: "")) }
                    }
                }
                .buttonStyle(.bordered)
                .tint(.white)
            }
        }
        .padding(20)
        .frame(maxWidth: 340)
        .background(Color.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 24)
        .allowsHitTesting(phase == .waitingForChoice)
    }
}
