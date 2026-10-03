import SwiftUI
import AVFoundation

// MARK: - Helper Extensions

private enum FileFormatDecorationStyle {
    case text
    case spreadsheet
    case presentation
    case archive
    case design
    case font
}

extension VideoFile {
    private var normalizedExtension: String {
        URL(fileURLWithPath: name).pathExtension.lowercased()
    }

    private var usesWordDocumentIcon: Bool {
        ["doc", "docx", "rtf", "odt", "pages"].contains(normalizedExtension)
    }

    private var usesSpreadsheetIcon: Bool {
        ["xls", "xlsx", "csv", "tsv", "ods", "numbers"].contains(normalizedExtension)
    }

    private var usesPresentationIcon: Bool {
        ["ppt", "pptx", "odp", "key"].contains(normalizedExtension)
    }

    private var usesArchiveIcon: Bool {
        ["zip", "rar", "7z", "tar", "gz", "bz2", "xz"].contains(normalizedExtension)
    }

    private var usesDesignAssetIcon: Bool {
        ["psd", "ai", "sketch", "fig", "xd"].contains(normalizedExtension)
    }

    private var usesFontIcon: Bool {
        ["ttf", "otf", "woff", "woff2"].contains(normalizedExtension)
    }

    var usesStyledFormatTile: Bool {
        switch type {
        case .document, .unknown, .audio, .video, .subtitle:
            return true
        default:
            return false
        }
    }

    var formatBadgeText: String? {
        switch normalizedExtension {
        case "pdf":
            return "PDF"
        case "doc":
            return "DOC"
        case "docx":
            return "DOCX"
        case "pages":
            return "PAGE"
        case "rtf":
            return "RTF"
        case "odt":
            return "ODT"
        case "xls":
            return "XLS"
        case "xlsx":
            return "XLSX"
        case "csv":
            return "CSV"
        case "tsv":
            return "TSV"
        case "numbers":
            return "NUM"
        case "ods":
            return "ODS"
        case "ppt":
            return "PPT"
        case "pptx":
            return "PPTX"
        case "key":
            return "KEY"
        case "odp":
            return "ODP"
        case "zip":
            return "ZIP"
        case "rar":
            return "RAR"
        case "7z":
            return "7Z"
        case "tar":
            return "TAR"
        case "gz":
            return "GZ"
        case "bz2":
            return "BZ2"
        case "xz":
            return "XZ"
        case "psd":
            return "PSD"
        case "ai":
            return "AI"
        case "sketch":
            return "SKT"
        case "fig":
            return "FIG"
        case "xd":
            return "XD"
        case "ttf":
            return "TTF"
        case "otf":
            return "OTF"
        case "woff":
            return "WOFF"
        case "woff2":
            return "WF2"
        default:
            let uppercasedExtension = normalizedExtension.uppercased()
            guard !uppercasedExtension.isEmpty else { return nil }
            return uppercasedExtension.count > 4 ? String(uppercasedExtension.prefix(4)) : uppercasedExtension
        }
    }

    var formatTileTint: Color {
        switch type {
        case .document:
            if normalizedExtension == "pdf" { return Color.red.opacity(0.14) }
            if usesSpreadsheetIcon { return Color.green.opacity(0.13) }
            if usesPresentationIcon { return Color.orange.opacity(0.15) }
            if usesWordDocumentIcon { return Color.blue.opacity(0.13) }
            return Color(UIColor.secondarySystemBackground)
        case .unknown:
            if usesArchiveIcon { return Color(UIColor.systemBrown).opacity(0.16) }
            if usesDesignAssetIcon { return Color.purple.opacity(0.14) }
            if usesFontIcon { return Color.blue.opacity(0.12) }
            return Color(UIColor.secondarySystemBackground)
        default:
            return Color(UIColor.secondarySystemBackground)
        }
    }

    fileprivate var formatDecorationStyle: FileFormatDecorationStyle {
        if usesSpreadsheetIcon { return .spreadsheet }
        if usesPresentationIcon { return .presentation }
        if usesArchiveIcon { return .archive }
        if usesDesignAssetIcon { return .design }
        if usesFontIcon { return .font }
        return .text
    }

    var usesPreviewThumbnailStyle: Bool {
        type == .video || type == .audio || type == .image
    }

    var showsPreviewIndicatorBadge: Bool {
        type == .video || type == .audio || type == .image
    }

    var previewThumbnailContentMode: ContentMode {
        switch type {
        case .video, .image:
            return .fit
        default:
            return .fill
        }
    }

    var previewThumbnailNeedsInset: Bool {
        previewThumbnailContentMode == .fit
    }

