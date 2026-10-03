import Foundation
import GenPlayerShell
import MediaPlayer
#if os(iOS)
import UIKit
#endif
import VLCKitSPM

// MARK: - VLCMediaPlayerDelegate (Event Handling)
extension VLCPlaybackService: VLCMediaPlayerDelegate {
    func mediaPlayerStateChanged(_ aNotification: Notification) {
        let callbackPlayer = aNotification.object as? VLCMediaPlayer
        let attemptID = playbackAttemptID
        DispatchQueue.main.async {
            guard !self.isUsingMPV, self.playbackAttemptID == attemptID, !self.isPreparingPlayback,
                  !self.hasTerminalPlaybackFailure,
                  !self.isPlaybackSuspendedForBackground else { return }
            if let callbackPlayer = callbackPlayer, callbackPlayer !== self.mediaPlayer {
                return
            }

            let playerState = callbackPlayer?.state ?? self.mediaPlayer?.state
            if self.state.currentItem == nil {
                if playerState == .stopped {
                    self.state.status = .idle
                    self.updateNowPlayingInfo()
                }
                return
            }

            let controlID = self.playbackControlID
            switch playerState {
            case .buffering, .opening:
                // Buffering notifications alone do not prove that playback output has stopped.
                self.pendingPlayingWorkItem?.cancel()
                self.pendingPlayingWorkItem = nil
                // While paused, seeking may transiently emit buffering events.
                // Keep paused UI semantics unless playback is actually running.
                if !(self.state.status == .paused && !(self.mediaPlayer?.isPlaying ?? false)) {
                    self.state.status = self.shouldShowPlaybackBuffering() ? .buffering : .playing
                }
                // Don't cancel metadata extraction during buffering
                
            case .playing:
                self.pendingPlayingWorkItem?.cancel()
                self.pendingPlayingWorkItem = nil
                self.hasStartedPlaybackForCurrentItem = true
                let shouldBuffer = self.shouldShowPlaybackBuffering()
                if !shouldBuffer && !self.isAwaitingSeekPlayback { self.clearPlaybackFailure() }
                self.state.status = shouldBuffer ? .buffering : .playing
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.isCurrentPlaybackControl(attemptID: attemptID, controlID: controlID) else { return }
                    self.refreshTracks()
                }
                
                // Trigger detached metadata extraction if not already scheduled
                if self.pendingMetadataWorkItem == nil {
                    let metaItem = DispatchWorkItem { [weak self] in
                        guard let self, self.isCurrentPlaybackControl(attemptID: attemptID, controlID: controlID) else { return }
                        self.extractMetadata()
                        self.pendingMetadataWorkItem = nil
                    }
                    self.pendingMetadataWorkItem = metaItem
                    // Start extraction almost immediately (0.1s)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: metaItem)
                }
                
            case .paused:
                self.pendingPlayingWorkItem?.cancel()
                if self.state.currentItem != nil,
                   Date().timeIntervalSinceReferenceDate < self.pictureInPictureSeekResumeGraceDeadline {
                    self.state.status = .buffering
                    print("[PiP] suppressing transient paused state during skip")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
                        guard let self, self.isCurrentPlaybackControl(attemptID: attemptID, controlID: controlID) else { return }
                        guard Date().timeIntervalSinceReferenceDate < self.pictureInPictureSeekResumeGraceDeadline else { return }
                        guard !(self.mediaPlayer?.isPlaying ?? false) else { return }
                        print("[PiP] resuming playback after transient paused state")
                        self.togglePlayPause()
                    }
                } else {
                    self.state.status = .paused
                    self.resetPlaybackStallDetection()
                }
                // Don't cancel metadata extraction during pause
            case .error:
                self.pendingPlayingWorkItem?.cancel()
                self.pendingMetadataWorkItem?.cancel()
                self.pendingMetadataWorkItem = nil
                self.schedulePlaybackFailureIfNeeded()
            case .stopped:
                self.pendingPlayingWorkItem?.cancel()
                self.pendingMetadataWorkItem?.cancel()
                self.pendingMetadataWorkItem = nil
                let stoppedDuringStartup = !self.isRecoveringFromFalseEnded
                    && !self.isStopInProgress
                    && self.state.currentItem != nil
                    && !self.hasStartedPlaybackForCurrentItem

                if stoppedDuringStartup {
                    self.schedulePlaybackFailureIfNeeded()
                } else if self.isRecoveringFromFalseEnded {
                } else {
                    self.state.status = .idle
                }
            case .ended:
                self.pendingPlayingWorkItem?.cancel()
                self.pendingMetadataWorkItem?.cancel()
                self.pendingMetadataWorkItem = nil
                // VLC bug: seek can falsely trigger .ended state
                // If current time is far from duration, this is a seek artifact — recover
                if self.state.duration > 0 && self.state.currentTime < self.state.duration - 5 {
                    let seekTime = self.state.currentTime
                    let localSeekTime = self.playerLocalTime(fromLogicalTime: seekTime)
                    self.isRecoveringFromFalseEnded = true
                    self.state.status = .buffering
                    
                    // play() alone can't recover after .ended → .stopped (VLC releases internal resources)
                    // Re-create media with :start-time to let VLC natively start at correct position
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                        guard let self, self.isCurrentPlaybackControl(attemptID: attemptID, controlID: controlID) else { return }
                        self.isRecoveringFromFalseEnded = false
                        if let url = self.state.currentItem?.url,
                           let item = self.state.currentItem {
                            guard PlaybackEngineAvailability.current.vlc else { return }
                            let media = VLCMedia(url: url)
                            self.configureMediaOptions(media, for: item)
                            if localSeekTime > 1.0 {
                                media.addOption(":start-time=\(Int(localSeekTime))")
                            }
                            self.mediaPlayer?.media = media
                            self.mediaPlayer?.play()
                            self.state.currentTime = seekTime
                        }
                    }
                } else {
                    let isAudioContext = !self.floatingAudioPlaylist.isEmpty && self.floatingAudioPlaylist.contains(where: { $0.url == self.state.currentItem?.url })
                    if isAudioContext {
                        _ = self.playNextAudio(autoTriggered: true)
                    } else {
                        self.state.status = .ended
                        self.reportServerStopped()
                    }
                }
            default:
                break
            }
            if #available(iOS 15.0, *) {
                self.videoPiPController?.invalidatePlaybackStateIfNeeded(force: true)
            }
            self.updateNowPlayingInfo()
        }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        if let callbackPlayer = aNotification.object as? VLCMediaPlayer,
           callbackPlayer !== mediaPlayer {
            return
        }

        guard state.currentItem != nil, !isPreparingPlayback, !hasTerminalPlaybackFailure else { return }
        let attemptID = playbackAttemptID
        let controlID = playbackControlID

        let currentTimeMs = (mediaPlayer?.time.intValue ?? 0)
        let durationMs = mediaPlayer?.media?.length.intValue ?? 0
        let preciseTime = Double(currentTimeMs) / 1000.0
        let resolvedDuration = resolvedPlaybackDuration(vlcDuration: Double(durationMs) / 1000.0)
        let logicalTime = logicalPlaybackTime(fromPlayerTime: preciseTime, duration: resolvedDuration)
        
        let didAdvanceTime = abs(logicalTime - lastTimeChangedPosition) > 0.01
        if didAdvanceTime {
            lastTimeChangedPosition = logicalTime
        }

        // 1. UI Throttling (10 FPS)
        if abs(logicalTime - lastUIUpdateTime) < 0.1 { return }
        lastUIUpdateTime = logicalTime
        
        DispatchQueue.main.async {
            guard !self.isUsingMPV, self.isCurrentPlaybackControl(attemptID: attemptID, controlID: controlID) else { return }
            if preciseTime > 0.5 && didAdvanceTime {
                self.hasStartedPlaybackForCurrentItem = true
            }
            let shouldBuffer = self.shouldShowPlaybackBuffering()
            if preciseTime > 0.5 && didAdvanceTime && !shouldBuffer && !self.isAwaitingSeekPlayback {
                self.clearPlaybackFailure()
            }
            // Even while menus are frozen, allow the player to clear a stale
            // buffering state once playback is actually advancing.
            if self.state.status == .buffering && (self.mediaPlayer?.isPlaying ?? false) && !shouldBuffer {
                self.state.status = .playing
            }

            self.updateCurrentSecondarySubtitleParts(at: logicalTime)

            self.state.duration = resolvedDuration

            // Check if we have an active playback resume guard (e.g. recovering from PiP or seeking on restart)
            let isUnderResumeGuard: Bool
            if let guardTarget = self.pendingPlaybackResumeTimeGuard {
                let now = Date().timeIntervalSinceReferenceDate
                if now < self.pendingPlaybackResumeTimeGuardDeadline {
                    if logicalTime < max(0, guardTarget - 1.5) {
                        isUnderResumeGuard = true
                    } else {
                        self.pendingPlaybackResumeTimeGuard = nil
                        self.pendingPlaybackResumeTimeGuardDeadline = .zero
                        isUnderResumeGuard = false
                    }
                } else {
                    self.pendingPlaybackResumeTimeGuard = nil
                    self.pendingPlaybackResumeTimeGuardDeadline = .zero
                    isUnderResumeGuard = false
                }
            } else {
                isUnderResumeGuard = false
            }

            if !isUnderResumeGuard {
                self.state.currentTime = logicalTime
                self.state.progress = self.resolvedPlaybackProgress(
                    currentTime: logicalTime,
                    duration: resolvedDuration,
                    fallbackPosition: (self.mediaPlayer?.position ?? 0)
                )
            }
            
            // Legacy Safe Seek (fallback — initial seek now uses :start-time VLC option)
            if let seekPos = self.pendingSeekPosition, !self.initialSeekPerformed {
                if (self.mediaPlayer?.isSeekable ?? false) && (preciseTime > 0.5 || (self.mediaPlayer?.isPlaying ?? false)) {
                    print("[VLC] Fallback Safe Seek to \(seekPos)")
                    self.mediaPlayer?.time = VLCTime(int: Int32(seekPos * 1000))
                    self.initialSeekPerformed = true
                    self.pendingSeekPosition = nil
                    self.state.currentTime = seekPos
                    return
                }
            }
            
            // Periodic Tasks
            self.handlePeriodicTasks(at: logicalTime)
        }
    }

    func mediaPlayerSnapshot(_ aNotification: Notification) {
        guard let callbackPlayer = aNotification.object as? VLCMediaPlayer,
              callbackPlayer === mediaPlayer else {
            return
        }

        if #available(iOS 15.0, *) {
            videoPiPController?.handleMediaPlayerSnapshot(from: callbackPlayer)
        }
    }
    
    private func handlePeriodicTasks(at time: Double) {
        // Report "Playing" to server once per playback session
        if !hasReportedServerPlaying {
            if ensureServerPlaybackContextIfNeeded() {
                print("[ServerSync] 🟢 First tick — calling reportServerPlaying()")
                hasReportedServerPlaying = reportServerPlaying()
            }
        }
        
        // Track Refresh (Adaptive: 2s initially, then 30s, or 2s if pending tracks exist)
        let hasPendingTracks = pendingAudioTrack != nil || pendingSubtitleTrack != nil
        let hasTracks = !state.audioTracks.isEmpty || !state.subtitleTracks.isEmpty
        let refreshInterval = (hasTracks && !hasPendingTracks) ? 30.0 : 2.0
        if isMenuPresented {
            lastTracksRefreshTime = time
        } else if abs(time - lastTracksRefreshTime) > refreshInterval, refreshTracks() {
            lastTracksRefreshTime = time
        }
        
        // History & Server Progress (Every 5s)
        if abs(time - lastSavedTime) > 5.0 {
            lastSavedTime = time
            saveProgress()
            reportServerProgress(reason: "periodic")
        }

        // Keep lock screen / Dynamic Island progress in sync while running.
        if state.status == .playing || state.status == .buffering || (mediaPlayer?.isPlaying ?? false) {
            if abs(time - lastNowPlayingRefreshTime) >= 1.0 {
                lastNowPlayingRefreshTime = time
                updateNowPlayingInfo()
            }
        }
    }
}

