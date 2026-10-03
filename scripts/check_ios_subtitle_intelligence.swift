import Foundation
import GenPlayerCore

func platformShellString(_ key: String) -> String { key == "AS.GeneratedName" ? "(Generated)%@" : key }
func platformResolvedLanguage(for value: String) -> String { "en" }

@main struct IOSSubtitleIntelligenceChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        var count = 0
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); count += 1; print("PASS: \(message)")
        }
        func until(_ condition: () -> Bool) async throws {
            for _ in 0..<200 {
                if condition() { return }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            preconditionFailure("Timed out")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "IOSSubtitleChecks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let url = root.appendingPathComponent("fixture.mov")
        let backend = MacAudioSubtitleBackend(inspect: { url in
            MacAudioSubtitleSource(url: url, identity: "fixture", duration: 90, tracks: [.init(id: 3, ordinal: 1, language: "en")])
        }, languages: { ["en-US"] }, available: { true }, prepare: { _ in }, transcribe: { _, _, _, chunk in
            try await Task.sleep(nanoseconds: 150_000_000)
            return [.init(id: chunk * 10000, start: Double(chunk) * 30, end: Double(chunk) * 30 + 1, text: "hello")]
        }, revision: "fixture")
        let audio = MacAudioSubtitleJob(backend: backend, store: MacAudioSubtitleStore(root: root), defaults: defaults)
        let model = IOSSubtitleIntelligence(audio: audio, translation: MacSubtitleTranslation(defaults: defaults))
        check(!model.canTranslatePrimary, "no selected primary hides primary translation")
        model.hasSelectedPrimarySubtitle = true
        check(model.canTranslatePrimary, "selected primary exposes primary translation")
        model.reset()
        check(!model.canTranslatePrimary, "reset clears primary translation availability")
        var primarySelections = 0, secondarySelections = 0
        model.onGeneratedPrimarySelected = { primarySelections += 1 }
        model.onIntelligentSecondarySelected = { secondarySelections += 1 }
        model.bind(url: url, live: false, provider: nil, serverID: nil, itemID: nil, serverURL: nil, token: nil, mediaSourceID: nil)
        defer {
            UserDefaults.standard.removeObject(forKey: MacSubtitleTranslationPreference.key(provider: nil, serverID: nil, itemID: nil, url: url))
        }
        try await until { !audio.inspecting }
        audio.language = "en-US"
        model.updateAudioNames([(3, "Original Audio")])
        audio.start()
        try await until { audio.cues.count == 1 }
        let configuration = audio.configuration
        model.updateTime(45)
        check(audio.configuration == configuration, "playback clock does not invalidate audio selectors")
        check(model.isGeneratedPrimary && primarySelections == 1, "generated primary selection reaches the player once")
        check(model.generatedName == "(Generated)Original Audio", "generated menu name preserves the source audio name")
        model.setTranslationEnabled(true)
        let session = model.translation.generation
        try await until { audio.cues.count == 2 }
        check(audio.configuration == configuration, "new subtitle chunks do not invalidate audio selectors")
        try await until { audio.cache?.isComplete == true && !audio.running }
        check(!audio.configuration.disabled, "finishing recognition re-enables source selection")
        let completedConfiguration = audio.configuration
        audio.language = "ja-JP"
        check(audio.configuration != completedConfiguration, "explicit language selection refreshes the selector value")
        audio.language = "en-US"
        check(model.translation.generation == session, "later audio chunks preserve the translation download session")
        let generatedBeforeRebuild = audio.cues
        let outputBeforeRebuild = model.secondaryID
        model.prepareForPlaybackRebuild()
        check(model.isGeneratedPrimary && audio.cues == generatedBeforeRebuild, "core rebuild preserves generated output and completed recognition")
        check(model.secondaryID == outputBeforeRebuild, "core rebuild preserves secondary intelligence selection")
        check(model.translation.generation == session, "core rebuild preserves generated translation session")
        check(model.primaryParts(at: 30.5).first?.text?.string == "hello", "generated primary follows media time")
        audio.select(.off)
        check(!model.translation.hasSource && model.translation.generation != session,
              "turning generated primary off immediately invalidates its translation without a playback tick")
        model.selectGeneratedPrimary()
        check(model.translation.hasSource, "reselecting generated primary supplies a fresh translation source")
        model.selectSecondary(IOSSubtitleIntelligence.generatedSecondaryID)
        check(!model.isTranslating && !model.isGeneratedPrimary && model.secondaryID == IOSSubtitleIntelligence.generatedSecondaryID,
              "generated secondary replaces translation and releases generated primary")
        check(model.secondaryParts(at: 60.5).count == 1 && secondarySelections >= 2, "generated secondary uses the existing second slot")
        model.selectedOrdinaryPrimary(isOff: false)
        check(model.secondaryID == IOSSubtitleIntelligence.generatedSecondaryID, "ordinary primary selection preserves generated secondary")
        let primaryBeforeTranslation = primarySelections
        defaults.set(true, forKey: "enableSecondarySubtitlesBeta")
        audio.setOriginalDestination(.none)
        audio.setAutomaticallyTranslate(true)
        check(model.isTranslatingAudio && model.isTranslating && !model.isGeneratedPrimary && model.translation.hasSource,
              "audio translates directly in secondary without selecting generated primary")
        check(primarySelections == primaryBeforeTranslation, "direct audio translation preserves native primary selection")
        let audioTranslationSession = model.translation.generation
        model.selectedOrdinaryPrimary(isOff: true)
        model.unavailablePrimary(bitmap: true)
        check(model.isTranslating && model.translation.hasSource && model.translation.generation == audioTranslationSession,
              "turning primary off or selecting bitmap primary cannot replace audio translation source")
        audio.setOriginalDestination(.secondary)
        model.translation.setDisplayContent(.bilingual)
        check(model.secondaryParts(at: 60.5).first?.text?.string == "hello\n ", "audio bilingual secondary shows original before translation")
        model.setBackground(true)
        model.setBackground(false)
        check(model.isTranslatingAudio && model.translation.hasSource, "background resumes independent audio source")
        model.selectSecondary(-1)
        check(!model.isTranslating && audio.display == .off && model.secondaryID == -1,
              "manual secondary off releases direct audio translation")
        audio.onResultsChanged?()
        check(model.secondaryID == -1 && !model.translation.hasSource, "late audio update cannot reclaim manual selection")
        audio.setOriginalDestination(.secondary)
        audio.setAutomaticallyTranslate(true)
        audio.setAutomaticallyTranslate(false)
        check(model.secondaryID == IOSSubtitleIntelligence.generatedSecondaryID && !model.isTranslating,
              "disabling automatic translation falls back to generated original")
        // All destination combinations use one ASR cache; equal slots compose bilingual output.
        model.translation.setOriginalFirst(true)
        let cachedAudioKey = audio.cache?.key
        for original in [MacAudioSubtitleJob.Destination.none, .primary, .secondary] {
            for target in [MacAudioSubtitleJob.Destination.primary, .secondary] {
                audio.setOriginalDestination(original)
                audio.setTranslationDestination(target)
                audio.setAutomaticallyTranslate(true)
                audio.useOrGenerate()
                let units = MacSubtitleTranslationPlan.units(cues: audio.cues.map {
                    MacSubtitleTranslationCue(index: $0.id, start: $0.start, end: $0.end, text: $0.text)
                })
                for unit in units { _ = model.translation.acceptTranslation("译文", for: unit) }
                for slot in [MacAudioSubtitleJob.Destination.primary, .secondary] {
                    let parts = slot == .primary ? model.primaryParts(at: 60.5) : model.secondaryParts(at: 60.5)
                    let expected: String? = original == slot && target == slot ? "hello\n译文" :
                        (target == slot ? "译文" : (original == slot ? "hello" : nil))
                    check(parts.first?.text?.string == expected, "routing \(original) / \(target) composes \(slot) correctly")
                }
                check(audio.cache?.key == cachedAudioKey && !audio.running, "destination change reuses completed audio cache")
            }
        }
        audio.setOriginalDestination(.secondary)
        audio.setTranslationDestination(.primary)
        audio.setAutomaticallyTranslate(true)
        model.selectSecondary(-1)
        check(model.isGeneratedPrimary && model.isTranslatingAudio && model.secondaryID == -1,
              "manual secondary off preserves translated primary")
        audio.setOriginalDestination(.primary)
        audio.setTranslationDestination(.secondary)
        audio.setAutomaticallyTranslate(true)
        model.selectedOrdinaryPrimary(isOff: false)
        check(!model.isGeneratedPrimary && model.isTranslatingAudio && model.secondaryID == IOSSubtitleIntelligence.translatedSecondaryID,
              "manual primary selection preserves translated secondary")
        audio.setOriginalDestination(.secondary)
        audio.setTranslationDestination(.primary)
        audio.setAutomaticallyTranslate(true)
        let stableRoutingSession = model.translation.generation
        audio.setOriginalDestination(.primary)
        check(model.translation.generation == stableRoutingSession, "moving audio output does not rebuild translation session")
        audio.setAutomaticallyTranslate(false)
        audio.setOriginalDestination(.secondary)
        var primarySourceRequests = 0
        model.onPrimarySourceNeeded = { primarySourceRequests += 1 }
        model.setTranslationEnabled(true)
        check(!model.isTranslatingAudio && primarySourceRequests > 0 && model.isTranslating,
              "legacy Translate Primary does not silently switch to audio recognition")
        model.setTranslationEnabled(false)
        audio.setOriginalDestination(.none)
        model.setTranslationEnabled(true)
        check(!audio.isConfigured && model.isTranslating && !model.isTranslatingAudio,
              "cache-only configuration releases routing before legacy primary translation")
        let cacheOnlySession = model.translation.generation
        audio.setOriginalDestination(.none)
        audio.setAutomaticallyTranslate(false)
        audio.useOrGenerate()
        check(model.isTranslatingPrimary && model.translation.enabled && model.translation.generation == cacheOnlySession,
              "cache-only audio preserves ordinary primary translation and its session")
        model.followPrimary(key: "cache-only-primary", language: "en") {
            SubtitleTimeline(parts: [SubtitlePart(start: 60, end: 61, text: NSAttributedString(string: "ordinary"))])
        }
        try await until { model.translation.hasSource }
        let ordinaryUnit = MacSubtitleTranslationPlan.units(cues: [.init(index: 0, start: 60, end: 61, text: "ordinary")])[0]
        check(model.translation.acceptTranslation("普通译文", for: ordinaryUnit), "cache-only audio still accepts primary translation")
        check(model.secondaryParts(at: 60.5).first?.text?.string == "普通译文", "cache-only audio does not hide ordinary translated output")
        audio.setTranslationDestination(.secondary)
        audio.setAutomaticallyTranslate(true)
        let requestsBeforeSwitch = primarySourceRequests
        model.setPrimaryTranslationEnabled(true)
        check(model.isTranslatingPrimary && !audio.translatesAudio && primarySourceRequests > requestsBeforeSwitch,
              "explicit primary translation switches away from active audio translation")
        audio.setOriginalDestination(.secondary)
        audio.setAutomaticallyTranslate(false)
        let selectionsBeforeDraft = primarySelections
        audio.language = "ja-JP"
        audio.setOriginalDestination(.primary)
        check(!model.isGeneratedPrimary && audio.activeOriginalDestination == .secondary && primarySelections == selectionsBeforeDraft,
              "draft source routing leaves the previous cache in its active slot")
        check(model.secondaryParts(at: 60.5).first?.text?.string == "hello", "draft routing preserves old secondary output")
        model.selectSecondary(-1)
        check(!audio.hasActiveOutput && model.secondaryID == -1, "manual release still works while another source is drafted")
        audio.language = "en-US"
        model.onPrimarySourceNeeded = nil
        model.translation.setDisplayContent(.translated)
        audio.select(.secondary)

        model.selectGeneratedPrimary()
        check(model.secondaryID == -1 && model.isGeneratedPrimary, "moving generated subtitles to primary clears duplicate secondary")
        model.setTranslationEnabled(true)
        model.selectedOrdinaryPrimary(isOff: false)
        check(!model.isGeneratedPrimary && model.isTranslating, "ordinary primary replaces generated primary without disabling translation")
        model.followPrimary(key: "slow", language: "en") {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return SubtitleTimeline(parts: [SubtitlePart(start: 0, end: 1, text: NSAttributedString(string: "stale"))])
        }
        model.reset()
        try await Task.sleep(nanoseconds: 250_000_000)
        check(!model.translation.hasSource && !model.isTranslating && !model.hasGeneratedSubtitles, "reset rejects a late subtitle load")
        model.bind(url: url, live: false, provider: nil, serverID: nil, itemID: nil, serverURL: nil, token: nil, mediaSourceID: nil)
        model.setBackground(true) // Also cover background while inspection is pending.
        try await until { !audio.inspecting }
        check(!audio.running && !audio.canStart, "background inspection cannot automatically resume recognition")
        model.setBackground(false)
        check(audio.canStart, "returning foreground allows explicit generation after inspection")
        audio.start()
        try await until { audio.cache?.isComplete == true && !audio.running }
        check(model.hasGeneratedSubtitles, "cached subtitles remain available after background suspension")
        model.setTranslationEnabled(true)
        model.translation.setSourceOverride("ja")
        model.setBackground(true)
        check(model.isTranslating && !model.translation.enabled, "background suspends translation without discarding its selection")
        model.setBackground(false)
        check(model.isTranslating && model.translation.enabled, "foreground restores the selected translation session")
        check(model.translation.sourceOverride == "ja" && model.translation.sourceLanguage == "ja",
              "background and foreground preserve the manual source language")
        defaults.set(true, forKey: "enableSecondarySubtitlesBeta")
        audio.select(.secondary)
        model.bind(url: url, live: false, provider: nil, serverID: nil, itemID: nil, serverURL: nil, token: nil, mediaSourceID: nil)
        try await until { !audio.inspecting && !audio.running }
        check(model.secondaryID == IOSSubtitleIntelligence.generatedSecondaryID,
              "cache still restores the saved secondary when there is no manual override")
        model.bind(url: url, live: false, provider: nil, serverID: nil, itemID: nil, serverURL: nil, token: nil, mediaSourceID: nil)
        model.setTranslationEnabled(true)
        try await until { !audio.inspecting && !audio.running }
        check(model.isTranslating && audio.display == .off,
              "manual translation wins over a late generated-secondary cache restoration")
        model.selectGeneratedPrimary()
        check(model.translation.hasSource, "restored cache can still be selected manually")
        audio.deleteCache()
        check(!model.translation.hasSource, "deleting generated subtitles immediately clears their translation source")
        try await until { !audio.inspecting }
        check(!model.hasGeneratedSubtitles && !model.translation.hasSource, "cache deletion cannot revive the old translation")
        model.followPrimary(key: "pending-ordinary", language: "en") {
            try await Task.sleep(nanoseconds: 100_000_000)
            return SubtitleTimeline(parts: [SubtitlePart(start: 0, end: 1, text: NSAttributedString(string: "ordinary"))])
        }
        model.translation.setSourceOverride("fr")
        model.setBackground(true)
        model.setBackground(false)
        try await until { model.translation.hasSource }
        check(model.translation.sourceOverride == "fr", "pending native subtitle loading resumes with its manual language")
        let ordinarySession = model.translation.generation
        audio.select(.off)
        check(model.translation.hasSource && model.translation.generation == ordinarySession,
              "turning an inactive generated track off preserves ordinary subtitle translation")
        model.selectedOrdinaryPrimary(isOff: true)
        check(!model.isTranslating, "explicit primary off disables translation")
        model.reset()
        let runningAudio = MacAudioSubtitleJob(backend: backend, store: MacAudioSubtitleStore(root: root.appendingPathComponent("uncached")), defaults: defaults)
        let runningModel = IOSSubtitleIntelligence(audio: runningAudio, translation: MacSubtitleTranslation(defaults: defaults))
        runningModel.bind(url: url, live: false, provider: nil, serverID: nil, itemID: nil, serverURL: nil, token: nil, mediaSourceID: nil)
        try await until { !runningAudio.inspecting }
        runningAudio.language = "en-US"
        if !runningAudio.running { runningAudio.start() }
        runningModel.setBackground(true)
        try await Task.sleep(nanoseconds: 250_000_000)
        check(!runningAudio.running && runningAudio.cues.isEmpty, "background cancels in-flight recognition and rejects its late result")
        runningModel.setBackground(false)
        check(!runningAudio.running && runningAudio.canStart, "foreground does not restart recognition without user action")
        runningModel.reset()
        model.bind(url: url, live: false, provider: nil, serverID: nil, itemID: nil, serverURL: nil, token: nil, mediaSourceID: nil)
        model.translation.setTarget("ja")
        let otherURL = root.appendingPathComponent("other.mov")
        model.bind(url: otherURL, live: false, provider: nil, serverID: nil, itemID: nil, serverURL: nil, token: nil, mediaSourceID: nil)
        model.translation.setTarget("fr")
        model.bind(url: url, live: false, provider: nil, serverID: nil, itemID: nil, serverURL: nil, token: nil, mediaSourceID: nil)
        check(model.translation.targetLanguage == "ja", "iOS media rebind restores its independent translation target")
        model.bind(url: otherURL, live: false, provider: nil, serverID: nil, itemID: nil, serverURL: nil, token: nil, mediaSourceID: nil)
        check(model.translation.targetLanguage == "fr", "iOS second video preserves its own target")
        model.reset()
        var inspectionAttempts = 0
        var retryBackend = backend
        retryBackend.inspect = { url in
            inspectionAttempts += 1
            if inspectionAttempts == 1 { throw MacAudioSubtitleError.remoteFailed }
            // Deliberately ignore cancellation to verify the job rejects late responses.
            try? await Task.sleep(nanoseconds: 100_000_000)
            return MacAudioSubtitleSource(url: url, identity: "retry-fixture", duration: 90,
                                          tracks: [.init(id: 7, ordinal: 1, language: nil)])
        }
        let retryAudio = MacAudioSubtitleJob(backend: retryBackend, store: MacAudioSubtitleStore(root: root), defaults: defaults)
        retryAudio.bind(url: url, live: false)
        try await until { !retryAudio.inspecting }
        check(retryAudio.source == nil && inspectionAttempts == 1, "initial failed inspection leaves audio unavailable")
        retryAudio.retryInspectionIfNeeded()
        retryAudio.retryInspectionIfNeeded()
        try await until { !retryAudio.inspecting }
        check(retryAudio.source?.tracks.first?.id == 7 && inspectionAttempts == 2,
              "page entry recovers tracks and coalesces repeated entries during loading")
        retryAudio.language = "ja-JP"
        retryAudio.retryInspectionIfNeeded()
        check(inspectionAttempts == 2 && retryAudio.language == "ja-JP", "loaded tracks and manual language survive page reentry")
        retryAudio.bind(url: url, live: false)
        try await until { inspectionAttempts == 3 }
        retryAudio.reset()
        retryAudio.retryInspectionIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        check(retryAudio.source == nil && !retryAudio.inspecting && inspectionAttempts == 3,
              "reset clears retry context and rejects a late inspection response")
        let remoteURL = URL(string: "https://fixture.invalid/Videos/item/stream")!
        let remoteAudio = MacAudioSubtitleJob(backend: backend, store: MacAudioSubtitleStore(root: root), defaults: defaults)
        let remoteModel = IOSSubtitleIntelligence(audio: remoteAudio, translation: MacSubtitleTranslation(defaults: defaults))
        let streams: [[String: Any]] = [
            ["Index": 3, "Type": "Audio", "Codec": "aac", "DisplayTitle": "English", "Language": "en"],
            ["Index": 8, "Type": "Audio", "Codec": "aac", "DisplayTitle": "Japanese", "Language": "ja"]]
        let metadata = try JSONSerialization.data(withJSONObject: ["MediaSources": [[
            "Id": "current-version", "RunTimeTicks": 1200000000, "Size": 200000, "ETag": "version-etag", "MediaStreams": streams]]])
        func supplyPlaybackMetadata(_ url: URL = remoteURL) {
            remoteModel.retryAudioInspection(url: url, provider: "jellyfin", serverID: "server", itemID: "item",
                serverURL: URL(string: "https://fixture.invalid"), token: "current-token", mediaSourceID: "current-version",
                playbackMetadata: metadata)
        }
        remoteModel.bind(url: remoteURL, live: false, provider: "jellyfin", serverID: "server", itemID: "item",
            serverURL: URL(string: "https://fixture.invalid"), token: "", mediaSourceID: "stale-version")
        try await until { !remoteAudio.inspecting }
        check(remoteAudio.source == nil, "stale initial remote context fails before page entry")
        supplyPlaybackMetadata()
        try await until { !remoteAudio.inspecting }
        check(remoteAudio.source?.tracks.map(\.id) == [3, 8], "existing playback server tracks recover without a metadata request")
        check(remoteAudio.source?.remote?.mediaSourceID == "current-version" && remoteAudio.source?.remote?.token == "current-token",
              "recovery replaces stale version and credentials with current playback context")
        check(remoteAudio.source?.remote?.usesVideoRoute == true, "recovered multiple tracks keep explicit server audio mapping")
        remoteModel.bind(url: remoteURL, live: false, provider: "jellyfin", serverID: "server", itemID: "item",
            serverURL: URL(string: "https://fixture.invalid"), token: "", mediaSourceID: "stale-version")
        supplyPlaybackMetadata()
        try await until { !remoteAudio.inspecting }
        check(remoteAudio.source?.tracks.count == 2, "ready playback metadata supersedes a pending initial read")
        let canonicalRemote = MacJellyfinAudioSubtitles(serverURL: URL(string: "https://fixture.invalid")!,
            serverID: "server", itemID: "item", mediaSourceID: "current-version", token: "current-token")
        let canonical = try canonicalRemote.source(from: metadata)
        check(remoteAudio.source?.identity == canonical.identity, "page recovery and independent inspection share ETag cache identity")
        let topLevel = try JSONSerialization.data(withJSONObject: ["MediaSources": [[
            "Id": "current-version", "RunTimeTicks": 1200000000, "Size": 200000, "ETag": "version-etag"]], "MediaStreams": streams])
        let normalized = try canonicalRemote.source(from: IOSSubtitleIntelligence.normalizedPlaybackMetadata(topLevel))
        check(normalized.identity == canonical.identity && normalized.tracks.count == 2,
              "single-version top-level streams preserve tracks and cache identity")
        let ambiguous = try JSONSerialization.data(withJSONObject: ["MediaSources": [[
            "Id": "current-version", "RunTimeTicks": 1200000000], ["Id": "other", "RunTimeTicks": 1200000000]], "MediaStreams": streams])
        check((try? canonicalRemote.source(from: IOSSubtitleIntelligence.normalizedPlaybackMetadata(ambiguous))) == nil,
              "ambiguous top-level streams are not assigned to a selected version")
        remoteModel.bind(url: remoteURL, live: false, provider: "jellyfin", serverID: "server", itemID: "item",
            serverURL: URL(string: "https://fixture.invalid"), token: "", mediaSourceID: "current-version")
        IOSSubtitleIntelligence.rememberPlaybackMetadata(metadata, provider: "jellyfin", serverID: "server", itemID: "item")
        remoteModel.retryAudioInspection(url: remoteURL, provider: "jellyfin", serverID: "server", itemID: "item",
            serverURL: URL(string: "https://fixture.invalid"), token: "current-token", mediaSourceID: "current-version")
        try await until { !remoteAudio.inspecting }
        check(remoteAudio.source?.identity == canonical.identity, "service response reuse preserves canonical fingerprint without synthetic metadata")
        remoteModel.reset()
        supplyPlaybackMetadata()
        check(remoteAudio.source == nil && !remoteAudio.inspecting, "old playback metadata cannot revive a reset player")
        remoteModel.hasSelectedPrimarySubtitle = true
        remoteModel.setTranslationEnabled(true)
        let remotePart = SubtitlePart(start: 10, end: 12, text: NSAttributedString(string: "remote dialogue"))
        var documentLoads = 0
        remoteModel.followPrimaryDocument(key: "remote-track-1", language: "en") {
            documentLoads += 1
            return SubtitleBrowserDocument(parts: [remotePart], isPartial: true, partialStatusKey: "SB.Indexed")
        }
        try await until { remoteModel.translation.hasSource }
        check(remoteModel.primarySourceIsPartial && documentLoads == 1, "Indexed primary feeds translation and preserves partial coverage")
        remoteModel.followPrimaryDocument(key: "remote-track-1", language: "en") {
            documentLoads += 1
            return SubtitleBrowserDocument(parts: [])
        }
        await Task.yield()
        check(remoteModel.primarySourceIsPartial && documentLoads == 1, "Repeated source refresh does not reread or erase coverage")
        remoteModel.followPrimary(key: "local-track", language: "en") { SubtitleTimeline(parts: [remotePart]) }
        try await until { remoteModel.translation.hasSource }
        check(!remoteModel.primarySourceIsPartial, "Returning to a complete local source clears remote partial coverage")
        var pendingDocument: CheckedContinuation<SubtitleBrowserDocument, Never>?
        remoteModel.followPrimaryDocument(key: "remote-slow", language: "en") {
            await withCheckedContinuation { pendingDocument = $0 }
        }
        try await until { pendingDocument != nil }
        remoteModel.reset()
        pendingDocument?.resume(returning: SubtitleBrowserDocument(parts: [remotePart], isPartial: true))
        try await Task.sleep(nanoseconds: 30_000_000)
        check(!remoteModel.primarySourceIsPartial && !remoteModel.translation.hasSource,
              "Late remote subtitle completion cannot restore text or coverage after reset")
        let decodedKey = "attempt-1|track-2"
        remoteModel.updateDecodedPrimary(key: decodedKey, language: "en", text: "observed", start: 10, end: 12)
        check(!remoteModel.isTranslating && !remoteModel.translation.hasSource, "Recording decoded primary does not enable translation")
        func decodedSource(_ full: SubtitleBrowserSource? = nil) -> SubtitleBrowserSource {
            remoteModel.decodedPrimaryBrowserSource(key: decodedKey, title: "Primary", offset: 2, fullSource: full)!
        }
        let observed = try await decodedSource().load()
        check(observed.isPartial && observed.partialStatusKey == "SB.Decoded" && observed.entries.first?.text == "observed", "Decoded browser contains only observed text and is explicitly partial")
        check(observed.activeIDs(at: 12, offset: 2) == [observed.entries[0].id], "Decoded browsing uses original cue timestamps plus display delay")
        var failedReads = 0
        let failing = SubtitleBrowserSource(id: "remote-full", title: "Primary", offset: 2) {
            failedReads += 1
            throw URLError(.badServerResponse)
        }
        let fallback = try await decodedSource(failing).load()
        check(failedReads == 1 && fallback.entries == observed.entries && fallback.isPartial, "Failed full browser read falls back to observed primary text")
        _ = try await decodedSource(failing).load()
        check(failedReads == 1, "Repeated browser updates do not retry a failed network source")
        let oldRevision = decodedSource(failing).revision
        remoteModel.updateDecodedPrimary(key: decodedKey, language: "en", text: "after seek", start: 2, end: 3)
        let appended = try await decodedSource(failing).load()
        check(decodedSource(failing).revision != oldRevision && appended.entries.last?.id == observed.entries[0].id,
              "New decoded lines refresh browser without renumbering existing rows")
        let currentRevision = decodedSource(failing).revision
        remoteModel.updateDecodedPrimary(key: decodedKey, language: "en", text: "after seek", start: 2, end: 3)
        check(decodedSource(failing).revision == currentRevision, "Repeated paused frames do not refresh browser documents")
        let full = SubtitleBrowserSource(id: "available-full", title: "Primary", revision: "v1", offset: 2) {
            SubtitleBrowserDocument(parts: [remotePart])
        }
        check(decodedSource(full).revision == "v1", "Decoded arrival does not change an in-progress full-read revision")
        let complete = try await decodedSource(full).load()
        check(!complete.isPartial && complete.entries.first?.text == "remote dialogue", "Successful full document stays preferred")
        for (id, error) in [("cancelled", CancellationError() as Error), ("bitmap", SubtitleBrowserError.bitmap as Error)] {
            let invalid = SubtitleBrowserSource(id: id, title: "Primary", offset: 0) { throw error }
            do { _ = try await decodedSource(invalid).load(); preconditionFailure("Must not fall back on cancellation/bitmap") }
            catch { check(decodedSource(invalid).revision == invalid.revision, "Cancellation and bitmap errors do not enable decoded browser fallback") }
        }
        remoteModel.hasSelectedPrimarySubtitle = true
        remoteModel.setTranslationEnabled(true)
        var failedTranslationReads = 0
        remoteModel.followPrimaryDocument(key: "failed-full", language: "en", decodedFallbackKey: decodedKey) {
            failedTranslationReads += 1
            throw URLError(.badServerResponse)
        }
        try await until { remoteModel.translation.hasSource }
        check(remoteModel.primarySourceIsPartial && !remoteModel.translation.canRetry,
              "Failed full translation read hands ownership to incremental decoded translation")
        let decodedGeneration = remoteModel.translation.generation
        remoteModel.translation.setSourceOverride("fr")
        let manualLanguageGeneration = remoteModel.translation.generation
        remoteModel.updateDecodedPrimary(key: decodedKey, language: "en", text: "next", start: 20, end: 22)
        check(remoteModel.translation.generation == manualLanguageGeneration && remoteModel.translation.sourceOverride == "fr",
              "New decoded lines preserve translation session and manual source language")
        remoteModel.followPrimaryDocument(key: "failed-full", language: "en", decodedFallbackKey: decodedKey) {
            failedTranslationReads += 1
            throw URLError(.badServerResponse)
        }
        await Task.yield()
        check(failedTranslationReads == 1, "Primary refresh does not reopen the failed full source during decoded translation")
        remoteModel.followPrimary(key: "full-replacement", language: "en") { SubtitleTimeline(parts: [remotePart]) }
        try await until { remoteModel.translation.hasSource }
        remoteModel.updateDecodedPrimary(key: decodedKey, language: "en", text: "later", start: 30, end: 32)
        check(!remoteModel.primarySourceIsPartial && remoteModel.translation.generation != decodedGeneration &&
              remoteModel.translation.browserParts(content: .original).first?.text?.string == "remote dialogue",
              "Decoded updates cannot overwrite a newly available full translation source")
        remoteModel.followDecodedPrimary(key: decodedKey)
        let staleBrowser = decodedSource(failing)
        remoteModel.updateDecodedPrimary(key: "attempt-1|track-3", language: "ja", text: "new track", start: 10, end: 12)
        check(!remoteModel.translation.hasSource, "Changing selected track immediately clears old decoded translation")
        do { _ = try await staleBrowser.load(); preconditionFailure("Old track source must be invalid") }
        catch is CancellationError { check(true, "Captured browser source cannot publish after a track change") }
        remoteModel.followDecodedPrimary(key: "attempt-1|track-3")
        remoteModel.updateDecodedPrimary(key: nil, language: nil, text: "", start: nil, end: nil)
        check(!remoteModel.translation.hasSource && remoteModel.decodedPrimaryBrowserSource(key: "attempt-1|track-3", title: "Primary", offset: 0, fullSource: nil) == nil,
              "Turning off primary removes decoded text and its browser source")
        remoteModel.reset()
        var preparationCount = 0
        var preparedTrack: Int32?
        var preparationTranscriptions = 0
        var preparationBackend = MacAudioSubtitleBackend(inspect: { url in
            MacAudioSubtitleSource(url: url, identity: "prepared-fixture", duration: 15,
                tracks: [.init(id: 7, ordinal: 1, language: "en")], decoder: .vlcRemux)
        }, languages: { ["en-US"] }, available: { true }, prepare: { _ in },
           transcribe: { _, _, _, _ in
            preparationTranscriptions += 1
            return [.init(id: 0, start: 0, end: 1, text: "prepared")]
        }, revision: "preparation-fixture", prepareAudio: { _, track in
            preparationCount += 1
            preparedTrack = track
        })
        let preparationJob = MacAudioSubtitleJob(backend: preparationBackend,
            store: MacAudioSubtitleStore(root: root.appendingPathComponent("prepared")), defaults: defaults)
        preparationJob.bind(url: root.appendingPathComponent("prepared.mkv"), live: false)
        try await until { !preparationJob.inspecting && preparationJob.source != nil }
        preparationJob.language = "en-US"
        preparationJob.start()
        try await until { !preparationJob.running && preparationJob.cache?.isComplete == true }
        check(preparationCount == 1 && preparedTrack == 7 && preparationTranscriptions == 1,
              "injected audio preparation uses selected source track without a live VLC extractor")
        preparationJob.reset()
        preparationBackend.prepareAudio = { _, _ in
            preparationCount += 1
            try? await Task.sleep(nanoseconds: 100_000_000) // an uncooperative provider
        }
        let cancelledPreparation = MacAudioSubtitleJob(backend: preparationBackend,
            store: MacAudioSubtitleStore(root: root.appendingPathComponent("cancelled-preparation")), defaults: defaults)
        cancelledPreparation.bind(url: root.appendingPathComponent("cancelled-prepared.mkv"), live: false)
        try await until { !cancelledPreparation.inspecting && cancelledPreparation.source != nil }
        cancelledPreparation.language = "en-US"
        cancelledPreparation.start()
        try await until { preparationCount == 2 }
        cancelledPreparation.reset()
        try await Task.sleep(nanoseconds: 150_000_000)
        check(preparationTranscriptions == 1 && cancelledPreparation.source == nil,
              "late audio preparation cannot start transcription after session reset")
        print("PASS: \(count) iOS adapter model checks")
        if let i = CommandLine.arguments.firstIndex(of: "--smb-fixture"), CommandLine.arguments.indices.contains(i + 1) {
            try await smbChecks(fixture: URL(fileURLWithPath: CommandLine.arguments[i + 1]), root: root)
        }
    }
}
