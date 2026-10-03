#if os(tvOS)
import AVFoundation
import CoreImage
import CryptoKit
import SwiftUI
import UIKit
import GenPlayerCore

// Extracted from TVMainView.swift


struct TVMediaLibraryPosterCard: View {
    let server: ServerConfig
    let node: TVMediaLibraryNode
    @Environment(\.isFocused) private var isFocused

    private let cardWidth = TVMediaLibraryLayout.posterWidth
    private let artworkHeight = TVMediaLibraryLayout.posterHeight
    private let cornerRadius = TVMediaLibraryLayout.posterCornerRadius

    private var secondaryText: String {
        tvMediaLibraryDisplayMetadataLine(for: node)
    }

    private var visiblePlaybackProgress: Double? {
        if node.isPlayed == true {
            return 1
        }
        guard let progress = node.playbackProgress, progress > 0 else { return nil }
        return progress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TVMediaLibraryLayout.posterTextSpacing) {
            ZStack(alignment: .topTrailing) {
                TVRemoteArtworkView(
                    url: node.posterURL,
                    server: server,
                    placeholderSystemImageName: node.isFolder ? "folder.fill" : node.type.tvSystemImageName
                )
                .aspectRatio(2.0/3.0, contentMode: .fill)
                .frame(width: cardWidth, height: artworkHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                if let communityRating = node.communityRating, communityRating > 0 {
                    TVRatingArtworkBadge(rating: communityRating)
                    .padding(10)
                }

                if let progress = visiblePlaybackProgress {
                    TVMediaPlaybackProgressBadge(
                        progress: progress,
                        systemImageName: progress >= 0.98 ? "checkmark" : "play.fill",
                        diameter: 40
                    )
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: cardWidth, height: artworkHeight)
            .tvFocusedPosterArtwork(cornerRadius: cornerRadius)
            .shadow(
                color: Color.black.opacity(isFocused ? 0.30 : 0.20),
                radius: isFocused ? 18 : 12,
                x: 0,
                y: isFocused ? 12 : 6
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(tvDisplayTitle(from: node.name, type: node.type))
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(isFocused ? TVShellStyle.primary : TVShellStyle.primary.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                Text(secondaryText)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isFocused ? TVShellStyle.secondary : TVShellStyle.secondary.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(width: cardWidth, height: TVMediaLibraryLayout.posterTextHeight, alignment: .topLeading)
        }
        .frame(width: cardWidth, height: TVMediaLibraryLayout.posterCardHeight, alignment: .topLeading)
        .tvPosterShelfCard(
            width: cardWidth,
            minHeight: TVMediaLibraryLayout.posterCardHeight,
            focusedScale: TVMediaLibraryLayout.posterFocusScale
        )
    }
}

struct TVMediaLibraryThumbCard: View {
    let server: ServerConfig
    let node: TVMediaLibraryNode
    @Environment(\.isFocused) private var isFocused

    private let cardWidth: CGFloat = 340
    private let artworkHeight: CGFloat = 191
    private let cornerRadius = TVMediaLibraryLayout.posterCornerRadius

    private var secondaryText: String {
        tvMediaLibraryDisplayMetadataLine(for: node)
    }

    private var visiblePlaybackProgress: Double? {
        if node.isPlayed == true {
            return 1
        }
        guard let progress = node.playbackProgress, progress > 0 else { return nil }
        return progress
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TVMediaLibraryLayout.posterTextSpacing) {
            ZStack(alignment: .topTrailing) {
                TVRemoteArtworkView(
                    url: node.backdropURL ?? node.posterURL,
                    server: server,
                    placeholderSystemImageName: node.isFolder ? "folder.fill" : node.type.tvSystemImageName
                )
                .aspectRatio(16.0/9.0, contentMode: .fill)
                .frame(width: cardWidth, height: artworkHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                if let communityRating = node.communityRating, communityRating > 0 {
                    TVRatingArtworkBadge(rating: communityRating)
                    .padding(10)
                }

                if let progress = visiblePlaybackProgress {
                    TVMediaPlaybackProgressBadge(
                        progress: progress,
                        systemImageName: progress >= 0.98 ? "checkmark" : "play.fill",
                        diameter: 40
                    )
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: cardWidth, height: artworkHeight)
            .tvFocusedPosterArtwork(cornerRadius: cornerRadius)
            .shadow(
                color: Color.black.opacity(isFocused ? 0.30 : 0.20),
                radius: isFocused ? 18 : 12,
                x: 0,
                y: isFocused ? 12 : 6
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(tvDisplayTitle(from: node.name, type: node.type))
                    .font(.callout.weight(.semibold))
                    .foregroundColor(isFocused ? TVShellStyle.primary : TVShellStyle.primary.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                Text(secondaryText)
                    .font(.caption.weight(.medium))
                    .foregroundColor(isFocused ? TVShellStyle.secondary : TVShellStyle.secondary.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(width: cardWidth, height: TVMediaLibraryLayout.posterTextHeight, alignment: .topLeading)
        }
        .frame(width: cardWidth, height: artworkHeight + TVMediaLibraryLayout.posterTextHeight + TVMediaLibraryLayout.posterTextSpacing, alignment: .topLeading)
        .tvPosterShelfCard(
            width: cardWidth,
            minHeight: artworkHeight + TVMediaLibraryLayout.posterTextHeight + TVMediaLibraryLayout.posterTextSpacing,
            focusedScale: TVMediaLibraryLayout.posterFocusScale
        )
    }
}



struct TVMediaLibraryListRow: View {
    let server: ServerConfig
    let node: TVMediaLibraryNode
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private let rowCornerRadius: CGFloat = 22

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var primaryColor: Color {
        TVRowFocusStyle.primary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var secondaryColor: Color {
        TVRowFocusStyle.secondary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var rowFill: Color {
        if showsFocus {
            return TVRowFocusStyle.focusedFill(for: colorScheme)
        }
        return TVShellStyle.surface.opacity(0.72)
    }

    private var rowStroke: Color {
        showsFocus ? Color.clear : Color.white.opacity(0.075)
    }

    private var detailedMetadataLine: String {
        var parts: [String] = []
        if let yearText = tvMediaLibraryDisplayDateText(for: node) {
            parts.append(yearText)
        }
        if let durationText = tvDurationText(ticks: node.runtimeTicks) {
            parts.append(durationText)
        }
        if let resolution = tvMediaLibraryResolutionText(for: node) {
            parts.append(resolution)
        }
        if let rating = node.rating, !rating.isEmpty {
            parts.append(rating)
        }
        if let childCount = node.childCount, childCount > 0 {
            if node.isSeries {
                parts.append(String(format: platformShellString("%d Seasons"), childCount))
            } else {
                parts.append(String(format: platformShellString("%d Items"), childCount))
            }
        }
        return parts.joined(separator: "  •  ")
    }

    var body: some View {
        HStack(spacing: 24) {
            TVRemoteArtworkView(
                url: node.posterURL,
                server: server,
                placeholderSystemImageName: node.isFolder ? "folder.fill" : node.type.tvSystemImageName
            )
            .aspectRatio(contentMode: .fill)
            .frame(width: 72, height: 108)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipped()

            VStack(alignment: .leading, spacing: 6) {
                Text(tvDisplayTitle(from: node.name, type: node.type))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(primaryColor)
                    .lineLimit(1)

                HStack(spacing: 14) {
                    if let rating = node.communityRating, rating > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.yellow)
                            Text(String(format: "%.1f", rating))
                                .font(.system(size: 18, weight: .bold))
                                .foregroundColor(primaryColor)
                        }
                    }
                    
                    if !detailedMetadataLine.isEmpty {
                        Text(detailedMetadataLine)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(secondaryColor)
                            .lineLimit(1)
                    }
                }

                if let summary = node.summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(summary)
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(secondaryColor.opacity(0.85))
                        .lineLimit(2)
                } else if !node.genres.isEmpty {
                    Text(node.genres.joined(separator: " / "))
                        .font(.system(size: 18, weight: .regular))
                        .foregroundColor(secondaryColor.opacity(0.85))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer(minLength: 10)

            Image(systemName: "chevron.right")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(secondaryColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 136, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                .stroke(rowStroke, lineWidth: 1)
        )
        .scaleEffect(showsFocus ? 1.012 : 1.0)
        .shadow(
            color: showsFocus ? Color.black.opacity(0.26) : .clear,
            radius: showsFocus ? 18 : 0,
            x: 0,
            y: showsFocus ? 10 : 0
        )
        .overlay(TVFocusedBlockOverlay(cornerRadius: rowCornerRadius, showsFocus: showsFocus, outerLineWidth: 2.8, innerInset: 4))
        .animation(.easeOut(duration: 0.16), value: showsFocus)
        .tvDisableSystemFocusEffect()
    }
}



struct TVMediaLibraryFeaturedCard: View {
    let server: ServerConfig
    let item: TVMediaLibraryFeaturedItem
    @Environment(\.isFocused) private var isFocused

    private let cardWidth = TVMediaLibraryLayout.featuredWidth
    private let artworkHeight = TVMediaLibraryLayout.featuredHeight
    private let cornerRadius = TVMediaLibraryLayout.posterCornerRadius

    private var secondaryText: String {
        tvMediaLibraryDisplayMetadataLine(for: item.node)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TVMediaLibraryLayout.posterTextSpacing) {
            ZStack(alignment: .bottomLeading) {
                TVRemoteArtworkView(
                    url: item.node.posterURL,
                    server: server,
                    placeholderSystemImageName: item.node.isFolder ? "folder.fill" : item.node.type.tvSystemImageName
                )
                .aspectRatio(16.0/9.0, contentMode: .fill)
                .frame(width: cardWidth, height: artworkHeight)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.clear,
                        Color.black.opacity(0.58)
                    ]),
                    startPoint: .center,
                    endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))

                if let progress = item.progress, progress > 0 {
                    TVMediaPlaybackProgressBadge(
                        progress: progress,
                        systemImageName: "play.fill",
                        diameter: 42
                    )
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .frame(width: cardWidth, height: artworkHeight)
            .tvFocusedPosterArtwork(cornerRadius: cornerRadius)
            .shadow(
                color: Color.black.opacity(isFocused ? 0.32 : 0.20),
                radius: isFocused ? 20 : 14,
                x: 0,
                y: isFocused ? 13 : 8
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(tvDisplayTitle(from: item.node.name, type: item.node.type))
                    .font(.callout.weight(.semibold))
                    .foregroundColor(isFocused ? TVShellStyle.primary : TVShellStyle.primary.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: TVMediaLibraryLayout.posterTitleHeight,
                        maxHeight: TVMediaLibraryLayout.posterTitleHeight,
                        alignment: .topLeading
                    )

                Text(secondaryText)
                    .font(.caption.weight(.medium))
                    .foregroundColor(isFocused ? TVShellStyle.secondary : TVShellStyle.secondary.opacity(0.72))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: TVMediaLibraryLayout.posterSubtitleHeight,
                        maxHeight: TVMediaLibraryLayout.posterSubtitleHeight,
                        alignment: .topLeading
                    )
            }
            .frame(width: cardWidth, height: TVMediaLibraryLayout.featuredTextHeight, alignment: .topLeading)
        }
        .frame(width: cardWidth, height: TVMediaLibraryLayout.featuredCardHeight, alignment: .topLeading)
        .tvPosterShelfCard(
            width: cardWidth,
            minHeight: TVMediaLibraryLayout.featuredCardHeight,
            focusedScale: TVMediaLibraryLayout.posterFocusScale
        )
    }
}



struct TVMediaLibraryBrowseAllCard: View {
    let title: String
    @Environment(\.isFocused) private var isFocused

    private let cardWidth = TVMediaLibraryLayout.posterWidth
    private let artworkHeight = TVMediaLibraryLayout.posterHeight
    private let cornerRadius = TVMediaLibraryLayout.posterCornerRadius

    var body: some View {
        VStack(alignment: .leading, spacing: TVMediaLibraryLayout.posterTextSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                TVShellStyle.accent.opacity(0.18),
                                Color.white.opacity(0.06),
                                Color.white.opacity(0.03)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                VStack(spacing: 14) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundColor(TVShellStyle.accentSoft)
                    Image(systemName: "chevron.right.circle.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(.white.opacity(0.60))
                }
            }
            .aspectRatio(2.0/3.0, contentMode: .fill)
            .frame(width: cardWidth, height: artworkHeight)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .tvFocusedPosterArtwork(cornerRadius: cornerRadius)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundColor(isFocused ? .white : .white.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: TVMediaLibraryLayout.posterTitleHeight,
                        maxHeight: TVMediaLibraryLayout.posterTitleHeight,
                        alignment: .topLeading
                    )

                Text(platformShellString("Browse"))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(isFocused ? .white.opacity(0.72) : .white.opacity(0.46))
                    .lineLimit(1)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: TVMediaLibraryLayout.posterSubtitleHeight,
                        maxHeight: TVMediaLibraryLayout.posterSubtitleHeight,
                        alignment: .topLeading
                    )
            }
            .frame(width: cardWidth, height: TVMediaLibraryLayout.posterTextHeight, alignment: .topLeading)
        }
        .frame(width: cardWidth, height: TVMediaLibraryLayout.posterCardHeight, alignment: .topLeading)
        .tvPosterShelfCard(
            width: cardWidth,
            minHeight: TVMediaLibraryLayout.posterCardHeight,
            focusedScale: TVMediaLibraryLayout.posterFocusScale
        )
    }
}



struct TVMediaLibraryCategoryCard: View {
    let server: ServerConfig
    let node: TVMediaLibraryNode
    @Environment(\.isFocused) private var isFocused
    @State private var previewBackdropURL: URL?
    @State private var realItemCount: Int?
    @State private var didAttemptLoadInfo = false
    @State private var loadInfoTask: Task<Void, Never>?

