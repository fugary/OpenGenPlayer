#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


struct TVMediaDetailView: View {
    let file: VideoFile

    @ObservedObject private var historyService = HistoryService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var networkService = AppNetworkService.shared
    private let playbackCoordinator = TVPlaybackCoordinator.shared

    private var displayTitle: String {
        tvDisplayTitle(for: file)
    }

    private var resolvedServer: ServerConfig? {
        file.tvResolvedServer(from: networkService.servers)
    }

    private var playbackProgress: PlaybackProgressSnapshot? {
        historyService.playbackProgressSnapshot(matching: file)
    }

    private var downloadedCopy: VideoFile? {
        downloadCenter.localPlaybackFile(for: file)
    }

    private var playableFile: VideoFile? {
        tvPlayableFile(from: file, downloadCenter: downloadCenter)
    }

    private var localFolderURL: URL? {
        guard tvShouldUseLocalFolderBrowser(for: file, intent: .revealParent) else { return nil }
        return tvLocalFolderNavigationURL(for: file, intent: .revealParent)
    }

    private var localFolderTargetURL: URL? {
        guard tvShouldUseLocalFolderBrowser(for: file, intent: .revealParent) else { return nil }
        return tvLocalFolderTargetFileURL(for: file, intent: .revealParent)
    }

    var body: some View {
        TVPageScrollView(
            title: displayTitle,
            subtitle: nil,
            handlesExitCommand: true
        ) {
            TVFileHeroPanel(
                file: file,
                displayTitle: displayTitle,
                resolvedServer: resolvedServer,
                playbackProgress: playbackProgress,
                downloadedCopy: downloadedCopy,
                playableFile: playableFile,
                onPlay: { file in
                    playbackCoordinator.play(file: file)
                }
            )

            if let downloadedCopy, downloadedCopy.url != file.url {
                NavigationLink(destination: TVMediaDetailView(file: downloadedCopy)) {
                    TVActionCard(
                        title: platformShellString("Downloaded Copy Available"),
                        subtitle: tvDisplayTitle(for: downloadedCopy),
                        systemImageName: "arrow.down.circle.fill",
                        iconTint: Color(red: 0.42, green: 0.88, blue: 0.58)
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

            if let localFolderURL {
                NavigationLink(
                    destination: TVLocalBrowserView(
                        url: localFolderURL,
                        rootTitle: platformShellString("Local"),
                        targetFileURL: localFolderTargetURL
                    )
                ) {
                    TVActionCard(
                        title: platformShellString("Show in Folder"),
                        subtitle: tvDisplayName(for: localFolderURL),
                        systemImageName: "folder"
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

            if let server = resolvedServer {
                NavigationLink(destination: tvServerHomeDestination(for: server)) {
                    TVActionCard(
                        title: server.name,
                        subtitle: server.fullURL,
                        systemImageName: server.type.systemIconName
                    )
                }
                .buttonStyle(TVPlainButtonStyle())
                .tvDisableSystemFocusEffect()
            }

            if let server = resolvedServer,
               !server.type.tvSupportsFileBrowsing,
               file.isRemote {
                TVEmptyStateCard(
                    title: platformShellString("Platform Shell TV Library Server Title"),
                    message: platformShellString("Platform Shell TV Library Server Body"),
                    systemImageName: server.type.systemIconName
                )
            }
        }
        .navigationTitle(Text(displayTitle))
    }
}



struct TVFileHeroPanel: View {
    let file: VideoFile
    let displayTitle: String
    let resolvedServer: ServerConfig?
    let playbackProgress: PlaybackProgressSnapshot?
    let downloadedCopy: VideoFile?
    let playableFile: VideoFile?
    let onPlay: (VideoFile) -> Void

    private var metadataLine: String {
        var tokens: [String] = []
        if file.size > 0 {
            tokens.append(tvByteCountString(file.size))
        }
        if let duration = file.tvDurationText {
            tokens.append(duration)
        }
        if let format = file.tvFormatBadgeText {
            tokens.append(format)
        }
        tokens.append(tvTimestamp(file.date))
        return tokens.joined(separator: " • ")
    }

    private var primaryButtonProgress: Double? {
        guard let playbackProgress,
              !playbackProgress.isFinished,
              playbackProgress.displayedProgress > 0.01 else {
            return nil
        }
        return min(max(playbackProgress.displayedProgress, 0), 1)
    }

    private var primaryButtonTitle: String {
        primaryButtonProgress == nil
            ? platformShellString("Play")
            : platformShellString("Continue")
    }

    var body: some View {
        ZStack(alignment: .leading) {
            LinearGradient(
                gradient: Gradient(colors: [
                    file.tvFileIconColor.opacity(0.38),
                    Color(red: 0.08, green: 0.09, blue: 0.09).opacity(0.95),
                    Color.black
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Image(systemName: file.tvDecorativeSymbolName)
                .font(.system(size: 280, weight: .regular))
                .foregroundColor(.white.opacity(0.08))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 110)

            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.58),
                    Color.clear
                ]),
                startPoint: .leading,
                endPoint: .trailing
            )

            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: file.type.tvSystemImageName)
                        .font(.title2.weight(.semibold))
                    Text(resolvedServer?.name ?? (file.isRemote ? platformShellString("Network") : platformShellString("Local")))
                        .font(.title3.weight(.semibold))
                }
                .foregroundColor(.white.opacity(0.78))

                Text(displayTitle)
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.62)
                    .frame(maxWidth: 860, alignment: .leading)

                Text(metadataLine)
                    .font(.title3.weight(.medium))
                    .foregroundColor(.white.opacity(0.68))
                    .lineLimit(2)

                if let playbackProgress {
                    HStack(spacing: 12) {
                        TVMediaPlaybackProgressBadge(
                            progress: playbackProgress.displayedProgress,
                            systemImageName: file.tvPlaybackBadgeSystemImage,
                            diameter: 54
                        )
                        Text("\(Int(playbackProgress.displayedProgress * 100))%")
                            .font(.headline.weight(.semibold))
                            .foregroundColor(.white.opacity(0.62))
                    }
                }

                HStack(spacing: 18) {
                    if let playableFile {
                        Button(action: { onPlay(playableFile) }) {
                            TVHeroActionButton(
                                title: primaryButtonTitle,
                                systemImageName: playableFile.type == .audio ? "music.note" : "play.fill",
                                isPrimary: true,
                                progress: primaryButtonProgress
                            )
                        }
                        .buttonStyle(TVPlainButtonStyle())
                        .tvDisableSystemFocusEffect()
                    }

                    if downloadedCopy != nil && file.isRemote {
                        HStack(spacing: 10) {
                            TVDownloadedStatusIcon(size: 22, showsShadow: false)
                            Text(platformShellString("Downloaded Copy Available"))
                        }
                        .font(.headline.weight(.semibold))
                        .foregroundColor(Color(red: 0.58, green: 0.92, blue: 0.72))
                        .padding(.horizontal, 18)
                        .frame(minHeight: 52)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.black.opacity(0.28))
                        )
                    }
                }
                .padding(.top, 8)
            }
            .padding(.leading, 56)
            .padding(.trailing, 64)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 560)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.34), radius: 24, x: 0, y: 16)
    }
}
#endif