    var iconName: String {
        switch type {
        case .folder: return "folder.fill"
        case .video: return "play.rectangle.fill"
        case .audio: return "music.note"
        case .subtitle: return "captions.bubble.fill"
        case .image: return "photo"
        case .document:
            if normalizedExtension == "pdf" { return "doc.richtext.fill" }
            if usesSpreadsheetIcon { return "tablecells.fill" }
            if usesPresentationIcon { return "chart.bar.fill" }
            if usesWordDocumentIcon { return "doc.text.fill" }
            return "doc.text"
        case .unknown:
            if usesArchiveIcon { return "archivebox.fill" }
            if usesDesignAssetIcon { return "paintpalette.fill" }
            if usesFontIcon { return "textformat" }
            return "doc.fill"
        }
    }

    var iconColor: Color {
        switch type {
        case .folder: return .blue
        case .video: return .purple
        case .audio: return .pink
        case .subtitle: return .orange
        case .image: return .green
        case .document:
            if normalizedExtension == "pdf" { return .red }
            if usesSpreadsheetIcon { return .green }
            if usesPresentationIcon { return .orange }
            if usesWordDocumentIcon { return .blue }
            return .gray
        case .unknown:
            if usesArchiveIcon { return Color(UIColor.systemBrown) }
            if usesDesignAssetIcon { return .purple }
            if usesFontIcon { return .blue }
            return .secondary
        }
    }

    var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size)
    }

    var displaySizeText: String? {
        if type == .folder {
            return nil
        }
        if size > 0 || !isRemote {
            return formattedSize
        }
        return nil
    }

    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var formattedListDate: String {
        formattedDate.replacingOccurrences(of: ",", with: "")
    }

    var formattedDurationText: String? {
        guard let duration = duration, duration > 0 else { return nil }
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var typeBadgeSystemImage: String {
        switch type {
        case .folder: return "folder.fill"
        case .video: return "play.fill"
        case .audio: return "music.note"
        case .subtitle: return "captions.bubble.fill"
        case .image: return "photo"
        case .document:
            if normalizedExtension == "pdf" { return "doc.richtext.fill" }
            if usesSpreadsheetIcon { return "tablecells.fill" }
            if usesPresentationIcon { return "chart.bar.fill" }
            if usesWordDocumentIcon { return "doc.text.fill" }
            return "doc.text.fill"
        case .unknown:
            if usesArchiveIcon { return "archivebox.fill" }
            if usesDesignAssetIcon { return "paintpalette.fill" }
            if usesFontIcon { return "textformat" }
            return "questionmark"
        }
    }

    var playbackBadgeSystemImage: String {
        if let serverType {
            switch serverType {
            case .jellyfin, .emby, .plex:
                if type == .folder {
                    return "folder.fill"
                }
                return type == .audio ? "music.note" : "play.fill"
            default:
                break
            }
        }

        if jellyfinItemId != nil {
            if type == .folder {
                return "folder.fill"
            }
            return type == .audio ? "music.note" : "play.fill"
        }

        if type == .unknown {
            if itemCount != nil {
                return "folder.fill"
            }
            if isRemote {
                return "play.fill"
            }
        }

        return typeBadgeSystemImage
    }

    func matchesHistoryEntry(_ historyFile: VideoFile) -> Bool {
        if url == historyFile.url { return true }
        if url.standardizedFileURL.path == historyFile.url.standardizedFileURL.path { return true }

        if url.isFileURL && historyFile.url.isFileURL && url.lastPathComponent == historyFile.url.lastPathComponent {
            return true
        }

        return false
    }
}