    private let cardWidth: CGFloat = 340
    private let cardHeight: CGFloat = 168
    private let cornerRadius: CGFloat = 18

    private var iconName: String {
        tvMediaLibraryCollectionIcon(for: node.libraryCollectionType, nodeName: node.name)
    }

    private var effectiveBackdropURL: URL? {
        node.backdropURL ?? node.posterURL ?? previewBackdropURL
    }

    private var effectiveItemCount: Int? {
        realItemCount ?? node.childCount
    }

    private var fallbackGradient: LinearGradient {
        let type = (node.libraryCollectionType ?? node.rawItemType).lowercased()
        switch type {
        case "movies", "movie":
            return LinearGradient(
                colors: [Color(red: 0.18, green: 0.25, blue: 0.46), Color(red: 0.08, green: 0.12, blue: 0.25)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "tvshows", "series", "show":
            return LinearGradient(
                colors: [Color(red: 0.12, green: 0.35, blue: 0.32), Color(red: 0.06, green: 0.15, blue: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "anime":
            return LinearGradient(
                colors: [Color(red: 0.42, green: 0.18, blue: 0.36), Color(red: 0.16, green: 0.08, blue: 0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "boxsets", "collections", "boxset":
            return LinearGradient(
                colors: [Color(red: 0.38, green: 0.26, blue: 0.12), Color(red: 0.16, green: 0.10, blue: 0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case "music", "musicalbum", "audio":
            return LinearGradient(
                colors: [Color(red: 0.36, green: 0.15, blue: 0.42), Color(red: 0.14, green: 0.06, blue: 0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        default:
            return LinearGradient(
                colors: [Color(red: 0.24, green: 0.24, blue: 0.28), Color(red: 0.11, green: 0.11, blue: 0.14)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let posterURL = effectiveBackdropURL {
                    TVRemoteArtworkView(
                        url: posterURL,
                        server: server,
                        placeholderSystemImageName: iconName,
                        placeholderCornerRadius: cornerRadius
                    )
                } else {
                    fallbackGradient
                }
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipped()

            LinearGradient(
                colors: [
                    Color.black.opacity(0.12),
                    Color.black.opacity(0.40),
                    Color.black.opacity(0.85)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: iconName)
                        .font(.system(size: 20, weight: .bold))
                        .foregroundColor(isFocused ? .white : TVShellStyle.accentSoft)

                    Text(node.name)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }

                if let count = effectiveItemCount, count > 0 {
                    Text(MediaCountFormatter.format(count: count, libraryType: node.jellyfinLibraryType))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white.opacity(0.72))
                        .padding(.leading, 30)
                }
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 18)
        }
        .frame(width: cardWidth, height: cardHeight)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(isFocused ? Color.white : Color.white.opacity(0.15), lineWidth: isFocused ? 3.5 : 1)
        )
        .tvPosterShelfCard(
            width: cardWidth,
            minHeight: cardHeight,
            focusedScale: 1.06
        )
        .onAppear {
            loadCategoryInfoIfNeeded()
        }
        .onDisappear {
            loadInfoTask?.cancel()
            loadInfoTask = nil
        }
    }

    private func loadCategoryInfoIfNeeded() {
        guard !didAttemptLoadInfo else { return }
        didAttemptLoadInfo = true
        loadInfoTask = Task {
            let (fetchedURL, fetchedCount) = await tvFetchMediaLibraryCategoryInfo(server: server, node: node)
            if Task.isCancelled { return }
            await MainActor.run {
                if let fetchedURL {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.previewBackdropURL = fetchedURL
                    }
                }
                if let fetchedCount, fetchedCount > 0 {
                    self.realItemCount = fetchedCount
                }
            }
        }
    }
}







struct TVMediaLibraryShelfLoadingCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: TVMediaLibraryLayout.posterTextSpacing) {
            ZStack {
                RoundedRectangle(cornerRadius: TVMediaLibraryLayout.posterCornerRadius, style: .continuous)
                    .fill(Color.white.opacity(0.07))

                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: TVShellStyle.primary))
            }
            .frame(width: TVMediaLibraryLayout.posterWidth, height: TVMediaLibraryLayout.posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: TVMediaLibraryLayout.posterCornerRadius, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(platformShellString("Platform Shell TV Loading"))
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: TVMediaLibraryLayout.posterTitleHeight,
                        maxHeight: TVMediaLibraryLayout.posterTitleHeight,
                        alignment: .topLeading
                    )

                Text(platformShellString("Browse"))
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: TVMediaLibraryLayout.posterSubtitleHeight,
                        maxHeight: TVMediaLibraryLayout.posterSubtitleHeight,
                        alignment: .topLeading
                    )
            }
            .frame(width: TVMediaLibraryLayout.posterWidth, height: TVMediaLibraryLayout.posterTextHeight, alignment: .topLeading)
        }
        .frame(width: TVMediaLibraryLayout.posterWidth, height: TVMediaLibraryLayout.posterCardHeight, alignment: .topLeading)
        .tvPosterShelfCard(
            width: TVMediaLibraryLayout.posterWidth,
            minHeight: TVMediaLibraryLayout.posterCardHeight,
            focusedScale: TVMediaLibraryLayout.posterFocusScale
        )
    }
}



struct TVRemoteArtworkView: View {
    let url: URL?
    let server: ServerConfig
    let placeholderSystemImageName: String
    var placeholderCornerRadius: CGFloat = 22

    @ObservedObject private var playbackCoordinator = TVPlaybackCoordinator.shared
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?

    private var isPlaybackActive: Bool {
        playbackCoordinator.activeRequest != nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: placeholderCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.055),
                            Color.black.opacity(0.20)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            if let image {
                Color.clear
                    .overlay(
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    )
                    .clipped()
            } else if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: TVShellStyle.primary))
            } else {
                Image(systemName: placeholderSystemImageName)
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .clipped()
        .onAppear {
            loadImageIfNeeded()
        }
        .onChange(of: url?.absoluteString ?? "") { _ in
            loadTask?.cancel()
            loadTask = nil
            isLoading = false
            image = nil
            loadImageIfNeeded()
        }
        .onChange(of: playbackCoordinator.activeRequest?.id) { _ in
            handlePlaybackActivityChange()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            if image == nil {
                isLoading = false
            }
        }
    }

    func loadImageIfNeeded() {
        guard image == nil, !isLoading, let url else { return }

        if let cached = TVImageCache.shared.image(for: url) {
            image = cached
            return
        }

        guard !isPlaybackActive else { return }

        isLoading = true
        loadTask?.cancel()
        loadTask = Task {
            do {
                guard let permit = await TVArtworkLoadLimiter.shared.acquire(.mediaLibraryImage) else {
                    return
                }
                defer { permit.release() }
                try Task.checkCancellation()

                var request = URLRequest(url: RuntimeNetworkAddressResolver.runtimeURL(from: url))
                tvApplyMediaLibraryImageHeaders(to: &request, server: server)

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200...299).contains(http.statusCode),
                      let loadedImage = UIImage(data: data) else {
                    throw URLError(.cannotDecodeContentData)
                }

                if Task.isCancelled { return }
                await MainActor.run {
                    TVImageCache.shared.save(loadedImage, for: url)
                    image = loadedImage
                    isLoading = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }

    private func handlePlaybackActivityChange() {
        guard image == nil else { return }

        if isPlaybackActive {
            loadTask?.cancel()
            loadTask = nil
            isLoading = false
        } else {
            loadImageIfNeeded()
        }
    }
}




struct TVServerCard: View {
    let server: ServerConfig
    var showsPrivacyBadge: Bool = false
    var privacyBadgeSystemName: String = "lock"
    var isConnecting: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            TVServerTypeLogo(type: server.type, size: 70)

            VStack(alignment: .leading, spacing: 6) {
                // Line 1: Server Type Pill + Privacy Badge
                HStack(spacing: 8) {
                    Text(server.type.displayName)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundColor(server.type.tvAccentColor)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(
                            Capsule(style: .continuous)
                                .fill(server.type.tvAccentColor.opacity(0.16))
                        )

                    if showsPrivacyBadge {
                        TVPrivacyMarkerBadge(systemImageName: privacyBadgeSystemName, diameter: 22, iconSize: 11)
                    }
                }

                // Line 2: Server Name
                Text(server.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                // VOD endpoints are implementation details, not useful browsing metadata on TV.
                if server.type != .vod {
                    Text(server.address.isEmpty ? server.type.displayName : server.address)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(TVShellStyle.secondary)
                        .lineLimit(1)
                }

                // Line 4: Indicators / Badges
                if isConnecting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text(platformShellString("Platform Shell TV Loading"))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(TVShellStyle.secondary)
                    }
                } else if server.type == .iptv {
                    if let summary = IPTVService.shared.summary(for: server.id) {
                        HStack(spacing: 12) {
                            HStack(spacing: 4) {
                                Image(systemName: "rectangle.stack")
                                Text("\(summary.groupCount)")
                            }
                            HStack(spacing: 4) {
                                Image(systemName: "tv")
                                Text(NumberFormatter.localizedString(from: NSNumber(value: summary.channelCount), number: .decimal))
                            }
                            HStack(spacing: 4) {
                                Image(systemName: "clock")
                                Text(IPTVService.shared.formatLastUpdated(summary.lastUpdated))
                            }
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(TVShellStyle.secondary.opacity(0.9))
                        .lineLimit(1)
                    } else {
                        Text(platformShellString("Not loaded yet"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(TVShellStyle.secondary.opacity(0.65))
                            .lineLimit(1)
                    }
                } else if let mediaSummary = server.mobileMediaSummary {
                    HStack(spacing: 12) {
                        if mediaSummary.movieCount > 0 || mediaSummary.seriesCount > 0 {
                            if mediaSummary.movieCount > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "film")
                                    Text(NumberFormatter.localizedString(from: NSNumber(value: mediaSummary.movieCount), number: .decimal))
                                }
                            }
                            if mediaSummary.seriesCount > 0 {
                                HStack(spacing: 4) {
                                    Image(systemName: "tv")
                                    Text(NumberFormatter.localizedString(from: NSNumber(value: mediaSummary.seriesCount), number: .decimal))
                                }
                            }
                        } else {
                            HStack(spacing: 4) {
                                Image(systemName: "square.stack.3d.up")
                                Text(NumberFormatter.localizedString(from: NSNumber(value: mediaSummary.libraryCount), number: .decimal))
                            }
                        }
                        if server.type == .vod, let sources = server.vodSources, sources.count > 1 {
                            Text(String(format: platformShellString("VOD Source Count %d"), sources.count))
                        }
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            Text(MediaServerSummaryService.shared.formatLastUpdated(mediaSummary.lastUpdated))
                        }
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(TVShellStyle.secondary.opacity(0.9))
                    .lineLimit(1)
                } else if server.type.isMediaServer {
                    Text(platformShellString("Not loaded yet"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(TVShellStyle.secondary.opacity(0.65))
                        .lineLimit(1)
                } else {
                    if let lastAccessed = server.lastAccessed {
                        HStack(spacing: 4) {
                            Image(systemName: "clock")
                            Text(MediaServerSummaryService.shared.formatLastUpdated(lastAccessed))
                        }
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(TVShellStyle.secondary.opacity(0.9))
                        .lineLimit(1)
                    } else {
                        Text(platformShellString("Not accessed yet"))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(TVShellStyle.secondary.opacity(0.65))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            Image(systemName: isConnecting ? "hourglass" : "chevron.right.circle.fill")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(TVShellStyle.secondary.opacity(0.48))
        }
        .tvServerShelfCard(width: TVServerCardMetrics.contentWidth, height: 104)
    }
}



struct TVPrivacyMarkerBadge: View {
    let systemImageName: String
    var diameter: CGFloat = 30
    var iconSize: CGFloat = 14

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(systemName: systemImageName)
            .font(.system(size: iconSize, weight: .heavy))
            .foregroundColor(colorScheme == .dark ? .white.opacity(0.96) : .black.opacity(0.55))
            .frame(width: diameter, height: diameter)
            .background(
                Circle()
                    .fill(colorScheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.06))
            )
            .overlay(
                Circle()
                    .stroke(colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.16), radius: 8, x: 0, y: 4)
    }
}



struct TVServerTypeLogo: View {
    let type: ServerConfig.ServerType
    let size: CGFloat
    var showsBackground = false

    private var cornerRadius: CGFloat {
        max(10, size * 0.22)
    }

    private var iconSize: CGFloat {
        size * (showsBackground ? 0.58 : 0.88)
    }

    var body: some View {
        ZStack {
            if showsBackground {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                type.tvAccentColor.opacity(0.62),
                                type.tvHeroSecondaryAccentColor.opacity(0.82)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            if let uiImage = UIImage(named: type.iconAssetName) {
                Image(uiImage: uiImage)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
            } else {
                Image(systemName: type.systemIconName)
                    .font(.system(size: size * (showsBackground ? 0.44 : 0.76), weight: .semibold))
                    .foregroundColor(showsBackground ? .white.opacity(0.92) : type.tvAccentColor)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            Group {
                if showsBackground {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                }
            }
        )
    }
}



struct TVServerIdentityPill: View {
    let server: ServerConfig

    var body: some View {
        HStack(spacing: 12) {
            TVServerTypeLogo(type: server.type, size: 46)

            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(server.type.displayName)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(server.type.tvAccentColor)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .frame(height: 62)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.075))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.11), lineWidth: 1)
        )
    }
}



struct TVServerIdentityInline: View {
    let server: ServerConfig

    var body: some View {
        HStack(spacing: 10) {
            TVServerTypeLogo(type: server.type, size: 38)

            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(.white.opacity(0.82))
                    .lineLimit(1)

                Text(server.type.displayName)
                    .font(.system(size: 14, weight: .heavy))
                    .foregroundColor(server.type.tvAccentColor)
                    .lineLimit(1)
            }
        }
    }
}



struct TVProfileShortcutTile: View {
    let title: String
    let systemImageName: String
    let accent: Color