// MARK: - Track Management
extension VLCPlaybackService {
    @discardableResult
    func refreshTracks(force: Bool = false) -> Bool {
        if isUsingMPV {
            if force { refreshSecondarySubtitleTracks() }
            return false
        }
        guard state.currentItem != nil else {
            if !state.audioTracks.isEmpty {
                state.audioTracks = []
            }
            if !state.subtitleTracks.isEmpty {
                state.subtitleTracks = []
            }
            return false
        }

        if isMenuPresented && !force {
            deferredTrackRefreshNeeded = true
            return false
        }
        deferredTrackRefreshNeeded = false

        // Audio
        if let names = mediaPlayer?.audioTrackNames as? [String],
           let indexes = mediaPlayer?.audioTrackIndexes as? [Int] {
            var tracks: [MediaTrack] = []
            var seenTrackIDs = Set<Int>()
            for (i, index) in indexes.enumerated() {
                if i < names.count, seenTrackIDs.insert(index).inserted {
                    tracks.append(MediaTrack(id: index, name: names[i], isExternal: false))
                }
            }
            tracks = applyingServerTrackNames(tracks, type: "Audio")
            if state.audioTracks != tracks {
                state.audioTracks = tracks
            }
        }
        
        // Subtitles (internal + external sidecars)
        var subtitleTracks: [MediaTrack] = []
        if let names = mediaPlayer?.videoSubTitlesNames as? [String],
           let indexes = mediaPlayer?.videoSubTitlesIndexes as? [Int] {
            
            // For local files, VLC auto-loads external sidecar subtitles but names them "Track X".
            // We map our known local candidates to the trailing unresolved "Track X" tracks.
            var mappedCandidatesForIndex = [Int: URL]()
            if state.currentItem?.url.isFileURL == true && !externalSubtitleCandidates.isEmpty {
                var genericTrackIndices: [Int] = []
                for (i, name) in names.enumerated() {
                    let trackID = i < indexes.count ? indexes[i] : -1
                    let isAlreadyResolved = externalSubtitleResolvedTrackIDs.values.contains(trackID)
                    if !isAlreadyResolved && (name.starts(with: "Track ") || name.starts(with: "Subtitle ")) {
                        genericTrackIndices.append(i)
                    }
                }
                
                let unmappedCandidates = externalSubtitleCandidates.filter { url in
                    let key = subtitleURLKey(url)
                    return externalSubtitleResolvedTrackIDs[key] == nil
                }
                
                let startIndexToMap = max(0, genericTrackIndices.count - unmappedCandidates.count)
                for i in startIndexToMap..<genericTrackIndices.count {
                    let candidateIndex = i - startIndexToMap
                    if candidateIndex < unmappedCandidates.count {
                        mappedCandidatesForIndex[genericTrackIndices[i]] = unmappedCandidates[candidateIndex]
                    }
                }
            }

            var seenTrackIDs = Set<Int>()
            for (i, index) in indexes.enumerated() {
                if i < names.count, seenTrackIDs.insert(index).inserted {
                    var finalName = index == -1 ? NSLocalizedString("Off", comment: "") : names[i]
                    if let key = externalSubtitleResolvedTrackIDs.first(where: { $1 == index })?.key,
                       let displayName = externalSubtitleDisplayNames[key] ?? URL(string: key)?.deletingPathExtension().lastPathComponent {
                        if !displayName.isEmpty && (finalName.starts(with: "Track ") || finalName.starts(with: "Subtitle ")) {
                            if let range = finalName.range(of: " - [") {
                                finalName = displayName + String(finalName[range.lowerBound...])
                            } else {
                                finalName = displayName
                            }
                        }
                    } else if let matchedURL = mappedCandidatesForIndex[i] {
                        let key = subtitleURLKey(matchedURL)
                        let displayName = externalSubtitleDisplayNames[key] ?? matchedURL.deletingPathExtension().lastPathComponent
                        if !displayName.isEmpty {
                            if let range = finalName.range(of: " - [") {
                                finalName = displayName + String(finalName[range.lowerBound...])
                            } else {
                                finalName = displayName
                            }
                        }
                    }
                    subtitleTracks.append(MediaTrack(id: index, name: finalName, isExternal: false))
                }
            }
        }
        subtitleTracks = applyingServerTrackNames(subtitleTracks, type: "Subtitle", external: false)
        resolveNativeExternalSubtitleTrackIDs(in: subtitleTracks)
        subtitleTracks = applyingResolvedExternalSubtitleDisplayNames(to: subtitleTracks)

        if let currentItem = state.currentItem,
           externalSubtitleMediaKey == mediaKey(for: currentItem.url),
           !externalSubtitleCandidates.isEmpty {
            let nativeSubtitleIDs = Set(subtitleTracks.map { $0.id })
            let nativeSubtitleTrackCount = subtitleTracks.reduce(0) { partial, track in
                partial + (track.id == -1 ? 0 : 1)
            }
            let selectedExternalKey = state.currentItem?.externalSubtitleURL.map(subtitleURLKey)
            if let selectedExternalKey,
               let resolvedSelectedTrackID = externalSubtitleResolvedTrackIDs[selectedExternalKey],
               nativeSubtitleIDs.contains(resolvedSelectedTrackID),
               Int((mediaPlayer?.currentVideoSubTitleIndex ?? -1)) == -1 {
                mediaPlayer?.currentVideoSubTitleIndex = Int32(resolvedSelectedTrackID)
            }
            // For remote playback, keep synthetic external entries visible. VLC may not expose them as native tracks.
            let shouldHideSelectedExternalSynthetic = currentItem.url.isFileURL
            for (offset, url) in externalSubtitleCandidates.enumerated() {
                let key = subtitleURLKey(url)
                if let resolvedTrackID = externalSubtitleResolvedTrackIDs[key],
                   nativeSubtitleIDs.contains(resolvedTrackID) {
                    // VLC already exposes this external subtitle as a native track ID.
                    continue
                }
                if shouldHideSelectedExternalSynthetic, selectedExternalKey == key {
                    // Current external subtitle is already exposed by VLC as a regular track.
                    continue
                }
                let displayName = externalSubtitleDisplayNames[key] ?? url.deletingPathExtension().lastPathComponent
                let fallbackName = displayName.isEmpty ? "Track \(nativeSubtitleTrackCount + offset + 1)" : displayName
                subtitleTracks.append(
                    MediaTrack(
                        id: externalSubtitleTrackBaseID + offset,
                        name: fallbackName,
                        isExternal: true
                    )
                )
            }
        }
        
        if state.subtitleTracks != subtitleTracks {
            state.subtitleTracks = subtitleTracks
        }
        refreshSecondarySubtitleTracks()
        
        // Restore Pending Audio Tracks
        restoreVLCEngineTracks()
        if let audio = pendingAudioTrack {
            if audio == -1 {
                state.currentAudioTrackID = -1
                mediaPlayer?.currentAudioTrackIndex = -1
                pendingAudioTrack = nil
            } else if state.audioTracks.contains(where: {$0.id == audio}) {
                state.currentAudioTrackID = audio
                mediaPlayer?.currentAudioTrackIndex = Int32(audio)
                pendingAudioTrack = nil
            } else if !state.audioTracks.isEmpty {
                // Give up if tracks are loaded but our target still isn't found
                pendingAudioTrack = nil
            }
        } else if let query = pendingAudioTrackQuery {
            if let matched = state.audioTracks.first(where: { $0.id != -1 && trackNameMatches($0.name, query: query) }) {
                state.currentAudioTrackID = matched.id
                mediaPlayer?.currentAudioTrackIndex = Int32(matched.id)
                pendingAudioTrackQuery = nil
                pendingAudioTrackOrdinal = nil
            } else if let ordinal = pendingAudioTrackOrdinal,
                      let fallback = selectableTrack(at: ordinal, from: state.audioTracks) {
                state.currentAudioTrackID = fallback.id
                mediaPlayer?.currentAudioTrackIndex = Int32(fallback.id)
                pendingAudioTrackQuery = nil
                pendingAudioTrackOrdinal = nil
            } else if state.audioTracks.contains(where: { $0.id != -1 }) {
                pendingAudioTrackQuery = nil
                pendingAudioTrackOrdinal = nil
            }
        } else if (mediaPlayer?.currentAudioTrackIndex ?? -1) == -1, !state.audioTracks.isEmpty, !preservesDisabledAudio {
            // Fix "Disabled" default: Force first VALID track (not -1) if none selected
            if let firstValid = state.audioTracks.first(where: { $0.id != -1 }) {
                mediaPlayer?.currentAudioTrackIndex = Int32(firstValid.id)
                if state.currentAudioTrackID != firstValid.id {
                    state.currentAudioTrackID = firstValid.id
                }
            }
        } else {
            let actualAudio = Int((mediaPlayer?.currentAudioTrackIndex ?? -1))
            if state.currentAudioTrackID != actualAudio {
                state.currentAudioTrackID = actualAudio
            }
        }
        
        subtitleIntelligence.refreshDefaultAudioTrack()
        // A generated primary may restore before VLC finishes opening. Keep native
        // auto-selection from placing a second primary underneath the generated overlay.
        if subtitleIntelligence.isGeneratedPrimary {
            mediaPlayer?.currentVideoSubTitleIndex = -1
            state.currentSubtitleTrackID = -1
            pendingSubtitleTrack = nil
            pendingSubtitleTrackQuery = nil
            pendingSubtitleTrackOrdinal = nil
        } else if let sub = pendingSubtitleTrack {
            if sub == -1 {
                hasResolvedAutomaticSubtitleSelection = true
                state.currentSubtitleTrackID = -1
                mediaPlayer?.currentVideoSubTitleIndex = -1
                state.currentItem?.externalSubtitleURL = nil
                pendingSubtitleTrack = nil
                pendingSubtitleTrackQuery = nil
                pendingSubtitleTrackOrdinal = nil
            } else if isExternalSubtitleTrack(sub) {
                hasResolvedAutomaticSubtitleSelection = true
                if let externalURL = externalSubtitleURL(forTrackID: sub) {
                    state.currentItem?.externalSubtitleURL = externalURL
                }
                pendingSubtitleTrack = nil
            } else if state.subtitleTracks.contains(where: {$0.id == sub}) {
                hasResolvedAutomaticSubtitleSelection = true
                state.currentSubtitleTrackID = sub
                mediaPlayer?.currentVideoSubTitleIndex = Int32(sub)
                pendingSubtitleTrack = nil
                pendingSubtitleTrackQuery = nil
                pendingSubtitleTrackOrdinal = nil
            } else if !state.subtitleTracks.isEmpty {
                // If the saved numeric track ID no longer exists, fall through to
                // the stored name/ordinal fallback on the next refresh.
                pendingSubtitleTrack = nil
            }
        } else if let query = pendingSubtitleTrackQuery {
            if let matched = state.subtitleTracks.first(where: { $0.id != -1 && trackNameMatches($0.name, query: query) }) {
                hasResolvedAutomaticSubtitleSelection = true
                if matched.isExternal {
                    setSubtitleTrack(matched.id)
                } else {
                    state.currentSubtitleTrackID = matched.id
                    mediaPlayer?.currentVideoSubTitleIndex = Int32(matched.id)
                }
                pendingSubtitleTrackQuery = nil
                pendingSubtitleTrackOrdinal = nil
            } else if let ordinal = pendingSubtitleTrackOrdinal,
                      let fallback = selectableTrack(at: ordinal, from: state.subtitleTracks) {
                hasResolvedAutomaticSubtitleSelection = true
                if fallback.isExternal {
                    setSubtitleTrack(fallback.id)
                } else {
                    state.currentSubtitleTrackID = fallback.id
                    mediaPlayer?.currentVideoSubTitleIndex = Int32(fallback.id)
                }
                pendingSubtitleTrackQuery = nil
                pendingSubtitleTrackOrdinal = nil
            } else if state.subtitleTracks.contains(where: { $0.id != -1 }) {
                pendingSubtitleTrackQuery = nil
                pendingSubtitleTrackOrdinal = nil
            }
        } else {
            let actualSub = Int((mediaPlayer?.currentVideoSubTitleIndex ?? -1))
            if applyAutomaticSubtitleSelectionIfNeeded() {
                return true
            }
            if state.currentSubtitleTrackID != actualSub {
                state.currentSubtitleTrackID = actualSub
            }
        }

        refreshSecondarySubtitleTracks()
        fitMacWindowToVideoAspectRatioIfNeeded()
        return true
    }

    private func trackNameMatches(_ trackName: String, query: String) -> Bool {
        let normalizedTrack = normalizedTrackQuery(trackName)
        let normalizedQuery = normalizedTrackQuery(query)
        guard !normalizedTrack.isEmpty, !normalizedQuery.isEmpty else { return false }
        return normalizedTrack.contains(normalizedQuery) || normalizedQuery.contains(normalizedTrack)
    }