struct PlaybackProgressRing: View {
    let progress: Double
    var color: Color = .blue

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.black.opacity(0.14), lineWidth: 2)
            if progress >= 1 {
                Circle()
                    .stroke(color, lineWidth: 2.6)
            } else {
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, progress))))
                    .stroke(color, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

struct PlaybackProgressBadge: View {
    let snapshot: PlaybackProgressSnapshot
    var diameter: CGFloat
    var usesDarkBackground: Bool = true
    var symbolName: String? = nil
    var finishedSymbolName: String? = nil
    var symbolSize: CGFloat = 9

    private var activeSymbolName: String? {
        if snapshot.isFinished, let finishedSymbolName {
            return finishedSymbolName
        }
        return symbolName
    }

    private var ringColor: Color {
        snapshot.isFinished ? .green : .blue
    }

    private var innerFillColor: Color {
        if usesDarkBackground {
            return snapshot.isFinished ? Color.black.opacity(0.82) : Color.black.opacity(0.72)
        }
        return snapshot.isFinished
            ? Color(UIColor.secondarySystemBackground)
            : Color(UIColor.secondarySystemBackground).opacity(0.96)
    }

    private var innerStrokeColor: Color {
        if usesDarkBackground {
            return snapshot.isFinished ? Color.white.opacity(0.2) : Color.white.opacity(0.12)
        }
        return Color.white.opacity(snapshot.isFinished ? 0.24 : 0.18)
    }

    var body: some View {
        ZStack {
            PlaybackProgressRing(
                progress: snapshot.displayedProgress,
                color: ringColor
            )
            .frame(width: diameter + 4, height: diameter + 4)

            Circle()
                .fill(innerFillColor)
                .frame(width: diameter, height: diameter)
                .overlay(
                    Circle()
                        .stroke(innerStrokeColor, lineWidth: 0.8)
                )

            if let activeSymbolName {
                Image(systemName: activeSymbolName)
                    .font(.system(size: symbolSize, weight: .bold))
                    .foregroundColor(usesDarkBackground ? .white : .primary)
            }
        }
    }
}

struct FileFormatIconView: View {
    let file: VideoFile
    let side: CGFloat
    var showsBackground: Bool = true

    private var isCompact: Bool {
        side <= 44
    }

    private var outerCornerRadius: CGFloat {
        side * 0.22
    }

    private var cardPadding: CGFloat {
        max(4, side * 0.12)
    }

    private var symbolBubbleSize: CGFloat {
        isCompact ? side * 0.42 : side * 0.3
    }

    private var symbolFontSize: CGFloat {
        max(10, side * 0.16)
    }

    private var codeFontSize: CGFloat {
        max(8.5, side * (isCompact ? 0.2 : 0.2))
    }

    private var extensionLabel: String {
        file.formatBadgeText ?? "FILE"
    }

    private var tileGradient: LinearGradient {
        LinearGradient(
            gradient: Gradient(colors: [
                file.iconColor.opacity(showsBackground ? 0.95 : 0.88),
                file.iconColor.opacity(showsBackground ? 0.72 : 0.62)
            ]),
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var tileGlow: some View {
        RoundedRectangle(cornerRadius: outerCornerRadius * 0.9, style: .continuous)
            .fill(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color.white.opacity(showsBackground ? 0.18 : 0.1),
                        Color.white.opacity(0.02)
                    ]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .padding(side * 0.05)
    }

    @ViewBuilder
    private var decorationView: some View {
        switch file.formatDecorationStyle {
        case .text:
            VStack(spacing: max(2, side * 0.035)) {
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: side * 0.34, height: max(2, side * 0.035))
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: side * 0.28, height: max(2, side * 0.033))
                if !isCompact {
                    Capsule()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: side * 0.21, height: max(2, side * 0.03))
                }
            }
        case .spreadsheet:
            HStack(spacing: max(2, side * 0.03)) {
                ForEach(0..<3) { _ in
                    RoundedRectangle(cornerRadius: side * 0.04, style: .continuous)
                        .fill(Color.white.opacity(0.22))
                        .frame(width: side * 0.07, height: side * (isCompact ? 0.14 : 0.18))
                }
            }
        case .presentation:
            HStack(alignment: .bottom, spacing: max(2, side * 0.035)) {
                RoundedRectangle(cornerRadius: side * 0.04, style: .continuous)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: side * 0.07, height: side * 0.12)
                RoundedRectangle(cornerRadius: side * 0.04, style: .continuous)
                    .fill(Color.white.opacity(0.24))
                    .frame(width: side * 0.07, height: side * 0.18)
                RoundedRectangle(cornerRadius: side * 0.04, style: .continuous)
                    .fill(Color.white.opacity(0.3))
                    .frame(width: side * 0.07, height: side * 0.24)
            }
        case .archive:
            VStack(spacing: max(2, side * 0.03)) {
                ForEach(0..<2) { _ in
                    RoundedRectangle(cornerRadius: side * 0.05, style: .continuous)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: side * 0.28, height: side * 0.08)
                }
            }
        case .design:
            HStack(spacing: max(2, side * 0.03)) {
                Circle()
                    .fill(Color.white.opacity(0.3))
                    .frame(width: side * 0.11, height: side * 0.11)
                Circle()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: side * 0.11, height: side * 0.11)
                Circle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: side * 0.11, height: side * 0.11)
            }
        case .font:
            Text("Aa")
                .font(.system(size: max(8, side * 0.18), weight: .semibold, design: .serif))
                .foregroundColor(Color.white.opacity(0.28))
        }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous)
                .fill(tileGradient)

            tileGlow

            RoundedRectangle(cornerRadius: outerCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.9)

            Group {
                if isCompact {
                    VStack(spacing: max(2, side * 0.055)) {
                        Spacer(minLength: 0)

                        compactSymbolBubble

                        compactExtensionLabel

                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(max(3, side * 0.08))
                } else {
                    VStack(spacing: max(2, side * 0.06)) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.2))

                            Image(systemName: file.iconName)
                                .font(.system(size: symbolFontSize, weight: .semibold))
                                .foregroundColor(.white.opacity(0.94))
                        }
                        .frame(width: symbolBubbleSize, height: symbolBubbleSize)

                        decorationView
                            .frame(maxWidth: .infinity, alignment: .center)

                        Spacer(minLength: 0)

                        Text(extensionLabel)
                            .font(.system(size: codeFontSize, weight: .heavy, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(cardPadding)
                }
            }
        }
        .frame(width: side, height: side)
    }

    private var compactSymbolBubble: some View {
        ZStack {
            RoundedRectangle(cornerRadius: side * 0.12, style: .continuous)
                .fill(Color.white.opacity(0.16))

            Image(systemName: file.iconName)
                .font(.system(size: symbolFontSize, weight: .semibold))
                .foregroundColor(.white.opacity(0.96))
        }
        .frame(width: symbolBubbleSize, height: symbolBubbleSize)
    }

    private var compactExtensionLabel: some View {
        Text(extensionLabel)
            .font(.system(size: codeFontSize, weight: .heavy, design: .rounded))
            .foregroundColor(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
    }
}