    @Environment(\.isFocused) private var isFocused

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                accent.opacity(0.35),
                                Color.white.opacity(0.08),
                                Color.black.opacity(0.18)
                            ]),
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: systemImageName)
                    .font(.system(size: 74, weight: .bold))
                    .foregroundColor(.white.opacity(0.86))
                    .padding(24)
            }
            .frame(height: 166)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(isFocused ? Color.clear : TVShellStyle.glassStroke, lineWidth: 1)
            )
            .overlay(TVFocusedBlockOverlay(cornerRadius: 22, showsFocus: isFocused))

            Text(title)
                .font(.title3.weight(.bold))
                .foregroundColor(TVShellStyle.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 360)
        .scaleEffect(isFocused ? 1.035 : 1.0)
        .shadow(color: isFocused ? Color.black.opacity(0.30) : Color.black.opacity(0.10), radius: isFocused ? 24 : 10, x: 0, y: isFocused ? 14 : 6)
        .shadow(color: isFocused ? TVShellStyle.focusStroke.opacity(0.14) : .clear, radius: isFocused ? 14 : 0, x: 0, y: 0)
        .animation(.easeOut(duration: 0.16), value: isFocused)
        .tvDisableSystemFocusEffect()
        .modifier(TVFocusedCardLayerModifier())
    }
}



