import SwiftUI
#if os(iOS)
import UIKit
#endif

struct SeekPreviewOverlay: View {
    let image: UIImage?
    let showsLoadingIndicator: Bool
    let targetTimeText: String
    let deltaIcon: String
    let deltaText: String

    private let previewSize = CGSize(width: 176, height: 100)
    private var hasPreviewImage: Bool { image != nil }

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))

                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.08),
                            Color.white.opacity(0.03),
                            Color.black.opacity(0.24)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }

                if showsLoadingIndicator {
                    ZStack {
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color.black.opacity(image == nil ? 0.16 : 0.18),
                                Color.black.opacity(image == nil ? 0.28 : 0.34)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )

                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.92)))
                            .scaleEffect(0.9)
                    }
                }
            }
            .frame(width: previewSize.width, height: previewSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
            )

            VStack(spacing: 4) {
                Text(targetTimeText)
                    .font(.system(size: 18, weight: .semibold, design: .monospaced))

                HStack(spacing: 6) {
                    Image(systemName: deltaIcon)
                        .font(.system(size: 12, weight: .semibold))

                    Text(deltaText)
                        .font(.system(.subheadline, design: .rounded).weight(.medium))
                }
                .foregroundColor(.white.opacity(0.88))
            }
        }
        .padding(.horizontal, hasPreviewImage ? 16 : 18)
        .padding(.vertical, hasPreviewImage ? 14 : 12)
        .background(
            VisualEffectView(effect: UIBlurEffect(style: .systemThinMaterialDark))
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
        )
        .foregroundColor(.white)
        .shadow(color: .black.opacity(0.22), radius: 10, x: 0, y: 5)
    }
}