private struct FileThumbnailCoreView: View {
    let file: VideoFile
    let iconSide: CGFloat
    var usesDecorativeBackgroundForNonPreview: Bool = true
    var loadsPreviewThumbnails: Bool = true
    @ObservedObject private var historyService = HistoryService.shared
    @State private var thumbnailAspectRatio: CGFloat?
    @State private var mediaSourceAspectRatio: CGFloat?
    @State private var isThumbnailRequestActive = false

    private var styledFormatInnerSide: CGFloat {
        if iconSide <= 44 {
            return iconSide * 0.68
        }
        return iconSide * (iconSide >= 76 ? 0.58 : 0.64)
    }

    private var styledFormatInnerSize: CGSize {
        if iconSide >= 76 {
            let side = min(44, iconSide * 0.55)
            return CGSize(width: side, height: side)
        }
        let side = styledFormatInnerSide
        return CGSize(width: side, height: side)
    }

    private var previewInset: CGFloat {
        file.previewThumbnailNeedsInset ? iconSide * 0.06 : 0
    }

    private var effectiveVideoAspectRatio: CGFloat? {
        if let hint = file.videoAspectRatioHint, hint > 0 {
            return CGFloat(hint)
        }

        if let historyHint = historyService.allHistory.first(where: { file.matchesHistoryEntry($0) })?.videoAspectRatioHint,
           historyHint > 0 {
            return CGFloat(historyHint)
        }

        if let mediaSourceAspectRatio, mediaSourceAspectRatio > 0 {
            return mediaSourceAspectRatio
        }

        if let thumbnailAspectRatio, thumbnailAspectRatio > 0 {
            return thumbnailAspectRatio
        }

        return nil
    }

    private var usesPortraitVideoThumbnailLayout: Bool {
        guard file.type == .video,
              let thumbnailURL = file.thumbnailURL,
              thumbnailURLMatchesMediaSource(thumbnailURL),
              let effectiveVideoAspectRatio,
              effectiveVideoAspectRatio > 0 else {
            return false
        }

        return effectiveVideoAspectRatio < 1.2
    }

    private var portraitVideoThumbnailSize: CGSize {
        let availableSide = max(0, iconSide - (previewInset * 2))
        let availableSize = CGSize(width: availableSide, height: availableSide)
        guard let aspectRatio = effectiveVideoAspectRatio,
              aspectRatio > 0 else {
            return availableSize
        }

        let width = min(availableSize.width, availableSize.height * aspectRatio)
        let height = min(availableSize.height, width / aspectRatio)
        return CGSize(width: width, height: height)
    }

    private var portraitVideoCornerRadius: CGFloat {
        min(iconSide * 0.18, max(8, portraitVideoThumbnailSize.width * 0.18))
    }