    private func resolveNativeExternalSubtitleTrackIDs(in tracks: [MediaTrack]) {
        guard !externalSubtitleCandidates.isEmpty else { return }

        let nativeTracks = tracks.filter { $0.id != -1 && !$0.isExternal }
        guard !nativeTracks.isEmpty else { return }

        var usedTrackIDs = Set(
            externalSubtitleResolvedTrackIDs.values.filter { trackID in
                nativeTracks.contains(where: { $0.id == trackID })
            }
        )

        for url in externalSubtitleCandidates {
            let key = subtitleURLKey(url)
            if let resolvedTrackID = externalSubtitleResolvedTrackIDs[key],
               nativeTracks.contains(where: { $0.id == resolvedTrackID }) {
                usedTrackIDs.insert(resolvedTrackID)
                continue
            }

            let displayName = externalSubtitleDisplayNames[key] ?? url.deletingPathExtension().lastPathComponent
            guard let matchedTrackID = matchingNativeSubtitleTrackID(
                for: displayName,
                among: nativeTracks,
                excluding: usedTrackIDs
            ) else {
                continue
            }

            externalSubtitleResolvedTrackIDs[key] = matchedTrackID
            usedTrackIDs.insert(matchedTrackID)
        }

        let unresolvedCandidates = externalSubtitleCandidates.filter { url in
            let key = subtitleURLKey(url)
            return externalSubtitleResolvedTrackIDs[key] == nil
        }
        let genericNativeTracks = nativeTracks.filter { track in
            !usedTrackIDs.contains(track.id) && isGenericNativeSubtitleTrackName(track.name)
        }

        guard !unresolvedCandidates.isEmpty,
              unresolvedCandidates.count == genericNativeTracks.count else {
            return
        }

        for (candidateURL, track) in zip(unresolvedCandidates, genericNativeTracks) {
            let key = subtitleURLKey(candidateURL)
            externalSubtitleResolvedTrackIDs[key] = track.id
            usedTrackIDs.insert(track.id)
        }
    }

    private func applyingResolvedExternalSubtitleDisplayNames(to tracks: [MediaTrack]) -> [MediaTrack] {
        guard !tracks.isEmpty else { return tracks }

        return tracks.map { track in
            guard !track.isExternal,
                  track.id != -1,
                  let key = externalSubtitleResolvedTrackIDs.first(where: { $1 == track.id })?.key else {
                return track
            }

            let candidateURL = externalSubtitleCandidates.first { subtitleURLKey($0) == key }
            let resolvedDisplayName = candidateURL.map { externalSubtitleDisplayName(for: $0) }
                ?? URL(string: key)?.deletingPathExtension().lastPathComponent
            let finalName = isGenericNativeSubtitleTrackName(track.name)
                ? (resolvedDisplayName?.isEmpty == false ? resolvedDisplayName! : track.name)
                : track.name

            return MediaTrack(id: track.id, name: finalName, isExternal: true)
        }
    }

    private func matchingNativeSubtitleTrackID(
        for displayName: String,
        among tracks: [MediaTrack],
        excluding excludedTrackIDs: Set<Int>
    ) -> Int? {
        let normalizedDisplayName = normalizedTrackQuery(displayName)
        guard !normalizedDisplayName.isEmpty else { return nil }

        let candidateTracks = tracks.filter { !excludedTrackIDs.contains($0.id) }
        let exactMatches = candidateTracks.filter { normalizedTrackQuery($0.name) == normalizedDisplayName }
        if exactMatches.count == 1 {
            return exactMatches[0].id
        }

        let relaxedMatches = candidateTracks.filter { trackNameMatches($0.name, query: displayName) }
        if relaxedMatches.count == 1 {
            return relaxedMatches[0].id
        }

        return nil
    }

    private func isGenericNativeSubtitleTrackName(_ name: String) -> Bool {
        var normalized = normalizedTrackQuery(name)
        let codecTokens = ["ass", "ssa", "srt", "subrip", "vtt", "sub"]
        codecTokens.forEach { token in
            normalized = normalized.replacingOccurrences(of: token, with: "")
        }
        let genericTokens = ["default", "forced", "subtitle", "subtitles", "caption", "captions", "track", "external", "internal"]
        genericTokens.forEach { token in
            normalized = normalized.replacingOccurrences(of: token, with: "")
        }
        return normalized.isEmpty
    }

    private func normalizedTrackQuery(_ value: String) -> String {
        let lowered = value.lowercased()
        let allowed = CharacterSet.alphanumerics
        return String(lowered.unicodeScalars.filter { allowed.contains($0) })
    }

    private func applyingServerTrackNames(
        _ tracks: [MediaTrack],
        type: String,
        external: Bool? = nil
    ) -> [MediaTrack] {
        let serverNames = serverTrackDisplayNames(type: type, external: external)
        let selectableIndices = tracks.indices.filter { tracks[$0].id != -1 && (external == nil || tracks[$0].isExternal == external) }

        guard !serverNames.isEmpty, selectableIndices.count == serverNames.count else {
            return tracks
        }

        var renamed = tracks
        for (offset, index) in selectableIndices.enumerated() {
            let displayName = serverNames[offset]
            guard !displayName.isEmpty else { continue }
            renamed[index] = MediaTrack(
                id: tracks[index].id,
                name: displayName,
                isExternal: tracks[index].isExternal
            )
        }
        return renamed
    }

    private func serverTrackDisplayNames(type: String, external: Bool? = nil) -> [String] {
        guard let streams = state.currentItem?.serverMediaStreams, !streams.isEmpty else { return [] }

        return streams.compactMap { stream in
            guard ((stream["Type"] as? String) ?? "") == type else { return nil }
            if let external, serverTrackBooleanValue(stream["IsExternal"]) != external {
                return nil
            }

            if type == "Subtitle" {
                return formattedServerSubtitleTrackDisplayName(stream)
            }

            if let title = cleanedServerTrackMetadataValue(stream["DisplayTitle"] as? String), !title.isEmpty {
                return title
            }

            let language = cleanedServerTrackMetadataValue(stream["Language"] as? String)
            let codec = cleanedServerTrackMetadataValue(stream["Codec"] as? String)
            let channels = stream["Channels"] as? Int

            var parts: [String] = []
            if let language, !language.isEmpty { parts.append(language.uppercased()) }
            if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
            if let channels, channels > 0, type == "Audio" { parts.append("\(channels)ch") }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }

    private func formattedServerSubtitleTrackDisplayName(_ stream: [String: Any]) -> String? {
        let title = cleanedServerSubtitlePresentationMetadataValue(stream["DisplayTitle"] as? String)
        let alternateTitle = cleanedServerSubtitlePresentationMetadataValue(stream["Title"] as? String)
        let displayLanguage = cleanedServerSubtitleLanguageMetadataValue(stream["DisplayLanguage"] as? String)
        let language = cleanedServerSubtitleLanguageMetadataValue(stream["Language"] as? String)
        let codec = cleanedServerTrackMetadataValue(stream["Codec"] as? String)?.uppercased()
        let isDefault = serverTrackBooleanValue(stream["IsDefault"])
        let isForced = serverTrackBooleanValue(stream["IsForced"])
        let normalizedTitle = normalizedServerTrackMetadataValue(title)

        var parts: [String] = []
        if let title,
           !title.isEmpty,
           !isGenericServerSubtitleDisplayTitle(title, codec: codec) {
            parts.append(title)
        }

        if let alternateTitle,
           !alternateTitle.isEmpty,
           !normalizedTitle.contains(normalizedServerTrackMetadataValue(alternateTitle)),
           !parts.contains(where: { normalizedServerTrackMetadataValue($0) == normalizedServerTrackMetadataValue(alternateTitle) }),
           !isGenericServerSubtitleDisplayTitle(alternateTitle, codec: codec) {
            parts.append(alternateTitle)
        }

        if let displayLanguage,
           !displayLanguage.isEmpty,
           !normalizedTitle.contains(normalizedServerTrackMetadataValue(displayLanguage)),
           !parts.contains(where: { normalizedServerTrackMetadataValue($0) == normalizedServerTrackMetadataValue(displayLanguage) }) {
            parts.append(displayLanguage)
        }

        if let language,
           !language.isEmpty,
           !normalizedTitle.contains(normalizedServerTrackMetadataValue(language)),
           !parts.contains(where: { normalizedServerTrackMetadataValue($0) == normalizedServerTrackMetadataValue(language) }) {
            parts.append(language)
        }

        var flagParts: [String] = []
        if isDefault, !normalizedTitle.contains("default") {
            flagParts.append(NSLocalizedString("Default", comment: ""))
        }
        if isForced, !normalizedTitle.contains("forced") {
            flagParts.append(NSLocalizedString("Forced", comment: ""))
        }
        if !flagParts.isEmpty {
            parts.append(flagParts.joined(separator: " "))
        }

        if let codec,
           !codec.isEmpty,
           !normalizedTitle.contains(normalizedServerTrackMetadataValue(codec)),
           !parts.contains(where: { normalizedServerTrackMetadataValue($0) == normalizedServerTrackMetadataValue(codec) }) {
            parts.append(codec)
        }

        if parts.isEmpty {
            return title ?? alternateTitle ?? displayLanguage ?? language ?? codec
        }
        return parts.joined(separator: " · ")
    }

    private func serverTrackBooleanValue(_ value: Any?) -> Bool {
        if let value = value as? Bool {
            return value
        }
        if let value = value as? NSNumber {
            return value.boolValue
        }
        if let value = value as? String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized == "true" || normalized == "1" || normalized == "yes"
        }
        return false
    }

    private func cleanedServerTrackMetadataValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func cleanedServerSubtitleLanguageMetadataValue(_ value: String?) -> String? {
        guard let cleaned = cleanedServerSubtitlePresentationMetadataValue(value) else { return nil }

        return cleaned
    }

    private func cleanedServerSubtitlePresentationMetadataValue(_ value: String?) -> String? {
        guard let cleaned = cleanedServerTrackMetadataValue(value) else { return nil }

        let lowered = cleaned
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let placeholderValues: Set<String> = [
            "und", "undefined", "unknown", "undetermined", "n/a", "na", "none", "null",
            "未定义", "未指定", "未知", "不明", "未設定", "未設置"
        ]

        return placeholderValues.contains(lowered) ? nil : cleaned
    }

    private func isGenericServerSubtitleDisplayTitle(_ title: String, codec: String?) -> Bool {
        var normalized = normalizedServerTrackMetadataValue(title)
        if let codec, !codec.isEmpty {
            normalized = normalized.replacingOccurrences(of: normalizedServerTrackMetadataValue(codec), with: "")
        }

        let genericTokens = ["default", "forced", "subtitle", "captions", "caption", "external", "internal"]
        genericTokens.forEach { token in
            normalized = normalized.replacingOccurrences(of: token, with: "")
        }
        return normalized.isEmpty
    }

