import SwiftUI

#if os(iOS)
public struct PlayerLiveTextViewer: View {
    public let image: UIImage
    public let onDismiss: () -> Void

    @State private var isAnalyzing: Bool = true

    public init(image: UIImage, onDismiss: @escaping () -> Void) {
        self.image = image
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.black
                .ignoresSafeArea()

            LiveTextInteractionView(image: image, isAnalyzing: $isAnalyzing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            HStack(alignment: .center, spacing: 12) {
                Spacer()
                    .frame(width: 44)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 13, weight: .semibold))
                    if isAnalyzing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.7)
                        Text(platformShellString("Analyzing Text..."))
                            .font(.system(size: 13, weight: .medium))
                    } else {
                        Text(platformShellString("Live Text"))
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.65))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )

                Spacer()

                Button(action: {
                    onDismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .frame(width: 44, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .zIndex(10)
        }
    }
}
#elseif os(macOS)
public struct PlayerLiveTextViewer: View {
    public let image: NSImage
    public let onDismiss: () -> Void

    @State private var isAnalyzing: Bool = true

    public init(image: NSImage, onDismiss: @escaping () -> Void) {
        self.image = image
        self.onDismiss = onDismiss
    }

    public var body: some View {
        ZStack(alignment: .top) {
            Color.black
                .ignoresSafeArea()

            LiveTextInteractionView(image: image, isAnalyzing: $isAnalyzing)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()

            HStack(alignment: .center, spacing: 12) {
                Spacer()
                    .frame(width: 54)

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: "text.viewfinder")
                        .font(.system(size: 13, weight: .semibold))
                    if isAnalyzing {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.7)
                        Text(platformShellString("Analyzing Text..."))
                            .font(.system(size: 13, weight: .medium))
                    } else {
                        Text(platformShellString("Live Text"))
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule()
                        .fill(Color.black.opacity(0.65))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                )

                Spacer()

                Button(action: {
                    onDismiss()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundColor(.white.opacity(0.85))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
                .macPointerHover()
                .frame(width: 54, alignment: .trailing)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .zIndex(10)
        }
    }
}

#elseif os(tvOS)
public struct PlayerLiveTextViewer: View {
    public init(onDismiss: @escaping () -> Void) {}
    public var body: some View {
        EmptyView()
    }
}
#endif
