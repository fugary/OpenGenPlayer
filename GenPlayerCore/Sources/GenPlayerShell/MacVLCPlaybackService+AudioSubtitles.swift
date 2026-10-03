#if os(macOS)
import Foundation
import GenPlayerCore

extension MacVLCPlaybackService {
    internal func bindAudioSubtitles(for file: VideoFile) {
        var remote: MacJellyfinAudioSubtitles?
        if !file.url.isFileURL, let provider = MacJellyfinAudioSubtitles.Provider(rawValue: file.serverType?.rawValue ?? ""),
           let itemID = file.jellyfinItemId, !itemID.isEmpty,
           let serverID = file.jellyfinServerId,
           let server = AppNetworkService.shared.servers.first(where: { $0.id == UUID(uuidString: serverID) }),
           server.type == file.serverType, let url = URL(string: server.fullURL),
           let token = server.accessToken, !token.isEmpty {
            let queryID = URLComponents(url: file.url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame })?.value
            let sourceID = file.mediaSourceId ?? queryID
            remote = .init(serverURL: url, serverID: serverID, itemID: itemID,
                           mediaSourceID: sourceID?.isEmpty == false ? sourceID : nil, token: token, provider: provider)
        }
        var fileAudio: MP4AudioAccess?
        var fileAudioScope: String?
        if !file.url.isFileURL, file.serverType == .smb,
           ["mp4", "m4v", "m4a"].contains(file.url.pathExtension.lowercased()),
           var clean = URLComponents(url: file.url, resolvingAgainstBaseURL: false) {
            let reader = SMBAudioRangeReader(url: RuntimeNetworkAddressResolver.runtimeURL(from: file.url))
            clean.user = nil; clean.password = nil; clean.query = nil; clean.fragment = nil
            if let identityURL = clean.url {
                fileAudioScope = MacAudioSubtitlePlan.digest(["smb", file.jellyfinServerId ?? "",
                    identityURL.deletingLastPathComponent().absoluteString])
                fileAudio = MP4AudioAccess(identity: MacAudioSubtitlePlan.digest([file.jellyfinServerId ?? "", identityURL.absoluteString]), metadata: {
                    let metadata = try await reader.metadata()
                    return .init(size: metadata.size, stamp: metadata.version)
                }, read: { try await reader.read(offset: $0, count: $1) })
            }
        }
        if !file.isLiveStream, fileAudio == nil, FileAudioRangeReader.supports(provider: file.serverType?.rawValue, url: file.url),
           ["mp4", "m4v", "m4a"].contains(URL(fileURLWithPath: file.serverPath ?? file.url.path).pathExtension.lowercased()),
           let identity = MP4AudioAccess.fileIdentity(url: file.url, provider: file.serverType?.rawValue,
               serverID: file.jellyfinServerId, path: file.serverPath) {
            let kind = file.serverType?.rawValue ?? "http"
            let reader = FileAudioRangeReader(url: file.url, provider: file.serverType?.rawValue,
                serverID: file.jellyfinServerId, path: file.serverPath, itemID: file.jellyfinItemId)
            fileAudioScope = identity.scope
            fileAudio = MP4AudioAccess(identity: identity.identity, metadata: {
                let value = try await reader.metadata()
                return .init(size: value.size, stamp: value.stamp)
            }, read: { try await reader.read(offset: $0, count: $1) }, kind: kind)
        }
        audioSubtitles.bind(url: file.url, live: file.isLiveStream || file.serverType == .iptv, remote: remote, fileAudio: fileAudio,
            continuationScope: fileAudioScope ?? MacAudioSubtitleJob.continuationScope(url: file.url, provider: file.serverType?.rawValue,
                serverID: file.jellyfinServerId, seriesID: file.seriesId))
    }

    var generatedSubtitleName: String {
        let track = audioSubtitles.source?.tracks.first { $0.id == audioSubtitles.activeTrack }
        let original: String
        if let name = track?.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            original = name
        } else if let track, audioSubtitles.source?.remote == nil {
            let selectable = audioTracks.filter { $0.id != -1 }
            let byID = audioSubtitles.source?.decoder == .vlcRemux
                ? selectable.first(where: { $0.id == Int(track.id) }) : nil
            original = byID?.name ?? (selectable.indices.contains(track.ordinal - 1) ? selectable[track.ordinal - 1].name
                : String(format: platformShellString("AS.TrackName"), track.ordinal))
        } else {
            original = String(format: platformShellString("AS.TrackName"), track?.ordinal ?? 1)
        }
        return String(format: platformShellString("AS.GeneratedName"), original)
    }

    internal func configureAudioSubtitles() {
        audioSubtitles.playbackAudioSelection = { [weak self] in
            guard let self else { return nil }
            if self.isUsingMPV, let source = self.audioSubtitles.source, source.decoder == .vlcRemux {
                guard let selected = MacMPVAudioMapping.remuxSelection(selectedID: self.currentAudioTrackID,
                    tracks: self.mpvTracks, source: source.tracks.map { (Int($0.id), $0.ordinal) }) else { return nil }
                return (selected, source.tracks.map { Int($0.id) })
            }
            return (self.currentAudioTrackID, self.audioTracks.map(\.id))
        }
        audioSubtitles.onResultsChanged = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.refreshPrimarySubtitleTranslation()
            self.updateCurrentSecondarySubtitleParts(at: Double(self.currentTime) / 1000)
        }
        audioSubtitles.onDisplayChanged = { [weak self] display in
            guard let self else { return }
            switch display {
            case .configured:
                self.applyConfiguredAudioOutput()
            case .primary:
                self.audioSubtitleTranslationActive = false
                self.setSubtitleTrack(MacAudioSubtitlePlan.primaryID)
            case .translatedSecondary:
                self.audioSubtitleTranslationActive = true
                if self.currentSubtitleTrackID == MacAudioSubtitlePlan.primaryID { self.setSubtitleTrack(-1) }
                self.setSecondarySubtitleTrack(MacSubtitleTranslation.trackID)
            case .secondary:
                self.audioSubtitleTranslationActive = false
                guard UserDefaults.standard.bool(forKey: "enableSecondarySubtitlesBeta") else {
                    self.audioSubtitles.select(.off)
                    return
                }
                if self.currentSubtitleTrackID == MacAudioSubtitlePlan.primaryID { self.setSubtitleTrack(-1) }
                self.setSecondarySubtitleTrack(MacAudioSubtitlePlan.secondaryID)
            case .off:
                if self.currentSubtitleTrackID == MacAudioSubtitlePlan.primaryID { self.setSubtitleTrack(-1) }
                let wasAudioTranslation = self.audioSubtitleTranslationActive
                self.audioSubtitleTranslationActive = false
                if self.currentSecondarySubtitleTrackID == MacAudioSubtitlePlan.secondaryID || wasAudioTranslation {
                    self.setSecondarySubtitleTrack(nil)
                }
            }
        }
    }

    private func applyConfiguredAudioOutput() {
        if !audioSubtitles.hasActiveOutput && !audioSubtitleTranslationActive
            && currentSubtitleTrackID != MacAudioSubtitlePlan.primaryID
            && currentSecondarySubtitleTrackID != MacAudioSubtitlePlan.secondaryID { return }
        audioSubtitleTranslationActive = audioSubtitles.translatesAudio
        if audioSubtitles.uses(.primary) {
            activateConfiguredAudioPrimary()
        } else if currentSubtitleTrackID == MacAudioSubtitlePlan.primaryID {
            if let mpvEngine { mpvEngine.set("sid", "no") }
            else { mediaPlayer?.currentVideoSubTitleIndex = -1 }
            currentSubtitleTrackID = -1
        }
        if audioSubtitles.uses(.secondary) {
            clearMPVSecondarySelection(persistPreference: false)
            secondarySubtitleLoadTask?.cancel()
            secondarySubtitleTimeline = nil
            pendingSecondarySubtitleTrackQuery = nil
            pendingSecondarySubtitleTrackOrdinal = nil
            currentSecondarySubtitleTrackID = audioSubtitles.activeTranslationDestination == .secondary
                ? MacSubtitleTranslation.trackID : MacAudioSubtitlePlan.secondaryID
            secondarySubtitleStatus = .ready
        } else if currentSecondarySubtitleTrackID == MacAudioSubtitlePlan.secondaryID || currentSecondarySubtitleTrackID == MacSubtitleTranslation.trackID {
            currentSecondarySubtitleTrackID = nil
            currentSecondarySubtitleParts = []
            secondarySubtitleStatus = .idle
        }
        pendingPrimarySubtitleTranslationRestore = false
        if let file = currentFile { savePrimarySubtitleTranslationPreference(for: file, enabled: false) }
        if audioSubtitles.translatesAudio {
            subtitleTranslation.setEnabled(true)
            subtitleTranslation.followsAudioRouting = true
            followGeneratedPrimaryTranslation()
        } else if subtitleTranslation.enabled { subtitleTranslation.setEnabled(false) }
        updateCurrentSecondarySubtitleParts(at: Double(currentTime) / 1000)
        objectWillChange.send()
    }

    var generatedPrimaryParts: [SubtitlePart] {
        guard currentSubtitleTrackID == MacAudioSubtitlePlan.primaryID else { return [] }
        let time = Double(currentTime) / 1000 - UserDefaults.standard.double(forKey: "subtitleDelaySeconds")
        if audioSubtitles.isConfigured {
            return subtitleTranslation.audioParts(at: time, cues: audioSubtitles.cues,
                original: audioSubtitles.activeOriginalDestination == .primary,
                translated: audioSubtitles.activeTranslationDestination == .primary)
        }
        return audioSubtitles.activeCues(at: time).map {
            SubtitlePart(start: $0.start, end: $0.end, text: NSAttributedString(string: $0.text))
        }
    }

    var generatedPrimaryText: String { generatedPrimaryParts.compactMap { $0.text?.string }.joined(separator: "\n") }

    internal func followGeneratedPrimaryTranslation() {
        guard let key = audioSubtitles.cache?.key else { return }
        subtitleTranslation.followGenerated(key: "\(translationPlaybackGeneration)|\(key)",
            language: audioSubtitles.activeLanguage, cues: audioSubtitles.cues)
    }
}
#endif