    private func normalizedServerTrackMetadataValue(_ value: String?) -> String {
        guard let value = value?.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased() else {
            return ""
        }
        return String(value.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private func selectableTrack(at ordinal: Int, from tracks: [MediaTrack]) -> MediaTrack? {
        guard ordinal >= 0 else { return nil }
        let selectable = tracks.filter { $0.id != -1 }
        guard ordinal < selectable.count else { return nil }
        return selectable[ordinal]
    }

    func applyAutomaticSubtitleSelectionIfNeeded() -> Bool {
        guard !hasResolvedAutomaticSubtitleSelection, !isMenuPresented,
              !subtitleIntelligence.isGeneratedPrimary,
              state.currentItem?.externalSubtitleURL == nil else { return false }
        let mode = AppSettings.shared.subtitleAutoSelectionMode.rawValue
        guard mode != "off" else {
            hasResolvedAutomaticSubtitleSelection = true
            return false
        }
        let tracks = state.subtitleTracks.filter { $0.id != -1 }
        guard !tracks.isEmpty else { return false }
        hasResolvedAutomaticSubtitleSelection = true
        let stored = UserDefaults.standard.string(forKey: "appLanguage") ?? "system"
        let language = stored == "system" ? (Locale.preferredLanguages.first ?? Locale.current.identifier) : stored
        guard let index = PlaybackSubtitleAutoSelection.index(in: tracks.map(\.name), mode: mode, language: language) else { return false }
        isApplyingAutomaticSubtitleSelection = true
        defer { isApplyingAutomaticSubtitleSelection = false }
        setSubtitleTrack(tracks[index].id)
        return true
    }

    func flushDeferredTrackRefreshIfNeeded() {
        guard deferredTrackRefreshNeeded else { return }
        _ = refreshTracks(force: true)
    }
}

// MARK: - Metadata Extraction
extension VLCPlaybackService {
    private struct ExtractedAudioMetadata {
        var title: String?
        var artist: String?
        var album: String?
        var albumArtist: String?
        var author: String?
        var composer: String?
        var artwork: UIImage?

        var isEmpty: Bool {
            title == nil &&
            artist == nil &&
            album == nil &&
            albumArtist == nil &&
            author == nil &&
            composer == nil &&
            artwork == nil
        }
    }

    func applyMPVAudioMetadata(_ values: [String: String]) {
        guard let item = state.currentItem, resolvedPlaybackItemType(for: item) == .audio else { return }
        if let title = normalizedMetadataText(values["title"]) { state.currentItem?.title = title }
        if let artist = normalizedMetadataText(values["artist"]) { state.currentItem?.artist = artist }
        if let album = normalizedMetadataText(values["album"]) { state.currentItem?.album = album }
        if let albumArtist = normalizedMetadataText(values["albumArtist"]) { state.currentItem?.albumArtist = albumArtist }
        if let author = normalizedMetadataText(values["author"]) { state.currentItem?.author = author }
        if let composer = normalizedMetadataText(values["composer"]) { state.currentItem?.composer = composer }
        updateNowPlayingInfo()
    }

    /// mpv metadata never creates a VLC parser; native tags and bounded supplemental reads share the current attempt.
    func extractMetadata() {
        guard let currentItem = state.currentItem,
              mediaPlayer?.media != nil || isUsingMPV else { return }
        if currentItem.artwork != nil && hasMeaningfulMetadataText(currentItem.artist)
            && hasMeaningfulMetadataText(currentItem.album) { return }
        let targetURL = currentItem.url
        let attempt = playbackAttemptID
        metadataReadID = UUID()
        let readID = metadataReadID
        metadataArtworkTask?.cancel()
        metadataArtworkTask = nil
        if playbackCapabilities.metadataBackend == .independent {
            guard resolvedPlaybackItemType(for: currentItem) == .audio,
                  targetURL.isFileURL || RemoteAudioArtworkReader.supports(url: targetURL, provider: currentItem.serverType?.rawValue) else { return }
            var independentStarted = false
            let nativeCompleted: () -> Void = { [weak self] in
                guard let self, self.metadataReadID == readID, !independentStarted else { return }
                independentStarted = true
                self.completeNativeAudioMetadata(targetURL: targetURL, attempt: attempt) { _ in }
                // Unsupported/incomplete data keeps existing server/mpv tags. Never
                // create a second engine or reconnect through VLC for metadata.
            }
            if targetURL.isFileURL {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.extractMetadataViaAVFoundation(targetURL: targetURL, attempt: attempt, completion: nativeCompleted)
                }
            } else {
                nativeCompleted()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: nativeCompleted)
        } else {
            extractCompatibilityMetadata(targetURL: targetURL, attempt: attempt)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.extractMetadataViaAVFoundation(targetURL: targetURL, attempt: attempt)
            }
        }
    }

    private func extractCompatibilityMetadata(targetURL: URL, attempt: UUID) {
        guard playbackCapabilities.metadataBackend == .vlc, playbackAttemptID == attempt, isMetadataTargetCurrent(targetURL: targetURL),
              let currentItem = state.currentItem else { return }
        if currentItem.artwork != nil && hasMeaningfulMetadataText(currentItem.artist)
            && hasMeaningfulMetadataText(currentItem.album) { return }
        guard PlaybackEngineAvailability.current.vlc else { return }
        // VLC playback owns its existing metadata parser.
        let media = mediaPlayer?.media ?? VLCMedia(url: RuntimeNetworkAddressResolver.runtimeURL(from: targetURL))
        let provider: any PlaybackMetadataProvider = VLCPlaybackMetadataProvider(media: media)
        provider.beginParsing()
        checkPlaybackMetadata(provider: provider, targetURL: targetURL, attempt: attempt)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.checkPlaybackMetadata(provider: provider, targetURL: targetURL, attempt: attempt)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.checkPlaybackMetadata(provider: provider, targetURL: targetURL, attempt: attempt)
        }
    }

    /// Helper to read VLC metadata and update state.
    private func checkPlaybackMetadata(provider: any PlaybackMetadataProvider, targetURL: URL, attempt: UUID) {
        guard playbackAttemptID == attempt, isMetadataTargetCurrent(targetURL: targetURL) else { return }

        let meta = provider.metadata

        var didUpdate = false

        if !hasMeaningfulMetadataText(state.currentItem?.artist),
           let artist = normalizedMetadataText(meta.artist) {
            state.currentItem?.artist = artist
            didUpdate = true
        }

        if !hasMeaningfulMetadataText(state.currentItem?.album),
           let album = normalizedMetadataText(meta.album) {
            state.currentItem?.album = album
            didUpdate = true
        }

        if state.currentItem?.artwork == nil,
           let artworkImage = meta.artwork {
            state.currentItem?.artwork = artworkImage
            cacheArtworkIfNeeded(artworkImage, targetURL: targetURL)
            didUpdate = true
        }

        if didUpdate {
            updateNowPlayingInfo()
        }

        guard state.currentItem?.artwork == nil, let artworkURL = meta.artworkURL else {
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self,
                  let data = try? Data(contentsOf: artworkURL),
                  let image = UIImage(data: data) else {
                return
            }

            DispatchQueue.main.async {
                guard self.playbackAttemptID == attempt, self.isMetadataTargetCurrent(targetURL: targetURL),
                      self.state.currentItem?.artwork == nil else {
                    return
                }

                self.state.currentItem?.artwork = image
                self.cacheArtworkIfNeeded(image, targetURL: targetURL)
                self.updateNowPlayingInfo()
            }
        }
    }

    /// Main-queue completion of mpv audio metadata; no playback engine is created.
    private func completeNativeAudioMetadata(targetURL: URL, attempt: UUID, completion: @escaping (Bool) -> Void) {
        guard playbackAttemptID == attempt, isMetadataTargetCurrent(targetURL: targetURL),
              let item = state.currentItem else { return }
        if item.artwork != nil && hasMeaningfulMetadataText(item.artist) && hasMeaningfulMetadataText(item.album) {
            completion(true); return
        }
        metadataArtworkTask?.cancel()
        metadataArtworkTask = Task { @MainActor [weak self] in
            let metadata: EmbeddedAudioArtworkReader.Metadata?
            if targetURL.isFileURL {
                metadata = try? await EmbeddedAudioArtworkReader.readMetadata(targetURL)
            } else {
                metadata = try? await RemoteAudioArtworkReader.readMetadata(url: targetURL, provider: item.serverType?.rawValue,
                    serverID: item.jellyfinServerId, path: item.serverPath, itemID: item.jellyfinItemId)
            }
            guard !Task.isCancelled, let self, self.playbackAttemptID == attempt,
                  self.isMetadataTargetCurrent(targetURL: targetURL) else { return }
            let image = metadata?.artwork.flatMap { UIImage(data: $0) }
            if let metadata {
                self.applyExtractedMetadata(.init(title: metadata.tags["title"], artist: metadata.tags["artist"],
                    album: metadata.tags["album"], albumArtist: metadata.tags["albumArtist"], author: metadata.tags["author"],
                    composer: metadata.tags["composer"], artwork: image), targetURL: targetURL, attempt: attempt)
            }
            self.metadataArtworkTask = nil
            // Preserve compatibility when cover bytes exist but UIKit cannot decode them.
            let artworkReadable = metadata?.artwork == nil || image != nil || self.state.currentItem?.artwork != nil
            completion(metadata?.isComplete == true && artworkReadable)
        }
    }

    /// Fallback: Use AVFoundation to extract embedded metadata from local audio files.
    private func extractMetadataViaAVFoundation(targetURL: URL, attempt: UUID, completion: (() -> Void)? = nil) {
        guard targetURL.isFileURL else { return }

        let asset = AVURLAsset(url: targetURL)

        // Quick pass from common metadata to improve first-open consistency in Media Info.
        let quickExtracted = extractAudioMetadata(from: asset.commonMetadata)
        if !quickExtracted.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.applyExtractedMetadata(quickExtracted, targetURL: targetURL, attempt: attempt)
            }
        }

        let keys = ["commonMetadata", "availableMetadataFormats"]

        asset.loadValuesAsynchronously(forKeys: keys) { [weak self] in
            guard let self = self else { return }

            for key in keys {
                var error: NSError?
                let status = asset.statusOfValue(forKey: key, error: &error)
                if status == .failed || status == .cancelled {
                    DispatchQueue.main.async { completion?() }
                    return
                }
            }

            var metadataItems = asset.commonMetadata
            for format in asset.availableMetadataFormats {
                metadataItems.append(contentsOf: asset.metadata(forFormat: format))
            }

            let extracted = self.extractAudioMetadata(from: metadataItems)
            DispatchQueue.main.async {
                if !extracted.isEmpty {
                    self.applyExtractedMetadata(extracted, targetURL: targetURL, attempt: attempt)
                }
                completion?()
            }
        }
    }

    private func applyExtractedMetadata(_ extracted: ExtractedAudioMetadata, targetURL: URL, attempt: UUID) {
        guard playbackAttemptID == attempt, isMetadataTargetCurrent(targetURL: targetURL) else { return }

        var didUpdate = false

        if state.currentItem?.artwork == nil, let artwork = extracted.artwork {
            state.currentItem?.artwork = artwork
            cacheArtworkIfNeeded(artwork, targetURL: targetURL)
            didUpdate = true
        }
        if !hasMeaningfulMetadataText(state.currentItem?.artist), let artist = extracted.artist {
            state.currentItem?.artist = artist
            didUpdate = true
        }
        if !hasMeaningfulMetadataText(state.currentItem?.album), let album = extracted.album {
            state.currentItem?.album = album
            didUpdate = true
        }
        if !hasMeaningfulMetadataText(state.currentItem?.albumArtist), let albumArtist = extracted.albumArtist {
            state.currentItem?.albumArtist = albumArtist
            didUpdate = true
        }
        if !hasMeaningfulMetadataText(state.currentItem?.author), let author = extracted.author {
            state.currentItem?.author = author
            didUpdate = true
        }
        if !hasMeaningfulMetadataText(state.currentItem?.composer), let composer = extracted.composer {
            state.currentItem?.composer = composer
            didUpdate = true
        }
        if let title = extracted.title,
           title != state.currentItem?.title {
            state.currentItem?.title = title
            didUpdate = true
        }

        if didUpdate {
            updateNowPlayingInfo()
        }
    }

    private func cacheArtworkIfNeeded(_ image: UIImage, targetURL: URL) {
        ImageCacheManager.shared.saveImage(image, for: targetURL)

        guard let currentItem = state.currentItem,
              currentItem.url == targetURL,
              let remoteArtworkKey = ArtworkCacheKey.remoteAudioArtwork(
                serverType: currentItem.serverType,
                serverId: currentItem.jellyfinServerId,
                serverPath: currentItem.serverPath,
                fallbackURL: targetURL
              ) else {
            return
        }

        ImageCacheManager.shared.saveImage(image, forKey: remoteArtworkKey)
    }

    private func extractAudioMetadata(from items: [AVMetadataItem]) -> ExtractedAudioMetadata {
        var extracted = ExtractedAudioMetadata()
        // Resolve dedicated tags before common-key/token fallbacks. AVFoundation can
        // expose artist and album artist through the same common key, in either order.
        extracted.artist = preferredMetadataText(from: items, identifiers: [
            .iTunesMetadataArtist, .id3MetadataLeadPerformer,
            .quickTimeMetadataArtist, .quickTimeUserDataArtist, .commonIdentifierArtist
        ])
        extracted.albumArtist = preferredMetadataText(from: items, identifiers: [
            .iTunesMetadataAlbumArtist, .id3MetadataBand
        ])
        extracted.author = preferredMetadataText(from: items, identifiers: [
            .iTunesMetadataAuthor, .quickTimeMetadataAuthor, .quickTimeUserDataAuthor
        ])
        extracted.composer = preferredMetadataText(from: items, identifiers: [
            .iTunesMetadataComposer, .id3MetadataComposer
        ])

        for item in items {
            if extracted.artwork == nil,
               let artwork = extractArtwork(from: item) {
                extracted.artwork = artwork
            }
            if extracted.title == nil,
               let title = extractMetadataText(
                from: item,
                identifierSet: titleMetadataIdentifiers,
                commonKeys: [.commonKeyTitle],
                fallbackTokens: ["title", "%a9nam", "tit2"]
               ) {
                extracted.title = title
            }
            if extracted.artist == nil,
               let artist = extractMetadataText(
                from: item,
                identifierSet: artistMetadataIdentifiers,
                commonKeys: [.commonKeyArtist, .commonKeyCreator],
                fallbackTokens: ["artist", "performer", "%a9art", "tpe1", "tpe2"]
               ) {
                extracted.artist = artist
            }
            if extracted.album == nil,
               let album = extractMetadataText(
                from: item,
                identifierSet: albumMetadataIdentifiers,
                commonKeys: [.commonKeyAlbumName],
                fallbackTokens: ["album", "%a9alb", "talb"]
               ) {
                extracted.album = album
            }
            if extracted.albumArtist == nil,
               let albumArtist = extractMetadataText(
                from: item,
                identifierSet: albumArtistMetadataIdentifiers,
                commonKeys: [.commonKeyArtist, .commonKeyCreator],
                fallbackTokens: ["albumartist", "band", "aart", "tpe2"]
               ) {
                extracted.albumArtist = albumArtist
            }
            if extracted.author == nil,
               let author = extractMetadataText(
                from: item,
                identifierSet: authorMetadataIdentifiers,
                commonKeys: [.commonKeyCreator],
                fallbackTokens: ["author", "writer", "%a9aut"]
               ) {
                extracted.author = author
            }
            if extracted.composer == nil,
               let composer = extractMetadataText(
                from: item,
                identifierSet: composerMetadataIdentifiers,
                commonKeys: [.commonKeyCreator],
                fallbackTokens: ["composer", "%a9wrt", "tcom"]
               ) {
                extracted.composer = composer
            }
        }

        if extracted.artist == nil {
            extracted.artist = extracted.albumArtist ?? extracted.author ?? extracted.composer
        }

        return extracted
    }

    private func preferredMetadataText(from items: [AVMetadataItem], identifiers: [AVMetadataIdentifier]) -> String? {
        for identifier in identifiers {
            for item in items where item.identifier == identifier {
                if let text = metadataTextValue(from: item) { return text }
            }
        }
        return nil
    }

    private var titleMetadataIdentifiers: Set<String> {
        [
            AVMetadataIdentifier.commonIdentifierTitle.rawValue,
            AVMetadataIdentifier.id3MetadataTitleDescription.rawValue,
            AVMetadataIdentifier.iTunesMetadataSongName.rawValue,
            AVMetadataIdentifier.quickTimeMetadataTitle.rawValue
        ]
    }

    private var artistMetadataIdentifiers: Set<String> {
        [
            AVMetadataIdentifier.commonIdentifierArtist.rawValue,
            AVMetadataIdentifier.commonIdentifierCreator.rawValue,
            AVMetadataIdentifier.id3MetadataLeadPerformer.rawValue,
            AVMetadataIdentifier.id3MetadataBand.rawValue,
            AVMetadataIdentifier.id3MetadataOriginalArtist.rawValue,
            AVMetadataIdentifier.id3MetadataComposer.rawValue,
            AVMetadataIdentifier.iTunesMetadataArtist.rawValue,
            AVMetadataIdentifier.iTunesMetadataAlbumArtist.rawValue,
            AVMetadataIdentifier.iTunesMetadataAuthor.rawValue,
            AVMetadataIdentifier.iTunesMetadataComposer.rawValue,
            AVMetadataIdentifier.quickTimeUserDataArtist.rawValue,
            AVMetadataIdentifier.quickTimeUserDataAuthor.rawValue,
            AVMetadataIdentifier.quickTimeMetadataArtist.rawValue,
            AVMetadataIdentifier.quickTimeMetadataAuthor.rawValue
        ]
    }

    private var albumMetadataIdentifiers: Set<String> {
        [
            AVMetadataIdentifier.commonIdentifierAlbumName.rawValue,
            AVMetadataIdentifier.id3MetadataAlbumTitle.rawValue,
            AVMetadataIdentifier.iTunesMetadataAlbum.rawValue,
            AVMetadataIdentifier.quickTimeUserDataAlbum.rawValue,
            AVMetadataIdentifier.quickTimeMetadataAlbum.rawValue
        ]
    }

    private var albumArtistMetadataIdentifiers: Set<String> {
        [
            AVMetadataIdentifier.iTunesMetadataAlbumArtist.rawValue,
            AVMetadataIdentifier.id3MetadataBand.rawValue
        ]
    }

    private var authorMetadataIdentifiers: Set<String> {
        [
            AVMetadataIdentifier.iTunesMetadataAuthor.rawValue,
            AVMetadataIdentifier.quickTimeUserDataAuthor.rawValue,
            AVMetadataIdentifier.quickTimeMetadataAuthor.rawValue
        ]
    }

    private var composerMetadataIdentifiers: Set<String> {
        [
            AVMetadataIdentifier.id3MetadataComposer.rawValue,
            AVMetadataIdentifier.iTunesMetadataComposer.rawValue
        ]
    }

    private var artworkMetadataIdentifiers: Set<String> {
        [
            AVMetadataIdentifier.commonIdentifierArtwork.rawValue,
            AVMetadataIdentifier.id3MetadataAttachedPicture.rawValue,
            AVMetadataIdentifier.iTunesMetadataCoverArt.rawValue
        ]
    }

    private func extractMetadataText(
        from item: AVMetadataItem,
        identifierSet: Set<String>,
        commonKeys: Set<AVMetadataKey>,
        fallbackTokens: [String] = []
    ) -> String? {
        if let commonKey = item.commonKey,
           commonKeys.contains(commonKey),
           let text = metadataTextValue(from: item) {
            return text
        }

        if let identifier = item.identifier?.rawValue,
           identifierSet.contains(identifier),
           let text = metadataTextValue(from: item) {
            return text
        }

        guard !fallbackTokens.isEmpty,
              let text = metadataTextValue(from: item) else {
            return nil
        }

        let loweredTokens = fallbackTokens.map { $0.lowercased() }
        let identifier = item.identifier?.rawValue.lowercased() ?? ""
        if loweredTokens.contains(where: { identifier.contains($0) }) {
            return text
        }

        let keyString = metadataKeyValue(from: item) ?? ""
        if loweredTokens.contains(where: { keyString.contains($0) }) {
            return text
        }

        return nil
    }

    private func extractArtwork(from item: AVMetadataItem) -> UIImage? {
        let isArtworkByCommonKey = item.commonKey == .commonKeyArtwork
        let isArtworkByIdentifier = item.identifier.map { artworkMetadataIdentifiers.contains($0.rawValue) } ?? false
        guard isArtworkByCommonKey || isArtworkByIdentifier else { return nil }

        if let data = item.dataValue, let image = UIImage(data: data) {
            return image
        }
        if let image = item.value as? UIImage {
            return image
        }
        if let rawData = item.value as? Data, let image = UIImage(data: rawData) {
            return image
        }

        return nil
    }

    private func metadataTextValue(from item: AVMetadataItem) -> String? {
        if let text = normalizedMetadataText(item.stringValue) {
            return text
        }
        if let text = normalizedMetadataText(item.value as? String) {
            return text
        }
        if let text = normalizedMetadataText((item.value as? NSString) as String?) {
            return text
        }
        if let data = item.dataValue,
           let text = decodeMetadataText(from: data) {
            return text
        }
        if let data = item.value as? Data,
           let text = decodeMetadataText(from: data) {
            return text
        }
        return nil
    }

    private func decodeMetadataText(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        let encodings: [String.Encoding] = [
            .utf8,
            .utf16,
            .utf16LittleEndian,
            .utf16BigEndian,
            .unicode,
            .isoLatin1,
            .shiftJIS
        ]

        for encoding in encodings {
            if let decoded = String(data: data, encoding: encoding),
               let normalized = normalizedMetadataText(decoded) {
                return normalized
            }
        }

        return nil
    }

    private func metadataKeyValue(from item: AVMetadataItem) -> String? {
        if let key = item.key as? String {
            return key.lowercased()
        }
        if let key = item.key as? NSString {
            return (key as String).lowercased()
        }
        if let key = item.key as? NSNumber {
            return key.stringValue.lowercased()
        }
        return nil
    }

    private func normalizedMetadataText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func hasMeaningfulMetadataText(_ value: String?) -> Bool {
        normalizedMetadataText(value) != nil
    }

    private func isMetadataTargetCurrent(targetURL: URL) -> Bool {
        guard let currentURL = state.currentItem?.url else { return false }
        if targetURL.isFileURL && currentURL.isFileURL {
            return targetURL.standardizedFileURL == currentURL.standardizedFileURL
        }
        return targetURL == currentURL
    }
}