struct TVStoredMediaArtworkView: View {
    let file: VideoFile
    let server: ServerConfig?
    let url: URL?
    let placeholderSymbolName: String

    private var accent: Color {
        file.tvFileIconColor
    }

    var body: some View {
        ZStack {
            if let server, let url, shouldUseRemoteFilePreviewArtwork(server: server, url: url) {
                TVRemoteFilePreviewArtworkView(
                    file: file,
                    server: server,
                    accent: accent,
                    placeholderSymbolName: placeholderSymbolName
                )
            } else if let server, let url, shouldUseMediaServerArtwork(server: server) {
                TVRemoteArtworkView(
                    url: url,
                    server: server,
                    placeholderSystemImageName: placeholderSymbolName
                )
            } else if let url {
                TVGenericArtworkView(
                    url: url,
                    accent: accent,
                    placeholderSymbolName: placeholderSymbolName,
                    contentMode: file.type == .audio ? .fit : .fill
                )
            } else {
                placeholder
            }

            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.08),
                    Color.black.opacity(0.18),
                    Color.black.opacity(0.48)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .clipped()
    }

    private func shouldUseRemoteFilePreviewArtwork(server: ServerConfig, url: URL) -> Bool {
        guard !url.isFileURL,
              file.type == .image || file.type == .audio else {
            return false
        }

        switch server.type {
        case .smb, .webdav:
            return true
        case .alist, .pan115, .onedrive, .googledrive, .ftp, .sftp, .nfs, .jellyfin, .emby, .plex, .iptv, .vod:
            return false
        }
    }