    var body: some View {
        Group {
            if file.usesPreviewThumbnailStyle && loadsPreviewThumbnails {
                let cornerRadius = iconSide * 0.2
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color(UIColor.secondarySystemBackground))

                    if let thumbnailURL = file.thumbnailURL {
                        if usesPortraitVideoThumbnailLayout {
                            RemoteImage(
                                url: thumbnailURL,
                                sourceFile: file,
                                placeholderSystemImage: file.iconName,
                                placeholderTint: file.iconColor,
                                contentMode: .fill,
                                isActive: isThumbnailRequestActive,
                                permitNetworkForAudioArtwork: true,
                                onImageLoaded: updateThumbnailAspectRatio
                            )
                                .frame(width: portraitVideoThumbnailSize.width, height: portraitVideoThumbnailSize.height)
                                .clipShape(RoundedRectangle(cornerRadius: portraitVideoCornerRadius, style: .continuous))
                        } else {
                            RemoteImage(
                                url: thumbnailURL,
                                sourceFile: file,
                                placeholderSystemImage: file.iconName,
                                placeholderTint: file.iconColor,
                                contentMode: file.previewThumbnailContentMode,
                                isActive: isThumbnailRequestActive,
                                permitNetworkForAudioArtwork: true,
                                onImageLoaded: updateThumbnailAspectRatio
                            )
                                .padding(previewInset)
                                .frame(width: iconSide, height: iconSide)
                        }
                    } else if file.usesStyledFormatTile {
                        FileFormatIconView(
                            file: file,
                            side: iconSide,
                            showsBackground: false
                        )
                    } else {
                        Image(systemName: file.iconName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: iconSide * 0.54, height: iconSide * 0.54)
                            .foregroundColor(file.iconColor)
                    }
                }
                .frame(width: iconSide, height: iconSide)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .onAppear {
                    if !isThumbnailRequestActive {
                        isThumbnailRequestActive = true
                    }
                    resolveMediaSourceAspectRatioIfNeeded()
                }
                .onChange(of: isThumbnailRequestActive) { newValue in
                    if newValue {
                        resolveMediaSourceAspectRatioIfNeeded()
                    }
                }
                .onDisappear {
                    if isThumbnailRequestActive {
                        isThumbnailRequestActive = false
                    }
                }
            } else {
                let cornerRadius = iconSide * 0.22
                ZStack {
                    if file.usesStyledFormatTile {
                        if usesDecorativeBackgroundForNonPreview {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(Color(UIColor.secondarySystemBackground))

                            FileFormatIconView(
                                file: file,
                                side: styledFormatInnerSize.width,
                                showsBackground: true
                            )
                            .frame(width: styledFormatInnerSize.width, height: styledFormatInnerSize.height)
                        } else {
                            FileFormatIconView(
                                file: file,
                                side: iconSide,
                                showsBackground: false
                            )
                        }
                    } else {
                        if usesDecorativeBackgroundForNonPreview {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(Color(UIColor.secondarySystemBackground))
                        }

                        Image(systemName: file.type == .folder ? "folder.fill" : file.iconName)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                width: file.type == .folder ? iconSide * 0.86 : iconSide * 0.68, 
                                height: file.type == .folder ? iconSide * 0.86 : iconSide * 0.68
                            )
                            .foregroundColor(file.iconColor)
                    }
                }
                .frame(width: iconSide, height: iconSide)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
        }
    }

    private func updateThumbnailAspectRatio(_ image: UIImage) {
        guard image.size.width > 0, image.size.height > 0 else { return }
        let ratio = image.size.width / image.size.height
        guard ratio.isFinite else { return }

        if let current = thumbnailAspectRatio, abs(current - ratio) < 0.01 {
            return
        }

        thumbnailAspectRatio = ratio
    }

    private func thumbnailURLMatchesMediaSource(_ thumbnailURL: URL) -> Bool {
        if thumbnailURL == file.url {
            return true
        }

        if thumbnailURL.isFileURL && file.url.isFileURL {
            return thumbnailURL.standardizedFileURL == file.url.standardizedFileURL
        }

        return thumbnailURL.absoluteString == file.url.absoluteString
    }

    private func resolveMediaSourceAspectRatioIfNeeded() {
        guard file.type == .video,
              mediaSourceAspectRatio == nil else {
            return
        }

        if let serverRatio = mediaSourceAspectRatioFromServerStreams() {
            mediaSourceAspectRatio = serverRatio
            return
        }

        guard file.url.isFileURL else { return }
        let fileURL = file.url

        DispatchQueue.global(qos: .utility).async {
            let asset = AVURLAsset(url: fileURL)
            guard let videoTrack = asset.tracks(withMediaType: .video).first else { return }

            let transformedSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
            let width = abs(transformedSize.width)
            let height = abs(transformedSize.height)
            guard width > 0, height > 0 else { return }

            let ratio = width / height
            guard ratio.isFinite else { return }

            DispatchQueue.main.async {
                if let current = self.mediaSourceAspectRatio, abs(current - ratio) < 0.01 {
                    return
                }
                self.mediaSourceAspectRatio = ratio
            }
        }
    }

    private func mediaSourceAspectRatioFromServerStreams() -> CGFloat? {
        guard let streams = file.serverMediaStreams else { return nil }

        for stream in streams {
            guard let type = stream["Type"] as? String,
                  type.caseInsensitiveCompare("Video") == .orderedSame,
                  let width = stream["Width"] as? Int,
                  let height = stream["Height"] as? Int,
                  width > 0,
                  height > 0 else {
                continue
            }

            let ratio = CGFloat(width) / CGFloat(height)
            if ratio.isFinite {
                return ratio
            }
        }

        return nil
    }
}

