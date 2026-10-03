#if os(macOS)
import Foundation
import GenPlayerCore
import VLCKit

extension MacVLCPlaybackService {
    func prepareMPVRemoteSidecars(for file: VideoFile) {
        let sources = file.externalSubtitleCandidates.map(\.url).filter {
            ["smb", "ftp", "ftps", "sftp", "nfs"].contains($0.scheme?.lowercased() ?? "")
        }
        guard !sources.isEmpty, let engine = mpvEngine else { return }
        let generation = translationPlaybackGeneration
        mpvSidecarTask = Task { @MainActor [weak self, weak engine] in
            for source in sources {
                guard let self, !Task.isCancelled else { return }
                guard let local = await self.cacheRemoteSubtitleToLocalIfNeeded(source, item: file) else { continue }
                guard !Task.isCancelled, self.translationPlaybackGeneration == generation, let engine else {
                    try? FileManager.default.removeItem(at: local); return
                }
                engine.addCachedSubtitle(local, source: source)
            }
        }
    }

    private func cacheRemoteSubtitleToLocalIfNeeded(_ url: URL, item: VideoFile? = nil) async -> URL? {
        let sourceServer = (item ?? currentFile).flatMap { embeddedSubtitleServer(for: $0) }
        let urlString = url.absoluteString
        let hasTokenInQuery = urlString.contains("api_key=") ||
                              urlString.contains("X-Emby-Token=") ||
                              urlString.contains("X-MediaBrowser-Token=") ||
                              urlString.contains("X-Plex-Token=")
        
        if url.scheme?.lowercased() == "http" || url.scheme?.lowercased() == "https", hasTokenInQuery {
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    return nil
                }
                let ext = url.pathExtension.isEmpty ? "srt" : url.pathExtension
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                try data.write(to: tempURL)
                return tempURL
            } catch {
                print("[MacVLCPlaybackService] Direct download failed: \(error)")
            }
        }
        
        if let server = sourceServer {
            do {
                let path: String
                if server.type == .jellyfin || server.type == .emby || server.type == .plex {
                    path = url.absoluteString
                } else {
                    path = url.path.removingPercentEncoding ?? url.path
                }
                guard !path.isEmpty else { return nil }
                let downloadedURL = try await AppNetworkService.shared.downloadFile(server: server, at: path)
                let ext = url.pathExtension.isEmpty ? "srt" : url.pathExtension
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                try FileManager.default.copyItem(at: downloadedURL, to: tempURL)
                return tempURL
            } catch {
                print("[MacVLCPlaybackService] Failed to download remote subtitle via AppNetworkService: \(error)")
            }
        }
        
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return nil
            }
            let ext = url.pathExtension.isEmpty ? "srt" : url.pathExtension
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try data.write(to: tempURL)
            return tempURL
        } catch {
            return nil
        }
    }

    private static var secondarySubtitleTimelineCache: [String: SubtitleTimeline] = [:]
    private static var secondarySubtitleTimelineCacheOrder: [String] = []
    private static let secondarySubtitleTimelineCacheLimit = 10

    internal func mediaKey(for url: URL?) -> String? {
        guard let url else { return nil }
        return url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }
    
    internal func subtitleURLKey(_ url: URL) -> String {
        url.isFileURL ? url.standardizedFileURL.path : url.absoluteString
    }

    private func stableHashHex(for input: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(format: "%016llx", hash)
    }

    private func normalizeServerHost(_ urlString: String) -> String {
        guard let url = URL(string: urlString), let host = url.host else {
            return urlString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        return host
    }

    func clearSecondarySubtitleTrack(persistPreference: Bool = false) {
        clearMPVSecondarySelection(persistPreference: persistPreference)
        if subtitleTranslation.enabled && !(audioSubtitles.isConfigured && audioSubtitles.translatesAudio) { subtitleTranslation.setEnabled(false) }
        secondarySubtitleLoadTask?.cancel()
        secondarySubtitleLoadTask = nil
        secondarySubtitleTimeline = nil
        currentSecondarySubtitleTrackID = nil
        secondarySubtitleStatus = .idle
        currentSecondarySubtitleParts = []

        if persistPreference,
           let item = currentFile {
            
        }
    }

    func refreshSecondarySubtitleTracks() {
        guard !isUsingMPV else { return }
        guard let item = currentFile else {
            secondarySubtitleTracks = []
            clearSecondarySubtitleTrack()
            return
        }

        let tracks = availableSecondarySubtitleTracks(for: item)
        if secondarySubtitleTracks != tracks {
            secondarySubtitleTracks = tracks
        }

        if let selectedID = currentSecondarySubtitleTrackID, selectedID != MacSubtitleTranslation.trackID, selectedID != MacAudioSubtitlePlan.secondaryID {
            if !tracks.contains(where: { $0.id == selectedID }) {
                clearSecondarySubtitleTrack()
            }
        }

        restorePendingSecondarySubtitleSelectionIfNeeded()
        refreshPrimarySubtitleTranslation()
    }

    internal func refreshPrimarySubtitleTranslation() {
        guard subtitleTranslation.enabled else { return }
        if audioSubtitles.isConfigured && audioSubtitles.hasActiveOutput {
            if audioSubtitles.translatesAudio { followGeneratedPrimaryTranslation() }
            return
        }
        guard UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta") else {
            setSecondarySubtitleTrack(nil)
            return
        }
        if audioSubtitles.display == .translatedSecondary {
            followGeneratedPrimaryTranslation()
            return
        }
        guard currentSubtitleTrackID != -1, let item = currentFile else {
            pendingPrimarySubtitleTranslationRestore = currentFile.map(storedPrimarySubtitleTranslationPreference) ?? false
            setSecondarySubtitleTrack(nil, persistTranslationPreference: false)
            return
        }
        if currentSubtitleTrackID == MacAudioSubtitlePlan.primaryID {
            followGeneratedPrimaryTranslation()
            return
        }
        if isUsingMPV {
            guard let track = mpvTracks.first(where: { $0.type == "sub" && $0.id == currentSubtitleTrackID }) else { return }
            guard !track.isBitmap else { subtitleTranslation.clearSource(status: "Translation.Bitmap"); return }
            let key = "\(translationPlaybackGeneration)|mpv|\(track.id)|\(primaryServerSubtitleTracks[track.id]?.id ?? "")"
            if mpvTranslationSourceKey != key {
                mpvTranslationSourceKey = key
                mpvTranslationSourceIsPartial = false
                mpvTranslationUsesDecodedText = false
            }
            if mpvTranslationUsesDecodedText {
                followMPVDecodedTranslation(key: key, language: track.language)
                return
            }
            let source = mpvBrowserSource(track: track, item: item, id: key, title: "", offset: 0)
            subtitleTranslation.follow(key: key, language: track.language) { [weak self] in
                do {
                    let document = try await source.load()
                    try Task.checkCancellation()
                    guard !document.entries.isEmpty else { throw SubtitleBrowserError.unreadable }
                    guard let self, self.mpvTranslationSourceKey == key else { throw CancellationError() }
                    self.mpvTranslationSourceIsPartial = document.isPartial
                    return SubtitleTimeline(parts: document.entries.map {
                        SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text))
                    })
                } catch {
                    try Task.checkCancellation()
                    guard let self, self.mpvTranslationSourceKey == key,
                          self.subtitleTranslation.enabled else { throw CancellationError() }
                    self.mpvTranslationUsesDecodedText = true
                    self.mpvTranslationSourceIsPartial = true
                    self.followMPVDecodedTranslation(key: key, language: track.language)
                    // The replacement source owns the model now; don't publish the old read error.
                    throw CancellationError()
                }
            }
            return
        }
        guard let track = primarySubtitleTranslationTrack(for: item) else {
            subtitleTranslation.clearSource(status: "Translation.Unreadable")
            return
        }
        guard track.isSelectable else {
            subtitleTranslation.clearSource(status: track.supportLevel == .unsupportedBitmap
                ? "Translation.Bitmap" : "Translation.Unreadable")
            return
        }
        let key = "\(translationPlaybackGeneration)|\(currentSubtitleTrackID)|\(track.id)"
        subtitleTranslation.follow(key: key, language: track.language) { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.readPrimaryTranslationTimeline(track: track, item: item)
        }
    }

    private func followMPVDecodedTranslation(key: String, language: String) {
        let decodedKey = "\(translationPlaybackGeneration)|mpv|\(currentSubtitleTrackID)"
        let cues = mpvDecodedSubtitles.key == decodedKey ? mpvDecodedSubtitles.cues : []
        subtitleTranslation.followGenerated(key: key + "|decoded", language: language,
            cues: cues.map { MacAudioSubtitleCue(id: $0.id, start: $0.start, end: $0.end, text: $0.text) })
    }

    private func primarySubtitleTranslationTrack(for item: VideoFile, includeLocalContainer: Bool = true) -> EmbeddedSubtitleTrack? {
        let primaryID = currentSubtitleTrackID
        let nativeID = externalSubtitleResolvedTrackIDs.first(where: {
            nativeToExternalTrackIDs[$0.value] == primaryID
        })?.value ?? primaryID

        if let serverTrack = primaryServerSubtitleTracks[primaryID] { return serverTrack }
        if let imported = translationImportedSubtitleURLs[nativeID] {
            return translationExternalTrack(url: imported, primaryID: primaryID)
        }
        if let url = remoteSecondarySubtitleURLs[primaryID] {
            // Prefer the server descriptor, retaining its language and bitmap support metadata.
            if let match = secondarySubtitleTracks.first(where: { $0.sourceURL == url }) { return match }
            return translationExternalTrack(url: url, primaryID: primaryID)
        }
        if let key = externalSubtitleResolvedTrackIDs.first(where: { $0.value == nativeID })?.key,
           let match = secondarySubtitleTracks.first(where: { $0.sourceURL.map(subtitleURLKey) == key }) {
            return match
        }

        let nativeTracks = subtitleTracks.filter {
            $0.id != -1 && $0.id < 10000 && !$0.isExternal &&
            translationImportedSubtitleURLs[$0.id] == nil && nativeToExternalTrackIDs[$0.id] == nil
        }
        if item.url.isFileURL {
            // Browser view updates must not synchronously inspect the media file.
            guard includeLocalContainer else { return nil }
            let containerTracks = localContainerSecondarySubtitleTracks(for: item)
                .sorted { ($0.streamIndex ?? -1) < ($1.streamIndex ?? -1) }
            // VLC and the extractor enumerate container subtitle streams in container order.
            // Extra sidecar tracks make the mapping ambiguous; never silently choose another track.
            guard containerTracks.count == nativeTracks.count,
                  let ordinal = nativeTracks.firstIndex(where: { $0.id == nativeID }) else { return nil }
            return containerTracks[ordinal]
        }
        // Menu deduplication can merge tracks with colliding VLC/server IDs.
        // Translation needs every original stream, including same-name tracks.
        let serverTracks = embeddedServerSubtitleTracks(for: item).filter { !$0.isExternal }
        guard serverTracks.count == nativeTracks.count,
              let ordinal = nativeTracks.firstIndex(where: { $0.id == nativeID }) else { return nil }
        return serverTracks[ordinal]
    }

    private func translationExternalTrack(url: URL, primaryID: Int) -> EmbeddedSubtitleTrack {
        EmbeddedSubtitleTrack(id: "translation|\(subtitleURLKey(url))", source: .externalFile,
                              streamIndex: nil, primaryTrackID: primaryID, codec: url.pathExtension,
                              language: nil, title: nil, displayName: url.lastPathComponent,
                              sourceURL: url, supportLevel: externalSubtitleSupportLevel(for: url), isExternal: true)
    }

    private func readPrimaryTranslationTimeline(track: EmbeddedSubtitleTrack, item: VideoFile) async throws -> SubtitleTimeline {
        guard let sourceURL = track.sourceURL else { throw CocoaError(.fileReadUnsupportedScheme) }
        let readableURL: URL
        if track.source == .localContainer, let index = track.streamIndex {
            readableURL = try await SharedLocalEmbeddedSubtitleExtractor.extractSubtitle(
                from: item.url, trackIndex: index, outputURL: sourceURL)
        } else if sourceURL.isFileURL {
            readableURL = sourceURL
        } else if let local = await cacheRemoteSubtitleToLocalIfNeeded(sourceURL, item: item) {
            readableURL = local
        } else {
            throw CocoaError(.fileReadUnknown)
        }
        try Task.checkCancellation()
        let format = subtitleParserFormat(for: track)
        let parts = try await Task.detached(priority: .utility) {
            let access = readableURL.startAccessingSecurityScopedResource()
            defer { if access { readableURL.stopAccessingSecurityScopedResource() } }
            return try SubtitleModel.loadParts(from: readableURL, format: format)
        }.value
        try Task.checkCancellation()
        return SubtitleTimeline(parts: parts)
    }

    func setSecondarySubtitleDelay(_ seconds: Double) {
        let clamped = min(max(seconds, -10.0), 10.0)
        guard abs(UserDefaults.standard.double(forKey: "secondarySubtitleDelaySeconds") - clamped) > 0.001 else { return }
        UserDefaults.standard.set(clamped, forKey: "secondarySubtitleDelaySeconds")
        if isUsingMPV {
            updateMPVSecondaryStyle()
            updateCurrentSecondarySubtitleParts(at: Double(currentTime) / 1000)
            return
        }
        updateCurrentSecondarySubtitleParts(at: Double(currentTime) / 1000.0)
    }

    internal func loadSecondarySubtitleTimeline(for track: EmbeddedSubtitleTrack) {
        secondarySubtitleLoadTask?.cancel()

        guard let sourceURL = track.sourceURL else {
            secondarySubtitleStatus = .unsupported
            currentSecondarySubtitleParts = []
            return
        }

        let cacheKey = secondarySubtitleTimelineCacheKey(for: track)
        if let cachedTimeline = cachedSecondarySubtitleTimeline(for: cacheKey) {
            secondarySubtitleTimeline = cachedTimeline
            secondarySubtitleStatus = .ready
            updateCurrentSecondarySubtitleParts(at: Double(currentTime) / 1000.0)
            return
        }

        secondarySubtitleStatus = .loading
        let currentItem = currentFile
        let itemID = currentItem?.id
        let generation = translationPlaybackGeneration
        secondarySubtitleLoadTask = Task { [weak self] in
            guard let self else { return }

            do {
                let readableURL: URL
                if track.source == .localContainer {
                    guard let currentItem,
                          let trackIndex = track.streamIndex else {
                        throw NSError(domain: "LocalEmbeddedSubtitleExtractor", code: -1)
                    }
                    readableURL = try await SharedLocalEmbeddedSubtitleExtractor.extractSubtitle(
                        from: currentItem.url,
                        trackIndex: trackIndex,
                        outputURL: sourceURL
                    )
                } else if sourceURL.isFileURL {
                    readableURL = sourceURL
                } else if let cachedURL = await self.cacheRemoteSubtitleToLocalIfNeeded(sourceURL) {
                    readableURL = cachedURL
                } else {
                    throw NSError(domain: "VLCPlaybackService.SecondarySubtitle", code: -1)
                }

                try Task.checkCancellation()
                let parts = try SubtitleModel.loadParts(
                    from: readableURL,
                    format: self.subtitleParserFormat(for: track)
                )
                let timeline = SubtitleTimeline(parts: parts)
                await MainActor.run {
                    guard !Task.isCancelled, self.translationPlaybackGeneration == generation, !self.isUsingMPV,
                          self.currentFile?.id == itemID,
                          self.currentSecondarySubtitleTrackID == track.id else { return }
                    self.storeSecondarySubtitleTimeline(timeline, for: cacheKey)
                    self.secondarySubtitleTimeline = timeline
                    self.secondarySubtitleStatus = .ready
                    self.updateCurrentSecondarySubtitleParts(at: Double(self.currentTime) / 1000.0)
                }
            } catch {
                await MainActor.run {
                    guard !Task.isCancelled, self.translationPlaybackGeneration == generation, !self.isUsingMPV,
                          self.currentFile?.id == itemID,
                          self.currentSecondarySubtitleTrackID == track.id else { return }
                    self.secondarySubtitleStatus = .error
                    self.currentSecondarySubtitleParts = []
                    self.secondarySubtitleTimeline = nil
                    print("[Subtitle] Failed to parse secondary subtitle: \(error.localizedDescription)")
                }
            }
        }
    }

    private func secondarySubtitleTimelineCacheKey(for track: EmbeddedSubtitleTrack) -> String {
        [
            track.source.rawValue,
            track.id,
            track.sourceURL.map(subtitleURLKey) ?? "no-url",
            track.codec ?? "unknown"
        ].joined(separator: "|")
    }

    private func cachedSecondarySubtitleTimeline(for key: String) -> SubtitleTimeline? {
        guard let timeline = Self.secondarySubtitleTimelineCache[key] else { return nil }
        Self.secondarySubtitleTimelineCacheOrder.removeAll { $0 == key }
        Self.secondarySubtitleTimelineCacheOrder.append(key)
        return timeline
    }

    private func storeSecondarySubtitleTimeline(_ timeline: SubtitleTimeline, for key: String) {
        Self.secondarySubtitleTimelineCache[key] = timeline
        Self.secondarySubtitleTimelineCacheOrder.removeAll { $0 == key }
        Self.secondarySubtitleTimelineCacheOrder.append(key)

        while Self.secondarySubtitleTimelineCacheOrder.count > Self.secondarySubtitleTimelineCacheLimit {
            let evictedKey = Self.secondarySubtitleTimelineCacheOrder.removeFirst()
            Self.secondarySubtitleTimelineCache.removeValue(forKey: evictedKey)
        }
    }


    private func subtitleParserFormat(for track: EmbeddedSubtitleTrack) -> String {
        if let codec = track.codec?.lowercased() {
            if codec == "subrip" { return "srt" }
            if codec == "webvtt" { return "vtt" }
            if codec == "mov_text" || codec == "tx3g" { return "srt" }
            return codec
        }
        return track.sourceURL?.pathExtension.lowercased() ?? "srt"
    }

    private func isCurrentPrimarySubtitle(_ track: EmbeddedSubtitleTrack) -> Bool {
        return false
    }

    internal func availableSecondarySubtitleTracks(for item: VideoFile) -> [EmbeddedSubtitleTrack] {
        let tracks = localContainerSecondarySubtitleTracks(for: item) +
            embeddedServerSubtitleTracks(for: item) +
            externalFileSecondarySubtitleTracks(for: item) +
            primaryExternalSecondarySubtitleTracks(for: item)
        var seenIDs = Set<String>()
        var seenURLKeys = Set<String>()
        var result: [EmbeddedSubtitleTrack] = []

        for track in tracks {
            guard seenIDs.insert(track.id).inserted else { continue }
            if let sourceURL = track.sourceURL {
                let key = subtitleURLKey(sourceURL)
                guard seenURLKeys.insert(key).inserted else { continue }
            }
            if let duplicateIndex = result.firstIndex(where: {
                secondarySubtitleTracksRepresentSameCandidate($0, track)
            }) {
                if shouldPreferSecondarySubtitleTrack(track, over: result[duplicateIndex]) {
                    result[duplicateIndex] = track
                }
                continue
            }
            result.append(track)
        }

        return result
    }

    private func secondarySubtitleTracksLikelySame(_ lhs: EmbeddedSubtitleTrack, _ rhs: EmbeddedSubtitleTrack) -> Bool {
        if let leftURL = lhs.sourceURL,
           let rightURL = rhs.sourceURL,
           subtitleURLKey(leftURL) == subtitleURLKey(rightURL) {
            return true
        }

        return secondarySubtitleNamesLikelyMatch(lhs.displayName, rhs.displayName)
    }

    private func secondarySubtitleNamesLikelyMatch(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalizedSecondarySubtitleName(lhs)
        let right = normalizedSecondarySubtitleName(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.contains(right) || right.contains(left)
    }

    private func normalizedSecondarySubtitleName(_ value: String) -> String {
        let lowered = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        return String(lowered.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private func secondarySubtitleSupportRank(_ supportLevel: EmbeddedSubtitleSupportLevel) -> Int {
        switch supportLevel {
        case .textSupported:
            return 3
        case .textBestEffort:
            return 2
        case .unsupportedBitmap:
            return 1
        case .unsupportedUnknown:
            return 0
        }
    }

    private func shouldPreferSecondarySubtitleTrack(
        _ candidate: EmbeddedSubtitleTrack,
        over existing: EmbeddedSubtitleTrack
    ) -> Bool {
        let candidateRank = secondarySubtitleSupportRank(candidate.supportLevel)
        let existingRank = secondarySubtitleSupportRank(existing.supportLevel)
        if candidateRank != existingRank {
            return candidateRank > existingRank
        }
        if (candidate.sourceURL != nil) != (existing.sourceURL != nil) {
            return candidate.sourceURL != nil
        }
        if candidate.source == .externalFile && existing.source != .externalFile {
            return false
        }
        return false
    }

    private func secondarySubtitleTracksRepresentSameCandidate(
        _ lhs: EmbeddedSubtitleTrack,
        _ rhs: EmbeddedSubtitleTrack
    ) -> Bool {
        if let leftPrimary = lhs.primaryTrackID,
           let rightPrimary = rhs.primaryTrackID,
           leftPrimary != -1,
           rightPrimary != -1,
           leftPrimary == rightPrimary {
            return true
        }

        if secondarySubtitleTracksLikelySame(lhs, rhs) {
            if lhs.isExternal && rhs.isExternal {
                return true
            }
            if !lhs.isSelectable || !rhs.isSelectable {
                return true
            }
        }

        if let leftIndex = lhs.streamIndex,
           let rightIndex = rhs.streamIndex,
           leftIndex == rightIndex,
           lhs.source == rhs.source {
            return true
        }

        return false
    }

    private func localContainerSecondarySubtitleTracks(
        for item: VideoFile,
        descriptors: [SharedLocalEmbeddedSubtitleDescriptor]? = nil
    ) -> [EmbeddedSubtitleTrack] {
        guard item.url.isFileURL else { return [] }

        let descriptors = descriptors ?? sharedLocalEmbeddedSubtitleDescriptors(for: item.url)
        guard !descriptors.isEmpty else { return [] }

        let nativeSubtitleTracks = subtitleTracks.filter { track in
            track.id != -1 &&
            !track.isExternal &&
            false
        }
        let itemMediaKey = mediaKey(for: item.url) ?? item.url.standardizedFileURL.path

        return descriptors.map { descriptor in
            let primaryTrack = descriptor.trackIndex < nativeSubtitleTracks.count
                ? nativeSubtitleTracks[descriptor.trackIndex]
                : nil
            let displayName = primaryTrack?.name ??
                localEmbeddedSubtitleDisplayName(for: descriptor, fallbackIndex: descriptor.trackIndex)
            let sourceURL = descriptor.supportLevel == .textSupported || descriptor.supportLevel == .textBestEffort
                ? localEmbeddedSubtitleOutputURL(
                    for: item.url,
                    trackIndex: descriptor.trackIndex,
                    codec: descriptor.codec
                )
                : nil
            let idParts = [
                EmbeddedSubtitleSource.localContainer.rawValue,
                itemMediaKey,
                "\(descriptor.trackIndex)",
                descriptor.codec ?? "unknown"
            ]

            return EmbeddedSubtitleTrack(
                id: idParts.joined(separator: "|"),
                source: .localContainer,
                streamIndex: descriptor.trackIndex,
                primaryTrackID: primaryTrack?.id,
                codec: descriptor.codec,
                language: descriptor.language,
                title: descriptor.title,
                displayName: displayName,
                sourceURL: sourceURL,
                supportLevel: descriptor.supportLevel,
                isExternal: false
            )
        }
    }

    private func sharedLocalEmbeddedSubtitleDescriptors(for mediaURL: URL) -> [SharedLocalEmbeddedSubtitleDescriptor] {
        let key = subtitleURLKey(mediaURL)
        

        let descriptors = SharedLocalEmbeddedSubtitleExtractor.descriptors(for: mediaURL)
        
        return descriptors
    }

    private func localEmbeddedSubtitleDisplayName(
        for descriptor: SharedLocalEmbeddedSubtitleDescriptor,
        fallbackIndex: Int
    ) -> String {
        var parts: [String] = []
        if let title = descriptor.title, !title.isEmpty {
            parts.append(title)
        }
        if let language = descriptor.language, !language.isEmpty,
           !parts.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
            parts.append(language.uppercased())
        }
        if let codec = descriptor.codec, !codec.isEmpty {
            parts.append(codec.uppercased())
        }
        if parts.isEmpty {
            return "\(platformShellString("Subtitle")) \(fallbackIndex + 1)"
        }
        return parts.joined(separator: " · ")
    }

    private func localEmbeddedSubtitleOutputURL(
        for mediaURL: URL,
        trackIndex: Int,
        codec: String?
    ) -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LocalEmbedded")
try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let baseName = String(mediaURL.deletingPathExtension().lastPathComponent.prefix(50))
        let normalizedCodec = codec?.lowercased()
        let outputExtension: String
        switch normalizedCodec {
        case "ass":
            outputExtension = "ass"
        case "ssa":
            outputExtension = "ssa"
        case "webvtt", "vtt":
            outputExtension = "vtt"
        default:
            outputExtension = "srt"
        }
        let key = "\(subtitleURLKey(mediaURL))|\(trackIndex)|\(normalizedCodec ?? "unknown")"
        let hash = stableHashHex(for: key)
        return folder.appendingPathComponent("\(baseName)_track\(trackIndex + 1)_\(hash).\(outputExtension)")
    }



    internal func embeddedServerSubtitleTracks(for item: VideoFile) -> [EmbeddedSubtitleTrack] {
        guard let streams = item.serverMediaStreams, !streams.isEmpty else { return [] }
        guard item.serverType == .jellyfin || item.serverType == .emby else { return [] }
        guard let server = embeddedSubtitleServer(for: item),
              let itemId = item.jellyfinItemId,
              !itemId.isEmpty else {
            return []
        }

        let token = embeddedSubtitleToken(for: item, server: server)
        let mediaSourceId = item.mediaSourceId ?? embeddedSubtitleMediaSourceID(from: item.url) ?? item.jellyfinItemId
        let subtitleStreams = streams.filter { isSubtitleServerStream($0) }
        let nativeSubtitleTracks = subtitleTracks.filter { $0.id != -1 && !$0.isExternal }
        let source: EmbeddedSubtitleSource = item.serverType == .emby ? .embyMediaStream : .jellyfinMediaStream

        let internalStreams = subtitleStreams.filter { !embeddedSubtitleStreamIsExternal($0) }
        let descriptors = internalStreams.map {
            (codec: $0["Codec"] as? String, language: $0["Language"] as? String, title: $0["Title"] as? String)
        }
        var nativeFallbackOffset = 0
        return subtitleStreams.enumerated().compactMap { offset, stream in
            guard let streamIndex = stream["Index"] as? Int else { return nil }

            let codec = cleanedEmbeddedSubtitleValue(stream["Codec"] as? String)
            let supportLevel = embeddedSubtitleSupportLevel(codec: codec, stream: stream)
            let sourceURL = embeddedSubtitleURL(
                server: server,
                itemId: itemId,
                mediaSourceId: mediaSourceId,
                streamIndex: streamIndex,
                codec: codec,
                deliveryURL: stream["DeliveryUrl"] as? String,
                token: token
            )
            let isExternal = embeddedSubtitleStreamIsExternal(stream)
            let nativeFallbackTrackID: Int?
            if isExternal {
                nativeFallbackTrackID = nil
            } else {
                nativeFallbackTrackID = nativeFallbackOffset < nativeSubtitleTracks.count
                    ? nativeSubtitleTracks[nativeFallbackOffset].id
                    : nil
                nativeFallbackOffset += 1
            }
            let exactPrimaryTrackID = subtitleTracks.contains(where: { $0.id == streamIndex }) ? streamIndex : nil
            let primaryTrackID: Int?
            if isUsingMPV {
                // Server stream Index is NOT an mpv sid, even when the numbers coincide.
                primaryTrackID = isExternal ? nil : mpvTracks.first { track in
                    guard track.type == "sub", !track.external,
                          let ordinal = MacMPVSubtitleMapping.ordinal(selectedID: track.id, tracks: mpvTracks,
                                                                      descriptors: descriptors) else { return false }
                    return internalStreams[ordinal]["Index"] as? Int == streamIndex
                }?.id
            } else {
                primaryTrackID = exactPrimaryTrackID ?? nativeFallbackTrackID
            }
            let displayName = embeddedSubtitleDisplayName(stream: stream, fallbackIndex: offset)
            let idParts = [
                source.rawValue,
                itemId,
                mediaSourceId ?? "unknown-source",
                "\(streamIndex)",
                codec ?? "unknown"
            ]

            return EmbeddedSubtitleTrack(
                id: idParts.joined(separator: "|"),
                source: source,
                streamIndex: streamIndex,
                primaryTrackID: primaryTrackID,
                codec: codec,
                language: cleanedEmbeddedSubtitleValue(stream["Language"] as? String),
                title: cleanedEmbeddedSubtitleValue(stream["Title"] as? String),
                displayName: displayName,
                sourceURL: sourceURL,
                supportLevel: supportLevel,
                isExternal: isExternal
            )
        }
    }




    private func embeddedSubtitleServer(for item: VideoFile) -> ServerConfig? {
        let servers = AppNetworkService.shared.savedServers
        if let serverID = item.jellyfinServerId,
           let uuid = UUID(uuidString: serverID),
           let matched = servers.first(where: { $0.id == uuid }) {
            return matched
        }

        guard let host = item.url.host?.lowercased() else { return nil }
        return servers.first { server in
            guard server.type == item.serverType else { return false }
            return normalizeServerHost(server.fullURL) == host || normalizeServerHost(server.address) == host
        }
    }

    private func embeddedSubtitleToken(for item: VideoFile, server: ServerConfig) -> String {
        URLComponents(url: item.url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("api_key") == .orderedSame })?
            .value
            ?? server.accessToken
            ?? ""
    }

    private func embeddedSubtitleMediaSourceID(from url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame })?
            .value
    }

    private func isSubtitleServerStream(_ stream: [String: Any]) -> Bool {
        let type = ((stream["Type"] as? String) ?? "").lowercased()
        return type == "subtitle" || type.contains("subtitle") || type.contains("caption")
    }

    private func embeddedSubtitleStreamIsExternal(_ stream: [String: Any]) -> Bool {
        if let value = stream["IsExternal"] as? Bool {
            return value
        }
        if let value = stream["IsExternal"] as? NSNumber {
            return value.boolValue
        }
        if let value = stream["IsExternal"] as? String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "true" || normalized == "1" || normalized == "yes"
        }
        return false
    }

    private func embeddedSubtitleSupportLevel(
        codec: String?,
        stream: [String: Any]
    ) -> EmbeddedSubtitleSupportLevel {
        if (stream["IsTextSubtitleStream"] as? Bool) == true {
            return .textSupported
        }

        switch codec?.lowercased() {
        case "srt", "subrip", "webvtt", "vtt", "mov_text", "tx3g":
            return .textSupported
        case "ass", "ssa":
            return .textBestEffort
        case "pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "vobsub", "dvbsub", "dvb_subtitle":
            return .unsupportedBitmap
        default:
            return .unsupportedUnknown
        }
    }

    private func externalSubtitleSupportLevel(for url: URL, displayName: String? = nil) -> EmbeddedSubtitleSupportLevel {
        var ext = url.pathExtension.lowercased()
        
        func isSupported(_ format: String) -> Bool {
            let f = format.lowercased()
            return ["srt", "vtt", "webvtt", "subrip", "ass", "ssa", "sub"].contains(f)
        }
        
        if !isSupported(ext) {
            if let path = url.path.components(separatedBy: "/").last?.lowercased() {
                if let dotRange = path.range(of: ".", options: .backwards) {
                    let pathExt = String(path[dotRange.upperBound...])
                    if isSupported(pathExt) {
                        ext = pathExt
                    }
                }
            }
        }
        
        if !isSupported(ext) {
            if let components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                if let formatQuery = components.queryItems?.first(where: { $0.name.lowercased() == "format" || $0.name.lowercased() == "codec" })?.value?.lowercased() {
                    if isSupported(formatQuery) {
                        ext = formatQuery
                    }
                }
            }
        }
        
        if !isSupported(ext), let displayName = displayName?.lowercased() {
            if displayName.contains("ass") || displayName.contains("ssa") {
                ext = "ass"
            } else if displayName.contains("srt") || displayName.contains("subrip") {
                ext = "srt"
            } else if displayName.contains("vtt") || displayName.contains("webvtt") {
                ext = "vtt"
            } else if displayName.contains("sub") {
                ext = "sub"
            }
        }
        
        switch ext {
        case "srt", "vtt", "webvtt", "subrip":
            return .textSupported
        case "ass", "ssa", "sub":
            return .textBestEffort
        case "pgs", "hdmv_pgs_subtitle", "dvdsub", "dvd_subtitle", "vobsub", "dvbsub", "dvb_subtitle":
            return .unsupportedBitmap
        default:
            return .unsupportedUnknown
        }
    }

    private func embeddedSubtitleURL(
        server: ServerConfig,
        itemId: String,
        mediaSourceId: String?,
        streamIndex: Int,
        codec: String?,
        deliveryURL: String?,
        token: String
    ) -> URL? {
        if let deliveryURL = cleanedEmbeddedSubtitleValue(deliveryURL),
           let resolvedURL = resolvedEmbeddedSubtitleDeliveryURL(server: server, rawValue: deliveryURL, token: token) {
            return resolvedURL
        }

        guard let mediaSourceId, !mediaSourceId.isEmpty else { return nil }
        let ext = embeddedSubtitleExportExtension(codec: codec)
        let tokenQuery = token.isEmpty ? "" : "?api_key=\(token)"
        return URL(string: "\(server.fullURL)/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(streamIndex)/Stream.\(ext)\(tokenQuery)")
    }

    private func resolvedEmbeddedSubtitleDeliveryURL(
        server: ServerConfig,
        rawValue: String,
        token: String
    ) -> URL? {
        let absoluteString: String
        if rawValue.hasPrefix("http://") || rawValue.hasPrefix("https://") {
            absoluteString = rawValue
        } else if rawValue.hasPrefix("/") {
            absoluteString = "\(server.fullURL)\(rawValue)"
        } else {
            absoluteString = "\(server.fullURL)/\(rawValue)"
        }

        guard var components = URLComponents(string: absoluteString) else { return nil }
        if !token.isEmpty,
           components.queryItems?.contains(where: { $0.name.caseInsensitiveCompare("api_key") == .orderedSame }) != true {
            var items = components.queryItems ?? []
            items.append(URLQueryItem(name: "api_key", value: token))
            components.queryItems = items
        }
        return components.url
    }

    private func embeddedSubtitleExportExtension(codec: String?) -> String {
        switch codec?.lowercased() {
        case "srt", "subrip":
            return "srt"
        case "webvtt", "vtt":
            return "vtt"
        case "ass":
            return "ass"
        case "ssa":
            return "ssa"
        case "mov_text", "tx3g":
            return "srt"
        default:
            return "srt"
        }
    }

    private func embeddedSubtitleDisplayName(stream: [String: Any], fallbackIndex: Int) -> String {
        var parts: [String] = []
        [
            stream["DisplayTitle"] as? String,
            stream["Title"] as? String,
            stream["DisplayLanguage"] as? String,
            stream["Language"] as? String
        ].forEach { value in
            guard let cleaned = cleanedEmbeddedSubtitleValue(value) else { return }
            if !parts.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame }) {
                parts.append(cleaned)
            }
        }

        if (stream["IsDefault"] as? Bool) == true {
            parts.append(platformShellString("Default"))
        }
        if (stream["IsForced"] as? Bool) == true {
            parts.append(platformShellString("Forced"))
        }
        if let codec = cleanedEmbeddedSubtitleValue(stream["Codec"] as? String) {
            parts.append(codec.uppercased())
        }

        if parts.isEmpty {
            return "\(platformShellString("Subtitle")) \(fallbackIndex + 1)"
        }
        return parts.joined(separator: " · ")
    }

    private func cleanedEmbeddedSubtitleValue(_ value: String?) -> String? {
        guard let cleaned = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleaned.isEmpty else {
            return nil
        }
        let lowered = cleaned
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let placeholders: Set<String> = ["und", "undefined", "unknown", "undetermined", "n/a", "na", "none", "null"]
        return placeholders.contains(lowered) ? nil : cleaned
    }
    
    private func externalFileSecondarySubtitleTracks(for item: VideoFile) -> [EmbeddedSubtitleTrack] {
        let candidates = item.externalSubtitleCandidates
        guard !candidates.isEmpty else {
            return []
        }
        let itemMediaKey = mediaKey(for: item.url) ?? "unknown-media"
        return candidates.enumerated().map { offset, candidate in
            let key = subtitleURLKey(candidate.url)
            let primaryTrackID = 10000 + offset
            let codec = cleanedEmbeddedSubtitleValue(candidate.url.pathExtension)
            let displayName = candidate.displayName
            let supportLevel = externalSubtitleSupportLevel(for: candidate.url, displayName: displayName)
            let idParts = [
                EmbeddedSubtitleSource.externalFile.rawValue,
                itemMediaKey,
                key
            ]

            return EmbeddedSubtitleTrack(
                id: idParts.joined(separator: "|"),
                source: .externalFile,
                streamIndex: nil,
                primaryTrackID: primaryTrackID,
                codec: codec,
                language: nil,
                title: displayName,
                displayName: displayName,
                sourceURL: candidate.url,
                supportLevel: supportLevel,
                isExternal: true
            )
        }
    }

    private func primaryExternalSecondarySubtitleTracks(for item: VideoFile) -> [EmbeddedSubtitleTrack] {
        let itemMediaKey = mediaKey(for: item.url)

        return subtitleTracks.compactMap { track in
            guard track.id != -1,
                  track.isExternal,
                  let url = remoteSecondarySubtitleURLs[track.id] else {
                return nil
            }

            let key = subtitleURLKey(url)
            let codec = cleanedEmbeddedSubtitleValue(url.pathExtension)
            let supportLevel = externalSubtitleSupportLevel(for: url, displayName: track.name)
            let idParts = [
                EmbeddedSubtitleSource.externalFile.rawValue,
                itemMediaKey ?? "unknown-media",
                "primary",
                key
            ]

            return EmbeddedSubtitleTrack(
                id: idParts.joined(separator: "|"),
                source: .externalFile,
                streamIndex: nil,
                primaryTrackID: track.id,
                codec: codec,
                language: nil,
                title: track.name,
                displayName: track.name,
                sourceURL: url,
                supportLevel: supportLevel,
                isExternal: true
            )
        }
    }

    private func secondarySubtitleDisplayName(for track: EmbeddedSubtitleTrack) -> String {
        if let primaryTrackID = track.primaryTrackID,
           let primaryTrack = subtitleTracks.first(where: { $0.id == primaryTrackID && $0.id != -1 }),
           secondarySubtitleNamesLikelyMatch(track.displayName, primaryTrack.name) {
            return primaryTrack.name
        }

        if track.isExternal,
           let sourceURL = track.sourceURL {
            let sourceKey = subtitleURLKey(sourceURL)
            if let primaryTrack = subtitleTracks.first(where: { primaryTrack in
                guard primaryTrack.id != -1,
                      primaryTrack.isExternal,
                      let primaryURL = remoteSecondarySubtitleURLs[primaryTrack.id] else {
                    return false
                }
                return subtitleURLKey(primaryURL) == sourceKey
            }) {
                return primaryTrack.name
            }
        }

        return track.displayName
    }

    private func selectedSecondarySubtitleOrdinal(for track: EmbeddedSubtitleTrack) -> Int? {
        let selectableTracks = secondarySubtitleTracks.filter { $0.isSelectable }
        return selectableTracks.firstIndex(where: { $0.id == track.id })
    }

    private func secondarySubtitlePreferenceScopeKey(for item: VideoFile) -> String? {
        if let seriesId = item.jellyfinItemId, !seriesId.isEmpty {
            return "item.\(seriesId)"
        }
        return nil
    }

    internal func storedSecondarySubtitlePreference(for item: VideoFile) -> (query: String?, ordinal: Int?) {
        if let provider = item.serverType?.rawValue,
           let serverId = item.jellyfinServerId,
           let scopeKey = secondarySubtitlePreferenceScopeKey(for: item) {
            let preference = secondarySubtitlePreference(
                provider: provider,
                serverId: serverId,
                scopeKey: scopeKey
            )
            if preference.query != nil || preference.ordinal != nil {
                return preference
            }
        }

        guard let key = mediaKey(for: item.url) else {
            return (nil, nil)
        }
        return secondarySubtitlePreference(mediaKey: key)
    }

    internal func saveStoredSecondarySubtitlePreference(for item: VideoFile, track: EmbeddedSubtitleTrack?) {
        let query = track.map { secondarySubtitleDisplayName(for: $0) }
        let ordinal = track.flatMap { selectedSecondarySubtitleOrdinal(for: $0) }

        if let provider = item.serverType?.rawValue,
           let serverId = item.jellyfinServerId,
           let scopeKey = secondarySubtitlePreferenceScopeKey(for: item) {
            saveSecondarySubtitlePreference(
                provider: provider,
                serverId: serverId,
                scopeKey: scopeKey,
                query: query,
                ordinal: ordinal
            )
            return
        }

        if let key = mediaKey(for: item.url) {
            saveSecondarySubtitlePreference(
                mediaKey: key,
                query: query,
                ordinal: ordinal
            )
        }
    }

    private func secondarySubtitlePreference(
        provider: String,
        serverId: String,
        scopeKey: String
    ) -> (query: String?, ordinal: Int?) {
        let prefix = "secondarySubtitle.server.\(provider).\(serverId).\(scopeKey)"
        return secondarySubtitlePreference(prefix: prefix)
    }

    private func saveSecondarySubtitlePreference(
        provider: String,
        serverId: String,
        scopeKey: String,
        query: String?,
        ordinal: Int?
    ) {
        let prefix = "secondarySubtitle.server.\(provider).\(serverId).\(scopeKey)"
        saveSecondarySubtitlePreference(prefix: prefix, query: query, ordinal: ordinal)
    }

    private func secondarySubtitlePreference(mediaKey: String) -> (query: String?, ordinal: Int?) {
        let prefix = "secondarySubtitle.media.\(stablePreferenceKey(mediaKey))"
        return secondarySubtitlePreference(prefix: prefix)
    }

    private func saveSecondarySubtitlePreference(
        mediaKey: String,
        query: String?,
        ordinal: Int?
    ) {
        let prefix = "secondarySubtitle.media.\(stablePreferenceKey(mediaKey))"
        saveSecondarySubtitlePreference(prefix: prefix, query: query, ordinal: ordinal)
    }

    private func secondarySubtitlePreference(prefix: String) -> (query: String?, ordinal: Int?) {
        let query = UserDefaults.standard.string(forKey: "\(prefix).secondarySubtitleQuery")
        let ordinal = UserDefaults.standard.object(forKey: "\(prefix).secondarySubtitleOrdinal") as? Int
        return (query, ordinal)
    }

    private func saveSecondarySubtitlePreference(
        prefix: String,
        query: String?,
        ordinal: Int?
    ) {
        let queryKey = "\(prefix).secondarySubtitleQuery"
        let ordinalKey = "\(prefix).secondarySubtitleOrdinal"

        if let query = query {
            UserDefaults.standard.set(query, forKey: queryKey)
        } else {
            UserDefaults.standard.removeObject(forKey: queryKey)
        }

        if let ordinal = ordinal {
            UserDefaults.standard.set(ordinal, forKey: ordinalKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ordinalKey)
        }
    }

    private func stablePreferenceKey(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    internal func primarySubtitleTranslationPreferenceKey(for item: VideoFile) -> String {
        MacSubtitleTranslationPreference.key(provider: item.serverType?.rawValue,
            serverID: item.jellyfinServerId, itemID: item.jellyfinItemId, url: item.url)
    }

    internal func storedPrimarySubtitleTranslationPreference(for item: VideoFile) -> Bool {
        MacSubtitleTranslationPreference.isEnabled(key: primarySubtitleTranslationPreferenceKey(for: item))
    }

    internal func savePrimarySubtitleTranslationPreference(for item: VideoFile, enabled: Bool) {
        MacSubtitleTranslationPreference.save(enabled, key: primarySubtitleTranslationPreferenceKey(for: item))
    }

    internal func restorePendingPrimarySubtitleTranslationIfNeeded() {
        guard pendingPrimarySubtitleTranslationRestore,
              UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta"),
              hasPrimarySubtitleForTranslation else { return }
        setSecondarySubtitleTrack(MacSubtitleTranslation.trackID)
    }

    internal func restorePendingSecondarySubtitleSelectionIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta") else { return }
        guard pendingSecondarySubtitleTrackQuery != nil || pendingSecondarySubtitleTrackOrdinal != nil else {
            return
        }

        let selectableTracks = secondarySubtitleTracks.filter { $0.isSelectable }
        let namedTracks = isUsingMPV ? secondarySubtitleTracks : selectableTracks
        guard !namedTracks.isEmpty else { return }

        var matchedTrack: EmbeddedSubtitleTrack?

        if let query = pendingSecondarySubtitleTrackQuery {
            matchedTrack = namedTracks.first { track in
                secondarySubtitleNamesLikelyMatch(secondarySubtitleDisplayName(for: track), query)
            }
        }

        if matchedTrack == nil, let ordinal = pendingSecondarySubtitleTrackOrdinal, ordinal >= 0, ordinal < selectableTracks.count {
            matchedTrack = selectableTracks[ordinal]
        }

        // Keep the same ordinal domain used when saving VLC/MPV preferences:
        // native bitmap tracks can match by name, but do not shift text ordinals.
        // A later asynchronous external track may still satisfy this preference.
        guard let matched = matchedTrack else { return }
        pendingSecondarySubtitleTrackQuery = nil
        pendingSecondarySubtitleTrackOrdinal = nil
        setSecondarySubtitleTrack(matched.id)
    }
}
// MARK: - Read-only subtitle browser
extension MacVLCPlaybackService {
    var subtitleBrowserSources: [SubtitleBrowserSource] {
        guard let item = currentFile, playbackCapabilities.supports(.subtitleBrowser, isVideo: item.type == .video) else { return [] }
        if isUsingMPV { return mpvSubtitleBrowserSources(item: item) }
        let session = translationPlaybackGeneration.uuidString
        let primaryDelay = UserDefaults.standard.double(forKey: "subtitleDelaySeconds")
        let secondaryDelay = primaryDelay + UserDefaults.standard.double(forKey: "secondarySubtitleDelaySeconds")
        var sources: [SubtitleBrowserSource] = []
        if audioSubtitles.uses(.primary) {
            sources.append(.generated(id: session + "|primary|generated", title: platformShellString("Primary"),
                offset: primaryDelay, audio: audioSubtitles, translation: subtitleTranslation,
                original: audioSubtitles.activeOriginalDestination == .primary,
                translated: audioSubtitles.activeTranslationDestination == .primary))
        } else if currentSubtitleTrackID != -1 {
            // Resolve only in-memory sources here. Local container metadata belongs to
            // the source's load task, whose stable request key survives playback ticks.
            let track = primarySubtitleTranslationTrack(for: item, includeLocalContainer: false)
            let id = "\(session)|primary|\(currentSubtitleTrackID)"
            sources.append((item.url.isFileURL && (track == nil || track?.source == .localContainer)
                ? localBrowserSource(item: item, id: id, offset: primaryDelay) : nil)
                ?? (track == nil ? remoteBrowserSource(item: item, id: id, offset: primaryDelay) : nil)
                ?? browserSource(track: track, item: item, id: id, title: platformShellString("Primary"), offset: primaryDelay))
        }
        if UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta") {
            if audioSubtitles.uses(.secondary) {
                sources.append(.generated(id: session + "|secondary|generated", title: platformShellString("Secondary"),
                    offset: secondaryDelay, audio: audioSubtitles, translation: subtitleTranslation,
                    original: audioSubtitles.activeOriginalDestination == .secondary,
                    translated: audioSubtitles.activeTranslationDestination == .secondary))
            } else if currentSecondarySubtitleTrackID == MacSubtitleTranslation.trackID {
                let offset = currentSubtitleTrackID == MacAudioSubtitlePlan.primaryID ? secondaryDelay : -secondaryDelay
                sources.append(.translated(id: session + "|secondary|translation", title: platformShellString("Secondary"),
                    offset: offset, translation: subtitleTranslation))
            } else if let id = currentSecondarySubtitleTrackID {
                sources.append(browserSource(track: secondarySubtitleTracks.first { $0.id == id }, item: item,
                    id: "\(session)|secondary|\(id)", title: platformShellString("Secondary"), offset: -secondaryDelay))
            }
        }
        return sources
    }

    private func mpvSubtitleBrowserSources(item: VideoFile) -> [SubtitleBrowserSource] {
        let session = translationPlaybackGeneration.uuidString
        let delay = UserDefaults.standard.double(forKey: "subtitleDelaySeconds")
        var result: [SubtitleBrowserSource] = []
        if audioSubtitles.uses(.primary) {
            result.append(.generated(id: session + "|primary|generated", title: platformShellString("Primary"),
                offset: delay, audio: audioSubtitles, translation: subtitleTranslation,
                original: audioSubtitles.activeOriginalDestination == .primary,
                translated: audioSubtitles.activeTranslationDestination == .primary))
        } else if let track = mpvTracks.first(where: { $0.type == "sub" && $0.id == currentSubtitleTrackID }) {
            result.append(mpvBrowserSource(track: track, item: item, id: "\(session)|primary|\(track.id)",
                title: platformShellString("Primary"), offset: delay))
        }
        let secondaryDelay = delay + UserDefaults.standard.double(forKey: "secondarySubtitleDelaySeconds")
        guard UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta") else { return result }
        if audioSubtitles.uses(.secondary) {
            result.append(.generated(id: session + "|secondary|generated", title: platformShellString("Secondary"),
                offset: secondaryDelay, audio: audioSubtitles, translation: subtitleTranslation,
                original: audioSubtitles.activeOriginalDestination == .secondary,
                translated: audioSubtitles.activeTranslationDestination == .secondary))
        } else if currentSecondarySubtitleTrackID == MacSubtitleTranslation.trackID {
            let partial = mpvTranslationSourceIsPartial
            let decoded = mpvTranslationUsesDecodedText
            let translation = subtitleTranslation
            result.append(SubtitleBrowserSource(id: session + "|secondary|translation", title: platformShellString("Secondary"),
                revision: "\(translation.browserRevision)|\(partial)", offset: secondaryDelay) {
                SubtitleBrowserDocument(parts: translation.browserParts(content: .translated),
                    isPartial: partial || translation.browserTranslationIsPartial,
                    partialStatusKey: partial && !decoded ? "SB.Indexed" : "SB.Partial")
            })
        } else if let selected = currentSecondarySubtitleTrackID,
           let track = mpvTracks.first(where: { $0.type == "sub" && "mpv-\($0.id)" == selected }) {
            result.append(mpvBrowserSource(track: track, item: item, id: "\(session)|secondary|\(track.id)",
                title: platformShellString("Secondary"), offset: MPVSecondarySubtitleRendering.nativeDelay(
                    primary: delay, secondary: UserDefaults.standard.double(forKey: "secondarySubtitleDelaySeconds"))))
        }
        return result
    }

    func loadMPVMirroredSecondaryTimeline(trackID: Int) {
        secondarySubtitleLoadTask?.cancel()
        guard let item = currentFile,
              let track = mpvTracks.first(where: { $0.type == "sub" && $0.id == trackID && !$0.isBitmap }) else { return }
        let generation = translationPlaybackGeneration
        let source = mpvBrowserSource(track: track, item: item, id: "\(generation)|mirror|\(trackID)", title: "", offset: 0)
        secondarySubtitleLoadTask = Task { @MainActor [weak self] in
            do {
                let document = try await source.load()
                try Task.checkCancellation()
                guard let self, self.translationPlaybackGeneration == generation,
                      self.mpvMirroredSecondaryID == trackID else { return }
                self.secondarySubtitleTimeline = SubtitleTimeline(parts: document.entries.map {
                    SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text))
                })
                self.updateCurrentSecondarySubtitleParts(at: Double(self.currentTime) / 1000)
            } catch {
                // Remote/index-limited sources may not expose a full transcript.
                // Keep using the selected decoder's bounded cue history instead.
            }
        }
    }

    func updateMPVMirroredSecondaryParts(at time: Double) {
        if usesMPVNativeASSSecondary {
            if !currentSecondarySubtitleParts.isEmpty { currentSecondarySubtitleParts = [] }
            return
        }
        let delay = UserDefaults.standard.double(forKey: "secondarySubtitleDelaySeconds")
        let primaryDelay = UserDefaults.standard.double(forKey: "subtitleDelaySeconds")
        let effective = MPVSecondarySubtitleRendering.sourceTime(playbackTime: time, primary: primaryDelay, secondary: delay)
        var parts = secondarySubtitleTimeline?.activeParts(at: effective) ?? []
        if parts.isEmpty {
            parts = mpvDecodedSubtitles.activeCues(at: effective).map {
                SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text))
            }
        }
        if secondarySubtitleTimeline == nil && primaryDelay == 0 && delay == 0 {
            // Also covers a live cue whose end timestamp is not known yet.
            parts = mpvMirroredSecondaryText.isEmpty ? [] : [SubtitlePart(start: time, end: time + 1,
                text: NSAttributedString(string: mpvMirroredSecondaryText))]
        }
        if currentSecondarySubtitleParts != parts { currentSecondarySubtitleParts = parts }
    }

    private func mpvBrowserSource(track: MacMPVTrack, item: VideoFile, id: String,
                                  title: String, offset: Double) -> SubtitleBrowserSource {
        let generation = translationPlaybackGeneration
        let tracks = mpvTracks
        if let serverTrack = primaryServerSubtitleTracks[track.id] {
            return browserSource(track: serverTrack, item: item, id: id, title: title, offset: offset)
        }
        if !track.external, !track.isBitmap, !item.url.isFileURL,
           let source = remoteBrowserSource(item: item, id: id, offset: offset, selectedID: track.id, title: title) {
            return source
        }
        return SubtitleBrowserSource(id: id, title: title, revision: "mpv-\(track.codec)-\(tracks.count)", offset: offset) { [weak self] in
            guard let self, self.translationPlaybackGeneration == generation else { throw CancellationError() }
            if track.isBitmap { throw SubtitleBrowserError.bitmap }
            let resolved: EmbeddedSubtitleTrack
            if let url = track.externalURL {
                resolved = self.translationExternalTrack(url: url, primaryID: track.id)
            } else if item.url.isFileURL, !track.external {
                let descriptors = try await MacSubtitleBrowserLocalTracks.readDescriptors(from: item.url)
                try Task.checkCancellation()
                guard self.translationPlaybackGeneration == generation else { throw CancellationError() }
                guard let ordinal = MacMPVSubtitleMapping.ordinal(selectedID: track.id, tracks: tracks,
                    descriptors: descriptors.map { ($0.codec, $0.language, $0.title) }) else { throw SubtitleBrowserError.unreadable }
                let container = self.localContainerSecondarySubtitleTracks(for: item, descriptors: descriptors)
                    .sorted { ($0.streamIndex ?? -1) < ($1.streamIndex ?? -1) }
                guard container.indices.contains(ordinal) else { throw SubtitleBrowserError.unreadable }
                resolved = container[ordinal]
            } else {
                throw SubtitleBrowserError.unreadable
            }
            if resolved.supportLevel == .unsupportedBitmap { throw SubtitleBrowserError.bitmap }
            let timeline = try await self.readPrimaryTranslationTimeline(track: resolved, item: item)
            try Task.checkCancellation()
            guard self.translationPlaybackGeneration == generation else { throw CancellationError() }
            return SubtitleBrowserDocument(parts: timeline.parts)
        }
    }

    private func browserSource(track: EmbeddedSubtitleTrack?, item: VideoFile, id: String,
                               title: String, offset: Double) -> SubtitleBrowserSource {
        SubtitleBrowserSource(id: id, title: title, revision: track?.id ?? "unresolved", offset: offset) { [weak self] in
            guard let self else { throw CancellationError() }
            guard let track else { throw SubtitleBrowserError.unreadable }
            if track.supportLevel == .unsupportedBitmap { throw SubtitleBrowserError.bitmap }
            guard track.isSelectable else { throw SubtitleBrowserError.unreadable }
            let timeline = try await self.readPrimaryTranslationTimeline(track: track, item: item)
            try Task.checkCancellation()
            return SubtitleBrowserDocument(parts: timeline.parts)
        }
    }

    private func localBrowserSource(item: VideoFile, id: String, offset: Double) -> SubtitleBrowserSource {
        let selectedID = currentSubtitleTrackID
        let generation = translationPlaybackGeneration
        return SubtitleBrowserSource(id: id, title: platformShellString("Primary"), revision: "original-local-tracks", offset: offset) { [weak self] in
            guard let self, self.translationPlaybackGeneration == generation else { throw CancellationError() }
            let originalIDs = try await MacSubtitleBrowserLocalTracks.read(from: item.url)
            let descriptors = try await MacSubtitleBrowserLocalTracks.readDescriptors(from: item.url)
            try Task.checkCancellation()
            guard self.translationPlaybackGeneration == generation else { throw CancellationError() }
            let tracks = self.localContainerSecondarySubtitleTracks(for: item, descriptors: descriptors)
                .sorted { ($0.streamIndex ?? -1) < ($1.streamIndex ?? -1) }
            guard let ordinal = MacSubtitleBrowserLocalTracks.ordinal(for: selectedID,
                originalTrackIDs: originalIDs, containerCount: tracks.count) else { throw SubtitleBrowserError.unreadable }
            let track = tracks[ordinal]
            if track.supportLevel == .unsupportedBitmap { throw SubtitleBrowserError.bitmap }
            guard track.isSelectable else { throw SubtitleBrowserError.unreadable }
            let timeline = try await self.readPrimaryTranslationTimeline(track: track, item: item)
            try Task.checkCancellation()
            return SubtitleBrowserDocument(parts: timeline.parts)
        }
    }

    private func remoteBrowserSource(item: VideoFile, id: String, offset: Double, selectedID: Int? = nil, title: String? = nil) -> SubtitleBrowserSource? {
        guard !item.url.isFileURL, !item.isLiveStream,
              [item.url.path, item.serverPath ?? "", item.name].contains(where: {
                  URL(fileURLWithPath: $0).pathExtension.lowercased() == "mkv"
              }), item.url.scheme?.lowercased() == "smb" || FileAudioRangeReader.supports(provider: item.serverType?.rawValue, url: item.url)
        else { return nil }
        let nativeTracks = subtitleTracks.filter {
            $0.id != -1 && $0.id < 10000 && !$0.isExternal &&
            translationImportedSubtitleURLs[$0.id] == nil && nativeToExternalTrackIDs[$0.id] == nil
        }
        guard let ordinal = nativeTracks.firstIndex(where: { $0.id == (selectedID ?? currentSubtitleTrackID) }) else { return nil }
        let generation = translationPlaybackGeneration
        let embeddedMPV = mpvTracks.filter { $0.type == "sub" && !$0.external }
        let numbers = embeddedMPV.compactMap(\.sourceID)
        let expectedNumbers = isUsingMPV && numbers.count == nativeTracks.count && numbers.allSatisfy({ $0 > 0 }) ? numbers : nil
        return SubtitleBrowserSource(id: id, title: title ?? platformShellString("Primary"), revision: "remote-mkv-\(nativeTracks.count)", offset: offset) { [weak self] in
            guard let self, self.translationPlaybackGeneration == generation else { throw CancellationError() }
            // Uses independent connections; no decoder state or playback input is touched.
            let metadata: () async throws -> AudioFileVersion
            let read: (UInt64, Int) async throws -> Data
            if item.url.scheme?.lowercased() == "smb" {
                let reader = SMBAudioRangeReader(url: RuntimeNetworkAddressResolver.runtimeURL(from: item.url))
                metadata = { let value = try await reader.metadata(); return .init(size: value.size, stamp: value.version) }
                read = { try await reader.read(offset: $0, count: $1) }
            } else {
                let reader = FileAudioRangeReader(url: item.url, provider: item.serverType?.rawValue,
                    serverID: item.jellyfinServerId, path: item.serverPath, itemID: item.jellyfinItemId)
                metadata = { try await reader.metadata() }
                read = { try await reader.read(offset: $0, count: $1) }
            }
            let version = try await metadata()
            try Task.checkCancellation()
            let key = "\(id)|\(ordinal)|\(nativeTracks.count)|\(version.size)|\(version.stamp)"
            if let cached = self.subtitleBrowserRemoteCache[key] { return cached }
            do {
                let result = try await MacRemoteSubtitleReader(size: version.size, read: read)
                    .load(subtitleOrdinal: ordinal, expectedSubtitleCount: nativeTracks.count, expectedTrackNumbers: expectedNumbers)
                guard try await metadata() == version else { throw URLError(.resourceUnavailable) }
                try Task.checkCancellation()
                guard self.translationPlaybackGeneration == generation else { throw CancellationError() }
                let document = SubtitleBrowserDocument(parts: result.parts, isPartial: result.indexed, partialStatusKey: "SB.Indexed")
                if self.subtitleBrowserRemoteCache.count >= 4 { self.subtitleBrowserRemoteCache.removeAll() }
                self.subtitleBrowserRemoteCache[key] = document
                return document
            } catch MacRemoteSubtitleReader.Failure.bitmap { throw SubtitleBrowserError.bitmap }
            catch MacRemoteSubtitleReader.Failure.limit { throw SubtitleBrowserError.remoteLimit }
            catch MacRemoteSubtitleReader.Failure.unsupported { throw SubtitleBrowserError.unreadable }
            catch MacRemoteSubtitleReader.Failure.trackMismatch { throw SubtitleBrowserError.unreadable }
        }
    }
}
#endif