    private func shouldUseMediaServerArtwork(server: ServerConfig) -> Bool {
        switch server.type {
        case .jellyfin, .emby, .plex:
            return true
        case .smb, .webdav, .alist, .pan115, .onedrive, .googledrive, .ftp, .sftp, .nfs, .iptv, .vod:
            return false
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            accent.opacity(0.34),
                            TVShellStyle.elevatedSurface,
                            Color.black.opacity(0.16)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: placeholderSymbolName)
                .font(.system(size: 92, weight: .regular))
                .foregroundColor(accent.opacity(0.64))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}



struct TVGenericArtworkView: View {
    let url: URL
    let accent: Color
    let placeholderSymbolName: String
    var contentMode: ContentMode = .fill

    @ObservedObject private var playbackCoordinator = TVPlaybackCoordinator.shared
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?

    private var isPlaybackActive: Bool {
        playbackCoordinator.activeRequest != nil
    }

    var body: some View {
        ZStack {
            placeholder

            if let image {
                if contentMode == .fit {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.clear
                        .overlay(
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                        )
                        .clipped()
                }
            } else if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: TVShellStyle.primary))
            }
        }
        .clipped()
        .onAppear {
            loadImageIfNeeded()
        }
        .onChange(of: url.absoluteString) { _ in
            loadTask?.cancel()
            loadTask = nil
            image = nil
            isLoading = false
            loadImageIfNeeded()
        }
        .onChange(of: playbackCoordinator.activeRequest?.id) { _ in
            handlePlaybackActivityChange()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            if image == nil {
                isLoading = false
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            accent.opacity(0.32),
                            TVShellStyle.elevatedSurface,
                            Color.black.opacity(0.18)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: placeholderSymbolName)
                .font(.system(size: 86, weight: .regular))
                .foregroundColor(accent.opacity(0.60))
        }
    }

    private func loadImageIfNeeded() {
        guard image == nil, !isLoading else { return }

        if let cached = TVImageCache.shared.image(for: url) {
            image = cached
            return
        }

        guard !isPlaybackActive else { return }

        isLoading = true
        loadTask?.cancel()
        loadTask = Task {
            do {
                guard let permit = await TVArtworkLoadLimiter.shared.acquire(.genericArtwork) else {
                    return
                }
                defer { permit.release() }
                try Task.checkCancellation()

                let loadedImage = try await tvLoadGenericArtworkImage(from: url)
                if Task.isCancelled { return }
                await MainActor.run {
                    TVImageCache.shared.save(loadedImage, for: url)
                    image = loadedImage
                    isLoading = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }

    private func handlePlaybackActivityChange() {
        guard image == nil else { return }

        if isPlaybackActive {
            loadTask?.cancel()
            loadTask = nil
            isLoading = false
        } else {
            loadImageIfNeeded()
        }
    }
}



struct TVMediaLandscapeCard: View {
    let file: VideoFile

    @ObservedObject private var historyService = HistoryService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var networkService = AppNetworkService.shared

    private var progress: PlaybackProgressSnapshot? {
        historyService.playbackProgressSnapshot(matching: file)
    }

    private var resolvedServer: ServerConfig? {
        file.tvResolvedServer(from: networkService.servers)
    }

    private var artworkURL: URL? {
        tvStoredMediaArtworkURL(for: file, server: resolvedServer)
    }

    private var hasDownloadedLocalCopy: Bool {
        if file.isRemote {
            return downloadCenter.localFileURL(for: file) != nil
        }
        return file.tvHasRemoteOrigin && file.url.isFileURL
    }

    private var subtitle: String {
        var tokens: [String] = []
        if let durationText = file.tvDurationText {
            tokens.append(durationText)
        }
        if let server = resolvedServer {
            tokens.append(server.name)
        } else {
            tokens.append(file.tvHasRemoteOrigin ? platformShellString("Network") : platformShellString("Local"))
        }
        return tokens.joined(separator: " • ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .bottomLeading) {
                TVStoredMediaArtworkView(
                    file: file,
                    server: resolvedServer,
                    url: artworkURL,
                    placeholderSymbolName: file.tvDecorativeSymbolName
                )
                .aspectRatio(16.0/9.0, contentMode: .fill)
                .frame(width: TVMediaLibraryLayout.featuredWidth, height: TVMediaLibraryLayout.featuredHeight)
                .clipShape(RoundedRectangle(cornerRadius: TVMediaLibraryLayout.posterCornerRadius, style: .continuous))

                HStack(alignment: .top, spacing: 12) {
                    TVStoredMediaPlaybackBadge(file: file, progress: progress, diameter: 44)

                    if hasDownloadedLocalCopy {
                        TVDownloadedStatusIcon(size: 22)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                TVStoredMediaSourceBadge(file: file, server: resolvedServer, maxWidth: 210)
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            }
            .frame(width: TVMediaLibraryLayout.featuredWidth, height: TVMediaLibraryLayout.featuredHeight)
            .tvFocusedPosterArtwork(cornerRadius: TVMediaLibraryLayout.posterCornerRadius)
            .shadow(color: Color.black.opacity(0.18), radius: 14, x: 0, y: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(tvDisplayTitle(for: file))
                    .font(.callout.weight(.semibold))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: TVMediaLibraryLayout.posterTitleHeight, maxHeight: TVMediaLibraryLayout.posterTitleHeight, alignment: .topLeading)

                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundColor(TVShellStyle.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: TVMediaLibraryLayout.posterSubtitleHeight, maxHeight: TVMediaLibraryLayout.posterSubtitleHeight, alignment: .topLeading)
            }
            .frame(width: TVMediaLibraryLayout.featuredWidth, height: TVMediaLibraryLayout.featuredTextHeight, alignment: .topLeading)
        }
        .tvPosterShelfCard(
            width: TVMediaLibraryLayout.featuredWidth,
            minHeight: TVMediaLibraryLayout.featuredCardHeight,
            focusedScale: TVMediaLibraryLayout.posterFocusScale
        )
    }
}



struct TVMediaCard: View {
    let file: VideoFile

    @ObservedObject private var historyService = HistoryService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var networkService = AppNetworkService.shared

    private var progress: PlaybackProgressSnapshot? {
        historyService.playbackProgressSnapshot(matching: file)
    }

    private var resolvedServer: ServerConfig? {
        file.tvResolvedServer(from: networkService.servers)
    }

    private var artworkURL: URL? {
        tvStoredMediaArtworkURL(for: file, server: resolvedServer)
    }

    private var hasDownloadedLocalCopy: Bool {
        if file.isRemote {
            return downloadCenter.localFileURL(for: file) != nil
        }
        return file.tvHasRemoteOrigin && file.url.isFileURL
    }

    private var subtitle: String {
        if let server = resolvedServer {
            return server.name
        }
        return file.tvHasRemoteOrigin ? platformShellString("Network") : platformShellString("Local")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                TVStoredMediaArtworkView(
                    file: file,
                    server: resolvedServer,
                    url: artworkURL,
                    placeholderSymbolName: file.tvDecorativeSymbolName
                )
                .aspectRatio(16.0/9.0, contentMode: .fill)
                .frame(width: 304, height: 171)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                HStack(alignment: .top, spacing: 12) {
                    TVStoredMediaPlaybackBadge(file: file, progress: progress, diameter: 46)

                    if hasDownloadedLocalCopy {
                        TVDownloadedStatusIcon(size: 26)
                    }

                    if TVSecurityService.shared.isPrivacySpaceEnabled && PrivacySpaceService.shared.isFileMarkedPrivate(file) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 32, height: 32)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                TVStoredMediaSourceBadge(file: file, server: resolvedServer)
                    .padding(18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            }
            .frame(width: 304, height: 171)
            .tvFocusedPosterArtwork(cornerRadius: 18)
            .shadow(color: Color.black.opacity(0.16), radius: 12, x: 0, y: 8)

            VStack(alignment: .leading, spacing: 4) {
                Text(tvDisplayTitle(for: file))
                    .font(.callout.weight(.semibold))
                    .foregroundColor(TVShellStyle.primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 48, maxHeight: 48, alignment: .topLeading)

                Text(subtitle)
                    .font(.caption.weight(.medium))
                    .foregroundColor(TVShellStyle.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .topLeading)

                Text(tvTimestamp(file.date))
                    .font(.caption.weight(.medium))
                    .foregroundColor(TVShellStyle.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, minHeight: 20, maxHeight: 20, alignment: .topLeading)
            }
            .frame(width: 304, height: 92, alignment: .topLeading)
        }
        .tvPosterShelfCard(width: 304, minHeight: 273, focusedScale: TVMediaLibraryLayout.posterFocusScale)
    }
}



struct TVFileGridCard: View {
    let file: VideoFile
    var server: ServerConfig? = nil
    var privacyBadgeSystemName: String?

    @ObservedObject private var historyService = HistoryService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @ObservedObject private var favoriteService = FavoriteService.shared
    @Environment(\.isFocused) private var isFocused
    @State private var resolvedFolderItemCount: Int?
    @State private var hasRequestedFolderItemCount = false
    @State private var folderItemCountTask: Task<Void, Never>?

    private var progress: PlaybackProgressSnapshot? {
        historyService.playbackProgressSnapshot(matching: file)
    }

    private var isFavorite: Bool {
        favoriteService.isFavorite(file: file, folderPath: favoritePath)
    }

    private var favoritePath: String? {
        file.type == .folder ? tvNormalizedRemotePath(file.remoteDownloadPath) : nil
    }

    private var displayedFolderItemCount: Int? {
        file.itemCount ?? resolvedFolderItemCount
    }

    private var metadataLine: String? {
        if file.type == .folder {
            if let itemCount = displayedFolderItemCount {
                return String(format: platformShellString("%d Items"), itemCount)
            }
            return tvTimestamp(file.date)
        }

        var tokens: [String] = []
        if let durationText = file.tvDurationText {
            tokens.append(durationText)
        }
        if file.size > 0 {
            tokens.append(tvByteCountString(file.size))
        }

        return tokens.isEmpty ? tvTimestamp(file.date) : tokens.joined(separator: " · ")
    }

    private var titleHeight: CGFloat {
        54
    }

    private var cardHeight: CGFloat {
        254
    }

    private var artworkHeight: CGFloat {
        134
    }

    private var cardPadding: CGFloat {
        15
    }

    private var cardSpacing: CGFloat {
        9
    }

    var body: some View {
        VStack(alignment: .center, spacing: cardSpacing) {
            artwork
                .frame(width: 222)

            VStack(alignment: .center, spacing: 5) {
                Text(tvDisplayTitle(for: file))
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(isFocused ? TVShellStyle.primary : TVShellStyle.primary.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: 222, alignment: .top)

                if let metadataLine = metadataLine {
                    Text(metadataLine)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(isFocused ? TVShellStyle.secondary : TVShellStyle.secondary.opacity(0.85))
                        .lineLimit(1)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 222, alignment: .top)
                }

            }
        }
        .padding(.horizontal, cardPadding)
        .padding(.top, cardPadding)
        .padding(.bottom, 10)
        .frame(width: 252, height: 250, alignment: .top)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .modifier(TVFileBrowserCardModifier())
        .modifier(TVFocusedCardLayerModifier())
        .onAppear {
            loadFolderItemCountIfNeeded()
        }
        .onDisappear {
            folderItemCountTask?.cancel()
            folderItemCountTask = nil
            if resolvedFolderItemCount == nil {
                hasRequestedFolderItemCount = false
            }
        }
    }

    private var artwork: some View {
        ZStack(alignment: .topTrailing) {
            TVFileGridArtworkView(
                file: file,
                server: server,
                isFocused: isFocused
            )

            fileStatusBadges
                .padding(10)

            if let formatBadge = file.tvFormatBadgeText,
               file.type != .folder {
                Text(formatBadge)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.54))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(isFocused ? 0.18 : 0.10), lineWidth: 1)
                    )
                    .padding(10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 222, height: artworkHeight)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.white.opacity(isFocused ? 0.20 : 0.08), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var fileStatusBadges: some View {
        if hasStatusBadges {
            HStack(spacing: 7) {
                if isFavorite {
                    Image(systemName: "star.fill")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundColor(Color(red: 1.0, green: 0.78, blue: 0.24))
                }

                if let privacyBadgeSystemName {
                    TVPrivacyMarkerBadge(
                        systemImageName: privacyBadgeSystemName,
                        diameter: 31,
                        iconSize: 15
                    )
                }

                if let progress, progress.displayedProgress > 0 {
                    TVStoredMediaPlaybackBadge(file: file, progress: progress, diameter: 31)
                }

                if downloadCenter.localFileURL(for: file) != nil && file.isRemote {
                    TVDownloadedStatusIcon(size: 18, showsShadow: false)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.black.opacity(0.18))
            )
        }
    }

    private var hasStatusBadges: Bool {
        isFavorite
            || privacyBadgeSystemName != nil
            || (progress?.displayedProgress ?? 0) > 0
            || (downloadCenter.localFileURL(for: file) != nil && file.isRemote)
    }

    private func loadFolderItemCountIfNeeded() {
        guard file.type == .folder,
              file.itemCount == nil,
              resolvedFolderItemCount == nil,
              !hasRequestedFolderItemCount,
              let server else {
            return
        }

        hasRequestedFolderItemCount = true
        let serverToLoad = server
        let folderPath = tvNormalizedRemotePath(file.remoteDownloadPath)

        folderItemCountTask = Task {
            do {
                let loaded = try await AppNetworkService.shared.fetchContents(for: serverToLoad, at: folderPath)
                if Task.isCancelled { return }

                await MainActor.run {
                    resolvedFolderItemCount = loaded.filter { candidate in
                        !candidate.name.hasPrefix(".") && !tvShouldHidePrivateFile(candidate)
                    }.count
                    folderItemCountTask = nil
                }
            } catch {
                if Task.isCancelled { return }

                await MainActor.run {
                    folderItemCountTask = nil
                }
            }
        }
    }
}