private struct MediaIndicatorBadge: View {
    let file: VideoFile
    let playbackSnapshot: PlaybackProgressSnapshot?
    let diameter: CGFloat
    let iconSize: CGFloat
    var usesDarkBackground: Bool = true

    var body: some View {
        ZStack {
            if let playbackSnapshot = playbackSnapshot,
               playbackSnapshot.displayedProgress > 0 {
                PlaybackProgressBadge(
                    snapshot: playbackSnapshot,
                    diameter: diameter,
                    usesDarkBackground: usesDarkBackground,
                    symbolName: file.playbackBadgeSystemImage,
                    symbolSize: iconSize
                )
            } else {
                Circle()
                    .fill(usesDarkBackground ? Color.black.opacity(0.72) : Color(UIColor.secondarySystemBackground).opacity(0.96))
                    .frame(width: diameter, height: diameter)
                    .overlay(
                        Circle()
                            .stroke(usesDarkBackground ? Color.white.opacity(0.12) : Color.white.opacity(0.18), lineWidth: 0.8)
                    )

                Image(systemName: file.playbackBadgeSystemImage)
                    .font(.system(size: iconSize, weight: .bold))
                    .foregroundColor(usesDarkBackground ? .white : .primary)
            }
        }
    }
}

struct DownloadStatusIcon: View {
    var size: CGFloat = 11

    var body: some View {
        Image(systemName: "arrow.down.circle.fill")
            .font(.system(size: size, weight: .semibold))
            .foregroundColor(.green)
    }
}

func appFormattedApproximateFileSize(_ size: Int64) -> String {
    let gb = Double(size) / 1_073_741_824.0
    if gb >= 1.0 {
        return "\(Int(gb.rounded())) GB"
    }
    let mb = Double(size) / 1_048_576.0
    if mb >= 1.0 {
        return "\(Int(mb.rounded())) MB"
    }
    let kb = Double(size) / 1024.0
    return "\(Int(kb.rounded())) KB"
}

func appLineBreakableTitle(_ title: String) -> String {
    title
        .replacingOccurrences(of: ".", with: ".\u{200B}")
        .replacingOccurrences(of: "_", with: "_\u{200B}")
        .replacingOccurrences(of: "-", with: "-\u{200B}")
}

struct DownloadedMetadataLine: View {
    let text: String?
    var isDownloaded: Bool
    var font: Font
    var iconSize: CGFloat = 11
    var spacing: CGFloat = 4

