#if os(macOS)
import SwiftUI
import GenPlayerCore


struct MacPlayerRightSidebar: View {
    @Binding var activeTab: MacPlayerSheet.RightSidebarTab
    let file: VideoFile
    @ObservedObject var playbackService: MacVLCPlaybackService
    @Binding var videoAspectRatio: String
    let thumbnailURL: URL?
    let currentPlaylist: [VideoFile]?
    let playbackServer: ServerConfig?
    let onSwitchPlayback: (VideoFile) -> Void
    var onAction: ((String, String) -> Void)? = nil
    let onClose: () -> Void

    private var visibleTabs: [MacPlayerSheet.RightSidebarTab] {
        MacPlayerSheet.RightSidebarTab.allCases.filter { tab in
            if file.type == .audio {
                return tab == .audio || tab == .info
            }
            return tab != .playlist && tab != .epg && tab != .sources && tab != .subtitleBrowser
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with tab bar and close button
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    ForEach(visibleTabs) { tab in
                        tabButton(tab)
                    }
                    
                    Spacer(minLength: 4)
                    
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                
                // Separator
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 1)
            }
            
            // Tab Content
            switch activeTab {
            case .video, .audio, .subtitle:
                MacPlayerInspector(
                    file: file,
                    playbackService: playbackService,
                    activeTab: activeTab,
                    videoAspectRatio: $videoAspectRatio,
                    onSwitchPlayback: onSwitchPlayback,
                    onAction: onAction,
                    onClose: onClose
                )
            case .info:
                MacPlayerInfoSidebar(file: file, playbackService: playbackService, thumbnailURL: thumbnailURL, playbackServer: playbackServer, currentPlaylist: currentPlaylist, onClose: onClose)
            case .playlist, .epg, .sources, .subtitleBrowser:
                EmptyView()
            }
        }
        .background(
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                Rectangle()
                    .fill(Color.black.opacity(0.55))
            }
        )
        .shadow(color: .black.opacity(0.35), radius: 12, x: -2, y: 0)
        .ignoresSafeArea()
    }

    @ViewBuilder
    private func tabButton(_ tab: MacPlayerSheet.RightSidebarTab) -> some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.15)) {
                activeTab = tab
            }
        }) {
            Text(platformShellString(tab.rawValue))
                .font(.system(size: 12, weight: activeTab == tab ? .semibold : .regular))
                .foregroundColor(activeTab == tab ? .white : .white.opacity(0.5))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    activeTab == tab
                        ? RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.15))
                        : RoundedRectangle(cornerRadius: 6).fill(Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#endif