struct TVFileGridArtworkView: View {
    let file: VideoFile
    let server: ServerConfig?
    let isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private var suppressesAutomaticArtwork: Bool {
        (server?.type ?? file.serverType) == .alist &&
            (file.type == .audio || file.type == .video)
    }

    private var canAttemptPreview: Bool {
        !suppressesAutomaticArtwork && (
            file.type == .image ||
                file.type == .video ||
                (file.type == .audio && (file.url.isFileURL || server != nil))
        )
    }

    private var usesRemoteDownloadPreview: Bool {
        guard (file.type == .image || file.type == .audio),
              !file.url.isFileURL,
              let server else {
            return false
        }

        switch server.type {
        case .smb, .webdav, .ftp, .sftp, .nfs:
            return true
        case .alist, .pan115, .onedrive, .googledrive, .jellyfin, .emby, .plex, .iptv, .vod:
            return false
        }
    }

    private var genericPreviewContentMode: ContentMode {
        file.type == .image ? .fit : .fill
    }

    var body: some View {
        ZStack {
            previewLayer

            LinearGradient(
                gradient: Gradient(colors: [
                    Color.black.opacity(0.0),
                    Color.black.opacity(file.type == .folder ? (colorScheme == .dark ? 0.04 : 0.0) : (colorScheme == .dark ? 0.36 : 0.16))
                ]),
                startPoint: .center,
                endPoint: .bottom
            )
        }
    }