// MARK: - History & Jellyfin
extension VLCPlaybackService {
    private func currentVideoAspectRatioHint() -> Double? {
        guard let item = state.currentItem,
              VideoFile.FileType.determineType(from: item.url) == .video else {
            return nil
        }
        let size = videoNaturalSize
        guard size.width > 0, size.height > 0 else { return nil }
        let ratio = size.width / size.height
        return ratio.isFinite ? Double(ratio) : nil
    }

    func saveProgress() {
        guard let item = state.currentItem else { return }
        
        // Check History Settings
        let isVideo = resolvedPlaybackItemType(for: item) == .video
        if isVideo && !AppSettings.shared.enableVideoHistory { return }
        if !isVideo && !AppSettings.shared.enableAudioHistory { return }

        let videoAspectRatioHint = currentVideoAspectRatioHint()
        
        let updated = historyService.updateProgress(
            for: item.url,
            time: state.currentTime,
            duration: state.duration,
            videoAspectRatioHint: videoAspectRatioHint,
            audioTrack: isUsingMPV ? nil : state.currentAudioTrackID,
            subtitleTrack: isUsingMPV ? nil : state.currentSubtitleTrackID,
            jellyfinItemId: item.jellyfinItemId,
            jellyfinServerId: item.jellyfinServerId,
            externalSubtitleCandidates: item.externalSubtitleCandidates,
            serverPath: item.serverPath
        )
        
        if updated == nil {
            // Not in history yet, so add it
            var file: VideoFile
            if let origFile = item.videoFile {
                file = origFile
                file.duration = state.duration
                file.lastPlayedPosition = state.currentTime
                file.videoAspectRatioHint = videoAspectRatioHint
                if !isUsingMPV { file.lastAudioTrack = state.currentAudioTrackID }
                if !isUsingMPV { file.lastSubtitleTrack = state.currentSubtitleTrackID }
                file.date = Date()
                if let path = item.serverPath, !path.isEmpty {
                    file.serverPath = path
                }
            } else {
                let fileURL: URL
                if (item.serverType?.requiresDynamicPlaybackURL == true), let serverPath = item.serverPath, !serverPath.isEmpty {
                    fileURL = URL(fileURLWithPath: serverPath)
                } else {
                    fileURL = item.url
                }
                file = VideoFile(
                    name: item.title,
                    url: fileURL,
                    type: VideoFile.FileType.determineType(from: item.url),
                    size: item.serverSize ?? 0,
                    date: Date(),
                    isRemote: item.isRemote,
                    duration: state.duration,
                    lastPlayedPosition: state.currentTime,
                    videoAspectRatioHint: videoAspectRatioHint,
                    lastAudioTrack: isUsingMPV ? nil : state.currentAudioTrackID,
                    lastSubtitleTrack: isUsingMPV ? nil : state.currentSubtitleTrackID,
                    jellyfinItemId: item.jellyfinItemId,
                    jellyfinServerId: item.jellyfinServerId,
                    serverType: item.serverType,
                    seriesId: item.seriesId,
                    seasonId: item.seasonId,
                    externalSubtitleCandidates: item.externalSubtitleCandidates
                )
                file.serverPath = item.serverPath
            }
            // Offline downloaded library items: localPlaybackFile() sets isRemote=false, but they
            // must still be routed to remoteHistory so the entry stays linked to the Jellyfin/Emby/Plex item.
            if !file.isRemote,
               let itemId = file.jellyfinItemId, !itemId.isEmpty,
               let serverId = file.jellyfinServerId, !serverId.isEmpty {
                file.isRemote = true
            }
            historyService.addToHistory(file)
        }

        if !isUsingMPV { saveSeriesTrackPreferenceIfNeeded(for: item) }
    }

    private func resetLocalReplayProgressIfNeeded(for item: MediaItem) {
        guard !hasResetReplayProgressLocallyForCurrentItem else { return }

        let isVideo = resolvedPlaybackItemType(for: item) == .video
        if isVideo && !AppSettings.shared.enableVideoHistory { return }
        if !isVideo && !AppSettings.shared.enableAudioHistory { return }

        let preferredDuration = state.duration > 0 ? state.duration : item.videoFile?.duration
        _ = historyService.resetPlaybackProgress(
            for: item.url,
            preferredDuration: preferredDuration,
            videoAspectRatioHint: currentVideoAspectRatioHint(),
            audioTrack: isUsingMPV || state.currentAudioTrackID == -1 ? nil : state.currentAudioTrackID,
            subtitleTrack: isUsingMPV ? nil : state.currentSubtitleTrackID,
            jellyfinItemId: item.jellyfinItemId,
            jellyfinServerId: item.jellyfinServerId,
            externalSubtitleCandidates: item.externalSubtitleCandidates
        )

        hasResetReplayProgressLocallyForCurrentItem = true
    }

