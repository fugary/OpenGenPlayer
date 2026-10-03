import SwiftUI
import AVFoundation

struct PlaylistView: View {
    @ObservedObject var playbackService: VLCPlaybackService
    @ObservedObject var historyService = HistoryService.shared
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    @Binding var showPlaylist: Bool
    var playlist: [VideoFile]
    var onSelect: (Int) -> Void
    @State private var downloadToastMessage: String?

    private var currentPlayingIndex: Int? {
        guard let currentURL = playbackService.state.currentItem?.url else {
            return nil
        }
        return playlist.firstIndex(where: { playlistURLsMatch($0.url, currentURL) })
    }
    
    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(playlist.indices), id: \.self) { index in
                            let file = playlist[index]
                            let isPlaying: Bool = {
                                guard let currentURL = playbackService.state.currentItem?.url else {
                                    return false
                                }
                                return playlistURLsMatch(file.url, currentURL)
                            }()

                            PlaylistRow(
                                file: file,
                                isPlaying: isPlaying,
                                index: index,
                                formatTime: formatTime,
                                playbackService: playbackService,
                                onQueueDownload: queueDownload
                            )
                            .id(index)
                            .onTapGesture {
                                onSelect(index)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 30)
                    .padding(.top, 16)
                }
                .onAppear {
                    scrollToCurrentItem(using: proxy, animated: false)
                }
                .onChange(of: currentPlayingIndex) { _ in
                    scrollToCurrentItem(using: proxy, animated: true)
                }
            }
            .background(Color(UIColor.tertiarySystemBackground).ignoresSafeArea())
            .preferredColorScheme(.dark)
            .navigationTitle(NSLocalizedString("Playlist", comment: ""))
            .navigationBarItems(trailing: Button(action: {
                showPlaylist = false
            }) {
                AppToolbarIcon(systemName: "xmark", style: .secondary)
            })
        }
        .floatingToast(message: $downloadToastMessage)
    }

    private func scrollToCurrentItem(using proxy: ScrollViewProxy, animated: Bool) {
        guard let currentPlayingIndex else {
            return
        }

        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.22)) {
                    proxy.scrollTo(currentPlayingIndex, anchor: .center)
                }
            } else {
                proxy.scrollTo(currentPlayingIndex, anchor: .center)
            }
        }
    }
    
    private func formatTime(_ seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    private func queueDownload(file: VideoFile) {
        guard file.isRemote,
              let server = file.resolvedServer else {
            return
        }

        if let remoteItemId = file.jellyfinItemId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteItemId.isEmpty {
            switch downloadCenter.taskStatus(serverId: server.id, remoteItemId: remoteItemId) {
            case .queued, .downloading, .paused, .completed:
                downloadToastMessage = NSLocalizedString("Already in Download Queue", comment: "")
                return
            default:
                break
            }

            let enqueued = downloadCenter.enqueueMediaDownload(
                server: server,
                remoteItemId: remoteItemId,
                fileName: file.name,
                totalBytes: file.serverSize ?? (file.size > 0 ? file.size : nil),
                displayTitle: file.name
            )
            downloadToastMessage = enqueued
                ? NSLocalizedString("Added to Download Queue", comment: "")
                : NSLocalizedString("Already in Download Queue", comment: "")
            return
        }

        let remotePath = (file.serverPath?.isEmpty == false ? file.serverPath! : file.url.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remotePath.isEmpty else { return }

        switch downloadCenter.taskStatus(serverId: server.id, remotePath: remotePath) {
        case .queued, .downloading, .paused, .completed:
            downloadToastMessage = NSLocalizedString("Already in Download Queue", comment: "")
            return
        default:
            break
        }

        downloadCenter.enqueueDownload(
            server: server,
            remotePath: remotePath,
            fileName: file.name,
            totalBytes: file.serverSize ?? (file.size > 0 ? file.size : nil),
            displayTitle: file.name
        )
        downloadToastMessage = NSLocalizedString("Added to Download Queue", comment: "")
    }
}

struct PlaylistRow: View {
    let file: VideoFile
    let isPlaying: Bool
    let index: Int
    let formatTime: (Int) -> String
    @ObservedObject var playbackService: VLCPlaybackService
    @ObservedObject private var downloadCenter = DownloadCenterService.shared
    var onQueueDownload: (VideoFile) -> Void

    @State private var progress: Double = 0
    @State private var lastPosition: Double = 0
    @State private var duration: Double = 0
    @State private var resolvedFileSize: Int64 = 0
    @State private var resolvedResolution: String?
    @State private var resolvedBitrate: Int?
    @State private var resolvedCodec: String?
    @State private var resolvedChannelLayout: String?
    @State private var didRequestLocalMetadata = false

    private var currentPlayingItem: MediaItem? {
        let current = playbackService.state.currentItem
        guard let current, playlistURLsMatch(current.url, file.url) else { return nil }
        return current
    }

    private var effectiveDuration: Double {
        if duration > 0 { return duration }
        if let fileDuration = file.duration, fileDuration > 0 { return fileDuration }
        if currentPlayingItem != nil, playbackService.state.duration > 0 {
            return playbackService.state.duration
        }
        return 0
    }

    private var progressText: String {
        let knownDuration = effectiveDuration
        if knownDuration > 0 {
            if lastPosition > 0 {
                return "\(formatTime(Int(lastPosition))) / \(formatTime(Int(knownDuration)))"
            }
            return formatTime(Int(knownDuration))
        }
        return NSLocalizedString("Unknown Duration", comment: "")
    }

    private var secondaryMetadataLine: String {
        let segments = metadataSegments
        return segments.joined(separator: " · ")
    }

    private var metadataSegments: [String] {
        var segments: [String] = []
        segments.append(file.type == .audio ? NSLocalizedString("Audio", comment: "") : NSLocalizedString("Video", comment: ""))

        if let codec = resolvedCodecText {
            segments.append(codec)
        }
        if let resolution = resolvedResolutionText {
            segments.append(resolution)
        }
        if let channelLayout = resolvedChannelLayoutText {
            segments.append(channelLayout)
        }
        if let container = resolvedContainerText {
            segments.append(container)
        }
        if let bitrate = resolvedBitrateText {
            segments.append(bitrate)
        }
        if let fileSize = resolvedFileSizeText {
            segments.append(fileSize)
        }

        return segments
    }

    private var resolvedContainerText: String? {
        let rawValue = currentPlayingItem?.serverContainer ?? file.serverContainer ?? file.url.pathExtension
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.uppercased()
    }

    private var resolvedFileSizeText: String? {
        let size = currentPlayingItem?.serverSize ?? file.serverSize ?? (resolvedFileSize > 0 ? resolvedFileSize : file.size)
        guard size > 0 else { return nil }
        return formatBytes(size)
    }

    private var resolvedResolutionText: String? {
        if let current = currentPlayingItem,
           let streams = current.serverMediaStreams,
           let value = videoResolution(from: streams) {
            return value
        }
        if let streams = file.serverMediaStreams,
           let value = videoResolution(from: streams) {
            return value
        }
        if let explicit = resolvedResolution, !explicit.isEmpty {
            return explicit
        }
        if isPlaying {
            let videoSize = playbackService.videoNaturalSize
            if videoSize.width > 0, videoSize.height > 0 {
                return "\(Int(videoSize.width))×\(Int(videoSize.height))"
            }
        }
        return nil
    }

    private var resolvedCodecText: String? {
        if let current = currentPlayingItem,
           let streams = current.serverMediaStreams,
           let value = preferredCodec(from: streams) {
            return value
        }
        if let streams = file.serverMediaStreams,
           let value = preferredCodec(from: streams) {
            return value
        }
        guard let codec = resolvedCodec, !codec.isEmpty else { return nil }
        return codec.uppercased()
    }

    private var resolvedChannelLayoutText: String? {
        if file.type != .audio { return nil }
        if let current = currentPlayingItem,
           let streams = current.serverMediaStreams,
           let value = preferredChannelLayout(from: streams) {
            return value
        }
        if let streams = file.serverMediaStreams,
           let value = preferredChannelLayout(from: streams) {
            return value
        }
        return resolvedChannelLayout
    }

    private var resolvedBitrateText: String? {
        let bitrate = preferredBitrate()
        guard bitrate > 0 else { return nil }
        return bitrate >= 1_000_000
            ? String(format: "%.1f Mbps", Double(bitrate) / 1_000_000.0)
            : "\(max(1, bitrate / 1000)) kbps"
    }

    private var downloadState: DownloadTaskStatus? {
        guard let server = resolvedDownloadServer else {
            return nil
        }

        if let remoteItemId = file.jellyfinItemId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !remoteItemId.isEmpty,
           let itemStatus = downloadCenter.taskStatus(serverId: server.id, remoteItemId: remoteItemId) {
            return itemStatus
        }

        let remotePath = (file.serverPath?.isEmpty == false ? file.serverPath! : file.url.path)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remotePath.isEmpty else { return nil }
        return downloadCenter.taskStatus(serverId: server.id, remotePath: remotePath)
    }

    private var resolvedDownloadServer: ServerConfig? {
        if let resolved = file.resolvedServer {
            return resolved
        }

        guard let serverIdString = file.jellyfinServerId,
              let serverId = UUID(uuidString: serverIdString) else {
            return nil
        }

        return AppNetworkService.shared.servers.first(where: { $0.id == serverId })
    }

    private var canQueueDownload: Bool {
        guard file.isRemote else { return false }
        switch downloadState {
        case .queued, .downloading, .paused, .completed:
            return false
        default:
            return true
        }
    }

    private var downloadButtonIcon: String {
        switch downloadState {
        case .completed:
            return "arrow.down.circle.fill"
        case .queued, .downloading, .paused:
            return "arrow.down.circle.fill"
        default:
            return "arrow.down.circle"
        }
    }

    private var downloadButtonColor: Color {
        switch downloadState {
        case .completed:
            return .green
        case .queued, .downloading, .paused:
            return .orange
        default:
            return .white.opacity(0.78)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isPlaying ? Color.white.opacity(0.2) : Color.white.opacity(0.1))
                    .frame(width: 48, height: 48)

                if let thumbnailURL = file.thumbnailURL {
                    RemoteImage(
                        url: thumbnailURL,
                        sourceFile: file,
                        placeholderSystemImage: file.type == .audio ? "music.note" : "video.fill",
                        placeholderTint: isPlaying ? .white : .white.opacity(0.7)
                    )
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Image(systemName: file.type == .audio ? "music.note" : "video.fill")
                        .font(.system(size: 20))
                        .foregroundColor(isPlaying ? .white : .white.opacity(0.7))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(file.name)
                    .font(.system(.body, design: .rounded))
                    .fontWeight(isPlaying ? .semibold : .regular)
                    .foregroundColor(.white)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    if effectiveDuration > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color.white.opacity(0.2))
                                    .frame(height: 3)
                                Capsule()
                                    .fill(isPlaying ? Color.white : Color.white.opacity(0.5))
                                    .frame(width: geo.size.width * CGFloat(min(progress, 1.0)), height: 3)
                            }
                        }
                        .frame(width: 80, height: 3)
                    }

                    Text(progressText)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(effectiveDuration > 0 ? .white.opacity(0.72) : .white.opacity(0.5))
                        .lineLimit(1)
                }

                if !secondaryMetadataLine.isEmpty {
                    Text(secondaryMetadataLine)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundColor(.white.opacity(0.55))
                        .lineLimit(2)
                }
            }

            Spacer()

            HStack(spacing: 10) {
                if file.isRemote && canQueueDownload {
                    Button(action: {
                        onQueueDownload(file)
                    }) {
                        Image(systemName: downloadButtonIcon)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(downloadButtonColor)
                    }
                    .buttonStyle(PlainButtonStyle())
                } else if let downloadState {
                    Image(systemName: downloadButtonIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(downloadButtonColor)
                        .opacity(downloadState == .completed ? 1.0 : 0.9)
                }

                if isPlaying {
                    Image(systemName: "waveform")
                        .foregroundColor(.white)
                        .font(.system(size: 12))
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isPlaying ? Color.white.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onAppear {
            loadProgress()
            loadSupplementalMetadataIfNeeded()
        }
        .onChange(of: playbackService.state.duration) { _ in
            if isPlaying {
                loadProgress()
            }
        }
    }

    private func loadProgress() {
        DispatchQueue.main.async {
            let url = file.url

            if let pos = HistoryService.shared.getLastPlayedPosition(for: url), pos > 0 {
                self.lastPosition = pos

                if let histFile = HistoryService.shared.allHistory.first(where: { playlistURLsMatch($0.url, url) }),
                   let dur = histFile.duration,
                   dur > 0 {
                    self.duration = dur
                    self.progress = pos / dur
                } else if let fileDur = file.duration, fileDur > 0 {
                    self.duration = fileDur
                    self.progress = pos / fileDur
                } else if let currentURL = playbackService.state.currentItem?.url,
                          playlistURLsMatch(currentURL, url),
                          playbackService.maxDuration > 0 {
                    self.duration = playbackService.maxDuration
                    self.progress = pos / playbackService.maxDuration
                }
            } else if let fileDur = file.duration, fileDur > 0 {
                self.duration = fileDur
                if let pos = file.lastPlayedPosition {
                    self.lastPosition = pos
                    self.progress = pos / fileDur
                }
            } else if let currentURL = playbackService.state.currentItem?.url,
                      playlistURLsMatch(currentURL, url),
                      playbackService.maxDuration > 0 {
                self.duration = playbackService.maxDuration
                let currentTime = playbackService.state.currentTime
                self.lastPosition = currentTime
                self.progress = currentTime / playbackService.maxDuration
            }
        }
    }

    private func loadSupplementalMetadataIfNeeded() {
        guard !didRequestLocalMetadata else { return }
        didRequestLocalMetadata = true

        if let streams = file.serverMediaStreams {
            resolvedResolution = videoResolution(from: streams)
            resolvedBitrate = firstRelevantBitrate(from: streams)
            resolvedCodec = preferredCodec(from: streams)
            resolvedChannelLayout = preferredChannelLayout(from: streams)
        }

        let knownSize = file.serverSize ?? file.size
        if knownSize > 0 {
            resolvedFileSize = knownSize
        }

        guard file.url.isFileURL else { return }

        DispatchQueue.global(qos: .utility).async {
            let resourceValues = try? file.url.resourceValues(forKeys: [.fileSizeKey])
            let localSize = Int64(resourceValues?.fileSize ?? 0)

            let asset = AVURLAsset(url: file.url)
            let assetDuration = asset.duration.seconds

            var resolution: String?
            var codec: String?
            var bitrate: Int?
            var channelLayout: String?

            if file.type == .video, let videoTrack = asset.tracks(withMediaType: .video).first {
                let transformedSize = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
                let width = Int(abs(transformedSize.width))
                let height = Int(abs(transformedSize.height))
                if width > 0 && height > 0 {
                    resolution = "\(width)×\(height)"
                }
                bitrate = Int(videoTrack.estimatedDataRate)
                if let formatDescription = videoTrack.formatDescriptions.first {
                    codec = codecDescription(from: formatDescription)
                }
            } else if file.type == .audio, let audioTrack = asset.tracks(withMediaType: .audio).first {
                bitrate = Int(audioTrack.estimatedDataRate)
                if let formatDescription = audioTrack.formatDescriptions.first {
                    codec = codecDescription(from: formatDescription)
                    channelLayout = audioChannelLayout(from: formatDescription)
                }
            }

            DispatchQueue.main.async {
                if self.resolvedFileSize == 0, localSize > 0 {
                    self.resolvedFileSize = localSize
                }
                if self.duration <= 0, assetDuration.isFinite, assetDuration > 0 {
                    self.duration = assetDuration
                    if self.lastPosition > 0 {
                        self.progress = self.lastPosition / assetDuration
                    }
                }
                if self.resolvedResolution == nil {
                    self.resolvedResolution = resolution
                }
                if self.resolvedBitrate == nil, let bitrate {
                    self.resolvedBitrate = bitrate
                }
                if self.resolvedCodec == nil, let codec {
                    self.resolvedCodec = codec
                }
                if self.resolvedChannelLayout == nil, let channelLayout {
                    self.resolvedChannelLayout = channelLayout
                }
            }
        }
    }

    private func preferredBitrate() -> Int {
        if let current = currentPlayingItem,
           let streams = current.serverMediaStreams,
           let bitrate = firstRelevantBitrate(from: streams) {
            return bitrate
        }
        if let streams = file.serverMediaStreams,
           let bitrate = firstRelevantBitrate(from: streams) {
            return bitrate
        }
        if let resolvedBitrate, resolvedBitrate > 0 {
            return resolvedBitrate
        }
        if let bitrate = currentPlayingItem?.serverBitrate, bitrate > 0 {
            return bitrate
        }
        return file.serverBitrate ?? 0
    }

    private func videoResolution(from streams: [[String: Any]]) -> String? {
        guard let stream = streams.first(where: { (($0["Type"] as? String) ?? "").caseInsensitiveCompare("Video") == .orderedSame }) else {
            return nil
        }
        guard let width = stream["Width"] as? Int,
              let height = stream["Height"] as? Int,
              width > 0,
              height > 0 else {
            return nil
        }
        return "\(width)×\(height)"
    }

    private func preferredCodec(from streams: [[String: Any]]) -> String? {
        let streamType = file.type == .audio ? "Audio" : "Video"
        guard let stream = streams.first(where: { (($0["Type"] as? String) ?? "").caseInsensitiveCompare(streamType) == .orderedSame }) else {
            return nil
        }
        guard let codec = stream["Codec"] as? String, !codec.isEmpty else {
            return nil
        }
        return codec.uppercased()
    }

    private func preferredChannelLayout(from streams: [[String: Any]]) -> String? {
        guard let stream = streams.first(where: { (($0["Type"] as? String) ?? "").caseInsensitiveCompare("Audio") == .orderedSame }) else {
            return nil
        }
        if let layout = stream["ChannelLayout"] as? String, !layout.isEmpty {
            return layout
        }
        if let channels = stream["Channels"] as? Int, channels > 0 {
            return "\(channels) ch"
        }
        return nil
    }

    private func firstRelevantBitrate(from streams: [[String: Any]]) -> Int? {
        let preferredTypes = file.type == .audio ? ["Audio"] : ["Video", "Audio"]
        for preferredType in preferredTypes {
            if let stream = streams.first(where: { (($0["Type"] as? String) ?? "").caseInsensitiveCompare(preferredType) == .orderedSame }),
               let bitrate = stream["BitRate"] as? Int,
               bitrate > 0 {
                return bitrate
            }
        }
        return nil
    }

    private func codecDescription(from formatDescription: Any) -> String? {
        let mediaSubType = CMFormatDescriptionGetMediaSubType(formatDescription as! CMFormatDescription)
        let bigEndian = CFSwapInt32HostToBig(mediaSubType)
        let scalars = [
            (bigEndian >> 24) & 0xFF,
            (bigEndian >> 16) & 0xFF,
            (bigEndian >> 8) & 0xFF,
            bigEndian & 0xFF
        ].compactMap(UnicodeScalar.init)
        let raw = String(String.UnicodeScalarView(scalars))
        let trimmed = raw.trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
        return trimmed.isEmpty ? nil : trimmed.uppercased()
    }

    private func audioChannelLayout(from formatDescription: Any) -> String? {
        let description = formatDescription as! CMAudioFormatDescription
        guard let basicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee else {
            return nil
        }
        let channelCount = Int(basicDescription.mChannelsPerFrame)
        guard channelCount > 0 else { return nil }
        return channelCount == 1 ? "Mono" : channelCount == 2 ? "Stereo" : "\(channelCount) ch"
    }
}

private func normalizedPlaylistRemotePath(_ rawPath: String) -> String {
    let decoded = rawPath.removingPercentEncoding ?? rawPath
    let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "/" }

    var normalized = trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    normalized = normalized.replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
    while normalized.count > 1 && normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    return normalized
}

private func playlistURLsMatch(_ lhs: URL, _ rhs: URL) -> Bool {
    if lhs == rhs {
        return true
    }

    if lhs.isFileURL || rhs.isFileURL {
        return lhs.standardizedFileURL.path == rhs.standardizedFileURL.path
    }

    let lhsScheme = lhs.scheme?.lowercased() ?? ""
    let rhsScheme = rhs.scheme?.lowercased() ?? ""
    guard lhsScheme == rhsScheme else {
        return false
    }

    return normalizedPlaylistRemotePath(lhs.path) == normalizedPlaylistRemotePath(rhs.path)
}
