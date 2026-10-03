#if os(macOS)
import SwiftUI

/// A single native button keeps this status strip reachable without multiplying
/// controls. Only the reported HDR render target receives the accent color.
struct MacHDRStatusBadges: View {
    let info: MPVHDRInfo
    let compact: Bool
    let showInfo: () -> Void
    @State private var isHovering = false

    private var status: String {
        info.hasHDRTarget ? platformShellString("HDR.Badge.Target")
            : (info.hasSDRTarget ? "HDR → SDR" : platformShellString("HDR.Badge.Source"))
    }

    var body: some View {
        Button(action: showInfo) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: info.hasHDRTarget ? "sun.max.fill" : "sun.max")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(info.hasHDRTarget ? Color.cyan.opacity(0.9) : Color.white.opacity(0.5))
                    Text(info.hasHDRTarget ? "HDR" : status)
                        .foregroundColor(.white.opacity(info.hasHDRTarget ? 0.9 : 0.65))
                        .lineLimit(1)
                }
                .font(.system(size: 10, weight: .semibold))
                .padding(.vertical, 4)
                if !compact {
                    Text(info.technicalBadges.joined(separator: "  ·  "))
                        .font(.system(size: 10, weight: .medium, design: .default))
                        .foregroundColor(.white.opacity(0.65))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .opacity(isHovering ? 1 : 0.9)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(status + "\n" + platformShellString("HDR.Badge.Help"))
        .accessibilityLabel(status + ", " + info.technicalBadges.joined(separator: ", "))
        .accessibilityHint(platformShellString("HDR.Badge.Help"))
    }
}
#endif