    private func clearRemotePlayedStateIfNeeded(
        for item: MediaItem,
        context: (server: ServerConfig, serverType: ServerConfig.ServerType, itemId: String, token: String, userId: String),
        reason: String
    ) async -> MediaItem {
        guard item.shouldResetRemotePlayedStateOnPlaybackStart else {
            return await MainActor.run { self.state.currentItem ?? item }
        }

        resetLocalReplayProgressIfNeeded(for: item)
        await MainActor.run {
            guard self.state.currentItem?.id == item.id else { return }
            self.state.currentItem?.startPosition = 0
            self.state.currentItem?.videoFile?.lastPlayedPosition = 0
        }

        do {
            switch context.serverType {
            case .jellyfin:
                guard !context.userId.isEmpty else {
                    print("[ServerSync] Skipping played-state reset (reason=\(reason)): missing Jellyfin userId")
                    return await MainActor.run { self.state.currentItem ?? item }
                }
                try await JellyfinService.shared.togglePlayed(
                    server: context.server,
                    itemId: context.itemId,
                    userId: context.userId,
                    token: context.token,
                    isPlayed: false
                )
            case .emby:
                guard !context.userId.isEmpty else {
                    print("[ServerSync] Skipping played-state reset (reason=\(reason)): missing Emby userId")
                    return await MainActor.run { self.state.currentItem ?? item }
                }
                try await EmbyService.shared.togglePlayed(
                    server: context.server,
                    itemId: context.itemId,
                    userId: context.userId,
                    token: context.token,
                    isPlayed: false
                )
            case .plex:
                try await PlexService.shared.setPlayed(
                    server: context.server,
                    itemId: context.itemId,
                    isPlayed: false
                )
            default:
                break
            }

            await MainActor.run {
                guard self.state.currentItem?.id == item.id else { return }
                self.state.currentItem?.shouldResetRemotePlayedStateOnPlaybackStart = false
                self.state.currentItem?.videoFile?.shouldResetRemotePlayedStateOnPlaybackStart = false
            }
            print("[ServerSync] ✅ cleared remote played state before replay (reason=\(reason), itemId=\(context.itemId))")
        } catch {
            print("[ServerSync] Failed to clear remote played state (reason=\(reason), itemId=\(context.itemId)): \(error)")
        }

        return await MainActor.run { self.state.currentItem ?? item }
    }

    private func saveSeriesTrackPreferenceIfNeeded(for item: MediaItem) {
        saveTrackQueryPreferenceIfNeeded(for: item)

        guard let provider = item.serverType?.rawValue,
              let serverId = item.jellyfinServerId,
              let seriesId = item.seriesId,
              !seriesId.isEmpty else {
            return
        }

        AppSettings.shared.saveSeriesTrackPreference(
            provider: provider,
            serverId: serverId,
            seriesId: seriesId,
            audio: state.currentAudioTrackID,
            subtitle: state.currentSubtitleTrackID
        )
    }

    private func saveTrackQueryPreferenceIfNeeded(for item: MediaItem) {
        guard let provider = item.serverType?.rawValue,
              let serverId = item.jellyfinServerId,
              let scopeKey = trackQueryScopeKey(for: item) else {
            return
        }

        let selectedAudioQuery = state.audioTracks.first(where: { $0.id == state.currentAudioTrackID })?.name
        let selectedSubtitleQuery = state.subtitleTracks.first(where: { $0.id == state.currentSubtitleTrackID })?.name
        let subtitlesDisabled = state.currentSubtitleTrackID == -1

        AppSettings.shared.saveTrackQueryPreference(
            provider: provider,
            serverId: serverId,
            scopeKey: scopeKey,
            audioQuery: selectedAudioQuery,
            subtitleQuery: subtitlesDisabled ? nil : selectedSubtitleQuery,
            subtitlesDisabled: subtitlesDisabled
        )
    }

    func storedTrackQueryPreference(for item: MediaItem) -> (audioQuery: String?, subtitleQuery: String?, subtitlesDisabled: Bool?) {
        guard let provider = item.serverType?.rawValue,
              let serverId = item.jellyfinServerId,
              let scopeKey = trackQueryScopeKey(for: item) else {
            return (nil, nil, nil)
        }

        return AppSettings.shared.trackQueryPreference(
            provider: provider,
            serverId: serverId,
            scopeKey: scopeKey
        )
    }

    private func trackQueryScopeKey(for item: MediaItem) -> String? {
        if let seriesId = item.seriesId, !seriesId.isEmpty {
            return "series.\(seriesId)"
        }
        if let itemId = item.jellyfinItemId, !itemId.isEmpty {
            return "item.\(itemId)"
        }
        return nil
    }

    private func serverSyncHost(from rawAddress: String) -> String? {
        let trimmed = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let host = URLComponents(string: trimmed)?.host?.lowercased(), !host.isEmpty {
            return host
        }

        var normalized = trimmed.lowercased()
        ["http://", "https://", "smb://"].forEach { prefix in
            if normalized.hasPrefix(prefix) {
                normalized.removeFirst(prefix.count)
            }
        }
        if let slashIndex = normalized.firstIndex(of: "/") {
            normalized = String(normalized[..<slashIndex])
        }
        if let colonIndex = normalized.firstIndex(of: ":") {
            normalized = String(normalized[..<colonIndex])
        }

        return normalized.isEmpty ? nil : normalized
    }

    private func serverSyncContext(for item: MediaItem) -> (server: ServerConfig, serverType: ServerConfig.ServerType, itemId: String, token: String, userId: String)? {
        guard let itemId = item.jellyfinItemId else { return nil }

        let allServers = AppNetworkService.shared.servers
        var resolvedServer: ServerConfig?
        if let serverId = item.jellyfinServerId {
            resolvedServer = allServers.first(where: {
                $0.id.uuidString.caseInsensitiveCompare(serverId) == .orderedSame
            })
        }

        if resolvedServer == nil,
           let itemComponents = URLComponents(url: item.url, resolvingAgainstBaseURL: false),
           let host = itemComponents.host?.lowercased() {
            let preferredType = item.serverType
            let itemPort = itemComponents.port ?? (itemComponents.scheme?.lowercased() == "https" ? 443 : 80)
            resolvedServer = allServers.first { server in
                guard server.type == .jellyfin || server.type == .emby || server.type == .plex else { return false }
                if let preferredType, server.type != preferredType { return false }

                guard let serverComponents = URLComponents(string: server.fullURL),
                      let serverHost = serverComponents.host?.lowercased() else {
                    return false
                }
                let serverPort = serverComponents.port ?? (serverComponents.scheme?.lowercased() == "https" ? 443 : 80)
                return serverHost == host && serverPort == itemPort
            }

            // Loose fallback for legacy/irregular addresses.
            if resolvedServer == nil {
                resolvedServer = allServers.first { server in
                    guard server.type == .jellyfin || server.type == .emby || server.type == .plex else { return false }
                    if let preferredType, server.type != preferredType { return false }
                    return serverSyncHost(from: server.fullURL) == host || serverSyncHost(from: server.address) == host
                }
            }
        }

        if resolvedServer == nil {
            let preferredType = item.serverType
            if let preferredType {
                resolvedServer = allServers.first(where: { $0.type == preferredType })
            } else if allServers.count == 1 {
                resolvedServer = allServers.first
            }
        }

        guard let server = resolvedServer else {
            print("[ServerSync] ⚠️ No matching server found for item \(item.title), serverId=\(item.jellyfinServerId ?? "nil")")
            return nil
        }
        let serverType = item.serverType ?? server.type
        guard serverType == .jellyfin || serverType == .emby || serverType == .plex else { return nil }

        let hydratedServer = AppNetworkService.shared.hydratedServer(from: server)
        let token = hydratedServer.accessToken
            ?? URLComponents(url: item.url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "api_key" || $0.name == "X-Plex-Token" })?
                .value

        let resolvedToken = token ?? ""
        if resolvedToken.isEmpty {
            let hasCredentials = (hydratedServer.username?.isEmpty == false && hydratedServer.passwordSecret?.isEmpty == false)
            if !hasCredentials {
                print("[ServerSync] ⚠️ Missing token and credentials for server \(server.name)")
                return nil
            }
        }