    private var hasText: Bool {
        guard let text else { return false }
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        if isDownloaded || hasText {
            HStack(spacing: spacing) {
                if isDownloaded {
                    DownloadStatusIcon(size: iconSize)
                }

                if let text, hasText {
                    Text(text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .font(font)
            .foregroundColor(.secondary)
        }
    }
}

// MARK: - Shared Views

struct MediaCollectionEmptyStateCard: View {
    enum Density {
        case compact
        case regular
    }

    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var density: Density = .regular

    private var iconFrame: CGFloat {
        density == .compact ? 44 : 56
    }

    private var iconFont: CGFloat {
        density == .compact ? 28 : 34
    }

    private var verticalPadding: CGFloat {
        density == .compact ? 16 : 24
    }

    private var titleFont: Font {
        density == .compact ? .body.weight(.medium) : .headline
    }

    var body: some View {
        VStack(spacing: density == .compact ? 10 : 12) {
            Image(systemName: systemImage)
                .font(.system(size: iconFont, weight: .regular))
                .foregroundColor(Color(UIColor.tertiaryLabel))
                .frame(width: iconFrame, height: iconFrame)

            Text(title)
                .font(titleFont)
                .foregroundColor(Color(UIColor.secondaryLabel))

            if let subtitle = subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(Color(UIColor.tertiaryLabel))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, verticalPadding)
    }
}

struct FileGridItemView: View {
    let file: VideoFile
    let isSelected: Bool
    let isSelectionMode: Bool
    var markers: [String] = []
    var loadsPreviewThumbnails: Bool = true
    @ObservedObject private var historyService = HistoryService.shared

    private var isPhone: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    private var iconSide: CGFloat {
        isPhone ? 66 : 80
    }

    private var tileSide: CGFloat {
        isPhone ? 92 : 110
    }

    private var badgeIconSize: CGFloat {
        isPhone ? 14 : 16
    }

    private var selectionBadgeSide: CGFloat {
        isPhone ? 18 : 20
    }

    private var titleFont: Font {
        isPhone ? .system(size: 12, weight: .medium) : .caption.weight(.medium)
    }

    private var detailFont: Font {
        .system(size: isPhone ? 10 : 11)
    }

    private var showsFavoriteMarker: Bool {
        markers.contains("star.fill")
    }

    private var showsDownloadedMarker: Bool {
        markers.contains("arrow.down.circle.fill")
    }

    private var showsPrivacyLockMarker: Bool {
        markers.contains("lock") || markers.contains("lock.fill") || markers.contains("lock.open") || markers.contains("lock.open.fill")
    }

    private var privacyMarkerIconName: String {
        markers.contains("lock.open.fill") || markers.contains("lock.open") ? "lock.open" : "lock"
    }

    var body: some View {
        VStack(spacing: isPhone ? 3 : 4) {
            ZStack {
                ZStack(alignment: .topTrailing) {
                    FileThumbnailCoreView(
                        file: file,
                        iconSide: (file.usesPreviewThumbnailStyle || file.type == .folder) ? tileSide : iconSide,
                        usesDecorativeBackgroundForNonPreview: file.type != .folder,
                        loadsPreviewThumbnails: loadsPreviewThumbnails
                    )
                    .frame(width: tileSide, height: tileSide)
                    .background((file.usesPreviewThumbnailStyle || file.type == .folder) ? Color.clear : Color(UIColor.secondarySystemBackground))
                    .cornerRadius((file.usesPreviewThumbnailStyle || file.type == .folder) ? 0 : (isPhone ? 10 : 12))

                    if showsFavoriteMarker {
                        Image(systemName: "star.fill")
                            .font(.system(size: badgeIconSize))
                            .foregroundColor(.yellow)
                            .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                            .padding(.top, isPhone ? 5 : 6)
                            .padding(.trailing, isPhone ? 5 : 6)
                    }
                }

                if isSelectionMode {
                    ZStack {
                        Circle()
                            .fill(isSelected ? Color.blue : Color.black.opacity(0.18))
                        Circle()
                            .stroke(isSelected ? Color.blue : Color.white.opacity(0.95), lineWidth: 1.5)
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: isPhone ? 8 : 9, weight: .bold))
                                .foregroundColor(.white)
                        }
                    }
                    .frame(width: selectionBadgeSide, height: selectionBadgeSide)
                    .padding(.top, isPhone ? 5 : 6)
                    .padding(.trailing, isPhone ? 5 : 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                } else {
                    let displayMarkers = markers.filter {
                        $0 != "star.fill" &&
                        $0 != "arrow.down.circle.fill" &&
                        $0 != "lock" &&
                        $0 != "lock.fill" &&
                        $0 != "lock.open" &&
                        $0 != "lock.open.fill"
                    }
                    ZStack {
                        if showsPrivacyLockMarker {
                            Image(systemName: privacyMarkerIconName)
                                .font(.system(size: isPhone ? 11 : 12, weight: .bold))
                                .foregroundColor(.white)
                                .padding(isPhone ? 6 : 7)
                                .background(Color.black.opacity(0.4))
                                .clipShape(Circle())
                                .padding(.bottom, isPhone ? 5 : 6)
                                .padding(.leading, isPhone ? 5 : 6)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }

                        if !displayMarkers.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(displayMarkers, id: \.self) { marker in
                                    Image(systemName: marker)
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(8)
                            .padding(.top, showsFavoriteMarker ? (isPhone ? 28 : 32) : (isPhone ? 5 : 6))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        }

                        if file.showsPreviewIndicatorBadge {
                            MediaIndicatorBadge(
                                file: file,
                                playbackSnapshot: playbackProgressSnapshot,
                                diameter: 18,
                                iconSize: 9,
                                usesDarkBackground: true
                            )
                            .padding(.bottom, isPhone ? 8 : 9)
                            .padding(.trailing, isPhone ? 8 : 9)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        }
                    }
                }
            }
            .frame(width: tileSide, height: tileSide)

            VStack(spacing: 2) {
                Text(file.name)
                    .font(titleFont)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)

                if file.type == .folder, let count = file.itemCount {
                    Text("\(count) \(NSLocalizedString("items", comment: ""))")
                        .font(detailFont)
                        .foregroundColor(.secondary)
                } else {
                    HStack(spacing: 4) {
                        if showsDownloadedMarker {
                            DownloadStatusIcon(size: isPhone ? 10 : 11)
                        }

                        Text(gridMetadataLine)
                            .lineLimit(1)
                    }
                    .font(detailFont)
                    .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: tileSide + (isPhone ? 4 : 0))
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        guard file.type == .video || file.type == .audio else {
            return nil
        }
        return historyService.playbackProgressSnapshot(matching: file)
    }

    private var gridMetadataLine: String {
        let parts = [file.formattedDurationText, file.displaySizeText].compactMap { $0 }
        return parts.isEmpty ? file.formattedListDate : parts.joined(separator: " · ")
    }
}

struct FileListItemView: View {
    let file: VideoFile
    let isSelected: Bool
    let isSelectionMode: Bool
    var markers: [String] = []
    var loadsPreviewThumbnails: Bool = true
    @ObservedObject private var historyService = HistoryService.shared

    private let iconSide: CGFloat = 40
    private let rowSpacing: CGFloat = 12
    private let verticalPadding: CGFloat = 5

    private var showsFavoriteMarker: Bool {
        markers.contains("star.fill")
    }

    private var showsDownloadedMarker: Bool {
        markers.contains("arrow.down.circle.fill")
    }

    private var showsPrivacyLockMarker: Bool {
        markers.contains("lock") || markers.contains("lock.fill") || markers.contains("lock.open") || markers.contains("lock.open.fill")
    }

    private var privacyMarkerIconName: String {
        markers.contains("lock.open.fill") || markers.contains("lock.open") ? "lock.open" : "lock"
    }

    var body: some View {
        HStack(spacing: rowSpacing) {
            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(isSelected ? .blue : .secondary.opacity(0.5))
                    .font(.title2)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            ZStack {
                ZStack(alignment: .topTrailing) {
                    FileThumbnailCoreView(
                        file: file,
                        iconSide: iconSide,
                        usesDecorativeBackgroundForNonPreview: true,
                        loadsPreviewThumbnails: loadsPreviewThumbnails
                    )

                    if showsFavoriteMarker {
                        Image(systemName: "star.fill")
                            .font(.system(size: 13))
                            .foregroundColor(.yellow)
                            .shadow(color: .black.opacity(0.3), radius: 1, x: 0, y: 1)
                            .offset(x: 5, y: -5)
                    }
                }

                if !isSelectionMode {
                    let displayMarkers = markers.filter {
                        $0 != "star.fill" &&
                        $0 != "arrow.down.circle.fill" &&
                        $0 != "lock" &&
                        $0 != "lock.fill" &&
                        $0 != "lock.open" &&
                        $0 != "lock.open.fill"
                    }
                    ZStack {
                        if showsPrivacyLockMarker {
                            Image(systemName: privacyMarkerIconName)
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.white)
                                .padding(4)
                                .background(Color.black.opacity(0.4))
                                .clipShape(Circle())
                                .offset(x: 4, y: -4)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        }

                        if !displayMarkers.isEmpty {
                            HStack(spacing: 2) {
                                ForEach(displayMarkers, id: \.self) { marker in
                                    Image(systemName: marker)
                                        .font(.system(size: 7, weight: .bold))
                                        .foregroundColor(.white)
                                }
                            }
                            .padding(.horizontal, 3.5)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.65))
                            .cornerRadius(5)
                            .offset(x: 5, y: showsFavoriteMarker ? 9 : -5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        }

                        if file.showsPreviewIndicatorBadge {
                            MediaIndicatorBadge(
                                file: file,
                                playbackSnapshot: playbackProgressSnapshot,
                                diameter: 15,
                                iconSize: 8,
                                usesDarkBackground: false
                            )
                            .offset(x: 4, y: 4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        }
                    }
                }
            }
            .frame(width: iconSide, height: iconSide)

            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.system(.body, design: .default))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if showsDownloadedMarker {
                        DownloadStatusIcon(size: 11)
                    }

                    if file.type == .folder {
                        Text(file.formattedListDate)
                        if let count = file.itemCount {
                            Text("·")
                            Text(String(format: NSLocalizedString("%d items", comment: ""), count))
                        }
                    } else {
                        Text(file.formattedListDate)
                        if let durationText = file.formattedDurationText {
                            Text("·")
                            Text(durationText)
                        }
                        if let sizeText = file.displaySizeText {
                            Text("·")
                            Text(sizeText)
                        }
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, verticalPadding)
        .padding(.horizontal, 2)
        .contentShape(Rectangle())
        .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        .cornerRadius(8)
        .animation(.default, value: isSelectionMode)
        .animation(.default, value: isSelected)
    }

    private var playbackProgressSnapshot: PlaybackProgressSnapshot? {
        guard file.type == .video || file.type == .audio else {
            return nil
        }
        return historyService.playbackProgressSnapshot(matching: file)
    }
}