    @ViewBuilder
    private var previewLayer: some View {
        if usesRemoteDownloadPreview, let server {
            TVRemoteFilePreviewArtworkView(
                file: file,
                server: server,
                accent: file.tvFileIconColor,
                placeholderSymbolName: file.tvDecorativeSymbolName
            )
        } else if canAttemptPreview {
            TVGenericArtworkView(
                url: file.url,
                accent: file.tvFileIconColor,
                placeholderSymbolName: file.tvDecorativeSymbolName,
                contentMode: genericPreviewContentMode
            )
        } else {
            placeholderLayer
        }
    }

    private var placeholderLayer: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: colorScheme == .dark ? [
                            file.tvFileIconColor.opacity(isFocused ? 0.23 : 0.15),
                            Color.white.opacity(isFocused ? 0.10 : 0.055),
                            Color.black.opacity(isFocused ? 0.18 : 0.24)
                        ] : [
                            file.tvFileIconColor.opacity(isFocused ? 0.12 : 0.06),
                            Color.white.opacity(isFocused ? 0.40 : 0.15),
                            file.tvFileIconColor.opacity(isFocused ? 0.06 : 0.02)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: file.tvFileIconName)
                .font(.system(size: file.type == .folder ? 45 : 52, weight: .semibold))
                .foregroundColor(file.tvFileIconColor.opacity(isFocused ? 0.94 : 0.82))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

}



struct TVRemoteFilePreviewArtworkView: View {
    let file: VideoFile
    let server: ServerConfig
    let accent: Color
    let placeholderSymbolName: String

    @ObservedObject private var playbackCoordinator = TVPlaybackCoordinator.shared
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var loadTask: Task<Void, Never>?

    private var isPlaybackActive: Bool {
        playbackCoordinator.activeRequest != nil
    }

    var body: some View {
        ZStack {
            TVFilePreviewPlaceholderArtwork(accent: accent, systemImageName: placeholderSymbolName)

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            } else if isLoading {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: TVShellStyle.primary))
            }
        }
        .clipped()
        .onAppear {
            loadImageIfNeeded()
        }
        .onChange(of: file.remoteDownloadPath) { _ in
            loadTask?.cancel()
            loadTask = nil
            image = nil
            isLoading = false
            loadImageIfNeeded()
        }
        .onChange(of: playbackCoordinator.activeRequest?.id) { _ in
            handlePlaybackActivityChange()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            if image == nil {
                isLoading = false
            }
        }
    }

    private func loadImageIfNeeded() {
        guard image == nil, !isLoading else { return }

        if let cached = TVImageCache.shared.image(for: file.url) {
            image = cached
            return
        }

        if file.type == .audio {
            isLoading = false
            return
        }

        guard !isPlaybackActive else { return }

        isLoading = true
        loadTask?.cancel()
        loadTask = Task {
            do {
                guard let permit = await TVArtworkLoadLimiter.shared.acquire(.fileServicePreview) else {
                    return
                }
                defer { permit.release() }
                try Task.checkCancellation()

                let localURL = try await AppNetworkService.shared.downloadFile(server: server, at: file.remoteDownloadPath)
                defer { tvCleanupTemporaryDownload(at: localURL) }

                let decodedImage: UIImage?
                if file.type == .audio {
                    decodedImage = try? tvExtractAudioArtworkImage(from: localURL)
                } else {
                    decodedImage = UIImage(contentsOfFile: localURL.path)
                        ?? (try? Data(contentsOf: localURL)).flatMap(UIImage.init(data:))
                }
                guard let decodedImage else {
                    throw URLError(.cannotDecodeContentData)
                }

                if Task.isCancelled { return }
                await MainActor.run {
                    TVImageCache.shared.save(decodedImage, for: file.url)
                    image = decodedImage
                    isLoading = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    isLoading = false
                }
            }
        }
    }

    private func handlePlaybackActivityChange() {
        guard image == nil else { return }

        if isPlaybackActive {
            loadTask?.cancel()
            loadTask = nil
            isLoading = false
        } else {
            loadImageIfNeeded()
        }
    }
}



struct TVFilePreviewPlaceholderArtwork: View {
    let accent: Color
    let systemImageName: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            accent.opacity(colorScheme == .dark ? 0.28 : 0.15),
                            accent.opacity(colorScheme == .dark ? 0.08 : 0.04),
                            colorScheme == .dark ? Color.black.opacity(0.18) : Color.black.opacity(0.02)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Image(systemName: systemImageName)
                .font(.system(size: 52, weight: .semibold))
                .foregroundColor(accent.opacity(0.70))
        }
    }
}



struct TVDownloadJobCard: View {
    let job: DownloadJobGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: job.sourceType.tvSystemImageName)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(TVShellStyle.accentSoft)
                Spacer()
                Image(systemName: job.primaryStatus.tvSystemImageName)
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.85))
            }

            Text(job.title)
                .font(.title3.weight(.bold))
                .lineLimit(2)

            Text(job.serverName)
                .font(.headline)
                .foregroundColor(.secondary)

            ProgressView(value: job.aggregateProgress)
                .progressViewStyle(LinearProgressViewStyle(tint: TVShellStyle.primary))

            HStack(spacing: 18) {
                Text("\(job.completedCount)/\(job.itemCount)")
                Text(tvTimestamp(job.createdAt))
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .tvShelfCard(width: 360, minHeight: 220)
    }
}



