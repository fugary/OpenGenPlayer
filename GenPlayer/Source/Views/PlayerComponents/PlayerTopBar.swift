import SwiftUI
import GenPlayerShell

struct PlayerTopBar: View {
    @ObservedObject var playbackService: VLCPlaybackService
    @Binding var isLocked: Bool
    @Binding var showPlaylist: Bool
    var hasPlaylist: Bool = false
    var isLiveStream: Bool = false
    var showsDownloadedIconBeforeTitle: Bool = false
    var horizontalPadding: CGFloat = 16
    var verticalPadding: CGFloat = 0
    var trailingControlSpacing: CGFloat = 14
    var horizontalCompensation: CGFloat = 0
    var onDismiss: () -> Void
    var onShowProgramGuide: (() -> Void)? = nil
    var onAction: ((String, String) -> Void)?
    var onLiveTextRequested: (() -> Void)? = nil
    var onShowInfo: (() -> Void)? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controlsRow

            if !isLocked, let info = playbackService.currentHDRInfo {
                hdrStatus(info)
                    .padding(.leading, 54)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, -horizontalCompensation)
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            if !isLocked {
                HStack(spacing: 10) {
                    Button(action: onDismiss) {
                        Image(systemName: "chevron.backward")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            if showsDownloadedIconBeforeTitle {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.green)
                            }

                            Text(playbackService.state.currentItem?.title ?? "")
                                .font(.system(.headline, design: .rounded))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: trailingControlSpacing) {
                    Button(action: {
                        playbackService.toggleMute()
                        onAction?(
                            playbackService.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            playbackService.isMuted
                                ? NSLocalizedString("Muted", comment: "")
                                : NSLocalizedString("Unmuted", comment: "")
                        )
                    }) {
                        Image(systemName: playbackService.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(OverlayButtonStyle())

                    if LiveTextCapability.isSupported {
                        Button(action: {
                            onLiveTextRequested?()
                        }) {
                            Image(systemName: "text.viewfinder")
                                .font(.system(size: 18, weight: .medium))
                        }
                        .buttonStyle(OverlayButtonStyle())
                    }
                    
                    Button(action: {
                        _ = playbackService.startPictureInPicture(userInitiated: true)
                    }) {
                        Image(systemName: "pip.enter")
                            // `pip.enter` looks optically taller than the neighboring SF Symbols.
                            // Nudge it slightly so the three trailing actions read as one straight row.
                            .font(.system(size: 18, weight: .medium))
                            .offset(y: 0.5)
                    }
                    .buttonStyle(OverlayButtonStyle())

                    if isLiveStream && onShowProgramGuide != nil {
                        Button(action: { onShowProgramGuide?() }) {
                            Image(systemName: "list.bullet.rectangle")
                        }
                        .buttonStyle(OverlayButtonStyle())
                    }

                    if hasPlaylist {
                        Button(action: { showPlaylist.toggle() }) {
                            Image(systemName: "list.bullet")
                        }
                        .buttonStyle(OverlayButtonStyle())
                    }
                }
            }
        }
        .frame(minHeight: 44)
    }

    private func hdrStatus(_ info: MPVHDRInfo) -> some View {
        let status = info.hasHDRTarget ? NSLocalizedString("HDR.Badge.Target", comment: "")
            : (info.hasSDRTarget ? "HDR → SDR" : NSLocalizedString("HDR.Badge.Source", comment: ""))
        return Button(action: { onShowInfo?() }) {
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: info.hasHDRTarget ? "sun.max.fill" : "sun.max")
                        .foregroundColor(info.hasHDRTarget ? Color(UIColor.systemCyan) : Color.white.opacity(0.5))
                    Text(info.hasHDRTarget ? "HDR" : status)
                        .foregroundColor(.white.opacity(info.hasHDRTarget ? 0.9 : 0.65))
                }
                .font(.system(size: 11, weight: .semibold))
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                Text(info.technicalBadges.joined(separator: " · "))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.65))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(status + ", " + info.technicalBadges.joined(separator: ", "))
        .accessibilityHint(NSLocalizedString("HDR.Badge.Help", comment: ""))
    }

}