        return (server: hydratedServer, serverType: serverType, itemId: itemId, token: resolvedToken, userId: hydratedServer.userId ?? "")

    }

    /// Jellyfin/Emby servers may require PlaySessionId/MediaSourceId for durable resume updates.
    /// Returns true when context is ready to report Playing/Progress.
    private func ensureServerPlaybackContextIfNeeded() -> Bool {
        guard let item = state.currentItem else {
            return false
        }
        guard let context = serverSyncContext(for: item) else {
            let typeDesc = item.serverType.map { String(describing: $0) } ?? "nil"
            print("[ServerSync] ⛔ ensureContext: no context — itemId=\(item.jellyfinItemId ?? "nil") serverId=\(item.jellyfinServerId ?? "nil") serverType=\(typeDesc) isRemote=\(item.isRemote) urlScheme=\(item.url.scheme ?? "?")")
            return false
        }

        if context.serverType == .plex {
            return true
        }

        if item.url.isFileURL || !item.isRemote {
            if self.state.currentItem?.playSessionId == nil {
                let newSessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                self.state.currentItem?.playSessionId = newSessionId
                print("[ServerSync] 🔑 offline file: synthesized playSessionId=\(newSessionId) server=\(context.server.name) userId=\(context.userId)")
            }
            self.state.currentItem?.remotePlaybackMethod = .directPlay
            return true
        }

        if shouldBypassPlaybackContextFetch {
            return true
        }

        if item.playSessionId?.isEmpty == false || item.mediaSourceId?.isEmpty == false {
            return true
        }

        if isFetchingServerPlaybackContext {
            return false
        }

        let now = Date().timeIntervalSince1970
        if playbackContextFetchFailureCount > 0,
           now - lastPlaybackContextFetchFailureTime < 8 {
            return true
        }

        // No userId means we cannot request PlaybackInfo; fall back to existing behavior.
        guard !context.userId.isEmpty else {
            print("[ServerSync] ⚠️ Missing userId; reporting without PlaySessionId")
            return true
        }

        isFetchingServerPlaybackContext = true
        let currentItemUUID = item.id
        Task {
            defer { self.isFetchingServerPlaybackContext = false }

            do {
                let playbackQuality = AppSettings.shared.resolvedRemotePlaybackQualityOption(for: item.preferredPlaybackQualityID)
                if context.serverType == .jellyfin {
                    let info = try await JellyfinService.shared.getPlaybackInfo(
                        server: context.server,
                        itemId: context.itemId,
                        userId: context.userId,
                        token: context.token,
                        playbackQuality: playbackQuality
                    )
                    let preferredSource = JellyfinService.shared.preferredPlaybackSource(
                        from: info.mediaSources,
                        playbackQuality: playbackQuality
                    )
                    let mediaSourceId = preferredSource?.id
                    let mediaStreams = JellyfinService.shared.preferredPlaybackStreams(
                        from: info.mediaSources,
                        playbackQuality: playbackQuality
                    ).map { $0.toDictionary() }
                    await MainActor.run {
                        guard self.state.currentItem?.id == currentItemUUID else { return }
                        self.state.currentItem?.playSessionId = info.playSessionId
                        self.state.currentItem?.mediaSourceId = mediaSourceId
                        self.state.currentItem?.serverMediaStreams = mediaStreams
                        self.state.currentItem?.serverContainer = preferredSource?.container
                        self.state.currentItem?.serverSize = preferredSource?.size
                        self.state.currentItem?.serverBitrate = preferredSource?.bitrate
                        self.state.currentItem?.serverPath = preferredSource?.path
                        self.state.currentItem?.preferredPlaybackQualityID = playbackQuality.id
                        let resolvedMethod: RemotePlaybackMethod
                        if item.url.isFileURL || !item.isRemote {
                            resolvedMethod = .directPlay
                        } else {
                            resolvedMethod = JellyfinService.shared.playbackMethod(
                                for: preferredSource,
                                resolvedURL: item.url,
                                playbackQuality: playbackQuality
                            )
                        }
                        self.state.currentItem?.remotePlaybackMethod = resolvedMethod
                        self.playbackContextFetchFailureCount = 0
                        self.lastPlaybackContextFetchFailureTime = 0
                        self.shouldBypassPlaybackContextFetch = false
                        if let currentItem = self.state.currentItem {
                            self.prewarmSeekPreviewIfNeeded(for: currentItem, targetTime: self.state.currentTime)
                        }
                        self.refreshSecondarySubtitleTracks()
                        print("[ServerSync] ✅ playback context ready (provider=jellyfin, playSessionId=\(info.playSessionId ?? "nil"), mediaSourceId=\(mediaSourceId ?? "nil"))")
                        if !self.hasReportedServerPlaying {
                            self.hasReportedServerPlaying = self.reportServerPlaying()
                        }
                    }
                } else if context.serverType == .emby {
                    let info = try await EmbyService.shared.getPlaybackInfo(
                        server: context.server,
                        itemId: context.itemId,
                        userId: context.userId,
                        token: context.token,
                        playbackQuality: playbackQuality,
                        currentPlaySessionId: item.playSessionId
                    )
                    let preferredSource = EmbyService.shared.preferredPlaybackSource(
                        from: info.mediaSources,
                        playbackQuality: playbackQuality
                    )
                    let mediaSourceId = preferredSource?.id
                    let mediaStreams = EmbyService.shared.preferredPlaybackStreams(
                        from: info.mediaSources,
                        playbackQuality: playbackQuality
                    ).map { $0.toDictionary() }
                    await MainActor.run {
                        guard self.state.currentItem?.id == currentItemUUID else { return }
                        self.state.currentItem?.playSessionId = info.playSessionId
                        self.state.currentItem?.mediaSourceId = mediaSourceId
                        self.state.currentItem?.serverMediaStreams = mediaStreams
                        self.state.currentItem?.serverContainer = preferredSource?.container
                        self.state.currentItem?.serverSize = preferredSource?.size
                        self.state.currentItem?.serverBitrate = preferredSource?.bitrate
                        self.state.currentItem?.serverPath = preferredSource?.path
                        self.state.currentItem?.preferredPlaybackQualityID = playbackQuality.id
                        let resolvedMethod: RemotePlaybackMethod
                        if item.url.isFileURL || !item.isRemote {
                            resolvedMethod = .directPlay
                        } else {
                            resolvedMethod = EmbyService.shared.playbackMethod(
                                for: preferredSource,
                                resolvedURL: item.url,
                                playbackQuality: playbackQuality
                            )
                        }
                        self.state.currentItem?.remotePlaybackMethod = resolvedMethod
                        self.playbackContextFetchFailureCount = 0
                        self.lastPlaybackContextFetchFailureTime = 0
                        self.shouldBypassPlaybackContextFetch = false
                        if let currentItem = self.state.currentItem {
                            self.prewarmSeekPreviewIfNeeded(for: currentItem, targetTime: self.state.currentTime)
                        }
                        self.refreshSecondarySubtitleTracks()
                        print("[ServerSync] ✅ playback context ready (provider=emby, playSessionId=\(info.playSessionId ?? "nil"), mediaSourceId=\(mediaSourceId ?? "nil"))")
                        if !self.hasReportedServerPlaying {
                            self.hasReportedServerPlaying = self.reportServerPlaying()
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self.playbackContextFetchFailureCount += 1
                    self.lastPlaybackContextFetchFailureTime = Date().timeIntervalSince1970
                    if self.state.currentItem?.playSessionId == nil {
                        self.state.currentItem?.playSessionId = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                    }
                    self.shouldBypassPlaybackContextFetch = true
                    print("[ServerSync] ⚠️ playback context fetch failed, fallback to direct reporting with generated PlaySessionId")
                    if !self.hasReportedServerPlaying {
                        self.hasReportedServerPlaying = self.reportServerPlaying()
                    }
                }
                print("[ServerSync] Failed to fetch playback context: \(error)")
            }
        }

        return false
    }

    private func serverProgressEventName(for reason: String, isPaused: Bool) -> String {
        if reason == "pause" || isPaused {
            return "pause"
        }
        if reason == "resume" {
            return "unpause"
        }
        return "timeupdate"
    }

    private func plexTimelineState(for reason: String, isPaused: Bool) -> String {
        if reason == "stop" || reason == "switch_item" {
            return "stopped"
        }
        return isPaused ? "paused" : "playing"
    }

    private func plexPlaybackPositionMilliseconds() -> Int64 {
        Int64(max(0, state.currentTime * 1000.0).rounded())
    }

    private func plexPlaybackDurationMilliseconds() -> Int64? {
        guard state.duration > 0 else { return nil }
        return Int64((state.duration * 1000.0).rounded())
    }
    
    private func executeWithServerAuthRetry(
        context: (server: ServerConfig, serverType: ServerConfig.ServerType, itemId: String, token: String, userId: String),
        action: (ServerConfig, String, String, String) async throws -> Void
    ) async throws {
        var currentToken = context.token
        var currentUserId = context.userId
        var currentServer = context.server

        // If token is missing, attempt silent login using stored username/password
        if currentToken.isEmpty {
            if context.serverType == .jellyfin,
               let username = context.server.username, !username.isEmpty,
               let password = context.server.passwordSecret, !password.isEmpty {
                print("[ServerSync] 🔄 Token missing, attempting initial silent login for Jellyfin server \(context.server.name)...")
                let authResult = try await JellyfinService.shared.login(server: context.server, username: username, password: password)
                currentServer.accessToken = authResult.accessToken
                currentServer.userId = authResult.user.id
                currentToken = authResult.accessToken
                currentUserId = authResult.user.id
                await MainActor.run {
                    AppNetworkService.shared.updateServer(currentServer)
                }
                print("[ServerSync] 🔄 Silent login succeeded, proceeding with playback report...")
            } else if context.serverType == .emby,
                      let username = context.server.username, !username.isEmpty,
                      let password = context.server.passwordSecret, !password.isEmpty {
                print("[ServerSync] 🔄 Token missing, attempting initial silent login for Emby server \(context.server.name)...")
                let authResult = try await EmbyService.shared.login(server: context.server, username: username, password: password)
                currentServer.accessToken = authResult.accessToken
                currentServer.userId = authResult.user.id
                currentToken = authResult.accessToken
                currentUserId = authResult.user.id
                await MainActor.run {
                    AppNetworkService.shared.updateServer(currentServer)
                }
                print("[ServerSync] 🔄 Silent login succeeded, proceeding with playback report...")
            } else {
                print("[ServerSync] ⚠️ Cannot perform silent login: missing username/password for \(context.server.name)")
                return
            }
        }

        do {
            try await action(currentServer, context.itemId, currentUserId, currentToken)
        } catch JellyfinError.unauthorized {
            guard context.serverType == .jellyfin,
                  let username = currentServer.username ?? context.server.username, !username.isEmpty,
                  let password = currentServer.passwordSecret ?? context.server.passwordSecret, !password.isEmpty else {
                throw JellyfinError.unauthorized
            }
            print("[ServerSync] 🔄 Token expired (401), attempting silent re-login for Jellyfin server \(context.server.name)...")
            let authResult = try await JellyfinService.shared.login(server: currentServer, username: username, password: password)
            var updatedServer = currentServer
            updatedServer.accessToken = authResult.accessToken
            updatedServer.userId = authResult.user.id
            await MainActor.run {
                AppNetworkService.shared.updateServer(updatedServer)
            }
            print("[ServerSync] 🔄 Silent re-login succeeded, retrying playback report...")
            try await action(updatedServer, context.itemId, authResult.user.id, authResult.accessToken)
        } catch EmbyError.unauthorized {
            guard context.serverType == .emby,
                  let username = currentServer.username ?? context.server.username, !username.isEmpty,
                  let password = currentServer.passwordSecret ?? context.server.passwordSecret, !password.isEmpty else {
                throw EmbyError.unauthorized
            }
            print("[ServerSync] 🔄 Token expired (401), attempting silent re-login for Emby server \(context.server.name)...")
            let authResult = try await EmbyService.shared.login(server: currentServer, username: username, password: password)
            var updatedServer = currentServer
            updatedServer.accessToken = authResult.accessToken
            updatedServer.userId = authResult.user.id
            await MainActor.run {
                AppNetworkService.shared.updateServer(updatedServer)
            }
            print("[ServerSync] 🔄 Silent re-login succeeded, retrying playback report...")
            try await action(updatedServer, context.itemId, authResult.user.id, authResult.accessToken)
        }
    }


    /// Report playback progress to server (Jellyfin/Emby/Plex).
    /// Safe to call frequently — throttled internally to once per 10s.
    func reportServerProgress(force: Bool = false, reason: String = "periodic") {
        guard let item = state.currentItem,
              let context = serverSyncContext(for: item) else { return }

        // Use the guard target (intended resume position) as the effective current time so
        // we don't report position=0 to the server during the brief seek-landing window.
        let effectiveCurrentTime: Double
        if let guardTarget = pendingPlaybackResumeTimeGuard {
            effectiveCurrentTime = guardTarget
        } else {
            effectiveCurrentTime = state.currentTime
        }

        // Strict Throttling (10s)
        let shouldReport = force || abs(effectiveCurrentTime - lastJellyfinSyncTime) >= 10.0
        guard shouldReport else { return }

        lastJellyfinSyncTime = effectiveCurrentTime
        let ticks = Int64(effectiveCurrentTime * 10_000_000)
        let isPaused = state.status == .paused
        let eventName = serverProgressEventName(for: reason, isPaused: isPaused)
        Task {
            do {
                let itemForReport = await self.clearRemotePlayedStateIfNeeded(
                    for: item,
                    context: context,
                    reason: "progress_\(reason)"
                )
                let playMethod: String
                if itemForReport.url.isFileURL || !itemForReport.isRemote {
                    playMethod = RemotePlaybackMethod.directPlay.rawValue
                } else {
                    playMethod = itemForReport.remotePlaybackMethod?.rawValue ?? RemotePlaybackMethod.directPlay.rawValue
                }
                if context.serverType == .jellyfin {
                    try await self.executeWithServerAuthRetry(context: context) { s, itemId, userId, token in
                        try await JellyfinService.shared.reportProgress(
                            server: s,
                            itemId: itemId,
                            userId: userId,
                            token: token,
                            positionTicks: ticks,
                            isPaused: isPaused,
                            eventName: eventName,
                            playSessionId: itemForReport.playSessionId,
                            mediaSourceId: itemForReport.mediaSourceId,
                            playMethod: playMethod
                        )
                    }
                } else if context.serverType == .emby {
                    try await self.executeWithServerAuthRetry(context: context) { s, itemId, userId, token in
                        try await EmbyService.shared.reportProgress(
                            server: s,
                            itemId: itemId,
                            userId: userId,
                            token: token,
                            positionTicks: ticks,
                            isPaused: isPaused,
                            eventName: eventName,
                            playSessionId: itemForReport.playSessionId,
                            mediaSourceId: itemForReport.mediaSourceId,
                            playMethod: playMethod
                        )
                    }
                } else if context.serverType == .plex {
                    try await PlexService.shared.reportTimeline(
                        server: context.server,
                        itemId: context.itemId,
                        positionMillis: plexPlaybackPositionMilliseconds(),
                        durationMillis: plexPlaybackDurationMilliseconds(),
                        state: plexTimelineState(for: reason, isPaused: isPaused),
                        sessionIdentifier: itemForReport.id.uuidString
                    )
                }
                print("[ServerSync] ✅ reportProgress succeeded (reason=\(reason), event=\(eventName), itemId=\(context.itemId), ticks=\(ticks), paused=\(isPaused), playSessionId=\(itemForReport.playSessionId ?? "nil"), mediaSourceId=\(itemForReport.mediaSourceId ?? "nil"))")
            } catch {
                print("[ServerSync] Failed to report progress (reason=\(reason)): \(error)")
            }
        }
    }
    
    @discardableResult
    func reportServerPlaying() -> Bool {
        guard let item = state.currentItem else {
            print("[ServerSync] reportServerPlaying: no currentItem")
            return false
        }
        guard let context = serverSyncContext(for: item) else {
            print("[ServerSync] reportServerPlaying: missing context (server/item/token/type)")
            return false
        }

        let effectiveTime = (pendingPlaybackResumeTimeGuard ?? state.currentTime)
        let ticks = Int64(effectiveTime * 10_000_000)
        Task {
            do {
                let itemForReport = await self.clearRemotePlayedStateIfNeeded(
                    for: item,
                    context: context,
                    reason: "playing"
                )
                let playMethod: String
                if itemForReport.url.isFileURL || !itemForReport.isRemote {
                    playMethod = RemotePlaybackMethod.directPlay.rawValue
                } else {
                    playMethod = itemForReport.remotePlaybackMethod?.rawValue ?? RemotePlaybackMethod.directPlay.rawValue
                }
                if context.serverType == .jellyfin {
                    try await self.executeWithServerAuthRetry(context: context) { s, itemId, userId, token in
                        try await JellyfinService.shared.reportPlaying(
                            server: s,
                            itemId: itemId,
                            userId: userId,
                            token: token,
                            positionTicks: ticks,
                            playSessionId: itemForReport.playSessionId,
                            mediaSourceId: itemForReport.mediaSourceId,
                            playMethod: playMethod
                        )
                    }
                } else if context.serverType == .emby {
                    try await self.executeWithServerAuthRetry(context: context) { s, itemId, userId, token in
                        try await EmbyService.shared.reportPlaying(
                            server: s,
                            itemId: itemId,
                            userId: userId,
                            token: token,
                            positionTicks: ticks,
                            playSessionId: itemForReport.playSessionId,
                            mediaSourceId: itemForReport.mediaSourceId,
                            playMethod: playMethod
                        )
                    }
                } else if context.serverType == .plex {
                    try await PlexService.shared.reportTimeline(
                        server: context.server,
                        itemId: context.itemId,
                        positionMillis: plexPlaybackPositionMilliseconds(),
                        durationMillis: plexPlaybackDurationMilliseconds(),
                        state: "playing",
                        sessionIdentifier: itemForReport.id.uuidString
                    )
                }
                print("[ServerSync] ✅ reportPlaying succeeded (itemId=\(context.itemId), playSessionId=\(itemForReport.playSessionId ?? "nil"), mediaSourceId=\(itemForReport.mediaSourceId ?? "nil"))")
            } catch {
                print("[ServerSync] ❌ Failed to report playing: \(error)")
            }
        }
        return true
    }
    
    func reportServerStopped() {
        guard let item = state.currentItem,
              let context = serverSyncContext(for: item) else { return }

        // Use guard target if state.currentTime is still frozen (user exits immediately after resume)
        let effectiveTime = (pendingPlaybackResumeTimeGuard ?? state.currentTime)
        let ticks = Int64(effectiveTime * 10_000_000)
        let playMethod: String
        if item.url.isFileURL || !item.isRemote {
            playMethod = RemotePlaybackMethod.directPlay.rawValue
        } else {
            playMethod = item.remotePlaybackMethod?.rawValue ?? RemotePlaybackMethod.directPlay.rawValue
        }
        let playSessionId = item.playSessionId
        let mediaSourceId = item.mediaSourceId
        Task {
            do {
                if context.serverType == .jellyfin {
                    try await self.executeWithServerAuthRetry(context: context) { s, itemId, userId, token in
                        try await JellyfinService.shared.reportProgress(
                            server: s,
                            itemId: itemId,
                            userId: userId,
                            token: token,
                            positionTicks: ticks,
                            isPaused: true,
                            eventName: "pause",
                            playSessionId: playSessionId,
                            mediaSourceId: mediaSourceId,
                            playMethod: playMethod
                        )
                        try await JellyfinService.shared.reportStopped(
                            server: s,
                            itemId: itemId,
                            userId: userId,
                            token: token,
                            positionTicks: ticks,
                            playSessionId: playSessionId,
                            mediaSourceId: mediaSourceId,
                            playMethod: playMethod
                        )
                    }
                } else if context.serverType == .emby {
                    try await self.executeWithServerAuthRetry(context: context) { s, itemId, userId, token in
                        try await EmbyService.shared.reportProgress(
                            server: s,
                            itemId: itemId,
                            userId: userId,
                            token: token,
                            positionTicks: ticks,
                            isPaused: true,
                            eventName: "pause",
                            playSessionId: playSessionId,
                            mediaSourceId: mediaSourceId,
                            playMethod: playMethod
                        )
                        try await EmbyService.shared.reportStopped(
                            server: s,
                            itemId: itemId,
                            userId: userId,
                            token: token,
                            positionTicks: ticks,
                            playSessionId: playSessionId,
                            mediaSourceId: mediaSourceId,
                            playMethod: playMethod
                        )
                    }
                } else if context.serverType == .plex {
                    try await PlexService.shared.reportTimeline(
                        server: context.server,
                        itemId: context.itemId,
                        positionMillis: plexPlaybackPositionMilliseconds(),
                        durationMillis: plexPlaybackDurationMilliseconds(),
                        state: "stopped",
                        sessionIdentifier: item.id.uuidString
                    )
                    try await PlexService.shared.updatePlayProgress(
                        server: context.server,
                        itemId: context.itemId,
                        positionMillis: plexPlaybackPositionMilliseconds(),
                        state: "stopped"
                    )
                }
                print("[ServerSync] ✅ reportStopped succeeded (itemId=\(context.itemId), ticks=\(ticks))")
            } catch {
                print("[ServerSync] Failed to report stopped: \(error)")
            }
        }
    }


    @discardableResult
    func endCurrentServerPlaybackSessionForRestart(reason: String = "restart") async -> Bool {
        guard let item = state.currentItem,
              let context = serverSyncContext(for: item) else {
            return false
        }

        guard context.serverType == .jellyfin else {
            return false
        }

        let ticks = Int64(state.currentTime * 10_000_000)
        let playMethod = item.remotePlaybackMethod?.rawValue ?? RemotePlaybackMethod.directPlay.rawValue

        do {
            try await self.executeWithServerAuthRetry(context: context) { s, itemId, userId, token in
                try await JellyfinService.shared.reportProgress(
                    server: s,
                    itemId: itemId,
                    userId: userId,
                    token: token,
                    positionTicks: ticks,
                    isPaused: true,
                    eventName: "pause",
                    playSessionId: item.playSessionId,
                    mediaSourceId: item.mediaSourceId,
                    playMethod: playMethod
                )
                try await JellyfinService.shared.reportStopped(
                    server: s,
                    itemId: itemId,
                    userId: userId,
                    token: token,
                    positionTicks: ticks,
                    playSessionId: item.playSessionId,
                    mediaSourceId: item.mediaSourceId,
                    playMethod: playMethod
                )
            }
            return true
        } catch {
            print("[ServerSync] Failed to end current server session for \(reason): \(error)")
            return false
        }
    }
}

// MARK: - Remote Commands
extension VLCPlaybackService {
    func setupRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = state.duration > 0

        // Disable skip forward/backward so iOS shows next/previous track buttons
        // on the lock screen, Dynamic Island, and Control Center instead.
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false

        center.nextTrackCommand.isEnabled = canSkipToNextTrack
        center.previousTrackCommand.isEnabled = canSkipToPreviousTrack

        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.stopCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)

        center.playCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            guard self.state.currentItem != nil else { return .noActionableNowPlayingItem }
            guard !self.state.isPlaying else { return .noActionableNowPlayingItem }
            self.togglePlayPause()
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            guard self.state.currentItem != nil else { return .noActionableNowPlayingItem }
            guard self.state.isPlaying else { return .noActionableNowPlayingItem }
            self.togglePlayPause()
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            guard self.state.currentItem != nil else { return .noActionableNowPlayingItem }
            self.togglePlayPause()
            return .success
        }
        center.stopCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            guard self.state.currentItem != nil else { return .noActionableNowPlayingItem }
            self.stop()
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            let handled = self.onRequestNextTrack?() ?? false
            return handled ? .success : .noSuchContent
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            guard let self = self else { return .commandFailed }
            let handled = self.onRequestPreviousTrack?() ?? false
            return handled ? .success : .noSuchContent
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self = self,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            print("[PiP] changePlaybackPosition requested positionTime=\(positionEvent.positionTime)")
            if self.onRequestSeekToTime?(positionEvent.positionTime) == true {
                return .success
            }
            if self.state.duration > 0 {
                self.seek(to: positionEvent.positionTime)
                return .success
            }
            return .noActionableNowPlayingItem
        }
        // skipForwardCommand / skipBackwardCommand targets intentionally removed
        // so that iOS renders next/previous track buttons on lock screen.
    }
    
    func updateNowPlayingInfo() {
        guard let item = state.currentItem else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            if #available(iOS 13.0, *) {
                MPNowPlayingInfoCenter.default().playbackState = .stopped
            }
            return
        }

        var info = [String: Any]()
        info[MPMediaItemPropertyTitle] = item.title
        if let artist = preferredArtistText(for: item) {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let album = normalizedMetadataText(item.album) {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        if let image = item.artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        } else {
            loadNowPlayingArtworkIfNeeded(for: item)
        }

        let playbackRate = state.isPlaying ? max(Double(state.rate), 0.1) : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = state.currentTime
        info[MPMediaItemPropertyPlaybackDuration] = state.duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = playbackRate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = max(Double(state.rate), 0.1)

        let fileType = resolvedPlaybackItemType(for: item)
        let mediaType: MPNowPlayingInfoMediaType = (fileType == .video) ? .video : .audio
        info[MPNowPlayingInfoPropertyMediaType] = mediaType.rawValue

        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = canSkipToNextTrack
        center.previousTrackCommand.isEnabled = canSkipToPreviousTrack
        center.changePlaybackPositionCommand.isEnabled = state.duration > 0

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        if #available(iOS 13.0, *) {
            switch state.status {
            case .playing:
                MPNowPlayingInfoCenter.default().playbackState = .playing
            case .paused:
                MPNowPlayingInfoCenter.default().playbackState = .paused
            case .idle, .error, .ended:
                MPNowPlayingInfoCenter.default().playbackState = .stopped
            case .buffering:
                MPNowPlayingInfoCenter.default().playbackState = .playing
            }
        }
    }

    private func loadNowPlayingArtworkIfNeeded(for item: MediaItem) {
        guard item.artwork == nil,
              let artworkURL = nowPlayingArtworkURL(for: item) else {
            return
        }

        let cacheKey = MediaImageCacheIdentity.cacheKey(from: artworkURL) ?? artworkURL.absoluteString
        let requestKey = "\(item.id.uuidString)|\(cacheKey)"
        guard nowPlayingArtworkRequestKey != requestKey else {
            return
        }

        nowPlayingArtworkDataTask?.cancel()
        nowPlayingArtworkDataTask = nil
        nowPlayingArtworkRequestKey = requestKey

        if let cachedImage = ImageCacheManager.shared.getImage(for: artworkURL) {
            applyNowPlayingArtwork(cachedImage, itemID: item.id, requestKey: requestKey)
            return
        }

        let requestURL = MediaImageCacheIdentity.requestURL(from: artworkURL)
        let dataTask = URLSession.shared.dataTask(with: requestURL) { [weak self] data, response, error in
            guard let self = self else { return }
            if let error = error as NSError?, error.code == NSURLErrorCancelled {
                return
            }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                return
            }
            guard let data,
                  let image = UIImage(data: data) else {
                return
            }

            ImageCacheManager.shared.saveImage(image, for: artworkURL)
            DispatchQueue.main.async {
                self.applyNowPlayingArtwork(image, itemID: item.id, requestKey: requestKey)
            }
        }

        nowPlayingArtworkDataTask = dataTask
        dataTask.resume()
    }

    private func nowPlayingArtworkURL(for item: MediaItem) -> URL? {
        guard item.isRemote,
              item.serverType == .jellyfin || item.serverType == .emby,
              let videoFile = item.videoFile,
              videoFile.type == .video,
              let thumbnailURL = videoFile.thumbnailURL else {
            return nil
        }

        return thumbnailURL
    }

    private func applyNowPlayingArtwork(_ image: UIImage, itemID: UUID, requestKey: String) {
        guard nowPlayingArtworkRequestKey == requestKey,
              var currentItem = state.currentItem,
              currentItem.id == itemID,
              currentItem.artwork == nil else {
            return
        }

        currentItem.artwork = image
        state.currentItem = currentItem
        updateNowPlayingInfo()
    }

    private func cancelNowPlayingArtworkLoad() {
        nowPlayingArtworkDataTask?.cancel()
        nowPlayingArtworkDataTask = nil
        nowPlayingArtworkRequestKey = nil
    }

    private func preferredArtistText(for item: MediaItem) -> String? {
        normalizedMetadataText(item.artist) ??
            normalizedMetadataText(item.albumArtist) ??
            normalizedMetadataText(item.author) ??
            normalizedMetadataText(item.composer)
    }
    
    /// Clear Now Playing info and remove remote command targets to dismiss lock screen / Dynamic Island controls
    func clearNowPlayingInfo() {
        cancelNowPlayingArtworkLoad()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        if #available(iOS 13.0, *) {
            MPNowPlayingInfoCenter.default().playbackState = .stopped
        }
        
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.stopCommand.removeTarget(nil)
        center.nextTrackCommand.removeTarget(nil)
        center.previousTrackCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
        center.playCommand.isEnabled = false
        center.pauseCommand.isEnabled = false
        center.togglePlayPauseCommand.isEnabled = false
        center.stopCommand.isEnabled = false
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false
        center.changePlaybackPositionCommand.isEnabled = false
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
    }
}