struct TVBrowserRow: View {
    let file: VideoFile
    var server: ServerConfig? = nil
    var privacyBadgeSystemName: String? = nil

    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    private let iconSide: CGFloat = 64
    private let rowCornerRadius: CGFloat = 22

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var metadataLine: String {
        var tokens: [String] = []

        tokens.append(tvTimestamp(file.date))

        if file.type != .folder, let durationText = file.tvDurationText {
            tokens.append(durationText)
        }

        if file.type != .folder, file.size > 0 {
            tokens.append(tvByteCountString(file.size))
        }

        if file.type != .folder,
           let formatBadge = file.tvFormatBadgeText,
           tokens.count == 1 {
            tokens.append(formatBadge)
        }

        return tokens.joined(separator: " • ")
    }

    private var primaryColor: Color {
        TVRowFocusStyle.primary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var secondaryColor: Color {
        TVRowFocusStyle.secondary(showsFocus: showsFocus, isEnabled: isEnabled, colorScheme: colorScheme)
    }

    private var rowFill: Color {
        if showsFocus {
            return TVRowFocusStyle.focusedFill(for: colorScheme)
        }
        return TVShellStyle.surface.opacity(0.72)
    }

    private var rowStroke: Color {
        showsFocus ? Color.clear : Color.white.opacity(0.075)
    }

    private var hasDownloadedCopy: Bool {
        downloadCenter.localFileURL(for: file) != nil && file.isRemote
    }

    var body: some View {
        HStack(spacing: 16) {
            previewTile

            VStack(alignment: .leading, spacing: 4) {
                Text(tvDisplayTitle(for: file))
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(primaryColor)
                    .lineLimit(1)

                Text(metadataLine)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(secondaryColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            trailingBadges

            Spacer(minLength: 10)

            Image(systemName: "chevron.right")
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(secondaryColor)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                .fill(rowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: rowCornerRadius, style: .continuous)
                .stroke(rowStroke, lineWidth: 1)
        )
        .overlay(TVFocusedBlockOverlay(cornerRadius: rowCornerRadius, showsFocus: showsFocus, outerLineWidth: 2.8, innerInset: 4))
        .scaleEffect(showsFocus ? 1.008 : 1.0)
        .shadow(
            color: showsFocus ? Color.black.opacity(0.22) : Color.clear,
            radius: showsFocus ? 16 : 0,
            x: 0,
            y: showsFocus ? 8 : 0
        )
        .modifier(TVFocusedCardLayerModifier())
        .animation(.easeOut(duration: 0.16), value: showsFocus)
        .tvDisableSystemFocusEffect()
    }

    private var previewTile: some View {
        ZStack(alignment: .topTrailing) {
            TVFileGridArtworkView(
                file: file,
                server: server,
                isFocused: showsFocus
            )
            .frame(width: iconSide, height: iconSide)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(file.tvFileIconColor.opacity(showsFocus ? 0.30 : 0.18), lineWidth: 1)
            )

            if let privacyBadgeSystemName {
                TVPrivacyMarkerBadge(
                    systemImageName: privacyBadgeSystemName,
                    diameter: 23,
                    iconSize: 11
                )
                .offset(x: 6, y: -6)
            }
        }
        .frame(width: iconSide, height: iconSide)
    }

    @ViewBuilder
    private var trailingBadges: some View {
        HStack(spacing: 10) {
            if hasDownloadedCopy {
                TVDownloadedStatusIcon(size: 20, showsShadow: false)
            }

            if file.type != .folder,
               let formatBadge = file.tvFormatBadgeText {
                Text(formatBadge)
                    .font(.system(size: 16, weight: .heavy))
                    .foregroundColor(showsFocus ? Color.black.opacity(0.70) : Color.white.opacity(0.82))
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        Capsule(style: .continuous)
                            .fill(showsFocus ? Color.black.opacity(0.08) : Color.white.opacity(0.08))
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(showsFocus ? Color.black.opacity(0.08) : Color.white.opacity(0.08), lineWidth: 1)
                    )
            }
        }
    }
}



struct TVActionCard: View {
    let title: String
    let subtitle: String
    let systemImageName: String
    var iconTint: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: systemImageName)
                .font(.title2)
                .foregroundColor(iconTint)
            Text(title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
        }
        .tvDetailPanel()
    }
}



struct TVNavigationCard: View {
    let title: String
    let subtitle: String
    let systemImageName: String
    var accentColor: Color = TVShellStyle.accentSoft
    var isDestructive = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                Image(systemName: systemImageName)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundColor(accentColor)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }

            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(isDestructive ? Color.red.opacity(0.95) : TVShellStyle.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
                .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)

            Text(subtitle)
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
        }
        .tvShelfCard(width: 330, minHeight: 224)
    }
}



struct TVCompactActionStrip<Content: View>: View {
    let title: String
    let content: () -> Content

    init(title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.system(size: 30, weight: .heavy))
                .foregroundColor(TVShellStyle.primary)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 18) {
                    content()
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
            .tvFocusSectionIfAvailable()
            .padding(.horizontal, -22)
        }
    }
}



struct TVCompactActionCard: View {
    let title: String
    let systemImageName: String
    var isDestructive = false

    @Environment(\.isFocused) private var isFocused
    @Environment(\.isEnabled) private var isEnabled

    private var showsFocus: Bool {
        isFocused && isEnabled
    }

    private var iconColor: Color {
        guard isEnabled else { return TVShellStyle.secondary.opacity(0.42) }
        return isDestructive ? Color.red.opacity(0.95) : TVShellStyle.accentSoft
    }

    private var titleColor: Color {
        guard isEnabled else { return TVShellStyle.secondary.opacity(0.42) }
        if isDestructive {
            return Color.red.opacity(showsFocus ? 0.98 : 0.95)
        }
        return TVShellStyle.primary
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: systemImageName)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(iconColor)
                .frame(width: 34)

            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundColor(titleColor)
                .lineLimit(1)
                .minimumScaleFactor(0.74)

            Spacer(minLength: 10)

            Image(systemName: "chevron.right")
                .font(.headline.weight(.bold))
                .foregroundColor(TVShellStyle.secondary.opacity(isEnabled ? 0.80 : 0.32))
        }
        .frame(width: 310, height: 76)
        .padding(.horizontal, 22)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(showsFocus ? TVShellStyle.elevatedSurface : TVShellStyle.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(showsFocus ? Color.clear : TVShellStyle.glassStroke, lineWidth: 1)
        )
        .overlay(TVFocusedBlockOverlay(cornerRadius: 22, showsFocus: showsFocus))
        .scaleEffect(showsFocus ? 1.025 : 1.0)
        .shadow(color: showsFocus ? Color.black.opacity(0.26) : .clear, radius: showsFocus ? 16 : 0, x: 0, y: showsFocus ? 8 : 0)
        .shadow(color: showsFocus ? TVShellStyle.focusStroke.opacity(0.14) : .clear, radius: showsFocus ? 14 : 0, x: 0, y: 0)
        .animation(.easeOut(duration: 0.16), value: showsFocus)
        .modifier(TVFocusedCardLayerModifier())
    }
}
#endif
